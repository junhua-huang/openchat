import Foundation

struct MCPToolAnnotations: Codable, Equatable {
    var readOnlyHint: Bool? = nil
    var destructiveHint: Bool? = nil
}

// Auto-execution is an explicit, per-connection trust choice, never inferred
// from a tool's name or description. Missing metadata continues to ask.
enum MCPApprovalPolicy: String, Codable, CaseIterable {
    case always, readOnly, never

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .always
    }

    var title: String {
        switch self {
        case .always: return "每次确认"
        case .readOnly: return "只读工具自动执行"
        case .never: return "全部工具自动执行"
        }
    }

    func requiresConfirmation(for annotations: MCPToolAnnotations?) -> Bool {
        switch self {
        case .always: return true
        case .readOnly:
            return annotations?.readOnlyHint != true || annotations?.destructiveHint == true
        case .never: return false
        }
    }
}
