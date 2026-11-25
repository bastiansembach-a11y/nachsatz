import AppKit
import Carbon.HIToolbox
import NachsatzCore
import os

/// Verbindet Tastatur, Textfeld, Modell und Anzeige.
@MainActor
final class Controller {
    let engine = Engine()
    let llama = Llama()
    private var typing = TypingSession()
    private var typingPID: pid_t = 0
    private var typingApp = ""
    private var fieldCounter = 0
    private var idle: Task<Void, Never>?
    private var languageByApp: [String: String] = [:]
    let overlay = Overlay()
    let tap = KeyTap()
    private let axQueue = DispatchQueue(label: "nachsatz.ax", qos: .userInteractive)
    /// Eigene Schlange, damit die Fehlersuche Vorschläge nicht aufhält.
    private let proofQueue = DispatchQueue(label: "nachsatz.ax.proof", qos: .userInitiated)
    private var task: Task<Void, Never>?
    /// Rechnet gerade an einem Vorschlag. Weitertippen bricht ihn nicht ab, er wird danach angepasst.
    private var worker: Task<Void, Never>?
    private var workerID = 0
    private var again = false
    /// Bisheriger ganzer Vorschlag, solange er angezeigt und noch verlängert wird.
    private var streamFull: String?
    private var epoch = 0
    private var lastKey = Date.distantPast
    /// Nur im Speicher: seit dem letzten Klick oder Feldwechsel Getipptes, für Apps ohne lesbares Feld.
    private var raw = ""
    private var blind = false
    private var unreadable: Set<pid_t> = []
    private var click: CGPoint?
    private var blindSpot: FieldContext?
    /// Letzte genaue Position, um eine fehlende zu schätzen.
    private var lastExact: (pid: pid_t, before: String, caret: CGRect, field: CGRect)?
    private let log = Logger(subsystem: "local.nachsatz.read", category: "lesen")
    private var outcome: [String: String] = [:]
    private var remaining = ""
    /// Text, der vor der Marke stehen muss, damit der Rest des Vorschlags noch passt.
    private var expected = ""
    private var suggestionPID: pid_t = 0
    /// Der letzte Vorschlag blieb aus, weil das Modell zu unsicher war.
    private var unsure = false
    private var suggestionFront: pid_t = 0
    private var suppressed = false
    /// Vorschlag steht mitten im Satz: als Blase zeigen und immer ganz übernehmen.
    private var mid = false
    lazy var proof = ProofController(queue: proofQueue, llama: llama)

