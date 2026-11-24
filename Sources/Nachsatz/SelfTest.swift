import AppKit
import ApplicationServices

/// Prüft Feld lesen, Vorschlag und Anzeige in einem eigenen Fenster, ohne Systemrechte
/// und ohne fremde Apps anzufassen. Schreibt ein Bild des Ergebnisses.
@MainActor
enum SelfTest {
    static var keep: [AnyObject] = []
    static var failures = 0

    static func run(_ app: NSApplication) {
        setvbuf(stdout, nil, _IONBF, 0)
        let w = NSWindow(contentRect: CGRect(x: 200, y: 300, width: 620, height: 170), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.font = .systemFont(ofSize: 16)
        tv.string = "Hallo Frau Müller,\n\nvielen Dank für Ihre schnelle Rückm"
        w.contentView = scroll
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        w.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        let controller = Controller()
        keep = [w, controller]

        Task {
            try? await Task.sleep(for: .milliseconds(600))
            let found = await withCheckedContinuation { c in
                DispatchQueue.main.async { c.resume(returning: find(AXUIElementCreateApplication(getpid()), 0).flatMap { try? AXReader.read(element: $0).get() }) }
            }
            var ctx: FieldContext
            if found != nil {
                let original = String(decoding: Array(tv.string.utf8), as: UTF8.self) // echte Kopie
                for t in ["eine Zeile", "eins\nzwei", "eins\n\ndrei ", "eins\nzwei\n"] {
                    tv.string = t
                    let end = NSRange(location: (t as NSString).length, length: 0)
                    tv.setSelectedRange(end)
                    try? await Task.sleep(for: .milliseconds(200))
                    let want = tv.firstRect(forCharacterRange: end, actualRange: nil)
                    let got = await withCheckedContinuation { c in
                        DispatchQueue.main.async { c.resume(returning: find(AXUIElementCreateApplication(getpid()), 0).flatMap { try? AXReader.read(element: $0).get() }) }
                    }.map { Overlay.flip($0.caret) } ?? .zero
                    let ok = abs(got.minX - want.minX) < 2 && abs(got.minY - want.minY) < 2
                    if !ok { failures += 1 }
                    print("Position \(t.debugDescription): \(ok ? "stimmt" : "FALSCH \(got) statt \(want)")")
                }
                tv.string = original
                tv.setSelectedRange(NSRange(location: (original as NSString).length, length: 0))
                try? await Task.sleep(for: .milliseconds(200))
            }
            let again = await withCheckedContinuation { c in
                DispatchQueue.main.async { c.resume(returning: find(AXUIElementCreateApplication(getpid()), 0).flatMap { try? AXReader.read(element: $0).get() }) }
            }
            if let found = again {
                ctx = found
                print("AX: gelesen, Text endet auf \(found.before.suffix(10).debugDescription), Marke \(found.caret), exakt \(found.exactCaret), Schrift \(found.fontName ?? "-") \(found.fontSize ?? 0)")
            } else {
                print("AX: im eigenen Prozess nicht lesbar (Recht fehlt), Position kommt aus dem Textfeld")
                let r = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
                let top = NSScreen.screens[0].frame.maxY
                let f = w.convertToScreen(scroll.frame)
                ctx = FieldContext(pid: getpid(), before: tv.string, after: "", caret: CGRect(x: r.minX, y: top - r.maxY, width: 1, height: r.height),
                                   field: CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height), exactCaret: true, fontName: nil, fontSize: 16)
            }
            // Fehler unterstreichen und Auswahl prüfen (ohne zu tippen).
            let faulty = "Kanst du mir morgen helfen?\nIch habe den Termin vergesen und komme spät."
            tv.string = faulty
            tv.setSelectedRange(NSRange(location: (faulty as NSString).length, length: 0))
            try? await Task.sleep(for: .milliseconds(250))
            let field = await withCheckedContinuation { c in
                DispatchQueue.main.async { c.resume(returning: find(AXUIElementCreateApplication(getpid()), 0).flatMap { AXReader.readText(element: $0) }) }
            }
            if let field {
                let fixes = controller.proof.spellingForTest(field.text, "de")
                let placed = await controller.proof.runForTest(field, fixes)
                print("Fehler: \(fixes.map { "\($0.original)>\($0.replacement)" })")
                for (w, r) in placed {
                    let want = tv.firstRect(forCharacterRange: (faulty as NSString).range(of: w), actualRange: nil), got = Overlay.flip(r)
                    let ok = abs(want.minX - got.minX) < 2 && abs(want.minY - got.minY) < 3 && abs(want.width - got.width) < 3
                    if !ok { failures += 1 }
                    print("Strich unter \(w): \(ok ? "stimmt" : "FALSCH \(got) statt \(want)")")
                }
                if placed.count != 2 { failures += 1; print("FALSCH: \(placed.count) statt 2 Striche") }
                let r = (faulty as NSString).range(of: "vergesen")
                let sel: String? = await withCheckedContinuation { c in
                    DispatchQueue.main.async { c.resume(returning: AXReader.select(field.element, r.location, r.length) ? AXReader.selectedText(field.element) : nil) }
                }
                if sel != "vergesen" { failures += 1 }
                print("Auswahl per Klick: \(sel ?? "nicht möglich")")
                controller.proof.hide()
            } else { failures += 1; print("FALSCH: Feldtext nicht lesbar") }
            // Ganze Prüfkette mit Grammatik, Text ohne Tippfehler.
            if Prefs.shared.model == "gemma" {
                _ = await controller.llama.waitReady(seconds: 30)
                let t2 = "Ich glaube das er morgen kommt. Wir treffen uns am Montag."
                tv.string = t2; tv.setSelectedRange(NSRange(location: 0, length: 0))
                try? await Task.sleep(for: .milliseconds(250))
                if let f2 = await withCheckedContinuation({ c in
                    DispatchQueue.main.async { c.resume(returning: find(AXUIElementCreateApplication(getpid()), 0).flatMap { AXReader.readText(element: $0) }) }
                }) {
                    await controller.proof.check(f2)
                    print("Grammatik: \(controller.proof.marksForTest)")
                    if controller.proof.marksForTest != ["glaube>glaube,", "das>dass"] { failures += 1; print("FALSCH") }
                    controller.proof.hide()
                }
                let g = try? await controller.llama.fillGap(before: "Wir fahren am Samstag ", after: "nach Hamburg.")
                print("Mitten im Satz: \((g ?? nil) ?? "nichts")")
            }
            tv.string = "Hallo Frau Müller,\n\nvielen Dank für Ihre schnelle Rückm"
            if Prefs.shared.model == "gemma" { print("Gemma bereit: \(await controller.llama.waitReady(seconds: 30))") }
            let s = await controller.suggestion(for: ctx)
            print("Vorschlag: \(s.debugDescription)")
            if let s {
                controller.overlay.show(s, at: ctx)
                let o = controller.overlay.panel.frame
                print("Anzeige: sichtbar \(controller.overlay.isVisible), Rahmen \(o), Fokus behalten: \(!controller.overlay.panel.isKeyWindow)")
                snapshot(w, controller.overlay.panel)
                // Ruhe in der Anzeige: mitrücken, Zeilenende, Blase.
                @MainActor func check(_ name: String, _ ok: Bool) { if !ok { failures += 1 }; print("\(name): \(ok ? "stimmt" : "FALSCH \(controller.overlay.panel.frame)")") }
                let ov = controller.overlay
                ov.hide(); ov.show("eldung und Grüße", at: ctx)
                let x0 = ov.panel.frame.minX, y0 = ov.panel.frame.minY
                ov.advance(by: "eld", rest: "ung und Grüße")
                let wide = ("eld" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 16)]).width
                check("Mitrücken", abs(ov.panel.frame.minX - x0 - wide) < 1.5 && ov.panel.frame.minY == y0 && ov.isInline)
                var wobble = ctx; wobble.caret.origin.x += wide; wobble.caret.origin.y += 2; wobble.caret.size.height += 1
                ov.show("ung und Grüße", at: wobble)
                check("Gleiche Zeile bleibt gleich hoch", abs(ov.panel.frame.minY - y0) < 0.6)
                var edge = ctx; edge.caret.origin.x = ctx.field.maxX - 90
                ov.hide(); ov.show("eldung und viele liebe Grüße", at: edge)
                check("Zeilenende gekürzt im Text", ov.isInline && Overlay.flip(ctx.field).maxX >= ov.panel.frame.maxX - 1)
                edge.caret.origin.x = ctx.field.maxX - 8
                ov.hide(); ov.show("eldung und", at: edge)
                let b0 = CGPoint(x: ov.panel.frame.minX, y: ov.panel.frame.maxY)
                check("Kein Platz: Blase", !ov.isInline)
                do {
                    ov.hide(); ov.show("eldung", at: ctx)
                    let f0 = ov.panel.frame
                    ov.extend(to: "eldung und Grüße")
                    check("Wächst nur hinten", ov.panel.frame.minX == f0.minX && ov.panel.frame.minY == f0.minY && ov.panel.frame.width > f0.width && ov.isInline)
                    var steps: [String] = []
                    let end = await controller.suggestion(for: ctx) { steps.append($0); return true }
                    check("Schrittweise \(steps.count) Teile", !steps.isEmpty && end?.hasPrefix(steps.last!) == true)
                    steps = []
                    let none = await controller.suggestion(for: ctx) { steps.append($0); return false }
                    check("Abbruch nach erstem Teil", steps.count == 1 && none == nil)
                    ov.hide(); ov.show("eldung und", at: edge)
                }
                edge.caret.origin.x += 5; ov.show("dung und", at: edge)
                check("Blase bleibt stehen", abs(ov.panel.frame.maxY - b0.y) < 1 && abs(ov.panel.frame.minX - b0.x) < 60)
            }
            exit(s == nil || failures > 0 ? 1 : 0)
        }
        app.run()
    }

    private nonisolated static func find(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &v)
        if v as? String == kAXTextAreaRole as String { return el }
        guard depth < 8, AXUIElementCopyAttributeValue(el, (depth == 0 ? kAXWindowsAttribute : kAXChildrenAttribute) as CFString, &v) == .success,
              let kids = v as? [AXUIElement] else { return nil }
        for k in kids { if let f = find(k, depth + 1) { return f } }
        return nil
    }

    /// Zeichnet Fenster und Vorschlag übereinander, ohne Bildschirmaufnahme.
    private static func snapshot(_ w: NSWindow, _ p: NSPanel) {
        guard let a = w.contentView, let b = p.contentView, let ra = a.bitmapImageRepForCachingDisplay(in: a.bounds),
              let rb = b.bitmapImageRepForCachingDisplay(in: b.bounds) else { return }
        a.cacheDisplay(in: a.bounds, to: ra); b.cacheDisplay(in: b.bounds, to: rb)
        let img = NSImage(size: a.bounds.size)
        img.lockFocus()
        ra.draw(in: a.bounds)
        let origin = w.convertPoint(fromScreen: p.frame.origin)
        rb.draw(in: CGRect(origin: origin, size: p.frame.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        img.unlockFocus()
        if let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t), let path = CommandLine.arguments.last, path.hasSuffix(".png") {
            try? r.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
}
