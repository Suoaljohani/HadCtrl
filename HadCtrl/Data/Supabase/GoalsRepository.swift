import Foundation
import Supabase

// Goals over RLS reads + the 001600 RPCs (§09). Progress is computed from the
// measuring indicator's approved readings inside the goal window, or from
// approved milestones (GoalMath), never from tasks (AC-010).

struct GoalRowDTO: Decodable, Sendable {
    let id: UUID
    let department_id: UUID
    let owner_id: UUID
    let title: String
    let description: String
    let lifecycle: String
    let priority: String
    let start_at: Date
    let due_at: Date
    let measurement_type: String
    let current_version_id: UUID?
    let cancel_reason: String?
    let version: Int
    static let columns = "id,department_id,owner_id,title,description,lifecycle,priority,start_at,due_at,measurement_type,current_version_id,cancel_reason,version"
}

struct GoalVersionRowDTO: Decodable, Sendable {
    struct Point: Decodable, Sendable { let at: String; let expected: Decimal }
    let id: UUID
    let goal_id: UUID
    let unit: String
    let baseline: Decimal?
    let target_value: Decimal?
    let progress_plan: [Point]
    let plan_is_linear: Bool
    let approved_at: Date?
    static let columns = "id,goal_id,unit,baseline,target_value,progress_plan,plan_is_linear,approved_at"
}

struct GoalMilestoneRowDTO: Decodable, Sendable {
    let id: UUID
    let goal_version_id: UUID
    let ordinal: Int
    let title: String
    let completion_criterion: String
    let weight: Decimal
    let completed_at: Date?
    let approved_by: UUID?
    static let columns = "id,goal_version_id,ordinal,title,completion_criterion,weight,completed_at,approved_by"

    var domain: GoalMilestone {
        GoalMilestone(id: id, ordinal: ordinal, title: title, criterion: completion_criterion, weight: weight,
                      completedAt: completed_at, approved: approved_by != nil)
    }
}

private struct GoalJSONDTO: Decodable, Sendable { let goal_id: UUID; let lifecycle: String; let version: Int }

struct SupabaseGoalsRepository: GoalsRepository {
    let backend: SupabaseBackend

    private struct LinkRow: Decodable, Sendable { let goal_id: UUID; let indicator_definition_id: UUID; let relation_type: String }
    private struct DefRow: Decodable, Sendable { let id: UUID; let title: String }
    private struct PeriodRow: Decodable, Sendable { let id: UUID; let start_date: String; let end_date: String }

    func goals(departmentID: UUID?, asOf: Date) async throws -> [GoalSummary] {
        let rows: [GoalRowDTO] = try await backend.call {
            var q = backend.client.from("goals").select(GoalRowDTO.columns).neq("lifecycle", value: "archived")
            if let departmentID { q = q.eq("department_id", value: departmentID) }
            return try await q.order("due_at").order("id").limit(200).execute().value
        }
        return try await summaries(rows, asOf: asOf).map(\.summary)
    }

