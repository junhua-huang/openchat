import Foundation

// Only allowlisted metadata reaches chat storage or the clipboard. Never include
// response bodies, server messages, authorization headers, tokens or user input.
struct ResponseFailure: LocalizedError {
    let message: String
    let diagnostic: String
    var errorDescription: String? { message }

    static func make(response: HTTPURLResponse?, shape: String, object: [String: Any]? = nil,
                     fallback: String = "服务没有返回完整的流式回复，请重试或复制诊断信息反馈。") -> ResponseFailure {
        let nestedResponse = object?["response"] as? [String: Any]
        let error = object?["error"] as? [String: Any] ?? nestedResponse?["error"] as? [String: Any]
        let rawCode = error?["code"] as? String ?? (object?["type"] as? String == "error" ? object?["code"] as? String : nil)
        let code = safe(rawCode, pattern: "^[a-z][a-z0-9_]{0,99}$")
        let param = safe(error?["param"] as? String, pattern: "^[a-z][a-z0-9_]*(?:\\[[0-9]+\\]|\\.[a-z][a-z0-9_]*)*$", limit: 120)
        let requestID = safe(response?.value(forHTTPHeaderField: "x-request-id") ?? object?["request_id"] as? String,
                             pattern: "^(?:req_[A-Za-z0-9_-]+|[A-Fa-f0-9-]{36})$", limit: 160)
        let status = response?.statusCode
        let message: String
        switch code {
        case "subscription_sharing_usage_limit_exceeded": message = "此连接的 ChatGPT 套餐用量达到限制，请到 ChatGPT 设置查看用量。"
        case "subscription_sharing_user_not_eligible": message = "当前用户、工作空间或策略不允许共享 ChatGPT 套餐额度。"
        case "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable": message = "暂时无法确认 ChatGPT 套餐可用性，请稍后重试。"
        case "subscription_sharing_unsupported_capability": message = "此 ChatGPT 套餐接口不支持本次请求的某项参数或能力，请复制诊断信息反馈。"
        case "subscription_sharing_route_not_supported": message = "当前授权不支持此推理路由，请复制诊断信息反馈。"
        case "chatpass_v2_scope_not_authorized", "chatpass_v2_invalid_authorization_context", "subscription_sharing_invalid_user":
            message = "当前连接的授权上下文未通过验证，请复制诊断信息反馈。"
        default:
            switch status {
            case 401: message = "ChatGPT 推理授权未被接受，请检查当前连接的套餐授权。"
            case 403: message = "ChatGPT 推理请求被策略或权限限制，请复制诊断信息反馈。"
            case 429: message = "请求过于频繁或此连接达到用量限制，请稍后重试并查看 ChatGPT 用量。"
            case 500, 502, 503, 504: message = "ChatGPT 推理服务暂时不可用，请稍后重试。"
            default: message = fallback
            }
        }
        let rawMIME = response?.mimeType?.lowercased() ?? "missing"
        let allowedMIME = ["text/event-stream", "application/json", "application/problem+json", "text/html", "text/plain", "application/octet-stream", "missing"]
        var fields = ["HTTP: \(status.map(String.init) ?? "unknown")",
                      "Content-Type: \(allowedMIME.contains(rawMIME) ? rawMIME : "other")", "Body: \(shape)"]
        if let code = code { fields.append("Code: " + code) }
        if let param = param { fields.append("Parameter: " + param) }
        if let requestID = requestID { fields.append("Request ID: " + requestID) }
        return ResponseFailure(message: message, diagnostic: fields.joined(separator: "\n"))
    }

    private static func safe(_ value: String?, pattern: String, limit: Int = 100) -> String? {
        guard let value = value, value.count <= limit,
              !value.hasPrefix("sk_"), !value.hasPrefix("eyJ"),
              value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value
    }
}
