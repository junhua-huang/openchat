import Foundation

struct WebSearchResult: Codable, Equatable, Identifiable {
    let title: String
    let url: String
    let snippet: String
    var id: String { url }
}

struct WebSearchResponse {
    let provider: String
    let results: [WebSearchResult]
    let filteredByDate: Bool
}

enum SearchFreshness: String, CaseIterable {
    case any, day, week, month
    var parameter: String? {
        switch self { case .any: return nil; case .day: return "d"; case .week: return "w"; case .month: return "m" }
    }
    var title: String {
        switch self { case .any: return "不限时间"; case .day: return "最近一天"; case .week: return "最近一周"; case .month: return "最近一月" }
    }
}

// Public search pages do not require an API key. Their availability and markup
// can change; a challenge/error is never treated as a successful search result.
// Only the query goes to these providers, never AI credentials or chat history.
struct WebSearchClient {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    var transport: Transport = { request in try await BoundedHTTP.read(request, limit: 1_000_000) }

    static var localDateContext: String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date()) + "（时区 " + TimeZone.current.identifier + "）"
    }
    static func request(query: String, freshness: SearchFreshness, bing: Bool = false) throws -> URLRequest {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500, text.utf8.count <= 2000 else { throw AppFailure.message("搜索词需要 1～500 个字符。") }
        var parts = URLComponents(string: bing ? "https://www.bing.com/search" : "https://html.duckduckgo.com/html/")!
        parts.queryItems = [URLQueryItem(name: "q", value: text)]
        if bing { parts.queryItems?.append(URLQueryItem(name: "format", value: "rss")) }
        else if let value = freshness.parameter { parts.queryItems?.append(URLQueryItem(name: "df", value: value)) }
        // HTML search endpoints decode query strings as form data, where a
        // literal '+' would otherwise become a space (for example, C++).
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url else { throw AppFailure.message("搜索词无法编码。") }
        var request = URLRequest(url: url); request.timeoutInterval = 25
        request.setValue("OpenChat/2.1.3", forHTTPHeaderField: "User-Agent")
        request.setValue(bing ? "application/rss+xml, application/xml, text/xml" : "text/html", forHTTPHeaderField: "Accept")
        return request
    }
    func search(query: String, freshness: SearchFreshness, count: Int) async throws -> WebSearchResponse {
        guard (1...8).contains(count) else { throw AppFailure.message("搜索结果数量需要在 1～8 之间。") }
        let primary = try Self.request(query: query, freshness: freshness)
        var empty: WebSearchResponse?
        do {
            let (data, response) = try await transport(primary); try Self.validate(data, response: response)
            let results = try Self.duckDuckGo(data, count: count)
            let result = WebSearchResponse(provider: "DuckDuckGo", results: results, filteredByDate: freshness != .any)
            if !results.isEmpty { return result }; empty = result
        } catch { if Task.isCancelled || error is CancellationError { throw CancellationError() } }
        try Task.checkCancellation()
        do {
            let (data, response) = try await transport(Self.request(query: query, freshness: freshness, bing: true))
            try Self.validate(data, response: response)
            let results = try Self.bingRSS(data, count: count)
            return WebSearchResponse(provider: "Bing", results: results, filteredByDate: false)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            if let empty = empty { return empty }
            throw AppFailure.message("公开搜索暂不可用，可能遇到网络限制、验证码或服务变更。请稍后重试，或连接搜索 MCP；本次没有取得可用搜索结果。")
        }
    }
    private static func validate(_ data: Data, response: HTTPURLResponse) throws {
        guard (200..<300).contains(response.statusCode), data.count <= 1_000_000 else { throw AppFailure.message("搜索服务返回异常。") }
    }
    private static func matches(_ pattern: String, _ text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func group(_ match: NSTextCheckingResult, _ index: Int, _ text: String) -> String {
        guard let range = Range(match.range(at: index), in: text) else { return "" }; return String(text[range])
    }
    static func plain(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?is)<(script|style|noscript)\\b[^>]*>.*?</\\1>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        let entities = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“"]
        for match in matches("&(#x[0-9a-f]+|#[0-9]+|[a-z]+);", text).reversed() {
            let name = group(match, 1, text); let value: String?
            if name.lowercased().hasPrefix("#x"), let code = UInt32(name.dropFirst(2), radix: 16), let scalar = UnicodeScalar(code) { value = String(scalar) }
            else if name.hasPrefix("#"), let code = UInt32(name.dropFirst()), let scalar = UnicodeScalar(code) { value = String(scalar) }
            else { value = entities[name.lowercased()] }
            if let value = value, let range = Range(match.range, in: text) { text.replaceSubrange(range, with: value) }
        }
        return text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func resultURL(_ raw: String) -> URL? {
        let decoded = plain(raw)
        let absolute = decoded.hasPrefix("//") ? "https:" + decoded : decoded.hasPrefix("/") ? "https://duckduckgo.com" + decoded : decoded
        guard var parts = URLComponents(string: absolute) else { return nil }
        let host = parts.host?.lowercased() ?? ""
        if host == "duckduckgo.com" || host.hasSuffix(".duckduckgo.com") || host == "bing.com" || host.hasSuffix(".bing.com") {
            if let target = parts.queryItems?.first(where: { ["uddg", "url"].contains($0.name) })?.value,
               let unwrapped = URLComponents(string: target) { parts = unwrapped }
            else { return nil }
        }
        guard ["https", "http"].contains(parts.scheme?.lowercased() ?? ""), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, let url = parts.url, url.absoluteString.count <= 4096 else { return nil }
        parts.fragment = nil
        return parts.url
    }
    static func duckDuckGo(_ data: Data, count: Int) throws -> [WebSearchResult] {
        guard data.count <= 1_000_000, let html = String(data: data, encoding: .utf8), !html.contains("anomaly.js") else {
            throw AppFailure.message("搜索服务需要浏览器验证。")
        }
        let anchors = matches("<a\\b([^>]*\\bclass\\s*=\\s*[\"'][^\"']*\\bresult__a\\b[^\"']*[\"'][^>]*)>(.*?)</a>", html)
        var seen = Set<String>(); var results: [WebSearchResult] = []
        for (index, match) in anchors.enumerated() {
            let attrs = group(match, 1, html)
            guard let href = matches("\\bhref\\s*=\\s*([\"'])(.*?)\\1", attrs).first,
                  let url = resultURL(group(href, 2, attrs)), seen.insert(url.absoluteString).inserted else { continue }
            let title = plain(group(match, 2, html)); guard !title.isEmpty else { continue }
            let start = match.range.location + match.range.length
            let end = index + 1 < anchors.count ? anchors[index + 1].range.location : (html as NSString).length
            let tail = (html as NSString).substring(with: NSRange(location: start, length: min(12000, max(0, end - start))))
            let snippet = matches("<(?:a|div|span)\\b[^>]*\\bclass\\s*=\\s*[\"'][^\"']*\\bresult__snippet\\b[^\"']*[\"'][^>]*>(.*?)</(?:a|div|span)>", tail).first.map { plain(group($0, 1, tail)) } ?? ""
            results.append(WebSearchResult(title: String(title.prefix(200)), url: url.absoluteString, snippet: String(snippet.prefix(1200))))
            if results.count >= count { break }
        }
        guard !results.isEmpty || html.contains("no-results") || html.contains("No results found") else {
            throw AppFailure.message("搜索结果页面格式已变化。")
        }
        return results
    }
    static func bingRSS(_ data: Data, count: Int) throws -> [WebSearchResult] {
        guard data.count <= 1_000_000, let xml = String(data: data, encoding: .utf8), !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else {
            throw AppFailure.message("搜索结果格式无效。")
        }
        let handler = SearchRSSParser(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = handler
        guard parser.parse(), handler.isRSS else { throw AppFailure.message("搜索服务没有返回 RSS 结果。") }
        var seen = Set<String>()
        return Array(handler.items.compactMap { item -> WebSearchResult? in
            guard let url = resultURL(item["link"] ?? ""), seen.insert(url.absoluteString).inserted else { return nil }
            let title = plain(item["title"] ?? ""); guard !title.isEmpty else { return nil }
            return WebSearchResult(title: String(title.prefix(200)), url: url.absoluteString, snippet: String(plain(item["description"] ?? "").prefix(1200)))
        }.prefix(count))
    }
}

private final class SearchRSSParser: NSObject, XMLParserDelegate {
    var isRSS = false; var items: [[String: String]] = []
    private var item: [String: String]?; private var element = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "rss" { isRSS = true }
        if elementName == "item" { item = [:] }
        element = elementName
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if item != nil { item?[element, default: ""] += string } }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let text = String(data: CDATABlock, encoding: .utf8), item != nil { item?[element, default: ""] += text }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "item", let value = item { items.append(value); item = nil }
        element = ""
    }
}
