import Foundation
import Testing
@testable import HadCtrl

/// Contract tests: decode real RPC output captured from the tested database
/// (Fixtures/contracts.json, produced by scripts/db-test.sh fixtures) with the
/// SDK's own decoder, and map real server error shapes. No network.
@Suite("Supabase contracts (API-01, my_context, errors)")
struct SupabaseContractTests {
    private final class BundleToken {}

    private func fixture() throws -> [String: Any] {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "contracts", withExtension: "json"))
        return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        let value = try #require(try fixture()[key])
        let data = try JSONSerialization.data(withJSONObject: value)
        return try SupabaseCoding.decoder.decode(T.self, from: data)
    }

    @Test("dashboard_snapshot decodes and maps without inventing numbers")
    func dashboardSnapshot() throws {
        let dto = try decode(DashboardSnapshotDTO.self, key: "dashboard_snapshot")
        #expect(dto.schema_version == 1)
        #expect(dto.coverage.verdict == "final")
        let lab = Department(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!, code: "LAB", nameAr: "المختبر",
                             category: .medical, headName: nil, headVisible: false, isArchived: false)
        let snap = DashboardMapper.map(dto, departments: [lab.id: lab])
        #expect(snap.verdict == .final)
        #expect(snap.coverage == 100)
        #expect(abs((snap.measuredScore ?? 0) - Decimal(string: "96.8421")!) < 0.0001)
        #expect(!snap.isDemoData, "server data is never labelled demo")
        #expect(snap.departmentsUpdated == nil, "not provided by the server; not faked")
        let reports = try #require(snap.readings.first { $0.metric == .reportsReceived })
        #expect(reports.numerator == 1 && reports.denominator == 1, "waived report excluded from denominator")
        #expect(snap.departments.count == dto.departments.count)
        #expect(snap.departments.first { $0.department.id == lab.id }?.department.nameAr == "المختبر")
    }

    @Test("dashboard actions map kinds, report titles and routes")
    func dashboardActions() throws {
        let json = """
        {"schema_version":1,"generated_at":"2026-11-23T09:02:14.592965+00:00","organization_id":"00000000-0000-0000-0000-0000000000a0",
         "period_id":"00000000-0000-0000-0000-0000000000f1","period_state":"open",
         "coverage":{"required_weight":4,"covered_weight":3,"coverage_pct":75.0,"measured_score":92.5,"verdict":"insufficient_data","policy":"coverage-80/v1"},
         "readings":{"goals_achieved":{"numerator":0,"denominator":0},"indicators_updated":{"numerator":3,"denominator":4,"unit":"weight"},
           "reports_received":{"numerator":1,"denominator":2,"waived":0,"late":1},"tasks_completed":{"numerator":1,"denominator":3,"cancelled":0},
           "achievements_approved":0,"awaiting_my_decision":1},
         "actions":[
           {"kind":"ready_for_approval","kind_rank":2,"entity_type":"report","entity_id":"00000000-0000-0000-0000-0000000002a1","title":null,"department_id":"00000000-0000-0000-0000-0000000000d1","due_at":"2026-12-05T20:59:00+00:00"},
           {"kind":"urgent_blocker","kind_rank":0,"entity_type":"task","entity_id":"00000000-0000-0000-0000-000000000c04","title":"عائق","department_id":"00000000-0000-0000-0000-0000000000d1","due_at":null},
           {"kind":"something_new","kind_rank":9,"entity_type":"task","entity_id":"00000000-0000-0000-0000-000000000c05","title":"x","department_id":"00000000-0000-0000-0000-0000000000d1","due_at":null}],
         "departments":[]}
        """
        let dto = try SupabaseCoding.decoder.decode(DashboardSnapshotDTO.self, from: Data(json.utf8))
        let snap = DashboardMapper.map(dto, departments: [:])
        #expect(snap.verdict == .insufficientData)
        #expect(snap.actions.count == 2, "unknown kinds are dropped, not guessed")
        #expect(snap.topActions.first?.kind == .urgentBlocker)
        let report = try #require(snap.actions.first { $0.kind == .readyForApproval })
        #expect(report.route == .report(UUID(uuidString: "00000000-0000-0000-0000-0000000002A1")!))
        #expect(!report.title.isEmpty)
    }

    @Test("my_context maps server roles; no membership → nil (AC-002)")
    func myContext() throws {
        let dto = try decode(MyContextDTO.self, key: "my_context")
        let ctx = try #require(dto.toDomain())
        #expect(ctx.isDirector)
        #expect(ctx.isDemo)
        #expect(ctx.timeZoneID == "Asia/Riyadh")
        let empty = MyContextDTO(user_id: UUID(), profile: nil, organizations: [])
        #expect(empty.toDomain() == nil)
    }

    @Test("create_task result decodes")
    func createTaskResult() throws {
        let dto = try decode(TaskMutationDTO.self, key: "create_task")
        #expect(dto.status == "assigned")
        #expect(dto.version == 1)
    }

    @Test("server HC_* errors map by code, with field errors and current version")
    func errorMapping() {
        let validation = SupabaseErrorMapper.mapPostgrest(message: "HC_VALIDATION_FAILED", code: "P0001",
                                                          details: #"{"fields":{"assignee_id":"not_active_department_member"}}"#)
        #expect(validation == .server(code: .validationFailed, fieldErrors: ["assignee_id": "not_active_department_member"],
                                      currentVersion: nil, correlationID: nil))
        let conflict = SupabaseErrorMapper.mapPostgrest(message: "HC_VERSION_CONFLICT", code: "P0001", details: #"{"current_version":4}"#)
        #expect(conflict == .server(code: .versionConflict, fieldErrors: [:], currentVersion: 4, correlationID: nil))
        #expect(SupabaseErrorMapper.mapPostgrest(message: "HC_NOT_FOUND", code: "P0001", details: "{}").code == .notFound)
        #expect(SupabaseErrorMapper.mapPostgrest(message: "permission denied for table tasks", code: "42501", details: nil).code == .forbidden)
        #expect(SupabaseErrorMapper.mapPostgrest(message: "JWT expired", code: "PGRST301", details: nil).requiresSignIn)
        // Free-text messages are never parsed for meaning.
        #expect(SupabaseErrorMapper.mapPostgrest(message: "something HC_FORBIDDEN-ish", code: "XX000", details: nil).code == .serverError)
        #expect(SupabaseErrorMapper.map(URLError(.notConnectedToInternet)) == .network(offline: true))
        #expect(SupabaseErrorMapper.map(CancellationError()) == .cancelled)
    }

    @Test("configuration refuses secret keys and placeholders (§22)")
    func configurationGuards() {
        #expect(BackendConfiguration.validate(urlString: "https://x.supabase.co", key: "sb_" + "secret_abc") != nil)
        #expect(BackendConfiguration.validate(urlString: "https://x.supabase.co", key: "") != nil)
        #expect(BackendConfiguration.validate(urlString: "https://x.supabase.co", key: "$(HC_SUPABASE_PUBLISHABLE_KEY)") != nil)
        #expect(BackendConfiguration.validate(urlString: "http://x.supabase.co", key: "sb_publishable_abc") != nil)
        #expect(BackendConfiguration.validate(urlString: "https://x.supabase.co", key: "sb_publishable_abc") == nil)
    }
}
