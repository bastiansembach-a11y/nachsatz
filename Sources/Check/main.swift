import AppKit
import CryptoKit
import NachsatzCore

let sc = NSSpellChecker.shared
func isWord(_ lang: String) -> (String) -> Bool {
    { w in sc.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound }
}
var failed = 0
func expect(_ text: String, _ raw: String, _ want: String?, lang: String = "de", max: Int = 8) {
    let got = Joiner.join(text: text, raw: raw, maxWords: max, isWord: isWord(lang))
    if got != want { failed += 1; print("FEHLER \(text.debugDescription) + \(raw.debugDescription): \(String(describing: got)) statt \(String(describing: want))") }
}
func expectRest(_ s: String, _ asked: String, _ now: String, _ want: String?) {
    let got = Joiner.rest(of: s, asked: asked, now: now)
    if got != want { failed += 1; print("FEHLER Rest \(s) \(now.suffix(30)): \(String(describing: got)) statt \(String(describing: want))") }
}
expectRest("eldung und", "Rückm", "Rückm", "eldung und")
expectRest("eldung und", "Rückm", "Rückmeld", "ung und")
expectRest("eldung und", "Rückm", "Rückmal", nil)
expectRest("eldung", "Rückm", "Rückmeldung", nil)
expectRest(" Zeit hast", "morgen", "morge", nil)
expectRest(" Zeit hast", "morgen", "morgen Z", "eit hast")
expectRest(" Zeit hast", "ganz", "anderer Text Zeit", nil)
func expectMatch(_ s: String, _ asked: String, _ now: String, _ want: Joiner.Match) {
    let got = Joiner.match(of: s, asked: asked, now: now)
    if got != want { failed += 1; print("FEHLER Passung \(s) \(now): \(got)") }
}
expectMatch("eldung", "Rückm", "Rückmeldung", .ahead)
expectMatch("eldung", "Rückm", "Rückmeldung u", .ahead)
expectMatch("eldung", "Rückm", "Rückmel", .rest("dung"))
expectMatch("eldung", "Rückm", "Rückmal", .no)
expectMatch("eldung", "Rückm", "Rück", .no)
func expectPartial(_ text: String, _ out: String, _ forced: String, _ want: String?) {
    let got = Completion.partial(text: text, output: out, forced: forced, maxWords: 7)
    if got != want { failed += 1; print("FEHLER Teil \(out): \(String(describing: got)) statt \(String(describing: want))") }
}
expectPartial("Ihre Rückm", " Rückmeld", " Rückm", nil)
expectPartial("Ihre Rückm", " Rückmeldung und", " Rückm", "eldung")
expectPartial("ob du morgen ", " Zeit", " ", nil)
expectPartial("ob du morgen ", " Zeit hast", " ", "Zeit")
expectPartial("ob du morgen ", " Zeit hast und ", " ", "Zeit hast und")
expectPartial("ob du morgen", " morgen Zeit hast", " morgen", " Zeit")
if !Completion.complete("Zeit hast?", maxWords: 7) || Completion.complete("ca.", maxWords: 7) || Completion.complete("Zeit hast", maxWords: 7) || !Completion.complete("a b c d e f g", maxWords: 7) { failed += 1; print("FEHLER Ende") }
let longText = (0..<400).map { "w\($0)" }.joined(separator: " ")
expectRest(" Zeit hast", String(longText.suffix(1200)), String((longText + " Ze").suffix(1200)), "it hast")
expect("Ihre schnelle Rückm", "meldung – danke", "eldung – danke")
expect("Ihre schnelle Rückm", "Rückmeldung und", "eldung und")
expect("ob du morgen Abend", "Zeit hast", " Zeit hast")
expect("ob du morgen Abend", "morgen Abend Zeit hast", " Zeit hast")
expect("Äpfel, Bana", "nen und Milch", "nen und Milch")
expect("Kannst du mir bitte ", " helfen", "helfen")
expect("Danke für deine Hilfe.", "Ich melde mich.", " Ich melde mich.")
expect("wir müssen noch kurz", "was einkaufen", " was einkaufen")
expect("I wanted to ask yest", "erday about it", "erday about it", lang: "en")
expect("I wanted to ask yest", "t. Could you", nil, lang: "en")
expect("Hallo ", "\"Welt\"", "Welt")
expect("Hallo ", "eins zwei drei vier", "eins zwei", max: 2)
expect("Hallo ", "eins. Zwei drei", "eins.")
expect("Hallo ", "...", nil)
expect("", "Hallo du", "Hallo du")
func fin(_ t: String, _ o: String, _ want: String?, cut: Bool = false, max: Int = 7) {
    let f = Completion.plan(t)?.forced ?? ""
    let got = Completion.finish(text: t, output: o, forced: f, cut: cut, maxWords: max)
    if got != want { failed += 1; print("FEHLER Gemma \(t.debugDescription) + \(o.debugDescription): \(String(describing: got)) statt \(String(describing: want))") }
}
fin("Ihre schnelle Rückm", " Rückmeldung und", "eldung und")
fin("ob du morgen Abend", " Abend Zeit hast.", " Zeit hast.")
fin("ob du morgen ", " Zeit hast", "Zeit hast")
fin("Mit freundlichen Gr", " Grüßen, 1. Dr", "üßen,")
fin("Hallo ", " du wie geh", "du wie", cut: true)
fin("Ich komme um ", " 8. Mai an", "8. Mai an")
fin("", "Hallo", "Hallo")
fin("Das war toll und das war toll und ", " das war toll", nil)
fin("sagte \"Hal", " \"Hallo", "lo")
if Completion.plan("a \"b\\c")?.grammar.hasPrefix("root ::= \" \\\"b\\\\c\" ") != true { failed += 1; print("FEHLER Grammatik", Completion.plan("a \"b\\c")?.grammar ?? "nil") }
fin("I really ", " appreciate it. I will", "appreciate it.")
fin("Lieferung kommt ", " am 14. Dezember an", "am 14. Dezember an")
fin("Ich frage ", " Dr. Lind heute", "Dr. Lind heute")

