import Foundation

// Domain models are independent of JSON field names; DTOs map them (spec §21).

enum OrgRole: String, Sendable, Codable, Hashable {
    case hospitalDirector = "hospital_director"
    case executiveViewer = "executive_viewer"
    case systemAdmin = "system_admin"
    case member
}

enum DepartmentRole: String, Sendable, Codable, Hashable {
    case head = "department_head"
    case coordinator = "department_coordinator"
}

struct DepartmentScope: Sendable, Hashable, Identifiable {
    let id: UUID
    let nameAr: String
    let code: String
    let roles: Set<DepartmentRole>
}

/// Memberships resolved by the server (`my_context`). Never chosen by the user.
struct UserContext: Sendable, Equatable {
    let userID: UUID
    let displayName: String
    let organizationID: UUID
    let organizationName: String
    let timeZoneID: String
    let isDemo: Bool
    let orgRoles: Set<OrgRole>
    let departments: [DepartmentScope]
    /// Set for accounts created with a temporary password (D-25).
    var mustChangePassword: Bool = false

    var isDirector: Bool { orgRoles.contains(.hospitalDirector) }
    /// May create departments and employee accounts (server re-checks).
    var canManageOrganization: Bool { isDirector || orgRoles.contains(.systemAdmin) }
    var headedDepartments: [DepartmentScope] { departments.filter { $0.roles.contains(.head) } }
    var canCreateAssignments: Bool { isDirector || !headedDepartments.isEmpty }
}

enum PeriodType: String, Sendable, Codable, CaseIterable { case weekly, monthly, quarterly, annual }

struct ReportingPeriod: Sendable, Hashable, Identifiable {
    enum State: String, Sendable, Codable { case planned, open, review, frozen }
    let id: UUID
    let type: PeriodType
    let start: Date
    let end: Date
    let state: State
    let title: String
}

enum DepartmentCategory: String, Sendable, Codable { case medical, technical, administrative }

struct Department: Sendable, Hashable, Identifiable {
    let id: UUID
    let code: String
    let nameAr: String
    let category: DepartmentCategory
    let headName: String?
    /// False when the caller may not read this department's memberships (RLS);
    /// then a missing head is unknown, not "no active head".
    var headVisible: Bool = true
    let isArchived: Bool
}

enum TaskStatus: String, Sendable, Codable, CaseIterable {
    case draft, assigned, acknowledged
    case inProgress = "in_progress"
    case blocked, submitted, returned, completed, cancelled

    var isOpen: Bool { ![.completed, .cancelled, .draft].contains(self) }
    /// Work is still with the assignee (used for "overdue"; submitted waits on the reviewer).
    var isWithAssignee: Bool { [.assigned, .acknowledged, .inProgress, .blocked, .returned].contains(self) }
}

enum Priority: String, Sendable, Codable, CaseIterable { case low, normal, high, urgent }

enum TaskTransition: String, Sendable, Codable {
    case assign, acknowledge, start, block, unblock, submit, approve, `return`, cancel, reassign

    var requiresNote: Bool { [.block, .return, .cancel, .reassign].contains(self) }
}

struct TaskItem: Sendable, Hashable, Identifiable {
    let id: UUID
    var departmentID: UUID
    var departmentName: String
    var title: String
    var details: String
    var status: TaskStatus
    var priority: Priority
    var assigneeID: UUID?
    var assigneeName: String?
    var creatorID: UUID
    var originalDueAt: Date?
    var dueAt: Date?
    var firstSubmittedAt: Date?
    var version: Int

    /// "Overdue" is computed, never stored (spec §12).
    func isOverdue(now: Date) -> Bool {
        guard let dueAt, status.isWithAssignee else { return false }
        return now > dueAt
    }

    /// Transitions the given user may attempt; the server re-checks every one.
    func availableTransitions(for user: UserContext) -> [TaskTransition] {
        let isAssignee = assigneeID == user.userID
        let headsDept = user.headedDepartments.contains { $0.id == departmentID }
        let canApprove = !isAssignee && (user.isDirector || (creatorID == user.userID && headsDept))
        switch status {
        case .draft: return creatorID == user.userID ? [.assign, .cancel] : []
        case .assigned: return (isAssignee ? [.acknowledge, .start, .submit] : []) + manage(user, headsDept)
        case .acknowledged: return (isAssignee ? [.start, .submit, .block] : []) + manage(user, headsDept)
        case .inProgress: return (isAssignee ? [.submit, .block] : []) + manage(user, headsDept)
        case .blocked: return (isAssignee || user.isDirector ? [.unblock] : []) + manage(user, headsDept)
        case .returned: return (isAssignee ? [.start, .submit] : []) + manage(user, headsDept)
        case .submitted: return (canApprove ? [.approve, .return] : []) + manage(user, headsDept)
        case .completed, .cancelled: return []
        }
    }

    private func manage(_ user: UserContext, _ headsDept: Bool) -> [TaskTransition] {
        var result: [TaskTransition] = []
        if user.isDirector || headsDept { result.append(.reassign) }
        if user.isDirector || (creatorID == user.userID && headsDept) { result.append(.cancel) }
        return result
    }
}

