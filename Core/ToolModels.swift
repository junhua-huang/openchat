import Foundation

enum JSONValue: Codable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode([String: JSONValue].self) { self = .object(x) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    var foundation: Any {
        switch self {
        case .object(let x): return x.mapValues(\.foundation)
        case .array(let x): return x.map(\.foundation)
        case .string(let x): return x
        case .number(let x): return x
        case .bool(let x): return x
        case .null: return NSNull()
        }
    }
}

struct ChatAttachment: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var storedName: String
    var byteCount: Int
    var mediaType: String
    var extractedText: String?
    var note: String?
    var isImage: Bool { mediaType.hasPrefix("image/") && mediaType != "image/svg+xml" }
}

struct ToolSettings: Codable, Equatable {
    var enabled = true
    // Optional so a 2.0 archive continues to decode with search enabled.
    var publicSearch: Bool?
    var allowsPublicSearch: Bool {
        get { publicSearch ?? true }
        set { publicSearch = newValue }
    }
}

struct ToolActivity: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var state: String = "running"
    var detail: String = ""
    var sources: [WebSearchResult]?
    // Character offset of the first event in the received assistant text.
    // Nil in older archives, whose event order cannot be reconstructed.
    var textOffset: Int?
}

struct ToolCall: Equatable {
    var id: String
    var name: String
    var arguments: String
    func object() throws -> [String: Any] {
        guard arguments.utf8.count <= 256_000,
              let data = arguments.data(using: .utf8),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AppFailure.message("工具参数无效或过大。")
        }
        return result
    }
}

struct ToolDefinition {
    let name: String
    let description: String
    let parameters: [String: Any]
    var responses: [String: Any] { ["type": "function", "name": name, "description": description, "parameters": parameters, "strict": false] }
    var chat: [String: Any] { ["type": "function", "function": ["name": name, "description": description, "parameters": parameters]] }
}

struct ToolApproval: Identifiable {
    let id = UUID()
    let threadID: UUID
    let runID: UUID
    let name: String
    let arguments: String
}

enum ToolEvent {
    case activity(ToolActivity)
    case file(ChatAttachment)
    case beginInference, restartInference
    case waitingForForeground(Bool)
}
