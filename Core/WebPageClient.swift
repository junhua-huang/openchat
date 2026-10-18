import Foundation
import CoreFoundation

/// Public browsing has its own redirect policy; MCP/OAuth credentials never enter it.
enum WebPageClient {
    static func validURL(_ url: URL) throws -> URL {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { throw AppFailure.message("请输入公开 HTTPS 网页地址。") }
        guard host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local"),
              !host.contains(":"), host != "0.0.0.0" else { throw AppFailure.message("公开网页工具不能访问本机或内网地址。") }
        let numbers = host.split(separator: ".").compactMap { Int($0) }
        if numbers.count == 4 {
            guard ![0,10,127].contains(numbers[0]), !(numbers[0] == 169 && numbers[1] == 254),
                  !(numbers[0] == 172 && (16...31).contains(numbers[1])), !(numbers[0] == 192 && numbers[1] == 168) else {
                throw AppFailure.message("公开网页工具不能访问本机或内网地址。")
            }
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!; parts.fragment = nil
        return parts.url!
    }
    static func read(_ original: URLRequest, transport: (URLRequest) async throws -> (Data, HTTPURLResponse)) async throws -> (Data, HTTPURLResponse) {
        guard let originalURL = original.url else { throw AppFailure.message("网页地址无效。") }
        var url = try validURL(originalURL); var visited = Set<String>()
        for _ in 0...5 {
            try Task.checkCancellation()
            guard visited.insert(url.absoluteString).inserted else { throw AppFailure.message("网页重定向形成循环。") }
            // Rebuild on each hop: never forward caller headers, cookies or credentials.
            var request = URLRequest(url: url); request.timeoutInterval = 30
            request.setValue("text/html, application/xhtml+xml, text/plain, application/json", forHTTPHeaderField: "Accept")
            request.setValue("OpenChat/2.2.0", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await transport(request)
            guard data.count <= 2_000_000 else { throw AppFailure.message("网页正文超过 2 MB 限制。") }
            if [301,302,303,307,308].contains(response.statusCode) {
                guard let location = response.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: location, relativeTo: url)?.absoluteURL else { throw AppFailure.message("网页跳转缺少有效地址。") }
                url = try validURL(next); continue
            }
            guard (200..<300).contains(response.statusCode) else {
                throw AppFailure.message("网页读取失败（HTTP \(response.statusCode)）。可能需要登录、遇到反爬限制或页面暂时不可用。")
            }
            return (data, response)
        }
        throw AppFailure.message("网页重定向超过 5 次，请使用最终网页地址。")
    }
    private static func encoding(_ name: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
    static func text(_ data: Data, response: HTTPURLResponse) throws -> String {
        let mime = response.mimeType?.lowercased()
        guard mime == nil || ["text/html", "application/xhtml+xml", "text/plain", "application/json", "text/xml", "application/xml"].contains(mime!) else {
            throw AppFailure.message("此地址返回 \(mime ?? "二进制文件")，不是可直接读取的网页文本。PDF 等文件请先作为附件导入。")
        }
        if data.starts(with: [0xEF,0xBB,0xBF]), let text = String(data: data.dropFirst(3), encoding: .utf8) { return clean(text, mime: mime) }
        var names: [String] = []
        if data.starts(with: [0xFF,0xFE]) || data.starts(with: [0xFE,0xFF]), let text = String(data: data, encoding: .utf16) { return clean(text, mime: mime) }
        if let header = response.textEncodingName { names.append(header) }
        let head = String(decoding: data.prefix(16000), as: UTF8.self)
        if let range = head.range(of: "charset\\s*=\\s*[\"']?([a-zA-Z0-9._-]+)", options: .regularExpression) {
            let declaration = String(head[range])
            if let equal = declaration.firstIndex(of: "=") { names.append(declaration[declaration.index(after: equal)...].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'")))) }
        }
        for name in names {
            if let encoding = encoding(name), let text = String(data: data, encoding: encoding) { return clean(text, mime: mime) }
        }
        if let text = String(data: data, encoding: .utf8) { return clean(text, mime: mime) }
        // Do not silently reinterpret arbitrary binary data as Latin-1.
        throw AppFailure.message("无法识别网页正文编码。服务未提供有效 charset，请尝试其他原文来源。")
    }
    private static func clean(_ input: String, mime: String?) -> String {
        guard mime == "text/html" || mime == "application/xhtml+xml" || (mime == nil && input.lowercased().contains("<html")) else { return input }
        var text = input.replacingOccurrences(of: "(?is)<(script|style|noscript)\\b[^>]*>.*?</\\1>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "(?is)<(?:br|/p|/div|/h[1-6]|/li)\\b[^>]*>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            let source = text; var decoded = ""; decoded.reserveCapacity(source.utf8.count)
            var cursor = source.startIndex
            for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range, in: source), let valueRange = Range(match.range(at: 1), in: source) else { continue }
                decoded += source[cursor..<range.lowerBound]
                let raw = String(source[valueRange]); let value = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
                if let value = value, let scalar = UnicodeScalar(value) { decoded.append(String(scalar)) }
                else { decoded += source[range] }
                cursor = range.upperBound
            }
            decoded += source[cursor...]; text = decoded
        }
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: value) }
        return text.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n\\s*\\n\\s*\\n", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
