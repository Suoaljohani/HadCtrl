import Foundation
import Observation

@MainActor
@Observable
final class AdminHubViewModel {
    private(set) var departments: LoadState<[Department]> = .idle
    private(set) var people: LoadState<[PersonSummary]> = .idle
    private let admin: AdminRepository
    private let directory: DepartmentsRepository

    init(admin: AdminRepository, directory: DepartmentsRepository) {
        self.admin = admin
        self.directory = directory
    }

    func load() async {
        departments = .loading(previous: departments.value)
        people = .loading(previous: people.value)
        async let d = directory.departments()
        async let p = admin.people()
        do { departments = .loaded((try await d).sorted { $0.code < $1.code }) }
        catch { departments = .failed(error as? AppError ?? .network(offline: false), previous: nil) }
        do { people = .loaded(try await p) }
        catch { people = .failed(error as? AppError ?? .network(offline: false), previous: nil) }
    }
}

/// A request id is kept while the content is unchanged, so a retry after a
/// lost response cannot create a second department or account (AC-011).
@MainActor
@Observable
final class NewDepartmentViewModel {
    var draft = NewDepartmentDraft()
    private(set) var fieldErrors: [String: String] = [:]
    private(set) var error: AppError?
    private(set) var isSaving = false
    private var requestID = UUID()
    private var lastDraft: NewDepartmentDraft?
    private let admin: AdminRepository

    init(admin: AdminRepository) { self.admin = admin }

    func save() async -> Department? {
        fieldErrors = Dictionary(uniqueKeysWithValues: draft.validate().map { ($0.key.rawValue, $0.value) })
        guard fieldErrors.isEmpty else { return nil }
        if lastDraft != draft { requestID = UUID(); lastDraft = draft }
        isSaving = true; error = nil
        defer { isSaving = false }
        do { return try await admin.createDepartment(draft, requestID: requestID) }
        catch let e as AppError {
            error = e
            if case .server(_, let fields, _, _) = e { fieldErrors.merge(fields) { _, server in server } }
            return nil
        } catch { self.error = .network(offline: false); return nil }
    }
}

@MainActor
@Observable
final class NewEmployeeViewModel {
    var draft = NewEmployeeDraft()
    private(set) var fieldErrors: [String: String] = [:]
    private(set) var error: AppError?
    private(set) var isSaving = false
    private var requestID = UUID()
    private var lastDraft: NewEmployeeDraft?
    private let admin: AdminRepository

    init(admin: AdminRepository) { self.admin = admin }

    func save() async -> EmployeeCreationResult? {
        fieldErrors = Dictionary(uniqueKeysWithValues: draft.validate().map { ($0.key.rawValue, $0.value) })
        guard fieldErrors.isEmpty else { return nil }
        if lastDraft != draft { requestID = UUID(); lastDraft = draft }
        isSaving = true; error = nil
        defer { isSaving = false }
        do { return try await admin.createEmployee(draft, requestID: requestID) }
        catch let e as AppError {
            error = e
            if case .server(_, let fields, _, _) = e { fieldErrors.merge(fields) { _, server in server } }
            return nil
        } catch { self.error = .network(offline: false); return nil }
    }
}

/// Local rules for a new password; Supabase Auth applies the project's policy too.
enum PasswordRules {
    static let minimumLength = 10

    static func problems(_ password: String, confirmation: String) -> [String] {
        var issues: [String] = []
        if password.count < minimumLength { issues.append(String(localized: "عشرة أحرف على الأقل")) }
        if password.rangeOfCharacter(from: .decimalDigits) == nil { issues.append(String(localized: "رقم واحد على الأقل")) }
        if password.rangeOfCharacter(from: .letters) == nil { issues.append(String(localized: "حرف واحد على الأقل")) }
        if !confirmation.isEmpty && confirmation != password { issues.append(String(localized: "التأكيد لا يطابق")) }
        return issues
    }
}
