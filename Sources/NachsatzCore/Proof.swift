import Foundation

/// Ergänzen mitten im Satz.
public enum Gap {
    static let head = """
    Lückentext mit Lösung.

    Satz: Morgen fahren wir ___ nach Berlin, weil dort ein Konzert ist.
    Lücke: mit dem Auto

    Satz: Please send ___ the invoice as soon as possible.
    Lücke: me

    Satz: Ich muss noch ___ erledigen und melde mich dann.
    Lücke: ein paar Dinge

    Satz: The new phone is ___ than the old one.
    Lücke: much faster


    """

    /// Satzteile links und rechts der Marke. nil, wenn die Marke in einem Wort oder am Zeilenende steht.
    public static func context(before: String, after: String) -> (String, String)? {
        let line = String(after.prefix { $0 != "\n" })
        guard line.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        if let l = before.last, let r = line.first, l.isLetter || l.isNumber, r.isLetter || r.isNumber { return nil }
        let left = String((before.components(separatedBy: "\n").last ?? "").suffix(220))
        let leftSentence = left.components(separatedBy: ". ").last ?? left
        guard leftSentence.filter(\.isLetter).count >= 3 else { return nil }
        // Steht die Marke direkt vor einem Satzende, ist es keine Lücke.
        guard let f = line.first(where: { !$0.isWhitespace }), !".!?".contains(f) else { return nil }
        var right = String(line.prefix(160))
        if let e = right.firstIndex(where: { ".!?".contains($0) }) { right = String(right[...e]) }
        return (leftSentence, right)
    }

    public static func prompt(_ l: String, _ r: String) -> String {
        let a = l.trimmingCharacters(in: .whitespaces), b = r.trimmingCharacters(in: .whitespaces)
        return head + "Satz: \(a) ___ \(b)\nLücke:"
    }

    /// Säubert die Antwort und setzt die Leerzeichen passend.
    public static func finish(_ raw: String, left: String, right: String) -> String? {
        var w = raw.components(separatedBy: "\n")[0].split(whereSeparator: \.isWhitespace).map(String.init)
        func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let l = left.split(whereSeparator: \.isWhitespace).map { key(String($0)) }, r = right.split(whereSeparator: \.isWhitespace).map { key(String($0)) }
        if w.count > 5 || w.contains(where: { $0.contains("_") || $0.contains("<") }) { return nil }
        while let f = w.first, let x = l.last, key(f) == x { w.removeFirst() }          // schon davor
        while let e = w.last, let x = r.first, key(e) == x { w.removeLast() }           // kommt danach
        if w.count > 1, let e = w.last, r.prefix(3).contains(key(e)), key(e).count > 3 { return nil }
        if let e = w.last, ".!?".contains(e.last!) { w[w.count - 1] = String(e.dropLast()) }
        guard !w.isEmpty, w.contains(where: { $0.contains(where: \.isLetter) }) else { return nil }
        if w.allSatisfy({ x in l.suffix(4).contains(key(x)) || r.prefix(4).contains(key(x)) }) { return nil }
        // Verstärker vor Verstärker („sehr“ vor „sehr lecker“, „so“ vor „sehr“).
        let boost: Set = ["sehr", "so", "ganz", "echt", "wirklich", "really", "very", "so", "quite", "too", "zu"]
        if let e = w.last, let x = r.first, boost.contains(key(e)), boost.contains(x) { return nil }
        var out = w.joined(separator: " ")
        if let c = left.last, !c.isWhitespace, !"(„\"".contains(c) { out = " " + out }
        if let c = right.first, c.isLetter || c.isNumber { out += " " }
        return out
    }
}

public struct Fix: Equatable, Sendable {
    public var range: NSRange          // im geprüften Text, UTF-16
    public var original: String
    public var replacement: String
    public var isSpelling: Bool        // sonst Grammatik oder Komma
    public var sentence: NSRange
    public init(range: NSRange, original: String, replacement: String, isSpelling: Bool, sentence: NSRange) {
        self.range = range; self.original = original; self.replacement = replacement; self.isSpelling = isSpelling; self.sentence = sentence
    }
}

