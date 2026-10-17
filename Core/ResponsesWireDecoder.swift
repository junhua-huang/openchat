import Foundation

// Identify the body itself: valid SSE can arrive without an SSE Content-Type.
// JSON errors must be decoded before reporting a generic format mismatch.
// Completion still requires a real response.completed event, never just HTTP 200.
struct ResponsesWireDecoder {
    private enum Mode { case unknown, sse, json }
    let response: HTTPURLResponse?
    private var mode: Mode = .unknown
    private var parser = SSEParser()
    private var json = ""
    private var jsonBytes = 0
    private var deliveredText = false
    private(set) var completed = false
    private(set) var output: [[String: Any]] = []

    init(response: HTTPURLResponse?) { self.response = response }

    @MainActor mutating func push(_ raw: String, onDelta: (String) -> Void) throws -> Bool {
        if completed { return true }
        let line = raw.hasPrefix("\u{FEFF}") ? String(raw.dropFirst()) : raw
        if mode == .unknown {
            let first = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if first.isEmpty { return false }
            if ["data:", "event:", ":", "id:", "retry:"].contains(where: { first.hasPrefix($0) }) { mode = .sse }
            else if first.hasPrefix("{") || first.hasPrefix("[") { mode = .json }
            else {
                throw ResponseFailure.make(response: response, shape: first.hasPrefix("<") ? "html" : "text",
                    fallback: "服务返回了非聊天内容，请重试或复制诊断信息反馈。")
            }
        }
        switch mode {
        case .sse:
            if let payload = try parser.push(line) { return try consume(payload, shape: "sse", onDelta: onDelta) }
        case .json:
            jsonBytes += line.utf8.count + 1
            guard jsonBytes <= 1_000_000 else { throw ResponseFailure.make(response: response, shape: "json_too_large") }
            json += line + "\n"
            if let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
                guard let value = object as? [String: Any] else { throw ResponseFailure.make(response: response, shape: "json_other") }
                let payload = json
                json = ""; jsonBytes = 0
                let type = value["type"] as? String ?? ""
                guard type.hasPrefix("response.") || type == "error" else {
                    let shape = value["error"] != nil ? "json_error" : value["detail"] != nil ? "json_detail" : "json_response"
                    throw ResponseFailure.make(response: response, shape: shape, object: value)
                }
                return try consume(payload, shape: "json_event", onDelta: onDelta)
            }
        case .unknown: break
        }
        return false
    }

    @MainActor mutating func finish(onDelta: (String) -> Void) throws -> Bool {
        if completed { return true }
        if mode == .sse, let payload = parser.finish(), try consume(payload, shape: "sse", onDelta: onDelta) { return true }
        let shape = mode == .sse ? "sse_interrupted" : mode == .json ? "json_incomplete" : "empty"
        throw ResponseFailure.make(response: response, shape: shape,
            fallback: "回复连接提前结束，未收到完成事件。已保留收到的内容，可以重试。")
    }

    @MainActor private mutating func consume(_ payload: String, shape: String, onDelta: (String) -> Void) throws -> Bool {
        if let response = response, !(200..<300).contains(response.statusCode) {
            let object = payload.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            throw ResponseFailure.make(response: response, shape: shape, object: object)
        }
        let done = try ResponsesClient.handle(payload, response: response, shape: shape) { text in
            onDelta(text)
        }
        if done, let data = payload.data(using: .utf8),
           let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = event["response"] as? [String: Any] { output = value["output"] as? [[String: Any]] ?? [] }
        // Completed-only terminal events may contain the entire output; do not
        // duplicate it when deltas already delivered the text.
        if done, !deliveredText, let data = payload.data(using: .utf8),
           let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = event["response"] as? [String: Any], let output = value["output"] as? [[String: Any]] {
            for item in output where item["type"] as? String == "message" {
                for content in item["content"] as? [[String: Any]] ?? [] {
                    if content["type"] as? String == "output_text", let text = content["text"] as? String { onDelta(text) }
                    else if content["type"] as? String == "refusal", let text = content["refusal"] as? String { onDelta(text) }
                }
            }
        }
        if !done, let data = payload.data(using: .utf8),
           let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           ["response.output_text.delta", "response.refusal.delta"].contains(event["type"] as? String ?? ""),
           let delta = event["delta"] as? String, !delta.isEmpty { deliveredText = true }
        completed = done
        return done
    }
}
