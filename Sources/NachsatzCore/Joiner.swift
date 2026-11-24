import Foundation

/// Fügt die Rohausgabe des Modells sauber an den getippten Text an:
/// entfernt Wiederholungen, entscheidet über Leerzeichen und kürzt.
public enum Joiner {
    public static func join(text: String, raw: String, maxWords: Int,
                            isWord: (String) -> Bool) -> String? {
        var out = raw.replacingOccurrences(of: "\r", with: "\n")
        while let f = out.first, f == "\n" { out.removeFirst() }
        out = out.components(separatedBy: "\n").first ?? ""
        for q in ["\"", "„", "“", "”"] where out.hasPrefix(q) { out.removeFirst() }
        while let l = out.last, "\"“”".contains(l) || l.isWhitespace { out.removeLast() }
        guard out.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }

        out = stripEcho(text: text, out: out)
        guard !out.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        guard let last = text.last else { return limit(trimLeading(out), maxWords) }

        if last.isWhitespace { return limit(trimLeading(out), maxWords) }

        if last.isLetter || last.isNumber {
            let w = String(text.reversed().prefix { $0.isLetter || $0.isNumber }.reversed())
            let startsWithSpace = out.first?.isWhitespace == true
            let body = trimLeading(out)
            let f = String(body.prefix { $0.isLetter || $0.isNumber })
            if f.isEmpty { return limit(startsWithSpace ? " " + body : body, maxWords) }
            let wOK = known(w, isWord)
            if startsWithSpace && wOK { return limit(" " + body, maxWords) }
            if wOK && known(f, isWord) { return limit(" " + body, maxWords) }
            for k in 0...min(w.count, f.count) {
                guard w.suffix(k).lowercased() == f.prefix(k).lowercased() else { continue }
                let glued = w + f.dropFirst(k)
                if glued.count > w.count, isWord(glued) {
                    return limit(String(body.dropFirst(k)), maxWords)
                }
            }
            return wOK ? limit(" " + body, maxWords) : nil
        }

        let body = trimLeading(out)
        if "([{/\\@#_„»'’-".contains(last) { return limit(body, maxWords) }
        if let b = body.first, ".,!?;:)".contains(b) { return nil }
        return limit(" " + body, maxWords)
    }

    /// Nächstes Wort samt führendem Leerzeichen.
    public static func nextChunk(of s: String) -> String {
        let lead = s.prefix { $0.isWhitespace }
        let word = s.dropFirst(lead.count).prefix { !$0.isWhitespace }
        return String(lead + word)
    }

    /// Das unfertige letzte Wort, falls der Text mitten im Wort endet.
    public static func partialWord(_ text: String) -> String {
        String(text.reversed().prefix { $0.isLetter }.reversed())
    }

    private static func known(_ w: String, _ isWord: (String) -> Bool) -> Bool {
        if w.count == 1 { return w == "I" || w == "a" || w == "A" || w.first!.isNumber }
        return isWord(w)
    }

    private static func trimLeading(_ s: String) -> String { String(s.drop { $0.isWhitespace }) }

    /// Entfernt ganze Wörter am Anfang, die der Text bereits enthält.
    private static func stripEcho(text: String, out: String) -> String {
        let t = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let body = trimLeading(out)
        let o = body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !t.isEmpty, !o.isEmpty else { return out }
        for n in stride(from: min(8, t.count, o.count), through: 1, by: -1) {
            if Array(t.suffix(n)) == o.prefix(n).map({ $0.lowercased() }) {
                let rest = o.dropFirst(n).joined(separator: " ")
                return rest.isEmpty ? "" : " " + rest
            }
        }
        return out
    }

    private static func limit(_ s: String, _ maxWords: Int) -> String? {
        var result = "", count = 0, rest = Substring(s)
        while !rest.isEmpty, count < maxWords {
            let c = nextChunk(of: String(rest))
            if c.trimmingCharacters(in: .whitespaces).isEmpty { break }
            result += c; rest = rest.dropFirst(c.count); count += 1
            if let l = result.last, ".!?".contains(l) { break }
        }
        return result.isEmpty ? nil : result
    }

    public enum Match: Equatable { case rest(String), ahead, no }

    /// Wie `rest`, unterscheidet aber „schon weiter als die bisherige Ausgabe“ von „passt nicht“.
    public static func match(of partial: String, asked: String, now: String) -> Match {
        if let r = rest(of: partial, asked: asked, now: now) { return .rest(r) }
        if now.hasPrefix(asked), now.dropFirst(asked.count).hasPrefix(partial) { return .ahead }
        return .no
    }

    /// Was vom Vorschlag übrig ist, wenn seit der Anfrage weitergetippt wurde. nil, wenn es nicht mehr passt.
    public static func rest(of suggestion: String, asked: String, now: String) -> String? {
        if now == asked { return suggestion }
        var typed: String?
        if now.hasPrefix(asked) { typed = String(now.dropFirst(asked.count)) }
        else if asked.count >= 200 { // Textfenster ist weitergerutscht
            let tail = String(asked.suffix(60))
            if let r = now.range(of: tail, options: .backwards) { typed = String(now[r.upperBound...]) }
        }
        guard let typed, !typed.isEmpty, typed.count < suggestion.count, suggestion.hasPrefix(typed) else { return nil }
        return String(suggestion.dropFirst(typed.count))
    }
}
