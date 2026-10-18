import XCTest

final class WorkspaceInteractionTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(extra: [String] = [], workspace: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + extra
        app.launch()
        if workspace { XCTAssertTrue(app.buttons["chat.history"].waitForExistence(timeout: 15)) }
        return app
    }
    @MainActor private func openHistory(_ app: XCUIApplication) {
        let button = app.buttons["chat.history"]
        XCTAssertTrue(button.isHittable)
        // Tap screen coordinates, exercising actual hit testing rather than
        // invoking an accessibility action through an overlapping scroll view.
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["你的对话"].waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "history-opened-by-coordinate-tap"; screenshot.lifetime = .keepAlways
        add(screenshot)
    }
    @MainActor func testHistoryOpensAfterScrollingAndCanReopenAfterDismissal() {
        let app = launch()
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        scroll.swipeUp(); scroll.swipeDown()
        openHistory(app)
        XCTAssertTrue(app.staticTexts["从想法到作品"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        XCTAssertTrue(app.buttons["chat.history"].waitForExistence(timeout: 5))
        openHistory(app)
    }
    @MainActor func testHistoryOpensWithKeyboardAndComposerCanSendAfterDismissal() {
        let app = launch()
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        composer.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        openHistory(app)
        app.buttons["完成"].tap()
        let send = app.buttons["发送消息"]
        XCTAssertTrue(send.waitForExistence(timeout: 5)); XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.staticTexts["这是本地界面预览。"].waitForExistence(timeout: 5))
    }
    @MainActor func testNewConversationRespondsFromHeaderAndHistoryWithKeyboard() {
        let app = launch()
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        composer.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let create = app.buttons["chat.new"]
        XCTAssertTrue(create.isHittable)
        create.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["有什么可以帮你？"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["发送消息"].isEnabled)
        composer.tap(); composer.typeText("keep this draft")
        openHistory(app)
        let historyNew = app.buttons["history.new"]
        XCTAssertTrue(historyNew.isHittable)
        historyNew.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["你的对话"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["有什么可以帮你？"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["发送消息"].isEnabled)
        composer.tap(); composer.typeText("new question")
        XCTAssertTrue(app.buttons["发送消息"].isEnabled); app.buttons["发送消息"].tap()
        XCTAssertTrue(app.staticTexts["这是本地界面预览。"].waitForExistence(timeout: 5))
    }
    @MainActor func testNewConversationResetsScrolledBlankWelcomeWhenReused() {
        let app = launch(extra: ["--ui-empty"])
        for _ in 0..<2 {
            app.scrollViews["chat.conversation"].swipeUp()
            let create = app.buttons["chat.new"]
            create.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let welcome = app.staticTexts["有什么可以帮你？"]
            XCTAssertTrue(welcome.waitForExistence(timeout: 5)); XCTAssertTrue(welcome.isHittable)
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(welcome.frame.minY, create.frame.maxY)
            XCTAssertLessThan(welcome.frame.maxY, app.keyboards.firstMatch.frame.minY)
        }
    }
    @MainActor func testReplySurvivesHomeAndForeground() async throws {
        let app = launch(extra: ["--ui-background"])
        let send = app.buttons["发送消息"]
        XCTAssertTrue(send.isEnabled); send.tap()
        XCUIDevice.shared.press(.home)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        app.activate()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "回复已在后台完成")).firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["网络连接已中断。"].exists)
    }
    @MainActor func testCompactComposerAndChatTapOrDragDismissKeyboard() {
        let app = launch()
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        let add = app.buttons["chat.add"]
        XCTAssertTrue(add.exists); XCTAssertLessThan(abs(add.frame.midY - composer.frame.midY), 20)
        XCTAssertFalse(app.buttons["工具已启用，打开工具设置"].exists)
        composer.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        let chat = app.scrollViews["chat.conversation"]
        let top = app.buttons["chat.history"].frame.maxY + 30
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: app.frame.width * 0.85, dy: top)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        composer.tap(); XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        chat.swipeDown()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        openHistory(app)
    }
    @MainActor func testMessagesScrollBehindFloatingControlsWithoutStealingTaps() {
        let app = launch(extra: ["--ui-floating"])
        let chat = app.scrollViews["chat.conversation"]
        let history = app.buttons["chat.history"]
        let composer = app.descendants(matching: .any).matching(identifier: "chat.composer").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        // A reserved header band would place the scroll view below this button.
        XCTAssertLessThan(chat.frame.minY, history.frame.minY)
        XCTAssertGreaterThan(chat.frame.maxY, composer.frame.maxY)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let upper = history.frame.maxY + 45
        let lower = composer.frame.minY - 45
        let start = origin.withOffset(CGVector(dx: app.frame.width * 0.6, dy: upper + (lower - upper) * 0.4))
        let end = origin.withOffset(CGVector(dx: app.frame.width * 0.6, dy: upper + (lower - upper) * 0.7))
        start.press(forDuration: 0.05, thenDragTo: end)
        let paragraphs = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "悬浮验证第")).allElementsBoundByIndex
        XCTAssertTrue(paragraphs.contains { $0.frame.intersects(history.frame) })
        XCTAssertTrue(paragraphs.contains { $0.frame.intersects(composer.frame) })
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "floating-controls-over-chat"; capture.lifetime = .keepAlways; add(capture)
        openHistory(app); app.buttons["完成"].tap()
        app.buttons["chat.add"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["工具与 MCP"].tap()
        XCTAssertTrue(app.navigationBars["工具与 MCP"].waitForExistence(timeout: 5))
    }
    @MainActor func testFirstSendAndRepeatedStreamingKeepLatestReplyInViewport() {
        let app = launch(extra: ["--ui-empty", "--ui-scroll"])
        let composer = app.textFields["chat.composer"]
        for index in 0..<3 {
            composer.tap(); composer.typeText("测试 \(index)\n输入框展开后发送")
            app.buttons["发送消息"].tap()
            let tail = app.staticTexts["滚动验收结束 \(index * 2 + 1)"]
            XCTAssertTrue(tail.waitForExistence(timeout: 10))
            // Wait for the coalesced post-layout scroll, then verify real geometry.
            let visible = NSPredicate { _, _ in
                // Each native AX lookup can take seconds on a loaded runner.
                // Read each frame once; geometry verifies the actual viewport.
                let replyFrame = tail.frame
                let headerFrame = app.buttons["chat.history"].frame
                let composerFrame = composer.frame
                return !replyFrame.isEmpty && replyFrame.midY > headerFrame.maxY && replyFrame.maxY < composerFrame.minY
            }
            expectation(for: visible, evaluatedWith: nil); waitForExpectations(timeout: 15)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "stream-after-send-\(index)"; shot.lifetime = .keepAlways; add(shot)
        }
        let chat = app.scrollViews["chat.conversation"]
        let top = app.buttons["chat.history"].frame.maxY + 20
        let bottom = composer.frame.minY - 20
        XCTAssertGreaterThan(bottom - top, 60)
        print("Streaming chat bounds: \(chat.frame); visible drag: \(top)...\(bottom); keyboard: \(app.keyboards.firstMatch.frame)")
        // A long lazy scroll view's accessibility frame can include offscreen
        // content. Drag only inside the screen area above the real keyboard.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: bottom - app.frame.minY))
        let end = origin.withOffset(CGVector(dx: app.frame.width / 2, dy: top - app.frame.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
    }
    @MainActor func testToolRecordsRemainAccessibleBelowAnswer() {
        let app = launch(extra: ["--ui-timeline"])
        app.scrollViews.firstMatch.swipeUp()
        let records = app.buttons["chat.tool-record"].firstMatch
        XCTAssertTrue(records.waitForExistence(timeout: 5)); records.tap()
        XCTAssertTrue(app.navigationBars["工具记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["计算"].exists); XCTAssertTrue(app.staticTexts["联网搜索"].exists)
    }
    @MainActor func testDarkSwitchAndRecommendedMCPPrefill() {
        let app = launch(extra: ["--ui-tools", "-appearance", "dark"], workspace: false)
        let toggle = app.switches["允许模型使用工具"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 15)); XCTAssertEqual(toggle.value as? String, "1")
        // SwiftUI exposes the whole labeled row as a Switch. Its center is the
        // label; tap the native thumb at the trailing edge of the row instead.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let offCapture = XCTAttachment(screenshot: app.screenshot()); offCapture.name = "dark-switch-off"; offCapture.lifetime = .keepAlways; add(offCapture)
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == %@", "1"), evaluatedWith: toggle)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.staticTexts["OpenAI 云端工具"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "dark-system-switches"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["mcp.discover"].tap()
        let deepwiki = app.descendants(matching: .any).matching(identifier: "mcp.listing.recommended-deepwiki").firstMatch
        XCTAssertTrue(deepwiki.waitForExistence(timeout: 5)); deepwiki.tap()
        app.buttons["添加连接"].tap()
        XCTAssertTrue(app.buttons["mcp.connect"].waitForExistence(timeout: 5))
        app.buttons["mcp.advanced"].tap()
        let endpoint = app.textFields["mcp.endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5)); XCTAssertEqual(endpoint.value as? String, "https://mcp.deepwiki.com/mcp")
        XCTAssertEqual(app.textFields["mcp.name"].value as? String, "DeepWiki")
    }
    @MainActor func testMCPRegistrySearchShowsSyntheticCompatibleResult() {
        let app = launch(extra: ["--ui-mcp"], workspace: false)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap(); search.typeText("docs")
        XCTAssertTrue(app.staticTexts["测试文档服务"].waitForExistence(timeout: 8))
        app.staticTexts["测试文档服务"].tap()
        XCTAssertTrue(app.navigationBars["服务详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["添加连接"].waitForExistence(timeout: 5))
    }
    @MainActor func testMCPVendorSearchFindsChineseNamesAndExplainsSetupRequirements() {
        let app = launch(extra: ["--ui-mcp"], workspace: false)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 15)); search.tap(); search.typeText("微软")
        let microsoft = app.descendants(matching: .any).matching(identifier: "mcp.listing.recommended-microsoft").firstMatch
        XCTAssertTrue(microsoft.waitForExistence(timeout: 5)); microsoft.tap()
        XCTAssertTrue(app.staticTexts["https://learn.microsoft.com/api/mcp"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["添加连接"].exists)
        app.navigationBars.buttons.firstMatch.tap()
        search.tap(); search.buttons.firstMatch.tap()
        search.typeText("Figma")
        let figma = app.descendants(matching: .any).matching(identifier: "mcp.listing.vendor-figma").firstMatch
        XCTAssertTrue(figma.waitForExistence(timeout: 5)); figma.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "OpenChat 尚未获准")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["添加连接"].exists)
    }
    @MainActor func testGitHubMCPShowsCompactUsableConnectionWithoutDeveloperFields() {
        let app = launch(extra: ["--ui-github"], workspace: false)
        let token = app.secureTextFields["mcp.token"]
        XCTAssertTrue(token.waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["mcp.oauth-client-id"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "mcp.oauth-callback").firstMatch.exists)
        XCTAssertFalse(app.textFields["mcp.endpoint"].exists)
        let connect = app.buttons["mcp.connect"]
        XCTAssertTrue(connect.exists); XCTAssertFalse(connect.isEnabled)
        XCTAssertGreaterThanOrEqual(connect.frame.height, 44)
        XCTAssertLessThan(connect.frame.maxY, app.frame.maxY)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mcp.github-token-help").firstMatch.exists)
        token.tap(); token.typeText("synthetic-token")
        XCTAssertTrue(connect.isEnabled); XCTAssertTrue(connect.isHittable)
        XCTAssertLessThanOrEqual(connect.frame.maxY, app.keyboards.firstMatch.frame.minY)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "github-compact-connection"; capture.lifetime = .keepAlways; add(capture)
        // No real GitHub request, browser login, clipboard read or paid model call.
    }
    @MainActor func testMCPAdvancedOAuthOptionsRemainOptionalAndConnectionActionStaysVisible() {
        let app = launch(extra: ["--ui-github"], workspace: false)
        let advanced = app.buttons["mcp.advanced"]
        XCTAssertTrue(advanced.waitForExistence(timeout: 15)); advanced.tap()
        let endpoint = app.textFields["mcp.endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        XCTAssertEqual(endpoint.value as? String, "https://api.githubcopilot.com/mcp/")
        app.buttons["mcp.auth-method"].tap(); app.buttons["OAuth 登录"].tap()
        XCTAssertTrue(app.textFields["mcp.oauth-client-id"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "mcp.oauth-callback").firstMatch.exists)
        advanced.tap()
        XCTAssertFalse(app.textFields["mcp.oauth-client-id"].exists)
        XCTAssertTrue(app.buttons["mcp.connect"].isHittable)
    }
}
