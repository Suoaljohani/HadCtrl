import XCTest

/// Deterministic UI scenarios on mock repositories (HC_APP_ENV=ui-testing).
/// Arabic locale forces the RTL layout path.
final class HadCtrlUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(user: String = "director", extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HC_APP_ENV"] = "ui-testing"
        app.launchEnvironment["HC_DEMO_USER"] = user
        app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"] + extraArgs
        app.launch()
        return app
    }

    func testFiveStableTabsAndDemoBanner() {
        let app = launch()
        XCTAssertTrue(app.otherElements["decisionsSection"].waitForExistence(timeout: 10) ||
                      app.staticTexts["تحتاج قرارك"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["demoBanner"].exists || app.otherElements["demoBanner"].exists)
        let tabBar = app.tabBars.firstMatch
        XCTAssertEqual(tabBar.buttons.count, 5, "exactly five navigation tabs; creation is an action, not a tab")
        for title in ["الرئيسية", "الأقسام", "الأداء", "التنفيذ", "التقارير"] {
            XCTAssertTrue(tabBar.buttons[title].exists, "missing tab \(title)")
        }
        tabBar.buttons["الأقسام"].tap()
        XCTAssertTrue(app.staticTexts["المختبر"].waitForExistence(timeout: 5))
        tabBar.buttons["التنفيذ"].tap()
        XCTAssertTrue(app.staticTexts["التنفيذ"].waitForExistence(timeout: 5))
    }

    /// Director opens "awaiting your approval", reviews the submitted task and approves it.
    func testDirectorApprovesSubmittedTask() {
        let app = launch()
        let tile = app.buttons["reading.awaitingDirector"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        let row = app.staticTexts["تحديث إجراءات استلام العينات"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        let approve = app.buttons["action.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5))
        approve.tap()
        XCTAssertTrue(app.staticTexts["مكتملة"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["action.approve"].exists, "approved task offers no further approval")
    }

    /// Returning requires a note (spec §12); the action is blocked until one is typed.
    func testReturnRequiresNote() {
        let app = launch()
        app.buttons["reading.awaitingDirector"].firstMatchWait()
        app.staticTexts["تحديث إجراءات استلام العينات"].firstMatchWait()
        app.buttons["action.return"].firstMatchWait()
        let confirm = app.buttons["confirmNote"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled)
        let field = app.textViews["noteField"].exists ? app.textViews["noteField"] : app.textFields["noteField"]
        field.tap()
        field.typeText("أرفق المحضر")
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(app.staticTexts["معادة للاستكمال"].waitForExistence(timeout: 5))
    }

    /// Department head sees only their department and has no approval on own work.
    func testHeadScopeAndNoSelfApproval() {
        let app = launch(user: "head")
        app.tabBars.firstMatch.buttons["الأقسام"].tap()
        XCTAssertTrue(app.staticTexts["المختبر"].waitForExistence(timeout: 5))
        app.tabBars.firstMatch.buttons["التنفيذ"].tap()
        let submitted = app.staticTexts["تحديث إجراءات استلام العينات"]
        XCTAssertTrue(submitted.waitForExistence(timeout: 5))
        submitted.tap()
        XCTAssertTrue(app.otherElements["taskStatus"].waitForExistence(timeout: 5) || app.staticTexts["مرفوعة للاعتماد"].exists)
        XCTAssertFalse(app.buttons["action.approve"].exists, "assignee cannot approve own submission")
    }

    func testLargeTextDoesNotHideDecisions() {
        let app = launch(extraArgs: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        XCTAssertTrue(app.staticTexts["تحتاج قرارك"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.firstMatch.buttons.count == 5)
    }
}

private extension XCUIElement {
    func firstMatchWait(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(waitForExistence(timeout: timeout), "\(self) not found", file: file, line: line)
        tap()
    }
}
