import AppKit
import ApplicationServices

struct FieldContext {
    var pid: pid_t
    var before: String
    var after: String
    /// Einfügemarke in AX-Koordinaten (Ursprung oben links).
    var caret: CGRect
    var field: CGRect
    var exactCaret: Bool
    var fontName: String?
    var fontSize: CGFloat?
    /// "bereich", "marke" oder "getippt"
    var way = "bereich"
    var role = ""
    var millis = 0
    /// Fenstertitel, etwa der Betreff einer Mail. Nur für den Prompt, nie gespeichert oder protokolliert.
    var title = ""
}

/// Warum ein Feld nicht gelesen werden konnte. Enthält nie Text.
enum ReadFailure: Error, Equatable {
    case noFocus, secure, search, selection
    /// Fokus liegt auf etwas, das kein Textfeld ist.
    case notText(String)
    /// Textfeld, aber Text oder Marke kommen nicht heraus.
    case unreadable(String)

    var label: String {
        switch self {
        case .noFocus: "kein Feld gemeldet"
        case .secure: "Passwortfeld"
        case .search: "Suchfeld"
        case .selection: "Text markiert"
        case .notText(let r): "kein Textfeld (\(r))"
        case .unreadable(let r): "Text nicht lesbar (\(r))"
        }
    }
    /// Kann sich gleich ändern, zum Beispiel weil die App ihren Baum erst aufbaut.
    var retry: Bool {
        switch self { case .noFocus, .notText, .unreadable: true; default: false }
    }
}

/// Liest das fokussierte Textfeld über die Bedienungshilfen. Nie auf dem Hauptthread aufrufen:
/// AX-Aufrufe warten auf die fremde App.
enum AXReader {
    private static let timeout: Float = 0.5
    private static let system: AXUIElement = {
        let e = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(e, timeout)
        return e
    }()

    // MARK: Wecken

    private static let wakeLock = NSLock()
    private static var woken: [pid_t: Date] = [:]
    private static var enhanced: Set<pid_t> = []

