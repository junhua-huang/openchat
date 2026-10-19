import XCTest
@testable import LiaoChat

final class UXReliabilityTests: XCTestCase {
    @MainActor func testCachedModelsAndSelectionSurviveOfflineRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(); let cache = ModelCatalogCache(defaults: nil)
        cache.save([ModelChoice(slug: "a", display_name: "A", visibility: "list"),
                    ModelChoice(slug: "b", display_name: "B", visibility: "list")], for: id)
        let auth = AuthManager()
        let first = ChatStore(accountID: id, auth: auth, storageDirectory: root, modelCatalogCache: cache,
            modelLoader: { throw URLError(.notConnectedToInternet) })
        await first.loadModels()
        XCTAssertEqual(first.models.map(\.slug), ["a", "b"])
        first.selectModel("b"); first.flushDrafts()
        let restored = ChatStore(accountID: id, auth: auth, storageDirectory: root, modelCatalogCache: cache,
            modelLoader: { throw URLError(.timedOut) })
        await restored.loadModels()
        XCTAssertEqual(restored.selectedModel, "b")
        XCTAssertEqual(restored.models.map(\.slug), ["a", "b"])
        XCTAssertNotNil(restored.modelCatalogNotice)
        XCTAssertNil(restored.errorText)
    }

    @MainActor func testFailedAPIRefreshRetainsManualAndCachedModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ModelCatalogCache(defaults: nil); let id = UUID()
        cache.save([ModelChoice(slug: "cached", display_name: "Cached", visibility: nil, reasoningEfforts: ["high"])], for: id)
        let api = APIConnection(name: "Synthetic", baseURL: "https://synthetic.invalid/v1", apiKey: "synthetic", modelIDs: ["manual"])
        let store = ChatStore(accountID: id, auth: AuthManager(), apiConnection: api, storageDirectory: root,
            modelCatalogCache: cache, modelLoader: { throw URLError(.notConnectedToInternet) })
        await store.loadModels(refresh: true)
        XCTAssertEqual(store.models.map(\.slug), ["manual", "cached"])
        store.selectModel("cached")
        XCTAssertEqual(store.effortOptions, [.high])
    }

    @MainActor func testCatalogCachePersistsPerConnectionWithoutCredentials() throws {
        let suite = "ux-catalog-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let cache = ModelCatalogCache(defaults: defaults)
        cache.save([ModelChoice(slug: "a", display_name: "A", visibility: nil)], for: id)
        XCTAssertEqual(ModelCatalogCache(defaults: defaults).models(for: id).map(\.slug), ["a"])
        XCTAssertTrue(ModelCatalogCache(defaults: defaults).models(for: UUID()).isEmpty)
    }

    @MainActor func testMemoryDraftRestoresWithoutBeingSharedOrOverwritingNewProgress() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = WorkingMemoryStore(directory: root)
        try memory.replace("已保存的任务", expectedRevision: 0)
        try memory.saveDraft(WorkingMemoryDraft(text: "UNSAVED-EDIT", baseText: memory.content.text, baseRevision: 1))
        try memory.replace("其他模型更新的进展", expectedRevision: 1)
        let restored = WorkingMemoryStore(directory: root)
        XCTAssertEqual(restored.draft?.text, "UNSAVED-EDIT")
        XCTAssertEqual(restored.draft?.baseRevision, 1)
        XCTAssertEqual(restored.content.revision, 2)
        XCTAssertFalse(restored.context?.contains("UNSAVED-EDIT") == true)
        XCTAssertThrowsError(try restored.replace("UNSAVED-EDIT", expectedRevision: 1))
        try restored.discardDraft()
        XCTAssertNil(WorkingMemoryStore(directory: root).draft)
        XCTAssertEqual(restored.content.text, "其他模型更新的进展")
    }

    @MainActor func testCorruptDraftDoesNotDisableSavedMemory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = WorkingMemoryStore(directory: root)
        try memory.replace("有效记忆", expectedRevision: 0)
        let file = root.appendingPathComponent("working-memory-draft.json")
        let original = Data("corrupt draft".utf8); try original.write(to: file)
        let restored = WorkingMemoryStore(directory: root)
        XCTAssertTrue(restored.ready); XCTAssertNotNil(restored.context)
        XCTAssertNotNil(restored.draftProblem); XCTAssertNil(restored.draft)
        XCTAssertEqual(try Data(contentsOf: file), original)
    }
}
