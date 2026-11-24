import Foundation

/// Wie stark eigene Sprache einfließt: 0 aus, 1 leicht, 2 mittel, 3 stark.
public struct Personalization: Sendable {
    public static let levels = 0...3
    public static let standard = 2
    let budget: Int        // Zeichen an Notizen
    let threshold: Double  // wie gut eine Notiz passen muss
    let maxNotes: Int
    let minMatches: Int    // so viele Wörter müssen mindestens übereinstimmen
    let samples: Int       // letzte eigene Texte aus derselben App als Stilprobe
    let bias: Double       // Bevorzugung eigener Wörter

    public init(level: Int) {
        let l = min(3, max(0, level))
        budget = [0, 500, 1100, 1900][l]
        threshold = [1, 0.7, 0.5, 0.3][l]
        maxNotes = [0, 2, 4, 8][l]
        minMatches = [9, 3, 1, 1][l]
        samples = [0, 0, 0, 4][l]
        bias = [0, 1.5, 5, 10][l]
    }
    public var isOff: Bool { budget == 0 }
}

/// Was auf welche Wörter folgt, gezählt aus den eigenen Notizen.
struct StyleModel {
    private var next: [String: [String: Int]] = [:]
    static let start = "^"

    init(notes: [Note]) {
        for n in notes {
            for s in Self.sentences(n.text) {
                let w = Self.tokens(s)
                var one = Self.start, two = Self.start
                for x in w {
                    next[one, default: [:]][x, default: 0] += 1
                    next[two + " " + one, default: [:]][x, default: 0] += 1
                    two = one; one = x.lowercased()
                }
            }
        }
    }

    /// Wörter, die hier mindestens zweimal geschrieben wurden, mit Gewicht 0…1.
    func followers(of text: String) -> [(word: String, weight: Double)] {
        var head = text, partial = ""
        if let l = text.last, l.isLetter || l.isNumber {
            partial = String(text.reversed().prefix { $0.isLetter || $0.isNumber }.reversed())
            head = String(text.dropLast(partial.count))
        } else if let l = text.last, !l.isWhitespace { return [] }
        let sentence = Self.sentences(String(head.suffix(200)) + "\u{1}").last.map { $0.replacingOccurrences(of: "\u{1}", with: "") } ?? ""
        let w = Self.tokens(sentence).map { $0.lowercased() }
        let one = w.last ?? Self.start
        let two = w.count >= 2 ? w[w.count - 2] : Self.start
        var score: [String: Double] = [:]
        for (key, factor) in [(two + " " + one, 1.0), (one, 0.5)] {
            guard let c = next[key] else { continue }
            let total = Double(c.values.reduce(0, +))
            for (x, n) in c where n >= 2 {
                if !partial.isEmpty, !(x.lowercased().hasPrefix(partial.lowercased()) && x.count > partial.count) { continue }
                score[x] = max(score[x] ?? 0, factor * Double(n) / (total + 1))
            }
        }
        return score.filter { $0.value >= 0.1 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6).map { ($0.key, $0.value) }
    }

    static func tokens(_ s: String) -> [String] {
        s.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }.map(String.init)
    }
    static func sentences(_ s: String) -> [String] {
        s.split { ".!?\n".contains($0) }.map(String.init)
    }
}
