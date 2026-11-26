import Foundation
import Security

enum OpenCodeGoKeychain {
    private static let item: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.erenshwang.petquotadisplay.opencode-go",
        kSecAttrAccount as String: "api-key",
    ]

    static func read() throws -> String? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return key
    }

    static func save(_ key: String) throws {
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let updateStatus = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            let newItem = item.merging(attributes) { _, value in value }
            try check(SecItemAdd(newItem as CFDictionary, nil))
        } else {
            try check(updateStatus)
        }
    }

    static func remove() throws {
        let status = SecItemDelete(item as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}
