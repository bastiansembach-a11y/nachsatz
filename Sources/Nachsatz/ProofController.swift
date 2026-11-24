import AppKit
import ApplicationServices
import NachsatzCore

/// Findet Fehler im fokussierten Feld, unterstreicht sie und korrigiert beim Klick.
@MainActor
final class ProofController {
    struct Mark { var fix: Fix; var rect: CGRect; var base: Int } // rect in AX-Koordinaten

    private let axQueue: DispatchQueue
    private let llama: Llama
    private let view = MarkOverlay()
    private let hover = HoverBubble()
    private var task: Task<Void, Never>?
    private var marks: [Mark] = []
    private var element: AXUIElement?
    private var textKey = ""
    private var cache: [String: String] = [:] // Satz -> Korrektur
    private var watch: Timer?
    private var moveMonitor: Any?
    private var pressed: (mark: Mark, at: CGPoint, alt: Bool)?
    /// Wird vor und nach einer Korrektur gerufen.
    var onApply: (() -> Void)?

    init(queue: DispatchQueue, llama: Llama) { axQueue = queue; self.llama = llama }

    // MARK: Prüfen

    func hide() {
        task?.cancel(); task = nil
        clearMarks()
    }

    private func clearMarks() {
        guard !marks.isEmpty else { return }
        marks = []; element = nil; textKey = ""
        view.hide(); hover.hide()
        watch?.invalidate(); watch = nil
        if let m = moveMonitor { NSEvent.removeMonitor(m); moveMonitor = nil }
    }