// Tipp-Erkennung
func same(_ a: String?, _ b: String?, _ n: String) { if a != b { failed += 1; print("FEHLER \(n): \(String(describing: a)) statt \(String(describing: b))") } }
var ts = TypingSession(); ts.typed("ich"); ts.read("Altes Zitat. ich"); ts.typed(" komme"); same(ts.text, "ich komme", "Tippen hinter Vorhandenem")
ts.read("Altes Zitat. ich komme"); ts.typed("x"); ts.deleted(); same(ts.text, "ich komme", "Löschen im Rest")
ts.deleted(); same(ts.text, nil, "Löschen im Gelesenen bleibt unsicher"); ts.read("Altes Zitat. ich komm"); same(ts.text, "ich komm", "nach neuem Lesen")
ts.read("anderes Feld"); same(ts.text, nil, "Feld gewechselt")
var t2 = TypingSession(); t2.typed("geheim"); same(t2.text, nil, "ohne Lesen nichts")
var t3 = TypingSession(); t3.typed("a"); t3.read("EINGEFÜGTER TEXT a"); t3.typed("b"); same(t3.text, "ab", "Eingefügtes zählt nicht")

// Filter
for bad in ["Meine IBAN ist DE89 3704 0044 0532 0130 00 danke dir", "Das Passwort lautet Sommerwiese okay", "Karte 4111 1111 1111 1111 bitte nehmen", "Der Code ist 482913 bitte eingeben",
            "nimm einfach hK7!pq9Zx als Login bitte", "hier der Schlüssel sk-abc123DEF456ghi789 bitte nicht teilen", "schau mal hier https://example.org/x an bitte"] where !NoteFilter.pieces(bad).isEmpty {
    failed += 1; print("FEHLER Filter lässt durch:", bad)
}
for good in ["Wir treffen uns am 14. Dezember um 18:30 am Nordring.", "Die Hausarbeit hat 12 Seiten und 3 Kapitel.", "Please call Priya about the Brightwell report tomorrow.", "Wir nutzen macOS und GPT-4 im Projekt Seerose.", "Die Donaudampfschifffahrtsgesellschaft hat uns heute geschrieben."] where NoteFilter.pieces(good).isEmpty {
    failed += 1; print("FEHLER Filter verwirft:", good)
}
same(NoteFilter.pieces("Wir sehen uns am Freitag im Büro. Mein Passwort ist Hund. Bring bitte die Pläne für Altenried mit.").joined(), "Wir sehen uns am Freitag im Büro. Bring bitte die Pläne für Altenried mit.", "nur heikler Satz raus")
if !NoteFilter.pieces("ja ok").isEmpty { failed += 1; print("FEHLER kurz") }

