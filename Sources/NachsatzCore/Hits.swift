import Foundation

/// Messung der Trefferquote (`Compare llama treffer`): Schnittstellen in Texten und ihre Auswertung.
public enum Hits {
    public struct Cut: Sendable {
        /// Text bis zur Schreibmarke
        public let text: String
        /// Was danach in derselben Zeile wirklich steht
        public let want: String
        /// Schnitt mitten im Wort
        public let mid: Bool
    }

    /// Ab dem vierten Wort jede `step`-te Wortgrenze, bei Wörtern ab sechs Buchstaben zusätzlich ein Schnitt in der Mitte.
    public static func cuts(_ text: String, step: Int = 1) -> [Cut] {
        let c = Array(text)
        let starts = c.indices.filter { !c[$0].isWhitespace && ($0 == 0 || c[$0 - 1].isWhitespace) }
        var out: [Cut] = []
        for (n, s) in starts.enumerated() where n >= 3 && (n - 3) % max(1, step) == 0 {
            let line = String(c[s...].prefix { $0 != "\n" })
            out.append(Cut(text: String(c[..<s]), want: line, mid: false))
            let letters = c[s...].prefix { $0.isLetter }.count
            if letters >= 6 {
                let k = letters / 2
                out.append(Cut(text: String(c[..<(s + k)]), want: String(line.dropFirst(k)), mid: true))
            }
        }
        return out
    }

    /// Wie viele Wörter des Vorschlags von vorn stimmen, und wie viele Zeichen das sind.
    public static func match(_ got: String, want: String) -> (words: Int, chars: Int) {
        var g = Substring(got), w = Substring(want), n = 0, chars = 0
        while !g.isEmpty, !w.isEmpty {
            let a = Joiner.nextChunk(of: String(g)), b = Joiner.nextChunk(of: String(w))
            guard !norm(a).isEmpty, norm(a) == norm(b) else { break }
            n += 1; chars += a.count
            g = g.dropFirst(a.count); w = w.dropFirst(b.count)
        }
        return (n, chars)
    }

    private static func norm(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: .punctuationCharacters).lowercased()
    }

    public struct Score: Sendable, Equatable {
        public var cases = 0
        /// Stellen mit Vorschlag
        public var shown = 0
        /// davon erstes Wort richtig
        public var right = 0
        /// richtige Wörter von vorn, über alle Vorschläge
        public var words = 0
        /// gesparte Anschläge: richtige Zeichen minus ein Tab je Wort
        public var saved = 0
        public init() {}
    }

    /// Auswertung bei einer Schwelle. `results` sind ungekürzte Vorschläge, nil = keiner.
    public static func tally(_ results: [(got: Scored?, cut: Cut)], min: Double) -> Score {
        var s = Score()
        for (got, cut) in results {
            s.cases += 1
            guard let got, let shown = Confidence.cut(got, min: min) else { continue }
            s.shown += 1
            let m = match(shown, want: cut.want)
            if m.words > 0 { s.right += 1 }
            s.words += m.words
            s.saved += max(0, m.chars - m.words)
        }
        return s
    }

    /// Wie oft das erste Wort stimmt, nach der Sicherheit, die das Modell dafür angab (in Zehnteln).
    public static func calibration(_ results: [(got: Scored?, cut: Cut)]) -> [(range: ClosedRange<Double>, n: Int, right: Int)] {
        var n = [Int](repeating: 0, count: 10), r = n
        for (got, cut) in results {
            guard let got, let p = got.sure?.first else { continue }
            let i = Swift.min(9, Int(p * 10))
            n[i] += 1
            if match(got.text, want: cut.want).words > 0 { r[i] += 1 }
        }
        var out: [(range: ClosedRange<Double>, n: Int, right: Int)] = []
        for i in 0..<10 {
            let low = Double(i) / 10, high = Double(i + 1) / 10
            out.append((range: low...high, n: n[i], right: r[i]))
        }
        return out
    }
}
