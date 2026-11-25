import Foundation

/// Ein erzeugtes Token mit seiner Wahrscheinlichkeit, aus der Antwort von llama-server (`n_probs`).
public struct TokenProb: Sendable {
    public struct Option: Sendable {
        public let id: Int
        public let bytes: [UInt8]
        public let logprob: Double
        public init(id: Int, bytes: [UInt8], logprob: Double) { self.id = id; self.bytes = bytes; self.logprob = logprob }
    }
    public let id: Int
    /// Der Text, den der Server zu diesem Token geschickt hat.
    public let bytes: [UInt8]
    public let logprob: Double
    /// Die wahrscheinlichsten Tokens an dieser Stelle, vor Grammatik und Bevorzugung.
    public let top: [Option]
    public init(id: Int, bytes: [UInt8], logprob: Double, top: [Option]) { self.id = id; self.bytes = bytes; self.logprob = logprob; self.top = top }
}

/// Ein Vorschlag mit der Sicherheit je Wort.
public struct Scored: Sendable, Equatable {
    public var text: String
    /// Je Wort (wie `Joiner.nextChunk` zerlegt): Wahrscheinlichkeit, dass der Vorschlag bis einschließlich
    /// dieses Worts stimmt. nil, wenn der Server keine Angaben gemacht hat.
    public var sure: [Double]?
    public init(text: String, sure: [Double]?) { self.text = text; self.sure = sure }
}

/// Nur zeigen, was das Modell für wahrscheinlich hält.
public enum Confidence {
    /// So viele Alternativen je Token fragt Nachsatz ab. Reicht, um das angefangene Wort herauszurechnen.
    public static let alternatives = 10
    public static let levels = 0...3
    public static let standard = 1

    /// Vorsicht 0 aus, 1 leicht, 2 mittel, 3 stark: so wahrscheinlich muss der gezeigte Text mindestens sein.
    public static func threshold(level: Int) -> Double { [0, 0.1, 0.25, 0.45][min(3, max(0, level))] }

    /// Liest `completion_probabilities`. nil, wenn sie fehlen oder ein unbekanntes Format haben.
    public static func tokens(_ list: Any?) -> [TokenProb]? {
        guard let list = list as? [[String: Any]] else { return nil }
        var out: [TokenProb] = []
        for t in list {
            guard let id = int(t["id"]), let lp = num(t["logprob"]) else { return nil }
            let top = (t["top_logprobs"] as? [[String: Any]] ?? []).compactMap { o -> TokenProb.Option? in
                guard let i = int(o["id"]), let l = num(o["logprob"]) else { return nil }
                return .init(id: i, bytes: bytes(o), logprob: l)
            }
            out.append(TokenProb(id: id, bytes: bytes(t), logprob: lp, top: top))
        }
        return out
    }

    /// Sicherheit je Wort von `suggestion`. `output` ist die ganze Modellausgabe, sie beginnt mit `forced`
    /// (dem angefangenen Wort). `biases` sind die Bevorzugungen nach Token, wie an den Server geschickt.
    /// nil, wenn sich Vorschlag und Tokens nicht sicher zuordnen lassen.
    public static func wordProbs(output: String, forced: String, suggestion: String, tokens: [TokenProb],
                                 biases: [Int: Double] = [:]) -> [Double]? {
        let out = Array(output.utf8), f = Array(forced.utf8), s = Array(suggestion.utf8)
        guard out.starts(with: f) else { return nil }
        // Der Vorschlag steht direkt hinter dem Vorgegebenen, höchstens ohne führende Leerzeichen.
        var base = f.count
        if !out[base...].starts(with: s) {
            while base < out.count, out[base] == 0x20 || out[base] == 0x09 { base += 1 }
            guard out[base...].starts(with: s) else { return nil }
        }
        var ends: [Int] = [], rest = suggestion, at = base
        while !rest.isEmpty {
            let c = Joiner.nextChunk(of: rest)
            if c.trimmingCharacters(in: .whitespaces).isEmpty { break }
            at += c.utf8.count; ends.append(at); rest.removeFirst(c.count)
        }
        guard !ends.isEmpty else { return nil }

        var result: [Double] = [], log = 0.0, pos = 0, i = 0
        for e in ends {
            while pos < e {
                guard i < tokens.count else { return nil } // Tokens reichen nicht bis zum Wortende
                let t = tokens[i], end = pos + t.bytes.count
                // Der Text der Tokens muss genau die Ausgabe ergeben.
                let n = min(end, out.count) - pos
                guard n >= 0, out[pos..<(pos + n)].elementsEqual(t.bytes.prefix(n)) else { return nil }
                if end > f.count { // ganz Vorgegebenes zählt nicht
                    guard let p = probability(t, forcedRest: pos < f.count ? Array(f[pos...]) : nil, biases: biases) else { return nil }
                    log += p
                }
                pos = end; i += 1
            }
            result.append(exp(log))
        }
        return result
    }

    /// Log-Wahrscheinlichkeit des gewählten Tokens. Steckt darin noch ein Teil des angefangenen Worts,
    /// zählen nur Tokens, die dazu passen: Das Modell wusste nicht, wie das Wort beginnt.
    static func probability(_ t: TokenProb, forcedRest: [UInt8]?, biases: [Int: Double]) -> Double? {
        var all = t.top
        if !all.contains(where: { $0.id == t.id }) { all.append(.init(id: t.id, bytes: t.bytes, logprob: t.logprob)) }
        func q(_ o: TokenProb.Option) -> Double { exp(o.logprob + (biases[o.id] ?? 0)) }
        let chosen = q(all.first { $0.id == t.id }!)
        let total: Double
        if let r = forcedRest {
            total = all.filter { $0.bytes.starts(with: r) || r.starts(with: $0.bytes) }.map(q).reduce(0, +)
        } else {
            // Bevorzugte Tokens verschieben die Verteilung. Erfasst sind nur die unter den Alternativen.
            total = 1 + all.filter { biases[$0.id] != nil }.map { exp($0.logprob) * (exp(biases[$0.id]!) - 1) }.reduce(0, +)
        }
        guard total > 0, chosen > 0 else { return nil }
        return Swift.min(0, Foundation.log(chosen / total))
    }

    /// Vorschlag bis zum letzten Wort, das noch sicher genug ist. nil, wenn schon das erste zu unsicher ist.
    /// Ohne Angaben vom Server bleibt der Vorschlag, wie er ist.
    public static func cut(_ s: Scored, min: Double) -> String? {
        guard min > 0, let sure = s.sure else { return s.text }
        var take = "", rest = s.text, i = 0
        while i < sure.count, sure[i] >= min, !rest.isEmpty {
            let c = Joiner.nextChunk(of: rest)
            if c.trimmingCharacters(in: .whitespaces).isEmpty { break }
            take += c; rest.removeFirst(c.count); i += 1
        }
        if rest.isEmpty || i == sure.count { return s.text }
        while let l = take.last, l.isWhitespace || "(„\"-–:;".contains(l) { take.removeLast() }
        return take.contains(where: { $0.isLetter || $0.isNumber }) ? take : nil
    }

    private static func num(_ x: Any?) -> Double? { (x as? NSNumber)?.doubleValue ?? (x as? Double) }
    private static func int(_ x: Any?) -> Int? { (x as? NSNumber)?.intValue ?? (x as? Int) }
    private static func bytes(_ o: [String: Any]) -> [UInt8] {
        if let b = o["bytes"] as? [Any] { return b.compactMap { int($0).map { UInt8(truncatingIfNeeded: $0) } } }
        return Array((o["token"] as? String ?? "").utf8)
    }
}
