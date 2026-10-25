import Foundation
import Security

/**
 * Access tokens live in the iOS Keychain, sealed by the system, never in a
 * preferences file. Each signed-in account has its own.
 *
 * A sideloaded app can lose the Keychain: re-signed with another Apple ID it
 * can no longer read what it stored, and an unsigned build (the simulator)
 * can't use it at all. Then the token goes to a file only this app can read,
 * protected by the iPhone's passcode until first unlock, and kept out of
 * backups, so signing in still works.
 */
enum Keychain {
    private static let service = "app.kinema.ios.servers"

    private static let fallbackFolder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("Tokens", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }()

    private static func fallbackFile(_ account: String) -> URL {
        let safe = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? account
        return fallbackFolder.appendingPathComponent(safe)
    }

    @discardableResult
    static func set(_ secret: String, for account: String) -> Bool {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess {
            try? FileManager.default.removeItem(at: fallbackFile(account))
            return true
        }
        do {
            try data.write(to: fallbackFile(account), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            return false
        }
    }

    /** Nil when there is nothing stored, or it cannot be read. */
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return String(data: data, encoding: .utf8)
        }
        guard let data = try? Data(contentsOf: fallbackFile(account)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        try? FileManager.default.removeItem(at: fallbackFile(account))
    }
}
