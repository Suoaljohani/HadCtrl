import Foundation

// Goals (spec §09, §11, AC-010). Progress comes from the measuring indicator's
// approved readings, or from approved milestones — never from completed tasks.
// Raw achievement may exceed 100%; the aggregate score is capped (§09).

enum GoalLifecycle: String, Sendable, CaseIterable {
    case draft, active
    case completionPending = "completion_pending"
    case completed, cancelled, archived
}

enum GoalDecision: String, Sendable {
    case activate, `return`, complete
    case rejectCompletion = "reject_completion"
    case cancel
    var needsNote: Bool { self == .return || self == .rejectCompletion || self == .cancel }
}

struct PlanPoint: Sendable, Hashable {
    let at: Date
    let expected: Decimal
}

struct GoalMilestone: Sendable, Hashable, Identifiable {
    let id: UUID
    let ordinal: Int
    let title: String
    let criterion: String
    let weight: Decimal
    let completedAt: Date?
    let approved: Bool
}

struct GoalProgress: Sendable, Hashable {
    enum Track: Sendable, Hashable { case onTrack, behind, noData, notStarted }
    /// Actual achieved value (count/ratio/duration in the goal unit; milestones: approved weight).
    let actual: Decimal?
    let target: Decimal?
    /// What the approved plan expects by `asOf` (nil without a plan).
    let expectedToDate: Decimal?
    /// actual ÷ target × 100, uncapped, and the capped value used in aggregates.
    let raw: Decimal?
    let capped: Decimal?
    let track: Track

    static let none = GoalProgress(actual: nil, target: nil, expectedToDate: nil, raw: nil, capped: nil, track: .noData)
}

struct GoalSummary: Sendable, Hashable, Identifiable {
    let id: UUID
    let departmentID: UUID
    let departmentName: String
    let title: String
    let lifecycle: GoalLifecycle
    let measurementType: MeasurementType
    let unit: String
    let startAt: Date
    let dueAt: Date
    let version: Int
    let progress: GoalProgress
}

struct GoalIndicatorLink: Sendable, Hashable, Identifiable {
    let id: UUID          // indicator definition id
    let title: String
    let measuresOutcome: Bool
}

struct GoalPermissions: Sendable, Equatable {
    var canActivate = false, canReturn = false, canCancel = false
    var canRequestCompletion = false, canDecideCompletion = false
    var canCompleteMilestone = false, canApproveMilestone = false
}

struct GoalDetail: Sendable, Equatable {
    let summary: GoalSummary
    let description: String
    let ownerName: String?
    let priority: Priority
    let baseline: Decimal?
    let plan: [PlanPoint]
    let planIsLinear: Bool
    let milestones: [GoalMilestone]
    let indicators: [GoalIndicatorLink]
    let cancelReason: String?
    let versionApproved: Bool

    func permissions(for user: UserContext) -> GoalPermissions {
        let roles = user.departments.first { $0.id == summary.departmentID }?.roles ?? []
        let director = user.isDirector
        let lc = summary.lifecycle
        var p = GoalPermissions()
        p.canActivate = director && lc == .draft
        p.canReturn = director && lc == .draft
        p.canCancel = director && [.draft, .active, .completionPending].contains(lc)
        p.canRequestCompletion = roles.contains(.head) && lc == .active
        p.canDecideCompletion = director && lc == .completionPending
        let running = lc == .active || lc == .completionPending
        p.canCompleteMilestone = roles.contains(.head) && running
        p.canApproveMilestone = director && roles.isEmpty && running
        return p
    }
}

enum GoalMath {
    /// Expected value at a date: the latest plan point on or before it; with an
    /// approved linear plan, linear from baseline (or 0) at start to target at due.
    static func expected(at date: Date, plan: [PlanPoint], linear: Bool, baseline: Decimal?, target: Decimal?,
                         start: Date, due: Date) -> Decimal? {
        if linear, let target {
            if date <= start { return baseline ?? 0 }
            if date >= due { return target }
            let b = baseline ?? 0
            let fraction = Decimal(date.timeIntervalSince(start) / due.timeIntervalSince(start))
            return b + (target - b) * fraction
        }
        guard let first = plan.sorted(by: { $0.at < $1.at }).last(where: { $0.at <= date }) else {
            return plan.isEmpty ? nil : 0
        }
        return first.expected
    }

