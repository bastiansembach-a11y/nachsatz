import AppKit
import CryptoKit
import NachsatzCore

// Vergleicht Apples Modell mit einem lokalen llama-server (nur 127.0.0.1).
// Aufruf: Compare apple|llama [port]
let german = [
    "Hallo Frau Berger, vielen Dank für Ihre Nachricht, ich melde mich morgen im Laufe des Tages bei Ihnen.",
    "Leider muss ich unseren Termin am Donnerstag absagen, weil ich den ganzen Tag unterwegs bin.",
    "Kannst du mir bitte kurz Bescheid geben, wenn du zu Hause angekommen bist?",
    "Ich hab gestern Abend noch lange gearbeitet und bin heute deshalb ziemlich müde.",
    "Anbei sende ich Ihnen die Rechnung für den letzten Monat und bitte um zeitnahe Überweisung.",
    "Wir treffen uns am Samstag um acht Uhr vor dem Kino, danach gehen wir noch etwas essen.",
    "Im zweiten Teil der Arbeit wird untersucht, welchen Einfluss das Klima auf die Ernte hat.",
    "Ich würde mich sehr freuen, wenn Sie mich zu einem persönlichen Gespräch einladen.",
    "Das Meeting wurde leider gecancelt, deshalb schicke ich euch das Update per Mail.",
    "Sag mal, hast du eigentlich schon mit deinem Chef über den Urlaub gesprochen?",
]
let english = [
    "Hi Sarah, thanks for getting back to me so quickly, I will send you the documents tomorrow morning.",
    "Unfortunately I have to cancel our meeting on Thursday because I will be travelling all day.",
    "Could you please let me know when you get home so I do not have to worry?",
    "I worked late last night, so I am pretty tired today and will go to bed early.",
    "Please find attached the invoice for last month and let me know if you have any questions.",
    "We are meeting in front of the cinema at eight and going out for dinner afterwards.",
    "The second part of the paper examines how changes in the climate affect the harvest.",
    "I would be very happy to discuss my application with you in a personal interview.",
    "The new version is much faster, but there are still a few bugs we need to fix before the release.",
    "Have you already talked to your boss about taking some time off in the summer?",
]
// Nicht zum Anpassen benutzt.
let germanNew = [
    "Guten Morgen Herr Schulz, könnten Sie mir bitte die Unterlagen für die Sitzung am Montag schicken?",
    "Meine Schwester hat nächste Woche Geburtstag und ich weiß noch nicht, was ich ihr schenken soll.",
    "Der Zug hatte mal wieder eine halbe Stunde Verspätung, deswegen komme ich etwas später ins Büro.",
    "Für die Prüfung muss ich noch drei Kapitel lernen und eine Zusammenfassung schreiben.",
    "Ich bin mir nicht sicher, ob wir das Angebot so annehmen sollten oder lieber noch verhandeln.",
    "Nach dem Update funktioniert die App wieder einwandfrei, vielen Dank für den schnellen Support.",
    "Wollen wir am Wochenende wandern gehen, falls das Wetter einigermaßen mitspielt?",
    "Bitte beachten Sie, dass unser Büro zwischen Weihnachten und Neujahr geschlossen bleibt.",
]
let englishNew = [
    "Good morning, could you please send me the latest version of the presentation before lunch?",
    "My train was delayed again, so I will probably be about half an hour late for work.",
    "I am not sure whether we should accept the offer or try to negotiate a better price.",
    "After the update everything works perfectly again, thank you for your quick support.",
    "Do you want to go hiking this weekend if the weather is nice?",
    "Please note that our office will be closed between Christmas and New Year.",
    "She told me that she is moving to a new apartment at the end of the month.",
    "We need to finish the report by Friday, otherwise the client will not be happy.",
]
let showcase = [
    "Sehr geehrte Damen und Herren,\n\nhiermit bewerbe ich mich um", "Hallo Frau Müller,\n\nvielen Dank für Ihre schnelle Rückm",
    "Ich wollte dich fragen, ob du morgen Abend", "Mit freundlichen Gr", "Ich hab das Meeting gecancelt, weil ",
    "lol ja das war echt ", "Heute war ich im Supermarkt und habe Äpfel, Bana",
    "Hi team,\n\nI wanted to follow up on our meeting yest", "The main reason we decided to change the architecture is that the old one ",
    "Thanks a lot for your help, I really ", "Sounds good, let's ", "Dear Mr. Brown,\n\nI am writing to ",
]

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "apple"
let fresh = args.contains("neu")
let engine = Engine()
let sc = NSSpellChecker.shared
func isWord(_ w: String, _ l: String) -> Bool {
    sc.checkSpelling(of: w, startingAt: 0, language: l, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
}

let client = Llama()
if mode == "llama" { print("Gemma bereit:", await client.waitReady(seconds: 40)) }

func predict(_ text: String, _ lang: String) async -> (String?, Double) {
    let t0 = Date()
    if mode == "llama" {
        let r = try? await client.complete(text, about: "", maxWords: 7)
        return (r ?? nil, Date().timeIntervalSince(t0))
    }
    let raw = (try? await engine.predict(text: text, language: lang, about: "", maxWords: 7)) ?? ""
    let dt = Date().timeIntervalSince(t0)
    return (Joiner.join(text: text, raw: raw, maxWords: 7, isWord: { isWord($0, lang) }), dt)
}

func firstWord(_ s: String) -> String {
    let t = s.drop { $0.isWhitespace }
    return String(t.prefix { $0.isLetter || $0.isNumber || $0 == "'" }).lowercased()
}

if let i = args.firstIndex(of: "korrektur") {
    struct D: Decodable { var gap: [[String]]?; var full: [[String]]?; let fix: [[String]]; let ok: [String] }
    func lang(_ s: String) -> String { Engine.detect(s) ?? "de" }
    func bad(_ w: String, _ l: String) -> Bool { !isWord(w, l) && !isWord(w, l == "de" ? "en" : "de") }
    func guess(_ w: String, _ l: String) -> Bool {
        (sc.guesses(forWordRange: NSRange(location: 0, length: (w as NSString).length), in: w, language: l, inSpellDocumentWithTag: 0) ?? []).contains { Corrector.distance($0, w) <= 2 }
    }
    func run(_ s: String) async -> (String, [Fix], Double) {
        let t0 = Date(), l = lang(s)
        guard let c = (try? await client.correct(s)) ?? nil else { return (s, [], 0) }
        let f = Corrector.fixes(sentence: s, at: 0, corrected: c, isMisspelled: { bad($0, l) }, hasGuess: { guess($0, l) })
        let out = NSMutableString(string: s)
        for x in f.reversed() { out.replaceCharacters(in: x.range, with: x.replacement) }
        return (out as String, f, Date().timeIntervalSince(t0))
    }
    var okAll = german + english + germanNew + englishNew
    for path in args[(i + 1)...] {
        let d = try JSONDecoder().decode(D.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        var hit = 0, marked = 0, ts: [Double] = []
        for f in d.fix {
            let r = await run(f[0]); ts.append(r.2); if r.0 == f[1] { hit += 1 } else { print("   soll: \(f[1]) | ist: \(r.0)") }
            if !r.1.isEmpty { marked += 1 }
        }
        print(String(format: "Fehlersätze: %d/%d exakt, %d markiert, Median %.2fs", hit, d.fix.count, marked, ts.sorted()[ts.count / 2]))
        okAll += d.ok
        if let g = d.gap {
            var h = 0, e = 0, gt: [Double] = []
            for x in g { let t0 = Date(); let o = (try? await client.fillGap(before: x[0], after: x[1])) ?? nil; gt.append(Date().timeIntervalSince(t0)); if o == nil { e += 1 } else if firstWord(o!) == firstWord(x[2]) { h += 1 } }
            print(String(format: "Lücken: %d/%d, ohne Vorschlag %d, Median %.2fs", h, g.count, e, gt.sorted()[gt.count / 2]))
            for x in d.full ?? [] { print("   vollständig: \(x[0])[\(((try? await client.fillGap(before: x[0], after: x[1])) ?? nil) ?? "-")]\(x[1])") }
        }
    }
    var fa = 0
    for s in okAll { let r = await run(s); if !r.1.isEmpty { fa += 1; print("   FEHLALARM: \(s) -> \(r.1.map { "\($0.original)>\($0.replacement)" })") } }
    print("Fehlalarme: \(fa)/\(okAll.count)")
    await client.stop(); exit(0)
}
if args.contains("memory") {
    // Erfundene Notizen, nicht die aus der Simulation.
    let facts = ["Das Angebot von Kessler Bau liegt bei 4200 Euro, ich spreche am Dienstag mit Herrn Kessler.", "Unser neuer Praktikant heißt Emeka und sitzt im Büro neben Svenja.",
        "Im Seminar bei Professor Halvorsen halte ich ein Referat über Gezeitenkraftwerke.", "hey lotte, das konzert von den blauen füchsen ist am 3. märz in der alten gießerei",
        "The migration to Tidewater starts next Wednesday and Rohan will run the first batch.", "Please send the Maple Street contract to Ingrid before noon.",
        "Meine Oma wohnt in Wittelsheim und feiert im Mai ihren achtzigsten Geburtstag.", "Der Beamer im Raum Kopernikus geht nicht, der Hausmeister weiß Bescheid.",
        "For the workshop in Lisbon I booked the hotel Azulejo, check-in is at three.", "Ich habe mich für den Kurs Keramik bei Frau Adebayo angemeldet."]
    let cases: [(String, String)] = [("Herr Kess", "ler"), ("Das Angebot von Kessler Bau liegt bei ", "4200"), ("Unser neuer Praktikant heißt ", "Emeka"), ("Bitte frag Sven", "ja"),
        ("Mein Referat handelt von Gezeiten", "kraftwerken"), ("Das Seminar ist bei Professor Hal", "vorsen"), ("Das Konzert ist in der alten ", "gießerei"), ("Meine Oma wohnt in Witt", "elsheim"),
        ("Der Beamer im Raum Koper", "nikus"), ("Den Kurs Keramik leitet Frau ", "Adebayo"), ("The migration to Tide", "water"), ("The first batch will be run by ", "Rohan"),
        ("Please send the Maple ", "Street"), ("In Lisbon I am staying at the hotel ", "Azulejo")]
    let noise = (german + english + germanNew + englishNew)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cmp-\(UUID()).bin")
    let store = MemoryStore(url: url, days: 14)
    try await store.open(key: SymmetricKey(size: .bits256))
    for (i, f) in facts.enumerated() { await store.add(f, app: "app\(i % 4)", date: Date().addingTimeInterval(-Double(i) * 30000)) }
    for (i, f) in noise.enumerated() { await store.add(f, app: "app\(i % 5)", date: Date().addingTimeInterval(-Double(i) * 9000)) }
    print("Notizen:", await store.all.count)
    func go(_ list: [(String, String)], _ use: Bool, _ show: Bool) async -> (Int, [Double]) {
        var hit = 0, ts: [Double] = []
        for (i, (t, w)) in list.enumerated() {
            let t0 = Date()
            let m = use ? await store.context(for: t, field: "f\(i)") : ""
            let r = (try? await client.complete(t, about: "", memory: m, maxWords: 7)) ?? nil
            ts.append(Date().timeIntervalSince(t0))
            let ok = firstWord(r ?? "") == firstWord(w); if ok { hit += 1 }
            if show { print("   \(ok ? "+" : "-") \(t)▮\(r ?? "-")") }
        }
        return (hit, ts.sorted())
    }
    for use in [false, true] {
        let (h, t) = await go(cases, use, use)
        print(String(format: "Vorwissen nötig, %@ Gedächtnis: %d/%d, Median %.2fs, max %.2fs", use ? "MIT" : "OHNE", h, cases.count, t[t.count / 2], t.last!))
    }
    // Gegenprobe: allgemeine Sätze, Notizen sind nur die Fakten.
    await store.clear()
    for (i, f) in facts.enumerated() { await store.add(f, app: "app\(i % 4)") }
    var general: [(String, String)] = []
    for s in germanNew + englishNew { let w = s.split(separator: " ").map(String.init); for i in stride(from: 4, to: w.count, by: 2) { general.append((w[..<i].joined(separator: " ") + " ", w[i])) } }
    for use in [false, true] {
        let (h, t) = await go(general, use, false)
        print(String(format: "Allgemein, %@ Gedächtnis: %d/%d, Median %.2fs, max %.2fs", use ? "MIT" : "OHNE", h, general.count, t[t.count / 2], t.last!))
    }
    await store.clear()
    for i in 0..<2000 { if i % 400 == 0 { } ; await store.add("Notiz Nummer \(i) handelt von Thema\(i % 97) und Ort\(i % 53) im Projekt.", app: "x") }
    let t0 = Date(); _ = await store.context(for: "Im Projekt geht es um Thema5 und Ort", field: "z")
    print(String(format: "Auswahl aus %d Notizen: %.0f ms", await store.all.count, Date().timeIntervalSince(t0) * 1000))
    await store.clear(); await client.stop(); exit(0)
}

if args.contains("stil") {
    // Erfundene Person mit eigenen Wendungen. Testsätze stehen nicht in den Notizen.
    let corpus = ["Moin zusammen, kurzer Hinweis zur Schicht am Montag.", "Moin zusammen, die Liste hängt jetzt am Brett.", "Moin Finja, kurzer Hinweis wegen der Schlüssel.", "Passt für mich, dann machen wir das so.", "Freitag passt für mich auch besser.",
        "Ich melde mich spätestens nach der Mittagspause.", "Ich melde mich spätestens heute Abend nochmal.", "Besten Dank vorab und schönen Feierabend!", "Besten Dank vorab für die schnelle Hilfe.", "Schönen Feierabend und bis die Tage!", "Wir sehen uns, bis die Tage!",
        "Das ist echt fein geworden, Respekt.", "Der Kuchen war echt fein gestern.", "Cheers for the heads up, I will sort it out.", "Cheers for the heads up about the van.", "I will sort it out before lunch.", "No worries at all, take your time.", "No worries at all, we can do it later.", "Catch you later in the workshop.", "Catch you later and safe travels."]
    let own: [(String, String)] = [("Moin ", "zusammen"), ("Moin zusammen, kurzer ", "Hinweis"), ("Danke euch. Montag passt für ", "mich"), ("Ich melde mich ", "spätestens"), ("Besten Dank ", "vorab"), ("Na dann schönen ", "Feierabend"), ("Alles klar, bis ", "die"), ("Die neue Lampe ist echt ", "fein"),
        ("Cheers for the ", "heads"), ("Okay, I will sort ", "it"), ("No worries ", "at"), ("Right, catch you ", "later"), ("Besten Dank vor", "ab"), ("Dann schönen Fei", "erabend")]
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stil-\(UUID()).bin")
    let store = MemoryStore(url: url, days: 14); try await store.open(key: SymmetricKey(size: .bits256))
    for (i, c) in (german + english).enumerated() { await store.add(c, app: "chat", date: Date().addingTimeInterval(-Double(i) * 9100)) }
    for (i, c) in corpus.enumerated() { await store.add(c, app: "mail", date: Date().addingTimeInterval(-Double(i) * 7000)) }
    // Offene Anfänge: mehrere Fortsetzungen sind richtig, gezählt wird nur die eigene Wortwahl.
    let open: [(String, [String])] = [("Hallo Thea, ich ", ["melde"]), ("Für morgen gilt, ich melde ", ["mich"]), ("Das Essen war ", ["echt", "fein"]), ("Der Termin passt ", ["für"]), ("Dann bis ", ["die"]), ("Vielen Dank, ", ["cheers", "besten"]),
        ("Dein neuer Schrank ist echt ", ["fein"]), ("Besten ", ["dank"]), ("Ich melde mich ", ["spätestens"]), ("Montag passt ", ["für"]), ("Schönen ", ["feierabend"]), ("Ganz ", ["echt"]),
        ("Sure, no ", ["worries"]), ("I will ", ["sort"]), ("Okay, catch ", ["you"]), ("Thanks, I will sort ", ["it"]), ("Cheers ", ["for"]), ("Right, no worries ", ["at"]), ("Great, see you and catch you ", ["later"]), ("It is fine, take your ", ["time"])]
    func copies(_ o: [String]) -> Int { o.filter { x in let w = x.lowercased().split(separator: " "); return w.count >= 4 && corpus.contains { $0.lowercased().contains(w.prefix(4).joined(separator: " ")) } }.count }
    var general: [(String, String)] = []
    for s in germanNew + englishNew { let w = s.split(separator: " ").map(String.init); for i in stride(from: 3, to: w.count, by: 2) { general.append((w[..<i].joined(separator: " ") + " ", w[i])) } }
    func go(_ list: [(String, String)], _ level: Int, _ show: Bool) async -> (Int, [Double], [String]) {
        var hit = 0, ts: [Double] = [], outs: [String] = []
        for (i, (t, w)) in list.enumerated() {
            let t0 = Date()
            let m = await store.context(for: t, field: "f\(i)", app: "mail", level: level)
            let p = await store.preferred(for: t, level: level)
            let r = (try? await client.complete(t, about: "", memory: m, prefer: p, maxWords: 7)) ?? nil
            ts.append(Date().timeIntervalSince(t0)); outs.append(r ?? "-")
            let ok = firstWord(r ?? "") == firstWord(w); if ok { hit += 1 }
            if show { print("   \(ok ? "+" : "-") \(t)▮\(r ?? "-")") }
        }
        return (hit, ts.sorted(), outs)
    }
    var base: [String] = []
    for level in Personalization.levels {
        let a = await go(own, level, false), g = await go(general, level, false)
        if level == 0 { base = g.2 }
        let op = await go(open.map { ($0.0, "") }, level, false)
        let mine = zip(op.2, open).filter { r, o in o.1.contains(firstWord(r)) }.count
        print("   offen: eigene Wortwahl \(mine)/\(open.count), wörtlich abgeschrieben \(copies(op.2 + a.2))/\(open.count + own.count), allgemein abgeschrieben \(copies(g.2))/\(general.count)")
        let changed = zip(base, g.2).filter { $0 != $1 }.count
        print(String(format: "Stufe %d: eigene Wendungen %d/%d, allgemein %d/%d (anders als Stufe 0: %d), Median %.2fs, max %.2fs", level, a.0, own.count, g.0, general.count, changed, g.1[g.1.count / 2], g.1.last!))
    }
    await store.clear(); await client.stop(); exit(0)
}

if args.contains("treffer") {
    // Größerer Testsatz, nicht zum Anpassen benutzt. Rechnet einmal ohne Vorsicht und wertet dann jede Schwelle aus.
    // Aufruf: Compare llama treffer [datei.json] [schnell]
    struct Item: Decodable { let lang: String; let kind: String; let text: String }
    let path = args.first { $0.hasSuffix(".json") } ?? "data/predict.json"
    let items = try JSONDecoder().decode([Item].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let step = args.contains("schnell") ? 3 : 1
    var all: [(item: Item, got: Scored?, cut: Hits.Cut)] = [], ts: [Double] = []
    var total = 0
    for item in items { total += Hits.cuts(item.text, step: step).count }
    for item in items {
        for cut in Hits.cuts(item.text, step: step) {
            let t0 = Date()
            let got = (try? await client.scored(cut.text, about: "", maxWords: 7)) ?? nil
            ts.append(Date().timeIntervalSince(t0))
            all.append((item, got, cut))
            if all.count % 100 == 0 { print("  \(all.count)/\(total)") }
        }
    }
    func pct(_ a: Int, _ b: Int) -> String { b == 0 ? "   -  " : String(format: "%5.1f%%", 100 * Double(a) / Double(b)) }
    func row(_ name: String, _ r: [(got: Scored?, cut: Hits.Cut)], _ t: Double) -> String {
        let x = Hits.tally(r, min: t)
        let shown = Double(max(1, x.shown))
        let rate = Double(x.right) / shown
        let margin: Double = 196 * sqrt(rate * (1 - rate) / shown) // 95 %, in Prozentpunkten
        let words: Double = Double(x.words) / shown
        let saved: Double = Double(x.saved) / Double(max(1, x.cases))
        var line = name.padding(toLength: 16, withPad: " ", startingAt: 0)
        line += pct(x.shown, x.cases)
        line += "   "
        line += pct(x.right, x.shown)
        line += String(format: " ±%4.1f   ", margin)
        line += pct(x.shown - x.right, x.cases)
        line += String(format: "   %5.2f   %6.2f", words, saved)
        return line
    }
    let pairs: [(got: Scored?, cut: Hits.Cut)] = all.map { (got: $0.got, cut: $0.cut) }
    var noProbs = 0, midCount = 0, noneCount = 0
    for x in all {
        if x.cut.mid { midCount += 1 }
        if let g = x.got { if g.sure == nil { noProbs += 1 } } else { noneCount += 1 }
    }
    print("Stellen: \(all.count), davon mitten im Wort \(midCount), ohne Vorschlag \(noneCount), ohne Sicherheitsangaben \(noProbs)")
    if noProbs > 0 { print("  Hinweis: Ohne Sicherheitsangaben greift die Vorsicht nicht. llama.cpp aktualisieren (brew upgrade llama.cpp).") }
    print("")
    let head = "                gezeigt  davon richtig    falsch gezeigt  Wörter richtig  gesparte Zeichen"
    print("Schwelle (Wörter richtig je Vorschlag, gesparte Anschläge je Stelle)")
    print(head)
    let levelNames: [String] = ["aus", "leicht", "mittel", "stark"]
    var levels: [Double: String] = [:]
    for l in Confidence.levels { levels[Confidence.threshold(level: l)] = levelNames[l] }
    let thresholds: [Double] = [0, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.45, 0.6]
    for t in thresholds {
        let name: String = String(format: "%.2f ", t) + (levels[t] ?? "")
        print(row(name, pairs, t))
    }
    let standard: Double = Confidence.threshold(level: Confidence.standard)
    for t in [0, standard] as [Double] {
        print("")
        let title: String = t == 0 ? "Nach Art, ohne Vorsicht" : String(format: "Nach Art, Schwelle %.2f (Standard)", t)
        print(title)
        print(head)
        func part(_ keep: ((item: Item, got: Scored?, cut: Hits.Cut)) -> Bool) -> [(got: Scored?, cut: Hits.Cut)] {
            all.filter(keep).map { (got: $0.got, cut: $0.cut) }
        }
        func key(_ i: Item) -> String { "\(i.lang) \(i.kind)" }
        let kinds: [String] = Set(all.map { key($0.item) }).sorted()
        for kind in kinds { print(row(kind, part { key($0.item) == kind }, t)) }
        print(row("Wortgrenze", part { !$0.cut.mid }, t))
        print(row("mitten im Wort", part { $0.cut.mid }, t))
    }
    print("")
    print("Angegebene Sicherheit des ersten Worts gegen tatsächliche Treffer:")
    for c in Hits.calibration(pairs) where c.n > 0 {
        let range = String(format: "  %.1f–%.1f: %4d Fälle, richtig ", c.range.lowerBound, c.range.upperBound, c.n)
        print(range + pct(c.right, c.n))
    }
    if args.contains("beispiele") {
        print("")
        for x in all.prefix(60) {
            let sure: [Double] = x.got?.sure ?? []
            let p: String = sure.map { String(format: "%.2f", $0) }.joined(separator: " ")
            let before: String = String(x.cut.text.suffix(30)).replacingOccurrences(of: "\n", with: "⏎")
            let got: String = x.got?.text ?? "-"
            let want: String = String(x.cut.want.prefix(30))
            print("  …\(before)▮\(got)  [\(p)]  soll: \(want)")
        }
    }
    let st: [Double] = ts.sorted()
    let median: Double = st[st.count / 2], p90: Double = st[Int(Double(st.count) * 0.9)]
    print(String(format: "\nZeit: Median %.2fs, 90%% unter %.2fs", median, p90))
    await client.stop(); exit(0)
}

if args.contains("strom") {
    // Schrittweise Ausgabe muss am Ende dasselbe liefern wie in einem Stück.
    var same = 0, n = 0, jump = 0, firsts: [Double] = [], totals: [Double] = [], whole: [Double] = []
    // Mit Vorsicht muss die schrittweise Ausgabe ebenfalls dasselbe ergeben, und nie mehr zeigen als am Ende übrig bleibt.
    let least = args.contains("vorsicht") ? Confidence.threshold(level: 2) : 0
    for s in german + english + germanNew + englishNew {
        let w = s.split(separator: " ").map(String.init)
        for i in stride(from: 3, to: w.count, by: 2) {
            for text in [w[..<i].joined(separator: " ") + " ", w[..<i].joined(separator: " ") + " " + w[i].prefix(max(1, w[i].count / 2))] {
                var t0 = Date()
                let a = (try? await client.complete(text, about: "", maxWords: 7, minConfidence: least)) ?? nil
                whole.append(Date().timeIntervalSince(t0))
                final class Box: @unchecked Sendable { var first: Double?; var last = "" ; var bad = false }
                let box = Box(); t0 = Date(); let start = t0
                let b = (try? await client.complete(text, about: "", maxWords: 7, minConfidence: least, onPartial: { p in
                    if box.first == nil { box.first = Date().timeIntervalSince(start) }
                    if !p.hasPrefix(box.last) { box.bad = true }
                    box.last = p; return true
                })) ?? nil
                totals.append(Date().timeIntervalSince(t0)); firsts.append(box.first ?? Date().timeIntervalSince(t0))
                n += 1; if a == b { same += 1 } else { print("   anders: \(text.suffix(30))▮ \(a ?? "-") | \(b ?? "-")") }
                if box.bad || (b.map { !$0.hasPrefix(box.last) } ?? !box.last.isEmpty) { jump += 1; print("   Sprung: \(text.suffix(30))▮ \(box.last) -> \(b ?? "-")") }
            }
        }
    }
    func med(_ x: [Double]) -> Double { x.sorted()[x.count / 2] }
    print(String(format: "gleich %d/%d, Sprünge %d, in einem Stück %.2fs, erstes Wort %.2fs (90%% %.2fs), fertig %.2fs", same, n, jump, med(whole), med(firsts), firsts.sorted()[Int(Double(n) * 0.9)], med(totals)))
    await client.stop(); exit(0)
}

var times: [Double] = []
for (lang, list) in fresh ? [("de", germanNew), ("en", englishNew)] : [("de", german), ("en", english)] {
    var hit = [0, 0], n = [0, 0], none = 0
    for s in list {
        let words = s.split(separator: " ").map(String.init)
        for i in 3..<words.count {
            // 0: Wortgrenze, 1: mitten im Wort (nur längere Wörter)
            var cuts: [(Int, String, String)] = [(0, words[..<i].joined(separator: " ") + " ", words[i])]
            if words[i].count >= 6 {
                let k = words[i].count / 2
                cuts.append((1, words[..<i].joined(separator: " ") + " " + words[i].prefix(k), String(words[i].dropFirst(k))))
            }
            for (kind, text, want) in cuts {
                let l = Engine.language(of: text, fallback: lang)
                let (got, dt) = await predict(text, l)
                times.append(dt); n[kind] += 1
                if let g = got { if firstWord(g) == firstWord(want) { hit[kind] += 1 } } else { none += 1 }
            }
        }
    }
    print(String(format: "%@ %@: nächstes Wort %d/%d (%.0f%%), mitten im Wort %d/%d (%.0f%%), ohne Vorschlag %d",
                 mode, lang, hit[0], n[0], 100 * Double(hit[0]) / Double(n[0]), hit[1], n[1], 100 * Double(hit[1]) / Double(max(1, n[1])), none))
}
let st = times.sorted()
print(String(format: "%@ Zeit: Median %.2fs, 90%% unter %.2fs, n=%d", mode, st[st.count / 2], st[Int(Double(st.count) * 0.9)], st.count))
for s in showcase {
    let l = Engine.language(of: s, fallback: "de")
    let (g, dt) = await predict(s, l)
    print(String(format: "  %.2fs %@ ", dt, l) + "…" + s.suffix(34).replacingOccurrences(of: "\n", with: "⏎") + "▮" + (g ?? "(kein Vorschlag)"))
}
await client.stop()
