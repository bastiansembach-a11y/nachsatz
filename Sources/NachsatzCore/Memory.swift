import CryptoKit
import Foundation

public struct Note: Codable, Identifiable, Sendable, Equatable {
    public var id = UUID()
    public var date: Date
    public var app: String
    public var text: String
    public init(date: Date, app: String, text: String) { self.date = date; self.app = app; self.text = text }
}

/// Verfolgt, was in einem Feld selbst getippt wird. Eingefügtes und vorhandener Text zählen nicht.
public struct TypingSession: Sendable {
    private var anchor: String?
    private var latest = ""
    private var tail = ""
    private var prelude = 0
    private var dirty = false

    public init() {}

    public mutating func typed(_ s: String) {
        tail += s
        if anchor == nil { prelude += s.count }
    }
    public mutating func deleted() {
        if !tail.isEmpty { tail.removeLast(); if anchor == nil { prelude -= 1 } } else { dirty = true }
    }
    public mutating func uncertain() { dirty = true }

    /// Stand des Feldes nach einer Tipp-Pause.
    public mutating func read(_ before: String) {
        if anchor == nil { anchor = String(before.dropLast(min(prelude, before.count))) }
        latest = before; tail = ""; dirty = false
    }

    public var text: String? {
        guard let anchor, !dirty else { return nil }
        let a = String(anchor.suffix(60))
        if a.isEmpty { return latest + tail }
        guard let r = latest.range(of: a, options: .backwards) else { return nil }
        return String(latest[r.upperBound...]) + tail
    }
}