    /// Chromium- und Electron-Apps bauen ihren AX-Baum erst nach dieser Aufforderung auf.
    static func wake(pid: pid_t, bundle: URL?, force: Bool = false) {
        wakeLock.lock()
        let due = force || Date().timeIntervalSince(woken[pid] ?? .distantPast) > 5
        if due { woken[pid] = Date() }
        wakeLock.unlock()
        guard due else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    /// Zweite Stufe für Chrome-artige Browser und Firefox, die nur auf dieses Merkmal hören.
    static func wakeBrowser(pid: pid_t, bundle: URL?, electron: Bool) {
        guard let bundle, electron && isElectron(bundle) || isBrowserShell(bundle) else { return }
        wakeLock.lock(); let fresh = enhanced.insert(pid).inserted; wakeLock.unlock()
        guard fresh else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }

    static func isElectron(_ bundle: URL) -> Bool {
        FileManager.default.fileExists(atPath: bundle.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
    }

    static func isBrowserShell(_ bundle: URL) -> Bool {
        if Bundle(url: bundle)?.bundleIdentifier?.hasPrefix("org.mozilla.") == true { return true }
        let list = (try? FileManager.default.contentsOfDirectory(atPath: bundle.appendingPathComponent("Contents/Frameworks").path)) ?? []
        guard !list.contains("Electron Framework.framework") else { return false }
        return list.contains { n in
            n.hasSuffix(".framework") && ["Chrome Framework", "Chromium", "Microsoft Edge Framework", "Brave Browser Framework", "Vivaldi Framework",
                                          "Opera Framework", "Arc Framework", "ArcCore"].contains { n.contains($0) }
        }
    }

    // MARK: Feld finden

    private static let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String]

    private static func role(_ e: AXUIElement) -> String { copy(e, kAXRoleAttribute) ?? "" }

    private static func settable(_ e: AXUIElement, _ attr: String) -> Bool {
        var s: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(e, attr as CFString, &s) == .success && s.boolValue
    }

    /// Fokussiertes, beschreibbares Feld. Web-Inhalte melden oft nur einen Absatz oder die ganze Seite als Fokus.
    static func locate(frontPID: pid_t, hint: Hint = Hint()) -> Result<AXUIElement, ReadFailure> {
        let first = focusedField(frontPID: frontPID)
        guard case .failure(let f) = first, f.retry else { return first }
        return searched(frontPID: frontPID, hint: hint).map { .success($0) } ?? first
    }

    /// Letzter Klick und zuletzt Getipptes. Damit lässt sich ein Feld finden, das die App nicht als fokussiert meldet.
    struct Hint { var click: CGPoint?; var typed = "" }

    private static let foundLock = NSLock()
    private static var found: [pid_t: AXUIElement] = [:]
    private static var missed: [pid_t: (at: Date, click: CGPoint?)] = [:]

    private static func searched(frontPID: pid_t, hint: Hint) -> AXUIElement? {
        func fits(_ e: AXUIElement) -> Bool {
            AXUIElementSetMessagingTimeout(e, timeout)
            guard textRoles.contains(role(e)) || settable(e, kAXValueAttribute) else { return false }
            if (copy(e, kAXFocusedAttribute) as NSNumber?)?.boolValue == true { return true }
            // Sonst zählt nur der Beweis: Vor der Marke steht genau das eben Getippte.
            let t = clean(hint.typed)
            guard t.filter({ !$0.isWhitespace }).count >= 3, case .success(let c) = read(element: e) else { return false }
            return c.before.hasSuffix(String(t.suffix(8)))
        }
        foundLock.lock(); let known = found[frontPID]; foundLock.unlock()
        if let known, fits(known) { return known }
        func keep(_ e: AXUIElement) -> AXUIElement { foundLock.lock(); found[frontPID] = e; foundLock.unlock(); return e }

        // Vergebliche Suche nicht bei jeder Taste wiederholen.
        foundLock.lock(); let miss = missed[frontPID]; foundLock.unlock()
        if let miss, miss.click == hint.click, Date().timeIntervalSince(miss.at) < 3 { return nil }
        if hint.typed.filter({ !$0.isWhitespace }).count >= 3 { foundLock.lock(); missed[frontPID] = (Date(), hint.click); foundLock.unlock() }

        let app = AXUIElementCreateApplication(frontPID)
        AXUIElementSetMessagingTimeout(app, timeout)
        if let p = hint.click {
            var e: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &e) == .success, let e {
                if fits(e) { return keep(e) }
                for a in ["AXHighestEditableAncestor", "AXEditableAncestor"] { if let up: AXUIElement = copy(e, a), fits(up) { return keep(up) } }
                var up: AXUIElement? = e
                for _ in 0..<6 {
                    up = up.flatMap { copy($0, kAXParentAttribute) }
                    guard let u = up else { break }
                    if textRoles.contains(role(u)), fits(u) { return keep(u) }
                }
            }
        }
        for area in webAreas(app) {
            let q: [String: Any] = ["AXSearchKey": ["AXTextFieldSearchKey"], "AXDirection": "AXDirectionNext", "AXResultsLimit": 40]
            for e in (param(area, "AXUIElementsForSearchPredicate", q as CFDictionary) as? [AXUIElement]) ?? [] where fits(e) { return keep(e) }
        }
        return nil
    }