    func schedule(after ms: Int) {
        task?.cancel()
        guard Prefs.shared.enabled, Prefs.shared.spelling else { return hide() }
        task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            if !Task.isCancelled { await self?.check() }
        }
    }

    private func check() async {
        guard let app = NSWorkspace.shared.frontmostApplication, !Prefs.shared.isExcluded(app.bundleIdentifier) else { return hide() }
        let pid = app.processIdentifier
        guard pid != getpid() else { return hide() } // eigene Fenster nie von hier aus verändern
        guard let f = await onAX({ AXReader.readText(frontPID: pid) }), !Task.isCancelled else { if !Task.isCancelled { clearMarks() }; return }
        await check(f)
    }

    func check(_ f: AXReader.FieldText) async {
        let ignored = Set(Prefs.shared.ignoredWords.map { $0.lowercased() })
        func learned(_ w: String) -> Bool { ignored.contains(w.lowercased()) }

        var fixes: [Fix] = []
        let all = Corrector.sentences(f.text)
        // Nächste Sätze zur Marke zuerst, höchstens zwölf.
        let near = all.sorted { abs($0.1.location - f.caret) < abs($1.1.location - f.caret) }.prefix(12)
        let fallback = Prefs.shared.language
        for (s, r) in near where spellable(s) {
            let lang = Engine.detect(s) ?? Engine.detect(f.text) ?? fallback
            fixes += spelling(s, r, lang, caret: f.caret, learned: learned)
        }
        await show(fixes, f)
        guard !Task.isCancelled, Prefs.shared.grammar, Prefs.shared.model == "gemma", Llama.problem == nil else { return }

        for (s, r) in near where s.split(separator: " ").count >= 3 && s.count <= 300 && spellable(s) {
            // Der Satz, an dessen Ende gerade getippt wird, ist noch nicht fertig.
            if f.caret >= r.location, f.caret <= NSMaxRange(r) + 1, f.caret >= NSMaxRange(r) - 1, !".!?".contains(s.last!) { continue }
            let c: String
            if let hit = cache[s] { c = hit } else {
                guard let got = try? await llama.correct(s), !Task.isCancelled else { if Task.isCancelled { return }; continue }
                if cache.count > 400 { cache = [:] }
                cache[s] = got; c = got
            }
            let lang = Engine.detect(s) ?? Engine.detect(f.text) ?? fallback
            let g = Corrector.fixes(sentence: s, at: r.location, corrected: c,
                                    isMisspelled: { Self.misspelled($0, lang) && !learned($0) }, hasGuess: { Self.guess($0, lang) != nil })
                .filter { x in !learned(x.original.trimmingCharacters(in: .punctuationCharacters)) }
            guard !g.isEmpty else { continue }
            // Gemma kennt den Zusammenhang, ersetzt also den einfachen Vorschlag an derselben Stelle.
            fixes.removeAll { x in g.contains { NSIntersectionRange($0.range, x.range).length > 0 } }
            fixes += g
            await show(fixes, f)
            if Task.isCancelled { return }
        }
    }

    private func spellable(_ s: String) -> Bool { !s.contains("://") && !s.contains("```") }

    private func spelling(_ s: String, _ r: NSRange, _ lang: String, caret: Int, learned: (String) -> Bool) -> [Fix] {
        let ns = s as NSString
        var out: [Fix] = [], at = 0
        while at < ns.length {
            let m = NSSpellChecker.shared.checkSpelling(of: s, startingAt: at, language: lang, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
            guard m.location != NSNotFound, m.length > 0 else { break }
            at = NSMaxRange(m)
            let w = ns.substring(with: m)
            let abs = NSRange(location: m.location + r.location, length: m.length)
            if caret >= abs.location, caret <= NSMaxRange(abs) { continue } // wird gerade getippt
            guard w.count >= 3, !learned(w), !w.contains(where: \.isNumber), w.uppercased() != w, Self.misspelled(w, lang),
                  let g = Self.guess(w, lang) else { continue }
            out.append(Fix(range: abs, original: w, replacement: g, isSpelling: true, sentence: r))
        }
        return out
    }

    /// Falsch nur, wenn das Wort weder in der Satzsprache noch in Deutsch oder Englisch bekannt ist.
    static func misspelled(_ w: String, _ lang: String) -> Bool {
        Set([lang, "de", "en"]).allSatisfy { l in
            NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0, language: l, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil).location != NSNotFound
        }
    }

    static func guess(_ w: String, _ lang: String) -> String? {
        let r = NSRange(location: 0, length: (w as NSString).length)
        let list = NSSpellChecker.shared.guesses(forWordRange: r, in: w, language: lang, inSpellDocumentWithTag: 0) ?? []
        let limit = w.count <= 4 ? 1 : 2
        return list.filter { !$0.contains(" ") && Corrector.distance($0.lowercased(), w.lowercased()) <= limit }
            .min { Corrector.typoCost(w, $0) < Corrector.typoCost(w, $1) }
    }

    // MARK: Anzeigen

    private func show(_ fixes: [Fix], _ f: AXReader.FieldText) async {
        guard !fixes.isEmpty else { if !Task.isCancelled { clearMarks() }; return }
        let placed: [Mark] = await onAX {
            fixes.prefix(40).compactMap { x in
                guard let r = AXReader.rect(f.element, f.base + x.range.location, x.range.length),
                      r.width > 2, r.height > 4, r.height < 80, f.frame.isEmpty || f.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.midX, y: r.midY)) else { return nil }
                return Mark(fix: x, rect: r, base: f.base)
            }
        }
        guard !Task.isCancelled else { return }
        guard !placed.isEmpty else { return clearMarks() }
        marks = placed; element = f.element; textKey = f.text
        view.show(placed.map { ($0.rect, $0.fix.isSpelling) })
        startWatching()
    }

    /// Verschiebt sich das Feld (Fenster bewegt, Text geändert), verschwinden die Striche sofort.
    private func startWatching() {
        if watch == nil {
            watch = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.verify() }
            }
        }
        if moveMonitor == nil {
            moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                MainActor.assumeIsolated { self?.hovered() }
            }
        }
    }

    private func verify() {
        guard let el = element, let first = marks.first else { return }
        let last = marks.last!
        Task {
            let ok: Bool = await onAX {
                [first, last].allSatisfy { m in
                    guard let r = AXReader.rect(el, m.base + m.fix.range.location, m.fix.range.length) else { return false }
                    return abs(r.minX - m.rect.minX) < 2 && abs(r.minY - m.rect.minY) < 2
                        && AXReader.text(el, m.base + m.fix.range.location, m.fix.range.length) == m.fix.original
                }
            }
            if !ok, self.element == el { self.hide(); self.schedule(after: 200) }
        }
    }

    private func mark(at p: CGPoint) -> Mark? { marks.first { $0.rect.insetBy(dx: -1, dy: -1).contains(p) } }

    private func hovered() {
        guard let e = CGEvent(source: nil), let m = mark(at: e.location) else { return hover.hide() }
        hover.show(m.fix.isSpelling ? m.fix.replacement : whole(m)?.2 ?? m.fix.replacement, at: m.rect)
    }

    // MARK: Klick

    /// true = Klick schlucken.
    func mouseDown(_ e: CGEvent) -> Bool {
        pressed = nil
        let other: CGEventFlags = [.maskCommand, .maskControl, .maskShift]
        guard e.flags.isDisjoint(with: other), let m = mark(at: e.location) else { return false }
        pressed = (m, e.location, e.flags.contains(.maskAlternate))
        return true
    }

    /// Wird doch gezogen, war es eine Markierung: den Klick nachreichen.
    func mouseDragged(_ e: CGEvent) -> Bool {
        guard let p = pressed else { return false }
        if hypot(e.location.x - p.at.x, e.location.y - p.at.y) > 4 { pressed = nil; hide(); Self.post(.leftMouseDown, p.at) }
        return true
    }

    func mouseUp(_ e: CGEvent) -> Bool {
        guard let p = pressed else { return false }
        pressed = nil
        hover.hide()
        if p.alt { ignore(p.mark) } else { apply(p.mark, clickAt: p.at) }
        return true
    }

    private func ignore(_ m: Mark) {
        guard m.fix.isSpelling else { // Grammatik: nur diesen Satz in Ruhe lassen
            let ns = textKey as NSString
            if NSMaxRange(m.fix.sentence) <= ns.length { let s = ns.substring(with: m.fix.sentence); cache[s] = s }
            hide(); schedule(after: 100)
            return
        }
        let w = m.fix.original.trimmingCharacters(in: .punctuationCharacters)
        if !Prefs.shared.ignoredWords.contains(w) { Prefs.shared.ignoredWords.append(w) }
        hide(); schedule(after: 100)
    }

    /// Rechtschreibung: nur das Wort. Grammatik: alle Korrekturen des Satzes als ein Stück.
    private func whole(_ m: Mark) -> (NSRange, String, String)? {
        let group = marks.map(\.fix).filter { $0.sentence == m.fix.sentence }.sorted { $0.range.location < $1.range.location }
        guard let a = group.first, let b = group.last else { return nil }
        let r = NSRange(location: a.range.location, length: NSMaxRange(b.range) - a.range.location)
        let ns = textKey as NSString
        guard NSMaxRange(r) <= ns.length else { return nil }
        let out = NSMutableString(string: ns.substring(with: r))
        for g in group.reversed() { out.replaceCharacters(in: NSRange(location: g.range.location - r.location, length: g.range.length), with: g.replacement) }
        return (r, ns.substring(with: r), out as String)
    }

    private func apply(_ m: Mark, clickAt: CGPoint) {
        guard let el = element else { return }
        let (range, old, new): (NSRange, String, String) = m.fix.isSpelling ? (m.fix.range, m.fix.original, m.fix.replacement)
            : whole(m) ?? (m.fix.range, m.fix.original, m.fix.replacement)
        let at = range.location + m.base
        onApply?()
        hide()
        Task {
            // Erst prüfen, dann markieren, dann nochmals prüfen. Erst danach wird getippt.
            let caret: Int? = await onAX {
                guard AXReader.text(el, at, range.length) == old, let c = AXReader.caret(el), AXReader.select(el, at, range.length),
                      AXReader.selectedText(el) == old else { return nil }
                return c
            }
            guard let caret else { // hat nicht gepasst: normalen Klick nachreichen
                Self.post(.leftMouseDown, clickAt); Self.post(.leftMouseUp, clickAt)
                return
            }
            KeyTap.type(new)
            try? await Task.sleep(for: .milliseconds(90))
            // Einfügemarke dorthin zurück, wo sie vorher war.
            let delta = (new as NSString).length - range.length
            let back = caret <= at ? caret : (caret >= at + range.length ? caret + delta : at + (new as NSString).length)
            await onAX { _ = AXReader.select(el, back, 0) }
            self.schedule(after: 350)
        }
    }

    private static func post(_ t: CGEventType, _ p: CGPoint) {
        guard let e = CGEvent(mouseEventSource: CGEventSource(stateID: .privateState), mouseType: t, mouseCursorPosition: p, mouseButton: .left) else { return }
        e.setIntegerValueField(.eventSourceUserData, value: KeyTap.marker)
        e.setIntegerValueField(.mouseEventClickState, value: 1)
        e.post(tap: .cgSessionEventTap)
    }

    private func onAX<T>(_ f: @escaping () -> T) async -> T {
        await withCheckedContinuation { c in axQueue.async { c.resume(returning: f()) } }
    }

    // Für den Selbsttest
    var marksForTest: [String] { marks.map { "\($0.fix.original)>\($0.fix.replacement)" } }
    func runForTest(_ f: AXReader.FieldText, _ fixes: [Fix]) async -> [(String, CGRect)] { await show(fixes, f); return marks.map { ($0.fix.original, $0.rect) } }
    func spellingForTest(_ text: String, _ lang: String) -> [Fix] {
        Corrector.sentences(text).flatMap { spelling($0.0, $0.1, lang, caret: -1, learned: { _ in false }) }
    }
}

