import Foundation
import Security

/// Refresh Token in der Keychain (SPEC §5).
///
/// Der Access Token liegt bewusst nirgends — weder hier noch in den
/// Einstellungen noch in `UserDefaults`. Er lebt nur im Speicher des
/// `AuthClient`.
struct TokenStore: Sendable {
    static let service = "de.baz.agfeopresence.refreshtoken"

    /// Die Client-ID als Konto: wechselt die Entra-Registrierung, wird nicht
    /// versehentlich ein Token der alten weiterverwendet.
    let account: String

    func save(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var insert = query
            insert.merge(attributes) { current, _ in current }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            if addStatus != errSecSuccess {
                Log.error(.auth, "Refresh Token konnte nicht abgelegt werden (OSStatus \(addStatus))")
            }
        default:
            Log.error(.auth, "Refresh Token konnte nicht aktualisiert werden (OSStatus \(status))")
        }
    }

    func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            Log.info(.auth, "Kein Refresh Token in der Keychain")
            return nil
        case errSecInteractionNotAllowed:
            // Der Schlüsselbund ist gesperrt. Kein Grund, die Anmeldung
            // für verloren zu erklären.
            Log.error(.auth, "Schlüsselbund gesperrt — Refresh Token gerade nicht lesbar")
            return nil
        case errSecAuthFailed:
            // Tritt auf, wenn die App mit einem anderen Zertifikat signiert
            // wurde als beim Ablegen: Die Zugriffsliste des Eintrags hängt an
            // der Signatur.
            Log.error(.auth, "Zugriff auf den Refresh Token verweigert — "
                      + "wurde die App neu signiert?")
            return nil
        default:
            Log.error(.auth, "Keychain nicht lesbar (OSStatus \(status))")
            return nil
        }
    }

    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Log.error(.auth, "Refresh Token konnte nicht gelöscht werden (OSStatus \(status))")
        }
    }
}
