import XCTest

final class WorkspaceInteractionTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-preview", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCTAssertTrue(app.buttons["chat.history"].waitForExistence(timeout: 15))
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
}