// Speicher
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("nachsatz-\(UUID()).bin")
let k = SymmetricKey(size: .bits256)
let m1 = MemoryStore(url: tmp, days: 5)
await m1.add("Das darf ohne Schlüssel nicht gespeichert werden.", app: "a")
if FileManager.default.fileExists(atPath: tmp.path) { failed += 1; print("FEHLER ohne Schlüssel gespeichert") }
try await m1.open(key: k)
await m1.add("Die Hausarbeit betreut Dr. Lindqvist an der Uni.", app: "a")
await m1.add("Ein uralter Satz, der längst weg sein muss.", app: "a", date: Date().addingTimeInterval(-6 * 86400))
await m1.add("Wir gehen am Samstag wieder bouldern am Nordring.", app: "b")
let onDisk = try Data(contentsOf: tmp)
if onDisk.range(of: Data("Lindqvist".utf8)) != nil { failed += 1; print("FEHLER Klartext auf der Platte") }
if (try FileManager.default.attributesOfItem(atPath: tmp.path)[.posixPermissions] as? Int) != 0o600 { failed += 1; print("FEHLER Dateirechte") }
let m2 = MemoryStore(url: tmp, days: 5); try await m2.open(key: k)
same(await m2.all.map(\.text).sorted().joined(separator: "|"), "Die Hausarbeit betreut Dr. Lindqvist an der Uni.|Wir gehen am Samstag wieder bouldern am Nordring.", "Laden und Verfall")
same(await m2.context(for: "Meine Hausarbeit betreut Dr. Lin", field: "f"), "Die Hausarbeit betreut Dr. Lindqvist an der Uni.", "Auswahl")
same(await m2.context(for: "Der Zug hatte wieder Verspätung und ", field: "g"), "", "nichts Passendes")
let m3 = MemoryStore(url: tmp)
do { try await m3.open(key: SymmetricKey(size: .bits256)); failed += 1; print("FEHLER falscher Schlüssel") } catch {}
await m2.prune(now: Date().addingTimeInterval(6 * 86400)); same("\(await m2.all.count)", "0", "alles verfallen")
await m1.clear(); if FileManager.default.fileExists(atPath: tmp.path) { failed += 1; print("FEHLER Löschen") }
// Persönlicher Stil
let tmp2 = FileManager.default.temporaryDirectory.appendingPathComponent("nachsatz-\(UUID()).bin")
let sm = MemoryStore(url: tmp2); try await sm.open(key: k)
for t in ["Moin zusammen, kurzer Hinweis zum Termin morgen.", "Moin zusammen, kurzer Hinweis zur neuen Liste.", "Passt für mich, sag einfach kurz Bescheid.", "Das passt für mich auch am Freitag gut."] { await sm.add(t, app: "a") }
let pf = await sm.preferred(for: "Moin ", level: 2)
same(pf.first?.word, "zusammen", "üblicher Folgewort")
same("\((await sm.preferred(for: "Moin ", level: 0)).count)", "0", "Stufe 0 aus")
same(await sm.context(for: "Hinweis zur Liste", field: "x", level: 0), "", "Stufe 0 ohne Notizen")
let b1 = await sm.preferred(for: "Moin ", level: 1).first?.bias ?? 0, bMax = await sm.preferred(for: "Moin ", level: 3).first?.bias ?? 0
if !(bMax > b1 && b1 > 0) { failed += 1; print("FEHLER Stärke", b1, bMax) }
same((await sm.preferred(for: "Moin zus", level: 3)).first?.word, "zusammen", "Folgewort mitten im Wort")
same("\((await sm.preferred(for: "Der Zug ", level: 3)).count)", "0", "nichts Übliches")
await sm.clear()
// Lücken
func gap(_ l: String, _ r: String, _ raw: String, _ want: String?) { same(Gap.finish(raw, left: l, right: r), want, "Lücke \(l)|\(r)") }
gap("Wir fahren ", "nach Berlin.", " mit dem Zug", "mit dem Zug ")
gap("Wir fahren", " nach Berlin.", "mit dem Zug", " mit dem Zug")
gap("She bought a ", "new car.", "brand new", "brand ")
gap("Das Essen war ", "sehr lecker.", "so", nil)
gap("Ich habe ", "gearbeitet.", "habe", nil)
gap("Verspätung habe ich, ", "deshalb komme ich.", "leider.", "leider ")
same("\(Gap.context(before: "Ich habe Wör", after: "ter hier.") == nil)", "true", "Marke im Wort")
same("\(Gap.context(before: "Das ist gut", after: ". Und jetzt") == nil)", "true", "vor Satzende")
same("\(Gap.context(before: "Das ist ", after: "") == nil)", "true", "Zeilenende")

