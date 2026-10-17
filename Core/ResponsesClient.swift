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

    static func request(token: String, model: String, history: [ChatMessage]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "store": false, "stream": true,
            "input": history.filter { $0.status == .complete }.map { ["role": $0.role.rawValue, "content": $0.text] }
        ])
        return request
    }

    @MainActor
    static func stream(token: String, model: String, history: [ChatMessage], onDelta: (String) -> Void) async throws {
        let request = try request(token: token, model: model, history: history)
        let (bytes, response) = try await HTTP.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ResponseFailure.make(response: nil, shape: "non_http")
        }
        var decoder = ResponsesWireDecoder(response: http)
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if try decoder.push(line, onDelta: onDelta) { return }
        }
        _ = try decoder.finish(onDelta: onDelta)
    }

    @MainActor
    static func handle(_ payload: String, response: HTTPURLResponse? = nil, shape: String = "sse", onDelta: (String) -> Void) throws -> Bool {
        if payload == "[DONE]" { return false }
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { throw ResponseFailure.make(response: response, shape: "invalid_event") }
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            if let delta = event["delta"] as? String { onDelta(delta) }
        case "response.completed":
            guard let completedResponse = event["response"] as? [String: Any], completedResponse["status"] as? String == "completed" else {
                throw ResponseFailure.make(response: response, shape: shape, object: event)
            }
            return true
        case "response.failed", "response.incomplete", "error":
            throw ResponseFailure.make(response: response, shape: shape, object: event)
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