    static func progress(type: MeasurementType, target: Decimal?, actual: Decimal?, expected: Decimal?,
                         started: Bool) -> GoalProgress {
        guard started else {
            return GoalProgress(actual: actual, target: target, expectedToDate: expected, raw: nil, capped: nil, track: .notStarted)
        }
        guard let actual else {
            return GoalProgress(actual: nil, target: target, expectedToDate: expected, raw: nil, capped: nil, track: .noData)
        }
        var raw: Decimal?, capped: Decimal?
        if let target, let p = IndicatorScoring.goalProgress(actual: actual, target: target) { raw = p.raw; capped = p.capped }
        let track: GoalProgress.Track
        if let expected { track = actual >= expected ? .onTrack : .behind } else { track = .noData }
        return GoalProgress(actual: actual, target: target, expectedToDate: expected, raw: raw, capped: capped, track: track)
    }

    /// Approved weight of milestones (§11: only approved, completed milestones count).
    static func milestoneActual(_ milestones: [GoalMilestone]) -> Decimal? {
        IndicatorScoring.milestoneProgress(milestones.map { ($0.weight, $0.completedAt != nil && $0.approved) })
    }

    /// Actual from the measuring indicator's approved readings inside the goal window,
    /// aggregated by the indicator's rule (ratio of sums for ratios; never a mean of ratios).
    static func indicatorActual(readings: [Reading], rule: AggregationRule, isRatio: Bool) -> Decimal? {
        guard !readings.isEmpty, case .success(let r) = IndicatorScoring.aggregate(readings, rule: rule),
              case .success(let a) = IndicatorScoring.actual(of: r, isRatio: isRatio) else { return nil }
        return a
    }
}

/// "New goal" form (§09). The server re-checks every rule.
struct NewGoalDraft: Sendable, Equatable {
    struct PlanRow: Sendable, Equatable, Identifiable { var id = UUID(); var at = Date(); var expectedText = "" }
    struct MilestoneRow: Sendable, Equatable, Identifiable { var id = UUID(); var title = ""; var criterion = ""; var weightText = "" }

    var departmentID: UUID?
    var title = ""
    var description = ""
    var measurementType: MeasurementType = .count
    var unit = ""
    var priority: Priority = .normal
    var startDate = Date()
    var dueDate = Date().addingTimeInterval(180 * 86_400)
    var baselineText = ""
    var targetText = ""
    var plan: [PlanRow] = []
    var planIsLinear = false
    var milestones: [MilestoneRow] = [MilestoneRow(), MilestoneRow()]
    var measuringIndicatorIDs: Set<UUID> = []

    enum Field: String, Sendable { case department = "department_id", title, unit, target, dueDate = "due_date", plan, milestones }

    var effectiveUnit: String {
        switch measurementType {
        case .milestones: return String(localized: "مرحلة")
        case .ratio: return "%"
        default: return unit.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func validate(calendar: HospitalCalendar = .riyadh) -> [Field: String] {
        var e: [Field: String] = [:]
        if departmentID == nil { e[.department] = String(localized: "اختر القسم") }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).count < 3 { e[.title] = String(localized: "اكتب عنوان الهدف") }
        if effectiveUnit.isEmpty { e[.unit] = String(localized: "حدد الوحدة") }
        let start = calendar.calendar.startOfDay(for: startDate), due = calendar.calendar.startOfDay(for: dueDate)
        if due <= start { e[.dueDate] = String(localized: "تاريخ النهاية بعد البداية") }
        if measurementType == .milestones {
            let weights = milestones.map { NumberInput.parseDecimal($0.weightText) }
            if milestones.isEmpty || milestones.contains(where: { $0.title.trimmingCharacters(in: .whitespaces).count < 2
                || $0.criterion.trimmingCharacters(in: .whitespaces).count < 3 }) || weights.contains(where: { ($0 ?? 0) <= 0 }) {
                e[.milestones] = String(localized: "لكل مرحلة عنوان ومعيار إنجاز ووزن")
            } else if weights.compactMap({ $0 }).reduce(0, +) != 100 {
                e[.milestones] = String(localized: "مجموع الأوزان يجب أن يساوي ١٠٠")
            }
        } else if let t = NumberInput.parseDecimal(targetText), t > 0 {
            // ok
        } else {
            e[.target] = String(localized: "حدد قيمة مستهدفة أكبر من صفر — لا يوجد «١٠٠٪» افتراضي")
        }
        var last: (Date, Decimal)?
        for row in plan.sorted(by: { $0.at < $1.at }) {
            let d = calendar.calendar.startOfDay(for: row.at)
            guard let v = NumberInput.parseDecimal(row.expectedText), v >= 0, d >= start, d <= due else {
                e[.plan] = String(localized: "نقاط الخطة داخل مدة الهدف وبقيم صحيحة"); break
            }
            if let last, (d <= last.0 || v < last.1) { e[.plan] = String(localized: "الخطة تتزايد مع الوقت"); break }
            last = (d, v)
        }
        return e
    }
}
