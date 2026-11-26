import CoreGraphics
import Foundation

/// Eine erkannte Textzeile auf dem Bildschirm, in globalen Koordinaten mit Ursprung oben links (wie AX).
public struct ScreenLine: Sendable, Equatable {
    public var text: String
    public var rect: CGRect
    public init(text: String, rect: CGRect) { self.text = text; self.rect = rect }
}

/// Macht aus den erkannten Zeilen eines Bildschirmfotos einen kurzen Kontext für das Modell.
public enum ScreenText {
    /// Zeichen, die höchstens in den Prompt gehen. Der Platz je Anfrage ist knapp.
    public static let budget = 600

    /// Nahe an der Schreibmarke zuerst, dann in Lesereihenfolge. Lässt weg, was in `skip` liegt
    /// (das eigene Feld, die Menüleiste), was schon im Feld steht, Bruchstücke und Heikles.
    public static func digest(_ lines: [ScreenLine], near caret: CGRect, skip: [CGRect] = [], written: String = "",
                              budget: Int = budget) -> String {
        let shown = flat(String(written.suffix(4000))).lowercased()
        var seen = Set<String>()
        var keep: [(line: ScreenLine, distance: CGFloat)] = []
        for l in lines {
            let t = flat(l.text)
            // Einzelne Wörter sind meist Knöpfe, Reiter oder Menüs.
            guard t.filter(\.isLetter).count >= 6, t.split(separator: " ").count >= 2 else { continue }
            let mid = CGPoint(x: l.rect.midX, y: l.rect.midY)
            guard !skip.contains(where: { $0.contains(mid) }), !NoteFilter.isSensitive(t) else { continue }
            let key = t.lowercased()
            guard !shown.contains(key), seen.insert(key).inserted else { continue }
            let dx = max(0, abs(mid.x - caret.midX) - l.rect.width / 2), dy = abs(mid.y - caret.midY)
            keep.append((ScreenLine(text: t, rect: l.rect), dy + dx / 2))
        }
        var used = 0, take: [ScreenLine] = []
        for k in keep.sorted(by: { $0.distance < $1.distance }) where used + k.line.text.count + 1 <= budget {
            take.append(k.line)
            used += k.line.text.count + 1
        }
        take.sort { (row($0), $0.rect.minX) < (row($1), $1.rect.minX) }
        return take.map(\.text).joined(separator: "\n")
    }

    /// Zeilen, die fast auf gleicher Höhe stehen, gelten als eine Zeile.
    private static func row(_ l: ScreenLine) -> Int { Int((l.rect.midY / 10).rounded(.down)) }

    private static func flat(_ s: String) -> String { s.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
