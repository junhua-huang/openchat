import Foundation

struct ModelChoice: Decodable, Identifiable {
    let slug: String
    let display_name: String
    let visibility: String?
    var id: String { slug }
}

enum ResponsesClient {
    static func models(token: String) async throws -> [ModelChoice] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let (data, response) = try await HTTP.session.data(for: request)
        try HTTP.check(response)
        struct Catalog: Decodable { let models: [ModelChoice] }
        return try JSONDecoder().decode(Catalog.self, from: data).models.filter { $0.visibility == "list" }
    }

    @MainActor
    static func stream(token: String, model: String, history: [ChatMessage], onDelta: (String) -> Void) async throws {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "store": false, "stream": true,
            "instructions": "You are a helpful assistant. Respond in the user's language unless asked otherwise.",
            "input": history.filter { $0.status == .complete }.map { ["role": $0.role.rawValue, "content": $0.text] }
        ])
        let (bytes, response) = try await HTTP.session.bytes(for: request)
        try HTTP.check(response)
        guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
            throw AppFailure.message("服务器没有返回预期的流式响应。")
        }
        var parser = SSEParser()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let event = try parser.push(line) {
                if try handle(event, onDelta: onDelta) { return }
            }
        }
        if let event = parser.finish(), try handle(event, onDelta: onDelta) { return }
        throw AppFailure.message("回复连接提前结束。这条回复没有被标记为完成，请重试。")
    }

    @MainActor
    static func handle(_ payload: String, onDelta: (String) -> Void) throws -> Bool {
        if payload == "[DONE]" { return false }
        guard let data = payload.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { throw AppFailure.message("无法解析流式响应。") }
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            if let delta = event["delta"] as? String { onDelta(delta) }
        case "response.completed":
            guard let response = event["response"] as? [String: Any], response["status"] as? String == "completed" else {
                throw AppFailure.message("服务器没有确认回复完成。")
            }
            return true
        case "response.failed", "response.incomplete", "error":
            throw AppFailure.message("模型没有完成回复。请检查所选模型与套餐权限后重试。")
        default: break
        }
        return false
    }
}

struct SSEParser {
    private var data: [String] = []
    private var size = 0
    mutating func push(_ line: String) throws -> String? {
        if line.isEmpty { return finish() }
        guard line.hasPrefix("data:") else { return nil }
        let raw = String(line.dropFirst(5))
        let part = raw.hasPrefix(" ") ? String(raw.dropFirst()) : raw
        size += part.utf8.count
        guard size < 4_000_000 else { throw AppFailure.message("单个响应事件过大，请重新开始对话。") }
        data.append(part)
        return nil
    }
    mutating func finish() -> String? {
        defer { data = []; size = 0 }
        return data.isEmpty ? nil : data.joined(separator: "\n")
    }
}
