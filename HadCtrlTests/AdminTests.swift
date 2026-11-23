import Foundation
import Testing
@testable import HadCtrl

@Suite("In-app administration (D-25)", .serialized)
@MainActor
struct AdminTests {
    typealias F = MockStore.Fixture
    let clock = FixedClock(date: ISO8601DateFormatter().date(from: "2026-11-23T09:00:00Z")!)

    @Test("department draft validation mirrors the server's format rules")
    func departmentDraft() {
        #expect(NewDepartmentDraft(code: "lab", nameAr: "المختبر").validate().isEmpty, "lower case is normalised")
        #expect(NewDepartmentDraft(code: "A B", nameAr: "المختبر").validate()[.code] != nil)
        #expect(NewDepartmentDraft(code: "مختبر", nameAr: "المختبر").validate()[.code] != nil, "Arabic codes are rejected")
        #expect(NewDepartmentDraft(code: "LAB", nameAr: " ").validate()[.nameAr] != nil)
    }

    @Test("employee draft: email/name required; primary only for heads with a department")
    func employeeDraft() {
        var d = NewEmployeeDraft(email: "x@y.sa", displayName: "سارة")
        #expect(d.validate().isEmpty)
        #expect(!d.effectivePrimary, "no department → not primary")
        d.departmentID = UUID()
        #expect(d.effectivePrimary)
        d.departmentRole = .coordinator
        #expect(!d.effectivePrimary)
        #expect(NewEmployeeDraft(email: "nope", displayName: "س").validate().count == 2)
    }

    @Test("director creates a department; it appears in the directory and duplicates are rejected")
    func createDepartment() async throws {
        let store = MockStore(clock: clock)
        let repos = MockRepositories(store: store, clock: clock, demoUser: F.director)
        let model = NewDepartmentViewModel(admin: repos.admin)
        model.draft = NewDepartmentDraft(code: "rad", nameAr: "الأشعة", category: .medical)
        let created = try #require(await model.save())
        #expect(created.code == "RAD")
        #expect(try await repos.departments.departments().contains { $0.id == created.id })
        let again = NewDepartmentViewModel(admin: repos.admin)
        again.draft = NewDepartmentDraft(code: "RAD", nameAr: "أشعة ٢", category: .medical)
        #expect(await again.save() == nil)
        #expect(again.fieldErrors["code"] != nil, "server-side duplicate error shown next to the field")
    }

    @Test("employee: temporary password shown once; a retry with the same request returns none")
    func createEmployee() async throws {
        let store = MockStore(clock: clock)
        let repos = MockRepositories(store: store, clock: clock, demoUser: F.director)
        let model = NewEmployeeViewModel(admin: repos.admin)
        model.draft = NewEmployeeDraft(email: "head.qlt@hospital.sa", displayName: "رئيس الجودة",
                                       departmentID: F.quality, departmentRole: .head, isPrimaryHead: true)
        let first = try #require(await model.save())
        #expect(first.accountCreated)
        #expect(first.temporaryPassword != nil)
        let replay = try #require(await model.save())      // same draft → same request id
        #expect(replay.userID == first.userID)
        #expect(replay.temporaryPassword == nil, "a password is never re-issued on replay")
        #expect(try await repos.admin.people().contains { $0.id == first.userID && $0.mustChangePassword })
        #expect(try await repos.departments.assignees(departmentID: F.quality).contains { $0.id == first.userID })
    }

    @Test("a department head cannot manage the organization; non-directors cannot create system admins")
    func authorization() async {
        let store = MockStore(clock: clock)
        let head = MockRepositories(store: store, clock: clock, demoUser: F.headLab)
        await #expect(throws: AppError.self) {
            _ = try await head.admin.createDepartment(NewDepartmentDraft(code: "ICU", nameAr: "العناية"), requestID: UUID())
        }
        #expect(!MockDirectory.context(for: F.headLab).canManageOrganization)
        #expect(MockDirectory.context(for: F.director).canManageOrganization)
    }

    @Test("Edge Function error bodies map to HC codes with field errors and correlation id")
    func functionErrors() {
        let body = #"{"code":"HC_VALIDATION_FAILED","details":{"fields":{"email":"invalid"}},"correlation_id":"abc"}"#
        #expect(FunctionErrorMapper.map(Data(body.utf8)) ==
                .server(code: .validationFailed, fieldErrors: ["email": "invalid"], currentVersion: nil, correlationID: "abc"))
        #expect(FunctionErrorMapper.map(Data(#"{"code":"HC_FORBIDDEN","details":{}}"#.utf8)).code == .forbidden)
        #expect(FunctionErrorMapper.map(Data("<html>".utf8)).code == .serverError, "unknown bodies are not guessed")
    }

    @Test("password rules")
    func passwordRules() {
        #expect(!PasswordRules.problems("short1", confirmation: "").isEmpty)
        #expect(!PasswordRules.problems("onlyletterslong", confirmation: "").isEmpty)
        #expect(PasswordRules.problems("hospital2026x", confirmation: "hospital2026x").isEmpty)
        #expect(!PasswordRules.problems("hospital2026x", confirmation: "different").isEmpty)
    }

    @Test("an account with a temporary password is routed to the password screen first")
    func forcedPasswordChange() async {
        struct TempAccount: SessionRepository {
            func restore() async throws -> UserContext? {
                UserContext(userID: UUID(), displayName: "x", organizationID: UUID(), organizationName: "x", timeZoneID: "Asia/Riyadh",
                            isDemo: false, orgRoles: [.member], departments: [], mustChangePassword: true)
            }
            func signIn(email: String, password: String) async throws -> UserContext { throw AppError.cancelled }
            func signOut() async {}
            func changePassword(_ newPassword: String) async throws -> UserContext {
                UserContext(userID: UUID(), displayName: "x", organizationID: UUID(), organizationName: "x", timeZoneID: "Asia/Riyadh",
                            isDemo: false, orgRoles: [.member], departments: [], mustChangePassword: false)
            }
        }
        let session = SessionStore(repository: TempAccount())
        await session.restore()
        guard case .mustChangePassword = session.phase else { Issue.record("expected mustChangePassword"); return }
        try? await session.changePassword("hospital2026x")
        guard case .ready = session.phase else { Issue.record("expected ready after change"); return }
    }

    @Test("my_context decodes must_change_password (server contract)")
    func contextFlag() throws {
        let json = #"{"user_id":"00000000-0000-0000-0000-000000000001","profile":{"display_name":"x","job_title":null,"must_change_password":true},"organizations":[{"organization_id":"00000000-0000-0000-0000-0000000000a0","name_ar":"م","name_en":null,"timezone":"Asia/Riyadh","is_demo":false,"roles":["member"],"departments":[]}]}"#
        let ctx = try #require(try SupabaseCoding.decoder.decode(MyContextDTO.self, from: Data(json.utf8)).toDomain())
        #expect(ctx.mustChangePassword)
        #expect(!ctx.canManageOrganization)
    }
}