/// Durchsichtiges Fenster mit Unterstreichungen. Nimmt keine Klicks an.
@MainActor
final class MarkOverlay {
    private final class Lines: NSView {
        var items: [(CGRect, Bool)] = []
        override var isFlipped: Bool { true }
        override func draw(_ d: NSRect) {
            for (r, spelling) in items {
                (spelling ? NSColor.systemRed : NSColor.systemBlue).withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: CGRect(x: r.minX, y: r.maxY - 2, width: r.width, height: 2), xRadius: 1, yRadius: 1).fill()
            }
        }
    }
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let lines = Lines()

    init() {
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.level = .floating; panel.hidesOnDeactivate = false; panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = lines
    }
    func hide() { panel.orderOut(nil) }
    func show(_ rects: [(CGRect, Bool)]) {
        let u = rects.dropFirst().reduce(rects[0].0) { $0.union($1.0) }.insetBy(dx: -2, dy: -3)
        lines.items = rects.map { ($0.0.offsetBy(dx: -u.minX, dy: -u.minY), $0.1) }
        panel.setFrame(Overlay.flip(u), display: false)
        lines.needsDisplay = true
        panel.orderFrontRegardless()
    }
}

/// Vorschau der Korrektur beim Überfahren.
@MainActor
final class HoverBubble {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let label = NSTextField(labelWithString: "")
    private let back = NSVisualEffectView()
    private var shown = ""