    func goal(id: UUID, asOf: Date) async throws -> GoalDetail {
        let rows: [GoalRowDTO] = try await backend.call {
            try await backend.client.from("goals").select(GoalRowDTO.columns).eq("id", value: id).limit(1).execute().value
        }
        guard let built = try await summaries(rows, asOf: asOf).first else {
            throw AppError.server(code: .notFound, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        return built
    }

    /// Loads versions, milestones, links and readings for a batch of goals.
    private func summaries(_ rows: [GoalRowDTO], asOf: Date) async throws -> [GoalDetail] {
        guard !rows.isEmpty else { return [] }
        let versionIDs = rows.compactMap(\.current_version_id).map(\.uuidString)
        let goalIDs = rows.map(\.id.uuidString)
        var versions: [GoalVersionRowDTO] = []
        var milestones: [GoalMilestoneRowDTO] = []
        if !versionIDs.isEmpty {
            versions = try await backend.call {
                try await backend.client.from("goal_versions").select(GoalVersionRowDTO.columns).in("id", values: versionIDs).execute().value
            }
            milestones = try await backend.call {
                try await backend.client.from("goal_milestones").select(GoalMilestoneRowDTO.columns)
                    .in("goal_version_id", values: versionIDs).order("ordinal").execute().value
            }
        }
        let links: [LinkRow] = try await backend.call {
            try await backend.client.from("goal_indicator_links").select("goal_id,indicator_definition_id,relation_type")
                .in("goal_id", values: goalIDs).execute().value
        }
        let defIDs = Set(links.map(\.indicator_definition_id))
        var defs: [DefRow] = []
        if !defIDs.isEmpty {
            defs = try await backend.call {
                try await backend.client.from("indicator_definitions").select("id,title").in("id", values: defIDs.map(\.uuidString))
                    .execute().value
            }
        }
        // Approved readings of the measuring indicators, per definition, with their period start.
        let measuring = Set(links.filter { $0.relation_type == "measures_outcome" }.map(\.indicator_definition_id))
        var readings: [UUID: (rule: AggregationRule, isRatio: Bool, items: [(start: Date, end: Date, reading: Reading)])] = [:]
        if !measuring.isEmpty {
            let indicatorVersions: [IndicatorVersionRowDTO] = try await backend.call {
                try await backend.client.from("indicator_definition_versions").select(IndicatorVersionRowDTO.columns)
                    .in("definition_id", values: measuring.map(\.uuidString)).execute().value
            }
            let domainVersions = indicatorVersions.compactMap { $0.toDomain(backend) }
            let versionByID = Dictionary(uniqueKeysWithValues: domainVersions.map { ($0.id, $0) })
            var measurements: [MeasurementRowDTO] = []
            if !domainVersions.isEmpty {
                measurements = try await backend.call {
                    try await backend.client.from("indicator_measurements").select(MeasurementRowDTO.columns + ",period_id")
                        .in("definition_version_id", values: domainVersions.map(\.id.uuidString)).eq("status", value: "approved")
                        .execute().value
                }
            }
            let periodByMeasurement = Dictionary(uniqueKeysWithValues: measurements.compactMap { m in m.period_id.map { (m.id, $0) } })
            let periodIDs = Set(periodByMeasurement.values)
            var periods: [PeriodRow] = []
            if !periodIDs.isEmpty {
                periods = try await backend.call {
                    try await backend.client.from("reporting_periods").select("id,start_date,end_date")
                        .in("id", values: periodIDs.map(\.uuidString)).execute().value
                }
            }
            let periodDates = Dictionary(uniqueKeysWithValues: periods.compactMap { p -> (UUID, (Date, Date))? in
                guard let s = backend.parseDate(p.start_date), let e = backend.parseDate(p.end_date) else { return nil }
                return (p.id, (s, e))
            })
            for m in measurements {
                guard let v = versionByID[m.definition_version_id], let pid = periodByMeasurement[m.id],
                      let dates = periodDates[pid], let rev = m.toDomain() else { continue }
                var entry = readings[v.definitionID] ?? (v.aggregation, v.isRatio, [])
                entry.items.append((dates.0, dates.1, rev.reading))
                readings[v.definitionID] = entry
            }
        }

        let versionByGoal = Dictionary(versions.map { ($0.goal_id, $0) }, uniquingKeysWith: { a, _ in a })
        let milestonesByVersion = Dictionary(grouping: milestones, by: \.goal_version_id)
        let defTitles = Dictionary(uniqueKeysWithValues: defs.map { ($0.id, $0.title) })
        let departments = try await backend.departmentsByID()
        let owners = try await backend.displayNames(Set(rows.map(\.owner_id)))

        return rows.compactMap { row in
            guard let lifecycle = GoalLifecycle(rawValue: row.lifecycle), let type = MeasurementType(rawValue: row.measurement_type)
            else { return nil }
            let v = versionByGoal[row.id]
            let ms = (v.flatMap { milestonesByVersion[$0.id] } ?? []).map(\.domain)
            let plan = (v?.progress_plan ?? []).compactMap { p in backend.parseDate(p.at).map { PlanPoint(at: $0, expected: p.expected) } }
            let goalLinks = links.filter { $0.goal_id == row.id }
            let actual: Decimal?
            if type == .milestones {
                actual = GoalMath.milestoneActual(ms)
            } else if let defID = goalLinks.first(where: { $0.relation_type == "measures_outcome" })?.indicator_definition_id,
                      let entry = readings[defID] {
                let inWindow = entry.items.filter { $0.end >= row.start_at && $0.start <= row.due_at && $0.start <= asOf }
                    .sorted { $0.start < $1.start }.map(\.reading)
                actual = GoalMath.indicatorActual(readings: inWindow, rule: entry.rule, isRatio: entry.isRatio)
            } else {
                actual = nil
            }
            let target = type == .milestones ? 100 : v?.target_value
            let expected = GoalMath.expected(at: asOf, plan: plan, linear: v?.plan_is_linear ?? false, baseline: v?.baseline,
                                             target: target, start: row.start_at, due: row.due_at)
            let progress = GoalMath.progress(type: type, target: target, actual: actual, expected: expected,
                                             started: asOf >= row.start_at)
            let summary = GoalSummary(id: row.id, departmentID: row.department_id,
                                      departmentName: departments[row.department_id]?.nameAr ?? "—", title: row.title,
                                      lifecycle: lifecycle, measurementType: type,
                                      unit: type == .ratio ? "٪" : (v?.unit ?? ""), startAt: row.start_at, dueAt: row.due_at,
                                      version: row.version, progress: progress)
            return GoalDetail(summary: summary, description: row.description, ownerName: owners[row.owner_id],
                              priority: Priority(rawValue: row.priority) ?? .normal, baseline: v?.baseline, plan: plan,
                              planIsLinear: v?.plan_is_linear ?? false, milestones: ms,
                              indicators: goalLinks.map { GoalIndicatorLink(id: $0.indicator_definition_id,
                                                                            title: defTitles[$0.indicator_definition_id] ?? "—",
                                                                            measuresOutcome: $0.relation_type == "measures_outcome") },
                              cancelReason: row.cancel_reason, versionApproved: v?.approved_at != nil)
        }
    }

    func create(_ draft: NewGoalDraft, requestID: UUID) async throws -> UUID {
        struct PlanParam: Encodable, Sendable { let at: String; let expected: Decimal }
        struct MilestoneParam: Encodable, Sendable { let title: String; let criterion: String; let weight: Decimal }
        struct LinkParam: Encodable, Sendable { let definition_id: UUID; let relation: String }
        struct Params: Encodable, Sendable {
            let p_department_id: UUID, p_title: String, p_measurement_type: String, p_unit: String
            let p_start_date: String, p_due_date: String, p_request_id: UUID
            let p_description: String, p_priority: String, p_baseline: Decimal?, p_target: Decimal?
            let p_plan: [PlanParam], p_plan_is_linear: Bool, p_milestones: [MilestoneParam], p_indicators: [LinkParam]
        }
        guard let dept = draft.departmentID else {
            throw AppError.server(code: .validationFailed, fieldErrors: ["department_id": "required"], currentVersion: nil, correlationID: nil)
        }
        let isMilestones = draft.measurementType == .milestones
        let params = Params(
            p_department_id: dept, p_title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines),
            p_measurement_type: draft.measurementType.rawValue, p_unit: draft.effectiveUnit,
            p_start_date: backend.dateString(draft.startDate), p_due_date: backend.dateString(draft.dueDate),
            p_request_id: requestID, p_description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines),
            p_priority: draft.priority.rawValue, p_baseline: NumberInput.parseDecimal(draft.baselineText),
            p_target: isMilestones ? nil : NumberInput.parseDecimal(draft.targetText),
            p_plan: isMilestones ? [] : draft.plan.sorted { $0.at < $1.at }.compactMap { row in
                NumberInput.parseDecimal(row.expectedText).map { PlanParam(at: backend.dateString(row.at), expected: $0) }
            },
            p_plan_is_linear: draft.planIsLinear,
            p_milestones: isMilestones ? draft.milestones.compactMap { m in
                NumberInput.parseDecimal(m.weightText).map {
                    MilestoneParam(title: m.title.trimmingCharacters(in: .whitespaces), criterion: m.criterion.trimmingCharacters(in: .whitespaces), weight: $0)
                }
            } : [],
            p_indicators: draft.measuringIndicatorIDs.sorted { $0.uuidString < $1.uuidString }
                .map { LinkParam(definition_id: $0, relation: "measures_outcome") })
        let dto: GoalJSONDTO = try await backend.call {
            try await backend.client.rpc("create_goal", params: params).execute().value
        }
        return dto.goal_id
    }

