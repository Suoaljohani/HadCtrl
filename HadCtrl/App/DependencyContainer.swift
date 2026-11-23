import Foundation

/// Runtime environment. `demo` and `uiTesting` use clearly labelled synthetic
/// data; `production` talks to Supabase and NEVER falls back to mocks (§21, AC-031).
enum AppEnvironment: String, Sendable {
    case production
    case demo
    case uiTesting = "ui-testing"

    var usesMockData: Bool { self != .production }

    static func resolve(processInfo: ProcessInfo = .processInfo, bundle: Bundle = .main) -> AppEnvironment {
        if let raw = processInfo.environment["HC_APP_ENV"], let env = AppEnvironment(rawValue: raw) { return env }
        if let raw = bundle.object(forInfoDictionaryKey: "HCDefaultAppEnvironment") as? String,
           let env = AppEnvironment(rawValue: raw) { return env }
        return .production
    }
}

/// Public client configuration (URL + publishable key only; spec §22).
struct BackendConfiguration: Sendable, Equatable {
    let url: URL
    let publishableKey: String

    static func fromBundle(_ bundle: Bundle = .main) -> Result<BackendConfiguration, AppError> {
        let urlString = (bundle.object(forInfoDictionaryKey: "HCSupabaseURL") as? String) ?? ""
        let key = (bundle.object(forInfoDictionaryKey: "HCSupabasePublishableKey") as? String) ?? ""
        if let error = validate(urlString: urlString, key: key) { return .failure(error) }
        return .success(BackendConfiguration(url: URL(string: urlString)!, publishableKey: key))
    }

    /// Returns the reason a URL/key pair must not be used by the client, or nil if acceptable.
    static func validate(urlString: String, key: String) -> AppError? {
        guard let url = URL(string: urlString), url.scheme == "https", url.host != nil else {
            return .configuration("HCSupabaseURL missing or not https")
        }
        guard !key.isEmpty, !key.hasPrefix("$(") else {
            return .configuration("HCSupabasePublishableKey not supplied")
        }
        // Refuse anything that looks like a secret/service key (spec §22, §36).
        guard !key.hasPrefix("sb_secret_"), !key.localizedCaseInsensitiveContains("service_role") else {
            return .configuration("A secret key was supplied to the client; refusing to start")
        }
        return nil
    }
}

/// Single composition root (spec §21).
struct DependencyContainer: Sendable {
    let environment: AppEnvironment
    let clock: HCClock
    let session: SessionRepository
    let dashboard: DashboardRepository
    let departments: DepartmentsRepository
    let tasks: TasksRepository
    let reports: ReportsRepository
    let indicators: IndicatorsRepository
    let achievements: AchievementsRepository
    let admin: AdminRepository
    let notifications: NotificationsRepository
    let goals: GoalsRepository
    let attachments: AttachmentsRepository
    /// Exposed for UI tests that need to shape mock behaviour.
    let mockStore: MockStore?

    static func make(environment: AppEnvironment, processInfo: ProcessInfo = .processInfo) -> DependencyContainer {
        let clock = SystemClock()
        switch environment {
        case .demo, .uiTesting:
            let store = MockStore(clock: clock)
            let user = processInfo.environment["HC_DEMO_USER"] == "head" ? MockStore.Fixture.headLab : MockStore.Fixture.director
            let mocks = MockRepositories(store: store, clock: clock, demoUser: user)
            return DependencyContainer(environment: environment, clock: clock, session: mocks.session,
                                       dashboard: mocks.dashboard, departments: mocks.departments, tasks: mocks.tasks,
                                       reports: mocks.reports, indicators: mocks.indicators,
                                       achievements: mocks.achievements, admin: mocks.admin,
                                       notifications: mocks.notifications, goals: mocks.goals,
                                       attachments: mocks.attachments, mockStore: store)
        case .production:
            switch BackendConfiguration.fromBundle() {
            case .failure(let error):
                // No publishable key / bad URL: show the configuration error, never demo data (AC-031).
                let unavailable = UnavailableBackend(error: error)
                return DependencyContainer(environment: environment, clock: clock, session: unavailable,
                                           dashboard: unavailable, departments: unavailable, tasks: unavailable,
                                           reports: unavailable, indicators: unavailable, achievements: unavailable,
                                           admin: unavailable, notifications: unavailable, goals: unavailable,
                                           attachments: unavailable, mockStore: nil)
            case .success(let config):
                let backend = SupabaseBackend(client: SupabaseClientFactory.make(config), cache: SessionCache(),
                                              calendar: .riyadh)
                return DependencyContainer(environment: environment, clock: clock,
                                           session: SupabaseSessionRepository(backend: backend),
                                           dashboard: SupabaseDashboardRepository(backend: backend),
                                           departments: SupabaseDepartmentsRepository(backend: backend),
                                           tasks: SupabaseTasksRepository(backend: backend, clock: clock),
                                           reports: SupabaseReportsRepository(backend: backend),
                                           indicators: SupabaseIndicatorsRepository(backend: backend),
                                           achievements: SupabaseAchievementsRepository(backend: backend),
                                           admin: SupabaseAdminRepository(backend: backend),
                                           notifications: SupabaseNotificationsRepository(backend: backend),
                                           goals: SupabaseGoalsRepository(backend: backend),
                                           attachments: SupabaseAttachmentsRepository(backend: backend), mockStore: nil)
            }
        }
    }
}

