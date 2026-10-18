import Foundation

// The standalone checker compiles a subset of Core without the app's auth stack.
enum AppFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

// Runs directly on the macOS host with swiftc, without an iOS simulator.
@main struct PortableCoreChecks {
    @MainActor static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }

        for readOnly in [nil, false, true] as [Bool?] {
            for destructive in [nil, false, true] as [Bool?] {
                let annotations = MCPToolAnnotations(readOnlyHint: readOnly, destructiveHint: destructive)
                check(MCPApprovalPolicy.always.requiresConfirmation(for: annotations), "Always must ask")
                check(!MCPApprovalPolicy.never.requiresConfirmation(for: annotations), "Explicit full trust must skip")
                check(MCPApprovalPolicy.readOnly.requiresConfirmation(for: annotations)
                      == (readOnly != true || destructive == true), "Only clearly read-only tools may skip")
            }
        }
        check(MCPApprovalPolicy.readOnly.requiresConfirmation(for: nil), "Missing metadata must ask")
        check(MCPApprovalPolicy.always.requiresConfirmation(for: nil), "Always must ask without metadata")
        check(!MCPApprovalPolicy.never.requiresConfirmation(for: nil), "Full trust applies to unannotated tools")
        let hint = try JSONDecoder().decode(MCPToolAnnotations.self, from: Data(#"{"readOnlyHint":true,"title":"Search","futureHint":true}"#.utf8))
        check(!MCPApprovalPolicy.readOnly.requiresConfirmation(for: hint), "Decode standard annotations")
        for policy in MCPApprovalPolicy.allCases {
            let decoded = try JSONDecoder().decode(MCPApprovalPolicy.self, from: JSONEncoder().encode(policy))
            check(decoded == policy, "Trust choice must round-trip")
        }
        let future = try JSONDecoder().decode(MCPApprovalPolicy.self, from: Data(#""future-policy""#.utf8))
        check(future == .always, "Unknown policy must ask")

        var connection = APIConnection(name: "Gateway", baseURL: "https://example.com/v1", apiKey: "synthetic", modelIDs: ["alias"])
        check(ReasoningSupport.options(model: "alias", connection: connection).isEmpty, "Unknown API must omit effort by default")
        connection.modelReasoningEfforts = ["alias": ["low", "high", "future"]]
        check(ReasoningSupport.options(model: "alias", connection: connection) == [.low, .high], "Catalog levels must be preserved")
        connection.reasoningOverrides = ["alias": []]
        check(ReasoningSupport.options(model: "alias", connection: connection).isEmpty, "Explicit disable overrides catalog")
        connection.reasoningOverrides = ["alias": ["medium", "high"]]
        try ReasoningSupport.validate(.high, model: "alias", connection: connection)
        var body: [String: Any] = [:]
        ReasoningSupport.apply(.automatic, to: &body, responses: false, connection: connection)
        check(body.isEmpty, "Default must not send reasoning parameters")
        ReasoningSupport.apply(.high, to: &body, responses: false, connection: connection)
        check(body["reasoning_effort"] as? String == "high", "Chat flat effort")
        connection.reasoningFormat = "object"; body = [:]
        ReasoningSupport.apply(.medium, to: &body, responses: false, connection: connection)
        check(body["reasoning"] as? [String: String] == ["effort": "medium"], "Gateway object effort")
        connection.reasoningFormat = "flat"; body = [:]
        ReasoningSupport.apply(.high, to: &body, responses: true, connection: connection)
        check(body["reasoning"] as? [String: String] == ["effort": "high"], "Responses always uses object")
        let restoredConnection = try JSONDecoder().decode(APIConnection.self, from: JSONEncoder().encode(connection))
        check(restoredConnection.reasoningOverrides == connection.reasoningOverrides, "Per-model capabilities persist")

        let memory = WorkingMemoryContent()
        let saved = try memory.replacing("目标：完成报告；下一步：核实数据。", expectedRevision: 0)
        check(saved.revision == 1 && saved.context != nil, "Shared memory must enter context")
        do { _ = try saved.replacing("覆盖", expectedRevision: 0); preconditionFailure("Stale write accepted") }
        catch WorkingMemoryContent.Failure.changed { count += 1 }
        do { _ = try saved.replacing(String(repeating: "字", count: 8001), expectedRevision: 1); preconditionFailure("Oversized memory accepted") }
        catch WorkingMemoryContent.Failure.tooLong { count += 1 }
        var disabled = saved; disabled.enabled = false
        check(disabled.context == nil, "Disabled memory must not enter context")
        let restoredMemory = try JSONDecoder().decode(WorkingMemoryContent.self, from: JSONEncoder().encode(saved))
        check(restoredMemory == saved, "Memory must round-trip")
        let cleared = try saved.replacing("", expectedRevision: 1)
        check(cleared.context == nil, "Cleared memory must not enter context")

        let draft = WorkingMemoryDraft(text: "尚未保存的编辑", baseText: saved.text, baseRevision: saved.revision)
        let restoredDraft = try JSONDecoder().decode(WorkingMemoryDraft.self, from: JSONEncoder().encode(draft))
        check(restoredDraft == draft, "Memory edit draft must round-trip independently")
        let sharedJSON = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        check(!sharedJSON.contains(draft.text), "Draft must never enter saved memory")
        let a = UUID(); let b = UUID()
        let cache = ModelCatalogCache(defaults: nil)
        cache.save([ModelChoice(slug: "a", display_name: "Model A", visibility: nil, reasoningEfforts: ["high"]),
                    ModelChoice(slug: "a", display_name: "Duplicate", visibility: nil)], for: a)
        cache.save([ModelChoice(slug: "b", display_name: "Model B", visibility: nil)], for: b)
        check(cache.models(for: a).map(\.slug) == ["a"], "Catalog must deduplicate model IDs")
        check(cache.models(for: a).first?.reasoningEfforts == ["high"], "Cache must retain reasoning levels")
        check(cache.models(for: b).map(\.slug) == ["b"], "Catalogs must stay separated by connection")
        let merged = ModelCatalog.merged(manual: ["manual", "a"], remote: cache.models(for: a))
        check(merged.map(\.slug) == ["manual", "a"], "Manual models and their order must survive refresh")
        check(merged.last?.display_name == "Model A", "Remote metadata must enrich configured models")
        check(ReplyProgress.current(approval: true, paused: false, runningTool: "create_file", hasText: false) == .approval,
              "Approval wait must not claim inference is running")
        check(ReplyProgress.current(approval: false, paused: true, runningTool: "create_file", hasText: true) == .paused,
              "Foreground wait must show paused")
        check(ReplyProgress.current(approval: false, paused: false, runningTool: "update_working_memory", hasText: true).title == "正在更新工作记忆…",
              "Memory activity must use readable titles")
        check(ComposerDraft.insertingSuggestion("建议", into: "原草稿") == "原草稿\n\n建议", "Suggestions must preserve unsent text")

        let inline = #"中文 \(\frac{x}{1-0.01y}\) 与 $z_1^2$"#
        check(MessageMath.parts(inline).filter { if case .math = $0 { return true }; return false }.count == 2,
              "Both inline delimiters must preserve LaTeX")
        for text in [#"价格 \$5 和 \$10"#, "价格 $5 和 $10", "$$x", #"\[\frac{x}{"#,
                     #"`$x$` [链接](https://example.com/$y$)"#] {
            check(MessageMath.parts(text) == [.text(text)], "Code, prices, links and incomplete streaming must stay text")
        }
        let display = #"\[\frac{x}{1-0.01y}\]"#
        check(MessageMath.parts(display) == [.math(MathExpression(latex: #"\frac{x}{1-0.01y}"#,
              display: true, source: display))], "Display delimiters must render")
        let stream = #"前文🙂 \[\frac{x}{1-y}\] 后文 $z$"#
        for end in stream.indices {
            let prefix = String(stream[..<end])
            let restored = MessageMath.parts(prefix).map { part -> String in
                switch part { case .text(let text): return text; case .math(let math): return math.source }
            }.joined()
            check(restored == prefix, "Streaming must preserve every character")
        }
        print("Passed \(count) portable math, approval, API reasoning and shared-memory checks (no simulator).")
    }
}
