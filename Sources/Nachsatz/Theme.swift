import AppKit
import SwiftUI

/// Ohne Xcode fehlt das Makro @State, die zugrunde liegende Hülle gibt es aber.
typealias Local<T> = SwiftUI.State<T>

enum Theme {
    static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let v = a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
        })
    }
    // Schreibpapier: Creme und Sepia, im Dunkeln Espresso.
    static let ink = dyn(0x35271C, 0xF1E7D8)
    static let ghost = dyn(0xA08D78, 0x8F806F)
    static let muted = dyn(0x6E5C4B, 0xBBAB98)
    static let accent = dyn(0x8A5A2B, 0xD6A46A)
    static let ember = dyn(0xB04A24, 0xE88B5C)
    static let good = dyn(0x5F7A3A, 0xA9C27B)
    static let spring = Animation.spring(response: 0.36, dampingFraction: 0.92)
    static let paper = [dyn(0xFAF5EA, 0x211A15), dyn(0xF1E6D3, 0x191310)]
}

/// Papier: fast einfarbig, mit einem Hauch Licht von oben. Bewegt sich nicht.
struct Paper: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            LinearGradient(colors: Theme.paper, startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [.white.opacity(scheme == .dark ? 0.04 : 0.55), .clear], center: UnitPoint(x: 0.7, y: 0), startRadius: 0, endRadius: 620)
        }
        .ignoresSafeArea()
    }
}

/// Karten gleiten beim Öffnen einer Seite nacheinander herein.
private struct Entrance: ViewModifier {
    let index: Int
    @Local private var shown = false
    @Environment(\.accessibilityReduceMotion) private var calm
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || calm ? 0 : 6)
            .onAppear { withAnimation(.easeOut(duration: 0.3).delay(Double(index) * 0.03)) { shown = true } }
    }
}
extension View {
    func entrance(_ i: Int) -> some View { modifier(Entrance(index: i)) }
}

/// Glasfläche mit Überschrift.
struct Card<Content: View>: View {
    var title: String?
    var icon: String?
    let index: Int
    let content: Content
    init(_ title: String? = nil, icon: String? = nil, index: Int = 0, @ViewBuilder content: () -> Content) {
        self.title = title; self.icon = icon; self.index = index; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack(spacing: 7) {
                    if let icon { Image(systemName: icon).foregroundStyle(Theme.accent) }
                    Text(title).foregroundStyle(Theme.ink)
                }
                .font(.system(size: 13, weight: .semibold))
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .entrance(index)
    }
}

struct Row<Trailing: View>: View {
    let title: String
    var note: String?
    let trailing: Trailing
    init(_ title: String, note: String? = nil, @ViewBuilder trailing: () -> Trailing) { self.title = title; self.note = note; self.trailing = trailing() }
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink)
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            trailing
        }
    }
}

struct Switch: View {
    @Binding var on: Bool
    var body: some View { Toggle("", isOn: $on.animation(Theme.spring)).toggleStyle(.switch).labelsHidden().tint(Theme.accent) }
}

/// Auswahl, deren Glasfläche zum gewählten Wert gleitet.
struct Choice<T: Hashable>: View {
    @Binding var value: T
    let options: [(T, String)]
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { o in
                let on = value == o.0
                Text(o.1)
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.ink : Theme.muted)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background {
                        if on {
                            Capsule().fill(.background.opacity(0.75)).shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "choice", in: ns)
                        }
                    }
                    .contentShape(.capsule)
                    .onTapGesture { withAnimation(Theme.spring) { value = o.0 } }
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.ink.opacity(0.07)))
        .fixedSize()
    }
}

/// Ruhiger Glasknopf neben einem betonten.
struct QuietButton: View {
    let title: String
    let action: () -> Void
    @Local private var hover = false
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink).padding(.horizontal, 14).padding(.vertical, 6).contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .scaleEffect(hover ? 1.03 : 1)
        .onHover { h in withAnimation(Theme.spring) { hover = h } }
    }
}

struct Hairline: View { var body: some View { Rectangle().fill(Theme.ink.opacity(0.08)).frame(height: 1) } }

struct Keycap: View {
    let text: String
    var down = false
    var body: some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.6))
                RoundedRectangle(cornerRadius: 8).fill(Theme.accent.opacity(down ? 0.35 : 0))
                RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.ink.opacity(0.14), lineWidth: 0.5)
            }
            .scaleEffect(down ? 0.9 : 1)
            .offset(y: down ? 1 : 0)
    }
}

/// Blinkende Schreibmarke.
struct Caret: View {
    var running: Bool
    @Environment(\.accessibilityReduceMotion) private var calm
    @Environment(\.self) private var env
    var body: some View {
        Loop(kind: .blink, color: Theme.ember.resolve(in: env).cgColor, running: running && !calm).frame(width: 2, height: 20)
    }
}

private struct Loop: NSViewRepresentable {
    enum Kind { case ripple, blink }
    let kind: Kind
    let color: CGColor
    let running: Bool

    final class Box: NSView {
        let dot = CALayer(), ring = CALayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.addSublayer(ring); layer?.addSublayer(dot)
        }
        required init?(coder: NSCoder) { nil }
        override func layout() {
            super.layout()
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for l in [dot, ring] { l.bounds = bounds; l.position = CGPoint(x: bounds.midX, y: bounds.midY); l.cornerRadius = min(bounds.width, bounds.height) / 2 }
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> Box { Box() }
    func updateNSView(_ v: Box, context: Context) {
        v.dot.backgroundColor = color
        v.ring.backgroundColor = color
        v.ring.isHidden = kind != .ripple || !running
        let has = v.dot.animation(forKey: "loop") != nil || v.ring.animation(forKey: "loop") != nil
        guard running else { v.dot.removeAllAnimations(); v.ring.removeAllAnimations(); return }
        guard !has else { return }
        switch kind {
        case .blink:
            let a = CAKeyframeAnimation(keyPath: "opacity")
            a.values = [1, 1, 0, 0, 1]; a.keyTimes = [0, 0.45, 0.55, 0.9, 1]; a.duration = 1.1; a.repeatCount = .infinity
            a.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 20, preferred: 15)
            v.dot.add(a, forKey: "loop")
        case .ripple:
            let s = CABasicAnimation(keyPath: "transform.scale"); s.fromValue = 1; s.toValue = 2.6
            let o = CABasicAnimation(keyPath: "opacity"); o.fromValue = 0.45; o.toValue = 0
            let g = CAAnimationGroup(); g.animations = [s, o]; g.duration = 1.8; g.repeatCount = .infinity
            g.timingFunction = CAMediaTimingFunction(name: .easeOut)
            g.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
            v.ring.add(g, forKey: "loop")
        }
    }
}
