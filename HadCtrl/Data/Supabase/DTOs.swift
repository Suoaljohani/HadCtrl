import Foundation

// Wire types for the Supabase API (docs/API_CONTRACTS.md). They mirror the
// server JSON exactly and are mapped to domain models in one place, so JSON
// names never leak into views (spec §21). Field names use snake_case keys.

struct MyContextDTO: Decodable, Sendable {
    struct Profile: Decodable, Sendable {
        let display_name: String
        let job_title: String?
        let must_change_password: Bool?
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
            },
            mustChangePassword: profile?.must_change_password ?? false)
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

struct CreatedDepartmentDTO: Decodable, Sendable {
    let department_id: UUID
    let code: String
    let name_ar: String
    let category: String
}

struct CreatedEmployeeDTO: Decodable, Sendable {
    let user_id: UUID
    let account_created: Bool
    let temporary_password: String?
}

/// One row of list_people.
struct PersonDTO: Decodable, Sendable {
    struct Assignment: Decodable, Sendable {
        let department_id: UUID
        let name_ar: String
        let code: String
        let role: String
        let is_primary: Bool
    }
    let user_id: UUID
    let display_name: String
    let job_title: String?
    let active: Bool
    let must_change_password: Bool
    let org_roles: [String]
    let departments: [Assignment]

    func toDomain() -> PersonSummary {
        PersonSummary(id: user_id, displayName: display_name, jobTitle: job_title, isActive: active,
                      mustChangePassword: must_change_password,
                      orgRoles: Set(org_roles.compactMap(OrgRole.init(rawValue:))),
                      assignments: departments.compactMap { a in
                          DepartmentRole(rawValue: a.role).map {
                              PersonSummary.Assignment(departmentName: a.name_ar, role: $0, isPrimary: a.is_primary)
                          }
                      })
    }
}

// MARK: - Reports (G4)

/// Report content values are text; numbers/booleans written by other clients are shown as text.
struct LooseTextDTO: Decodable, Sendable {
    let text: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { text = nil }
        else if let s = try? c.decode(String.self) { text = s }
        else if let d = try? c.decode(Decimal.self) { text = "\(d)" }
        else if let b = try? c.decode(Bool.self) { text = b ? "true" : "false" }
        else { text = nil }
    }
}

struct ReportRowDTO: Decodable, Sendable {
    let id: UUID
    let department_id: UUID
    let period_id: UUID
    let template_version_id: UUID
    let due_at: Date
    let status: String
    let first_submitted_at: Date?
    let waiver_reason: String?
    let latest_revision_id: UUID?
    let version: Int
    static let columns = "id,department_id,period_id,template_version_id,due_at,status,first_submitted_at,waiver_reason,latest_revision_id,version"

    func toDomain(departmentName: String, templateName: String, periodTitle: String) throws -> ReportItem {
        guard let status = ReportStatus(rawValue: status) else { throw AppError.decoding("unknown report status \(self.status)") }
        return ReportItem(id: id, departmentName: departmentName, templateName: templateName, periodTitle: periodTitle,
                          dueAt: due_at, firstSubmittedAt: first_submitted_at, status: status, waiverReason: waiver_reason,
                          departmentID: department_id, version: version)
    }
}

struct TemplateRowDTO: Decodable, Sendable {
    let id: UUID
    let name_ar: String
    static let columns = "id,name_ar"
}

struct TemplateVersionRowDTO: Decodable, Sendable {
    struct FieldDTO: Decodable, Sendable {
        let key: String
        let label: String?
        let required: Bool?
    }
    /// `{"fields":[…]}`; templates of another shape fall back to required_fields.
    struct FieldSchema: Decodable, Sendable {
        let fields: [FieldDTO]?
        enum CodingKeys: String, CodingKey { case fields }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fields = try? c.decodeIfPresent([FieldDTO].self, forKey: .fields)
        }
    }
    let id: UUID
    let template_id: UUID
    let field_schema: FieldSchema
    let required_fields: [String]
    static let columns = "id,template_id,field_schema,required_fields"

    var fields: [ReportField] {
        var result = (field_schema.fields ?? []).map {
            ReportField(key: $0.key, label: $0.label ?? $0.key, required: $0.required ?? required_fields.contains($0.key))
        }
        for key in required_fields where !result.contains(where: { $0.key == key }) {
            result.append(ReportField(key: key, label: key, required: true))
        }
        return result
    }
}

struct ReportRevisionRowDTO: Decodable, Sendable {
    let id: UUID
    let revision: Int
    let state: String
    let content: [String: LooseTextDTO]
    let version: Int
    let submitted_at: Date?
    static let columns = "id,revision,state,content,version,submitted_at"

