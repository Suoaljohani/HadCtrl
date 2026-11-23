import Foundation
import Testing
@testable import HadCtrl

@Suite("Number input normalization (§10)")
struct NumberInputTests {
    @Test("Arabic-Indic, Persian and Latin digits with either decimal separator",
          arguments: [("٩٠٫٥", "90.5"), ("90.5", "90.5"), ("۱۲", "12"), ("12,5", "12.5"), ("-3", "-3"), ("٠", "0")])
    func parses(raw: String, expected: String) {
        #expect(NumberInput.parseDecimal(raw) == Decimal(string: expected, locale: Locale(identifier: "en_US_POSIX")))
    }

    @Test("ambiguous or non-numeric input is rejected, never zero",
          arguments: ["", "  ", "abc", "1.2.3", "1,234.5", "١٬٢٣٤", ".", "5.", "--1", "1-", "NaN", "inf"])
    func rejects(raw: String) {
        #expect(NumberInput.parseDecimal(raw) == nil)
    }
}

@Suite("Hospital calendar (§15)")
struct HospitalCalendarTests {
    let cal = HospitalCalendar.riyadh

    @Test("date-only deadline is 23:59:59 Riyadh = 20:59:59 UTC")
    func endOfDay() throws {
        let due = try #require(cal.endOfDay(year: 2026, month: 11, day: 30))
        #expect(due == ISO8601DateFormatter().date(from: "2026-11-30T20:59:59Z"))
    }

    @Test("non-existent day is rejected; day 31 clamps to month length")
    func shortMonths() {
        #expect(cal.endOfDay(year: 2026, month: 11, day: 31) == nil)
        #expect(cal.clampedDay(31, year: 2026, month: 2) == 28)
        #expect(cal.clampedDay(31, year: 2028, month: 2) == 29)
        #expect(cal.clampedDay(5, year: 2026, month: 12) == 5)
    }

    @Test("overdue uses submission, not approval time (AC-015)")
    func overdue() throws {
        let due = try #require(cal.endOfDay(year: 2026, month: 11, day: 5))
        let late = due.addingTimeInterval(3600)
        #expect(cal.isOverdue(dueAt: due, submittedAt: nil, now: late))
        #expect(!cal.isOverdue(dueAt: due, submittedAt: due.addingTimeInterval(-60), now: late))
        let report = ReportItem(id: UUID(), departmentName: "", templateName: "", periodTitle: "", dueAt: due,
                                firstSubmittedAt: due.addingTimeInterval(-60), status: .approved, waiverReason: nil)
        #expect(report.submittedOnTime == true)
    }
}

@Suite("Arabic search normalization (§17)")
struct ArabicSearchTests {
    @Test("alef/yaa/taa marbuta variants and harakat match")
    func normalize() {
        #expect(ArabicSearch.normalize("الإدارة") == ArabicSearch.normalize("الاداره"))
        #expect(ArabicSearch.normalize("مُستشفى") == ArabicSearch.normalize("مستشفي"))
        #expect(ArabicSearch.normalize("المـختبر") == "المختبر")
    }
}

@Suite("Routes (§04)")
struct RouteTests {
    @Test("deep link parses id only; role hints ignored")
    func deepLink() {
        let id = UUID()
        #expect(AppRoute(url: URL(string: "hadctrl://task/\(id.uuidString)?role=hospital_director")!) == .task(id))
        #expect(AppRoute(url: URL(string: "hadctrl://task/not-a-uuid")!) == nil)
        #expect(AppRoute(url: URL(string: "https://task/\(id.uuidString)")!) == nil)
    }
}

@Suite("Backend configuration (§22)")
struct ConfigurationTests {
    @Test("error codes round-trip and classify retryability")
    func errorCodes() {
        #expect(HCErrorCode(rawValue: "HC_VERSION_CONFLICT") == .versionConflict)
        #expect(AppError.network(offline: true).isRetryable)
        #expect(!AppError.server(code: .forbidden, fieldErrors: [:], currentVersion: nil, correlationID: nil).isRetryable)
        #expect(AppError.server(code: .authRequired, fieldErrors: [:], currentVersion: nil, correlationID: nil).requiresSignIn)
    }
}
