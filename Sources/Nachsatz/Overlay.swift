import AppKit
import NachsatzCore

/// Zeigt den Vorschlag als grauen Text an der Einfügemarke, ohne den Fokus zu nehmen.
@MainActor
final class Overlay {
    let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let bubble = NSVisualEffectView()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        bubble.material = .popover
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 6
        bubble.layer?.masksToBounds = true
        let root = NSView()
        root.addSubview(bubble)
        root.addSubview(label)
        panel.contentView = root
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
    }

    /// Gilt für einen Vorschlag: Form und Ort wechseln nicht, während man weitertippt.
    private enum Form { case inline, bubble }
    private var form: Form?
    private var bubbleOrigin: CGPoint?
    private var bubbleLine: CGFloat = 0
    /// Zeile, auf der zuletzt angezeigt wurde. Kleine Messunterschiede derselben Zeile werden geglättet.
    private var line: (pid: pid_t, midY: CGFloat, height: CGFloat, size: CGFloat)?

    var isVisible: Bool { panel.isVisible }
    var isInline: Bool { form == .inline }

    func hide() {
        form = nil; bubbleOrigin = nil
        if panel.isVisible { panel.orderOut(nil) }
    }

    /// Weitergetippt oder Wort übernommen: sofort mitrücken, ohne auf die App zu warten.
    func advance(by typed: String, rest: String) {
        guard isVisible else { return }
        if form == .inline, let font = label.font {
            let w = (typed as NSString).size(withAttributes: [.font: font]).width
            var f = panel.frame
            f.origin.x += w; f.size.width = max(24, f.width - w)
            label.stringValue = rest
            panel.setFrame(f, display: true)
            label.frame = CGRect(x: -1, y: 0, width: f.width, height: f.height)
        } else {
            setBubble(rest)
        }
    }

    /// Vorschlag wächst hinten, Ort und Form bleiben.
    func extend(to text: String) {
        guard isVisible else { return }
        if form == .inline, let font = label.font {
            let w = ceil((text as NSString).size(withAttributes: [.font: font]).width) + 8
            var f = panel.frame
            f.size.width = min(w, max(rightEdge - f.minX, 24))
            label.stringValue = text
            panel.setFrame(f, display: true)
            label.frame = CGRect(x: -1, y: 0, width: f.width, height: f.height)
        } else { setBubble(text) }
    }
    private var rightEdge: CGFloat = .infinity

    func show(_ text: String, at c: FieldContext, bubble forceBubble: Bool = false) {
        var caret = Self.flip(c.caret)
        let field = Self.flip(c.field)
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -2, dy: -2).contains(CGPoint(x: caret.midX, y: caret.midY)) }) else { return hide() }

        var h = c.caret.height
        var size = min(max(h / 1.2, 9), 44)
        if let s = c.fontSize, s > h * 0.4, s < h * 1.1 { size = s }
        if c.exactCaret {
            if let l = line, l.pid == c.pid, abs(l.midY - caret.midY) <= max(4, l.height * 0.35), abs(l.height - h) <= l.height * 0.45 {
                caret = CGRect(x: caret.minX, y: l.midY - l.height / 2, width: caret.width, height: l.height)
                h = l.height; size = l.size
            } else { line = (c.pid, caret.midY, h, size) }
        }
        let font = (c.fontName.flatMap { $0.hasPrefix(".") ? nil : NSFont(name: $0, size: size) }) ?? .systemFont(ofSize: size)
        func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: font]).width) }
        rightEdge = min(field.isEmpty ? .infinity : field.maxX, screen.visibleFrame.maxX)
        let room = rightEdge - caret.maxX

        if form == nil {
            let fits = width(text) <= room || width(Joiner.nextChunk(of: text) + "…") <= room
            form = !forceBubble && Prefs.shared.inlineText && c.exactCaret && fits ? .inline : .bubble
        } else if form == .inline, !c.exactCaret || width(Joiner.nextChunk(of: text)) > room {
            form = .bubble // Zeilenende erreicht
        }

        if form == .inline {
            bubble.isHidden = true
            panel.hasShadow = false
            label.font = font
            label.textColor = NSColor(white: 0.55, alpha: 0.95)
            label.lineBreakMode = .byTruncatingTail
            label.stringValue = text
            let fit = label.fittingSize.height
            let f = CGRect(x: caret.maxX - 1, y: caret.midY - fit / 2, width: min(width(text) + 8, max(room, 24)), height: fit)
            let old = panel.frame
            let sameSpot = panel.isVisible && abs(old.minX - f.minX) < 1.5 && abs(old.minY - f.minY) < 1.5
            let target = CGRect(origin: sameSpot ? old.origin : f.origin, size: f.size)
            panel.setFrame(target, display: false)
            label.frame = CGRect(x: -1, y: 0, width: target.width, height: target.height)
        } else {
            bubble.isHidden = false
            panel.hasShadow = true
            label.font = .systemFont(ofSize: 13)
            label.textColor = .labelColor
            label.lineBreakMode = .byClipping
            if bubbleOrigin == nil || abs(bubbleLine - caret.midY) > max(4, caret.height * 0.6) {
                let vf = screen.visibleFrame
                var y = caret.minY - 4
                if y - 30 < vf.minY { y = caret.maxY + 4 + 26 }
                bubbleOrigin = CGPoint(x: caret.minX, y: y) // obere linke Ecke
                bubbleLine = caret.midY
            }
            setBubble(text)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private func setBubble(_ text: String) {
        guard let o = bubbleOrigin else { return }
        label.stringValue = text.trimmingCharacters(in: .whitespaces) + "  ⇥"
        let fit = label.fittingSize, w = fit.width + 16, hh = fit.height + 8
        let vf = (NSScreen.screens.first { $0.frame.contains(o) } ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        let x = max(vf.minX + 4, min(o.x, vf.maxX - w - 4))
        panel.setFrame(CGRect(x: x, y: o.y - hh, width: w, height: hh), display: true)
        bubble.frame = CGRect(x: 0, y: 0, width: w, height: hh)
        label.frame = CGRect(x: 8, y: 4, width: fit.width, height: fit.height)
    }

    static func flip(_ r: CGRect) -> CGRect {
        guard !r.isEmpty || r.height > 0, let primary = NSScreen.screens.first else { return .zero }
        return CGRect(x: r.minX, y: primary.frame.maxY - r.maxY, width: r.width, height: r.height)
    }
}
