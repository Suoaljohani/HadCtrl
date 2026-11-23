import Foundation
import Testing
@testable import HadCtrl

@Suite("Goals (§09, AC-010)", .serialized)
@MainActor
struct GoalTests {
    typealias F = MockStore.Fixture
    let clock = FixedClock(date: ISO8601DateFormatter().date(from: "2026-11-23T09:00:00Z")!)
    let cal = HospitalCalendar.riyadh.calendar
    func d(_ m: Int, _ day: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: day))! }

    @Test("§09 example: 11 of 12 by end of November is on track; 6 of 11 expected is behind")
    func trainingExample() {
        let plan = [PlanPoint(at: d(6, 30), expected: 6), PlanPoint(at: d(11, 30), expected: 11), PlanPoint(at: d(12, 31), expected: 12)]
        let expected = GoalMath.expected(at: d(11, 30), plan: plan, linear: false, baseline: nil, target: 12, start: d(1, 1), due: d(12, 31))
        #expect(expected == 11)
        let ok = GoalMath.progress(type: .count, target: 12, actual: 11, expected: expected, started: true)
        #expect(ok.track == .onTrack)
        #expect(ok.raw.map { NSDecimalNumber(decimal: $0).doubleValue.rounded() } == 92, "annual completion ≈ 91.7%")
        let late = GoalMath.progress(type: .count, target: 12, actual: 6, expected: expected, started: true)
        #expect(late.track == .behind)
        #expect(GoalMath.expected(at: d(3, 1), plan: plan, linear: false, baseline: nil, target: 12, start: d(1, 1), due: d(12, 31)) == 0,
                "before the first plan point nothing is expected yet")
    }

    @Test("raw achievement may exceed 100% but the aggregate value is capped")
    func rawVersusCapped() {
        let p = GoalMath.progress(type: .count, target: 10, actual: 13, expected: nil, started: true)
        #expect(p.raw == 130 && p.capped == 100)
        #expect(GoalMath.progress(type: .count, target: 10, actual: nil, expected: 5, started: true).track == .noData,
                "missing data is not zero")
    }

    @Test("a linear plan is used only when approved as linear")
    func linearPlan() {
        let mid = Date(timeIntervalSince1970: (d(1, 1).timeIntervalSince1970 + d(12, 31).timeIntervalSince1970) / 2)
        let e = GoalMath.expected(at: mid, plan: [], linear: true, baseline: 0, target: 12, start: d(1, 1), due: d(12, 31))
        #expect(e.map { NSDecimalNumber(decimal: $0).doubleValue.rounded() } == 6)
        #expect(GoalMath.expected(at: mid, plan: [], linear: false, baseline: 0, target: 12, start: d(1, 1), due: d(12, 31)) == nil)
    }

    @Test("milestones count only when completed and approved; ratio goals use ratio of sums")
    func milestoneAndRatio() {
        let ms = [GoalMilestone(id: UUID(), ordinal: 1, title: "أ", criterion: "معيار", weight: 60, completedAt: Date(), approved: true),
                  GoalMilestone(id: UUID(), ordinal: 2, title: "ب", criterion: "معيار", weight: 40, completedAt: Date(), approved: false)]
        #expect(GoalMath.milestoneActual(ms) == 60)
        let ratio = GoalMath.indicatorActual(readings: [.ratio(90, 100), .ratio(1, 2)], rule: .ratioOfSums, isRatio: true)
        #expect(ratio.map { NSDecimalNumber(decimal: $0).doubleValue } .map { ($0 * 100).rounded() / 100 } == 89.22, "91/102, not mean(90%, 50%)")
    }

    @Test("new goal form: explicit target or milestones totalling 100; plan inside the window and increasing")
    func draftValidation() {
        var g = NewGoalDraft(departmentID: F.lab, title: "خفض الرفض", unit: "عينة", startDate: d(1, 1), dueDate: d(12, 31))
        #expect(g.validate()[.target] != nil, "no default 100%")
        g.targetText = "5"
        #expect(g.validate().isEmpty)
        g.plan = [.init(at: d(6, 1), expectedText: "3"), .init(at: d(9, 1), expectedText: "2")]
        #expect(g.validate()[.plan] != nil)
        g.measurementType = .milestones
        g.plan = []
        g.milestones = [.init(title: "إعداد", criterion: "مسودة", weightText: "60"), .init(title: "تطبيق", criterion: "تقرير", weightText: "30")]
        #expect(g.validate()[.milestones] != nil)
        g.milestones[1].weightText = "40"
        #expect(g.validate().isEmpty)
    }

    @Test("director activates a draft; head requests completion; director refuses with a note, then completes")
    func lifecycle() async throws {
        let store = MockStore(clock: clock)
        let director = MockRepositories(store: store, clock: clock, demoUser: F.director).goals
        let head = MockRepositories(store: store, clock: clock, demoUser: F.headLab).goals
        let draftID = MockGoalStore.id(3)
        let headCtx = MockDirectory.context(for: F.headLab), dirCtx = MockDirectory.context(for: F.director)
        let draft = try await head.goal(id: draftID, asOf: clock.now())
        #expect(!draft.permissions(for: headCtx).canActivate)
        await #expect(throws: AppError.self) {
            try await head.decide(id: draftID, decision: .activate, expectedVersion: draft.summary.version, note: nil, requestID: UUID())
        }
        let model = GoalDetailViewModel(goalID: draftID, repository: director, clock: clock)
        await model.load()
        #expect(model.state.value?.permissions(for: dirCtx).canActivate == true)
        await model.decide(.activate, note: nil)
        #expect(model.state.value?.summary.lifecycle == .active)

        let headModel = GoalDetailViewModel(goalID: draftID, repository: head, clock: clock)
        await headModel.load()
        await headModel.requestCompletion()
        #expect(headModel.state.value?.summary.lifecycle == .completionPending)

        await model.load()
        await model.decide(.rejectCompletion, note: " ")
        #expect(model.actionError?.code == .validationFailed, "refusing completion needs a note")
        await model.decide(.rejectCompletion, note: "المؤشر لم يبلغ المستهدف")
        #expect(model.state.value?.summary.lifecycle == .active, "AC-010: not completed just because work was done")
    }

    @Test("milestones: the head completes, only the director approves, progress follows approval")
    func milestones() async throws {
        let store = MockStore(clock: clock)
        let goalID = MockGoalStore.id(2)
        let head = GoalDetailViewModel(goalID: goalID, repository: MockRepositories(store: store, clock: clock, demoUser: F.headLab).goals, clock: clock)
        await head.load()
        let second = try #require(head.state.value?.milestones.first { $0.ordinal == 2 })
        #expect(head.state.value?.summary.progress.actual == 60)
        await head.milestone(second, approve: false)
        #expect(head.state.value?.summary.progress.actual == 60, "completed but not approved does not count")
        await head.milestone(second, approve: true)
        #expect(head.actionError?.code == .forbidden)
        let director = GoalDetailViewModel(goalID: goalID, repository: MockRepositories(store: store, clock: clock, demoUser: F.director).goals, clock: clock)
        await director.load()
        await director.milestone(try #require(director.state.value?.milestones.first { $0.ordinal == 2 }), approve: true)
        #expect(director.state.value?.summary.progress.actual == 100)
    }
}
