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
        toggle.tap(); XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap(); XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertFalse(app.staticTexts["OpenAI 云端工具"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = "dark-system-switches"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["mcp.discover"].tap()
        let deepwiki = app.descendants(matching: .any).matching(identifier: "mcp.listing.recommended-deepwiki").firstMatch
        XCTAssertTrue(deepwiki.waitForExistence(timeout: 5)); deepwiki.tap()
        app.buttons["添加连接"].tap()
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
        XCTAssertTrue(app.buttons["添加连接"].waitForExistence(timeout: 5))
    }
}
