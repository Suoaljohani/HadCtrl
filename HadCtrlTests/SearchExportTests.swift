import Foundation
import PDFKit
import Testing
@testable import HadCtrl

@Suite("Search and export", .serialized)
@MainActor
struct SearchExportTests {
    typealias F = MockStore.Fixture
    let clock = FixedClock(date: ISO8601DateFormatter().date(from: "2026-11-20T09:00:00Z")!)

    private func repos() -> MockRepositories {
        MockRepositories(store: MockStore(clock: clock), clock: clock, demoUser: F.director)
    }

    private func search(_ r: MockRepositories) -> CompositeSearchRepository {
        CompositeSearchRepository(departments: r.departments, tasks: r.tasks, goals: r.goals, reports: r.reports,
                                  achievements: r.achievements, indicators: r.indicators, clock: clock)
    }

    // MARK: Search

    @Test("§17: hamza/alef variants match — «اجراءات» finds «إجراءات»")
    func normalizedMatch() async throws {
        let results = try await search(repos()).search("اجراءات", periodID: nil, routePeriodID: F.november)
        let tasks = results.hits[.tasks] ?? []
        #expect(tasks.contains { $0.title.contains("إجراءات") })
        #expect(tasks.allSatisfy { $0.route != nil })
    }

    @Test("results come grouped by kind in a fixed order and open the shared routes")
    func grouped() async throws {
        let results = try await search(repos()).search("المختبر", periodID: nil, routePeriodID: F.november)
        #expect(results.groups.first?.category == .departments)
        #expect(results.hits[.departments]?.first?.route == .department(F.lab))
    }

    @Test("queries shorter than two characters do not search")
    func minimumLength() {
        #expect(SearchQuery.usable("م") == nil)
        #expect(SearchQuery.usable("  مه ") == "مه")
    }

    @Test("only the latest query updates the results")
    func latestWins() async throws {
        let model = SearchModel(repository: search(repos()), periodID: { F.november }, debounce: .milliseconds(10))
        model.query = "التدريب"
        model.query = "العينات"
        try await Task.sleep(for: .milliseconds(50))
        await model.waitForIdle()
        let titles = (model.state.value?.hits[.tasks] ?? []).map(\.title)
        #expect(titles.allSatisfy { $0.contains("العينات") })
    }

    // MARK: CSV

    @Test("§19: CSV guards free text against formulas but keeps negative numbers")
    func csvFormulaGuard() {
        #expect(CSVWriter.cell("=SUM(A1:A9)", numeric: false) == "'=SUM(A1:A9)")
        #expect(CSVWriter.cell("@cmd", numeric: false) == "'@cmd")
        #expect(CSVWriter.cell("-5", numeric: true) == "-5")
        #expect(CSVWriter.cell("-5", numeric: false) == "'-5")
    }

    @Test("§19: CSV quotes commas, quotes and line breaks")
    func csvQuoting() {
        #expect(CSVWriter.cell("أ، ب, ج", numeric: false) == "\"أ، ب, ج\"")
        #expect(CSVWriter.cell("قال \"نعم\"", numeric: false) == "\"قال \"\"نعم\"\"\"")
        #expect(CSVWriter.cell("سطر\nثانٍ", numeric: false) == "\"سطر\nثانٍ\"")
    }

    // MARK: Export document

    private func document(_ r: MockRepositories, department: UUID? = nil) async throws -> ExportDocument {
        let snapshot = try await r.dashboard.snapshot(periodID: F.november)
        let indicators = try await r.indicators.indicators(periodID: F.november)
        let reports = try await r.reports.reports(periodID: F.november)
        return ExportBuilder.build(organization: "مستشفى تجريبي", periodTitle: "نوفمبر ٢٠٢٦", snapshot: snapshot,
                                   indicators: indicators, reports: reports, departmentID: department,
                                   departmentName: department == nil ? nil : "المختبر", now: clock.now(),
                                   style: NumberStyle(digits: .arabicIndic))
    }

    @Test("§19: unapproved data is labelled draft, never as final")
    func draftLabel() async throws {
        let doc = try await document(repos())
        #expect(doc.isFinal == false)
        #expect(doc.statusNote.contains("مسودة"))
        let csv = String(decoding: CSVWriter.data(doc).dropFirst(3), as: UTF8.self)
        #expect(csv.contains("مسودة"))
        #expect(CSVWriter.data(doc).prefix(3) == Data([0xEF, 0xBB, 0xBF]), "UTF-8 BOM for spreadsheets")
    }

    @Test("a department export contains only that department's rows")
    func departmentScope() async throws {
        let doc = try await document(repos(), department: F.lab)
        let deptColumn = String(localized: "القسم")
        for table in doc.tables where table.columns.contains(deptColumn) {
            let col = table.columns.firstIndex(of: deptColumn)!
            #expect(table.rows.allSatisfy { $0[col] == "المختبر" })
        }
        #expect(doc.scope.contains("المختبر"))
    }

    @Test("§19: the PDF is paginated real text with a footer on every page")
    func pdfPagination() async throws {
        let base = try await document(repos())
        let many = ExportTable(title: "جدول طويل", columns: ["أ", "ب", "ج"], numericColumns: [2],
                               rows: (1...160).map { ["صف \($0)", "قيمة نصية أطول قليلًا", "\($0)"] })
        let doc = ExportDocument(title: base.title, organization: base.organization, periodTitle: base.periodTitle,
                                 scope: base.scope, generatedAt: base.generatedAt, isFinal: base.isFinal,
                                 statusNote: base.statusNote, summary: base.summary, tables: base.tables + [many])
        let data = PDFExporter.data(doc, rightToLeft: true)
        #expect(data.prefix(4) == Data("%PDF".utf8))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount >= 3)
        for i in 0..<pdf.pageCount {
            #expect(pdf.page(at: i)?.string?.contains("HadCtrl") == true, "footer on page \(i + 1)")
        }
    }
}
