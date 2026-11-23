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
        app.scrollToHittable(app.buttons["reading.awaitingDirector"]).tap()
        app.scrollToHittable(app.staticTexts["تحديث إجراءات استلام العينات"]).tap()
        app.scrollToHittable(app.buttons["action.approve"]).tap()
        app.expectTaskStatus("مكتملة")
        XCTAssertTrue(app.buttons["action.approve"].waitForNonExistence(timeout: 5),
                      "approved task offers no further approval")
    }

    /// Returning requires a note (spec §12); the action is blocked until one is typed.
    func testReturnRequiresNote() {
        let app = launch()
        app.scrollToHittable(app.buttons["reading.awaitingDirector"]).tap()
        app.scrollToHittable(app.staticTexts["تحديث إجراءات استلام العينات"]).tap()
        app.scrollToHittable(app.buttons["action.return"]).tap()
        let confirm = app.buttons["confirmNote"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        XCTAssertFalse(confirm.isEnabled)
        let field = app.textViews["noteField"].exists ? app.textViews["noteField"] : app.textFields["noteField"]
        field.tap()
        field.typeText("أرفق المحضر")
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        app.expectTaskStatus("معادة للاستكمال")
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
        app.expectTaskStatus("مرفوعة للاعتماد")
        XCTAssertFalse(app.buttons["action.approve"].exists, "assignee cannot approve own submission")
    }

    func testLargeTextDoesNotHideDecisions() {
        let app = launch(extraArgs: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        XCTAssertTrue(app.staticTexts["تحتاج قرارك"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.firstMatch.buttons.count == 5)
    }
}

private extension XCUIApplication {
    /// Finds `element` the way a user would: gives the screen time to load, and
    /// scrolls to reveal rows that lazy lists only create once they are near the
    /// viewport. Then scrolls toward the element until it is hittable.
    @discardableResult
    func scrollToHittable(_ element: XCUIElement, loadTimeout: TimeInterval = 15, settle: TimeInterval = 3,
                          maxSwipes: Int = 8, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let deadline = Date().addingTimeInterval(loadTimeout)
        let startScanning = Date().addingTimeInterval(settle)   // don't swipe while content is still loading
        var swipes = 0
        while !element.exists && Date() < deadline {
            if Date() >= startScanning && swipes < maxSwipes {
                swipeUp()
                swipes += 1
            } else {
                _ = element.waitForExistence(timeout: 0.5)
            }
        }
        XCTAssertTrue(element.exists, "\(element) never appeared (after \(swipes) swipes)", file: file, line: line)
        while element.exists && !element.isHittable && swipes < maxSwipes * 2 {
            if element.frame.minY < frame.midY { swipeDown() } else { swipeUp() }
            swipes += 1
        }
        XCTAssertTrue(element.exists && element.isHittable, "\(element) not reachable after \(swipes) swipes",
                      file: file, line: line)
        return element
    }

    /// Asserts the task detail status badge shows exactly `title`.
    func expectTaskStatus(_ title: String, timeout: TimeInterval = 5,
                          file: StaticString = #filePath, line: UInt = #line) {
        let badge = descendants(matching: .any)["taskStatusBadge"]
        let matches = NSPredicate(format: "label == %@", title)
        let expectation = XCTNSPredicateExpectation(predicate: matches, object: badge)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "task status is '\(badge.exists ? badge.label : "<missing>")', expected '\(title)'",
                       file: file, line: line)
    }
}