    var frontApp: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }

    /// Hier ruht der Abgriff. Wird in den Systemeinstellungen die Freigabe entzogen, während er läuft,
    /// kann macOS alle Klicks am Mac festhalten.
    static let pausedApps: Set<String> = ["com.apple.systempreferences"]
    var pausedHere: Bool { frontApp?.bundleIdentifier.map { Self.pausedApps.contains($0) } ?? false }
    /// Eine andere App ist nach vorn gekommen.
    var onActivate: (() -> Void)?

    init() {
        tap.onKey = { [weak self] in self?.key($0) ?? false }
        tap.onPointer = { [weak self] in 
            guard let self else { return }
            self.clear(); self.commitTyping(); self.fieldCounter += 1; self.raw = ""; self.unreadable = []; self.blindSpot = nil; self.lastExact = nil
            self.click = CGEvent(source: nil)?.location
            self.proof.hide()
            self.suppressed = false
            self.schedule(after: 450, onlyMid: true)
            self.proof.schedule(after: 600)
        }
        tap.onScroll = { [weak self] in self?.clear(); self?.proof.hide(); self?.proof.schedule(after: 350) }
        tap.onMouse = { [weak self] type, e in
            guard let self, Prefs.shared.enabled, Prefs.shared.spelling else { return false }
            switch type {
            case .leftMouseDown: return self.proof.mouseDown(e)
            case .leftMouseDragged: return self.proof.mouseDragged(e)
            default: return self.proof.mouseUp(e)
            }
        }
        proof.onApply = { [weak self] in self?.clear(); self?.commitTyping(); Stats.shared.didFix() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let pid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                self?.clear(); self?.commitTyping(); self?.fieldCounter += 1; self?.raw = ""; self?.blindSpot = nil; self?.lastExact = nil; self?.click = nil
                self?.proof.hide(); self?.proof.schedule(after: 900)
                self?.wake(pid)
                self?.onActivate?()
            }
        }
        // Fehlersuche: meldet nur Rollen und Längen, nie Text.
        DistributedNotificationCenter.default().addObserver(forName: .init("local.nachsatz.probe"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
    }

    func start() -> Bool {
        guard tap.start() else { return false }
        // Apps, die schon vor der Freigabe liefen, wurden noch nie geweckt.
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular { wake(a.processIdentifier) }
        return true
    }

    /// Nach dem Klick in ein Textfeld: Modell wecken und den Text schon einlesen.
    private func warm(_ c: FieldContext) {
        guard Prefs.shared.model == "gemma", Llama.problem == nil, worker != nil else { return }
        let field = "\(c.pid)-\(fieldCounter)", app = frontApp?.bundleIdentifier ?? ""
        Task { [llama] in
            let mine = await MemoryHub.shared.personal(for: c.before, field: field, app: app)
            await llama.warm(c.before, about: Prefs.shared.about, memory: mine.notes)
        }
    }

    private func wake(_ pid: pid_t?, force: Bool = false) {
        guard let pid, pid != getpid(), let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier?.hasPrefix("com.apple.") != true, !Prefs.shared.isExcluded(app.bundleIdentifier) else { return }
        let url = app.bundleURL
        axQueue.async { AXReader.wake(pid: pid, bundle: url, force: force) }
    }

    private func probe() {
        guard let app = frontApp, !Prefs.shared.isExcluded(app.bundleIdentifier) else { return }
        let pid = app.processIdentifier, id = app.bundleIdentifier ?? "?", hint = AXReader.Hint(click: click, typed: raw)
        axQueue.async { [log] in
            let s = AXReader.probe(frontPID: pid, hint: hint)
            log.notice("probe \(id, privacy: .public): \(s, privacy: .public)")
        }
    }

    /// Letzter Stand je App für Menü und Protokoll, nie Text.
    private func note(_ s: String, detail: String = "") {
        let id = frontApp?.bundleIdentifier ?? "?"
        if outcome[id] != s { outcome[id] = s; log.notice("\(id, privacy: .public): \(s, privacy: .public) \(detail, privacy: .public)") }
        else { log.info("\(id, privacy: .public): \(s, privacy: .public) \(detail, privacy: .public)") }
    }
    func status(of id: String) -> String? { outcome[id] }

    /// Server nur laufen lassen, wenn er gebraucht wird.
    func syncModel(running: Bool) {
        let want = Prefs.shared.enabled && Prefs.shared.model == "gemma" && running
        Task { if want { await llama.start() } else { await llama.stop() } }
    }

    func clear() {
        task?.cancel(); task = nil
        worker?.cancel(); worker = nil; again = false; streamFull = nil
        epoch += 1
        hideSuggestion()
    }

    private func hideSuggestion() {
        if streamFull != nil { // es wird noch daran gerechnet, aber er passt nicht mehr
            worker?.cancel(); worker = nil; again = false
            streamFull = nil
        }
        remaining = ""
        overlay.hide()
    }

    // MARK: Gedächtnis

    /// Übergibt das selbst Getippte ans Gedächtnis und beginnt neu.
    func commitTyping() {
        idle?.cancel(); idle = nil
        let text = typing.text, app = typingApp
        typing = TypingSession()
        guard let text, Prefs.shared.remembers(app) else { return }
        Task { await MemoryHub.shared.add(text, app: app) }
    }

    private func typingKey(pid: pid_t, app: String) {
        if pid != typingPID { commitTyping(); typingPID = pid; typingApp = app }
        idle?.cancel()
        idle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { self?.commitTyping() }
        }
    }

    private func typingRead(_ c: FieldContext) {
        guard Prefs.shared.remembers(typingApp) else { typing = TypingSession(); return }
        typing.read(c.before)
        if let t = typing.text, t.count > 500 { commitTyping(); typing.read(c.before) } // lange Texte in Stücken
    }

    // MARK: Tastatur

    private func key(_ e: CGEvent) -> Bool {
        let prefs = Prefs.shared
        guard prefs.enabled, !IsSecureEventInputEnabled(), let app = frontApp, !prefs.isExcluded(app.bundleIdentifier) else {
            clear(); proof.hide(); raw = ""
            if IsSecureEventInputEnabled() { typing = TypingSession() } else { commitTyping() }
            return false
        }
        proof.hide()
        proof.schedule(after: 900)
        typingKey(pid: app.processIdentifier, app: app.bundleIdentifier ?? "")
        let code = Int(e.getIntegerValueField(.keyboardEventKeycode))
        let flags = e.flags
        let showing = overlay.isVisible && !remaining.isEmpty && suggestionFront == app.processIdentifier
        let command = !flags.isDisjoint(with: [.maskCommand, .maskControl])

        if showing, !command, !flags.contains(.maskAlternate) {
            if code == kVK_Tab {
                accept(all: mid || prefs.tabTakesAll != flags.contains(.maskShift))
                return true
            }
            if code == kVK_Escape { clear(); suppressed = true; return true }
        }
        epoch += 1
        lastKey = Date()
        if command { clear(); commitTyping(); raw = ""; return false }

        let chars = KeyTap.characters(e)
        let printable = chars.unicodeScalars.first.map { $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) } ?? false
        if printable {
            suppressed = false
            typing.typed(chars)
            raw = String((raw + chars).suffix(1200))
            if showing, remaining.hasPrefix(chars) {
                remaining.removeFirst(chars.count)
                expected += chars
                if !remaining.trimmingCharacters(in: .whitespaces).isEmpty { overlay.advance(by: chars, rest: remaining); reposition(); return false }
            }
            hideSuggestion(); schedule(after: 90)
        } else if code == kVK_Delete {
            if flags.contains(.maskAlternate) { typing.uncertain(); raw = "" } else { typing.deleted(); _ = raw.popLast() }
            clear(); if !suppressed { schedule(after: 350) }
        } else {
            clear()
            if code != kVK_Escape { raw = "" }
            if [kVK_Return, kVK_ANSI_KeypadEnter, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
                kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_Tab].contains(code) {
                commitTyping()
                if [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].contains(code), flags.isDisjoint(with: [.maskShift, .maskAlternate]) {
                    schedule(after: 450, onlyMid: true)
                }
            } else if code != kVK_Escape {
                typing.uncertain() // zum Beispiel Akzenttasten
            }
        }
        return false
    }

    private func accept(all: Bool) {
        let piece = all ? remaining : Joiner.nextChunk(of: remaining)
        remaining.removeFirst(piece.count)
        expected += piece
        typing.typed(piece)
        raw = String((raw + piece).suffix(1200))
        Stats.shared.didAccept(piece)
        epoch += 1
        KeyTap.type(piece)
        if remaining.trimmingCharacters(in: .whitespaces).isEmpty {
            let wasMid = mid
            clear()
            if !wasMid { schedule(after: 150) } // mitten im Satz nicht endlos weiter ergänzen
        } else {
            overlay.advance(by: piece, rest: remaining)
            reposition()
        }
    }

    // MARK: Vorschlag

    private func readResult() async -> Result<FieldContext, ReadFailure> {
        guard let pid = frontApp?.processIdentifier else { return .failure(.noFocus) }
        if pid == getpid() { return AXReader.read(frontPID: pid) } // eigenes Fenster: AppKit verlangt den Hauptthread
        let hint = AXReader.Hint(click: click, typed: raw)
        let r = await withCheckedContinuation { c in axQueue.async { c.resume(returning: AXReader.read(frontPID: pid, hint: hint)) } }
        return r.map(refine)
    }

    /// Fehlt die genaue Position einmal, aus der letzten schätzen, statt woanders anzuzeigen.
    private func refine(_ c: FieldContext) -> FieldContext {
        if c.exactCaret { lastExact = (c.pid, c.before, c.caret, c.field); return c }
        guard let l = lastExact, l.pid == c.pid, abs(l.field.minX - c.field.minX) < 3, abs(l.field.width - c.field.width) < 3, c.before.hasPrefix(l.before) else { return c }
        let more = String(c.before.dropFirst(l.before.count))
        guard more.count <= 60, !more.contains(where: \.isNewline) else { return c }
        var out = c
        out.caret = l.caret
        out.caret.origin.x += (more as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: max(9, l.caret.height / 1.2))]).width
        guard out.caret.maxX < c.field.maxX else { return c }
        out.exactCaret = true
        return out
    }

    private func read() async -> FieldContext? {
        if blind { return await blindContext() }
        if case .success(let c) = await readResult() { return c }
        return nil
    }

    private func blindContext() async -> FieldContext? {
        guard let pid = frontApp?.processIdentifier, !raw.isEmpty else { return nil }
        let text = raw
        // Ein fester Platz je Fenster, bis geklickt oder die App gewechselt wird.
        if var spot = blindSpot, spot.pid == pid { spot.before = text; return spot }
        let at = click
        let c = await withCheckedContinuation { c in axQueue.async { c.resume(returning: AXReader.blind(frontPID: pid, typed: text, click: at)) } }
        blindSpot = c
        return c
    }

    /// Liest das Feld und gibt der App Zeit, es überhaupt zu melden. Sonst bleibt nur das Getippte.
    private func readPatiently(onlyMid: Bool) async -> FieldContext? {
        blind = false
        var last: ReadFailure = .noFocus
        let pid = frontApp?.processIdentifier ?? 0
        for wait in unreadable.contains(pid) ? [0] : [0, 200, 500] {
            if wait > 0 { try? await Task.sleep(for: .milliseconds(wait)) }
            if Task.isCancelled { return nil }
            switch await readResult() {
            case .success(let c): unreadable.remove(pid); return c
            case .failure(let f):
                last = f
                guard f.retry, !Task.isCancelled else { break }
                if let app = frontApp {
                    wake(app.processIdentifier)
                    if wait > 0 { let pid = app.processIdentifier, url = app.bundleURL; axQueue.async { AXReader.wakeBrowser(pid: pid, bundle: url, electron: f == .noFocus) } }
                }
            }
            if !last.retry { break }
        }
        guard !Task.isCancelled else { return nil }
        typing = TypingSession() // kein lesbares Feld, zum Beispiel Passwort
        if Prefs.shared.blind, !onlyMid, last.retry, Self.maybeText(last), !IsSecureEventInputEnabled(),
           raw.filter(\.isLetter).count >= 10, raw.split(separator: " ").count >= 3 {
            blind = true
            unreadable.insert(pid) // beim nächsten Mal nicht wieder warten
            if let c = await blindContext() { note("liest nur Getipptes", detail: last.label); return c }
            blind = false
        }
        note(last.label)
        return nil
    }

    /// Listen, Knöpfe und Ähnliches sind sicher keine Texte.
    private static func maybeText(_ f: ReadFailure) -> Bool {
        guard case .notText(let r) = f else { return true }
        return ["", "AXWebArea", "AXGroup", "AXWindow", "AXScrollArea", "AXUnknown", "AXApplication", "AXStaticText", "AXLayoutArea", "AXSplitGroup"].contains(r)
    }

    /// Zeigt den Rest des Vorschlags an der neuen Einfügemarke, sobald die App den Text übernommen hat.
    private func reposition() {
        task?.cancel()
        let pid = suggestionPID
        let tail = String(expected.suffix(40))
        task = Task { [weak self] in
            for i in 0..<14 {
                try? await Task.sleep(for: .milliseconds(i < 8 ? 25 : 60)) // Web-Apps brauchen länger
                guard !Task.isCancelled, let self else { return }
                let c = await self.read()
                guard !Task.isCancelled else { return }
                guard let c else { continue }
                guard c.pid == pid else { return self.clear() }
                if c.before.hasSuffix(tail) {
                    if !self.blind { self.typingRead(c) }
                    return self.overlay.show(self.remaining, at: c, bubble: self.mid)
                }
            }
            if !Task.isCancelled { self?.clear() }
        }
    }

    private func schedule(after ms: Int, onlyMid: Bool = false) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled, let self else { return }
            if self.worker != nil { self.again = true; return }
            self.work(onlyMid: onlyMid)
        }
    }

    private func work(onlyMid: Bool) {
        workerID += 1
        let id = workerID
        again = false
        worker = Task { [weak self] in
            await self?.suggest(onlyMid: onlyMid)
            guard let self, self.workerID == id, !Task.isCancelled else { return }
            self.worker = nil
            // Während des Rechnens weitergetippt und nichts gezeigt: mit dem neuen Text noch einmal.
            if self.again, self.remaining.isEmpty { self.work(onlyMid: false) }
        }
    }

    private func suggest(onlyMid: Bool) async {
        guard Prefs.shared.enabled, !IsSecureEventInputEnabled(), !Prefs.shared.isExcluded(frontApp?.bundleIdentifier) else { return }
        let front = frontApp?.processIdentifier
        guard let c = await readPatiently(onlyMid: onlyMid), !Task.isCancelled,
              !Prefs.shared.isExcluded(NSRunningApplication(processIdentifier: c.pid)?.bundleIdentifier) else { return }
        if !onlyMid, !blind { typingRead(c) }
        let isMid = c.after.prefix(while: { $0 != "\n" }).contains { $0.isLetter || $0.isNumber }
        if onlyMid, !isMid { warm(c); return }
        let began = Date()
        let detail = "weg=\(c.way) rolle=\(c.role) vor=\(c.before.count) nach=\(c.after.count) exakt=\(c.exactCaret) lesen=\(c.millis)ms"
        var stopped = false
        streamFull = nil
        unsure = false
        func offer(_ s: String, final: Bool) async -> Bool {
            let go = await present(s, for: c, isMid: isMid, front: front, began: began, detail: detail, final: final)
            if !go { stopped = true }
            return go
        }
        let s = await suggestion(for: c) { await offer($0, final: false) }
        guard !Task.isCancelled else { return }
        if let s { _ = await offer(s, final: true) }
        else if !stopped {
            if streamFull != nil { streamFull = nil; hideSuggestion() } // war nur eine Wiederholung
            note(unsure ? "gelesen, Modell zu unsicher" : "gelesen, kein Vorschlag", detail: detail)
        }
        if !Task.isCancelled { streamFull = nil }
    }

    /// Zeigt den bisherigen Vorschlag oder verlängert ihn. false = nicht weiterrechnen.
    private func present(_ s: String, for c: FieldContext, isMid: Bool, front: pid_t?, began: Date, detail: String, final: Bool) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let full = streamFull { // steht schon da
            guard s.hasPrefix(full) else { return true }
            let more = String(s.dropFirst(full.count))
            if !more.isEmpty { streamFull = s; remaining += more; overlay.extend(to: remaining) }
            return true
        }
        // Inzwischen weitergetippt? Dann passt der Vorschlag oft noch, nur kürzer.
        for _ in 0..<5 {
            let pause = 0.045 - Date().timeIntervalSince(lastKey) // der App Zeit lassen, die Taste zu verarbeiten
            if pause > 0 { try? await Task.sleep(for: .seconds(pause)) }
            let before = epoch
            guard let now = await read(), !Task.isCancelled, now.pid == c.pid, frontApp?.processIdentifier == front else { return false }
            if epoch != before { continue }
            let left: String
            switch Joiner.match(of: s, asked: c.before, now: now.before) {
            case .rest(let r) where !r.trimmingCharacters(in: .whitespaces).isEmpty && (!isMid || now.before == c.before): left = r
            case .rest where !isMid, .ahead where !isMid:
                if final { note("gelesen, weitergetippt", detail: detail) }
                return !final // das Nächste abwarten
            default:
                note("gelesen, weitergetippt", detail: detail)
                return false
            }
            again = false
            task?.cancel(); task = nil // sonst würde der eben gezeigte Vorschlag gleich ersetzt
            remaining = left
            streamFull = s
            expected = String(now.before.suffix(40))
            suggestionPID = c.pid
            suggestionFront = front ?? c.pid
            mid = isMid
            overlay.show(left, at: now, bubble: isMid)
            Stats.shared.didShow(ms: Int(Date().timeIntervalSince(began) * 1000))
            note(blind ? "Vorschlag gezeigt (nur Getipptes)" : "Vorschlag gezeigt", detail: detail + " erstes=\(Int(Date().timeIntervalSince(began) * 1000))ms sichtbar=\(overlay.isVisible)")
            return true
        }
        return !final
    }

    func suggestion(for c: FieldContext, onPartial: Llama.Partial? = nil) async -> String? {
        let text = c.before
        guard text.filter(\.isLetter).count >= 3 else { return nil }
        if c.after.prefix(while: { $0 != "\n" }).contains(where: { $0.isLetter || $0.isNumber }) {
            guard Prefs.shared.midFill, Prefs.shared.model == "gemma", Llama.problem == nil else { return nil }
            return (try? await llama.fillGap(before: c.before, after: c.after)) ?? nil
        }
        guard c.after.prefix(while: { $0 != "\n" }).allSatisfy({ $0.isWhitespace || ")]}\"“”'’»«*_`.,;:!?".contains($0) }) else { return nil }
        let prefs = Prefs.shared
        // Kurze Texte: zuletzt in dieser App erkannte Sprache, sonst die Standardsprache.
        let app = NSRunningApplication(processIdentifier: c.pid)?.bundleIdentifier ?? ""
        let detected = Engine.detect(text)
        if let detected { languageByApp[app] = detected }
        let lang = detected ?? languageByApp[app] ?? prefs.language

        if prefs.model == "gemma", Llama.problem == nil {
            do {
                let mine = await MemoryHub.shared.personal(for: text, field: "\(c.pid)-\(fieldCounter)", app: typingApp)
                let caution = Confidence.caution(level: prefs.caution)
                let r = try await llama.scored(text, about: prefs.about, memory: mine.notes, prefer: mine.prefer, maxWords: prefs.maxWords,
                                               caution: caution, onPartial: onPartial)
                let s = r.flatMap { Confidence.cut($0, caution, mid: Confidence.isMid(text)) }
                if r != nil, s == nil { unsure = true }
                return Task.isCancelled ? nil : s
            } catch {
                if Task.isCancelled { return nil }
                // Gemma lädt noch oder antwortet nicht: Apples Modell springt ein.
            }
        }
        guard Engine.status == nil,
              let raw = try? await engine.predict(text: text, language: lang, about: prefs.about, maxWords: prefs.maxWords),
              !Task.isCancelled else { return nil }
        if let s = Joiner.join(text: text, raw: raw, maxWords: prefs.maxWords, isWord: { Self.isWord($0, lang) }) { return s }
        return Self.completeWord(text, lang)
    }

    private static func isWord(_ w: String, _ lang: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: lang, wrap: false,
                                            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }

    /// Rückfallebene: angefangenes Wort mit der Rechtschreibprüfung ergänzen.
    private static func completeWord(_ text: String, _ lang: String) -> String? {
        let w = Joiner.partialWord(text)
        guard w.count >= 3, !isWord(w, lang) else { return nil }
        let range = NSRange(location: 0, length: (w as NSString).length)
        let hits = NSSpellChecker.shared.completions(forPartialWordRange: range, in: w, language: lang, inSpellDocumentWithTag: 0)
        guard let best = hits?.first(where: { $0.lowercased().hasPrefix(w.lowercased()) && $0.count > w.count }) else { return nil }
        return String(best.dropFirst(w.count))
    }
}
