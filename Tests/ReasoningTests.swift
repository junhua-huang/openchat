import XCTest
@testable import LiaoChat

final class ReasoningTests: XCTestCase {
    func testCatalogCapabilitiesAndPerModelOverride() throws {
        let data = Data(#"{"data":[{"id":"alias","name":"Gateway model","reasoning":{"supported_efforts":["low","high"]}}]}"#.utf8)
        let models = try APIChatClient.decodeModels(data)
        XCTAssertEqual(models.first?.reasoningEfforts, ["low", "high"])
        var api = connection("https://example.com/v1")
        api.modelReasoningEfforts = ["alias": models[0].reasoningEfforts!]
        XCTAssertEqual(ReasoningSupport.options(model: "alias", connection: api), [.low, .high])
        api.reasoningFormat = "object"
        let request = try body(APIChatClient.chatRequest(connection: api, model: "alias", history: [], effort: .high))
        XCTAssertEqual(request["reasoning"] as? [String: String], ["effort": "high"])
        XCTAssertNil(request["reasoning_effort"])
        api.reasoningOverrides = ["alias": []]
        XCTAssertTrue(ReasoningSupport.options(model: "alias", connection: api).isEmpty)
        XCTAssertThrowsError(try APIChatClient.chatRequest(connection: api, model: "alias", history: [], effort: .high))
    }

    private func connection(_ base: String = "https://api.openai.com/v1") -> APIConnection {
        APIConnection(name: "Synthetic", baseURL: base, apiKey: "synthetic-key", modelIDs: ["gpt-6.1-sol"])
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    func testPlanEffortsUseResponsesReasoningObjectAndKeepRequiredFlags() throws {
        for effort in ReasoningSupport.options(model: "gpt-6.1-sol") {
            let request = try ResponsesClient.request(token: "synthetic-token", model: "gpt-6.1-sol",
                history: [ChatMessage(role: .user, text: "你好🙂")], effort: effort)
            let json = try body(request)
            XCTAssertEqual(json["reasoning"] as? [String: String], ["effort": effort.rawValue])
            XCTAssertEqual(json["store"] as? Bool, false)
            XCTAssertEqual(json["stream"] as? Bool, true)
            XCTAssertEqual(json["input"] as? [[String: String]], [["role": "user", "content": "你好🙂"]])
            XCTAssertNil(json["reasoning_effort"])
        }
        XCTAssertThrowsError(try ResponsesClient.request(token: "synthetic-token", model: "gpt-6.1-sol", history: [], effort: .none))
        XCTAssertThrowsError(try ResponsesClient.request(token: "synthetic-token", model: "gpt-6.1-sol", history: [], effort: .minimal))
    }
    func testChatCompletionsUsesFlatEffortAndDefaultOmitsBothFields() throws {
        let explicit = try body(APIChatClient.chatRequest(connection: connection(), model: "gpt-6-luna", history: [], effort: .none))
        XCTAssertEqual(explicit["reasoning_effort"] as? String, "none")
        XCTAssertNil(explicit["reasoning"])
        let plan = try body(ResponsesClient.request(token: "synthetic-token", model: "unknown", history: []))
        let api = try body(APIChatClient.chatRequest(connection: connection("https://example.com/v1"), model: "unknown", history: []))
        for json in [plan, api] {
            XCTAssertNil(json["reasoning"]); XCTAssertNil(json["reasoning_effort"])
        }
    }
    func testUnknownModelsAndOtherProvidersCannotReceiveUnsupportedParameters() throws {
        for model in ["gpt-6.1-sol-custom", "GPT-6.1-Sol", "gpt-4.1", "deepseek-reasoner", "unknown"] {
            XCTAssertTrue(ReasoningSupport.options(model: model).isEmpty)
            XCTAssertThrowsError(try ResponsesClient.request(token: "synthetic-token", model: model, history: [], effort: .high))
        }
        for base in ["https://example.com/v1", "https://api.openai.com.example.com/v1", "https://api.openai.com/custom/v1",
                     "https://api.openai.com:8443/v1"] {
            XCTAssertTrue(ReasoningSupport.options(model: "gpt-6.1-sol", connection: connection(base)).isEmpty)
            XCTAssertThrowsError(try APIChatClient.chatRequest(connection: connection(base), model: "gpt-6.1-sol", history: [], effort: .high))
        }
    }
    func testVersionAndEditBranchPreserveTheirOriginalEffortMetadata() throws {
        var message = ChatMessage(role: .assistant, text: "第一版", model: "gpt-6.1-sol", reasoningEffort: "low")
        message.beginRegeneration(model: "gpt-6.1-sol", reasoningEffort: "high")
        message.text = "第二版"; message.status = .complete; message.recordVersion()
        XCTAssertTrue(message.chooseVersion(0)); XCTAssertEqual(message.reasoningEffort, "low")
        XCTAssertTrue(message.chooseVersion(1)); XCTAssertEqual(message.reasoningEffort, "high")
        let user = ChatMessage(role: .user, text: "原问题")
        let thread = ChatThread(model: "gpt-6.1-sol", messages: [user, message], reasoningEfforts: ["gpt-6.1-sol": "max"])
        let archive = try ChatArchive.decode(JSONEncoder().encode(ChatArchive(threads: [thread], selectedID: thread.id)))
        let branch = try XCTUnwrap(archive.threads.first?.editing(user.id, text: "新问题"))
        XCTAssertEqual(branch.reasoningEfforts, ["gpt-6.1-sol": "max"])
        XCTAssertEqual(archive.threads.first?.messages.last?.versions?.map(\.reasoningEffort), ["low", "high"])
    }
    @MainActor func testLegacyArchiveAndUnknownFutureEffortRemainReadable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(); let thread = ChatThread(model: "gpt-6.1-sol", reasoningEfforts: ["gpt-6.1-sol": "future-effort"])
        // Legacy array format with an unrecognized value must not pause storage.
        try JSONEncoder().encode([thread]).write(to: directory.appendingPathComponent(id.uuidString + ".json"))
        let store = ChatStore(accountID: id, auth: AuthManager(), apiConnection: connection(), storageDirectory: directory,
                              transport: { _, _, _, _ in })
        await store.loadModels()
        XCTAssertTrue(store.storageReady); XCTAssertEqual(store.selectedEffort, .automatic)
        store.selectEffort(.high); store.flushDrafts()
        let archive = try ChatArchive.decode(Data(contentsOf: directory.appendingPathComponent(id.uuidString + ".json")))
        XCTAssertEqual(archive.threads.first?.reasoningEfforts?["gpt-6.1-sol"], "high")
    }
}
