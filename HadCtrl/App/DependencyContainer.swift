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
                                       achievements: mocks.achievements, mockStore: store)
        case .production:
            switch BackendConfiguration.fromBundle() {
            case .failure(let error):
                // No publishable key / bad URL: show the configuration error, never demo data (AC-031).
                let unavailable = UnavailableBackend(error: error)
                return DependencyContainer(environment: environment, clock: clock, session: unavailable,
                                           dashboard: unavailable, departments: unavailable, tasks: unavailable,
                                           reports: unavailable, indicators: unavailable, achievements: unavailable,
                                           mockStore: nil)
            case .success(let config):
                let backend = SupabaseBackend(client: SupabaseClientFactory.make(config), cache: SessionCache(),
                                              calendar: .riyadh)
                let pending = PendingSliceRepository()
                return DependencyContainer(environment: environment, clock: clock,
                                           session: SupabaseSessionRepository(backend: backend),
                                           dashboard: SupabaseDashboardRepository(backend: backend),
                                           departments: SupabaseDepartmentsRepository(backend: backend),
                                           tasks: SupabaseTasksRepository(backend: backend, clock: clock),
                                           reports: pending, indicators: pending, achievements: pending,
                                           mockStore: nil)
            }
        }
    }
}

/// Used when the backend configuration is missing or invalid: every call
/// surfaces the configuration error instead of showing demo data.
struct UnavailableBackend: SessionRepository, DashboardRepository, DepartmentsRepository, TasksRepository,
                           ReportsRepository, IndicatorsRepository, AchievementsRepository {
    let error: AppError
    func restore() async throws -> UserContext? { throw error }
    func signIn(email: String, password: String) async throws -> UserContext { throw error }
    func signOut() async {}
    func periods() async throws -> [ReportingPeriod] { throw error }
    func snapshot(periodID: UUID) async throws -> DashboardSnapshot { throw error }
    func departments() async throws -> [Department] { throw error }
    func assignees(departmentID: UUID) async throws -> [Assignee] { throw error }
    func tasks(filter: TaskFilter) async throws -> [TaskItem] { throw error }
    func task(id: UUID) async throws -> TaskItem { throw error }
    func createTask(_ draft: NewTaskDraft, requestID: UUID) async throws -> TaskItem { throw error }
    func transition(taskID: UUID, expectedVersion: Int, transition: TaskTransition, note: String?, requestID: UUID) async throws -> TaskItem { throw error }
    func reports(periodID: UUID) async throws -> [ReportItem] { throw error }
    func indicators(periodID: UUID) async throws -> [IndicatorSummary] { throw error }
    func achievements(periodID: UUID) async throws -> [AchievementItem] { throw error }
}