    func decide(id: UUID, decision: GoalDecision, expectedVersion: Int, note: String?, requestID: UUID) async throws {
        struct Params: Encodable, Sendable {
            let p_goal_id: UUID, p_decision: String, p_expected_version: Int, p_request_id: UUID, p_note: String?
        }
        let _: GoalJSONDTO = try await backend.call {
            try await backend.client.rpc("decide_goal", params: Params(
                p_goal_id: id, p_decision: decision.rawValue, p_expected_version: expectedVersion, p_request_id: requestID,
                p_note: note.nonEmpty)).execute().value
        }
    }

    func requestCompletion(id: UUID, expectedVersion: Int, note: String?, requestID: UUID) async throws {
        struct Params: Encodable, Sendable { let p_goal_id: UUID, p_expected_version: Int, p_request_id: UUID, p_note: String? }
        let _: GoalJSONDTO = try await backend.call {
            try await backend.client.rpc("request_goal_completion", params: Params(
                p_goal_id: id, p_expected_version: expectedVersion, p_request_id: requestID, p_note: note.nonEmpty)).execute().value
        }
    }

    func setMilestone(id: UUID, approve: Bool, requestID: UUID) async throws {
        struct Params: Encodable, Sendable { let p_milestone_id: UUID, p_action: String, p_request_id: UUID }
        let _: GoalJSONDTO = try await backend.call {
            try await backend.client.rpc("set_milestone", params: Params(
                p_milestone_id: id, p_action: approve ? "approve" : "complete", p_request_id: requestID)).execute().value
        }
    }
}
