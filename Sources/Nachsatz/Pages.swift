import AppKit
import NachsatzCore
import ServiceManagement
import SwiftUI

// MARK: Übersicht

struct HomePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Prefs
    @ObservedObject var stats = Stats.shared

    var body: some View {
        if !model.trusted { PermissionCard().transition(.scale(scale: 0.96).combined(with: .opacity)) }
        if model.rival { Banner(text: "Cotypist läuft auch. Bitte eines von beiden beenden, sonst streiten sie um Tab.") }
        if case .problem(let p) = model.model { Banner(text: p) }
        Hero(model: model).entrance(1)
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 12) {
                Tile(value: stats.words, label: "Wörter heute", icon: "arrow.right.to.line", index: 2)
                Tile(value: stats.chars, label: "Anschläge gespart", icon: "keyboard", index: 3)
                Tile(value: stats.fixes, label: "Fehler korrigiert", icon: "checkmark.seal", index: 4)
                Tile(value: stats.firstMs, label: "bis zum ersten Wort", icon: "bolt", suffix: " ms", index: 5)
            }
        }
        Card("Läuft im Hintergrund", icon: "cpu", index: 6) {
            Row("Sprachmodell", note: modelNote) { StateTag(text: modelText, color: modelColor) }
            Hairline()
            Row("Gedächtnis", note: prefs.memoryOn ? "Verschlüsselt auf diesem Mac, \(prefs.memoryDays) \(prefs.memoryDays == 1 ? "Tag" : "Tage")" : "Merkt sich nichts Neues") {
                StateTag(text: model.memoryProblem ?? (prefs.memoryOn ? "An" : "Aus"), color: model.memoryProblem != nil ? Theme.ember : (prefs.memoryOn ? Theme.good : Theme.ghost))
            }
        }
        Card("Ausprobieren", icon: "pencil.line", index: 7) {
            TextEditor(text: $model.scratch)
                .font(.system(size: 15, design: .serif))
                .scrollContentBackground(.hidden)
                .frame(height: 84)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.ink.opacity(0.05)))
            Text("Schreib hier einen Satz. Tab übernimmt das nächste Wort, Esc blendet aus.").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
    }

    private var modelText: String {
        switch model.model {
        case .ready: "Bereit"
        case .asleep: "Schläft"
        case .loading: model.trusted && prefs.enabled ? "Lädt" : "Aus"
        case .problem: "Fehlt"
        }
    }
    private var modelNote: String {
        prefs.model == "gemma" ? "Gemma 4 E2B, rechnet nur auf diesem Mac" : "Apples Modell, rechnet nur auf diesem Mac"
    }
    private var modelColor: Color {
        switch model.model { case .ready: Theme.good; case .asleep, .loading: Theme.ghost; case .problem: Theme.ember }
    }
}

struct StateTag: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(color.opacity(0.15)))
            .contentTransition(.opacity)
    }
}

struct Banner: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.ember)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(Theme.ember.opacity(0.12)), in: .rect(cornerRadius: 16))
    }
}

private struct Tile: View {
    let value: Int?
    let label: String
    let icon: String
    var suffix = ""
    let index: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.accent).frame(height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(value.map { $0.formatted() + suffix } ?? "–")
                    .font(.system(size: 24, weight: .medium, design: .serif)).monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText(value: Double(value ?? 0)))
                    .animation(Theme.spring, value: value)
                    .lineLimit(1).minimumScaleFactor(0.6)
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .entrance(index)
    }
}

/// Zeigt in einer Schleife, was Nachsatz tut: tippen, grauer Nachsatz, Tab.
@MainActor
final class HeroDemo: ObservableObject {
    @Published var typed = ""
    @Published var ghost = ""
    @Published var tab = false
    private var task: Task<Void, Never>?
    static let lines = [("Vielen Dank für Ihre schnelle Rückm", ["eldung,", " ich", " freue", " mich."]),
                        ("Ich melde mich spätestens ", ["morgen", " Nachmittag."]),
                        ("Sounds good, let’s meet ", ["after", " lunch."]),
                        ("Der Zug hatte Verspätung, deshalb ", ["komme", " ich", " später."])]

