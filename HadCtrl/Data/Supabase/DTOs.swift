import Foundation

// Wire types for the Supabase API (docs/API_CONTRACTS.md). They mirror the
// server JSON exactly and are mapped to domain models in one place, so JSON
// names never leak into views (spec §21). Field names use snake_case keys.

struct MyContextDTO: Decodable, Sendable {
    struct Profile: Decodable, Sendable {
        let display_name: String
        let job_title: String?
    }
    struct Department: Decodable, Sendable {
        let department_id: UUID
        let name_ar: String
        let code: String
        let roles: [String]
    }
    struct Organization: Decodable, Sendable {
        let organization_id: UUID
        let name_ar: String
        let name_en: String?
        let timezone: String
        let is_demo: Bool
        let roles: [String]
        let departments: [Department]
    }
    let user_id: UUID
    let profile: Profile?
    let organizations: [Organization]

    /// v1 supports one hospital per account (§02). Picks the first membership the
    /// server returned (ordered by name). Returns nil when there is none.
    func toDomain() -> UserContext? {
        guard let org = organizations.first else { return nil }
        return UserContext(
            userID: user_id,
            displayName: profile?.display_name ?? "",
            organizationID: org.organization_id,
            organizationName: org.name_ar,
            timeZoneID: org.timezone,
            isDemo: org.is_demo,
            orgRoles: Set(org.roles.compactMap(OrgRole.init(rawValue:))),
            departments: org.departments.map {
                DepartmentScope(id: $0.department_id, nameAr: $0.name_ar, code: $0.code,
                                roles: Set($0.roles.compactMap(DepartmentRole.init(rawValue:))))
            })
    }
}

/// Result of create_task / transition_task (task_json on the server).
struct TaskMutationDTO: Decodable, Sendable {
    let task_id: UUID
    let status: String
    let version: Int
    let replayed: Bool?
}

struct TaskRowDTO: Decodable, Sendable {
    let id: UUID
    let department_id: UUID
    let title: String
    let description: String
    let status: String
    let priority: String
    let assignee_id: UUID?
    let creator_id: UUID
    let original_due_at: Date?
    let due_at: Date?
    let first_submitted_at: Date?
    let version: Int

    static let columns = "id,department_id,title,description,status,priority,assignee_id,creator_id,original_due_at,due_at,first_submitted_at,version"

    func toDomain(departmentName: String, assigneeName: String?) throws -> TaskItem {
        guard let status = TaskStatus(rawValue: status), let priority = Priority(rawValue: priority) else {
            throw AppError.decoding("unknown task status/priority \(self.status)/\(self.priority)")
        }
        return TaskItem(id: id, departmentID: department_id, departmentName: departmentName, title: title,
                        details: description, status: status, priority: priority, assigneeID: assignee_id,
                        assigneeName: assigneeName, creatorID: creator_id, originalDueAt: original_due_at,
                        dueAt: due_at, firstSubmittedAt: first_submitted_at, version: version)
    }
}

struct DepartmentRowDTO: Decodable, Sendable {
    let id: UUID
    let code: String
    let name_ar: String
    let category: String
    let archived_at: Date?
    static let columns = "id,code,name_ar,category,archived_at"
}

struct MembershipRowDTO: Decodable, Sendable {
    let department_id: UUID
    let user_id: UUID
    let role: String
    let is_primary: Bool
    static let columns = "department_id,user_id,role,is_primary"
}

struct ProfileRowDTO: Decodable, Sendable {
    let user_id: UUID
    let display_name: String
}

struct PeriodRowDTO: Decodable, Sendable {
    let id: UUID
    let type: String
    let start_date: String   // PostgreSQL `date` → "YYYY-MM-DD"
    let end_date: String
    let state: String
    static let columns = "id,type,start_date,end_date,state"
}

struct DashboardSnapshotDTO: Decodable, Sendable {
    struct Coverage: Decodable, Sendable {
        let required_weight: Decimal
        let covered_weight: Decimal
        let coverage_pct: Decimal
        let measured_score: Decimal?
        let verdict: String
        let policy: String
    }
    struct Ratio: Decodable, Sendable {
        let numerator: Decimal
        let denominator: Decimal
    }
    struct Readings: Decodable, Sendable {
        let goals_achieved: Ratio
        let indicators_updated: Ratio
        let reports_received: Ratio
        let tasks_completed: Ratio
        let achievements_approved: Int
        let awaiting_my_decision: Int
    }
    struct Action: Decodable, Sendable {
        let kind: String
        let entity_type: String
        let entity_id: UUID
        let title: String?
        let department_id: UUID
        let due_at: Date?
    }
    struct Department: Decodable, Sendable {
        let department_id: UUID
        let code: String
        let name_ar: String
        let open_tasks: Int
        let overdue_tasks: Int
        let reports_pending: Int
    }
    let schema_version: Int
    let generated_at: Date
    let organization_id: UUID
    let period_id: UUID
    let period_state: String
    let coverage: Coverage
    let readings: Readings
    let actions: [Action]
    let departments: [Department]
}

/// HC_* error details: `{"fields":{name:reason}}` and/or `{"current_version":n}`.
struct RPCErrorDetailDTO: Decodable, Sendable {
    let fields: [String: String]?
    let current_version: Int?
}
