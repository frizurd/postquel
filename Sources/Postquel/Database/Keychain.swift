import Foundation
import Security

/// Connection passwords as generic passwords in the login keychain.
enum Keychain {
    private static let service = "dev.postquel.connection"

    static func password(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return legacyPassword(account: account)
        }
        return String(data: data, encoding: .utf8)
    }

    /// A password saved before the app was renamed: moved to Postquel's own entry on first use.
    /// macOS may ask once whether Postquel can read the old item.
    private static func legacyPassword(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: LegacyMigration.keychainService,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let password = String(data: data, encoding: .utf8)
        else { return nil }
        setPassword(password, account: account)
        let old: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: LegacyMigration.keychainService,
            kSecAttrAccount: account,
        ]
        SecItemDelete(old as CFDictionary)
        return password
    }

    static func setPassword(_ password: String, account: String) {
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let data = Data(password.utf8)
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = match
            item[kSecValueData] = data
            item[kSecAttrLabel] = "Postquel – \(account)"
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func deletePassword(account: String) {
        let match: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(match as CFDictionary)
    }
}
