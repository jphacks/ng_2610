import Foundation
import Security

struct Pairing: Equatable, Sendable {
    /// wss://host/public/device — never logged together with the token.
    var endpoint: URL
    var token: String

    /// https://host — the single trusted origin for language packs and shortcut setup.
    var origin: URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = endpoint.host
        c.port = endpoint.port
        return c.url!
    }

    /// Accepts only `wss://<host>/public/device?token=<base64url>`.
    static func parse(_ text: String) -> Pairing? {
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              comps.scheme == "wss", let host = comps.host, !host.isEmpty, comps.path == "/public/device",
              let token = comps.queryItems?.first(where: { $0.name == "token" })?.value,
              token.range(of: #"^[A-Za-z0-9_-]{20,128}$"#, options: .regularExpression) != nil else { return nil }
        var endpoint = URLComponents()
        endpoint.scheme = "wss"
        endpoint.host = host
        endpoint.port = comps.port
        endpoint.path = "/public/device"
        guard let url = endpoint.url else { return nil }
        return Pairing(endpoint: url, token: token)
    }
}

/// Keychain storage, available after first unlock so a locked phone can reconnect (spec §9.1).
enum PairingStore {
    private static let service = "jp.nigeyo.pairing"
    private static let account = "demo-server"

    static func save(_ pairing: Pairing) {
        delete()
        let value = "\(pairing.endpoint.absoluteString)?token=\(pairing.token)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> Pairing? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return Pairing.parse(text)
    }

    static func delete() {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}