    func run(_ on: Bool, calm: Bool) {
        task?.cancel(); task = nil
        if calm || !on {
            if typed.isEmpty || calm { typed = Self.lines[0].0; ghost = Self.lines[0].1.joined() }
            return
        }
        task = Task { [weak self] in
            var i = 0
            while !Task.isCancelled {
                let (start, words) = Self.lines[i % Self.lines.count]; i += 1
                self?.ghost = ""; self?.typed = ""
                try? await Task.sleep(for: .milliseconds(350))
                for c in start {
                    if Task.isCancelled { return }
                    self?.typed.append(c)
                    try? await Task.sleep(for: .milliseconds(c == " " ? 70 : Int.random(in: 35...75)))
                }
                try? await Task.sleep(for: .milliseconds(180))
                for n in 1...words.count {
                    if Task.isCancelled { return }
                    self?.ghost = words[..<n].joined()
                    try? await Task.sleep(for: .milliseconds(90))
                }
                try? await Task.sleep(for: .milliseconds(650))
                for n in 0..<words.count {
                    if Task.isCancelled { return }
                    withAnimation(.spring(response: 0.18, dampingFraction: 0.6)) { self?.tab = true }
                    try? await Task.sleep(for: .milliseconds(110))
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { self?.tab = false }
                    self?.typed += words[n]
                    self?.ghost = words[(n + 1)...].joined()
                    try? await Task.sleep(for: .milliseconds(240))
                }
                try? await Task.sleep(for: .milliseconds(5500))
            }
        }
    }
}

private struct Hero: View {
    @ObservedObject var model: AppModel
    @Local private var demo = HeroDemo() // bewusst nicht beobachtet: nur Zeile und Taste zeichnen neu
    @Environment(\.accessibilityReduceMotion) private var calm

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeroLine(demo: demo)
                .frame(maxWidth: .infinity, minHeight: 68, maxHeight: 68, alignment: .topLeading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Beispiel: Nachsatz schreibt den angefangenen Satz grau weiter, Tab übernimmt.")
            HStack(spacing: 8) {
                HeroTab(demo: demo); Text("nächstes Wort")
                Keycap(text: "⇧⇥").padding(.leading, 10); Text("alles")
                Keycap(text: "esc").padding(.leading, 10); Text("ausblenden")
            }
            .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .onAppear { demo.run(model.visible, calm: calm) }
        .onChange(of: model.visible) { _, v in demo.run(v, calm: calm) }
        .onDisappear { demo.run(false, calm: false) }
    }
}

private struct HeroLine: View {
    @ObservedObject var demo: HeroDemo
    var body: some View {
        let a = Text(demo.typed).foregroundStyle(Theme.ink)
        let caret = Text("\u{2009}|\u{2009}").font(.system(size: 25, weight: .light)).foregroundStyle(Theme.ember)
        let b = Text(demo.ghost).foregroundStyle(Theme.ghost)
        Text("\(a)\(caret)\(b)").font(.system(size: 25, design: .serif))
    }
}

private struct HeroTab: View {
    @ObservedObject var demo: HeroDemo
    var body: some View { Keycap(text: "⇥ Tab", down: demo.tab) }
}

