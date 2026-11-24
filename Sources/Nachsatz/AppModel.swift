import AppKit
import NachsatzCore
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case home, suggest, proof, memory, apps, general
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "Übersicht"
        case .suggest: "Vorschläge"
        case .proof: "Korrektur"
        case .memory: "Gedächtnis"
        case .apps: "Apps"
        case .general: "Allgemein"
        }
    }
    var icon: String {
        switch self {
        case .home: "text.append"
        case .suggest: "wand.and.sparkles"
        case .proof: "checkmark.seal"
        case .memory: "brain.head.profile"
        case .apps: "square.grid.2x2"
        case .general: "gearshape"
        }
    }
}

/// Zahlen des Tages. Nur Zähler, nie Text.
@MainActor
final class Stats: ObservableObject {
    static let shared = Stats()
    private let d = UserDefaults(suiteName: "local.nachsatz.settings") ?? .standard
    @Published private(set) var shown = 0
    @Published private(set) var words = 0
    /// Alle je vervollständigten Wörter.
    @Published private(set) var total = 0
    @Published private(set) var chars = 0
    @Published private(set) var fixes = 0
    @Published private(set) var firstMs: Int?
    private var day = ""

    private init() {
        let s = d.dictionary(forKey: "stats") ?? [:]
        total = s["total"] as? Int ?? s["words"] as? Int ?? 0
        roll()
    }
    /// Auch um Mitternacht auf den neuen Tag umstellen.
    func roll() {
        let today = Date().formatted(.iso8601.year().month().day())
        guard today != day else { return }
        day = today
        let s = d.dictionary(forKey: "stats") ?? [:]
        let same = s["day"] as? String == today
        shown = same ? s["shown"] as? Int ?? 0 : 0
        words = same ? s["words"] as? Int ?? 0 : 0
        chars = same ? s["chars"] as? Int ?? 0 : 0
        fixes = same ? s["fixes"] as? Int ?? 0 : 0
    }
    private func save() { d.set(["day": day, "shown": shown, "words": words, "chars": chars, "fixes": fixes, "total": total], forKey: "stats") }

    func didShow(ms: Int) { roll(); shown += 1; firstMs = firstMs.map { ($0 * 3 + ms) / 4 } ?? ms; save() }
    func didAccept(_ piece: String) {
        roll()
        let w = piece.split(whereSeparator: \.isWhitespace).count
        words += w; total += w; chars += piece.count; save()
    }
    func didFix() { roll(); fixes += 1; save() }
    func demo() { shown = 128; words = 342; total = 12_480; chars = 1870; fixes = 17; firstMs = 140 }
}

@MainActor
final class AppModel: ObservableObject {
    enum Model: Equatable { case ready, asleep, loading, problem(String) }
    struct AppLine: Identifiable, Equatable { var id: String; var name: String; var last: String? }

    @Published var page: Page = .home
    @Published var trusted = false
    @Published var model: Model = .loading
    @Published var memoryProblem: String?
    @Published var rival = false
    @Published var notes: [Note] = []
    @Published var apps: [AppLine] = []
    @Published var visible = false
    @Published var scratch = ""
    @Published var login = false
    var demo = false
    weak var controller: Controller?

    var active: Bool { trusted && Prefs.shared.enabled && !modelBroken }
    var modelBroken: Bool { if case .problem = model { true } else { false } }

    func refresh() {
        guard !demo else { return }
        set(\.trusted, AXIsProcessTrusted())
        set(\.memoryProblem, MemoryHub.shared.problem)
        set(\.rival, !NSRunningApplication.runningApplications(withBundleIdentifier: "app.cotypist.Cotypist").isEmpty)
        if Prefs.shared.model == "apple" {
            set(\.model, Engine.status.map { .problem($0) } ?? .ready)
        } else if let p = Llama.problem {
            set(\.model, .problem(p))
        } else if let llama = controller?.llama {
            Task {
                let ready = await llama.isReady, last = await llama.lastUse
                set(\.model, !ready ? .loading : (Date().timeIntervalSince(last) > 900 ? .asleep : .ready))
            }
        }
        var ids = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
        ids.formUnion(Prefs.shared.excluded.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil })
        ids.formUnion(Prefs.shared.memoryExcluded)
        ids.remove(Bundle.main.bundleIdentifier ?? "")
        set(\.apps, ids.map { AppLine(id: $0, name: Self.name($0), last: controller?.status(of: $0)) }
            .sorted { ($0.last == nil ? 1 : 0, $0.name.lowercased()) < ($1.last == nil ? 1 : 0, $1.name.lowercased()) })
    }

    private func set<T: Equatable>(_ key: ReferenceWritableKeyPath<AppModel, T>, _ v: T) {
        if self[keyPath: key] != v { withAnimation(Theme.spring) { self[keyPath: key] = v } }
    }

    func loadNotes() {
        guard !demo else { return }
        Task { let n = await MemoryHub.shared.store.all; withAnimation(Theme.spring) { notes = n } }
    }
    func delete(_ n: Note) {
        withAnimation(Theme.spring) { notes.removeAll { $0.id == n.id } }
        if !demo { Task { await MemoryHub.shared.store.delete(n.id) } }
    }
    func clearNotes() {
        withAnimation(Theme.spring) { notes = [] }
        if !demo { Task { await MemoryHub.shared.store.clear() } }
    }

    private static var names: [String: String] = [:]
    static func name(_ id: String) -> String {
        if let n = names[id] { return n }
        var n = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { FileManager.default.displayName(atPath: $0.path) } ?? id
        if n.hasSuffix(".app") { n.removeLast(4) }
        names[id] = n
        return n
    }
    private static var icons: [String: NSImage] = [:]
    static func icon(_ id: String) -> NSImage {
        if let i = icons[id] { return i }
        let i = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)!
        icons[id] = i
        return i
    }
}
