import AppKit
import Carbon.HIToolbox
import NachsatzCore
import os
import ScreenCaptureKit
import Vision

/// Liest ab und zu den ganzen Bildschirm als Text, damit Vorschläge wissen, worum es gerade geht,
/// zum Beispiel um die Mail, auf die du antwortest. Das Bild wird sofort verworfen, der Text bleibt
/// nur im Arbeitsspeicher und wird weder gemerkt noch protokolliert. Braucht „Bildschirmaufnahme“.
@MainActor
final class ScreenWatch {
    /// Höchstens so oft wird neu aufgenommen, und nur, während geschrieben wird.
    static let interval: TimeInterval = 45
    private var text = ""
    private var pid: pid_t = 0
    private var taken = Date.distantPast
    private var tried: (pid: pid_t, at: Date) = (0, .distantPast)
    private var running: Task<Void, Never>?
    private let log = Logger(subsystem: "local.nachsatz.read", category: "bildschirm")

    nonisolated static var allowed: Bool { CGPreflightScreenCaptureAccess() }
    /// Zeigt beim ersten Mal die Rückfrage von macOS und trägt Nachsatz in die Liste ein.
    static func ask() { if !allowed { _ = CGRequestScreenCaptureAccess() } }
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    /// Text, der zuletzt um dieses Feld herum zu sehen war. Stößt bei Bedarf eine neue Aufnahme an,
    /// wartet aber nie darauf, damit der Vorschlag nicht langsamer wird.
    func context(for c: FieldContext) -> String {
        guard Prefs.shared.screen, !IsSecureEventInputEnabled(), Self.allowed else { forget(); return "" }
        let now = Date()
        if tried.pid != c.pid || now.timeIntervalSince(tried.at) > Self.interval { refresh(c) }
        // Zu alt, weil die Aufnahme länger nicht klappt: lieber nichts als Überholtes.
        guard pid == c.pid, now.timeIntervalSince(taken) < Self.interval * 4 else { return "" }
        return text
    }

    func forget() {
        running?.cancel(); running = nil
        text = ""; pid = 0; taken = .distantPast; tried = (0, .distantPast)
    }

    private func refresh(_ c: FieldContext) {
        guard running == nil else { return }
        tried = (c.pid, Date())
        let target = c.pid, caret = c.caret, written = c.before + c.after
        let skip = [c.field] + Self.menuBars()
        let hidden = Set(Prefs.shared.excluded + [Bundle.main.bundleIdentifier ?? ""])
        running = Task { [weak self] in
            let began = Date()
            let lines = await Self.capture(around: caret, hiding: hidden)
            guard let self, !Task.isCancelled else { return }
            self.running = nil
            guard let lines, Prefs.shared.screen, !IsSecureEventInputEnabled() else {
                self.log.notice("Bildschirm nicht gelesen")
                return
            }
            self.text = ScreenText.digest(lines, near: caret, skip: skip, written: written)
            self.pid = target
            self.taken = Date()
            // Nur Zahlen, nie Text.
            self.log.info("Bildschirm gelesen: \(lines.count) Zeilen, \(self.text.count) Zeichen, \(Int(Date().timeIntervalSince(began) * 1000)) ms")
        }
    }

    /// Menüleisten aller Bildschirme in AX-Koordinaten.
    private static func menuBars() -> [CGRect] {
        guard let top = NSScreen.screens.first?.frame.maxY else { return [] }
        return NSScreen.screens.compactMap { s in
            let h = s.frame.maxY - s.visibleFrame.maxY
            return h > 0 ? CGRect(x: s.frame.minX, y: top - s.frame.maxY, width: s.frame.width, height: h) : nil
        }
    }

    /// Bildschirm mit der Schreibmarke, ohne Nachsatz selbst und ohne ausgeschlossene Apps.
    private nonisolated static func capture(around caret: CGRect, hiding: Set<String>) async -> [ScreenLine]? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let point = CGPoint(x: caret.midX, y: caret.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(point) }) ?? content.displays.first else { return nil }
            let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { hiding.contains($0.bundleIdentifier) },
                                         exceptingWindows: [])
            let config = SCStreamConfiguration()
            // Retina-Auflösung, aber nicht mehr als nötig: das spart Zeit bei der Texterkennung.
            let scale = min(2, 3000 / max(1, CGFloat(display.width)))
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard !Task.isCancelled else { return nil }
            let frame = display.frame
            return await withCheckedContinuation { c in
                DispatchQueue.global(qos: .utility).async { c.resume(returning: ScreenWatch.recognize(image, in: frame)) }
            }
        } catch {
            return nil
        }
    }

    /// Texterkennung von Apple, rechnet auf dem Mac.
    private nonisolated static func recognize(_ image: CGImage, in frame: CGRect) -> [ScreenLine]? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["de-DE", "en-US"]
        request.minimumTextHeight = 0.006 // winzige Schrift ist meist Beiwerk
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) } catch { return nil }
        return (request.results ?? []).compactMap { o -> ScreenLine? in
            guard let t = o.topCandidates(1).first, t.confidence >= 0.4 else { return nil }
            let b = o.boundingBox // normiert, Ursprung unten links
            return ScreenLine(text: t.string, rect: CGRect(x: frame.minX + b.minX * frame.width, y: frame.minY + (1 - b.maxY) * frame.height,
                                                           width: b.width * frame.width, height: b.height * frame.height))
        }
    }
}
