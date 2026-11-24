import AppKit
import SwiftUI

/// Hauptfenster. Nur solange es offen ist, erscheint Nachsatz im Dock.
@MainActor
final class MainWindow: NSObject, NSWindowDelegate {
    let model: AppModel
    private var window: NSWindow?
    private var timer: Timer?

    init(model: AppModel) { self.model = model }

    static func make(_ model: AppModel) -> NSWindow {
        let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 920, height: 660),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Nachsatz"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        // Leere Symbolleiste rückt die Fensterknöpfe in die Seitenleiste.
        w.toolbar = NSToolbar()
        w.toolbarStyle = .unified
        w.titlebarSeparatorStyle = .none
        w.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: MainView(model: model))
        host.sizingOptions = [.minSize]
        w.contentView = host
        w.minSize = CGSize(width: 800, height: 560)
        return w
    }

    func show(_ page: Page? = nil) {
        if let page { model.page = page }
        let first = window == nil
        if first {
            let w = Self.make(model)
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("NachsatzMain")
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        model.refresh(); model.loadNotes()
        guard let w = window else { return }
        let fresh = !w.isVisible
        if fresh, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            w.alphaValue = 0
            w.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { c in
                c.duration = 0.28
                c.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().alphaValue = 1
            }
        } else {
            w.alphaValue = 1
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer?.tolerance = 0.3
        }
        tick()
    }

    private func tick() {
        guard let w = window else { return }
        let seen = w.isVisible && w.occlusionState.contains(.visible) && w.isKeyWindow
        if model.visible != seen { model.visible = seen }
        if w.isVisible { model.refresh() }
    }

    func windowDidBecomeKey(_ n: Notification) { tick() }
    func windowDidResignKey(_ n: Notification) { tick() }
    func windowDidChangeOcclusionState(_ n: Notification) { tick() }
    func windowWillClose(_ n: Notification) {
        timer?.invalidate(); timer = nil
        model.visible = false
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Bilder aller Seiten mit erfundenen Daten, für die Sichtprüfung. Fasst Gedächtnis und Einstellungen nicht an.
@MainActor
enum Shots {
    /// Wechselt Seiten schnell und langsam und legt Bilder ab.
    static func flip(_ app: NSApplication, dir: String) {
        app.setActivationPolicy(.regular)
        let m = AppModel(); m.demo = true; m.trusted = true; m.model = .ready; m.visible = true
        let w = MainWindow.make(m); w.center(); w.makeKeyAndOrderFront(nil); app.activate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            let seq: [(Page, Bool)] = [(.general, true), (.home, false), (.proof, true), (.home, true), (.general, true), (.home, true)]
            for (i, s) in seq.enumerated() {
                m.trusted = s.1
                m.page = s.0
                for ms in [350, 1150] {
                    try? await Task.sleep(for: .milliseconds(ms))
                    save(w, dir + "/flip\(i)-\(s.0.rawValue)-\(ms).png")
                }
            }
            exit(0)
        }
        app.run()
    }

    /// Misst den eigenen Prozessorverbrauch je Seite: vorn (bewegt) und ruhend.
    static func bench(_ app: NSApplication, _ what: String) {
        app.setActivationPolicy(.regular)
        let m = AppModel()
        m.demo = true; m.trusted = true; m.model = .ready; m.visible = true
        Stats.shared.demo()
        let w = MainWindow.make(m)
        w.center(); w.makeKeyAndOrderFront(nil); app.activate()
        func cpu() -> Double { var r = rusage(); getrusage(RUSAGE_SELF, &r); return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6 }
        Task {
            for (name, page, moving) in [("Übersicht vorn", Page.home, true), ("Korrektur vorn", .proof, true), ("Übersicht ruhend", .home, false)] {
                m.page = page; m.visible = moving
                try? await Task.sleep(for: .seconds(3))
                let a = cpu(); try? await Task.sleep(for: .seconds(8))
                print(String(format: "%@: %.1f %%", name, (cpu() - a) / 8 * 100))
            }
            exit(0)
        }
        app.run()
    }

    static func run(_ app: NSApplication, dir: String) {
        app.setActivationPolicy(.regular)
        let m = AppModel()
        m.demo = true; m.visible = true; m.trusted = true; m.model = .ready; m.login = true
        Stats.shared.demo()
        m.notes = [.init(date: Date(), app: "com.apple.TextEdit", text: "Moin zusammen, die Liste hängt jetzt am Brett."),
                   .init(date: Date().addingTimeInterval(-4000), app: "com.apple.mail", text: "Ich melde mich spätestens nach der Mittagspause nochmal."),
                   .init(date: Date().addingTimeInterval(-90000), app: "com.apple.Notes", text: "The new lamp in the workshop works really well.")]
        m.apps = [.init(id: "com.apple.TextEdit", name: "TextEdit", last: "Vorschlag gezeigt"), .init(id: "com.apple.mail", name: "Mail", last: "gelesen, kein Vorschlag"),
                  .init(id: "com.apple.Notes", name: "Notizen", last: nil), .init(id: "com.apple.Terminal", name: "Terminal", last: nil)]
        let w = MainWindow.make(m)
        w.center(); w.makeKeyAndOrderFront(nil); app.activate()
        Task {
            for mode in ["hell", "dunkel"] {
                w.appearance = NSAppearance(named: mode == "hell" ? .aqua : .darkAqua)
                for p in Page.allCases {
                    m.page = p
                    try? await Task.sleep(for: .milliseconds(p == .home ? 2600 : 1300))
                    save(w, dir + "/\(mode)-\(p.rawValue).png")
                }
                m.trusted = false; m.page = .home
                try? await Task.sleep(for: .milliseconds(1500))
                save(w, dir + "/\(mode)-freigabe.png"); m.trusted = true
            }
            exit(0)
        }
        app.run()
    }

    /// Nur das eigene Fenster, ohne Bildschirmaufnahme.
    private static func save(_ w: NSWindow, _ path: String) {
        typealias F = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        var rep: NSBitmapImageRep?
        if let s = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
           let img = unsafeBitCast(s, to: F.self)(.null, 8, UInt32(w.windowNumber), 1 | 8)?.takeRetainedValue() { rep = NSBitmapImageRep(cgImage: img) }
        if rep == nil, let v = w.contentView, let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) { v.cacheDisplay(in: v.bounds, to: r); rep = r; print("nur Ansicht: \(path)") }
        try? rep?.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
