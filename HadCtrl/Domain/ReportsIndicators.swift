import Foundation

// G4–G5 domain: recurring reports (§14–15) and indicator readings (§10–11).
// Pure types and rules; permissions here only decide which buttons to show.
// The server re-checks every action (D-02).

// MARK: - Reports

struct ReportField: Sendable, Hashable, Identifiable {
    let key: String
    let label: String
    let required: Bool
    var id: String { key }
}

struct ReportRevision: Sendable, Hashable, Identifiable {
    enum State: String, Sendable { case draft, submitted, returned, approved, superseded }
    let id: UUID
    let revision: Int
    let state: State
    let content: [String: String]
    let version: Int
    let submittedAt: Date?
}

struct ReportReviewEntry: Sendable, Hashable, Identifiable {
    let id: UUID
    let revisionID: UUID
    let approved: Bool
    let note: String?
    let decidedAt: Date
    let reviewerName: String?
}

enum ReportDecision: String, Sendable { case approved, returned }

struct ReportPermissions: Sendable, Equatable {
    var canEdit = false
    var canSubmit = false
    var canDecide = false
    var canWaive = false
}

struct ReportDetail: Sendable, Equatable {
    var report: ReportItem
    let departmentID: UUID
    let fields: [ReportField]
    /// Newest first.
    let revisions: [ReportRevision]
    let reviews: [ReportReviewEntry]
    let latestRevisionID: UUID?

    var openDraft: ReportRevision? { revisions.first { $0.state == .draft } }

    /// The revision the reviewer decides on (the latest submission).
    var latestSubmitted: ReportRevision? {
        if let id = latestRevisionID, let r = revisions.first(where: { $0.id == id }), r.state != .draft { return r }
        return revisions.first { $0.state != .draft }
    }

    /// Content to start editing from: the open draft, else the returned submission.
    var editableContent: [String: String] { openDraft?.content ?? latestSubmitted?.content ?? [:] }

