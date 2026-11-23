import Foundation

/// Calculation rules from spec §11. Pure, deterministic, Decimal-based.
/// Missing data is never zero; incompatible values are never averaged.
enum ImprovementDirection: String, Sendable, Codable {
    case higherIsBetter = "higher_is_better"
    case lowerIsBetter = "lower_is_better"
    case withinRange = "within_range"
}

enum AggregationRule: String, Sendable, Codable {
    case sum
    case weightedMean = "weighted_mean"
    case ratioOfSums = "ratio_of_sums"
    case latest
}

struct IndicatorRule: Sendable, Equatable {
    var direction: ImprovementDirection
    var target: Decimal?
    var rangeMin: Decimal?
    var rangeMax: Decimal?
    var rangeInclusive: Bool = true
    /// Target 0 for events that must not happen: 0 events → 100, any → 0.
    var zeroEventRule: Bool = false
}

enum NotComputableReason: String, Sendable, Equatable {
    case zeroDenominator
    case invalidTarget
    case negativeValue
    case missingWeights
    case incompatibleUnits
    case notApplicable
}

enum ScoreOutcome: Sendable, Equatable {
    /// Normalized score 0...100.
    case score(Decimal)
    /// No reading entered for the period ("لم يُحدّث").
    case notUpdated
    case notComputable(NotComputableReason)
    /// within_range indicator outside its approved range (score 0, labelled).
    case outOfRange

    var value: Decimal? {
        switch self {
        case .score(let v): return v
        case .outOfRange: return 0
        default: return nil
        }
    }
}

/// A single period reading. `value` for counts/durations; numerator/denominator for ratios.
struct Reading: Sendable, Equatable {
    var value: Decimal?
    var numerator: Decimal?
    var denominator: Decimal?
    var notApplicableReason: String?

    static func value(_ v: Decimal?) -> Reading { Reading(value: v) }
    static func ratio(_ n: Decimal?, _ d: Decimal?) -> Reading { Reading(numerator: n, denominator: d) }
}

enum IndicatorScoring {
    static let hundred: Decimal = 100

    /// Actual value of a reading. Ratios are expressed as a percentage.
    static func actual(of reading: Reading, isRatio: Bool) -> Result<Decimal, ScoreOutcome> {
        if reading.notApplicableReason != nil { return .failure(.notComputable(.notApplicable)) }
        if isRatio {
            guard let n = reading.numerator, let d = reading.denominator else { return .failure(.notUpdated) }
            guard d > 0 else { return .failure(.notComputable(.zeroDenominator)) }
            guard n >= 0 else { return .failure(.notComputable(.negativeValue)) }
            return .success(n / d * hundred)
        }
        guard let v = reading.value else { return .failure(.notUpdated) }
        return .success(v)
    }

    static func score(_ reading: Reading, isRatio: Bool, rule: IndicatorRule) -> ScoreOutcome {
        switch actual(of: reading, isRatio: isRatio) {
        case .failure(let outcome): return outcome
        case .success(let actual): return score(actual: actual, rule: rule)
        }
    }

    static func score(actual: Decimal?, rule: IndicatorRule) -> ScoreOutcome {
        guard let actual else { return .notUpdated }
        switch rule.direction {
        case .higherIsBetter:
            guard let target = rule.target, target > 0 else { return .notComputable(.invalidTarget) }
            guard actual >= 0 else { return .notComputable(.negativeValue) }
            return .score(min(hundred, actual / target * hundred))
        case .lowerIsBetter:
            guard actual >= 0 else { return .notComputable(.negativeValue) }
            if rule.zeroEventRule {
                guard rule.target == 0 else { return .notComputable(.invalidTarget) }
                return .score(actual == 0 ? hundred : 0)
            }
            guard let target = rule.target, target > 0 else { return .notComputable(.invalidTarget) }
            if actual == 0 { return .score(hundred) }
            return .score(min(hundred, target / actual * hundred))
        case .withinRange:
            guard let lo = rule.rangeMin, let hi = rule.rangeMax, lo <= hi else { return .notComputable(.invalidTarget) }
            let inside = rule.rangeInclusive ? (actual >= lo && actual <= hi) : (actual > lo && actual < hi)
            return inside ? .score(hundred) : .outOfRange
        }
    }

