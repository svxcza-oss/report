import Foundation
import Security

/// 사용자가 넣은 AI API 키는 이 기기의 키체인에만 둬요. 저장 파일(state.json)이나 위젯에는 들어가지 않아요.
enum KeyStore {
    private static let service = "hanju.stack.ai"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    @discardableResult static func set(_ account: String, _ value: String) -> Bool {
        remove(account)
        guard !value.isEmpty else { return true }
        var query = base(account)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }
}