/// Vergleicht einen Satz mit seiner Korrektur und behält nur vertrauenswürdige Änderungen.
public enum Corrector {
    static let head: String = {
        let p: [(String, String?)] = [
            ("Ich hoffe das du morgen zeit hast.", "Ich hoffe, dass du morgen Zeit hast."), ("Wir treffen uns am Montag im Büro.", nil),
            ("He have two brothers and one sister.", "He has two brothers and one sister."), ("ok bis später, hab grad keine Zeit", nil),
            ("Der Film, dass wir gesehen haben, war lang.", "Der Film, den wir gesehen haben, war lang."), ("Das Haus, dass er gebaut hat, ist alt.", "Das Haus, das er gebaut hat, ist alt."),
            ("Thanks for the update, see you tomorrow.", nil), ("Ich habe gestern ein neuen Schreibtich gekauft.", "Ich habe gestern einen neuen Schreibtisch gekauft."),
            ("Seit ihr schon fertig?", "Seid ihr schon fertig?"), ("Ich warte schon seid einer Stunde.", "Ich warte schon seit einer Stunde."),
            ("Hab ich schon erledigt, danke dir!", nil), ("Sie ist jünger wie ihr Bruder.", "Sie ist jünger als ihr Bruder."),
            ("Were is you're bag? I definitly saw it.", "Where is your bag? I definitely saw it."), ("gonna check that later, thx", nil),
            ("Mein Bruder und ich geht heute Schwimmen.", "Mein Bruder und ich gehen heute schwimmen."), ("I am interested to learn Spanish.", "I am interested in learning Spanish."),
        ]
        return "Korrekturen. Nur echte Fehler werden geändert. Richtige Sätze, Umgangssprache und Namen bleiben gleich.\n\n"
            + p.map { "Original: \($0)\nKorrigiert: \($1 ?? $0)\n\n" }.joined()
    }()
    public static func prompt(_ s: String) -> String { head + "Original: \(s)\nKorrigiert:" }

    struct Token { var text: String; var range: NSRange }

    static func tokens(_ s: String) -> [Token] {
        let ns = s as NSString
        var out: [Token] = [], i = 0
        let white = CharacterSet.whitespacesAndNewlines
        while i < ns.length {
            while i < ns.length, let u = UnicodeScalar(ns.character(at: i)), white.contains(u) { i += 1 }
            let a = i
            while i < ns.length {
                if let u = UnicodeScalar(ns.character(at: i)), white.contains(u) { break }
                i += 1
            }
            if i > a { out.append(Token(text: ns.substring(with: NSRange(location: a, length: i - a)), range: NSRange(location: a, length: i - a))) }
        }
        return out
    }

    /// `isMisspelled` bekommt das Wort ohne Satzzeichen, `hasGuess` sagt, ob das System eine nahe Schreibweise kennt.
    public static func fixes(sentence: String, at offset: Int, corrected: String,
                             isMisspelled: (String) -> Bool, hasGuess: (String) -> Bool) -> [Fix] {
        let o = tokens(sentence), n = tokens(corrected)
        guard !o.isEmpty, !n.isEmpty, o.count <= 80 else { return [] }
        let ratio = Double(corrected.count) / Double(max(1, sentence.count))
        guard ratio > 0.6, ratio < 1.7 else { return [] }
        var hunks = diff(o.map(\.text), n.map(\.text))
        let changed = hunks.reduce(0) { $0 + max($1.0.count, $1.1.count) }
        guard Double(changed) <= 0.6 * Double(o.count) + 1 else { return [] } // umgeschrieben statt korrigiert
        // Reine Einfügung oder Löschung um ein Nachbarwort erweitern, damit es etwas zum Anklicken gibt.
        hunks = hunks.map { a, b in
            guard a.isEmpty || b.isEmpty else { return (a, b) }
            if a.lowerBound > 0, b.lowerBound > 0 { return (a.lowerBound - 1..<a.upperBound, b.lowerBound - 1..<b.upperBound) }
            if a.upperBound < o.count, b.upperBound < n.count { return (a.lowerBound..<a.upperBound + 1, b.lowerBound..<b.upperBound + 1) }
            return (a, b)
        }
        let whole = NSRange(location: offset, length: (sentence as NSString).length)
        var out: [Fix] = []
        for (a, b) in hunks where !a.isEmpty && !b.isEmpty {
            let x = o[a].map(\.text), y = n[b].map(\.text)
            let bad = x.map(core).contains { !$0.isEmpty && isMisspelled($0) }
            guard accept(x, y, first: a.lowerBound == 0, last: a.upperBound == o.count, misspelled: bad, hasGuess: hasGuess) else { continue }
            let r = NSRange(location: o[a.lowerBound].range.location, length: NSMaxRange(o[a.upperBound - 1].range) - o[a.lowerBound].range.location)
            out.append(Fix(range: NSRange(location: r.location + offset, length: r.length), original: (sentence as NSString).substring(with: r),
                           replacement: y.joined(separator: " "), isSpelling: bad, sentence: whole))
        }
        return out
    }