/// Zerlegt Getipptes in speicherbare Stücke und wirft Heikles weg. Fängt nicht alles ab.
public enum NoteFilter {
    private static let keyword = try! NSRegularExpression(
        pattern: #"(?i)\b(passw\w*|password\w*|kennwort\w*|zugangsdaten|pin|tan|cvv|cvc|api[ -]?key|secret|token|einmalcode|sicherheitscode|iban|kreditkarte\w*)\b"#)
    private static let iban = try! NSRegularExpression(pattern: #"(?i)\b[a-z]{2}\d{2}(?: ?[a-z0-9]){11,30}\b"#)
    private static let digits = try! NSRegularExpression(pattern: #"\d(?:[ .\-/]?\d){5,}"#)

    public static func pieces(_ raw: String) -> [String] {
        var out: [String] = [], cur = ""
        // Heikle Wörter markieren, bevor „!“ oder „.“ darin sie in zwei Sätze zerlegt.
        let marked = raw.components(separatedBy: .newlines).map { line in
            line.split(whereSeparator: \.isWhitespace).map { isSensitiveWord(String($0)) ? "\u{26D4}" : String($0) }.joined(separator: " ")
        }.joined(separator: "\n")
        for s in sentences(marked) where !isSensitive(s) && !s.contains("\u{26D4}") {
            if cur.count + s.count > 400, !cur.isEmpty { out.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : " ") + s
        }
        if !cur.isEmpty { out.append(cur) }
        return out.filter { $0.count >= 20 && $0.split(separator: " ").count >= 4 }
    }

    public static func isSensitive(_ s: String) -> Bool {
        let r = NSRange(s.startIndex..., in: s)
        if [keyword, iban, digits].contains(where: { $0.firstMatch(in: s, range: r) != nil }) { return true }
        return s.split(whereSeparator: \.isWhitespace).contains { isSensitiveWord(String($0)) }
    }

    private static func isSensitiveWord(_ w: String) -> Bool {
        let t = w.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:()\"„“”'"))
        if t.lowercased().hasPrefix("http") || t.contains("://") { return true }
        let d = t.contains(where: \.isNumber), l = t.contains(where: \.isLetter)
        let mixed = t.contains(where: \.isUppercase) && t.contains(where: \.isLowercase)
        let symbol = t.contains(where: { !$0.isLetter && !$0.isNumber && !"-–/.'’".contains($0) })
        return (t.count >= 8 && d && l && (mixed || symbol)) || (t.count >= 24 && d && l) || t.count > 45
    }

    private static func sentences(_ s: String) -> [String] {
        var out: [String] = []
        s.enumerateSubstrings(in: s.startIndex..., options: [.bySentences]) { sub, _, _, _ in
            let t = (sub ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !t.isEmpty { out.append(t) }
        }
        return out
    }
}

/// Verschlüsselter Speicher für wenige Tage. Ohne Schlüssel wird nichts gespeichert.
public actor MemoryStore {
    public nonisolated static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Nachsatz/memory.bin")

    private let url: URL
    private var key: SymmetricKey?
    private var notes: [Note] = []
    private var days: Int
    private var style: StyleModel?
    private var selected: (field: String, notes: [Note]) = ("", [])

    public init(url: URL = MemoryStore.defaultURL, days: Int = 5) { self.url = url; self.days = days }

    public enum OpenError: Error { case wrongKey }

    /// Lädt vorhandene Notizen. Passt der Schlüssel nicht, bleibt die Datei unangetastet.
    public func open(key: SymmetricKey) throws {
        if let data = try? Data(contentsOf: url) {
            guard let box = try? AES.GCM.SealedBox(combined: data), let plain = try? AES.GCM.open(box, using: key),
                  let list = try? JSONDecoder().decode([Note].self, from: plain) else { throw OpenError.wrongKey }
            notes = list
        }
        self.key = key
        prune()
    }

    public var isOpen: Bool { key != nil }
    public var all: [Note] { notes.sorted { $0.date > $1.date } }

    public func setDays(_ d: Int) { days = d; prune() }

    public func add(_ raw: String, app: String, date: Date = Date()) {
        guard key != nil else { return }
        var changed = false
        for p in NoteFilter.pieces(raw) {
            if notes.contains(where: { $0.text.contains(p) }) { continue }
            notes.removeAll { $0.app == app && date.timeIntervalSince($0.date) < 900 && p.hasPrefix($0.text) } // gleicher Text, weitergeschrieben
            notes.append(Note(date: date, app: app, text: p))
            changed = true
            style = nil
        }
        if changed { prune(force: true) }
    }

    public func delete(_ id: UUID) { notes.removeAll { $0.id == id }; selected = ("", []); style = nil; save() }

    public func clear() {
        notes = []; selected = ("", []); style = nil
        try? FileManager.default.removeItem(at: url)
    }

    public func prune(force: Bool = false, now: Date = Date()) {
        let n = notes.count
        notes.removeAll { now.timeIntervalSince($0.date) > Double(days) * 86400 }
        if notes.count > 2000 { notes = Array(notes.sorted { $0.date < $1.date }.suffix(2000)) }
        if notes.count != n { selected = ("", []); style = nil }
        if force || notes.count != n { save() }
    }

    private func save() {
        guard let key, let plain = try? JSONEncoder().encode(notes), let box = try? AES.GCM.seal(plain, using: key).combined else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? box.write(to: url, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var u = url, v = URLResourceValues()
        v.isExcludedFromBackup = true
        try? u.setResourceValues(v)
    }

    // MARK: Auswahl

    /// Notizen, die zum Text passen. Bleibt innerhalb eines Feldes möglichst gleich und
    /// wächst nur hinten, damit das Modell den Anfang nicht neu lesen muss.
    public func context(for text: String, field: String, app: String = "", level: Int = Personalization.standard) -> String {
        let p = Personalization(level: level)
        guard key != nil, !notes.isEmpty, !p.isOff else { return "" }
        let hits = rank(text, p)
        let field = field + "#\(level)"
        if selected.field != field {
            // Stilprobe: letzte eigene Texte aus derselben App, am Anfang und damit stabil.
            selected = (field, Array(notes.filter { $0.app == app && !text.contains($0.text) }.sorted { $0.date < $1.date }.suffix(p.samples)))
        }
        for h in hits where !selected.notes.contains(h) { selected.notes.append(h) }
        if selected.notes.reduce(0, { $0 + $1.text.count + 2 }) > p.budget { // zu voll: nur noch Passendes
            selected.notes = []
            var used = 0
            for h in hits where used + h.text.count + 2 <= p.budget { selected.notes.append(h); used += h.text.count + 2 }
        }
        return selected.notes.map(\.text).joined(separator: "\n\n")
    }

    /// Eigene Wörter, die an dieser Stelle üblich sind, mit Stärke für das Modell.
    public func preferred(for text: String, level: Int) -> [(word: String, bias: Double)] {
        let p = Personalization(level: level)
        guard key != nil, !p.isOff, !notes.isEmpty else { return [] }
        if style == nil { style = StyleModel(notes: notes) }
        return style!.followers(of: text).map { ($0.word, $0.weight * p.bias) }
    }

    private func rank(_ text: String, _ p: Personalization) -> [Note] {
        let tail = String(text.suffix(240))
        var words = Self.words(tail)
        var partial = ""
        if let l = tail.last, !l.isWhitespace, let w = words.last { partial = w; words.removeLast() }
        let query = Set(words.filter { !Self.stop.contains($0) && $0.count > 2 })
        guard !query.isEmpty || partial.count >= 2 else { return [] }

        let sets = notes.map { Set(Self.words($0.text)) }
        var df: [String: Int] = [:]
        for s in sets { for w in s { df[w, default: 0] += 1 } }
        let total = Double(notes.count)
        func idf(_ w: String) -> Double { log(1 + total / Double(df[w] ?? 1)) }
        let now = Date()
        var scored: [(Note, Double)] = []
        for (n, s) in zip(notes, sets) {
            if text.contains(n.text) { continue } // steht schon da
            let common = query.intersection(s)
            var matches = common.count
            var score = common.reduce(0) { $0 + idf($1) }
            if partial.count >= 2, !Self.stop.contains(partial),
               let w = s.filter({ $0.hasPrefix(partial) && $0.count > max(4, partial.count) }).max(by: { idf($0) < idf($1) }) {
                score += idf(w) * (partial.count >= 4 ? 1 : 0.7)
                matches += partial.count >= 4 ? 3 : 2 // ein angefangenes seltenes Wort ist ein klares Zeichen
            }
            let age = now.timeIntervalSince(n.date) / 86400
            if score > 0, matches >= p.minMatches { scored.append((n, score * (1 + 0.2 / (1 + age)))) }
        }
        guard let best = scored.map(\.1).max() else { return [] }
        return scored.filter { $0.1 >= best * p.threshold }.sorted { $0.1 > $1.1 }.prefix(p.maxNotes).map(\.0)
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    static let stop: Set<String> = Set("""
    der die das den dem des ein eine einen einem einer eines und oder aber ich du er sie es wir ihr mich dich mir dir uns euch ihm ihn ihnen sich mein dein sein \
    meine deine seine unser ihre ihren ihrer ihrem ist sind war waren bin bist hat habe haben hatte wird werden wurde kann können könnte muss müssen soll will würde \
    nicht noch schon auch nur sehr mal wieder dann wenn weil dass ob als wie was wer wo von vom zum zur mit bei für auf aus nach vor über unter durch gegen ohne um an am im in \
    heute morgen gestern bitte danke vielen viele dank grüße liebe lieber hallo hier dort ja nein gerne kurz so zu da man alle alles mehr \
    the and but you she they him her them his their our your its are was were been have has had will would can could should must not also only very just again then when because that this these those \
    what who where with from for into about after before under over out off than too thank thanks please hello hey best kind regards dear today tomorrow yesterday here there yes more all some any let get got
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}
