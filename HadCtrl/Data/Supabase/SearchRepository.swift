import Foundation
import Supabase

/// API-19 `search_records`; falls back to searching the lists the caller can already
/// read (RLS-filtered on the server) while migration 001900 is not yet applied.
struct SupabaseSearchRepository: SearchRepository {
    let backend: SupabaseBackend
    let fallback: CompositeSearchRepository

    private struct Row: Decodable, Sendable {
        let id: UUID
        let title: String
        let subtitle: String?
        let status: String?
    }
    private struct Payload: Decodable, Sendable {
        let departments: [Row]; let goals: [Row]; let tasks: [Row]
        let reports: [Row]; let achievements: [Row]; let indicators: [Row]
    }
    private struct Params: Encodable, Sendable { let p_query: String; let p_period_id: UUID? }

    func search(_ query: String, periodID: UUID?, routePeriodID: UUID?) async throws -> SearchResults {
        let payload: Payload
        do {
            payload = try await backend.client.rpc("search_records", params: Params(p_query: query, p_period_id: periodID))
                .execute().value
        } catch let error as PostgrestError where error.code == "PGRST202" {
            return try await fallback.search(query, periodID: periodID, routePeriodID: routePeriodID)
        } catch {
            throw SupabaseErrorMapper.map(error)
        }
        func hits(_ rows: [Row], _ c: SearchCategory) -> [SearchHit] {
            rows.map { r in
                let route: AppRoute? = switch c {
                    case .departments: .department(r.id)
                    case .goals: .goal(r.id)
                    case .tasks: .task(r.id)
                    case .reports: .report(r.id)
                    case .achievements: .achievement(r.id)
                    case .indicators: routePeriodID.map { .indicator(r.id, periodID: $0) }
                }
                return SearchHit(id: r.id, category: c, title: r.title, subtitle: r.subtitle ?? "", status: r.status, route: route)
            }
        }
        return SearchResults(hits: [
            .departments: hits(payload.departments, .departments), .goals: hits(payload.goals, .goals),
            .tasks: hits(payload.tasks, .tasks), .reports: hits(payload.reports, .reports),
            .achievements: hits(payload.achievements, .achievements), .indicators: hits(payload.indicators, .indicators),
        ])
    }
}

/// Searches the lists the caller can already read, with the same Arabic
/// normalization. Used by demo builds and as the server fallback.
struct CompositeSearchRepository: SearchRepository {
    let departments: DepartmentsRepository
    let tasks: TasksRepository
    let goals: GoalsRepository
    let reports: ReportsRepository
    let achievements: AchievementsRepository
    let indicators: IndicatorsRepository
    let clock: HCClock
    let limit = 8

    func search(_ query: String, periodID: UUID?, routePeriodID: UUID?) async throws -> SearchResults {
        let q = ArabicSearch.normalize(query)
        func match(_ s: String) -> Bool { ArabicSearch.normalize(s).contains(q) }
        let period = periodID ?? routePeriodID

        async let deptList = departments.departments()
        async let taskList = tasks.tasks(filter: TaskFilter())
        async let goalList = goals.goals(departmentID: nil, asOf: clock.now())
        let depts = try await deptList
        let taskItems = try await taskList
        let goalItems = try await goalList
        var reportItems: [ReportItem] = []
        var achievementItems: [AchievementItem] = []
        var indicatorItems: [IndicatorSummary] = []
        if let period {
            async let r = reports.reports(periodID: period)
            async let a = achievements.achievements(periodID: period)
            async let i = indicators.indicators(periodID: period)
            reportItems = (try? await r) ?? []
            achievementItems = (try? await a) ?? []
            indicatorItems = (try? await i) ?? []
        }
        var out = SearchResults()
        out.hits[.departments] = depts.filter { match($0.nameAr) || $0.code.lowercased().contains(q) }.prefix(limit)
            .map { SearchHit(id: $0.id, category: .departments, title: $0.nameAr, subtitle: $0.code, status: nil, route: .department($0.id)) }
        out.hits[.goals] = goalItems.filter { match($0.title) }.prefix(limit)
            .map { SearchHit(id: $0.id, category: .goals, title: $0.title, subtitle: $0.departmentName, status: $0.lifecycle.rawValue, route: .goal($0.id)) }
        out.hits[.tasks] = taskItems.filter { match($0.title) }.prefix(limit)
            .map { SearchHit(id: $0.id, category: .tasks, title: $0.title, subtitle: $0.departmentName, status: $0.status.rawValue, route: .task($0.id)) }
        out.hits[.reports] = reportItems.filter { match($0.templateName) || match($0.departmentName) }.prefix(limit)
            .map { SearchHit(id: $0.id, category: .reports, title: $0.templateName, subtitle: $0.departmentName, status: $0.status.rawValue, route: .report($0.id)) }
        out.hits[.achievements] = achievementItems.filter { match($0.title) }.prefix(limit)
            .map { SearchHit(id: $0.id, category: .achievements, title: $0.title, subtitle: $0.departmentName, status: $0.status.rawValue, route: .achievement($0.id)) }
        out.hits[.indicators] = indicatorItems.filter { match($0.title) || $0.code.lowercased().contains(q) }.prefix(limit)
            .map { i in SearchHit(id: i.id, category: .indicators, title: i.title, subtitle: "\(i.departmentName) · \(i.code)", status: nil,
                                  route: period.map { .indicator(i.id, periodID: $0) }) }
        return out
    }
}
