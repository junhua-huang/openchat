import XCTest
@testable import LiaoChat

@MainActor final class MCPConnectionFlowTests: XCTestCase {
    private let endpoint = "https://mcp.example.com/mcp"
    private func server(token: String = "") -> MCPServer { MCPServer(name: "Test", endpoint: endpoint, token: token, enabled: true) }
    private func credentials() -> MCPOAuthCredentials {
        MCPOAuthCredentials(resource: endpoint, issuer: "https://auth.example.com", tokenEndpoint: "https://auth.example.com/token", clientID: "synthetic-public", accessToken: "synthetic-access")
    }
    func testAutomaticConnectionSignsInOnceAfterFresh401AndReturnsCatalog() async throws {
        var logins = 0, requests = 0
        let result = try await MCPConnectionFlow.connect(server(), mode: .automatic, login: { endpoint, clientID in
            logins += 1; XCTAssertEqual(endpoint, self.endpoint); XCTAssertEqual(clientID, "")
            return self.credentials()
        }, catalog: { server in
            requests += 1
            if requests == 1 { XCTAssertNil(server.oauth); throw MCPAuthorizationRequired(message: "HTTP 401") }
            XCTAssertEqual(server.oauth?.accessToken, "synthetic-access"); XCTAssertTrue(server.token.isEmpty)
            var value = server; value.tools = [MCPTool(name: "read", inputSchema: .object(["type": .string("object")]))]; return value
        })
        XCTAssertEqual(logins, 1); XCTAssertEqual(requests, 2); XCTAssertEqual(result.tools.map(\.name), ["read"])
        XCTAssertEqual(result.oauthClientID, "synthetic-public"); XCTAssertEqual(result.usesOAuth, true)
    }
    func testExistingCredentialRejectionDoesNotOpenBrowserOrRetry() async throws {
        for useOAuth in [false, true] {
            var value = server(token: useOAuth ? "" : "synthetic-token")
            if useOAuth { value.oauth = credentials() }
            var requests = 0
            do {
                _ = try await MCPConnectionFlow.connect(value, mode: .automatic, login: { _, _ in XCTFail("Do not silently replace saved credentials"); return self.credentials() }, catalog: { _ in
                    requests += 1; throw MCPAuthorizationRequired(message: "HTTP 401")
                }); XCTFail("Expected rejected credentials")
            } catch { XCTAssertTrue(error is MCPAuthorizationRequired); XCTAssertEqual(requests, 1) }
        }
    }
    func testNetworkAndPermissionFailuresNeverTriggerBrowserSignIn() async throws {
        let failures: [Error] = [URLError(.timedOut), AppFailure.message("HTTP 403"), AppFailure.message("HTTP 503")]
        for failure in failures {
            var requests = 0
            do {
                _ = try await MCPConnectionFlow.connect(server(), mode: .automatic, login: { _, _ in XCTFail("Not an authentication challenge"); return self.credentials() }, catalog: { _ in requests += 1; throw failure })
                XCTFail("Expected failure")
            } catch { XCTAssertEqual(error.localizedDescription, failure.localizedDescription); XCTAssertEqual(requests, 1) }
        }
    }
    func testGitHubBlankTokenStopsBeforeNetworkAndDoesNotPretendLoginIsConfigured() async throws {
        do {
            _ = try await MCPConnectionFlow.connect(MCPServer(name: "GitHub", endpoint: "https://api.githubcopilot.com/mcp/", enabled: true), mode: .automatic,
                login: { _, _ in XCTFail("No configured GitHub application"); return self.credentials() },
                catalog: { value in XCTFail("No anonymous GitHub request"); return value })
            XCTFail("Requires access token")
        } catch { XCTAssertEqual(error.localizedDescription, MCPServer.gitHubTokenRequired) }
    }
    func testAuthorizationFailureOrSecond401NeverLoopsOrSavesFalseSuccess() async throws {
        for rejectedLogin in [false, true] {
            var requests = 0, logins = 0
            do {
                _ = try await MCPConnectionFlow.connect(server(), mode: .automatic, login: { _, _ in
                    logins += 1
                    if rejectedLogin { throw MCPOAuthSetupRequired(message: "Requires app registration") }
                    return self.credentials()
                }, catalog: { _ in requests += 1; throw MCPAuthorizationRequired(message: "HTTP 401") })
                XCTFail("Never report a successful connection")
            } catch {
                XCTAssertEqual(logins, 1); XCTAssertEqual(requests, rejectedLogin ? 1 : 2)
                XCTAssertTrue(rejectedLogin ? error is MCPOAuthSetupRequired : error is MCPAuthorizationRequired)
            }
        }
    }
    func testDisabledConnectionDoesNotFetchOrLaunchAuthorization() async throws {
        var value = server(); value.enabled = false
        let saved = try await MCPConnectionFlow.connect(value, mode: .oauth,
            login: { _, _ in XCTFail("Disabled connection"); return self.credentials() },
            catalog: { value in XCTFail("Disabled connection"); return value })
        XCTAssertFalse(saved.enabled); XCTAssertNil(saved.oauth)
    }
    func testIssuedCredentialsCannotBeUsedForAnotherEndpoint() async throws {
        var requests = 0
        do {
            _ = try await MCPConnectionFlow.connect(server(), mode: .automatic, login: { _, _ in
                var value = self.credentials(); value.boundEndpoint = "https://other.example.com/mcp"; return value
            }, catalog: { _ in requests += 1; throw MCPAuthorizationRequired(message: "HTTP 401") })
            XCTFail("Resource mismatch")
        } catch { XCTAssertTrue(error.localizedDescription.contains("不匹配")); XCTAssertEqual(requests, 1) }
    }
}