// Korrekturen
let wrong: Set = ["Kanst", "vergesen", "schiken", "Zablotny", "Zeitt"]
func fx(_ a: String, _ b: String, _ want: [String]) {
    let got = Corrector.fixes(sentence: a, at: 10, corrected: b, isMisspelled: { wrong.contains($0) }, hasGuess: { $0 != "Zablotny" })
    let t = got.map { "\($0.original)>\($0.replacement)" }
    if t != want || got.contains(where: { f in (String(repeating: "x", count: 10) + a as NSString).substring(with: f.range) != f.original }) { failed += 1; print("FEHLER Korrektur \(a): \(t) statt \(want)") }
}
fx("Kanst du mir helfen?", "Kannst du mir helfen?", ["Kanst>Kannst"])
fx("Ich glaube das er kommt.", "Ich glaube, dass er kommt.", ["glaube>glaube,", "das>dass"])
fx("Ich hab leider keine Zeit.", "Ich habe leider keine Zeit.", [])
fx("ok bis später", "Ok bis später.", [])
fx("They're late again.", "They are late again.", [])
fx("Er ist größer wie ich.", "Er ist größer als ich.", ["wie>als"])
fx("Frau Zablotny kommt.", "Frau Zablotnik kommt.", [])
fx("Das Haus ist alt und schön.", "Dieses Gebäude wirkt sehr alt.", [])
fx("She is more taller than me.", "She is taller than me.", ["is more>is"])
fx("Wir kommen um 8 Uhr an.", "Wir kommen um 9 Uhr an.", [])
fx("Emoji 😀 Kanst du?", "Emoji 😀 Kannst du?", ["Kanst>Kannst"])
same(Corrector.sentences("Hallo Tom.  Wie geht's?\nGut").map { "\($0.0)@\($0.1.location)" }.joined(separator: "|"), "Hallo Tom.@0|Wie geht's?@12|Gut@24", "Sätze")
same("\(Corrector.distance("schiken", "schicken"))\(Corrector.distance("adn", "and"))", "11", "Abstand")
if !(Corrector.typoCost("vergesen", "vergessen") < Corrector.typoCost("vergesen", "vergehen")) || !(Corrector.typoCost("Konten", "Könten") < 1) { failed += 1; print("FEHLER typoCost") }
assert(Joiner.nextChunk(of: " Zeit hast") == " Zeit" && Joiner.nextChunk(of: "eldung und") == "eldung")

