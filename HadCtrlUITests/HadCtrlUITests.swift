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
        app.sign()
        app.expectTaskStatus("مكتملة")
        XCTAssertTrue(app.scrollToHittable(app.descendants(matching: .any)["signatureRow"]).exists,
                      "the handwritten signature is shown with the decision")
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

    /// Director creates a department and an employee from Settings (D-25, mock backend).
    func testDirectorCreatesDepartmentAndEmployee() {
        let app = launch()
        app.scrollToHittable(app.buttons["settingsButton"].firstMatch).tap()
        app.scrollToHittable(app.buttons["settings.admin"]).tap()

        app.scrollToHittable(app.buttons["admin.addDepartment"]).tap()
        let name = app.textFields["department.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("الأشعة")
        let code = app.textFields["department.code"]
        code.tap(); code.typeText("RAD")
        app.buttons["department.save"].tap()
        XCTAssertTrue(app.anyElement(containing: "الأشعة").waitForExistence(timeout: 5), "new department listed")

        app.scrollToHittable(app.buttons["admin.addEmployee"]).tap()
        let email = app.textFields["employee.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        email.tap(); email.typeText("new.employee@hospital.sa")
        let person = app.textFields["employee.name"]
        person.tap(); person.typeText("موظف جديد")
        app.buttons["employee.save"].tap()

        let password = app.descendants(matching: .any)["employee.tempPassword"]
        XCTAssertTrue(password.waitForExistence(timeout: 5), "temporary password shown once")
        app.buttons["employee.done"].tap()
        XCTAssertFalse(password.waitForExistence(timeout: 2), "password screen gone after «تم»")
        // The employees section is below the departments in a lazy List: scroll to it.
        app.scrollToHittable(app.anyElement(containing: "موظف جديد"))
    }

    /// Department head fills the monthly report and submits it (spec §14); required fields are checked first.
    func testHeadSubmitsMonthlyReport() {
        let app = launch(user: "head")
        app.tabBars.firstMatch.buttons["التقارير"].tap()
        app.scrollToHittable(app.row("reportRow.00000000-0000-0000-0000-000000000201")).tap()
        app.expectBadge("reportStatusBadge", "لم يُسلّم")
        app.textInput("reportField.f1").tap()
        app.textInput("reportField.f1").typeText("اكتمل توثيق العينات")
        app.dismissKeyboard()
        app.scrollToHittable(app.textInput("reportField.f3")).tap()
        app.textInput("reportField.f3").typeText("مراجعة إجراءات الاستلام")
        app.dismissKeyboard()
        app.scrollToHittable(app.buttons["report.submit"]).tap()
        app.expectBadge("reportStatusBadge", "مُسلّم")
        XCTAssertFalse(app.buttons["report.submit"].exists, "a submitted report is frozen")
    }

    /// Director approves a submitted report, then a pending indicator reading (no self-approval path involved).
    func testDirectorApprovesReportAndReading() {
        let app = launch()
        app.tabBars.firstMatch.buttons["التقارير"].tap()
        app.scrollToHittable(app.row("reportRow.00000000-0000-0000-0000-000000000202")).tap()
        app.scrollToHittable(app.buttons["report.approve"]).tap()
        app.sign()
        app.expectBadge("reportStatusBadge", "معتمد")

        app.tabBars.firstMatch.buttons["الأداء"].tap()
        app.scrollToHittable(app.row("indicatorRow.LAB.DOC")).tap()
        app.scrollToHittable(app.buttons["indicator.approve"]).tap()
        app.sign()
        XCTAssertTrue(app.descendants(matching: .any)["indicator.confirmation"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["indicator.approve"].exists)
    }

    /// The bell opens the inbox; tapping an item marks it read and opens the record (D-30).
    func testInboxOpensRecord() {
        let app = launch()
        app.scrollToHittable(app.buttons["inboxButton"].firstMatch).tap()
        app.scrollToHittable(app.anyElement(containing: "تقرير بانتظار مراجعتك")).tap()
        app.expectBadge("reportStatusBadge", "مُسلّم")
        XCTAssertTrue(app.buttons["report.approve"].waitForExistence(timeout: 5) || app.scrollToHittable(app.buttons["report.approve"]).exists)
    }

    /// The head adds the impact to the department's draft achievement and submits it (§16).
    func testHeadSubmitsAchievement() {
        let app = launch(user: "head")
        app.tabBars.firstMatch.buttons["التنفيذ"].tap()
        app.segmentedControls.buttons["المنجزات"].tap()
        app.scrollToHittable(app.row("achievementRow.00000000-0000-0000-0000-000000000403")).tap()
        app.expectBadge("achievementStatusBadge", "مسودة")
        app.scrollToHittable(app.buttons["achievement.edit"]).tap()
        let impact = app.textInput("achievement.impact")
        XCTAssertTrue(impact.waitForExistence(timeout: 5))
        impact.tap()
        impact.typeText("انخفاض العينات المرفوضة من ٧ إلى ١")
        app.buttons["achievement.saveDraft"].tap()
        app.scrollToHittable(app.buttons["achievement.submit"]).tap()
        app.expectBadge("achievementStatusBadge", "بانتظار الاعتماد")
        XCTAssertFalse(app.buttons["achievement.approve"].exists, "a department never approves its own achievement")
    }

    /// The director approves a submitted achievement from another department.
    func testDirectorApprovesAchievement() {
        let app = launch()
        app.tabBars.firstMatch.buttons["التنفيذ"].tap()
        app.segmentedControls.buttons["المنجزات"].tap()
        app.scrollToHittable(app.row("achievementRow.00000000-0000-0000-0000-000000000402")).tap()
        app.scrollToHittable(app.buttons["achievement.approve"]).tap()
        app.sign()
        app.expectBadge("achievementStatusBadge", "معتمد")
    }

    /// The director activates a department's draft goal from Performance → Goals (§09).
    func testDirectorActivatesGoal() {
        let app = launch()
        app.tabBars.firstMatch.buttons["الأداء"].tap()
        app.segmentedControls.buttons["الأهداف"].tap()
        app.scrollToHittable(app.row("goalRow.00000000-0000-0000-0000-000000000603")).tap()
        app.expectBadge("goalStatusBadge", "مسودة بانتظار الاعتماد")
        app.scrollToHittable(app.buttons["goal.activate"]).tap()
        app.sign()
        app.expectBadge("goalStatusBadge", "نشط")
    }

    /// The department card has internal sections for goals, indicators, tasks, reports and achievements (§08).
    func testDepartmentCardSections() {
        let app = launch(user: "head")
        app.tabBars.firstMatch.buttons["الأقسام"].tap()
        app.scrollToHittable(app.staticTexts["المختبر"]).tap()
        let sections = app.segmentedControls["department.sections"]
        XCTAssertTrue(sections.waitForExistence(timeout: 10))
        for title in ["الأهداف", "المؤشرات", "المهام", "التقارير", "المنجزات"] {
            XCTAssertTrue(sections.buttons[title].exists, "missing section \(title)")
        }
        XCTAssertTrue(app.row("goalRow.00000000-0000-0000-0000-000000000602").waitForExistence(timeout: 10),
                      "the department's goals are listed")
        sections.buttons["المنجزات"].tap()
        XCTAssertTrue(app.row("achievementRow.00000000-0000-0000-0000-000000000401").waitForExistence(timeout: 10))
    }

    /// Evidence on an approved achievement is visible to the department but can no longer be added or removed (§26).
    func testApprovedAchievementEvidenceIsReadOnly() {
        let app = launch(user: "head")
        app.tabBars.firstMatch.buttons["التنفيذ"].tap()
        app.segmentedControls.buttons["المنجزات"].tap()
        app.scrollToHittable(app.row("achievementRow.00000000-0000-0000-0000-000000000401")).tap()
        app.expectBadge("achievementStatusBadge", "معتمد")
        XCTAssertTrue(app.scrollToHittable(app.anyElement(containing: "قراءة LAB.TAT المعتمدة")).exists, "existing evidence is listed")
        XCTAssertFalse(app.buttons["attachment.addFile"].exists, "no new evidence on an approved record")
    }

    /// Global search (§17): normalized match, grouped results, opens the shared route.
    func testSearchOpensTask() {
        let app = launch()
        app.scrollToHittable(app.buttons["searchButton"].firstMatch).tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("اجراءات")   // no hamza: must still match «إجراءات»
        let hit = app.anyElement(containing: "تحديث إجراءات استلام العينات")
        XCTAssertTrue(hit.waitForExistence(timeout: 10), "normalized search finds the task")
        hit.tap()
        app.expectTaskStatus("مرفوعة للاعتماد")
    }

    /// Export (§19): the director builds PDF and CSV for the period.
    func testDirectorExportsSummary() {
        let app = launch()
        app.scrollToHittable(app.buttons["dashboard.tools"].firstMatch).tap()
        let export = app.buttons["dashboard.export"]
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        let build = app.buttons["export.build"]
        XCTAssertTrue(build.waitForExistence(timeout: 10))
        build.tap()
        XCTAssertFalse(app.descendants(matching: .any)["export.noPeriod"].exists, "a period is selected")
        let done = app.descendants(matching: .any)["export.done"].firstMatch
        if !done.waitForExistence(timeout: 20) {
            let failure = app.descendants(matching: .any)["export.error"]
            XCTFail(failure.exists ? "export failed: \(failure.label)" : "no files were produced and no error was shown")
            return
        }
        XCTAssertTrue(done.label.contains("2") || done.label.contains("٢"), "PDF and CSV were produced: \(done.label)")
    }

    func testLargeTextDoesNotHideDecisions() {
        let app = launch(extraArgs: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        XCTAssertTrue(app.staticTexts["تحتاج قرارك"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.firstMatch.buttons.count == 5)
    }
}

private extension XCUIApplication {
    /// Draws a signature on the pad and confirms it (D-37).
    func sign(file: StaticString = #filePath, line: UInt = #line) {
        let pad = descendants(matching: .any)["signature.pad"]
        XCTAssertTrue(pad.waitForExistence(timeout: 10), "the signature pad is shown before a decision", file: file, line: line)
        let confirm = buttons["signature.confirm"]
        XCTAssertFalse(confirm.isEnabled, "an empty signature cannot be confirmed", file: file, line: line)
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.55))
            .press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.35)))
        pad.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.7))
            .press(forDuration: 0.05, thenDragTo: pad.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.65)))
        XCTAssertTrue(confirm.isEnabled, "a drawn signature can be confirmed", file: file, line: line)
        confirm.tap()
        XCTAssertTrue(pad.waitForNonExistence(timeout: 10), "the signature sheet closes once sealed", file: file, line: line)
    }

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
        // Bring it into the tappable area with short drags; full swipes overshoot
        // elements that sit just under the navigation bar or the floating tab bar.
        var nudges = 0
        while element.exists && !element.isHittable && nudges < 20 {
            nudge(contentUp: element.frame.midY > frame.midY)
            nudges += 1
        }
        swipes += nudges
        XCTAssertTrue(element.exists && element.isHittable, "\(element) not reachable after \(swipes) swipes",
                      file: file, line: line)
        return element
    }

    /// Scrolls by about a fifth of the screen. `contentUp` reveals content below.
    func nudge(contentUp: Bool) {
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: contentUp ? 0.6 : 0.4))
        let end = coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: contentUp ? 0.4 : 0.6))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    func anyElement(containing text: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Taps the keyboard's «تم» button so later scrolling is not done on the keyboard.
    func dismissKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        let done = buttons["keyboard.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5), "keyboard «تم» button missing", file: file, line: line)
        done.tap()
        XCTAssertTrue(keyboards.firstMatch.waitForNonExistence(timeout: 5), "keyboard still visible", file: file, line: line)
    }

    /// A list row by accessibility identifier, whatever element type SwiftUI gives it.
    func row(_ id: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// Multi-line text fields are text views; single-line ones are text fields.
    func textInput(_ id: String) -> XCUIElement {
        let view = textViews[id]
        return view.exists ? view : textFields[id]
    }

    /// Asserts a status badge (by identifier) shows exactly `title`, scrolling back up to it if needed.
    func expectBadge(_ id: String, _ title: String, timeout: TimeInterval = 10,
                     file: StaticString = #filePath, line: UInt = #line) {
        let badge = descendants(matching: .any)[id]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if badge.exists && badge.label == title { return }
            if badge.exists { Thread.sleep(forTimeInterval: 0.3) } else { swipeDown() }
        }
        XCTFail("\(id) is '\(badge.exists ? badge.label : "<missing>")', expected '\(title)'", file: file, line: line)
    }

    /// Asserts the task detail status badge shows exactly `title`. The badge is
    /// the first row of a lazy List: if the test scrolled down to reach an
    /// action, scroll back up to it, as a user would, before reading it.
    func expectTaskStatus(_ title: String, timeout: TimeInterval = 10,
                          file: StaticString = #filePath, line: UInt = #line) {
        let badge = descendants(matching: .any)["taskStatusBadge"]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if badge.exists && badge.label == title { return }
            if badge.exists { Thread.sleep(forTimeInterval: 0.3) } else { swipeDown() }   // wait for the label to update
        }
        XCTFail("task status is '\(badge.exists ? badge.label : "<missing>")', expected '\(title)'", file: file, line: line)
    }
}