struct PermissionCard: View {
    @Local private var lift = false
    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 72, height: 72)
                    .scaleEffect(lift ? 1.06 : 1)
                    .shadow(color: .black.opacity(lift ? 0.25 : 0.12), radius: lift ? 12 : 5, y: lift ? 6 : 2)
                    .onHover { h in withAnimation(Theme.spring) { lift = h } }
                    .onDrag { NSItemProvider(contentsOf: Bundle.main.bundleURL) ?? NSItemProvider() }
                Text("Ziehen").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Noch ein Schritt: Freigabe").font(.system(size: 17, weight: .medium, design: .serif)).foregroundStyle(Theme.ink)
                Text("Öffne die Systemeinstellungen, entferne alte Nachsatz-Einträge mit „–“ und schalte Nachsatz ein. Fehlt es in der Liste, zieh das Symbol links direkt hinein.")
                    .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Systemeinstellungen öffnen") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
                    QuietButton("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Theme.ember.opacity(0.10)), in: .rect(cornerRadius: 24))
    }
}

// MARK: Vorschläge

struct SuggestPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Prefs
    var body: some View {
        Card("Aussehen", icon: "eye", index: 1) {
            Preview(inline: prefs.inlineText, words: prefs.maxWords)
            Row("Anzeige") { Choice(value: $prefs.inlineText, options: [(true, "Grau im Text"), (false, "Blase darunter")]) }
            Hairline()
            Row("Länge", note: "Kurz ist am schnellsten fertig.") { Choice(value: $prefs.maxWords, options: [(4, "Kurz"), (7, "Mittel"), (12, "Lang")]) }
        }
        Card("Verhalten", icon: "keyboard", index: 2) {
            Row("Tab übernimmt", note: "Umschalt-Tab macht jeweils das andere. Esc blendet aus.") {
                Choice(value: $prefs.tabTakesAll, options: [(false, "Nächstes Wort"), (true, "Alles")])
            }
            Hairline()
            Row("Mitten im Satz ergänzen", note: "Wenn du mit der Schreibmarke in einen Satz gehst.") { Switch(on: $prefs.midFill) }
            Hairline()
            Row("Auch ohne lesbares Textfeld", note: "Für Apps wie Claude. Der Vorschlag steht über der angeklickten Stelle und kennt nur das gerade Getippte.") { Switch(on: $prefs.blind) }
            Hairline()
            Row("Bildschirm als Kontext", note: "Liest beim Schreiben höchstens alle \(Int(ScreenWatch.interval)) Sekunden den sichtbaren Text, damit Vorschläge zur Mail oder zum Chat daneben passen. Nur im Arbeitsspeicher, ausgeschlossene Apps bleiben unsichtbar.") {
                Switch(on: Binding(get: { prefs.screen }, set: { on in
                    prefs.screen = on
                    if on, !model.demo { ScreenWatch.ask(); model.refresh() }
                }))
            }
            if prefs.screen, !model.screenAllowed, !model.demo {
                HStack(spacing: 10) {
                    Text("Dafür braucht Nachsatz die Freigabe „Bildschirmaufnahme“.").font(.system(size: 11)).foregroundStyle(Theme.ember)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    QuietButton("Systemeinstellungen öffnen") { NSWorkspace.shared.open(ScreenWatch.settingsURL) }
                }
                .transition(.opacity)
            }
        }
        Card("Sprache und Modell", icon: "globe", index: 3) {
            Row("Sprache bei kurzen Texten") {
                Picker("", selection: $prefs.language) {
                    Text("Deutsch").tag("de"); Text("Englisch").tag("en"); Text("Französisch").tag("fr"); Text("Spanisch").tag("es"); Text("Italienisch").tag("it")
                }.labelsHidden().fixedSize()
            }
            Hairline()
            Row("Sprachmodell", note: "Beide rechnen auf diesem Mac.") { Choice(value: $prefs.model, options: [("gemma", "Gemma 4 E2B"), ("apple", "Apple")]) }
        }
    }

    private struct Preview: View {
        let inline: Bool
        let words: Int
        private var ghost: String { " " + "morgen Abend Zeit hast und wir zusammen etwas essen gehen wollen, ja?".split(separator: " ").prefix(words).joined(separator: " ") }
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Text("Ich wollte dich fragen, ob du").foregroundStyle(Theme.ink))\(Text(inline ? ghost : "").foregroundStyle(Theme.ghost))")
                    .font(.system(size: 16, design: .serif)).lineLimit(1).truncationMode(.tail)
                    .contentTransition(.interpolate)
                if !inline {
                    Text(ghost.dropFirst() + "  ⇥").font(.system(size: 12)).lineLimit(1)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassEffect(.regular, in: .rect(cornerRadius: 9))
                        .padding(.leading, 90)
                        .transition(.scale(scale: 0.8, anchor: .topLeading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.ink.opacity(0.05)))
            .animation(Theme.spring, value: inline).animation(Theme.spring, value: words)
        }
    }
}