// Sicherheit je Wort
func near(_ a: [Double]?, _ b: [Double], _ n: String) {
    guard let a, a.count == b.count, zip(a, b).allSatisfy({ abs($0 - $1) < 0.001 }) else { failed += 1; print("FEHLER Sicherheit \(n): \(String(describing: a)) statt \(b)"); return }
}
func tok(_ id: Int, _ s: String, _ p: Double, _ top: [(Int, String, Double)] = []) -> TokenProb {
    TokenProb(id: id, bytes: Array(s.utf8), logprob: log(p), top: top.map { .init(id: $0.0, bytes: Array($0.1.utf8), logprob: log($0.2)) })
}
// Wortgrenze: Das erzwungene Leerzeichen schließt Tokens ohne Leerzeichen aus.
let zt = [tok(1, " Zeit", 0.5, [(1, " Zeit", 0.5), (2, "Zeit", 0.3), (3, " Lust", 0.1)]), tok(4, " hast", 0.8)]
near(Confidence.wordProbs(output: " Zeit hast", forced: " ", suggestion: "Zeit hast", tokens: zt), [0.5 / 0.6, 0.5 / 0.6 * 0.8], "Wortgrenze")
// Mitten im Wort: Tokens, die ganz im Getippten liegen, zählen nicht, das angebrochene nur unter passenden.
let rt = [tok(10, " Rück", 0.02, [(11, " Antwort", 0.5), (10, " Rück", 0.02)]),
          tok(12, "meldung", 0.6, [(12, "meldung", 0.6), (13, "mel", 0.1), (14, "x", 0.2)]), tok(15, " und", 0.5)]
near(Confidence.wordProbs(output: " Rückmeldung und", forced: " Rückm", suggestion: "eldung und", tokens: rt), [0.6 / 0.7, 0.6 / 0.7 * 0.5], "mitten im Wort")
// Bevorzugung verschiebt die Wahrscheinlichkeit
let e2: Double = exp(2.0)
let biased: Double = 0.1 * e2 / (1 + 0.1 * (e2 - 1))
near(Confidence.wordProbs(output: " Moin", forced: "", suggestion: " Moin", tokens: [tok(5, " Moin", 0.1, [(5, " Moin", 0.1)])], biases: [5: 2]),
     [biased], "Bevorzugung")
