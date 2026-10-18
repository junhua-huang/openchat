import Foundation
import Combine

@MainActor final class MCPOAuthSignIn: ObservableObject {
    static let callbackAddress = "http://127.0.0.1:51219/auth/callback"
    @Published var browser: BrowserRequest?
    @Published private(set) var stage = ""
    private let callback = LoopbackServer()
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    func login(endpoint: String, clientID: String) async throws -> MCPOAuthCredentials {
        defer { callback.stop(); timeout?.cancel(); browser = nil; stage = "" }
        let client = MCPOAuthClient()
        stage = "正在发现授权服务器"
        let discovery = try await client.discover(endpoint: endpoint)
        try Task.checkCancellation()
        let redirect = try await callback.start(port: 51219)
        try Task.checkCancellation()
        let attempt = try await client.prepare(discovery, clientID: clientID, redirect: redirect)
        try Task.checkCancellation()
        stage = "等待浏览器授权"
        let code: String = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { pending in
                continuation = pending
                callback.accept = { [weak self] url in
                    guard let self = self, self.continuation != nil else { return false }
                    // Reject unrelated callbacks without consuming this login attempt.
                    guard MCPOAuthClient.matchesCallback(url, attempt: attempt) else { return false }
                    let pending = self.continuation; self.continuation = nil
                    self.browser = nil; self.timeout?.cancel()
                    do { pending?.resume(returning: try MCPOAuthClient.code(from: url, attempt: attempt)) }
                    catch { pending?.resume(throwing: error) }
                    return true
                }
                browser = BrowserRequest(url: attempt.authorizationURL)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 180_000_000_000) } catch { return }
                    self?.cancel()
                }
            }
        }, onCancel: { Task { @MainActor in self.cancel() } })
        try Task.checkCancellation()
        stage = "正在完成授权"
        return try await client.exchange(attempt, code: code)
    }
    func cancel() {
        let pending = continuation; continuation = nil
        timeout?.cancel(); callback.stop(); browser = nil
        pending?.resume(throwing: CancellationError())
    }
}