// MARK: Korrektur

struct ProofPage: View {
    @ObservedObject var prefs: Prefs
    @Local private var fixed = false
    var body: some View {
        Card("So sieht es aus", icon: "hand.tap", index: 1) {
            HStack(spacing: 5) {
                Text("Ich habe den Termin"); word
                Text("und komme später.")
            }
            .font(.system(size: 17, design: .serif)).foregroundStyle(Theme.ink)
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.ink.opacity(0.05)))
            Text("Klick auf das rote Wort: genau so funktioniert es in deinen Apps.").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        Card("Prüfen", icon: "text.badge.checkmark", index: 2) {
            Row("Rechtschreibfehler anzeigen", note: "Rot: Ein Klick korrigiert das Wort.") { Switch(on: $prefs.spelling) }
            Hairline()
            Row("Grammatik und Kommas", note: "Blau: Ein Klick korrigiert den Satz. Nur mit Gemma.") { Switch(on: $prefs.grammar) }
                .disabled(!prefs.spelling || prefs.model != "gemma").opacity(prefs.spelling && prefs.model == "gemma" ? 1 : 0.5)
            Hairline()
            Text("⌥-Klick ignoriert ein Wort künftig. Mit ⌘Z machst du eine Korrektur rückgängig.").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        if !prefs.ignoredWords.isEmpty {
            Card("Ignorierte Wörter", icon: "eye.slash", index: 3) {
                Flow(spacing: 8) {
                    ForEach(prefs.ignoredWords, id: \.self) { w in
                        Button { withAnimation(Theme.spring) { prefs.ignoredWords.removeAll { $0 == w } } } label: {
                            HStack(spacing: 6) { Text(w); Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted) }.font(.system(size: 12))
                        }
                        .buttonStyle(.glass).transition(.scale.combined(with: .opacity))
                    }
                }
            }
        }
    }

    private var word: some View {
        Text(fixed ? "vergessen" : "vergesen")
            .contentTransition(.interpolate)
            .overlay(alignment: .bottom) {
                Capsule().fill(.red).frame(height: 2).offset(y: 2).scaleEffect(x: fixed ? 0 : 1, anchor: .leading)
            }
            .onTapGesture {
                withAnimation(Theme.spring) { fixed = true }
                Task { try? await Task.sleep(for: .seconds(2.2)); withAnimation(Theme.spring) { fixed = false } }
            }
            .accessibilityAddTraits(.isButton)
    }
}

/// Bricht Elemente um wie Text.
struct Flow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        place(proposal.width ?? 400, subviews).size
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (v, p) in zip(subviews, place(b.width, subviews).points) { v.place(at: CGPoint(x: b.minX + p.x, y: b.minY + p.y), proposal: .unspecified) }
    }
    private func place(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, out: [CGPoint] = []
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += row + spacing; row = 0 }
            out.append(CGPoint(x: x, y: y)); x += s.width + spacing; row = max(row, s.height)
        }
        return (CGSize(width: width, height: y + row), out)
    }
}

// MARK: Gedächtnis

