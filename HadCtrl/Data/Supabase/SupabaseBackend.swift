import Foundation
import Supabase

// Production data layer on supabase-swift 2.55.7 (pinned in project.yml,
// locked by Config/Package.resolved). Only the URL and publishable key reach
// the device (§22); every authorization decision is made by the server.

/// The SDK's own PostgREST decoder (Supabase date handling, keys unchanged).
/// Exposed so contract tests decode exactly as production does.
enum SupabaseCoding {
    static var decoder: JSONDecoder { PostgrestClient.Configuration.jsonDecoder }
}

enum SupabaseClientFactory {
    /// Session tokens live in the Keychain (SDK `KeychainLocalStorage`), under an
    /// app-specific service name, never in UserDefaults or logs (§22).
    static func make(_ config: BackendConfiguration) -> SupabaseClient {
        SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.publishableKey,
            options: SupabaseClientOptions(
                auth: .init(storage: KeychainLocalStorage(service: "hadctrl.auth"),
                            redirectToURL: URL(string: "hadctrl://auth/callback"),
                            emitLocalSessionAsInitialSession: true)))
    }
}

/// Maps transport, auth and PostgREST errors to `AppError` using machine codes
/// only (§27). Never surfaces SQL or tokens to the UI.
enum SupabaseErrorMapper {
    static func map(_ error: Error) -> AppError {
        if let app = error as? AppError { return app }
        if error is CancellationError { return .cancelled }
        if let pg = error as? PostgrestError { return map(pg) }
        if let auth = error as? AuthError { return map(auth) }
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return .network(offline: true)
            case .cancelled: return .cancelled
            default: return .network(offline: false)
            }
        }
        if error is DecodingError { return .decoding(String(describing: type(of: error))) }
        return .server(code: .serverError, fieldErrors: [:], currentVersion: nil, correlationID: nil)
    }

    static func map(_ pg: PostgrestError) -> AppError {
        mapPostgrest(message: pg.message, code: pg.code, details: pg.details)
    }

    /// PostgREST error fields → AppError. Pure, so it is unit-tested directly.
    static func mapPostgrest(message: String, code: String?, details: String?) -> AppError {
        if let hc = HCErrorCode(rawValue: message) {
            let detail = details.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(RPCErrorDetailDTO.self, from: $0) }
            return .server(code: hc, fieldErrors: detail?.fields ?? [:], currentVersion: detail?.current_version,
                           correlationID: nil)
        }
        switch code {
        case "42501": // insufficient_privilege: grant/RLS refusal
            return .server(code: .forbidden, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        case "PGRST301", "PGRST302": // JWT expired / missing
            return .server(code: .authRequired, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        default:
            return .server(code: .serverError, fieldErrors: [:], currentVersion: nil, correlationID: code)
        }
    }

    static func map(_ auth: AuthError) -> AppError {
        switch auth {
        case .sessionMissing, .refreshDiscarded:
            return .server(code: .authRequired, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        case .api(_, let errorCode, _, _) where errorCode == .invalidCredentials:
            return .invalidCredentials
        default:
            return .server(code: .authRequired, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
    }
}

/// Per-session lookup cache (names of departments and people). Cleared on
/// sign-in/sign-out so nothing from a previous account is reused (AC-025).
actor SessionCache {
    private var departments: [UUID: Department]?
    private var names: [UUID: String] = [:]
    private(set) var context: UserContext?

    func clear() { departments = nil; names = [:]; context = nil }
    func set(context: UserContext?) { self.context = context }
    func invalidateDepartments() { departments = nil }
    func cachedDepartments() -> [UUID: Department]? { departments }
    func store(departments list: [Department]) { departments = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) }) }
    func names(for ids: Set<UUID>) -> (known: [UUID: String], missing: Set<UUID>) {
        var known: [UUID: String] = [:]
        var missing: Set<UUID> = []
        for id in ids { if let n = names[id] { known[id] = n } else { missing.insert(id) } }
        return (known, missing)
    }
    func store(names new: [UUID: String]) { names.merge(new) { _, latest in latest } }
}

/// Shared plumbing for all Supabase repositories.
struct SupabaseBackend: Sendable {
    let client: SupabaseClient
    let cache: SessionCache
    let calendar: HospitalCalendar

    /// Runs a call and maps any error to AppError.
    func call<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw SupabaseErrorMapper.map(error) }
    }

    func departmentsByID() async throws -> [UUID: Department] {
        if let cached = await cache.cachedDepartments() { return cached }
        let rows: [DepartmentRowDTO] = try await call {
            try await client.from("departments").select(DepartmentRowDTO.columns)
                .order("sort_order").order("name_ar").execute().value
        }
        // Primary heads are visible to the director, system admin and the head
        // themself; for others the head is "not visible", not "missing" (RLS).
        let heads: [MembershipRowDTO] = try await call {
            try await client.from("department_memberships").select(MembershipRowDTO.columns)
                .eq("role", value: "department_head").eq("is_primary", value: true).eq("active", value: true)
                .execute().value
        }
        let headNames = try await displayNames(Set(heads.map(\.user_id)))
        let headByDept = Dictionary(heads.map { ($0.department_id, $0.user_id) }, uniquingKeysWith: { a, _ in a })
        // Membership rows are readable by the director/system admin (all) and by a
        // head (own department). Elsewhere an absent head means "not visible".
        let ctx = await cache.context
        let seesAllHeads = ctx.map { $0.isDirector || $0.orgRoles.contains(.systemAdmin) } ?? false
        let headedIDs = Set(ctx?.headedDepartments.map(\.id) ?? [])
        let list = rows.map { row in
            Department(id: row.id, code: row.code, nameAr: row.name_ar,
                       category: DepartmentCategory(rawValue: row.category) ?? .administrative,
                       headName: headByDept[row.id].flatMap { headNames[$0] },
                       headVisible: seesAllHeads || headedIDs.contains(row.id),
                       isArchived: row.archived_at != nil)
        }
        await cache.store(departments: list)
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    func displayNames(_ ids: Set<UUID>) async throws -> [UUID: String] {
        guard !ids.isEmpty else { return [:] }
        let (known, missing) = await cache.names(for: ids)
        guard !missing.isEmpty else { return known }
        let rows: [ProfileRowDTO] = try await call {
            try await client.from("profiles").select("user_id,display_name")
                .in("user_id", values: missing.map(\.uuidString)).execute().value
        }
        let fetched = Dictionary(uniqueKeysWithValues: rows.map { ($0.user_id, $0.display_name) })
        await cache.store(names: fetched)
        return known.merging(fetched) { a, _ in a }
    }

    /// "YYYY-MM-DD" in hospital time for date-only parameters (server applies end of day).
    func dateString(_ date: Date) -> String {
        let c = calendar.calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func parseDate(_ s: String) -> Date? {
        let parts = s.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