/// Used when the backend configuration is missing or invalid: every call
/// surfaces the configuration error instead of showing demo data.
struct UnavailableBackend: SessionRepository, DashboardRepository, DepartmentsRepository, TasksRepository,
                           ReportsRepository, IndicatorsRepository, AchievementsRepository, AdminRepository,
                           NotificationsRepository, GoalsRepository, AttachmentsRepository {
    let error: AppError
    func restore() async throws -> UserContext? { throw error }
    func signIn(email: String, password: String) async throws -> UserContext { throw error }
    func signOut() async {}
    func changePassword(_ newPassword: String) async throws -> UserContext { throw error }
    func people() async throws -> [PersonSummary] { throw error }
    func createDepartment(_ draft: NewDepartmentDraft, requestID: UUID) async throws -> Department { throw error }
    func createEmployee(_ draft: NewEmployeeDraft, requestID: UUID) async throws -> EmployeeCreationResult { throw error }
    func periods() async throws -> [ReportingPeriod] { throw error }
    func snapshot(periodID: UUID) async throws -> DashboardSnapshot { throw error }
    func departments() async throws -> [Department] { throw error }
    func assignees(departmentID: UUID) async throws -> [Assignee] { throw error }
    func tasks(filter: TaskFilter) async throws -> [TaskItem] { throw error }
    func task(id: UUID) async throws -> TaskItem { throw error }
    func createTask(_ draft: NewTaskDraft, requestID: UUID) async throws -> TaskItem { throw error }
    func transition(taskID: UUID, expectedVersion: Int, transition: TaskTransition, note: String?, requestID: UUID) async throws -> TaskItem { throw error }
    func reports(periodID: UUID) async throws -> [ReportItem] { throw error }
    func report(id: UUID) async throws -> ReportDetail { throw error }
    func saveDraft(reportID: UUID, content: [String: String], expectedRevisionVersion: Int?, requestID: UUID) async throws -> SavedDraft { throw error }
    func submit(reportID: UUID, draftRevisionID: UUID, expectedVersion: Int, requestID: UUID) async throws { throw error }
    func decide(reportID: UUID, revisionID: UUID, decision: ReportDecision, expectedVersion: Int, note: String?, requestID: UUID) async throws { throw error }
    func waive(reportID: UUID, reason: String, expectedVersion: Int, requestID: UUID) async throws { throw error }
    func createTemplate(_ draft: NewReportTemplateDraft, requestID: UUID) async throws -> UUID { throw error }
    func schedule(templateID: UUID, departmentIDs: [UUID], dueDay: Int, requestID: UUID) async throws -> Int { throw error }
    func ensureCurrentPeriod() async throws -> UUID { throw error }
    func generateReports(periodID: UUID) async throws -> Int { throw error }
    func indicators(periodID: UUID) async throws -> [IndicatorSummary] { throw error }
    func indicator(definitionID: UUID, periodID: UUID) async throws -> IndicatorDetail { throw error }
    func submitMeasurement(definitionVersionID: UUID, periodID: UUID, reading: Reading, sourceNote: String?,
                           correctionReason: String?, requestID: UUID) async throws { throw error }
    func decideMeasurement(measurementID: UUID, approve: Bool, expectedVersion: Int, note: String?, requestID: UUID) async throws { throw error }
    func createIndicator(_ draft: NewIndicatorDraft, requestID: UUID) async throws -> UUID { throw error }
    func achievements(periodID: UUID) async throws -> [AchievementItem] { throw error }
    func achievement(id: UUID) async throws -> AchievementDetail { throw error }
    func save(_ draft: AchievementDraft, requestID: UUID) async throws -> UUID { throw error }
    func submit(id: UUID, expectedVersion: Int, requestID: UUID) async throws { throw error }
    func decide(id: UUID, decision: AchievementDecision, expectedVersion: Int, note: String?, requestID: UUID) async throws { throw error }
    func linkableTasks(departmentID: UUID) async throws -> [TaskItem] { throw error }
    func inbox() async throws -> [InboxItem] { throw error }
    func attachments(for target: AttachmentTarget) async throws -> [Attachment] { throw error }
    func upload(_ data: Data, fileName: String, mimeType: String, to target: AttachmentTarget, requestID: UUID) async throws -> Attachment { throw error }
    func signedURL(for attachment: Attachment) async throws -> URL { throw error }
    func remove(_ attachment: Attachment, requestID: UUID) async throws { throw error }
    func goals(departmentID: UUID?, asOf: Date) async throws -> [GoalSummary] { throw error }
    func goal(id: UUID, asOf: Date) async throws -> GoalDetail { throw error }
    func create(_ draft: NewGoalDraft, requestID: UUID) async throws -> UUID { throw error }
    func decide(id: UUID, decision: GoalDecision, expectedVersion: Int, note: String?, requestID: UUID) async throws { throw error }
    func requestCompletion(id: UUID, expectedVersion: Int, note: String?, requestID: UUID) async throws { throw error }
    func setMilestone(id: UUID, approve: Bool, requestID: UUID) async throws { throw error }
    func unreadCount() async throws -> Int { throw error }
    func markRead(id: UUID) async throws { throw error }
    func markAllRead() async throws -> Int { throw error }
}