    init() {
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.ignoresMouseEvents = true
        panel.level = .popUpMenu; panel.hidesOnDeactivate = false; panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        back.material = .popover; back.state = .active; back.wantsLayer = true
        back.layer?.cornerRadius = 6; back.layer?.masksToBounds = true
        back.addSubview(label)
        panel.contentView = back
    }
    func hide() { if !shown.isEmpty { shown = ""; panel.orderOut(nil) } }
    func show(_ text: String, at r: CGRect) {
        let id = text + "\(r)"
        guard id != shown else { return }
        shown = id
        let s = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.labelColor])
        s.append(NSAttributedString(string: "   Klick korrigiert, ⌥-Klick ignoriert", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        label.attributedStringValue = s
        let fit = label.fittingSize, w = fit.width + 16, h = fit.height + 8
        let c = Overlay.flip(r)
        let vf = (NSScreen.screens.first { $0.frame.contains(CGPoint(x: c.midX, y: c.midY)) } ?? NSScreen.screens[0]).visibleFrame
        var y = c.minY - h - 5
        if y < vf.minY { y = c.maxY + 5 }
        panel.setFrame(CGRect(x: max(vf.minX + 4, min(c.minX, vf.maxX - w - 4)), y: y, width: w, height: h), display: false)
        label.frame = CGRect(x: 8, y: 4, width: fit.width, height: fit.height)
        panel.orderFrontRegardless()
    }
}