    /// Aggregate several period readings into one (e.g. months → quarter).
    static func aggregate(_ readings: [Reading], rule: AggregationRule, weights: [Decimal]? = nil) -> Result<Reading, ScoreOutcome> {
        let usable = readings.filter { $0.notApplicableReason == nil }
        guard !usable.isEmpty else { return .failure(.notUpdated) }
        switch rule {
        case .ratioOfSums:
            // 90/100 and 1/2 → 91/102, never mean(90%, 50%).
            var n: Decimal = 0, d: Decimal = 0
            for r in usable {
                guard let rn = r.numerator, let rd = r.denominator else { return .failure(.notUpdated) }
                n += rn; d += rd
            }
            guard d > 0 else { return .failure(.notComputable(.zeroDenominator)) }
            return .success(.ratio(n, d))
        case .sum:
            var total: Decimal = 0
            for r in usable {
                guard let v = r.value else { return .failure(.notUpdated) }
                total += v
            }
            return .success(.value(total))
        case .latest:
            // Cumulative counters (e.g. year-to-date): last reading, never the sum.
            guard let v = usable.last?.value else { return .failure(.notUpdated) }
            return .success(.value(v))
        case .weightedMean:
            guard let weights, weights.count == readings.count else { return .failure(.notComputable(.missingWeights)) }
            var num: Decimal = 0, den: Decimal = 0
            for (r, w) in zip(readings, weights) where r.notApplicableReason == nil {
                guard let v = r.value else { return .failure(.notUpdated) }
                guard w > 0 else { return .failure(.notComputable(.missingWeights)) }
                num += v * w; den += w
            }
            guard den > 0 else { return .failure(.notComputable(.missingWeights)) }
            return .success(.value(num / den))
        }
    }

    /// Raw goal progress may exceed 100%; the aggregated score is capped.
    static func goalProgress(actual: Decimal, target: Decimal) -> (raw: Decimal, capped: Decimal)? {
        guard target > 0, actual >= 0 else { return nil }
        let raw = actual / target * hundred
        return (raw, min(hundred, raw))
    }

    /// Milestone goals: sum of weights of approved completed milestones (weights total 100).
    static func milestoneProgress(_ milestones: [(weight: Decimal, completedAndApproved: Bool)]) -> Decimal? {
        let total = milestones.reduce(Decimal(0)) { $0 + $1.weight }
        guard total == hundred else { return nil }
        return milestones.filter(\.completedAndApproved).reduce(Decimal(0)) { $0 + $1.weight }
    }
}

/// Department score with explicit coverage (spec §11).
struct CoverageResult: Sendable, Equatable {
    enum Verdict: Sendable, Equatable {
        /// < 80%: no overall verdict, no ranking.
        case insufficientData
        /// 80% ..< 100%: provisional verdict, clearly labelled.
        case provisional
        /// 100% coverage and closed period.
        case final
        /// 100% coverage but the period is still open.
        case completeButOpen
    }

    let measuredScore: Decimal?
    let coverage: Decimal
    let verdict: Verdict

    static let minimumCoverage: Decimal = 80

    static func compute(_ items: [(weight: Decimal, outcome: ScoreOutcome)], periodClosed: Bool) -> CoverageResult {
        let required = items.reduce(Decimal(0)) { $0 + $1.weight }
        guard required > 0 else { return CoverageResult(measuredScore: nil, coverage: 0, verdict: .insufficientData) }
        var covered: Decimal = 0, weighted: Decimal = 0
        for item in items {
            guard let v = item.outcome.value else { continue }
            covered += item.weight
            weighted += v * item.weight
        }
        let coverage = covered / required * IndicatorScoring.hundred
        let score: Decimal? = covered > 0 ? weighted / covered : nil
        let verdict: Verdict
        if coverage < minimumCoverage { verdict = .insufficientData }
        else if coverage < IndicatorScoring.hundred { verdict = .provisional }
        else { verdict = periodClosed ? .final : .completeButOpen }
        return CoverageResult(measuredScore: score, coverage: coverage, verdict: verdict)
    }
}

/// Allows `Result<_, ScoreOutcome>` for early exits in aggregation.
extension ScoreOutcome: Error {}