struct MemoryPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Prefs
    @Local private var asking = false
    private let names = ["Aus", "Leicht", "Mittel", "Stark"]

    var body: some View {
        Card("Persönlicher Stil", icon: "signature", index: 1) {
            HStack(alignment: .firstTextBaseline) {
                Text(names[prefs.style]).font(.system(size: 24, weight: .medium, design: .serif)).foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                Spacer()
                Bars(level: prefs.style)
            }
            Slider(value: Binding(get: { Double(prefs.style) }, set: { v in withAnimation(Theme.spring) { prefs.style = Int(v.rounded()) } }), in: 0...3, step: 1) { EmptyView() }
                .labelsHidden()
            Text("Wie sehr Vorschläge nach deinen eigenen Wörtern und Wendungen klingen. Bei Stark übernimmt Nachsatz öfter ganze frühere Sätze.")
                .font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        .disabled(!prefs.memoryOn || prefs.model != "gemma")
        Card("Über mich", icon: "person.text.rectangle", index: 2) {
            TextEditor(text: $prefs.about).font(.system(size: 13)).scrollContentBackground(.hidden).frame(height: 60).padding(10)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.ink.opacity(0.05)))
            Text("Zum Beispiel Name, Beruf, Duzen oder Siezen. Bleibt auf diesem Mac.").font(.system(size: 11)).foregroundStyle(Theme.muted)
        }
        Card("Merken", icon: "lock.shield", index: 3) {
            Row("Getipptes als Kontext merken", note: "Verschlüsselt auf diesem Mac. Passwortfelder und ausgeschlossene Apps bleiben außen vor. Private Browserfenster werden nicht erkannt.") { Switch(on: $prefs.memoryOn) }
            Hairline()
            Row("Behalten für") {
                Choice(value: $prefs.memoryDays, options: [(1, "1 Tag"), (3, "3"), (5, "5"), (7, "7"), (14, "14 Tage")])
            }
            .onChange(of: prefs.memoryDays) { _, n in if !model.demo { Task { await MemoryHub.shared.store.setDays(n); model.loadNotes() } } }
            if let p = model.memoryProblem { Banner(text: p) }
        }
        Card("\(model.notes.count) \(model.notes.count == 1 ? "Eintrag" : "Einträge")", icon: "tray.full", index: 4) {
            if model.notes.isEmpty {
                Text("Noch nichts gemerkt. Einträge erscheinen, sobald du in einer erlaubten App ein paar Sätze schreibst.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            LazyVStack(spacing: 10) {
                ForEach(model.notes) { n in
                    NoteRow(note: n) { model.delete(n) }
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                }
            }
            if !model.notes.isEmpty {
                QuietButton("Alles löschen …") { asking = true }
                    .confirmationDialog("Alle \(model.notes.count) Einträge löschen?", isPresented: $asking) {
                        Button("Alles löschen", role: .destructive) { model.clearNotes() }
                        Button("Abbrechen", role: .cancel) {}
                    } message: { Text("Das lässt sich nicht rückgängig machen.") }
            }
        }
        .onAppear { model.loadNotes() }
    }

    private struct Bars: View {
        let level: Int
        var body: some View {
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(1...3, id: \.self) { i in
                    Capsule().fill(level >= i ? Theme.accent : Theme.ink.opacity(0.12)).frame(width: 8, height: CGFloat(8 + i * 8))
                        .scaleEffect(y: level >= i ? 1 : 0.55, anchor: .bottom)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: level)
        }
    }

    private struct NoteRow: View {
        let note: Note
        let delete: () -> Void
        @Local private var hover = false
        var body: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: AppModel.icon(note.app)).resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.text).font(.system(size: 12)).foregroundStyle(Theme.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text("\(AppModel.name(note.app)), \(note.date.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 4)
                Button(action: delete) { Image(systemName: "trash").font(.system(size: 11)) }
                    .buttonStyle(.borderless).foregroundStyle(hover ? Theme.ember : Theme.muted).opacity(hover ? 1 : 0.4)
                    .help("Eintrag löschen").accessibilityLabel("Eintrag löschen")
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.ink.opacity(hover ? 0.08 : 0.04)))
            .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        }
    }
}

// MARK: Apps

