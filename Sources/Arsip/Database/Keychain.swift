import Foundation
import Security

/// Connection passwords as generic passwords in the login keychain.
enum Keychain {
    private static let service = "dev.arsip.connection"

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
            return nil
        }
        return String(data: data, encoding: .utf8)
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
            item[kSecAttrLabel] = "Arsip – \(account)"
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
