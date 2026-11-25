import AppKit
import NachsatzCore

@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    // Eigene Domäne, damit Einstellungen eine neue App-Kennung überstehen.
    private let d = UserDefaults(suiteName: "local.nachsatz.settings") ?? .standard

    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "enabled") } }
    @Published var maxWords: Int { didSet { d.set(maxWords, forKey: "maxWords") } }
    @Published var tabTakesAll: Bool { didSet { d.set(tabTakesAll, forKey: "tabTakesAll") } }
    @Published var language: String { didSet { d.set(language, forKey: "language") } }
    @Published var about: String { didSet { d.set(about, forKey: "about") } }
    /// "gemma" oder "apple"
    @Published var model: String { didSet { d.set(model, forKey: "model") } }
    @Published var midFill: Bool { didSet { d.set(midFill, forKey: "midFill") } }
    @Published var spelling: Bool { didSet { d.set(spelling, forKey: "spelling") } }
    /// Im Text anzeigen, sonst immer als Blase unter der Zeile.
    @Published var inlineText: Bool { didSet { d.set(inlineText, forKey: "inlineText") } }
    /// "today", "total" oder "off"
    @Published var menuCount: String { didSet { d.set(menuCount, forKey: "menuCount") } }
    @Published var blind: Bool { didSet { d.set(blind, forKey: "blind") } }
    @Published var grammar: Bool { didSet { d.set(grammar, forKey: "grammar") } }
    @Published var ignoredWords: [String] { didSet { d.set(ignoredWords, forKey: "ignoredWords") } }
    @Published var memoryOn: Bool { didSet { d.set(memoryOn, forKey: "memoryOn") } }
    @Published var memoryDays: Int { didSet { d.set(memoryDays, forKey: "memoryDays") } }
    /// 0 aus, 1 leicht, 2 mittel, 3 stark
    @Published var style: Int { didSet { d.set(style, forKey: "style") } }
    /// Wie sicher sich das Modell sein muss: 0 aus, 1 leicht, 2 mittel, 3 stark
    @Published var caution: Int { didSet { d.set(caution, forKey: "caution") } }
    /// Fenstertitel (etwa den Betreff) als Kopfzeile in den Prompt, sonst nur die Art der App
    @Published var useTitle: Bool { didSet { d.set(useTitle, forKey: "useTitle") } }
    @Published var memoryExcluded: [String] { didSet { d.set(memoryExcluded, forKey: "memoryExcluded") } }
    @Published var excluded: [String] { didSet { d.set(excluded, forKey: "excluded") } }

    private init() {
        if d.object(forKey: "migrated") == nil {
            let old = UserDefaults(suiteName: "local.nachsatz.mac")
            for k in ["enabled", "maxWords", "tabTakesAll", "language", "about", "excluded"] {
                if let v = old?.object(forKey: k) { d.set(v, forKey: k) }
            }
            d.set(true, forKey: "migrated")
        }
        d.register(defaults: [
            "enabled": true, "maxWords": 7, "tabTakesAll": false, "language": "de", "about": "", "model": "gemma", "midFill": true, "spelling": true, "grammar": true, "blind": true, "menuCount": "today", "inlineText": true, "ignoredWords": [String](), "memoryOn": true, "memoryDays": 5, "style": 2, "caution": Confidence.standard, "useTitle": true, "memoryExcluded": [String](),
            "excluded": ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                         "com.apple.dt.Xcode", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
                         "com.1password.1password", "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess"],
        ])
        enabled = d.bool(forKey: "enabled")
        maxWords = d.integer(forKey: "maxWords")
        tabTakesAll = d.bool(forKey: "tabTakesAll")
        language = d.string(forKey: "language") ?? "de"
        about = d.string(forKey: "about") ?? ""
        model = d.string(forKey: "model") ?? "gemma"
        midFill = d.bool(forKey: "midFill")
        spelling = d.bool(forKey: "spelling")
        menuCount = d.string(forKey: "menuCount") ?? "today"
        inlineText = d.bool(forKey: "inlineText")
        blind = d.bool(forKey: "blind")
        grammar = d.bool(forKey: "grammar")
        ignoredWords = d.stringArray(forKey: "ignoredWords") ?? []
        memoryOn = d.bool(forKey: "memoryOn")
        memoryDays = min(14, max(1, d.integer(forKey: "memoryDays")))
        style = min(3, max(0, d.integer(forKey: "style")))
        caution = min(3, max(0, d.integer(forKey: "caution")))
        useTitle = d.bool(forKey: "useTitle")
        memoryExcluded = d.stringArray(forKey: "memoryExcluded") ?? []
        excluded = d.stringArray(forKey: "excluded") ?? []
    }

    func isExcluded(_ id: String?) -> Bool { id.map(excluded.contains) ?? false }
    func remembers(_ id: String?) -> Bool { memoryOn && id.map { !memoryExcluded.contains($0) && !excluded.contains($0) } ?? false }
    func toggleRemember(_ id: String) {
        if let i = memoryExcluded.firstIndex(of: id) { memoryExcluded.remove(at: i) } else { memoryExcluded.append(id) }
    }
    func toggleExcluded(_ id: String) {
        if let i = excluded.firstIndex(of: id) { excluded.remove(at: i) } else { excluded.append(id) }
    }
}
