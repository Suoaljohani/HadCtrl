import Foundation

// Repository contracts (spec §21). Screens depend only on these; one
// composition root decides between Supabase and explicit demo/test mocks.

protocol SessionRepository: Sendable {
    /// Restores a stored session and returns the server-resolved context, or nil if signed out.
    func restore() async throws -> UserContext?
    func signIn(email: String, password: String) async throws -> UserContext
    func signOut() async
    /// Replaces a temporary password, then returns the refreshed context.
    func changePassword(_ newPassword: String) async throws -> UserContext
}

protocol DashboardRepository: Sendable {
    func periods() async throws -> [ReportingPeriod]
    /// API-01 dashboard_snapshot: one consistent document per period.
    func snapshot(periodID: UUID) async throws -> DashboardSnapshot
}

protocol DepartmentsRepository: Sendable {
    func departments() async throws -> [Department]
    func assignees(departmentID: UUID) async throws -> [Assignee]
}

struct TaskFilter: Sendable, Hashable {
    enum Scope: String, Sendable, CaseIterable { case assignedToMe, overdue, awaitingApproval, all }
    var scope: Scope = .all
    var departmentID: UUID?
}

protocol TasksRepository: Sendable {
    func tasks(filter: TaskFilter) async throws -> [TaskItem]
    func task(id: UUID) async throws -> TaskItem
    /// API-04: returns the created task; replays with the same requestID return the same task.
    func createTask(_ draft: NewTaskDraft, requestID: UUID) async throws -> TaskItem
    /// API-05: atomic transition guarded by expectedVersion.
    func transition(taskID: UUID, expectedVersion: Int, transition: TaskTransition, note: String?, requestID: UUID) async throws -> TaskItem
}

protocol ReportsRepository: Sendable {
    func reports(periodID: UUID) async throws -> [ReportItem]
    func report(id: UUID) async throws -> ReportDetail
    /// API-07: creates or updates the open draft (expectedRevisionVersion nil = new draft).
    func saveDraft(reportID: UUID, content: [String: String], expectedRevisionVersion: Int?, requestID: UUID) async throws -> SavedDraft
    /// API-08: freezes the draft as a submission; the first submission time never changes.
    func submit(reportID: UUID, draftRevisionID: UUID, expectedVersion: Int, requestID: UUID) async throws
    /// API-09: approve or return (note required) the latest submitted revision.
    func decide(reportID: UUID, revisionID: UUID, decision: ReportDecision, expectedVersion: Int, note: String?, requestID: UUID) async throws
    func waive(reportID: UUID, reason: String, expectedVersion: Int, requestID: UUID) async throws
    // Director definitions (D-29)
    func createTemplate(_ draft: NewReportTemplateDraft, requestID: UUID) async throws -> UUID
    func schedule(templateID: UUID, departmentIDs: [UUID], dueDay: Int, requestID: UUID) async throws -> Int
    func ensureCurrentPeriod() async throws -> UUID
    func generateReports(periodID: UUID) async throws -> Int
}

protocol IndicatorsRepository: Sendable {
    func indicators(periodID: UUID) async throws -> [IndicatorSummary]
    func indicator(definitionID: UUID, periodID: UUID) async throws -> IndicatorDetail
    /// API-06: a new submitted revision; replacing an approved one needs a correction reason.
    func submitMeasurement(definitionVersionID: UUID, periodID: UUID, reading: Reading, sourceNote: String?,
                           correctionReason: String?, requestID: UUID) async throws
    func decideMeasurement(measurementID: UUID, approve: Bool, expectedVersion: Int, note: String?, requestID: UUID) async throws
    /// Director only (D-29): definition + approved version 1.
    func createIndicator(_ draft: NewIndicatorDraft, requestID: UUID) async throws -> UUID
}

protocol AchievementsRepository: Sendable {
    func achievements(periodID: UUID) async throws -> [AchievementItem]
}
