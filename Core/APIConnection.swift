import Foundation
import Combine
import Security

struct APIConnection: Codable, Identifiable, Equatable {
    var id = UUID()
    var revision = UUID()
    var name: String
    var baseURL: String
    var apiKey: String
    var modelIDs: [String]

    var host: String { URL(string: baseURL)?.host ?? baseURL }

    static func normalizedURL(_ input: String) throws -> URL {
        guard var parts = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw AppFailure.message("请输入 HTTPS API 基础地址，不要包含密钥、查询参数或片段。")
        }
        parts.scheme = "https"
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        for suffix in ["/chat/completions", "/models"] where parts.path.hasSuffix(suffix) {
            parts.path.removeLast(suffix.count)
            break
        }
        guard let url = parts.url else { throw AppFailure.message("API 地址无效。") }
        return url
    }

    static func parseModels(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.components(separatedBy: CharacterSet(charactersIn: ",，\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func validated() throws -> APIConnection {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        result.baseURL = try Self.normalizedURL(baseURL).absoluteString
        result.modelIDs = Self.parseModels(modelIDs.joined(separator: "\n"))
        guard !result.name.isEmpty, !result.apiKey.isEmpty, !result.modelIDs.isEmpty else {
            throw AppFailure.message("请填写连接名称、API Key 和至少一个模型 ID。")
        }
        guard !result.apiKey.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw AppFailure.message("API Key 不能包含空格或换行。")
        }
        return result
    }
}

private struct APIConnectionVault: Codable {
    var connections: [APIConnection] = []
    var activeID: UUID?
}

@MainActor
final class APIConnections: ObservableObject {
    @Published private(set) var connections: [APIConnection] = []
    @Published private(set) var activeID: UUID?
    @Published private(set) var isReady = false
    @Published var errorText: String?
    var active: APIConnection? { connections.first { $0.id == activeID } }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "LiaoChat") + ".api-connections",
         kSecAttrAccount as String: "connections-v1"]
    }

    init() { reload() }

    func reload() {
        do {
            var q = query
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &item)
            if status == errSecItemNotFound {
                connections = []; activeID = nil; isReady = true; errorText = nil; return
            }
            guard status == errSecSuccess, let data = item as? Data else {
                throw AppFailure.message("无法读取 API 钥匙串，请解锁设备后重试。")
            }
            let vault = try JSONDecoder().decode(APIConnectionVault.self, from: data)
            connections = vault.connections
            activeID = vault.activeID
            isReady = true
            errorText = nil
        } catch { isReady = false; errorText = error.localizedDescription }
    }

    func save(_ connection: APIConnection) throws {
        var value = try connection.validated()
        value.revision = UUID()
        var next = connections
        if let i = next.firstIndex(where: { $0.id == value.id }) { next[i] = value }
        else { next.append(value) }
        try persist(next, active: activeID)
    }

    func select(_ id: UUID?) throws {
        guard id == nil || connections.contains(where: { $0.id == id }) else {
            throw AppFailure.message("这个 API 连接已被删除。")
        }
        if id == activeID { return }
        try persist(connections, active: id)
    }

    func delete(_ id: UUID) throws {
        try persist(connections.filter { $0.id != id }, active: activeID == id ? nil : activeID)
    }

    private func persist(_ next: [APIConnection], active: UUID?) throws {
        guard isReady else { throw AppFailure.message("API 安全存储尚未就绪，请先重试读取。") }
        let vault = APIConnectionVault(connections: next, activeID: active)
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(vault),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw AppFailure.message("无法保存 API 连接，请检查设备钥匙串。")
            }
        } else if status != errSecSuccess { throw AppFailure.message("无法更新 API 连接。") }
        connections = next
        activeID = active
    }
}
