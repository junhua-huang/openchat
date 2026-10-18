import Foundation

enum MCPToolFailure {
    static func describe(_ result: [String: Any], secrets: [String]) -> String {
        let texts = (result["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        var text = String(texts.joined(separator: "\n").prefix(2000))
        for secret in secrets where !secret.isEmpty {
            text = text.replacingOccurrences(of: secret, with: "[已隐藏凭据]")
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { text = text.replacingOccurrences(of: encoded, with: "[已隐藏凭据]") }
        }
        for pattern in ["(?i)Bearer\\s+[^\\s\"'<>]+", "(?i)(?:api[_-]?key|access[_-]?token|refresh[_-]?token|authorization|password|client_secret)[\"']?\\s*[:=]\\s*[\"']?[^\\s,\"'<>]+", "https?://[^\\s<>\"']+\\?[^\\s<>\"']+", "(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+)"] {
            text = text.replacingOccurrences(of: pattern, with: "[已隐藏凭据或查询参数]", options: .regularExpression)
        }
        text = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" }.map(String.init).joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "MCP 工具执行失败，服务没有提供错误说明。请检查服务授权、参数或额度。" }
        return "MCP 工具执行失败。服务返回：" + String(text.prefix(700))
    }
}
