import Foundation

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum BoundedHTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 90; config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()
    static func read(_ request: URLRequest, limit: Int = 2_000_000, using session: URLSession = BoundedHTTP.session) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw AppFailure.message("服务没有返回 HTTP 响应。") }
        guard (200..<300).contains(http.statusCode) else {
            throw AppFailure.message("请求失败（HTTP \(http.statusCode)）。请检查地址、权限和服务状态。")
        }
        if response.expectedContentLength > Int64(limit) { throw AppFailure.message("服务返回的数据超过大小限制。") }
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(min(limit, Int(response.expectedContentLength))) }
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw AppFailure.message("服务返回的数据超过大小限制。") }
            data.append(byte)
        }
        return (data, http)
    }
    static func endpoint(_ text: String) throws -> URL {
        guard let parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil,
              let url = parts.url else { throw AppFailure.message("请输入不含凭据、查询参数的 HTTPS 地址。") }
        return url
    }
}
