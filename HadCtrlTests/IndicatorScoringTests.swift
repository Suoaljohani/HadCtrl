import Foundation
import Testing
@testable import HadCtrl

/// Reference cases from spec §11 and AC-005..AC-010.
@Suite("Indicator scoring (§11)")
struct IndicatorScoringTests {
    private func approx(_ outcome: ScoreOutcome, _ expected: Decimal, tolerance: Decimal = 0.0001) -> Bool {
        guard case .score(let v) = outcome else { return false }
        return abs(v - expected) <= tolerance
    }

    @Test("higher-is-better ratio: 90 vs 95 ≈ 94.7368")
    func higherIsBetter() {
        let outcome = IndicatorScoring.score(actual: 90, rule: IndicatorRule(direction: .higherIsBetter, target: 95))
        #expect(approx(outcome, Decimal(string: "94.7368")!))
    }

    @Test("lower-is-better duration: 12h vs 10h ≈ 83.3333 (AC-008)")
    func lowerIsBetter() {
        let outcome = IndicatorScoring.score(actual: 12, rule: IndicatorRule(direction: .lowerIsBetter, target: 10))
        #expect(approx(outcome, Decimal(string: "83.3333")!))
    }

    @Test("lower-is-better actual 0 with positive target scores 100")
    func lowerIsBetterZeroActual() {
        #expect(IndicatorScoring.score(actual: 0, rule: IndicatorRule(direction: .lowerIsBetter, target: 10)) == .score(100))
    }

    @Test("missing reading is 'not updated', never zero (AC-005)")
    func nullIsNotZero() {
        let rule = IndicatorRule(direction: .higherIsBetter, target: 95)
        #expect(IndicatorScoring.score(actual: nil, rule: rule) == .notUpdated)
        #expect(IndicatorScoring.score(actual: 0, rule: rule) == .score(0))
        #expect(IndicatorScoring.score(.ratio(nil, 10), isRatio: true, rule: rule) == .notUpdated)
    }

    @Test("zero denominator is not computable, no NaN (AC-006)")
    func zeroDenominator() {
        let rule = IndicatorRule(direction: .higherIsBetter, target: 95)
        #expect(IndicatorScoring.score(.ratio(0, 0), isRatio: true, rule: rule) == .notComputable(.zeroDenominator))
    }

    @Test("zero-event rule: 0 → 100, 1 → 0", arguments: [(Decimal(0), Decimal(100)), (Decimal(1), Decimal(0)), (Decimal(3), Decimal(0))])
    func zeroEvent(actual: Decimal, expected: Decimal) {
        let rule = IndicatorRule(direction: .lowerIsBetter, target: 0, zeroEventRule: true)
        #expect(IndicatorScoring.score(actual: actual, rule: rule) == .score(expected))
    }

    @Test("target 0 for higher-is-better is rejected")
    func invalidTarget() {
        #expect(IndicatorScoring.score(actual: 5, rule: IndicatorRule(direction: .higherIsBetter, target: 0)) == .notComputable(.invalidTarget))
    }

    @Test("within range: inclusive bounds score 100, outside is labelled")
    func withinRange() {
        let rule = IndicatorRule(direction: .withinRange, target: nil, rangeMin: 2, rangeMax: 4, rangeInclusive: true)
        #expect(IndicatorScoring.score(actual: 2, rule: rule) == .score(100))
        #expect(IndicatorScoring.score(actual: 4, rule: rule) == .score(100))
        #expect(IndicatorScoring.score(actual: 4.5, rule: rule) == .outOfRange)
        let exclusive = IndicatorRule(direction: .withinRange, target: nil, rangeMin: 2, rangeMax: 4, rangeInclusive: false)
        #expect(IndicatorScoring.score(actual: 4, rule: exclusive) == .outOfRange)
    }

    @Test("count goal over target: raw 150%, capped 100")
    func overTarget() {
        let progress = IndicatorScoring.goalProgress(actual: 15, target: 10)
        #expect(progress?.raw == 150)
        #expect(progress?.capped == 100)
    }

    @Test("milestones: weights must total 100; only approved completions count")
    func milestones() {
        #expect(IndicatorScoring.milestoneProgress([(30, true), (30, false), (40, true)]) == 70)
        #expect(IndicatorScoring.milestoneProgress([(30, true), (30, false)]) == nil)
    }
}

@Suite("Aggregation across periods (§11)")
struct AggregationTests {
    @Test("ratio of sums: 90/100 + 1/2 = 91/102, not mean of ratios (AC-007)")
    func ratioOfSums() throws {
        let result = try IndicatorScoring.aggregate([.ratio(90, 100), .ratio(1, 2)], rule: .ratioOfSums).get()
        #expect(result.numerator == 91)
        #expect(result.denominator == 102)
        let pct = try IndicatorScoring.actual(of: result, isRatio: true).get()
        #expect(abs(pct - Decimal(string: "89.2157")!) < 0.001)
        #expect(abs(pct - 70) > 1) // the wrong answer
    }

    @Test("cumulative counter uses latest reading, not 3+6+9")
    func latest() throws {
        let result = try IndicatorScoring.aggregate([.value(3), .value(6), .value(9)], rule: .latest).get()
        #expect(result.value == 9)
    }

    @Test("independent counts sum")
    func sum() throws {
        #expect(try IndicatorScoring.aggregate([.value(3), .value(4)], rule: .sum).get().value == 7)
    }

    @Test("weighted mean requires weights")
    func weightedMean() {
        if case .failure(.notComputable(.missingWeights)) = IndicatorScoring.aggregate([.value(1)], rule: .weightedMean) {} else {
            Issue.record("expected missingWeights")
        }
    }

    @Test("a missing month makes the aggregate 'not updated'")
    func missingMonth() {
        if case .failure(.notUpdated) = IndicatorScoring.aggregate([.ratio(90, 100), .ratio(nil, nil)], rule: .ratioOfSums) {} else {
            Issue.record("expected notUpdated")
        }
    }
}

@Suite("Coverage and verdict (§11, AC-009)")
struct CoverageTests {
    @Test("60% coverage: score shown as measured, no overall verdict")
    func insufficient() {
        let r = CoverageResult.compute([(3, .score(100)), (2, .notUpdated)], periodClosed: true)
        #expect(r.coverage == 60)
        #expect(r.verdict == .insufficientData)
    }

    @Test("80–99% coverage is provisional")
    func provisional() {
        let r = CoverageResult.compute([(4, .score(50)), (1, .notUpdated)], periodClosed: true)
        #expect(r.coverage == 80)
        #expect(r.verdict == .provisional)
        #expect(r.measuredScore == 50)
    }

    @Test("full coverage is final only for a closed period")
    func final() {
        #expect(CoverageResult.compute([(1, .score(90))], periodClosed: true).verdict == .final)
        #expect(CoverageResult.compute([(1, .score(90))], periodClosed: false).verdict == .completeButOpen)
    }

    @Test("out-of-range counts as covered with score 0")
    func outOfRangeCovered() {
        let r = CoverageResult.compute([(1, .outOfRange), (1, .score(100))], periodClosed: true)
        #expect(r.coverage == 100)
        #expect(r.measuredScore == 50)
    }
}
