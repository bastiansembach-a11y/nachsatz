import Foundation

/// Wo geschrieben wird. Das Basismodell setzt Dokumente fort und rät besser, wenn der Text so
/// eingerahmt ist wie in echten Dokumenten, etwa mit einer Betreffzeile über einer Mail.
public enum FieldKind: String, Sendable, CaseIterable {
    case mail, chat, document, other
}

public enum Frame {
    public enum Mode: String, Sendable, CaseIterable {
        /// nur der Text, wie bisher
        case off = "ohne"
        /// eine Zeile zur Art, ohne Titel
        case kind = "art"
        /// Art und Fenstertitel, etwa der Betreff
        case title = "titel"
    }

    /// Was die App verwendet. Bleibt aus, bis `Compare llama rahmen` zeigt, dass ein Rahmen hilft.
    public static let standard: Mode = .off

    static let mailApps: Set<String> = ["com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.mimestream.Mimestream",
                                        "it.bloop.airmail2", "com.superhuman.electron", "ch.protonmail.desktop", "org.mozilla.thunderbird"]
    static let chatApps: Set<String> = ["net.whatsapp.WhatsApp", "desktop.WhatsApp", "com.tinyspeck.slackmacgap", "com.hnc.Discord",
                                        "ru.keepcoder.Telegram", "org.telegram.desktop", "com.apple.MobileSMS", "com.microsoft.teams2",
                                        "com.microsoft.teams", "org.whispersystems.signal-desktop", "com.facebook.archon"]
    static let documentApps: Set<String> = ["com.microsoft.Word", "com.apple.iWork.Pages", "com.apple.TextEdit", "com.apple.Notes",
                                            "md.obsidian", "notion.id", "net.shinyfrog.bear", "com.ulyssesapp.mac"]
    static let browsers: Set<String> = ["com.google.Chrome", "com.apple.Safari", "org.mozilla.firefox", "com.brave.Browser",
                                        "company.thebrowser.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"]

    /// Art des Felds aus App und Fenstertitel. Bei Browsern zählt nur, welcher Dienst im Titel steht.
    public static func kind(bundle: String, title: String) -> FieldKind {
        if mailApps.contains(bundle) { return .mail }
        if chatApps.contains(bundle) { return .chat }
        if documentApps.contains(bundle) { return .document }
        guard browsers.contains(bundle) else { return .other }
        let t = title.lowercased()
        if ["gmail", "outlook", "proton mail", "posteingang", "inbox", "web.de", "gmx"].contains(where: t.contains) { return .mail }
        if ["whatsapp", "slack", "discord", "messenger", "telegram", "teams"].contains(where: t.contains) { return .chat }
        if ["google docs", "notion"].contains(where: t.contains) { return .document }
        return .other
    }

    /// Der Teil des Fenstertitels, der etwas über den Text sagt. nil bei Browsern und nichtssagenden Titeln.
    public static func usableTitle(bundle: String, title: String) -> String? {
        guard !browsers.contains(bundle) else { return nil } // Browsertitel enthalten oft Adressen und Zähler
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for sep in [" - ", " – ", " — ", " | "] { if let r = t.range(of: sep) { t = String(t[..<r.lowerBound]) } }
        for ext in [".docx", ".doc", ".pages", ".txt", ".rtf", ".md", ".odt"] where t.lowercased().hasSuffix(ext) { t = String(t.dropLast(ext.count)) }
        t = t.trimmingCharacters(in: .whitespaces)
        let generic: Set<String> = ["ohne titel", "untitled", "neue e-mail", "new message", "neue nachricht", "whatsapp", "signal", "telegram",
                                    "discord", "slack", "notizen", "notes", "dokument", "document", "posteingang", "inbox", "mail", "nachrichten", "messages"]
        guard t.count >= 2, t.count <= 80, t.contains(where: \.isLetter), !generic.contains(t.lowercased()) else { return nil }
        return t
    }

    /// Kopfzeile vor dem Text, leer wenn nichts Brauchbares bekannt ist. `lang` "de" oder sonst Englisch.
    public static func header(bundle: String, title: String, lang: String, mode: Mode) -> String {
        guard mode != .off else { return "" }
        let kind = kind(bundle: bundle, title: title)
        let t = mode == .title ? usableTitle(bundle: bundle, title: title) : nil
        let de = lang == "de"
        switch (kind, t) {
        case (.mail, let t?): return (de ? "Betreff: " : "Subject: ") + t + "\n\n"
        case (.mail, nil): return de ? "Neue E-Mail\n\n" : "New email\n\n"
        case (.chat, let t?): return (de ? "Chat mit " : "Chat with ") + t + "\n\n"
        case (.chat, nil): return de ? "Chatnachricht\n\n" : "Chat message\n\n"
        case (.document, let t?): return t + "\n\n"
        case (.document, nil), (.other, _): return "" // unbekannte Apps: Titel sagt oft nichts über den Text
        }
    }
}
