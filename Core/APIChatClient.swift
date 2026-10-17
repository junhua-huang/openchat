import Foundation

// Do not forward a user's API key to redirect targets, including the same host.
private final class APIRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum APIChatClient {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config, delegate: APIRedirectGuard(), delegateQueue: nil)
    }()

    static func request(connection: APIConnection, path: String) throws -> URLRequest {
        let base = try APIConnection.normalizedURL(connection.baseURL)
        let key = connection.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw AppFailure.message("请填写有效的 API Key。")
        }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        return request
    }

    static func models(connection: APIConnection) async throws -> [ModelChoice] {
        let request = try request(connection: connection, path: "models")
        let (data, response) = try await session.data(for: request)
        try check(response)
        return try decodeModels(data)
    }

    static func decodeModels(_ data: Data) throws -> [ModelChoice] {
        struct Catalog: Decodable {
            struct Item: Decodable { let id: String }
            let data: [Item]
        }
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        var seen = Set<String>()
        return catalog.data.filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
            .map { ModelChoice(slug: $0.id, display_name: $0.id, visibility: nil) }
            .sorted { $0.slug < $1.slug }
    }

    static func chatRequest(connection: APIConnection, model: String, history: [ChatMessage], effort: ReasoningEffort = .automatic) throws -> URLRequest {
        try ReasoningSupport.validate(effort, model: model, connection: connection)
        var request = try request(connection: connection, path: "chat/completions")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": model, "stream": true,
            "messages": history.filter { $0.status == .complete }.map { ["role": $0.role.rawValue, "content": $0.text] }
        ]
        if effort != .automatic { body["reasoning_effort"] = effort.rawValue }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    @MainActor
    static func stream(connection: APIConnection, model: String, history: [ChatMessage], effort: ReasoningEffort = .automatic,
                       onDelta: (String) -> Void) async throws {
        let request = try chatRequest(connection: connection, model: model, history: history, effort: effort)
        let (bytes, response) = try await session.bytes(for: request)
        try check(response)
        guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw AppFailure.message("服务商未返回 SSE 流，请确认接口支持 Chat Completions 流式输出。")
        }
        var parser = SSEParser()
        var state = ChatCompletionStreamState()
        for try await line in SSEByteLines(base: bytes) {
            try Task.checkCancellation()
            if let payload = try parser.push(line), try state.consume(payload, onDelta: onDelta) { return }
        }
        if let payload = parser.finish(), try state.consume(payload, onDelta: onDelta) { return }
        throw AppFailure.message("API 连接提前结束，回复未完成。可以重试生成。")
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AppFailure.message("API 返回了无效响应。") }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 300..<400: throw AppFailure.message("API 地址发生重定向，请在设置中填写服务商的最终 HTTPS 基础地址。")
            case 401: throw AppFailure.message("API Key 无效或已过期，请在 API 连接中更新。")
            case 403: throw AppFailure.message("API 服务商拒绝访问，请检查密钥权限和模型访问权限。")
            case 404: throw AppFailure.message("API 路径或模型不存在，请检查基础地址和模型 ID。")
            case 429: throw AppFailure.message("API 限流或余额不足，请查看服务商控制台。")
            default: throw AppFailure.message("API 请求失败（HTTP \(http.statusCode)），请检查服务商状态和接口兼容性。")
            }
        }
    }
}

struct ChatCompletionStreamState {
    private(set) var completed = false
    mutating func consume(_ payload: String, onDelta: (String) -> Void) throws -> Bool {
        if completed { return true }
        guard payload != "[DONE]" else { throw AppFailure.message("API 未提供完成状态，回复可能被中断。") }
        guard let data = payload.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppFailure.message("无法解析 API 流式响应。")
        }
        if event["error"] != nil { throw AppFailure.message("API 返回错误，请检查模型、密钥权限和服务商余额。") }
        guard let choices = event["choices"] as? [[String: Any]] else {
            throw AppFailure.message("接口返回格式不兼容 Chat Completions。")
        }
        guard let choice = choices.first(where: { ($0["index"] as? Int ?? 0) == 0 }) else { return false }
        if let delta = choice["delta"] as? [String: Any] {
            if let text = delta["content"] as? String { onDelta(text) }
            if let refusal = delta["refusal"] as? String { onDelta(refusal) }
        }
        guard let reason = choice["finish_reason"] as? String else { return false }
        switch reason {
        case "stop": completed = true; return true
        case "length": throw AppFailure.message("回复达到服务商输出长度上限，已保留收到的内容。")
        case "content_filter": throw AppFailure.message("回复被服务商的内容策略中断。")
        case "tool_calls", "function_call": throw AppFailure.message("该模型请求调用工具，当前 API 聊天只支持文本回复。")
        default: throw AppFailure.message("服务商未正常完成回复，已保留收到的内容。")
        }
    }
}
