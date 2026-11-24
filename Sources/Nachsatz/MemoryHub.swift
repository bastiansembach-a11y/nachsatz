import AppKit
import CryptoKit
import NachsatzCore
import Security

/// Gedächtnis der App: Schlüssel im Schlüsselbund, Notizen verschlüsselt auf der Platte.
@MainActor
final class MemoryHub {
    static let shared = MemoryHub()
    let store = MemoryStore(days: Prefs.shared.memoryDays)
    private(set) var problem: String?
    private var opening = false

    var usable: Bool { Prefs.shared.memoryOn }

    func open() {
        guard !opening else { return }
        opening = true
        Task {
            // Der Schlüsselbund kann nachfragen, deshalb nie auf dem Hauptthread.
            let result = await Task.detached { Self.loadKey() }.value
            switch result {
            case .success(let key):
                do { try await store.open(key: key); problem = nil }
                catch { problem = "Gedächtnis passt nicht zum Schlüssel" }
            case .failure(let e): problem = e.message
            }
        }
    }

    func add(_ text: String, app: String) async {
        guard usable, problem == nil else { return }
        await store.add(text, app: app)
    }

    /// Passende Notizen und übliche eigene Wörter für diese Stelle, je nach eingestellter Stärke.
    func personal(for text: String, field: String, app: String) async -> (notes: String, prefer: [(word: String, bias: Double)]) {
        let level = Prefs.shared.style
        guard usable, problem == nil, level > 0 else { return ("", []) }
        return (await store.context(for: text, field: field, app: app, level: level), await store.preferred(for: text, level: level))
    }

    struct KeyProblem: Error { let message: String }

    private nonisolated static func loadKey() -> Result<SymmetricKey, KeyProblem> {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "local.nachsatz.memory", kSecAttrAccount as String: "key"]
        var q = base
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess, let d = out as? Data, d.count == 32 { return .success(SymmetricKey(data: d)) }
        guard status == errSecItemNotFound else { return .failure(.init(message: "Schlüsselbund-Zugriff für Gedächtnis fehlt")) }
        if FileManager.default.fileExists(atPath: MemoryStore.defaultURL.path) {
            return .failure(.init(message: "Schlüssel für Gedächtnis fehlt"))
        }
        let key = SymmetricKey(size: .bits256)
        var add = base
        add[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrLabel as String] = "Nachsatz Gedächtnis"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
            ? .success(key) : .failure(.init(message: "Schlüssel konnte nicht angelegt werden"))
    }
}
