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

    static func request(token: String, model: String, history: [ChatMessage], effort: ReasoningEffort = .automatic) throws -> URLRequest {
        try ReasoningSupport.validate(effort, model: model)
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/responses")!)
        request.httpMethod = "POST"
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var body: [String: Any] = [
            "model": model, "store": false, "stream": true,
            "input": history.filter { $0.status == .complete }.map { ["role": $0.role.rawValue, "content": $0.text] }
        ]
        if effort != .automatic { body["reasoning"] = ["effort": effort.rawValue] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    @MainActor
    static func stream(token: String, model: String, history: [ChatMessage], effort: ReasoningEffort = .automatic,
                       onDelta: (String) -> Void) async throws {
        let request = try request(token: token, model: model, history: history, effort: effort)
        let (bytes, response) = try await HTTP.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ResponseFailure.make(response: nil, shape: "non_http")
        }
        try await consume(bytes, response: http, onDelta: onDelta)
    }

    @MainActor
    // Xcode 26.6 / Swift 6.3.3 crashes in LLVM CoroSplit when this throwing
    // async loop is specialized for URLSession.AsyncBytes in Release builds.
    // Keep this network-bound adapter out of optimization; the wire decoder
    // and the rest of the app retain their normal Release optimizations.
    @_optimize(none)
    @inline(never)
    static func consume<Body: AsyncSequence>(_ bytes: Body, response: HTTPURLResponse,
                                             onDelta: (String) -> Void) async throws where Body.Element == UInt8 {
        var decoder = ResponsesWireDecoder(response: response)
        for try await line in SSEByteLines(base: bytes) {
            try Task.checkCancellation()
            if try decoder.push(line, onDelta: onDelta) { return }
        }
        _ = try decoder.finish(onDelta: onDelta)
    }

    @MainActor
    static func handle(_ payload: String, response: HTTPURLResponse? = nil, shape: String = "sse", onDelta: (String) -> Void) throws -> Bool {
        if payload == "[DONE]" { return false }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            throw ResponseFailure.make(response: response, shape: "invalid_event_json")
        }
        guard let event = object as? [String: Any] else {
            throw ResponseFailure.make(response: response, shape: "event_not_object")
        }
        guard let type = event["type"] as? String, !type.isEmpty else {
            throw ResponseFailure.make(response: response,
                shape: event["error"] != nil ? "event_error" : "event_missing_type", object: event)
        }
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
        guard size < 16_000_000 else { throw AppFailure.message("单个响应事件过大，请重新开始对话。") }
        data.append(part)
        return nil
    }
    mutating func finish() -> String? {
        defer { data = []; size = 0 }
        let payload = data.joined(separator: "\n")
        return payload.isEmpty ? nil : payload
    }
}

// SSE framing requires empty lines. Split raw bytes on CR, LF or CRLF without
// relying on a general-purpose text adapter's treatment of empty lines.
// Decode only complete lines so a network chunk cannot split a UTF-8 scalar.
struct SSEByteLines<Base: AsyncSequence>: AsyncSequence where Base.Element == UInt8 {
    typealias Element = String
    let base: Base
    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: base.makeAsyncIterator()) }

    struct AsyncIterator: AsyncIteratorProtocol {
        var base: Base.AsyncIterator
        private var buffer: [UInt8] = []
        private var skipLF = false
        private var reachedEnd = false

        init(base: Base.AsyncIterator) { self.base = base }

        mutating func next() async throws -> String? {
            guard !reachedEnd else { return nil }
            while let byte = try await base.next() {
                try Task.checkCancellation()
                if skipLF {
                    skipLF = false
                    if byte == 10 { continue }
                }
                if byte == 13 || byte == 10 {
                    skipLF = byte == 13
                    return try takeLine()
                }
                guard buffer.count < 16_000_000 else {
                    throw AppFailure.message("单行响应过大，请重新开始对话。")
                }
                buffer.append(byte)
            }
            reachedEnd = true
            return buffer.isEmpty ? nil : try takeLine()
        }

        private mutating func takeLine() throws -> String {
            defer { buffer.removeAll(keepingCapacity: true) }
            guard let line = String(bytes: buffer, encoding: .utf8) else {
                throw AppFailure.message("回复包含无效的 UTF-8 编码，请重试。")
            }
            return line
        }
    }
}