    func missingRequired(in content: [String: String]) -> [String] {
        fields.filter { $0.required && (content[$0.key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.key)
    }

    /// Mirrors can_draft_report / can_submit_report / can_decide_report (D-07: no self-approval).
    /// Delegated reviewers are not known to the client; the server still lets them act.
    func permissions(for user: UserContext) -> ReportPermissions {
        let roles = user.departments.first { $0.id == departmentID }?.roles ?? []
        let isMember = !roles.isEmpty
        let editable = report.status == .notSubmitted || report.status == .returned
        var p = ReportPermissions()
        p.canEdit = isMember && editable
        p.canSubmit = roles.contains(.head) && editable
        p.canDecide = user.isDirector && !isMember && (report.status == .submitted || report.status == .underReview)
        p.canWaive = user.isDirector && report.status != .approved && report.status != .waived
        return p
    }
}

struct SavedDraft: Sendable, Equatable {
    let revisionID: UUID
    let revisionVersion: Int
    let reportVersion: Int
}

/// "New report template" form: fields get stable machine keys (f1, f2, …) because
/// labels are Arabic; the key never changes once a report uses it.
struct NewReportTemplateDraft: Sendable, Equatable {
    struct FieldDraft: Sendable, Equatable, Identifiable {
        var id = UUID()
        var label = ""
        var required = true
    }
    var nameAr = ""
    var frequency: PeriodType = .monthly
    var fields: [FieldDraft] = [FieldDraft(label: String(localized: "ملخص الإنجاز")),
                                FieldDraft(label: String(localized: "العوائق والاحتياجات"), required: false),
                                FieldDraft(label: String(localized: "خطة الفترة القادمة"))]
    var departmentIDs: Set<UUID> = []
    var dueDay = 5

    enum Field: String, Sendable { case nameAr = "name_ar", fields, departments = "department_ids", dueDay = "due_day" }

    var wireFields: [ReportField] {
        fields.enumerated().map { i, f in
            ReportField(key: "f\(i + 1)", label: f.label.trimmingCharacters(in: .whitespacesAndNewlines), required: f.required)
        }
    }

    func validate() -> [Field: String] {
        var e: [Field: String] = [:]
        if nameAr.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 { e[.nameAr] = String(localized: "اكتب اسم التقرير") }
        let labels = fields.map { $0.label.trimmingCharacters(in: .whitespacesAndNewlines) }
        if labels.isEmpty || labels.count > 30 { e[.fields] = String(localized: "من حقل واحد إلى ٣٠ حقلًا") }
        else if labels.contains(where: { $0.count < 2 }) { e[.fields] = String(localized: "اكتب عنوانًا لكل حقل") }
        if departmentIDs.isEmpty { e[.departments] = String(localized: "اختر قسمًا واحدًا على الأقل") }
        if !(1...28).contains(dueDay) { e[.dueDay] = String(localized: "يوم الاستحقاق من ١ إلى ٢٨") }
        return e
    }
}

// MARK: - Indicators

enum MeasurementType: String, Sendable, CaseIterable, Identifiable {
    case ratio, count, duration, milestones
    var id: String { rawValue }
}

enum MeasurementStatus: String, Sendable { case draft, submitted, returned, approved, superseded }

struct IndicatorDefinitionVersion: Sendable, Hashable, Identifiable {
    let id: UUID
    let definitionID: UUID
    let revision: Int
    let measurementType: MeasurementType
    let unit: String
    let direction: ImprovementDirection
    let aggregation: AggregationRule
    let frequency: PeriodType
    let zeroEventRule: Bool
    let numeratorDescription: String?
    let denominatorDescription: String?
    let dataSource: String
    let target: Decimal?
    let rangeMin: Decimal?
    let rangeMax: Decimal?
    let rangeInclusive: Bool
    let weight: Decimal
    let validFrom: Date
    let isApproved: Bool

    var rule: IndicatorRule {
        IndicatorRule(direction: direction, target: target, rangeMin: rangeMin, rangeMax: rangeMax,
                      rangeInclusive: rangeInclusive, zeroEventRule: zeroEventRule)
    }
    var isRatio: Bool { measurementType == .ratio }
}

struct IndicatorDefinitionInfo: Sendable, Hashable {
    let id: UUID
    let departmentID: UUID
    let code: String
    let title: String
    let description: String
}

struct MeasurementRevision: Sendable, Hashable, Identifiable {
    let id: UUID
    let revision: Int
    let status: MeasurementStatus
    let value: Decimal?
    let numerator: Decimal?
    let denominator: Decimal?
    let notApplicableReason: String?
    let sourceNote: String?
    let enteredBy: UUID
    let submittedAt: Date?
    let approvedAt: Date?
    let version: Int

    var reading: Reading {
        Reading(value: value, numerator: numerator, denominator: denominator, notApplicableReason: notApplicableReason)
    }
}

enum IndicatorMath {
    /// The approved version that applies to a period: the latest valid_from on or before its end (§10).
    static func applicableVersion(_ versions: [IndicatorDefinitionVersion], periodEnd: Date) -> IndicatorDefinitionVersion? {
        versions.filter { $0.isApproved && $0.validFrom <= periodEnd }.max { $0.validFrom < $1.validFrom }
    }

    /// Plain-language "how is it measured?" text (§10).
    static func howMeasured(_ def: IndicatorDefinitionInfo, _ v: IndicatorDefinitionVersion?) -> String {
        var parts: [String] = []
        if !def.description.isEmpty { parts.append(def.description) }
        if let v {
            if v.isRatio, let n = v.numeratorDescription, let d = v.denominatorDescription {
                parts.append(String(localized: "البسط: \(n). المقام: \(d)."))
            }
            parts.append(String(localized: "المصدر: \(v.dataSource)."))
        }
        return parts.joined(separator: " ")
    }

    /// Period summary from the approved reading only; a pending submission is shown
    /// as pending, never as a result (§10: receipt ≠ approval).
    static func summary(definition def: IndicatorDefinitionInfo, version: IndicatorDefinitionVersion?, departmentName: String,
                        measurements: [MeasurementRevision]) -> IndicatorSummary {
        let approved = measurements.first { $0.status == .approved }
        let latest = measurements.max { $0.revision < $1.revision }
        var actual: Decimal?
        let outcome: ScoreOutcome
        if let version, let approved {
            if case .success(let a) = IndicatorScoring.actual(of: approved.reading, isRatio: version.isRatio) { actual = a }
            outcome = IndicatorScoring.score(approved.reading, isRatio: version.isRatio, rule: version.rule)
        } else {
            outcome = .notUpdated
        }
        return IndicatorSummary(
            id: def.id, code: def.code, title: def.title, departmentName: departmentName,
            unit: version.map { $0.isRatio ? "٪" : $0.unit } ?? "",
            direction: version?.direction ?? .higherIsBetter, target: version?.target, actual: actual,
            outcome: ScoreOutcomeBox(outcome: outcome), weight: version?.weight ?? 1,
            howMeasured: howMeasured(def, version),
            definitionVersionID: version?.id, departmentID: def.departmentID,
            latestStatus: latest?.status, rangeMin: version?.rangeMin, rangeMax: version?.rangeMax)
    }
}

struct IndicatorPermissions: Sendable, Equatable {
    var canSubmit = false
    /// Replacing an approved value needs a correction reason (AC-020).
    var needsCorrectionReason = false
    var canDecide = false
}

struct IndicatorDetail: Sendable, Equatable {
    let definition: IndicatorDefinitionInfo
    let version: IndicatorDefinitionVersion?
    let period: ReportingPeriod
    /// Newest first.
    let measurements: [MeasurementRevision]
    let summary: IndicatorSummary

    var approved: MeasurementRevision? { measurements.first { $0.status == .approved } }
    var pending: MeasurementRevision? { measurements.first { $0.status == .submitted } }

    /// Mirrors submit_measurement / decide_measurement checks.
    func permissions(for user: UserContext) -> IndicatorPermissions {
        let roles = user.departments.first { $0.id == definition.departmentID }?.roles ?? []
        var p = IndicatorPermissions()
        let frozenWithoutApproved = period.state == .frozen && approved == nil
        p.canSubmit = roles.contains(.head) && version != nil && pending == nil && !frozenWithoutApproved
        p.needsCorrectionReason = approved != nil
        if let pending {
            p.canDecide = user.isDirector && roles.isEmpty && pending.enteredBy != user.userID
        }
        return p
    }
}

/// Reading entry form (§10): explicit "not applicable" instead of a silent zero.
struct MeasurementDraft: Sendable, Equatable {
    enum Mode: String, Sendable, CaseIterable, Identifiable { case value, notApplicable
        var id: String { rawValue } }
    var mode: Mode = .value
    var valueText = ""
    var numeratorText = ""
    var denominatorText = ""
    var notApplicableReason = ""
    var sourceNote = ""
    var correctionReason = ""

    enum Field: String, Sendable {
        case value, numerator, denominator
        case notApplicableReason = "not_applicable_reason"
        case correctionReason = "correction_reason"
    }

    /// Parsed reading, or field errors. Values are never coerced to zero.
    func parse(isRatio: Bool, needsCorrectionReason: Bool) -> Result<Reading, [Field: String]> {
        var e: [Field: String] = [:]
        var reading = Reading()
        let invalid = String(localized: "رقم غير صالح")
        switch mode {
        case .notApplicable:
            let reason = notApplicableReason.trimmingCharacters(in: .whitespacesAndNewlines)
            if reason.count < 3 { e[.notApplicableReason] = String(localized: "اذكر سبب عدم الانطباق") }
            reading.notApplicableReason = reason
        case .value where isRatio:
            let n = NumberInput.parseDecimal(numeratorText), d = NumberInput.parseDecimal(denominatorText)
            if n == nil { e[.numerator] = invalid } else if n! < 0 { e[.numerator] = String(localized: "لا يقبل قيمة سالبة") }
            if d == nil { e[.denominator] = invalid } else if d! < 0 { e[.denominator] = String(localized: "لا يقبل قيمة سالبة") }
            if let n, let d, d > 0, n > d { e[.numerator] = String(localized: "البسط أكبر من المقام") }
            reading.numerator = n; reading.denominator = d
        case .value:
            let v = NumberInput.parseDecimal(valueText)
            if v == nil { e[.value] = invalid } else if v! < 0 { e[.value] = String(localized: "لا يقبل قيمة سالبة") }
            reading.value = v
        }
        if needsCorrectionReason && correctionReason.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 {
            e[.correctionReason] = String(localized: "سبب التصحيح مطلوب لاستبدال قيمة معتمدة")
        }
        return e.isEmpty ? .success(reading) : .failure(e)
    }
}

/// "New indicator" form (§10–11). Mirrors the table's CHECK rules so the
/// director sees problems next to the field; the server re-checks.
struct NewIndicatorDraft: Sendable, Equatable {
    var departmentID: UUID?
    var code = ""
    var title = ""
    var description = ""
    var measurementType: MeasurementType = .count
    var unit = ""
    var direction: ImprovementDirection = .higherIsBetter
    /// For non-ratio indicators: sum per period, or latest reading for cumulative counters.
    var cumulative = false
    var targetText = ""
    var rangeMinText = ""
    var rangeMaxText = ""
    var zeroEventRule = false
    var numeratorDescription = ""
    var denominatorDescription = ""
    var dataSource = ""

    enum Field: String, Sendable {
        case department = "department_id", code, title, unit, target, range, numerator, denominator
        case dataSource = "data_source", definition
    }

    var aggregation: AggregationRule { measurementType == .ratio ? .ratioOfSums : (cumulative ? .latest : .sum) }
    var effectiveUnit: String { measurementType == .ratio ? "%" : unit.trimmingCharacters(in: .whitespacesAndNewlines) }
    var target: Decimal? { zeroEventRule ? 0 : NumberInput.parseDecimal(targetText) }

    func validate() -> [Field: String] {
        var e: [Field: String] = [:]
        if departmentID == nil { e[.department] = String(localized: "اختر القسم") }
        let c = code.trimmingCharacters(in: .whitespaces).uppercased()
        if c.range(of: "^[A-Z0-9][A-Z0-9_.-]{0,31}$", options: .regularExpression) == nil {
            e[.code] = String(localized: "رمز لاتيني مثل LAB.TAT")
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 { e[.title] = String(localized: "اكتب اسم المؤشر") }
        if effectiveUnit.isEmpty { e[.unit] = String(localized: "حدد وحدة القياس") }
        if dataSource.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 { e[.dataSource] = String(localized: "حدد مصدر البيانات") }
        if measurementType == .ratio {
            if numeratorDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { e[.numerator] = String(localized: "عرّف البسط") }
            if denominatorDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { e[.denominator] = String(localized: "عرّف المقام") }
        }
        switch direction {
        case .withinRange:
            let lo = NumberInput.parseDecimal(rangeMinText), hi = NumberInput.parseDecimal(rangeMaxText)
            if lo == nil || hi == nil || lo! > hi! { e[.range] = String(localized: "حدد نطاقًا صحيحًا (الأدنى ≤ الأعلى)") }
        case .higherIsBetter:
            if let t = target { if t <= 0 { e[.target] = String(localized: "المستهدف يجب أن يكون أكبر من صفر") } }
            else { e[.target] = String(localized: "حدد المستهدف") }
        case .lowerIsBetter:
            if !zeroEventRule {
                if let t = target { if t <= 0 { e[.target] = String(localized: "استخدم قاعدة «صفر أحداث» للمستهدف صفر") } }
                else { e[.target] = String(localized: "حدد المستهدف") }
            }
        }
        if zeroEventRule && direction != .lowerIsBetter { e[.target] = String(localized: "قاعدة صفر أحداث للمؤشرات «الأقل أفضل» فقط") }
        return e
    }
}
