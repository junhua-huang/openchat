import XCTest
import UIKit
@testable import LiaoChat

private final class OpenResponseProtocol: URLProtocol {
    static var status = 200
    static var payload = Data()
    static var stopped: XCTestExpectation?
    private let closeLock = NSLock()
    private var closed = false
    private func closeOnce() -> Bool {
        closeLock.lock(); defer { closeLock.unlock() }
        guard !closed else { return false }; closed = true; return true
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !Self.payload.isEmpty { client?.urlProtocol(self, didLoad: Self.payload) }
        // Deliberately keep the connection open, like a server that has sent a
        // terminal event but does not close its HTTP stream.
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self = self, self.closeOnce() else { return }
            self.client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        }
    }
    override func stopLoading() { if closeOnce() { Self.stopped?.fulfill() } }
}

final class ReliabilityTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [OpenResponseProtocol.self]
        config.timeoutIntervalForRequest = 5
        return URLSession(configuration: config)
    }
    @MainActor func testLongChineseAndEmojiFilenamesPreserveExtensionsAndCanBeShared() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        for name in [String(repeating: "中文说明", count: 40) + ".md", String(repeating: "👨‍👩‍👧‍👦", count: 60) + ".docx"] {
            let safe = FileVault.safeName(name)
            XCTAssertLessThanOrEqual(safe.utf8.count, 220)
            XCTAssertEqual(URL(fileURLWithPath: safe).pathExtension, URL(fileURLWithPath: name).pathExtension)
            XCTAssertEqual(FileVault.safeName(safe), safe)
            if name.contains("👨‍👩‍👧‍👦") { XCTAssertTrue(safe.contains("👨‍👩‍👧‍👦")) }
            let file = try vault.save(data: Data("内容🙂".utf8), name: name)
            XCTAssertEqual(try Data(contentsOf: vault.exportURL(file)), Data("内容🙂".utf8))
        }
    }
    func testLegacyLongFilenameCanStillExportWithoutRewritingTheArchive() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        var file = try vault.save(data: Data("旧附件内容".utf8), name: "旧附件.md")
        file.name = String(repeating: "旧版中文长文件名", count: 16) + ".md"
        let original = file.name; let url = try vault.exportURL(file)
        XCTAssertLessThanOrEqual(url.lastPathComponent.utf8.count, 220)
        XCTAssertEqual(url.pathExtension, "md")
        XCTAssertEqual(try Data(contentsOf: url), Data("旧附件内容".utf8))
        XCTAssertEqual(file.name, original)
    }
    @MainActor func testOfficeGenerationAndExtractionRunOffTheUIExecutor() async throws {
        let result = try await FileWork.run {
            let isMain = Thread.isMainThread
            let word = try FileFormats.generatePortable(format: "docx", content: "后台文档🙂\n第二段")
            let excel = try FileFormats.generatePortable(format: "xlsx", content: #"[["项目",12.5]]"#)
            return (isMain, try FileFormats.extract(word, ext: "docx"), try FileFormats.extract(excel, ext: "xlsx"))
        }
        XCTAssertFalse(result.0)
        XCTAssertEqual(result.1, "后台文档🙂\n第二段\n")
        XCTAssertTrue(result.2.contains("12.5"))
    }
    @MainActor func testWorkerCancellationPreventsSavingAnUntrackedFile() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        let started = DispatchSemaphore(value: 0); let release = DispatchSemaphore(value: 0)
        let task = Task { try await FileWork.run {
            started.signal(); _ = release.wait(timeout: .now() + 3)
            return try vault.save(data: Data("取消的内容".utf8), name: "取消.txt")
        } }
        let cancellation = Task.detached {
            _ = started.wait(timeout: .now() + 3); task.cancel(); release.signal()
        }
        do { _ = try await task.value; XCTFail("Cancellation must reach the worker") }
        catch { XCTAssertTrue(error is CancellationError) }
        await cancellation.value
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: vault.directory.path), [])
    }
    @MainActor func testStoppedAndFailedPartialRepliesRemainAvailableToFollowUp() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        let file = try vault.save(data: Data("已生成".utf8), name: "生成.txt", text: "已生成")
        for status in [ChatMessage.Status.cancelled, .failed] {
            let history = [ChatMessage(role: .assistant, text: "已经解释的第一部分", status: status, attachments: [file]), ChatMessage(role: .user, text: "继续")]
            for responses in [true, false] {
                let input = try ChatAgentClient.historyInput(history, responses: responses, vault: vault)
                XCTAssertEqual(input.count, 2); XCTAssertEqual(input.first?["role"] as? String, "assistant")
                let text = try XCTUnwrap(input.first?["content"] as? String)
                XCTAssertTrue(text.contains("已中断")); XCTAssertTrue(text.contains("第一部分")); XCTAssertTrue(text.contains(file.id.uuidString))
            }
        }
        XCTAssertTrue(try ChatAgentClient.historyInput([ChatMessage(role: .assistant, text: "", status: .failed)], responses: true, vault: vault).isEmpty)
    }
    @MainActor func testRepeatedContainerCitationsDownloadOnlyOnceAcrossToolRounds() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ToolRuntime(vault: try FileVault(accountID: UUID(), root: root), files: [], servers: [], approve: { _, _ in false }, event: { _ in })
        let connection = APIConnection(name: "Synthetic", baseURL: "https://api.openai.com/v1", apiKey: "synthetic", modelIDs: ["m"])
        let endpoint = AgentEndpoint(token: "synthetic", connection: connection)
        let output: [[String: Any]] = [["type": "message", "content": [["annotations": [["type": "container_file_citation", "container_id": "cntr_test", "file_id": "file_test", "filename": "结果.txt"]]]]]]
        var downloads = 0
        for _ in 0..<2 {
            try await ChatAgentClient.collectFiles(output, endpoint: endpoint, runtime: runtime, download: { _ in downloads += 1; return Data("实际文件".utf8) })
        }
        XCTAssertEqual(downloads, 1); XCTAssertEqual(runtime.files.count, 1)
        XCTAssertEqual(runtime.files.first?.extractedText, "实际文件")
    }
    @MainActor func testGeneratedImagesAreDeduplicatedAndInvalidImageEncodingReportsFailure() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = ToolRuntime(vault: try FileVault(accountID: UUID(), root: root), files: [], servers: [], approve: { _, _ in false }, event: { _ in })
        let endpoint = AgentEndpoint(token: "synthetic", connection: APIConnection(name: "Test", baseURL: "https://api.openai.com/v1", apiKey: "synthetic", modelIDs: ["m"]))
        let image = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }.pngData())
        let output: [[String: Any]] = [["type": "image_generation_call", "id": "img_test", "result": image.base64EncodedString()]]
        for _ in 0..<2 { try await ChatAgentClient.collectFiles(output, endpoint: endpoint, runtime: runtime) }
        XCTAssertEqual(runtime.files.count, 1)
        do {
            try await ChatAgentClient.collectFiles([["type": "image_generation_call", "id": "img_bad", "result": "not base64 !"]], endpoint: endpoint, runtime: runtime)
            XCTFail("Invalid data must not be reported as a successfully saved image")
        } catch { XCTAssertTrue(error.localizedDescription.contains("无效")) }
        XCTAssertEqual(runtime.files.count, 1)
    }
    @MainActor func testZipHandlesCollidingOriginalAndPrefixedFilenames() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let vault = try FileVault(accountID: UUID(), root: root)
        let files = try ["a.txt", "3-a.txt", "a.txt"].enumerated().map { try vault.save(data: Data("item-\($0.offset)".utf8), name: $0.element) }
        let runtime = ToolRuntime(vault: vault, files: files, servers: [], approve: { _, _ in false }, event: { _ in })
        let args = try JSONSerialization.data(withJSONObject: ["name": "all.zip", "file_ids": files.map { $0.id.uuidString }])
        let output = try await runtime.execute(ToolCall(id: "zip", name: "zip_files", arguments: String(decoding: args, as: UTF8.self)))
        XCTAssertFalse(output.hasPrefix("Tool error:"))
        let zip = try DocumentArchive(vault.data(XCTUnwrap(runtime.files.last)))
        XCTAssertEqual(zip.entries.count, 3); XCTAssertEqual(Set(zip.entries.map(\.name)).count, 3)
        XCTAssertEqual(try Set(zip.entries.map { String(decoding: try zip.content($0.name), as: UTF8.self) }), Set(["item-0", "item-1", "item-2"]))
    }
    @MainActor func testMultilineToolProgressUsesValidatedSSEFraming() throws {
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        var decoder = ResponsesWireDecoder(response: response); var activities: [ToolActivity] = []
        for line in ["data: {", #"data: "type":"response.web_search_call.in_progress","item_id":"search1"}"#] {
            XCTAssertFalse(try decoder.push(line, onActivity: { activities.append($0) }) { _ in })
        }
        XCTAssertTrue(activities.isEmpty)
        XCTAssertFalse(try decoder.push("", onActivity: { activities.append($0) }) { _ in })
        XCTAssertEqual(activities.map(\.id), ["search1"])
        var failed = ResponsesWireDecoder(response: HTTPURLResponse(url: response.url!, statusCode: 401, httpVersion: "HTTP/1.1", headerFields: [:])!)
        XCTAssertThrowsError(try failed.push(#"{"type":"response.web_search_call.completed","item_id":"bad"}"#, onActivity: { activities.append($0) }) { _ in })
        XCTAssertEqual(activities.count, 1)
    }
    @MainActor func testLiveResponseTaskIsCancelledAfterTerminalEvent() async throws {
        let session = session(); let stopped = expectation(description: "Underlying response task cancelled")
        OpenResponseProtocol.status = 200; OpenResponseProtocol.stopped = stopped
        OpenResponseProtocol.payload = Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[]}}\n\n".utf8)
        defer { OpenResponseProtocol.stopped = nil; session.invalidateAndCancel() }
        let output = try await ChatAgentClient.responsesTurn(URLRequest(url: URL(string: "https://synthetic.invalid/stream")!), using: session, delta: { _ in }, activity: { _ in })
        XCTAssertTrue(output.isEmpty)
        await fulfillment(of: [stopped], timeout: 2)
    }
    func testHTTPFailureCancelsAnUnfinishedBodyImmediately() async throws {
        let session = session(); let stopped = expectation(description: "Failed HTTP task cancelled")
        OpenResponseProtocol.status = 403; OpenResponseProtocol.stopped = stopped; OpenResponseProtocol.payload = Data()
        defer { OpenResponseProtocol.stopped = nil; session.invalidateAndCancel() }
        do { _ = try await BoundedHTTP.read(URLRequest(url: URL(string: "https://synthetic.invalid/error")!), using: session); XCTFail("HTTP failure expected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("403")) }
        await fulfillment(of: [stopped], timeout: 2)
    }
    @MainActor func testStreamingCheckpointPreservesPartialTextWithoutWritingEveryToolEvent() async throws {
        let root = directory(); let accountID = UUID()
        var continuation: CheckedContinuation<Void, Never>?
        let archiveURL = root.appendingPathComponent(accountID.uuidString + ".json")
        let connection = APIConnection(name: "Test", baseURL: "https://example.com/v1", apiKey: "synthetic", modelIDs: ["m"])
        let store = ChatStore(accountID: accountID, auth: AuthManager(), apiConnection: connection, storageDirectory: root,
            mcpConnections: MCPConnections(memoryOnly: true), agentTransport: { runtime, delta in
                let before = try Data(contentsOf: archiveURL)
                for _ in 0..<100 { runtime.event(.activity(ToolActivity(id: "tool", name: "search_web", detail: "正在执行"))) }
                XCTAssertEqual(try Data(contentsOf: archiveURL), before)
                delta("正在生成的实际内容🙂")
                await withCheckedContinuation { continuation = $0 }
            }, checkpointInterval: 20_000_000)
        defer { store.stopAll(); continuation?.resume(); try? FileManager.default.removeItem(at: root) }
        await store.loadModels(); XCTAssertTrue(store.send("测试"))
        var saved: ChatArchive?
        for _ in 0..<100 {
            let archive = try ChatArchive.decode(Data(contentsOf: archiveURL))
            if archive.threads.first?.messages.last?.text == "正在生成的实际内容🙂" { saved = archive; break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertNotNil(saved); XCTAssertTrue(store.isSending)
        XCTAssertEqual(saved?.threads.first?.messages.last?.toolActivities?.count, 1)
        XCTAssertEqual(saved?.threads.first?.messages.last?.status, .streaming)
        store.stop()
        let final = try ChatArchive.decode(Data(contentsOf: archiveURL))
        XCTAssertEqual(final.threads.first?.messages.last?.status, .cancelled)
        XCTAssertEqual(final.threads.first?.messages.last?.text, "正在生成的实际内容🙂")
    }
}
