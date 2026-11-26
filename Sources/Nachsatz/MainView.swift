import AppKit
import SwiftUI

struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var prefs = Prefs.shared
    @Environment(\.accessibilityReduceMotion) private var calm

    var body: some View {
        // Einmal gelesen und weitergereicht, damit Seitenleiste und Inhalt nie auseinanderlaufen.
        let page = model.page
        ZStack {
            Paper()
            HStack(spacing: 0) {
                Sidebar(page: page, trusted: model.trusted, broken: model.modelBroken, enabled: prefs.enabled, moving: model.visible,
                        select: { model.page = $0 }, toggle: { prefs.enabled.toggle() })
                    .frame(width: 204)
                    .padding(.leading, 8).padding(.vertical, 8)
                PageScroll(page: page, model: model, prefs: prefs)
                    .id(page)
                    .transition(.opacity.animation(.easeOut(duration: calm ? 0 : 0.18)))
            }
            .ignoresSafeArea()
        }
        .frame(minWidth: 800, minHeight: 560)
        .tint(Theme.accent)
    }
}

private struct PageScroll: View {
    let page: Page
    let model: AppModel
    let prefs: Prefs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(page.title)
                    .font(.system(size: 30, weight: .medium, design: .serif))
                    .foregroundStyle(Theme.ink)
                    .entrance(0)
                content
            }
            .padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 28)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .home: HomePage(model: model, prefs: prefs)
        case .suggest: SuggestPage(model: model, prefs: prefs)
        case .proof: ProofPage(prefs: prefs)
        case .memory: MemoryPage(model: model, prefs: prefs)
        case .apps: AppsPage(model: model, prefs: prefs)
        case .general: GeneralPage(model: model, prefs: prefs)
        }
    }
}

private struct Sidebar: View {
    let page: Page
    let trusted: Bool
    let broken: Bool
    let enabled: Bool
    let moving: Bool
    let select: (Page) -> Void
    let toggle: () -> Void
    @Local private var hover: Page?
    private let rowHeight: CGFloat = 38

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(running: moving).padding(.horizontal, 12).padding(.top, 52).padding(.bottom, 14)
            VStack(spacing: 4) {
                ForEach(Page.allCases) { p in row(p) }
            }
            .background(alignment: .top) {
                Capsule().fill(Theme.accent.opacity(0.15))
                    .frame(height: rowHeight)
                    .offset(y: CGFloat(Page.allCases.firstIndex(of: page) ?? 0) * (rowHeight + 4))
                    .animation(Theme.spring, value: page)
            }
            Spacer()
            status
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
    }

    private func row(_ p: Page) -> some View {
        let on = p == page
        return Button { select(p) } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon).frame(width: 20).foregroundStyle(on ? Theme.accent : Theme.ink.opacity(0.65))
                Text(p.title).foregroundStyle(Theme.ink.opacity(on ? 1 : 0.8))
                Spacer()
            }
            .font(.system(size: 13, weight: on ? .semibold : .regular))
            .padding(.horizontal, 12)
            .frame(height: rowHeight)
            .background(Capsule().fill(Theme.ink.opacity(hover == p && !on ? 0.05 : 0)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { h in if h { hover = p } else if hover == p { hover = nil } }
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var status: some View {
        let text = !trusted ? "Freigabe fehlt" : (!enabled ? "Pausiert" : (broken ? "Modell fehlt" : "Aktiv"))
        let color = !trusted || broken ? Theme.ember : (enabled ? Theme.good : Theme.ghost)
        return Button { if trusted { toggle() } else { select(.home) } } label: {
            HStack(spacing: 9) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
                Spacer()
                if trusted { Image(systemName: enabled ? "pause.fill" : "play.fill").font(.system(size: 10)).foregroundStyle(Theme.muted).contentTransition(.symbolEffect(.replace)) }
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .background(Capsule().fill(color.opacity(0.14)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .animation(Theme.spring, value: text)
    }
}

/// Name mit blinkender Schreibmarke und grauem Nachsatz.
private struct Wordmark: View {
    let running: Bool
    var body: some View {
        HStack(spacing: 1) {
            Text("Nach").foregroundStyle(Theme.ink)
            Caret(running: running)
            Text("satz").foregroundStyle(Theme.ghost)
        }
        .font(.system(size: 21, weight: .medium, design: .serif))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nachsatz")
    }
}
