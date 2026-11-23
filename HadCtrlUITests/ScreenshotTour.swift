import XCTest

/// Visual review tour: walks the main screens on mock data and attaches a
/// screenshot of each (kept in the .xcresult; CI exports them as PNG files).
/// Assertions are light on purpose — functional checks live in HadCtrlUITests.
final class ScreenshotTour: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    private func launch(user: String = "director", scheme: String, extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["HC_APP_ENV"] = "ui-testing"
        app.launchEnvironment["HC_DEMO_USER"] = user
        app.launchEnvironment["HC_FORCE_SCHEME"] = scheme
        app.launchArguments += ["-AppleLanguages", "(ar)", "-AppleLocale", "ar_SA"] + extraArgs
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 1.2)   // let transitions and loads settle
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tab(_ app: XCUIApplication, _ title: String) {
        let button = app.tabBars.firstMatch.buttons[title]
        if button.waitForExistence(timeout: 10) { button.tap() }
    }

    private func tapFirst(_ app: XCUIApplication, prefix: String) {
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        if row.waitForExistence(timeout: 8) { row.tap() }
    }

    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists { button.tap() }
    }

    private func tour(scheme: String, user: String = "director", extraArgs: [String] = [], prefix: String) {
        let app = launch(user: user, scheme: scheme, extraArgs: extraArgs)
        _ = app.tabBars.firstMatch.waitForExistence(timeout: 15)
        shot(app, "\(prefix)-01-home")
        app.swipeUp(); shot(app, "\(prefix)-02-home-scrolled")
        app.swipeUp(); shot(app, "\(prefix)-03-home-bottom")

        tab(app, "الأقسام"); shot(app, "\(prefix)-04-departments")
        let lab = app.staticTexts["المختبر"]
        if lab.waitForExistence(timeout: 8) { lab.tap(); shot(app, "\(prefix)-05-department-card"); back(app) }

        tab(app, "الأداء"); shot(app, "\(prefix)-06-indicators")
        tapFirst(app, prefix: "indicatorRow."); shot(app, "\(prefix)-07-indicator-detail"); back(app)
        app.segmentedControls.buttons["الأهداف"].tap(); shot(app, "\(prefix)-08-goals")
        tapFirst(app, prefix: "goalRow."); shot(app, "\(prefix)-09-goal-detail"); back(app)

        tab(app, "التنفيذ"); shot(app, "\(prefix)-10-tasks")
        let task = app.staticTexts["تحديث إجراءات استلام العينات"]
        if task.waitForExistence(timeout: 8) { task.tap(); shot(app, "\(prefix)-11-task-detail"); back(app) }
        app.segmentedControls.buttons["المنجزات"].tap(); shot(app, "\(prefix)-12-achievements")
        tapFirst(app, prefix: "achievementRow."); shot(app, "\(prefix)-13-achievement-detail"); back(app)

        tab(app, "التقارير"); shot(app, "\(prefix)-14-reports")
        tapFirst(app, prefix: "reportRow."); shot(app, "\(prefix)-15-report-detail"); back(app)

        tab(app, "الرئيسية")
        let bell = app.buttons["inboxButton"].firstMatch
        if bell.waitForExistence(timeout: 5) { bell.tap(); shot(app, "\(prefix)-16-inbox") }
    }

    func testTourLight() { tour(scheme: "light", prefix: "light") }
    func testTourDark() { tour(scheme: "dark", prefix: "dark") }
    func testTourHeadLight() { tour(scheme: "light", user: "head", prefix: "head") }
    func testTourLargeText() {
        tour(scheme: "light", extraArgs: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"],
             prefix: "ax")
    }
}
