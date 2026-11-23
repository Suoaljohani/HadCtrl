import Foundation
import Supabase

// G4–G5 Supabase repositories: reports and indicators. Reads are RLS-scoped
// SELECTs; every write is an RPC with membership, version and request_id
// checks on the server (docs/API_CONTRACTS.md API-06…API-09, D-29).

private func notFound() -> AppError { .server(code: .notFound, fieldErrors: [:], currentVersion: nil, correlationID: nil) }

extension SupabaseBackend {
    func period(id: UUID) async throws -> ReportingPeriod {
        let rows: [PeriodRowDTO] = try await call {
            try await client.from("reporting_periods").select(PeriodRowDTO.columns).eq("id", value: id).limit(1).execute().value
        }
        guard let row = rows.first, let p = row.toDomain(self) else { throw notFound() }
        return p
    }

    func organizationID() async throws -> UUID {
        guard let id = await cache.context?.organizationID else {
            throw AppError.server(code: .authRequired, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        return id
    }
}

extension PeriodRowDTO {
    func toDomain(_ backend: SupabaseBackend) -> ReportingPeriod? {
        guard let type = PeriodType(rawValue: type), let state = ReportingPeriod.State(rawValue: state),
              let start = backend.parseDate(start_date), let end = backend.parseDate(end_date) else { return nil }
        return ReportingPeriod(id: id, type: type, start: start, end: end, state: state,
                               title: PeriodTitle.make(type: type, start: start, end: end, calendar: backend.calendar))
    }
}

// MARK: - Reports

struct SupabaseReportsRepository: ReportsRepository {
    let backend: SupabaseBackend

    func reports(periodID: UUID) async throws -> [ReportItem] {
        let rows: [ReportRowDTO] = try await backend.call {
            try await backend.client.from("report_instances").select(ReportRowDTO.columns)
                .eq("period_id", value: periodID).order("due_at").order("id").limit(200).execute().value
        }
        let period = try? await backend.period(id: periodID)
        let names = try await templateNames(Set(rows.map(\.template_version_id)))
        let departments = try await backend.departmentsByID()
        return try rows.map { try $0.toDomain(departmentName: departments[$0.department_id]?.nameAr ?? "—",
                                              templateName: names[$0.template_version_id]?.name ?? "—",
                                              periodTitle: period?.title ?? "") }
    }

    func report(id: UUID) async throws -> ReportDetail {
        let rows: [ReportRowDTO] = try await backend.call {
            try await backend.client.from("report_instances").select(ReportRowDTO.columns).eq("id", value: id).limit(1).execute().value
        }
        guard let row = rows.first else { throw notFound() }   // invisible == missing (HC-120)
        let template = try await templateNames([row.template_version_id])[row.template_version_id]
        let revisions: [ReportRevisionRowDTO] = try await backend.call {
            try await backend.client.from("report_revisions").select(ReportRevisionRowDTO.columns)
                .eq("report_id", value: id).order("revision", ascending: false).execute().value
        }
        var reviews: [ReportReviewRowDTO] = []
        if !revisions.isEmpty {
            reviews = try await backend.call {
                try await backend.client.from("report_reviews").select(ReportReviewRowDTO.columns)
                    .in("revision_id", values: revisions.map(\.id.uuidString))
                    .order("decided_at", ascending: false).execute().value
            }
        }
        let reviewers = try await backend.displayNames(Set(reviews.map(\.reviewer_id)))
        let period = try? await backend.period(id: row.period_id)
        let departments = try await backend.departmentsByID()
        let item = try row.toDomain(departmentName: departments[row.department_id]?.nameAr ?? "—",
                                    templateName: template?.name ?? "—", periodTitle: period?.title ?? "")
        return ReportDetail(report: item, departmentID: row.department_id, fields: template?.fields ?? [],
                            revisions: revisions.compactMap { $0.toDomain() },
                            reviews: reviews.map { $0.toDomain(reviewerName: reviewers[$0.reviewer_id]) },
                            latestRevisionID: row.latest_revision_id)
    }

    func saveDraft(reportID: UUID, content: [String: String], expectedRevisionVersion: Int?, requestID: UUID) async throws -> SavedDraft {
        struct Params: Encodable, Sendable {
            let p_report_id: UUID, p_content: [String: String], p_request_id: UUID, p_expected_revision_version: Int?
        }
        let dto: SavedDraftDTO = try await backend.call {
            try await backend.client.rpc("save_report_draft", params: Params(
                p_report_id: reportID, p_content: content, p_request_id: requestID,
                p_expected_revision_version: expectedRevisionVersion)).execute().value
        }
        return SavedDraft(revisionID: dto.revision_id, revisionVersion: dto.revision_version, reportVersion: dto.report.version)
    }

    func submit(reportID: UUID, draftRevisionID: UUID, expectedVersion: Int, requestID: UUID) async throws {
        struct Params: Encodable, Sendable {
            let p_report_id: UUID, p_draft_revision_id: UUID, p_expected_version: Int, p_request_id: UUID
        }
        let _: ReportJSONDTO = try await backend.call {
            try await backend.client.rpc("submit_report", params: Params(
                p_report_id: reportID, p_draft_revision_id: draftRevisionID, p_expected_version: expectedVersion,
                p_request_id: requestID)).execute().value
        }
    }

    func decide(reportID: UUID, revisionID: UUID, decision: ReportDecision, expectedVersion: Int, note: String?, requestID: UUID) async throws {
        struct Params: Encodable, Sendable {
            let p_report_id: UUID, p_revision_id: UUID, p_decision: String, p_expected_version: Int, p_request_id: UUID
            let p_note: String?
        }
        let _: ReportJSONDTO = try await backend.call {
            try await backend.client.rpc("decide_report", params: Params(
                p_report_id: reportID, p_revision_id: revisionID, p_decision: decision.rawValue,
                p_expected_version: expectedVersion, p_request_id: requestID, p_note: note)).execute().value
        }
    }

    func waive(reportID: UUID, reason: String, expectedVersion: Int, requestID: UUID) async throws {
        struct Params: Encodable, Sendable {
            let p_report_id: UUID, p_reason: String, p_expected_version: Int, p_request_id: UUID
        }
        let _: ReportJSONDTO = try await backend.call {
            try await backend.client.rpc("waive_report", params: Params(
                p_report_id: reportID, p_reason: reason, p_expected_version: expectedVersion,
                p_request_id: requestID)).execute().value
        }
    }

    func createTemplate(_ draft: NewReportTemplateDraft, requestID: UUID) async throws -> UUID {
        struct FieldParam: Encodable, Sendable { let key: String, label: String, required: Bool }
        struct Params: Encodable, Sendable {
            let p_organization_id: UUID, p_name_ar: String, p_frequency: String, p_fields: [FieldParam], p_request_id: UUID
        }
        let org = try await backend.organizationID()
        let params = Params(p_organization_id: org, p_name_ar: draft.nameAr.trimmingCharacters(in: .whitespacesAndNewlines),
                            p_frequency: draft.frequency.rawValue,
                            p_fields: draft.wireFields.map { FieldParam(key: $0.key, label: $0.label, required: $0.required) },
                            p_request_id: requestID)
        let dto: CreatedTemplateDTO = try await backend.call {
            try await backend.client.rpc("create_report_template", params: params).execute().value
        }
        return dto.template_id
    }

    func schedule(templateID: UUID, departmentIDs: [UUID], dueDay: Int, requestID: UUID) async throws -> Int {
        struct Params: Encodable, Sendable {
            let p_template_id: UUID, p_department_ids: [UUID], p_due_day: Int, p_request_id: UUID
        }
        let dto: ScheduledDTO = try await backend.call {
            try await backend.client.rpc("schedule_report", params: Params(
                p_template_id: templateID, p_department_ids: departmentIDs, p_due_day: dueDay,
                p_request_id: requestID)).execute().value
        }
        return dto.scheduled
    }

    func ensureCurrentPeriod() async throws -> UUID {
        struct Params: Encodable, Sendable { let p_organization_id: UUID }
        let org = try await backend.organizationID()
        let dto: PeriodIDDTO = try await backend.call {
            try await backend.client.rpc("ensure_current_period", params: Params(p_organization_id: org)).execute().value
        }
        return dto.period_id
    }

    func generateReports(periodID: UUID) async throws -> Int {
        struct Params: Encodable, Sendable { let p_period_id: UUID }
        let dto: GeneratedDTO = try await backend.call {
            try await backend.client.rpc("generate_reports_for_period", params: Params(p_period_id: periodID)).execute().value
        }
        return dto.created
    }

    private struct TemplateInfo: Sendable { let name: String; let fields: [ReportField] }

    private func templateNames(_ versionIDs: Set<UUID>) async throws -> [UUID: TemplateInfo] {
        guard !versionIDs.isEmpty else { return [:] }
        let versions: [TemplateVersionRowDTO] = try await backend.call {
            try await backend.client.from("report_template_versions").select(TemplateVersionRowDTO.columns)
                .in("id", values: versionIDs.map(\.uuidString)).execute().value
        }
        let templates: [TemplateRowDTO] = try await backend.call {
            try await backend.client.from("report_templates").select(TemplateRowDTO.columns)
                .in("id", values: Set(versions.map(\.template_id)).map(\.uuidString)).execute().value
        }
        let names = Dictionary(templates.map { ($0.id, $0.name_ar) }, uniquingKeysWith: { a, _ in a })
        return Dictionary(versions.map { v in (v.id, TemplateInfo(name: names[v.template_id] ?? "—", fields: v.fields)) },
                          uniquingKeysWith: { a, _ in a })
    }
}

// MARK: - Indicators

struct SupabaseIndicatorsRepository: IndicatorsRepository {
    let backend: SupabaseBackend

    func indicators(periodID: UUID) async throws -> [IndicatorSummary] {
        let period = try await backend.period(id: periodID)
        let defs: [IndicatorDefinitionRowDTO] = try await backend.call {
            try await backend.client.from("indicator_definitions").select(IndicatorDefinitionRowDTO.columns)
                .eq("active", value: true).order("code").limit(200).execute().value
        }
        guard !defs.isEmpty else { return [] }
        let versions = try await versions(definitionIDs: defs.map(\.id))
        let applicable = Dictionary(grouping: versions, by: \.definitionID)
            .compactMapValues { IndicatorMath.applicableVersion($0, periodEnd: period.end) }
        let measurements = try await measurements(versionIDs: applicable.values.map(\.id), periodID: periodID)
        let departments = try await backend.departmentsByID()
        return defs.map { d in
            let info = d.info
            let v = applicable[d.id]
            return IndicatorMath.summary(definition: info, version: v,
                                         departmentName: departments[d.department_id]?.nameAr ?? "—",
                                         measurements: v.map { measurements[$0.id] ?? [] } ?? [])
        }
    }

    func indicator(definitionID: UUID, periodID: UUID) async throws -> IndicatorDetail {
        let defs: [IndicatorDefinitionRowDTO] = try await backend.call {
            try await backend.client.from("indicator_definitions").select(IndicatorDefinitionRowDTO.columns)
                .eq("id", value: definitionID).limit(1).execute().value
        }
        guard let def = defs.first else { throw notFound() }
        let period = try await backend.period(id: periodID)
        let allVersions = try await versions(definitionIDs: [def.id])
        let version = IndicatorMath.applicableVersion(allVersions, periodEnd: period.end)
        var history: [MeasurementRevision] = []
        if let version { history = try await measurements(versionIDs: [version.id], periodID: periodID)[version.id] ?? [] }
        let departments = try await backend.departmentsByID()
        let summary = IndicatorMath.summary(definition: def.info, version: version,
                                            departmentName: departments[def.department_id]?.nameAr ?? "—",
                                            measurements: history)
        return IndicatorDetail(definition: def.info, version: version, period: period,
                               measurements: history.sorted { $0.revision > $1.revision }, summary: summary)
    }

    func submitMeasurement(definitionVersionID: UUID, periodID: UUID, reading: Reading, sourceNote: String?,
                           correctionReason: String?, requestID: UUID) async throws {
        struct Params: Encodable, Sendable {
            let p_definition_version_id: UUID, p_period_id: UUID, p_request_id: UUID
            let p_value: Decimal?, p_numerator: Decimal?, p_denominator: Decimal?
            let p_not_applicable_reason: String?, p_source_note: String?, p_correction_reason: String?
        }
        let params = Params(p_definition_version_id: definitionVersionID, p_period_id: periodID, p_request_id: requestID,
                            p_value: reading.value, p_numerator: reading.numerator, p_denominator: reading.denominator,
                            p_not_applicable_reason: reading.notApplicableReason, p_source_note: sourceNote.nonEmpty,
                            p_correction_reason: correctionReason.nonEmpty)
        let _: MeasurementJSONDTO = try await backend.call {
            try await backend.client.rpc("submit_measurement", params: params).execute().value
        }
    }

    func decideMeasurement(measurementID: UUID, approve: Bool, expectedVersion: Int, note: String?, requestID: UUID) async throws {
        struct Params: Encodable, Sendable {
            let p_measurement_id: UUID, p_decision: String, p_expected_version: Int, p_request_id: UUID, p_note: String?
        }
        let _: MeasurementJSONDTO = try await backend.call {
            try await backend.client.rpc("decide_measurement", params: Params(
                p_measurement_id: measurementID, p_decision: approve ? "approved" : "returned",
                p_expected_version: expectedVersion, p_request_id: requestID, p_note: note.nonEmpty)).execute().value
        }
    }

    func createIndicator(_ draft: NewIndicatorDraft, requestID: UUID) async throws -> UUID {
        struct Params: Encodable, Sendable {
            let p_organization_id: UUID, p_department_id: UUID, p_code: String, p_title: String
            let p_measurement_type: String, p_unit: String, p_direction: String, p_aggregation: String
            let p_frequency: String, p_data_source: String, p_request_id: UUID
            let p_target: Decimal?, p_range_min: Decimal?, p_range_max: Decimal?
            let p_numerator_description: String?, p_denominator_description: String?
            let p_zero_event_rule: Bool, p_description: String
        }
        guard let dept = draft.departmentID else {
            throw AppError.server(code: .validationFailed, fieldErrors: ["department_id": "required"], currentVersion: nil, correlationID: nil)
        }
        let org = try await backend.organizationID()
        let within = draft.direction == .withinRange
        let ratio = draft.measurementType == .ratio
        let params = Params(
            p_organization_id: org, p_department_id: dept, p_code: draft.code.trimmingCharacters(in: .whitespaces).uppercased(),
            p_title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines), p_measurement_type: draft.measurementType.rawValue,
            p_unit: draft.effectiveUnit, p_direction: draft.direction.rawValue, p_aggregation: draft.aggregation.rawValue,
            p_frequency: PeriodType.monthly.rawValue, p_data_source: draft.dataSource.trimmingCharacters(in: .whitespacesAndNewlines),
            p_request_id: requestID, p_target: within ? nil : draft.target,
            p_range_min: within ? NumberInput.parseDecimal(draft.rangeMinText) : nil,
            p_range_max: within ? NumberInput.parseDecimal(draft.rangeMaxText) : nil,
            p_numerator_description: ratio ? draft.numeratorDescription.nonEmpty : nil,
            p_denominator_description: ratio ? draft.denominatorDescription.nonEmpty : nil,
            p_zero_event_rule: draft.zeroEventRule, p_description: draft.description.trimmingCharacters(in: .whitespacesAndNewlines))
        let dto: CreatedIndicatorDTO = try await backend.call {
            try await backend.client.rpc("create_indicator", params: params).execute().value
        }
        return dto.definition_id
    }

    private func versions(definitionIDs: [UUID]) async throws -> [IndicatorDefinitionVersion] {
        let rows: [IndicatorVersionRowDTO] = try await backend.call {
            try await backend.client.from("indicator_definition_versions").select(IndicatorVersionRowDTO.columns)
                .in("definition_id", values: definitionIDs.map(\.uuidString)).execute().value
        }
        return rows.compactMap { $0.toDomain(backend) }
    }

    private func measurements(versionIDs: [UUID], periodID: UUID) async throws -> [UUID: [MeasurementRevision]] {
        guard !versionIDs.isEmpty else { return [:] }
        let rows: [MeasurementRowDTO] = try await backend.call {
            try await backend.client.from("indicator_measurements").select(MeasurementRowDTO.columns)
                .eq("period_id", value: periodID).in("definition_version_id", values: versionIDs.map(\.uuidString))
                .order("revision", ascending: false).execute().value
        }
        return Dictionary(grouping: rows, by: \.definition_version_id).mapValues { $0.compactMap { $0.toDomain() } }
    }
}

extension Optional where Wrapped == String {
    /// Trimmed text, or nil when empty (optional RPC parameters are then omitted).
    var nonEmpty: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

extension String {
    var nonEmpty: String? { Optional(self).nonEmpty }
}