struct AppsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Prefs
    var body: some View {
        Card("Wo Nachsatz mitschreibt", icon: "square.grid.2x2", index: 1) {
            Text("Links schaltest du Vorschläge ein, rechts, ob sich Nachsatz Getipptes aus der App merkt.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            LazyVStack(spacing: 8) {
                ForEach(model.apps) { a in
                    let on = !prefs.isExcluded(a.id)
                    HStack(spacing: 12) {
                        Image(nsImage: AppModel.icon(a.id)).resizable().frame(width: 30, height: 30).saturation(on ? 1 : 0.1).opacity(on ? 1 : 0.55)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.name).font(.system(size: 13)).foregroundStyle(Theme.ink)
                            Text(!on ? "Ausgeschlossen" : (a.last.map { "Zuletzt: \($0)" } ?? "Noch nicht benutzt")).font(.system(size: 10)).foregroundStyle(Theme.muted).contentTransition(.opacity)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { !prefs.isExcluded(a.id) }, set: { _ in withAnimation(Theme.spring) { prefs.toggleExcluded(a.id) } }))
                            .toggleStyle(.switch).labelsHidden().help("Vorschläge").accessibilityLabel("Vorschläge in \(a.name)")
                        Button { withAnimation(Theme.spring) { prefs.toggleRemember(a.id) } } label: {
                            Image(systemName: prefs.remembers(a.id) ? "brain.head.profile.fill" : "brain.head.profile")
                                .contentTransition(.symbolEffect(.replace)).foregroundStyle(prefs.remembers(a.id) ? Theme.accent : Theme.muted).frame(width: 22)
                        }
                        .buttonStyle(.borderless).disabled(!on || !prefs.memoryOn)
                        .help(prefs.remembers(a.id) ? "Merkt sich Getipptes" : "Merkt sich nichts").accessibilityLabel("Aus \(a.name) merken")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.ink.opacity(0.04)))
                }
            }
        }
    }
}

// MARK: Allgemein

struct GeneralPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs: Prefs
    @ObservedObject var stats = Stats.shared
    var body: some View {
        Card("Nachsatz", icon: "power", index: 1) {
            Row("Vorschläge aktiv") { Switch(on: $prefs.enabled) }
            Hairline()
            Row("Wortzähler in der Menüleiste", note: "Wie viele Wörter Nachsatz für dich vervollständigt hat. Insgesamt bisher: \(stats.total.formatted())") {
                Choice(value: $prefs.menuCount, options: [("today", "Heute"), ("total", "Gesamt"), ("off", "Aus")])
            }
            Hairline()
            Row("Beim Anmelden starten") {
                Switch(on: Binding(get: { model.login }, set: { on in
                    do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch {}
                    model.login = SMAppService.mainApp.status == .enabled
                }))
            }
            .onAppear { if !model.demo { model.login = SMAppService.mainApp.status == .enabled } }
        }
        Card("Freigabe", icon: "hand.raised", index: 2) {
            Row("Bedienungshilfen", note: "Nötig, um Textfelder zu lesen und Tab zu erkennen.") {
                StateTag(text: model.trusted ? "Erteilt" : "Fehlt", color: model.trusted ? Theme.good : Theme.ember)
            }
            if !model.trusted { PermissionCard() }
            if prefs.screen {
                Hairline()
                Row("Bildschirmaufnahme", note: "Nur für „Bildschirm als Kontext“. Das Bild wird sofort in Text umgewandelt und verworfen.") {
                    StateTag(text: model.screenAllowed ? "Erteilt" : "Fehlt", color: model.screenAllowed ? Theme.good : Theme.ember)
                }
            }
        }
        Card("Privatsphäre", icon: "lock", index: 3) {
            Text("Alles bleibt auf diesem Mac. Das Modell läuft lokal und ohne Netz. Protokolle enthalten nur App, Feldart, Längen und Zeiten, nie deinen Text und nie Bildschirminhalte.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}
