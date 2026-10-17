import Foundation

enum ReasoningEffort: String, CaseIterable, Identifiable {
    case automatic, none, minimal, low, medium, high, xhigh, max
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "默认"
        case .none: return "关闭思考"
        case .minimal: return "极低"
        case .low: return "轻量"
        case .medium: return "标准"
        case .high: return "深入"
        case .xhigh: return "超高"
        case .max: return "最高"
        }
    }
}

enum ReasoningSupport {
    // Exact IDs only: a similar display name or a third-party alias is not a
    // capability guarantee. Keep unknown models on the provider's default.
    // Verified against official model pages / deployment checklist, 2026-10-17.
    static func options(model: String, connection: APIConnection? = nil) -> [ReasoningEffort] {
        if let connection = connection {
            guard let url = try? APIConnection.normalizedURL(connection.baseURL),
                  url.host?.lowercased() == "api.openai.com", url.port == nil || url.port == 443,
                  url.path == "/v1" else { return [] }
        }
        switch model {
        case "gpt-6.1-sol", "gpt-6-astra": return [.low, .medium, .high, .xhigh, .max]
        case "gpt-6-sol", "gpt-6-luna": return [.none, .low, .medium, .high, .xhigh, .max]
        case "gpt-5.2", "gpt-5.4", "gpt-5.5": return [.none, .low, .medium, .high, .xhigh]
        case "gpt-5.1": return [.none, .low, .medium, .high]
        case "gpt-5": return [.minimal, .low, .medium, .high]
        default: return []
        }
    }

    static func validate(_ effort: ReasoningEffort, model: String, connection: APIConnection? = nil) throws {
        guard effort == .automatic || options(model: model, connection: connection).contains(effort) else {
            throw AppFailure.message("当前模型或连接不支持这个推理强度，请选择默认或其他可用档位。")
        }
    }
}