    func toDomain() -> ReportRevision? {
        guard let state = ReportRevision.State(rawValue: state) else { return nil }
        return ReportRevision(id: id, revision: revision, state: state, content: content.compactMapValues(\.text),
                              version: version, submittedAt: submitted_at)
    }
}

struct ReportReviewRowDTO: Decodable, Sendable {
    let id: UUID
    let revision_id: UUID
    let reviewer_id: UUID
    let decision: String
    let note: String?
    let decided_at: Date
    static let columns = "id,revision_id,reviewer_id,decision,note,decided_at"

    func toDomain(reviewerName: String?) -> ReportReviewEntry {
        ReportReviewEntry(id: id, revisionID: revision_id, approved: decision == "approved", note: note,
                          decidedAt: decided_at, reviewerName: reviewerName)
    }
}

/// private.report_json
struct ReportJSONDTO: Decodable, Sendable {
    let report_id: UUID
    let status: String
    let version: Int
}

struct SavedDraftDTO: Decodable, Sendable {
    let revision_id: UUID
    let revision: Int
    let revision_version: Int
    let report: ReportJSONDTO
}

struct CreatedTemplateDTO: Decodable, Sendable {
    let template_id: UUID
    let template_version_id: UUID
}

struct ScheduledDTO: Decodable, Sendable { let scheduled: Int }
struct PeriodIDDTO: Decodable, Sendable { let period_id: UUID }
struct GeneratedDTO: Decodable, Sendable { let created: Int }

// MARK: - Indicators (G5)

struct IndicatorDefinitionRowDTO: Decodable, Sendable {
    let id: UUID
    let department_id: UUID
    let code: String
    let title: String
    let description: String
    static let columns = "id,department_id,code,title,description"

    var info: IndicatorDefinitionInfo {
        IndicatorDefinitionInfo(id: id, departmentID: department_id, code: code, title: title, description: description)
    }
}

struct IndicatorVersionRowDTO: Decodable, Sendable {
    let id: UUID
    let definition_id: UUID
    let revision: Int
    let measurement_type: String
    let unit: String
    let direction: String
    let aggregation: String
    let frequency: String
    let zero_event_rule: Bool
    let numerator_description: String?
    let denominator_description: String?
    let data_source: String
    let target: Decimal?
    let range_min: Decimal?
    let range_max: Decimal?
    let range_inclusive: Bool
    let weight: Decimal
    let valid_from: String
    let approved_at: Date?
    static let columns = "id,definition_id,revision,measurement_type,unit,direction,aggregation,frequency,zero_event_rule,numerator_description,denominator_description,data_source,target,range_min,range_max,range_inclusive,weight,valid_from,approved_at"

    func toDomain(_ backend: SupabaseBackend) -> IndicatorDefinitionVersion? {
        guard let type = MeasurementType(rawValue: measurement_type), let dir = ImprovementDirection(rawValue: direction),
              let agg = AggregationRule(rawValue: aggregation), let freq = PeriodType(rawValue: frequency),
              let from = backend.parseDate(valid_from) else { return nil }
        return IndicatorDefinitionVersion(
            id: id, definitionID: definition_id, revision: revision, measurementType: type, unit: unit, direction: dir,
            aggregation: agg, frequency: freq, zeroEventRule: zero_event_rule, numeratorDescription: numerator_description,
            denominatorDescription: denominator_description, dataSource: data_source, target: target, rangeMin: range_min,
            rangeMax: range_max, rangeInclusive: range_inclusive, weight: weight, validFrom: from, isApproved: approved_at != nil)
    }
}

struct MeasurementRowDTO: Decodable, Sendable {
    let id: UUID
    let definition_version_id: UUID
    let revision: Int
    let status: String
    let value: Decimal?
    let numerator: Decimal?
    let denominator: Decimal?
    let not_applicable_reason: String?
    let source_note: String?
    let entered_by: UUID
    let submitted_at: Date?
    let approved_at: Date?
    let version: Int
    /// Only selected by goal progress queries.
    var period_id: UUID? = nil
    static let columns = "id,definition_version_id,revision,status,value,numerator,denominator,not_applicable_reason,source_note,entered_by,submitted_at,approved_at,version"

    func toDomain() -> MeasurementRevision? {
        guard let status = MeasurementStatus(rawValue: status) else { return nil }
        return MeasurementRevision(id: id, revision: revision, status: status, value: value, numerator: numerator,
                                   denominator: denominator, notApplicableReason: not_applicable_reason, sourceNote: source_note,
                                   enteredBy: entered_by, submittedAt: submitted_at, approvedAt: approved_at, version: version)
    }
}

/// private.measurement_json
struct MeasurementJSONDTO: Decodable, Sendable {
    let measurement_id: UUID
    let status: String
    let version: Int
}

struct CreatedIndicatorDTO: Decodable, Sendable {
    let definition_id: UUID
    let definition_version_id: UUID
    let code: String
}
