import AppKit

/// Fängt Tastendrücke systemweit ab. Zeichnet nichts auf und speichert nichts.
@MainActor
final class KeyTap {
    static let marker: Int64 = 0x4E534154 // eigene Ereignisse erkennen
    /// Rückgabe true = Taste schlucken.
    var onKey: ((CGEvent) -> Bool)?
    var onPointer: (() -> Void)?
    /// Rückgabe true = Ereignis schlucken (Klick auf eine Unterstreichung).
    var onMouse: ((CGEventType, CGEvent) -> Bool)?
    var onScroll: (() -> Void)?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var running: Bool { port != nil }

    func start() -> Bool {
        guard port == nil else { return true }
        let mask: CGEventMask = [CGEventType.keyDown, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .scrollWheel]
            .reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
        guard let p = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, info in
                let me = Unmanaged<KeyTap>.fromOpaque(info!).takeUnretainedValue()
                let swallow = MainActor.assumeIsolated { me.handle(type, event) }
                return swallow ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        port = p
        source = CFMachPortCreateRunLoopSource(nil, p, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: p, enable: true)
        return true
    }

    func stop() {
        guard let p = port else { return }
        CGEvent.tapEnable(tap: p, enable: false)
        CFMachPortInvalidate(p)
        if let s = source { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        port = nil; source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let p = port { CGEvent.tapEnable(tap: p, enable: true) }
            return false
        case .keyDown:
            if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return false }
            return onKey?(event) ?? false
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return false }
            if onMouse?(type, event) == true { return true }
            if type == .leftMouseDown { onPointer?() }
            return false
        case .scrollWheel:
            onScroll?()
            return false
        default:
            onPointer?()
            return false
        }
    }

    static func characters(_ e: CGEvent) -> String {
        var n = 0
        var buf = [UniChar](repeating: 0, count: 8)
        e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &n, unicodeString: &buf)
        return String(utf16CodeUnits: buf, count: n)
    }

    /// Tippt Text in die aktive App, in Stücken bis 20 UTF-16-Einheiten.
    static func type(_ text: String) {
        let src = CGEventSource(stateID: .privateState)
        var piece: [UniChar] = []
        func flush() {
            guard !piece.isEmpty else { return }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: piece.count, unicodeString: piece)
                e.setIntegerValueField(.eventSourceUserData, value: marker)
                e.post(tap: .cgSessionEventTap)
            }
            piece = []
        }
        for ch in text {
            let u = Array(String(ch).utf16)
            if piece.count + u.count > 20 { flush() }
            piece += u
        }
        flush()
    }
}