same("\(Confidence.wordProbs(output: " Zeit hast", forced: " ", suggestion: "Zeit hast", tokens: [tok(1, " Zeit", 0.5)]) == nil)", "true", "Tokens zu kurz")
same("\(Confidence.wordProbs(output: " Zeit hast", forced: " ", suggestion: "Zeit hast", tokens: [tok(1, " Zeug", 0.5), tok(4, " hast", 0.8)]) == nil)", "true", "Tokens passen nicht")
same("\(Confidence.wordProbs(output: " Zeit", forced: " ", suggestion: "Lust", tokens: zt) == nil)", "true", "Vorschlag passt nicht")
let parsed = Confidence.tokens(try! JSONSerialization.jsonObject(with: Data(#"[{"id":7,"token":" Zeit","bytes":[32,90,101,105,116],"logprob":-0.5,"top_logprobs":[{"id":7,"token":" Zeit","bytes":[32,90,101,105,116],"logprob":-0.5},{"id":8,"token":" Lust","logprob":-2}]}]"#.utf8)))
same(parsed.map { "\($0[0].id) \(String(decoding: $0[0].bytes, as: UTF8.self)) \($0[0].logprob) \($0[0].top.count) \(String(decoding: $0[0].top[1].bytes, as: UTF8.self))" }, "7  Zeit -0.5 2  Lust", "Antwort lesen")
same("\(Confidence.tokens([["content": "x", "probs": []]]) == nil)", "true", "altes Format")
let sc3 = Scored(text: "Zeit hast du", sure: [0.8, 0.5, 0.2])
same(Confidence.cut(sc3, min: 0.3), "Zeit hast", "kürzen")
same(Confidence.cut(sc3, min: 0.9), nil, "zu unsicher")
same(Confidence.cut(sc3, min: 0.1), "Zeit hast du", "alles sicher")
same(Confidence.cut(sc3, min: 0), "Zeit hast du", "Vorsicht aus")
same(Confidence.cut(Scored(text: "Zeit hast", sure: nil), min: 0.5), "Zeit hast", "ohne Angaben")
same(Confidence.cut(Scored(text: " und – bald", sure: [0.9, 0.8, 0.1]), min: 0.3), " und", "Rest sauber")

// Messung
let hc = Hits.cuts("eins zwei drei vier fünf sechsten")
same(hc.map { "\($0.text)|\($0.want)|\($0.mid)" }.joined(separator: " / "), "eins zwei drei |vier fünf sechsten|false / eins zwei drei vier |fünf sechsten|false / eins zwei drei vier fünf |sechsten|false / eins zwei drei vier fünf sech|sten|true", "Schnitte")
same("\(Hits.cuts("a b c d e f g h", step: 3).count)", "2", "Schnitte jede dritte")
same(Hits.cuts("Hallo Frau Weber,\n\nvielen Dank für").map(\.want).joined(separator: "|"), "vielen Dank für|len Dank für|Dank für|für", "Schnitte über Zeilen")
let hm = Hits.match("Zeit hast du", want: "Zeit hast, oder?")
same("\(hm.words) \(hm.chars)", "2 9", "Treffer zählen")
same("\(Hits.match("eldung und", want: "eldung, danke").words)", "1", "Treffer mitten im Wort")
let ht = Hits.tally([(Scored(text: "Zeit hast", sure: [0.9, 0.2]), hc[0]), (Scored(text: "vier fünf", sure: [0.9, 0.8]), hc[0]), (nil, hc[0])], min: 0.5)
same("\(ht.cases) \(ht.shown) \(ht.right) \(ht.words) \(ht.saved)", "3 2 1 2 7", "Auswertung")
print(failed == 0 ? "Textlogik: alle Prüfungen bestanden" : "Textlogik: \(failed) fehlgeschlagen")

// Nur Textlogik, ohne Modell (für die automatische Prüfung).
if CommandLine.arguments.contains("--logic") { exit(failed == 0 ? 0 : 1) }
if let s = Engine.status { print("Apples Modell übersprungen: \(s)"); exit(failed == 0 ? 0 : 1) }

let samples = [
    "Hallo Frau Müller,\n\nvielen Dank für Ihre schnelle ", "Hallo Frau Müller,\n\nvielen Dank für Ihre schnelle Rückm",
    "Ich wollte dich fragen, ob du morgen Abend", "Hi team,\n\nI wanted to follow up on our meeting yest",
    "Sehr geehrte Damen und Herren,\n\nhiermit bewerbe ich mich um", "Kannst du mir bitte ", "Wie geht es ",
    "The main reason we decided to change the architecture is that the old one ",
    "Heute war ich im Supermarkt und habe Äpfel, Bana", "Mit freundlichen Gr",
    "Danke für die Einladung! Leider kann ich am Samstag nicht kommen, weil ich ", "lol ja das war echt ",
    "Gestern habe ich mit Anna telefoniert und sie hat mir erz", "Bonjour, je voudrais savoir si vous ",
]
let engine = Engine()
var times: [Double] = []
for s in samples {
    let lang = Engine.language(of: s, fallback: "de")
    let t0 = Date()
    do {
        let raw = try await engine.predict(text: s, language: lang, about: "", maxWords: 7)
        let dt = Date().timeIntervalSince(t0); times.append(dt)
        let j = Joiner.join(text: s, raw: raw, maxWords: 7, isWord: isWord(lang))
        print(String(format: "%.2fs %@", dt, lang), "…" + s.suffix(28).replacingOccurrences(of: "\n", with: "⏎") + "▮" + (j ?? "(kein Vorschlag, roh: \(raw))"))
    } catch { print("ERR", s, error) }
    try? await Task.sleep(for: .milliseconds(250))
}
if !times.isEmpty { print(String(format: "Median %.2fs", times.sorted()[times.count / 2])) }
exit(failed == 0 ? 0 : 1)
