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
    private var collected = ResponsesOutput()
    private(set) var completed = false
    private(set) var output: [[String: Any]] = []

    init(response: HTTPURLResponse?) { self.response = response }

    @MainActor mutating func push(_ raw: String, onActivity: ((ToolActivity) -> Void)? = nil, onDelta: (String) -> Void) throws -> Bool {
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
            if let payload = try parser.push(line) { return try consume(payload, shape: "sse", onActivity: onActivity, onDelta: onDelta) }
        case .json:
            jsonBytes += line.utf8.count + 1
            guard jsonBytes <= 1_000_000 else { throw ResponseFailure.make(response: response, shape: "json_too_large") }
            json += line + "\n"
            if let data = json.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) {
                guard let value = object as? [String: Any] else { throw ResponseFailure.make(response: response, shape: "json_other") }
                json = ""; jsonBytes = 0
                let type = value["type"] as? String ?? ""
                guard type.hasPrefix("response.") || type == "error" else {
                    let shape = value["error"] != nil ? "json_error" : value["detail"] != nil ? "json_detail" : "json_response"
                    throw ResponseFailure.make(response: response, shape: shape, object: value)
                }
                return try consumeEvent(value, shape: "json_event", onActivity: onActivity, onDelta: onDelta)
            }
        case .unknown: break
        }
        return false
    }

    @MainActor mutating func finish(onActivity: ((ToolActivity) -> Void)? = nil, onDelta: (String) -> Void) throws -> Bool {
        if completed { return true }
        if mode == .sse, let payload = parser.finish(), try consume(payload, shape: "sse", onActivity: onActivity, onDelta: onDelta) { return true }
        let shape = mode == .sse ? "sse_interrupted" : mode == .json ? "json_incomplete" : "empty"
        throw ResponseFailure.make(response: response, shape: shape,
            fallback: "回复连接提前结束，未收到完成事件。已保留收到的内容，可以重试。")
    }

    @MainActor private mutating func consume(_ payload: String, shape: String, onActivity: ((ToolActivity) -> Void)?, onDelta: (String) -> Void) throws -> Bool {
        if let response = response, !(200..<300).contains(response.statusCode) {
            let object = try? ResponsesClient.parseEvent(payload, response: response)
            throw ResponseFailure.make(response: response, shape: shape, object: object)
        }
        guard let event = try ResponsesClient.parseEvent(payload, response: response) else { return false }
        return try consumeEvent(event, shape: shape, onActivity: onActivity, onDelta: onDelta)
    }

    @MainActor private mutating func consumeEvent(_ event: [String: Any], shape: String, onActivity: ((ToolActivity) -> Void)?, onDelta: (String) -> Void) throws -> Bool {
        if let response = response, !(200..<300).contains(response.statusCode) {
            throw ResponseFailure.make(response: response, shape: shape, object: event)
        }
        let done = try ResponsesClient.handleEvent(event, response: response, shape: shape, onDelta: onDelta)
        do { try collected.consume(event) }
        catch { throw ResponseFailure.make(response: response, shape: "incomplete_tool_output", fallback: error.localizedDescription) }
        let type = event["type"] as? String ?? ""
        for tool in ["web_search_call", "code_interpreter_call", "image_generation_call"] where type.hasPrefix("response." + tool + ".") {
            let id = event["item_id"] as? String ?? tool
            onActivity?(ToolActivity(id: id, name: tool, state: type.hasSuffix("completed") ? "complete" : "running", detail: type.hasSuffix("completed") ? "已完成" : "正在执行"))
        }
        if done, let value = event["response"] as? [String: Any] {
            do { output = try collected.finish(value["output"] as? [[String: Any]] ?? []) }
            catch { throw ResponseFailure.make(response: response, shape: "incomplete_tool_output", fallback: error.localizedDescription) }
        }
        // Completed-only terminal events may contain the entire output; do not
        // duplicate it when deltas already delivered the text.
        if done, !deliveredText {
            for item in output where item["type"] as? String == "message" {
                for content in item["content"] as? [[String: Any]] ?? [] {
                    if content["type"] as? String == "output_text", let text = content["text"] as? String { onDelta(text) }
                    else if content["type"] as? String == "refusal", let text = content["refusal"] as? String { onDelta(text) }
                }
            }
        }
        if !done, ["response.output_text.delta", "response.refusal.delta"].contains(type),
           let delta = event["delta"] as? String, !delta.isEmpty { deliveredText = true }
        completed = done
        return done
    }
}
