import XCTest
import CoreFoundation
@testable import LiaoChat

final class WebPageClientTests: XCTestCase {
    private func response(_ url: URL, _ status: Int = 200, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
    func testPublicRedirectsAreFollowedWithNoCredentialsAndFinalSource() async throws {
        let url = URL(string: "https://example.com/start")!
        var request = URLRequest(url: url); request.setValue("Bearer secret", forHTTPHeaderField: "Authorization"); request.setValue("session=secret", forHTTPHeaderField: "Cookie")
        var paths: [String] = []
        let (data, final) = try await WebPageClient.read(request) { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            paths.append(request.url!.path)
            if paths.count == 1 { return (Data(), self.response(request.url!, 302, ["Location": "/next"])) }
            if paths.count == 2 { return (Data(), self.response(request.url!, 301, ["Location": "https://news.example.com/article"])) }
            return (Data("<p>新闻正文</p>".utf8), self.response(request.url!, 200, ["Content-Type": "text/html; charset=utf-8"]))
        }
        XCTAssertEqual(paths, ["/start", "/next", "/article"])
        XCTAssertEqual(final.url?.absoluteString, "https://news.example.com/article")
        XCTAssertEqual(try WebPageClient.text(data, response: final), "新闻正文")
    }
    func testRedirectLoopsDowngradesAndPrivateLocationsStop() async throws {
        for target in ["https://example.com/start", "http://example.com/article", "https://user:password@example.com/article", "https://127.0.0.1/private", "https://192.168.0.1/private"] {
            var requests = 0
            do {
                _ = try await WebPageClient.read(URLRequest(url: URL(string: "https://example.com/start")!)) { request in
                    requests += 1; return (Data(), self.response(request.url!, 302, ["Location": target]))
                }; XCTFail("Unsafe/cyclic redirect should stop")
            } catch { XCTAssertEqual(requests, 1) }
        }
    }
    func testRedirectCountAndResponseSizeStayBounded() async throws {
        var requests = 0
        do {
            _ = try await WebPageClient.read(URLRequest(url: URL(string: "https://example.com/0")!)) { request in
                requests += 1; return (Data(), self.response(request.url!, 302, ["Location": "/\(requests)"]))
            }; XCTFail("Redirects must be bounded")
        } catch { XCTAssertEqual(requests, 6); XCTAssertTrue(error.localizedDescription.contains("5 次")) }
        do {
            _ = try await WebPageClient.read(URLRequest(url: URL(string: "https://example.com/")!)) { request in
                (Data(repeating: 32, count: 2_000_001), self.response(request.url!))
            }; XCTFail("Oversize body")
        } catch { XCTAssertTrue(error.localizedDescription.contains("2 MB")) }
    }
    func testCharsetHeaderGB18030AndHTMLDeclarationAreDecoded() throws {
        let cf = CFStringConvertIANACharSetNameToEncoding("gb18030" as CFString)
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        let body = "<html><meta charset=gb18030><p>中文新闻 &amp; &#x4E16;&#30028;</p><script>ignore me</script></html>"
        let data = try XCTUnwrap(body.data(using: encoding))
        let url = URL(string: "https://example.com/article")!
        for header in ["text/html; charset=gb18030", "text/html"] {
            let text = try WebPageClient.text(data, response: response(url, 200, ["Content-Type": header]))
            XCTAssertTrue(text.contains("中文新闻 & 世界")); XCTAssertFalse(text.contains("ignore me"))
        }
    }
    func testUTF16AndPlainTextPreserveMeaningAndBinaryIsExplained() throws {
        let url = URL(string: "https://example.com/page")!
        let text = "中文 <示例> & code"
        XCTAssertEqual(try WebPageClient.text(XCTUnwrap(text.data(using: .utf16)), response: response(url, 200, ["Content-Type": "text/plain"])), text)
        XCTAssertEqual(try WebPageClient.text(Data(text.utf8), response: response(url, 200, ["Content-Type": "text/plain; charset=utf-8"])), text)
        XCTAssertThrowsError(try WebPageClient.text(Data([0x89,0x50,0x4e,0x47]), response: response(url, 200, ["Content-Type": "image/png"]))) { XCTAssertTrue($0.localizedDescription.contains("image/png")) }
    }
    func testMCPToolErrorsKeepUsefulDetailsAndRedactCredentials() {
        let result: [String: Any] = ["isError": true, "content": [["type": "text", "text": "Upstream HTTP 429: quota exceeded. token=synthetic-secret Bearer private-bearer api_key=hidden https://example.com/?key=hidden github_pat_hidden"]]]
        let message = MCPToolFailure.describe(result, secrets: ["synthetic-secret"])
        XCTAssertTrue(message.contains("429")); XCTAssertTrue(message.contains("quota exceeded"))
        for secret in ["synthetic-secret", "private-bearer", "api_key=hidden", "?key=hidden", "github_pat_hidden"] { XCTAssertFalse(message.contains(secret)) }
    }
}
