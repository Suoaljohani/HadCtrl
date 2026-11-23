import Foundation
import Testing
@testable import HadCtrl

@Suite("Achievements (§16, API-10)", .serialized)
@MainActor
struct AchievementTests {
    typealias F = MockStore.Fixture
    let clock = FixedClock(date: ISO8601DateFormatter().date(from: "2026-11-23T09:00:00Z")!)
    let approvedLab = MockAchievementStore.id(1)
    let submittedTraining = MockAchievementStore.id(2)
    let draftLab = MockAchievementStore.id(3)

    private func repos(_ user: UUID, _ store: MockStore) -> MockRepositories {
        MockRepositories(store: store, clock: clock, demoUser: user)
    }

    @Test("a draft needs a title; submission also needs the impact; own department is not a contributor")
    func draftValidation() {
        var d = AchievementDraft(departmentID: F.lab, periodID: F.november, title: "توحيد الملصقات")
        #expect(d.validate(forSubmission: false).isEmpty)
        #expect(d.validate(forSubmission: true)[.impact] != nil)
        d.impact = "انخفاض الرفض إلى صفر"
        #expect(d.validate(forSubmission: true).isEmpty)
        d.contributorIDs = [F.lab]
        #expect(d.validate(forSubmission: false)[.contributors] != nil)
        #expect(AchievementDraft(departmentID: F.lab, periodID: nil, title: "x").validate(forSubmission: false).count == 2)
    }

    @Test("drafts stay in the department; approved ones are visible to everyone")
    func visibility() async throws {
        let store = MockStore(clock: clock)
        let director = try await repos(F.director, store).achievements.achievements(periodID: F.november).map(\.id)
        #expect(!director.contains(draftLab), "the director does not see drafts")
        #expect(director.contains(submittedTraining) && director.contains(approvedLab))
        let head = try await repos(F.headLab, store).achievements.achievements(periodID: F.november).map(\.id)
        #expect(head.contains(draftLab) && head.contains(approvedLab))
        #expect(!head.contains(submittedTraining), "another department's submission is not visible")
    }

    @Test("the head adds the impact and submits; the head cannot approve; the director then can")
    func headSubmitsDirectorApproves() async throws {
        let store = MockStore(clock: clock)
        let head = repos(F.headLab, store).achievements
        let headCtx = MockDirectory.context(for: F.headLab)
        let draft = try await head.achievement(id: draftLab)
        #expect(draft.permissions(for: headCtx) == AchievementPermissions(canEdit: true, canSubmit: true, canDecide: false))

        let editor = AchievementEditorViewModel(draft: draft.draft, repository: head, directory: repos(F.headLab, store).departments)
        #expect(await editor.save(submit: true) == false, "no submission without an impact")
        #expect(editor.fieldErrors["impact_text"] != nil)
        editor.draft.impact = "انخفاض العينات المرفوضة من ٧ إلى ١"
        #expect(await editor.save(submit: true))
        let submitted = try await head.achievement(id: draftLab)
        #expect(submitted.item.status == .submitted)
        await #expect(throws: AppError.self) {
            try await head.decide(id: draftLab, decision: .approved, expectedVersion: submitted.item.version, note: nil, requestID: UUID())
        }

        let director = AchievementDetailViewModel(achievementID: draftLab, repository: repos(F.director, store).achievements)
        await director.load()
        #expect(director.state.value?.permissions(for: MockDirectory.context(for: F.director)).canDecide == true)
        await director.decide(.approved, note: nil)
        #expect(director.state.value?.item.status == .approved)
        #expect(director.state.value?.reviews.first?.decision == .approved)
    }

    @Test("returning or rejecting needs a note and keeps the history")
    func returnNeedsNote() async throws {
        let store = MockStore(clock: clock)
        let director = repos(F.director, store).achievements
        let d = try await director.achievement(id: submittedTraining)
        do {
            try await director.decide(id: d.item.id, decision: .rejected, expectedVersion: d.item.version, note: " ", requestID: UUID())
            Issue.record("reject without a note must fail")
        } catch let e as AppError { #expect(e.code == .validationFailed) }
        let model = AchievementDetailViewModel(achievementID: submittedTraining, repository: director)
        await model.load()
        await model.decide(.returned, note: "أرفق كشف الحضور")
        #expect(model.state.value?.item.status == .returned)
        #expect(model.state.value?.reviews.first?.note == "أرفق كشف الحضور")
    }

    @Test("a retried save with the same request id creates one achievement")
    func idempotentCreate() async throws {
        let store = MockStore(clock: clock)
        let head = repos(F.headLab, store).achievements
        let draft = AchievementDraft(departmentID: F.lab, periodID: F.november, title: "أتمتة تقرير الجودة")
        let request = UUID()
        let a = try await head.save(draft, requestID: request)
        let b = try await head.save(draft, requestID: request)
        #expect(a == b)
        #expect(try await head.achievements(periodID: F.november).filter { $0.title == "أتمتة تقرير الجودة" }.count == 1)
    }
}