    static func core(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.symbols)) }

    static let colloquial: [String: Set<String>] = [
        "hab": ["habe"], "nen": ["einen"], "ne": ["eine", "nein"], "nem": ["einem"], "is": ["ist"], "nich": ["nicht"], "grad": ["gerade"], "nix": ["nichts"],
        "mal": ["einmal"], "was": ["etwas"], "rein": ["herein", "hinein"], "raus": ["heraus", "hinaus"], "drauf": ["darauf"], "ok": ["okay"], "thx": ["thanks"],
        "gonna": ["going"], "wanna": ["want"], "cause": ["because"], "u": ["you"], "np": ["no"], "nö": ["nein"], "moin": ["hallo"], "würd": ["würde"], "könnt": ["könnte"],
        "gehts": ["geht's", "geht"], "gibts": ["gibt's", "gibt"], "wars": ["war's", "war"], "find": ["finde"], "glaub": ["glaube"], "denk": ["denke"], "mach": ["mache"], "komm": ["komme"], "muss": ["müssen"],
    ]
    static let small: Set<String> = Set("als wie das dass den dem des der die ein eine einen einem einer mein dein sein ihr seit seid für vor von is are am was were be has have had do does did a an the of on in at to for too than then there their they're your you're its it's me my this these that those go goes went come came see saw much many".split(separator: " ").map(String.init))

    static func accept(_ x: [String], _ y: [String], first: Bool, last: Bool, misspelled: Bool, hasGuess: (String) -> Bool) -> Bool {
        guard x.count <= 5, y.count <= 5 else { return false }
        let a = x.joined(separator: " "), b = y.joined(separator: " ")
        if a == b || a.contains("@") || a.contains("/") || a.contains("#") { return false }
        if a.filter(\.isNumber) != b.filter(\.isNumber) { return false }
        let ca = core(a), cb = core(b)
        if ca == cb {
            if last { // nur Satzzeichen am Ende: Geschmackssache
                let inner = a.dropLast(a.reversed().prefix { !$0.isLetter && !$0.isNumber }.count)
                let innerB = b.dropLast(b.reversed().prefix { !$0.isLetter && !$0.isNumber }.count)
                if inner == innerB { return false }
            }
            return !b.hasSuffix("!") || a.hasSuffix("!")
        }
        if first, ca.lowercased() == cb.lowercased(), x.count == y.count { return false } // klein geschriebener Chat-Anfang
        for (p, q) in zip(x, y) where colloquial[core(p).lowercased()]?.contains(core(q).lowercased()) == true { return false }
        if expand(ca) == expand(cb) { return false }
        if misspelled {
            // Unbekanntes großgeschriebenes Wort ohne nahe Schreibweise ist wohl ein Name.
            for p in x.map(core) where p.first?.isUppercase == true && !first && !hasGuess(p) && !y.map(core).contains(p) { return false }
            return distance(ca, cb) <= max(3, ca.count / 2)
        }
        if ca.lowercased() == cb.lowercased() { return true } // Groß- und Kleinschreibung
        let d = Double(distance(ca.lowercased(), cb.lowercased())) / Double(max(ca.count, cb.count))
        if d <= 0.5 { return true }
        if x.count == 2, y.count == 1, core(x[1]).lowercased() == core(y[0]).lowercased() || core(x[0]).lowercased() == core(y[0]).lowercased() { return true }
        return x.count == y.count && zip(x, y).allSatisfy { p, q in
            let s = core(p).lowercased(), t = core(q).lowercased()
            return s == t || (small.contains(s) && small.contains(t)) || Double(distance(s, t)) / Double(max(s.count, t.count)) <= 0.5
        }
    }

    private static func expand(_ s: String) -> String {
        var t = s.lowercased().replacingOccurrences(of: "’", with: "'")
        for (p, q) in [("n't", " not"), ("'re", " are"), ("'ve", " have"), ("'ll", " will"), ("'m", " am"), ("'d", " would"), ("it's", "it is"), ("that's", "that is")] { t = t.replacingOccurrences(of: p, with: q) }
        return t.replacingOccurrences(of: "can not", with: "cannot").replacingOccurrences(of: "ca not", with: "cannot").replacingOccurrences(of: "wo not", with: "will not")
    }

    public static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty || y.isEmpty { return max(x.count, y.count) }
        var p2 = [Int](), prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] { cur[j] = min(cur[j], p2[j - 2] + 1) }
            }
            p2 = prev; prev = cur
        }
        return prev[y.count]
    }

    /// Wie wahrscheinlich ein Vertipper ist: doppelte Buchstaben, Umlaute und Dreher wiegen weniger.
    public static func typoCost(_ wrong: String, _ right: String) -> Double {
        let a = wrong.lowercased(), b = right.lowercased()
        func plain(_ s: String) -> String {
            var out = ""
            for c in s.replacingOccurrences(of: "ß", with: "s").folding(options: .diacriticInsensitive, locale: nil) where out.last != c { out.append(c) }
            return out
        }
        let d = Double(distance(a, b))
        if plain(a) == plain(b) { return d * 0.5 }
        return a.sorted() == b.sorted() ? d * 0.8 : d
    }

    /// Geänderte Abschnitte (Bereiche in a und b).
    static func diff(_ a: [String], _ b: [String]) -> [(Range<Int>, Range<Int>)] {
        var t = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                t[i][j] = a[i] == b[j] ? t[i + 1][j + 1] + 1 : max(t[i + 1][j], t[i][j + 1])
            }
        }
        var out: [(Range<Int>, Range<Int>)] = [], i = 0, j = 0, si = 0, sj = 0
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] {
                if si < i || sj < j { out.append((si..<i, sj..<j)) }
                i += 1; j += 1; si = i; sj = j
            } else if j >= b.count || (i < a.count && t[i + 1][j] >= t[i][j + 1]) { i += 1 } else { j += 1 }
        }
        if si < i || sj < j { out.append((si..<i, sj..<j)) }
        // Nebeneinander gleich lange Änderungen einzeln anbieten (Wort für Wort).
        return out.flatMap { r, s -> [(Range<Int>, Range<Int>)] in
            guard r.count == s.count, r.count > 1 else { return [(r, s)] }
            return (0..<r.count).map { (r.lowerBound + $0..<r.lowerBound + $0 + 1, s.lowerBound + $0..<s.lowerBound + $0 + 1) }
        }
    }

    /// Sätze mit Position, auch an Zeilenumbrüchen getrennt.
    public static func sentences(_ text: String) -> [(String, NSRange)] {
        var out: [(String, NSRange)] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byLines]) { _, line, _, _ in
            ns.enumerateSubstrings(in: line, options: [.bySentences]) { sub, r, _, _ in
                guard let sub else { return }
                let lead = sub.prefix { $0.isWhitespace }.utf16.count
                let t = sub.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append((t, NSRange(location: r.location + lead, length: (t as NSString).length))) }
            }
        }
        return out
    }
}
