import Foundation
import CryptoKit
import Security

enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

enum EncodingTools {
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decodeBase64URL(_ string: String) throws -> Data {
        let raw = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: raw + String(repeating: "=", count: (4 - raw.count % 4) % 4)) else {
            throw AppFailure.message("登录响应的编码无效。")
        }
        return data
    }
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw AppFailure.message("无法生成安全的登录参数。")
        }
        return base64URL(Data(bytes))
    }
    static func challenge(_ verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
    }
}

enum HTTP {
    // Ephemeral sessions keep OAuth/API credentials and responses out of URL caches.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()
    static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AppFailure.message("服务器没有返回有效响应。") }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw AppFailure.message("登录已失效，请在账户页面重新连接。")
            case 403: throw AppFailure.message("当前账户、工作空间或授权不允许此请求。请检查套餐使用权限。")
            case 429: throw AppFailure.message("请求过于频繁或套餐额度已用完，请稍后重试，并在 ChatGPT 中查看用量。")
            default: throw AppFailure.message("请求失败（HTTP \(http.statusCode)）。请稍后重试。")
            }
        }
    }
}

struct TokenReply: Decodable {
    let access_token: String
    let refresh_token: String?
    let id_token: String?
    let token_type: String
    let expires_in: Double
    let scope: String?
}

struct Tokens: Codable {
    var access: String
    var refresh: String?
    var idToken: String?
    var expiresAt: Date
    var scopes: [String]
    var permitsInference: Bool { scopes.contains("chatgpt.tokens.use.direct") && scopes.contains("resource.invoke") }
    init(reply: TokenReply, previous: Tokens? = nil) throws {
        guard reply.token_type.lowercased() == "bearer", !reply.access_token.isEmpty,
              reply.expires_in > 0, reply.expires_in.isFinite else {
            throw AppFailure.message("服务器返回了无效的授权令牌。")
        }
        access = reply.access_token
        refresh = reply.refresh_token ?? previous?.refresh
        idToken = reply.id_token ?? previous?.idToken
        expiresAt = Date().addingTimeInterval(reply.expires_in)
        scopes = reply.scope.map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
    }
}

struct Account: Codable, Identifiable {
    let id: UUID
    let clientID: String
    let subject: String
    var email: String?
    var tokens: Tokens?
    var label: String { "\(email ?? (subject.isEmpty ? "待完成的连接" : "ChatGPT 账户")) · \(String(id.uuidString.prefix(4)))" }
}

struct CredentialVault: Codable {
    var hostID: String
    var accounts: [Account] = []
    var activeID: UUID?
}

enum SecureStore {
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "LiaoChat") + ".credentials",
         kSecAttrAccount as String: "vault-v1"]
    }
    static func load() throws -> CredentialVault? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppFailure.message("无法读取设备安全存储（\(status)）。请解锁设备后重试。")
        }
        return try JSONDecoder().decode(CredentialVault.self, from: data)
    }
    static func save(_ value: CredentialVault) throws {
        let attrs: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(value),
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if result == errSecItemNotFound {
            var new = query
            attrs.forEach { new[$0.key] = $0.value }
            let status = SecItemAdd(new as CFDictionary, nil)
            guard status == errSecSuccess else { throw AppFailure.message("无法保存登录状态（\(status)）。") }
        } else if result != errSecSuccess { throw AppFailure.message("无法更新登录状态（\(result)）。") }
    }
}
