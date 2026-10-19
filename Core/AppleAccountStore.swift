import Foundation
import Security

enum AppleAccountStore {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "LiaoChat") + ".apple-sign-in",
         kSecAttrAccount as String: "identity-v1"]
    }

    static func load() throws -> AppleAccount? {
        var query = self.query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppFailure.message("无法读取 Apple 登录资料，请解锁设备后重试。")
        }
        let value = try JSONDecoder().decode(AppleAccount.self, from: data)
        guard !value.userID.isEmpty else { throw AppFailure.message("Apple 登录资料不完整。") }
        return value
    }

    static func save(_ account: AppleAccount) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(account),
                                       kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw AppFailure.message("无法安全保存 Apple 登录资料，请重试。")
            }
        } else if status != errSecSuccess {
            throw AppFailure.message("无法更新 Apple 登录资料，请重试。")
        }
    }

    static func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppFailure.message("无法移除 Apple 登录资料，请解锁设备后重试。")
        }
    }
}
