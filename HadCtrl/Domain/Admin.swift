import Foundation

// In-app administration (D-25): the director or system admin creates
// departments and employee accounts. Every rule is enforced on the server;
// these types only shape input and show results.

struct NewDepartmentDraft: Sendable, Equatable {
    var code = ""
    var nameAr = ""
    var category: DepartmentCategory = .medical

    enum Field: String, Sendable { case code, nameAr = "name_ar", category }

    /// Mirrors the server's format check so mistakes show next to the field
    /// before a round trip; the server re-checks everything.
    func validate() -> [Field: String] {
        var errors: [Field: String] = [:]
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        if c.range(of: "^[A-Z0-9][A-Z0-9_-]{0,15}$", options: .regularExpression) == nil {
            errors[.code] = String(localized: "رمز من حروف لاتينية وأرقام، حتى ١٦ خانة (مثل LAB)")
        }
        if nameAr.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
            errors[.nameAr] = String(localized: "اكتب اسم القسم")
        }
        return errors
    }
}

enum EmployeeOrgRole: String, Sendable, CaseIterable, Identifiable {
    case member
    case executiveViewer = "executive_viewer"
    case systemAdmin = "system_admin"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .member: return String(localized: "موظف")
        case .executiveViewer: return String(localized: "مشاهد تنفيذي")
        case .systemAdmin: return String(localized: "مسؤول تقني")
        }
    }
}

struct NewEmployeeDraft: Sendable, Equatable {
    var email = ""
    var displayName = ""
    var jobTitle = ""
    var orgRole: EmployeeOrgRole = .member
    var departmentID: UUID?
    var departmentRole: DepartmentRole = .head
    var isPrimaryHead = true

    enum Field: String, Sendable { case email, displayName = "display_name", departmentID = "department_id", isPrimary = "is_primary", orgRole = "org_role" }

    func validate() -> [Field: String] {
        var errors: [Field: String] = [:]
        let e = email.trimmingCharacters(in: .whitespaces)
        if e.range(of: "^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", options: .regularExpression) == nil {
            errors[.email] = String(localized: "بريد إلكتروني غير صالح")
        }
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
            errors[.displayName] = String(localized: "اكتب اسم الموظف")
        }
        return errors
    }

    /// The primary flag only applies to heads.
    var effectivePrimary: Bool { departmentID != nil && departmentRole == .head && isPrimaryHead }
}

/// Result of account creation. The temporary password exists only in memory,
/// is shown once, and is never persisted or logged.
struct EmployeeCreationResult: Sendable, Equatable {
    let userID: UUID
    let accountCreated: Bool
    let temporaryPassword: String?
}

struct PersonSummary: Sendable, Hashable, Identifiable {
    struct Assignment: Sendable, Hashable {
        let departmentName: String
        let role: DepartmentRole
        let isPrimary: Bool
    }
    let id: UUID
    let displayName: String
    let jobTitle: String?
    let isActive: Bool
    let mustChangePassword: Bool
    let orgRoles: Set<OrgRole>
    let assignments: [Assignment]
}

protocol AdminRepository: Sendable {
    func people() async throws -> [PersonSummary]
    func createDepartment(_ draft: NewDepartmentDraft, requestID: UUID) async throws -> Department
    func createEmployee(_ draft: NewEmployeeDraft, requestID: UUID) async throws -> EmployeeCreationResult
}
