import Foundation
import Testing
@testable import HadCtrl

@Suite("View models: concurrency and correctness", .serialized)
@MainActor
struct ViewModelTests {
    typealias F = MockStore.Fixture
    let clock = FixedClock(date: ISO8601DateFormatter().date(from: "2026-11-20T09:00:00Z")!)

    private func mocks(user: UUID = F.director) -> (MockStore, MockRepositories) {
        let store = MockStore(clock: clock)
        return (store, MockRepositories(store: store, clock: clock, demoUser: user))
    }

    @Test("AC-004: switching Nov → Oct quickly keeps only October's result")
    func latestPeriodWins() async throws {
        let (store, repos) = mocks()
        await store.setLatency(.milliseconds(300), for: F.november)   // slow
        await store.setLatency(.milliseconds(10), for: F.october)     // fast
        let model = DashboardViewModel(repository: repos.dashboard)
        model.select(periodID: F.november)
        model.select(periodID: F.october)
        await model.waitForIdle()
        try await Task.sleep(for: .milliseconds(400))                  // let the stale response arrive
        #expect(model.selectedPeriodID == F.october)
        #expect(model.state.value?.periodID == F.october)
    }

    @Test("AC-031: backend failure shows an error, not demo numbers")
    func failureIsVisible() async {
        let (store, repos) = mocks()
        await store.setFailure(.network(offline: true))
        let model = DashboardViewModel(repository: repos.dashboard)
        model.select(periodID: F.november)
        await model.waitForIdle()
        #expect(model.state.error == .network(offline: true))
        #expect(model.state.value == nil)
    }

    @Test("coverage below 80% yields no overall verdict on the dashboard")
    func dashboardVerdict() async throws {
        let (_, repos) = mocks()
        let snapshot = try await repos.dashboard.snapshot(periodID: F.november)
        #expect(snapshot.coverage == 75)
        #expect(snapshot.verdict == .insufficientData)
        #expect(snapshot.topActions.count <= 3)
        #expect(snapshot.topActions.first?.kind == .urgentBlocker)
        let awaiting = snapshot.readings.first { $0.metric == .awaitingDirector }?.numerator
        let listed = try await repos.tasks.tasks(filter: TaskFilter(scope: .awaitingApproval)).count
        #expect(awaiting == listed, "the count must equal the list it opens (§06)")
    }

    @Test("AC-011: saving twice with the same draft creates one task")
    func idempotentCreate() async throws {
        let (store, repos) = mocks()
        let model = NewTaskViewModel(tasks: repos.tasks, departments: repos.departments, clock: clock, preselectedDepartment: F.lab)
        await model.loadAssignees()
        model.draft.title = "مهمة اختبارية"
        model.draft.dueDate = clock.now().addingTimeInterval(3 * 86_400)
        let first = try #require(await model.save())
        let second = try #require(await model.save())
        #expect(first.id == second.id)
        #expect(await store.allTasks().filter { $0.title == "مهمة اختبارية" }.count == 1)
    }

    @Test("validation errors stay next to fields and keep input")
    func validation() async {
        let (_, repos) = mocks()
        let model = NewTaskViewModel(tasks: repos.tasks, departments: repos.departments, clock: clock, preselectedDepartment: nil)
        model.draft.title = "ab"
        let result = await model.save()
        #expect(result == nil)
        #expect(model.fieldErrors[.department] != nil)
        #expect(model.fieldErrors[.title] != nil)
        #expect(model.draft.title == "ab")
    }

    @Test("AC-012/AC-014: stale version is rejected; submitted is not completed")
    func lifecycle() async throws {
        let (store, _) = mocks()
        await store.setActor(F.headLab)
        let head = MockRepositories(store: store, clock: clock, demoUser: F.headLab).tasks
        let director = MockRepositories(store: store, clock: clock, demoUser: F.director).tasks
        let taskID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")! // assigned to head LAB
        let acked = try await head.transition(taskID: taskID, expectedVersion: 1, transition: .acknowledge, note: nil, requestID: UUID())
        #expect(acked.version == 2)
        await #expect(throws: AppError.server(code: .versionConflict, fieldErrors: [:], currentVersion: 2, correlationID: nil)) {
            _ = try await head.transition(taskID: taskID, expectedVersion: 1, transition: .start, note: nil, requestID: UUID())
        }
        let submitted = try await head.transition(taskID: taskID, expectedVersion: 2, transition: .submit, note: nil, requestID: UUID())
        #expect(submitted.status == .submitted)
        #expect(submitted.status != .completed)
        await #expect(throws: AppError.self) {
            _ = try await head.transition(taskID: taskID, expectedVersion: 3, transition: .approve, note: nil, requestID: UUID())
        }
        await #expect(throws: AppError.self) {
            _ = try await director.transition(taskID: taskID, expectedVersion: 3, transition: .return, note: nil, requestID: UUID())
        }
        let done = try await director.transition(taskID: taskID, expectedVersion: 3, transition: .approve, note: nil, requestID: UUID())
        #expect(done.status == .completed)
    }

    @Test("overdue is computed; submitted work is not 'overdue' for the assignee")
    func overdueComputed() {
        var t = TaskItem(id: UUID(), departmentID: F.lab, departmentName: "", title: "x", details: "", status: .inProgress,
                         priority: .normal, assigneeID: F.headLab, assigneeName: nil, creatorID: F.director,
                         originalDueAt: clock.now().addingTimeInterval(-60), dueAt: clock.now().addingTimeInterval(-60),
                         firstSubmittedAt: nil, version: 1)
        #expect(t.isOverdue(now: clock.now()))
        t.status = .submitted
        #expect(!t.isOverdue(now: clock.now()))
    }

    @Test("session: context without memberships is denied, never given a role picker (AC-002)")
    func noMembership() async {
        struct Empty: SessionRepository {
            func restore() async throws -> UserContext? {
                UserContext(userID: UUID(), displayName: "x", organizationID: UUID(), organizationName: "x", timeZoneID: "Asia/Riyadh",
                            isDemo: false, orgRoles: [], departments: [])
            }
            func signIn(email: String, password: String) async throws -> UserContext { throw AppError.cancelled }
            func signOut() async {}
            func changePassword(_ newPassword: String) async throws -> UserContext { throw AppError.cancelled }
        }
        let store = SessionStore(repository: Empty())
        await store.restore()
        #expect(store.phase == .noActiveMembership)
    }

    @Test("production with no publishable key surfaces a configuration error (no demo fallback)")
    func productionNeverFallsBack() async {
        let deps = DependencyContainer.make(environment: .production)
        #expect(deps.mockStore == nil)
        await #expect(throws: AppError.self) { _ = try await deps.dashboard.periods() }
    }
}