    /// Web-Inhalte der vorderen Fenster, begrenzt in Menge und Zeit.
    private static func webAreas(_ app: AXUIElement) -> [AXUIElement] {
        let stop = Date().addingTimeInterval(0.25)
        var queue: [AXUIElement] = [], i = 0, out: [AXUIElement] = []
        for a in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] { if let w: AXUIElement = copy(app, a) { queue.append(w) } }
        if queue.isEmpty, let all: [AXUIElement] = copy(app, kAXWindowsAttribute) { queue = Array(all.prefix(2)) }
        while i < queue.count, i < 250, out.count < 4, Date() < stop {
            let e = queue[i]; i += 1
            AXUIElementSetMessagingTimeout(e, 0.2)
            if role(e) == "AXWebArea" { out.append(e); continue }
            if let kids: [AXUIElement] = copy(e, kAXChildrenAttribute) { queue += kids.prefix(30) }
        }
        return out
    }

    private static func focusedField(frontPID: pid_t) -> Result<AXUIElement, ReadFailure> {
        var tried: [AXUIElement] = []
        if let e: AXUIElement = copy(system, kAXFocusedUIElementAttribute) { tried.append(e) }
        let app = AXUIElementCreateApplication(frontPID)
        AXUIElementSetMessagingTimeout(app, timeout)
        // Nicht jede App beantwortet die systemweite Frage, deshalb zusätzlich die App selbst fragen.
        if tried.first.map({ !textRoles.contains(role($0)) }) ?? true, let e: AXUIElement = copy(app, kAXFocusedUIElementAttribute) { tried.append(e) }
        guard !tried.isEmpty else {
            if let w: AXUIElement = copy(app, kAXFocusedWindowAttribute), let f = focusedInside(w) { return .success(f) }
            return .failure(.noFocus)
        }
        for e in tried {
            AXUIElementSetMessagingTimeout(e, timeout)
            let r = role(e)
            if textRoles.contains(r) { return .success(e) }
            for a in ["AXHighestEditableAncestor", "AXEditableAncestor"] {
                if let up: AXUIElement = copy(e, a) { return .success(up) }
            }
            if settable(e, kAXValueAttribute), !["AXSlider", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXScrollBar", "AXIncrementor"].contains(r) { return .success(e) }
        }
        for e in tried where ["AXWebArea", "AXGroup", "AXWindow", "AXScrollArea", "AXUnknown", "AXApplication", "AXSplitGroup", ""].contains(role(e)) {
            if let f = focusedInside(e) { return .success(f) }
        }
        // Seite mit beschreibbarem Inhalt (Mail-Editoren): die Marke selbst kennt ihr Feld.
        for e in tried {
            if let s = markerSelection(e), let at: AXUIElement = element(param(e, "AXUIElementForTextMarker", s.end)) {
                if textRoles.contains(role(at)) { return .success(at) }
                if let up: AXUIElement = copy(at, "AXHighestEditableAncestor") { return .success(up) }
            }
        }
        return .failure(.notText(role(tried[0])))
    }

    /// Sucht unterhalb eines Elements das Textfeld mit dem Fokus, begrenzt in Menge und Zeit.
    private static func focusedInside(_ top: AXUIElement) -> AXUIElement? {
        let stop = Date().addingTimeInterval(0.35)
        var queue = [top], i = 0
        while i < queue.count, i < 400, Date() < stop {
            let e = queue[i]; i += 1
            AXUIElementSetMessagingTimeout(e, 0.2)
            if i > 1, textRoles.contains(role(e)), (copy(e, kAXFocusedAttribute) as NSNumber?)?.boolValue == true { return e }
            if let kids: [AXUIElement] = copy(e, kAXChildrenAttribute) { queue += kids.prefix(60) }
        }
        return nil
    }

    struct FieldText { var element: AXUIElement; var text: String; var base: Int; var caret: Int; var frame: CGRect }

    /// Sichtbarer Text des Feldes, höchstens 4.000 Zeichen um die Marke.
    static func readText(frontPID: pid_t) -> FieldText? {
        guard case .success(let e) = locate(frontPID: frontPID) else { return nil }
        return readText(element: e)
    }

    static func readText(element el: AXUIElement) -> FieldText? {
        AXUIElementSetMessagingTimeout(el, timeout)
        let role: String = copy(el, kAXRoleAttribute) ?? "", subrole: String = copy(el, kAXSubroleAttribute) ?? ""
        if subrole == kAXSecureTextFieldSubrole as String || subrole == kAXSearchFieldSubrole as String { return nil }
        guard [kAXTextAreaRole, kAXTextFieldRole].map({ $0 as String }).contains(role) else { return nil }
        guard let c = caret(el), let total = (copy(el, kAXNumberOfCharactersAttribute) as NSNumber?)?.intValue, total > 2 else { return nil }
        var from = max(0, c - 2000), to = min(total, c + 2000)
        if let v: AXValue = copy(el, kAXVisibleCharacterRangeAttribute) {
            var r = CFRange()
            if AXValueGetValue(v, .cfRange, &r), r.length > 0 { from = max(from, r.location); to = min(to, r.location + r.length) }
        }
        guard to > from, let t = string(el, from, to - from), (t as NSString).length == to - from else { return nil }
        // Web-Editoren zählen Zeichen manchmal anders, als sie Text melden. Dann lieber keine Striche als falsche.
        if isRich(el), let m = markerText(el) {
            let here = (t as NSString).substring(to: max(0, min(c - from, (t as NSString).length)))
            func tail(_ s: String) -> String { String(clean(s).filter { !$0.isWhitespace }.suffix(12)) }
            guard c >= from, tail(here) == tail(m.before) else { return nil }
        }
        return FieldText(element: el, text: t.replacingOccurrences(of: "\u{00A0}", with: " "), base: from, caret: c - from, frame: frame(el))
    }

    /// Ende der Auswahl, also die Einfügemarke.
    static func caret(_ el: AXUIElement) -> Int? {
        guard let v: AXValue = copy(el, kAXSelectedTextRangeAttribute) else { return nil }
        var r = CFRange()
        return AXValueGetValue(v, .cfRange, &r) && r.location >= 0 ? r.location + r.length : nil
    }
    static func text(_ el: AXUIElement, _ loc: Int, _ len: Int) -> String? { string(el, loc, len)?.replacingOccurrences(of: "\u{00A0}", with: " ") }
    static func rect(_ el: AXUIElement, _ loc: Int, _ len: Int) -> CGRect? { bounds(el, loc, len) }
    static func select(_ el: AXUIElement, _ loc: Int, _ len: Int) -> Bool {
        guard AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, range(loc, len)) == .success else { return false }
        guard let v: AXValue = copy(el, kAXSelectedTextRangeAttribute) else { return false }
        var r = CFRange()
        return AXValueGetValue(v, .cfRange, &r) && r.location == loc && r.length == len
    }
    static func selectedText(_ el: AXUIElement) -> String? { (copy(el, kAXSelectedTextAttribute) as String?)?.replacingOccurrences(of: "\u{00A0}", with: " ") }

    static func read(frontPID: pid_t, hint: Hint = Hint()) -> Result<FieldContext, ReadFailure> { locate(frontPID: frontPID, hint: hint).flatMap { read(element: $0) } }

    /// Unsichtbare Zeichen, mit denen Web-Editoren Zeilen offen halten.
    static func clean(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars where ![0x200B, 0x2060, 0xFEFF, 0xFFFC].contains(u.value) { out.append(u.value == 0xA0 ? " " : u) }
        return String(out)
    }

    static func read(element el: AXUIElement) -> Result<FieldContext, ReadFailure> {
        AXUIElementSetMessagingTimeout(el, timeout)
        let began = Date()
        var pid: pid_t = 0
        AXUIElementGetPid(el, &pid)
        let r = role(el), subrole: String = copy(el, kAXSubroleAttribute) ?? ""
        if subrole == kAXSecureTextFieldSubrole as String { return .failure(.secure) }
        if subrole == kAXSearchFieldSubrole as String { return .failure(.search) }

        let plain = rangeText(el)
        // Formatierte Web-Felder: Zahlen-Bereiche sind dort unzuverlässig, Textmarken nicht.
        var way = "bereich", text: (before: String, after: String)?
        let rich = isRich(el)
        if !rich, case .failure(.selection) = plain { return .failure(.selection) }
        if rich, let s = markerSelection(el), !(markerString(el, s.start, s.end) ?? "").isEmpty { return .failure(.selection) }
        if rich, let m = markerText(el) {
            var emptyDespiteText = false
            if m.before.isEmpty, case .success(let p) = plain, !p.before.isEmpty { emptyDespiteText = true }
            if !emptyDespiteText { text = m; way = "marke" }
        }
        if text == nil, case .success(let p) = plain { text = (p.before, p.after) }
        if text == nil, !rich, let m = markerText(el) { text = m; way = "marke" }
        guard let text else { return .failure(.unreadable(r)) }
        let before = clean(text.before), after = clean(text.after)

        let field = frame(el)
        var caret = CGRect.zero, exact = false
        func plausible(_ r: CGRect) -> Bool {
            r.height > 4 && r.height < 200 && (field.isEmpty || field.insetBy(dx: -20, dy: -20).intersects(r))
        }
        // Das Zeichen vor der Marke ist verlässlich. Für die leere Auswahl meldet AppKit
        // eine Zeile zu hoch, deshalb ist sie nur die zweite Wahl.
        var loc = -1
        if case .success(let p) = plain, way == "bereich" { loc = p.location }
        let prev = loc > 0 ? bounds(el, loc - 1, 1) : (way == "marke" ? markerPrevious(el) : nil)
        if let r = prev, text.before.last?.isNewline == false, plausible(r) {
            caret = CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height); exact = true
        } else if loc >= 0, let r = bounds(el, loc, 0), plausible(r) {
            caret = CGRect(x: r.minX, y: r.minY, width: 1, height: r.height); exact = true
            // Nach einem Umbruch muss die Marke unter der Zeile des Umbruchs stehen.
            if let p = prev, text.before.last?.isNewline == true, r.minY <= p.minY + 1 { caret.origin.y = p.minY + p.height }
        } else if let r = markerBounds(el), plausible(r) {
            caret = CGRect(x: r.maxX, y: r.minY, width: 1, height: r.height); exact = true
        } else if !field.isEmpty {
            caret = CGRect(x: field.minX, y: max(field.minY, field.maxY - 20), width: 1, height: 20)
        } else if let w = window(of: el) {
            caret = CGRect(x: w.midX - 100, y: w.maxY - 60, width: 1, height: 20)
        } else { return .failure(.unreadable("Position")) }

        let font = loc > 0 ? fontInfo(el, loc - 1) : nil
        var c = FieldContext(pid: pid, before: way == "marke" ? String(before.dropFirst(windowStart(before.count))) : before, after: String(after.prefix(200)), caret: caret, field: field,
                             exactCaret: exact, fontName: font?.0, fontSize: font?.1, way: way, role: r,
                             millis: Int(Date().timeIntervalSince(began) * 1000))
        c.title = windowTitle(el)
        return .success(c)
    }

    /// Notbehelf ohne lesbares Feld: Blase unten im vorderen Fenster, Text nur aus dem gerade Getippten.
    static func blind(frontPID: pid_t, typed: String, click: CGPoint?) -> FieldContext? {
        let app = AXUIElementCreateApplication(frontPID)
        AXUIElementSetMessagingTimeout(app, timeout)
        var w = CGRect.zero
        if let e: AXUIElement = copy(app, kAXFocusedWindowAttribute) { w = frame(e) }
        if w.isEmpty { w = frontWindow(frontPID) ?? .zero }
        guard !w.isEmpty else { return nil }
        // Knapp über der angeklickten Zeile, sonst unten im Fenster.
        var at = CGPoint(x: w.midX - 100, y: w.maxY - 120)
        if let click, w.contains(click) { at = CGPoint(x: click.x, y: max(w.minY, click.y - 64)) }
        return FieldContext(pid: frontPID, before: typed, after: "", caret: CGRect(x: at.x, y: at.y, width: 1, height: 20), field: w,
                            exactCaret: false, fontName: nil, fontSize: nil, way: "getippt", role: "-", millis: 0)
    }

    private static func windowTitle(_ el: AXUIElement) -> String {
        guard let w: AXUIElement = copy(el, kAXWindowAttribute) else { return "" }
        return copy(w, kAXTitleAttribute) ?? ""
    }

    private static func window(of el: AXUIElement) -> CGRect? {
        guard let w: AXUIElement = copy(el, kAXWindowAttribute) else { return nil }
        let f = frame(w)
        return f.isEmpty ? nil : f
    }

    /// Rahmen des vordersten Fensters, ohne Titel oder Inhalt zu lesen.
    private static func frontWindow(_ pid: pid_t) -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let b = w[kCGWindowBounds as String], let r = CGRect(dictionaryRepresentation: b as! CFDictionary), r.height > 100 { return r }
        }
        return nil
    }

    /// Nur Rollen und Merkmale für die Fehlersuche, nie Text.
    static func probe(frontPID: pid_t, hint: Hint) -> String {
        var out: [String] = []
        func line(_ name: String, _ e: AXUIElement?) {
            guard let e else { out.append("\(name)=nichts"); return }
            AXUIElementSetMessagingTimeout(e, timeout)
            var pid: pid_t = 0
            AXUIElementGetPid(e, &pid)
            let kids: [AXUIElement] = copy(e, kAXChildrenAttribute) ?? []
            out.append("\(name)=\(role(e))/\(copy(e, kAXSubroleAttribute) as String? ?? "-") eigenePid=\(pid == frontPID) kinder=\(kids.count) bereich=\(caret(e) ?? -1) zeichen=\((copy(e, kAXNumberOfCharactersAttribute) as NSNumber?)?.intValue ?? -1) marke=\(markerSelection(e) != nil) editierbar=\((copy(e, "AXHighestEditableAncestor") as AXUIElement?) != nil) wert=\(settable(e, kAXValueAttribute))")
        }
        let sys: AXUIElement? = copy(system, kAXFocusedUIElementAttribute)
        let app = AXUIElementCreateApplication(frontPID)
        line("system", sys)
        line("app", copy(app, kAXFocusedUIElementAttribute))
        func code(_ e: AXUIElement, _ a: String) -> Int32 { var v: CFTypeRef?; return AXUIElementCopyAttributeValue(e, a as CFString, &v).rawValue }
        out.append("fehler: system=\(code(system, kAXFocusedUIElementAttribute)) app=\(code(app, kAXFocusedUIElementAttribute)) fenster=\(code(app, kAXFocusedWindowAttribute)) haupt=\(code(app, kAXMainWindowAttribute)) liste=\(code(app, kAXWindowsAttribute)) manuell=\(code(app, "AXManualAccessibility")) erweitert=\(code(app, "AXEnhancedUserInterface"))")
        out.append("webbereiche=\(webAreas(app).map { a in (copy(a, kAXChildrenAttribute) as [AXUIElement]?)?.count ?? -1 })")
        if let p = hint.click {
            var e: AXUIElement?
            let err = AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &e)
            out.append("klick=\(err.rawValue)"); line("klick", e)
        }
        switch locate(frontPID: frontPID, hint: hint) {
        case .failure(let f): out.append("gefunden: \(f.label)")
        case .success(let e):
            line("feld", e)
            let p = rangeText(e)
            if case .success(let x) = p { out.append("bereich: vor=\(x.before.count) nach=\(x.after.count)") } else { out.append("bereich: nein") }
            if let m = markerText(e) { out.append("marke: vor=\(m.before.count) nach=\(m.after.count)") } else { out.append("marke: nein") }
            switch read(element: e) {
            case .success(let c): out.append("ergebnis: \(c.way) vor=\(c.before.count) nach=\(c.after.count) exakt=\(c.exactCaret) hoehe=\(Int(c.caret.height)) imFeld=\(c.field.insetBy(dx: -4, dy: -4).contains(CGPoint(x: c.caret.midX, y: c.caret.midY))) ms=\(c.millis)")
            case .failure(let f): out.append("ergebnis: \(f.label)")
            }
        }
        return out.joined(separator: " | ")
    }

    // MARK: Text über Zahlen-Bereiche

    /// Beginn des Textfensters in 400er-Schritten. Ein fester Anfang lässt das Modell seinen Zwischenstand weiterverwenden.
    static func windowStart(_ n: Int) -> Int { n <= 1200 ? 0 : (n - 1200 + 399) / 400 * 400 }

    private static func rangeText(_ el: AXUIElement) -> Result<(before: String, after: String, location: Int), ReadFailure> {
        guard let rv: AXValue = copy(el, kAXSelectedTextRangeAttribute) else { return .failure(.unreadable("Auswahl")) }
        var sel = CFRange()
        guard AXValueGetValue(rv, .cfRange, &sel), sel.location >= 0 else { return .failure(.unreadable("Auswahl")) }
        guard sel.length == 0 else { return .failure(.selection) }
        let total: Int = (copy(el, kAXNumberOfCharactersAttribute) as NSNumber?)?.intValue ?? -1
        let start = windowStart(sel.location)
        var before: String?, after: String?
        if total >= sel.location {
            before = sel.location == 0 ? "" : string(el, start, sel.location - start)
            let n = min(200, total - sel.location)
            after = n == 0 ? "" : string(el, sel.location, n)
        }
        if before == nil || after == nil {
            guard let v: String = copy(el, kAXValueAttribute) else { return .failure(.unreadable("Wert")) }
            let ns = v as NSString
            guard sel.location <= ns.length else { return .failure(.unreadable("Wert")) }
            before = ns.substring(with: NSRange(location: start, length: sel.location - start))
            after = ns.substring(with: NSRange(location: sel.location, length: min(200, ns.length - sel.location)))
        }
        return .success((before!, after!, sel.location))
    }

    // MARK: Text über Textmarken (WebKit, Chromium, Electron, Firefox)

    private static func markerSelection(_ el: AXUIElement) -> (start: AXTextMarker, end: AXTextMarker, range: AXTextMarkerRange)? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
        let r = v as! AXTextMarkerRange
        return (AXTextMarkerRangeCopyStartMarker(r), AXTextMarkerRangeCopyEndMarker(r), r)
    }

    private static func markerRange(_ el: AXUIElement, _ attr: String, _ arg: CFTypeRef) -> AXTextMarkerRange? {
        guard let v = param(el, attr, arg), CFGetTypeID(v) == AXTextMarkerRangeGetTypeID() else { return nil }
        return (v as! AXTextMarkerRange)
    }

    private static func markerString(_ el: AXUIElement, _ a: AXTextMarker, _ b: AXTextMarker) -> String? {
        param(el, "AXStringForTextMarkerRange", AXTextMarkerRangeCreate(nil, a, b)) as? String
    }

    /// Feld mit inneren Absätzen, also kein einfaches Eingabefeld.
    private static func isRich(_ el: AXUIElement) -> Bool {
        guard markerSelection(el) != nil else { return false }
        let kids: [AXUIElement] = copy(el, kAXChildrenAttribute) ?? []
        return !kids.isEmpty
    }

    private static func markerText(_ el: AXUIElement) -> (before: String, after: String)? {
        guard let s = markerSelection(el), (markerString(el, s.start, s.end) ?? "").isEmpty,
              let all = markerRange(el, "AXTextMarkerRangeForUIElement", el) else { return nil }
        let first = AXTextMarkerRangeCopyStartMarker(all), last = AXTextMarkerRangeCopyEndMarker(all)
        guard let whole = markerString(el, first, s.end), let rest = markerString(el, s.end, last) else { return nil }
        // Zwischen Absätzen fehlt oft der Umbruch. Die Absatzgrenze der Marke hilft weiter.
        if let para = markerRange(el, "AXParagraphTextMarkerRangeForTextMarker", s.end),
           let lead = markerString(el, AXTextMarkerRangeCopyStartMarker(para), s.end), let trail = markerString(el, s.end, AXTextMarkerRangeCopyEndMarker(para)),
           whole.hasSuffix(lead), rest.hasPrefix(trail) {
            var head = String(whole.dropLast(lead.count))
            if !head.isEmpty, head.last?.isNewline == false { head += "\n" }
            var tail = trail
            if rest.count > trail.count, tail.last?.isNewline != true { tail += "\n" }
            return (head + lead, tail + rest.dropFirst(trail.count).prefix(200))
        }
        return (whole, rest)
    }

    /// Rahmen des Zeichens vor der Marke.
    private static func markerPrevious(_ el: AXUIElement) -> CGRect? {
        guard let s = markerSelection(el), let v = param(el, "AXPreviousTextMarkerForTextMarker", s.end), CFGetTypeID(v) == AXTextMarkerGetTypeID() else { return nil }
        guard let r = rect(param(el, "AXBoundsForTextMarkerRange", AXTextMarkerRangeCreate(nil, (v as! AXTextMarker), s.end))), r.width > 0 else { return nil }
        return r
    }

    // MARK: Hilfen

    private static func copy<T>(_ el: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v else { return nil }
        if T.self == AXUIElement.self { return CFGetTypeID(v) == AXUIElementGetTypeID() ? (v as! T) : nil }
        if T.self == AXValue.self { return CFGetTypeID(v) == AXValueGetTypeID() ? (v as! T) : nil }
        return v as? T
    }

    private static func param(_ el: AXUIElement, _ attr: String, _ arg: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, arg, &v) == .success ? v : nil
    }

    private static func range(_ loc: Int, _ len: Int) -> AXValue {
        var r = CFRange(location: loc, length: len)
        return AXValueCreate(.cfRange, &r)!
    }

    private static func string(_ el: AXUIElement, _ loc: Int, _ len: Int) -> String? {
        param(el, kAXStringForRangeParameterizedAttribute, range(loc, len)) as? String
    }

    private static func rect(_ v: CFTypeRef?) -> CGRect? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil
    }

    private static func bounds(_ el: AXUIElement, _ loc: Int, _ len: Int) -> CGRect? {
        rect(param(el, kAXBoundsForRangeParameterizedAttribute, range(loc, len)))
    }

    private static func markerBounds(_ el: AXUIElement) -> CGRect? {
        guard let s = markerSelection(el) else { return nil }
        return rect(param(el, "AXBoundsForTextMarkerRange", s.range))
    }

    private static func element(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func frame(_ el: AXUIElement) -> CGRect {
        guard let p: AXValue = copy(el, kAXPositionAttribute), let s: AXValue = copy(el, kAXSizeAttribute) else { return .zero }
        var o = CGPoint.zero, z = CGSize.zero
        AXValueGetValue(p, .cgPoint, &o); AXValueGetValue(s, .cgSize, &z)
        return CGRect(origin: o, size: z)
    }

    private static func fontInfo(_ el: AXUIElement, _ loc: Int) -> (String, CGFloat)? {
        guard let s = param(el, kAXAttributedStringForRangeParameterizedAttribute, range(loc, 1)) as? NSAttributedString,
              s.length > 0,
              let d = s.attribute(NSAttributedString.Key("AXFont"), at: 0, effectiveRange: nil) as? [String: Any],
              let size = (d["AXFontSize"] as? NSNumber)?.doubleValue else { return nil }
        return (d["AXFontName"] as? String ?? "", CGFloat(size))
    }
}
