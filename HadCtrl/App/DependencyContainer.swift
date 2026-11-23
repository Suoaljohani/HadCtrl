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
        guard let urlString = bundle.object(forInfoDictionaryKey: "HCSupabaseURL") as? String,
              let url = URL(string: urlString), url.scheme == "https", url.host != nil else {
            return .failure(.configuration("HCSupabaseURL missing or not https"))
        }
        let key = (bundle.object(forInfoDictionaryKey: "HCSupabasePublishableKey") as? String) ?? ""
        guard !key.isEmpty, !key.hasPrefix("$(") else {
            return .failure(.configuration("HCSupabasePublishableKey not supplied"))
        }
        // Refuse anything that looks like a secret/service key (spec §22, §36).
        guard !key.hasPrefix("sb_secret_"), !key.localizedCaseInsensitiveContains("service_role") else {
            return .failure(.configuration("A secret key was supplied to the client; refusing to start"))
        }
        return .success(BackendConfiguration(url: url, publishableKey: key))
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
            let backend = UnavailableBackend(error: {
                switch BackendConfiguration.fromBundle() {
                case .success: return AppError.configuration("Supabase client not yet linked in this build")
                case .failure(let e): return e
                }
            }())
            return DependencyContainer(environment: environment, clock: clock, session: backend, dashboard: backend,
                                       departments: backend, tasks: backend, reports: backend, indicators: backend,
                                       achievements: backend, mockStore: nil)
        }
    }
}

/// Production placeholder until the Supabase adapters land (G3 client slice).
/// It surfaces a real configuration error instead of showing demo data.
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