struct NewTaskDraft: Sendable, Equatable {
    var departmentID: UUID?
    var title = ""
    var details = ""
    var assigneeID: UUID?
    var dueDate: Date?
    var priority: Priority = .normal

    enum Field: String, Sendable { case department, title, assignee, dueDate }

    func validate(now: Date) -> [Field: String] {
        var errors: [Field: String] = [:]
        if departmentID == nil { errors[.department] = String(localized: "اختر القسم") }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 { errors[.title] = String(localized: "العنوان قصير جدًا") }
        if assigneeID == nil { errors[.assignee] = String(localized: "حدد المسؤول") }
        if let dueDate { if dueDate <= now { errors[.dueDate] = String(localized: "الموعد يجب أن يكون في المستقبل") } }
        else { errors[.dueDate] = String(localized: "حدد موعد الاستحقاق") }
        return errors
    }
}

struct Assignee: Sendable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let role: DepartmentRole
}

enum ReportStatus: String, Sendable, Codable, CaseIterable {
    case notSubmitted = "not_submitted"
    case submitted
    case underReview = "under_review"
    case returned, approved, waived
}

struct ReportItem: Sendable, Hashable, Identifiable {
    let id: UUID
    let departmentName: String
    let templateName: String
    let periodTitle: String
    let dueAt: Date
    let firstSubmittedAt: Date?
    let status: ReportStatus
    let waiverReason: String?
    var departmentID: UUID?
    /// report_instances.version, sent back as expected_version.
    var version: Int = 1

    /// Submission compliance uses the first valid submission, not the approval time (AC-015).
    var submittedOnTime: Bool? {
        guard let firstSubmittedAt else { return nil }
        return firstSubmittedAt <= dueAt
    }
}

struct IndicatorSummary: Sendable, Hashable, Identifiable {
    let id: UUID
    let code: String
    let title: String
    let departmentName: String
    let unit: String
    let direction: ImprovementDirection
    let target: Decimal?
    let actual: Decimal?
    let outcome: ScoreOutcomeBox
    let weight: Decimal
    let howMeasured: String
    var definitionVersionID: UUID?
    var departmentID: UUID?
    /// Status of the newest reading this period (a pending one is not a result).
    var latestStatus: MeasurementStatus?
    var rangeMin: Decimal?
    var rangeMax: Decimal?
}

/// Hashable wrapper so views can diff summaries.
struct ScoreOutcomeBox: Sendable, Hashable {
    let outcome: ScoreOutcome
    static func == (l: Self, r: Self) -> Bool { l.outcome == r.outcome }
    func hash(into h: inout Hasher) { h.combine(String(describing: outcome)) }
}

struct AchievementItem: Sendable, Hashable, Identifiable {
    enum Status: String, Sendable { case draft, submitted, returned, approved, rejected, archived }
    let id: UUID
    let title: String
    let departmentName: String
    let impactSummary: String
    let periodTitle: String
    let status: Status
}

/// A "needs your decision" item with an explicit ordering rule (spec §06).
struct ActionItem: Sendable, Hashable, Identifiable {
    enum Kind: Int, Sendable, Comparable {
        case urgentBlocker = 0, overdueSubmission = 1, readyForApproval = 2, dueSoon = 3
        static func < (l: Kind, r: Kind) -> Bool { l.rawValue < r.rawValue }
    }
    let id: UUID
    let kind: Kind
    let title: String
    let departmentName: String
    let reason: String
    let dueAt: Date?
    let route: AppRoute
}

/// A count that always carries its numerator, denominator and target route.
struct DashboardReading: Sendable, Hashable, Identifiable {
    enum Metric: String, Sendable, CaseIterable {
        case goalsAchieved, indicatorsUpdated, reportsReceived, tasksCompleted, achievementsApproved, awaitingDirector
    }
    var id: Metric { metric }
    let metric: Metric
    let numerator: Int
    let denominator: Int?
    let route: AppRoute
}

struct DepartmentPulse: Sendable, Hashable, Identifiable {
    var id: UUID { department.id }
    let department: Department
    let openTasks: Int
    let overdueTasks: Int
    let reportsDue: Int
    let coverage: Decimal?
}

struct DashboardSnapshot: Sendable, Equatable {
    let generatedAt: Date
    let periodID: UUID
    let organizationID: UUID
    let measuredScore: Decimal?
    let coverage: Decimal
    let verdict: CoverageResult.Verdict
    /// Departments with updated data; nil when the source does not report it.
    let departmentsUpdated: Int?
    let departmentsTotal: Int?
    let readings: [DashboardReading]
    let actions: [ActionItem]
    let departments: [DepartmentPulse]
    let isDemoData: Bool

    /// Up to three actions, ordered by kind then due date (spec §06).
    var topActions: [ActionItem] {
        Array(actions.sorted { ($0.kind, $0.dueAt ?? .distantFuture) < ($1.kind, $1.dueAt ?? .distantFuture) }.prefix(3))
    }
}
