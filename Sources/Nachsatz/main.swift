import AppKit
import Combine
import NachsatzCore
import os
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = Controller()
    private var item: NSStatusItem!
    private let model = AppModel()
    private lazy var window = MainWindow(model: model)
    private var pruneTimer: Timer?
    private var timer: Timer?
    private let log = Logger(subsystem: "local.nachsatz.read", category: "status")
    private var lastStatus = ""
    private var lastWant = ""
    private var lastOn: Bool?
    private var lastCount: String?
    private var watch: Set<AnyCancellable> = []
    private var modelProblem: String? {
        if Prefs.shared.model == "gemma", Llama.problem == nil { return nil }
        return Engine.status
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        // Textbearbeitung in den eigenen Feldern braucht ein Bearbeiten-Menü.
        let main = NSMenu()
        let appItem = NSMenuItem(), appMenu = NSMenu(title: "Nachsatz")
        appMenu.addItem(withTitle: "Einstellungen …", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Nachsatz ausblenden", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Nachsatz beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem(), edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let winItem = NSMenuItem(), winMenu = NSMenu(title: "Fenster")
        winMenu.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu
        main.addItem(winItem)
        NSApp.mainMenu = main

        // Trägt Nachsatz in die Liste der Bedienungshilfen ein.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        MemoryHub.shared.open()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { await MemoryHub.shared.store.prune() }
            MainActor.assumeIsolated { Stats.shared.roll() }
        }
        model.controller = controller
        controller.onActivate = { [weak self] in self?.check() }
        Stats.shared.objectWillChange.merge(with: Prefs.shared.objectWillChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.showCount() } }
            .store(in: &watch)
        showCount()
        check()
        // Beim Anmelden still im Hintergrund, sonst mit Fenster.
        let e = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = e?.eventID == kAEOpenApplication && e?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !atLogin { window.show(.home) }
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer?.tolerance = 0.5
    }

    /// Vervollständigte Wörter neben dem Symbol.
    private func showCount() {
        let s = Stats.shared
        let n: Int? = Prefs.shared.menuCount == "today" ? s.words : (Prefs.shared.menuCount == "total" ? s.total : nil)
        let text = n.map { " " + $0.formatted() } ?? ""
        guard text != lastCount, let b = item.button else { return }
        lastCount = text
        b.attributedTitle = NSAttributedString(string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .baselineOffset: 0.5])
        b.toolTip = "Vervollständigte Wörter: heute \(s.words.formatted()), insgesamt \(s.total.formatted())"
        b.setAccessibilityLabel("Nachsatz, \(s.words) Wörter heute vervollständigt")
    }

    private func check() {
        let trusted = AXIsProcessTrusted()
        if trusted, !controller.pausedHere {
            if !controller.tap.running { _ = controller.start() }
        } else if controller.tap.running {
            controller.tap.stop(); controller.clear(); controller.proof.hide()
        }
        // In den Systemeinstellungen ruht nur der Abgriff, das Modell bleibt geladen.
        let running = controller.tap.running || (trusted && controller.pausedHere)
        // Nur Zustände, nie getippter Text.
        let status = "trusted=\(trusted) tap=\(controller.tap.running) pause=\(controller.pausedHere) model=\(Prefs.shared.model) \(modelProblem ?? "ok")"
        if status != lastStatus { lastStatus = status; log.notice("\(status, privacy: .public)") }
        let want = "\(Prefs.shared.enabled)\(Prefs.shared.model)\(running)"
        if want != lastWant { lastWant = want; controller.syncModel(running: running) }
        let on = running && Prefs.shared.enabled && modelProblem == nil
        if on != lastOn { // nur bei Änderung neu zeichnen
            lastOn = on
            item.button?.image = NSImage(systemSymbolName: on ? "text.append" : "text.badge.xmark", accessibilityDescription: "Nachsatz")
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ t: String, _ a: Selector?, on: Bool? = nil, enabled: Bool = true) {
            let i = NSMenuItem(title: t, action: a, keyEquivalent: "")
            i.target = self; i.isEnabled = enabled
            if let on { i.state = on ? .on : .off }
            menu.addItem(i)
        }
        if !AXIsProcessTrusted() { add("Bedienungshilfen erlauben …", #selector(openAccess)) }
        if Prefs.shared.model == "gemma", let s = Llama.problem { add(s + ", nutze Apples Modell", nil, enabled: false) }
        if let s = modelProblem { add(s, nil, enabled: false) }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: "app.cotypist.Cotypist").isEmpty
            || NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == "Cotypist" }) {
            add("Cotypist läuft auch: bitte eines davon beenden", nil, enabled: false)
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        Stats.shared.roll()
        add("Vervollständigt: heute \(Stats.shared.words.formatted()), insgesamt \(Stats.shared.total.formatted()) Wörter", nil, enabled: false)
        add("Nachsatz öffnen …", #selector(openMain))
        menu.addItem(.separator())
        add("Vorschläge aktiv", #selector(toggle), on: Prefs.shared.enabled)
        if let app = controller.frontApp, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier {
            add("In \(app.localizedName ?? id) aktiv", #selector(toggleApp), on: !Prefs.shared.isExcluded(id))
            if let s = controller.status(of: id) { add("Zuletzt: \(s)", nil, enabled: false) }
        }
        add("Fehler anzeigen", #selector(toggleSpelling), on: Prefs.shared.spelling)
        menu.addItem(.separator())
        if let p = MemoryHub.shared.problem { add(p, nil, enabled: false) }
        add("Gedächtnis aktiv", #selector(toggleMemory), on: Prefs.shared.memoryOn)
        if let app = controller.frontApp, let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier, !Prefs.shared.isExcluded(id) {
            add("Aus \(app.localizedName ?? id) merken", #selector(toggleRemember), on: Prefs.shared.remembers(id), enabled: Prefs.shared.memoryOn)
        }
        add("Gedächtnis anzeigen …", #selector(openMemory))
        menu.addItem(.separator())
        add("Einstellungen …", #selector(openSettings))
        add("Nachsatz beenden", #selector(quit))
    }

    @objc private func toggle() { Prefs.shared.enabled.toggle(); controller.clear(); check() }
    @objc private func toggleApp() {
        if let id = controller.frontApp?.bundleIdentifier { Prefs.shared.toggleExcluded(id); controller.clear() }
    }
    @objc private func toggleSpelling() { Prefs.shared.spelling.toggle(); controller.proof.hide() }
    @objc private func toggleMemory() { controller.commitTyping(); Prefs.shared.memoryOn.toggle() }
    @objc private func toggleRemember() {
        if let id = controller.frontApp?.bundleIdentifier { controller.commitTyping(); Prefs.shared.toggleRemember(id) }
    }
    @objc private func openMain() { window.show() }
    @objc private func openMemory() { window.show(.memory) }
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool { window.show(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        controller.commitTyping()
        Task {
            try? await Task.sleep(for: .milliseconds(150)) // letzte Notiz sichern
            await controller.llama.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    @objc private func openAccess() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc private func openSettings() { window.show(.general) }
    @objc private func quit() { NSApp.terminate(nil) }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    if CommandLine.arguments.contains("--selftest") {
        SelfTest.run(app)
    } else if let i = CommandLine.arguments.firstIndex(of: "--flip"), CommandLine.arguments.count > i + 1 {
        Shots.flip(app, dir: CommandLine.arguments[i + 1])
    } else if let i = CommandLine.arguments.firstIndex(of: "--bench"), CommandLine.arguments.count > i + 1 {
        Shots.bench(app, CommandLine.arguments[i + 1])
    } else if let i = CommandLine.arguments.firstIndex(of: "--shots"), CommandLine.arguments.count > i + 1 {
        Shots.run(app, dir: CommandLine.arguments[i + 1])
    } else {
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
