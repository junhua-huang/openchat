import XCTest
@testable import LiaoChat

final class CoreTests: XCTestCase {
    func testStreamingCodeBlockPreservesUnicodeAndIncompleteFence() {
        XCTAssertEqual(MessageContent.blocks("说明\n```swift\nlet greeting = \"你好🙂\""), [
            .prose("说明"), .code(language: "swift", text: "let greeting = \"你好🙂\"")
        ])
    }
    func testLongFenceKeepsShorterFenceInsideCodeAndNormalizesCRLF() {
        XCTAssertEqual(MessageContent.blocks("````markdown\r\n```swift\r\n代码\r\n```\r\n````\r\n完成"), [
            .code(language: "markdown", text: "```swift\n代码\n```"), .prose("完成")
        ])
    }
    func testPKCERFC7636Vector() {
        XCTAssertEqual(EncodingTools.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testFormEncodingPreservesReservedCharactersAndUnicode() {
        let value = "a+b&c= 中文/🙂"
        let encoded = String(data: EncodingTools.form(["code": value]), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("中文"))
        XCTAssertEqual(String(encoded.dropFirst(5)).removingPercentEncoding, value)
    }
    func testSSECommentsMultilineAndFinalEvent() throws {
        var parser = SSEParser()
        XCTAssertNil(try parser.push(": heartbeat"))
        XCTAssertNil(try parser.push("event: message"))
        XCTAssertNil(try parser.push("data: 第一行"))
        XCTAssertNil(try parser.push("data:第二行"))
        XCTAssertEqual(try parser.push(""), "第一行\n第二行")
        XCTAssertNil(try parser.push(""))
        XCTAssertNil(try parser.push("data: final"))
        XCTAssertEqual(parser.finish(), "final")
        XCTAssertNil(parser.finish())
    }
    @MainActor func testOnlyCompletedResponseCountsAsSuccess() async throws {
        XCTAssertFalse(try ResponsesClient.handle("[DONE]", onDelta: { _ in }))
        XCTAssertThrowsError(try ResponsesClient.handle(#"{"type":"response.completed","response":{"status":"failed"}}"#, onDelta: { _ in }))
        XCTAssertThrowsError(try ResponsesClient.handle(#"{"type":"response.incomplete"}"#, onDelta: { _ in }))
        XCTAssertTrue(try ResponsesClient.handle(#"{"type":"response.completed","response":{"status":"completed"}}"#, onDelta: { _ in }))
        var text = ""
        XCTAssertFalse(try ResponsesClient.handle(#"{"type":"response.output_text.delta","delta":"你好🙂"}"#, onDelta: { text += $0 }))
        XCTAssertEqual(text, "你好🙂")
    }
    func testRealSignaturesAndRejectedIdentityClaims() throws {
        let url = Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: "json")!
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let jwks = try JSONSerialization.data(withJSONObject: fixture["jwks"]!)
        let metadata = OpenIDMetadata(issuer: "https://auth.openai.com",
            authorization_endpoint: URL(string: "https://auth.openai.com/api/accounts/authorize")!,
            token_endpoint: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!,
            jwks_uri: URL(string: "https://auth.openai.com/.well-known/jwks.json")!, revocation_endpoint: nil)
        for name in ["rsa", "ec"] {
            let identity = try IdentityVerifier.verify(fixture[name] as! String, clientID: "test-client", nonce: "test-nonce", metadata: metadata, jwks: jwks)
            XCTAssertEqual(identity.sub, "test-user")
        }
        for name in ["wrong-audience", "expired", "wrong-nonce", "wrong-issuer", "future-iat", "multiple-audiences-no-azp", "tampered", "none-algorithm"] {
            XCTAssertThrowsError(try IdentityVerifier.verify(fixture[name] as! String, clientID: "test-client", nonce: "test-nonce", metadata: metadata, jwks: jwks), name)
        }
    }
    func testMissingNewGrantDoesNotEnablePlanUse() throws {
        let reply = try JSONDecoder().decode(TokenReply.self, from: Data(#"{"access_token":"test","token_type":"Bearer","expires_in":3600,"scope":"openid email"}"#.utf8))
        XCTAssertFalse(try Tokens(reply: reply).permitsInference)
    }
}
