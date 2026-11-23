import Foundation
import Testing
@testable import HadCtrl

@Suite("Reports and indicators (G4–G5)", .serialized)
@MainActor
struct ReportsIndicatorsTests {
    typealias F = MockStore.Fixture
    let clock = FixedClock(date: ISO8601DateFormatter().date(from: "2026-11-23T09:00:00Z")!)
    static let labReport = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    static let trainingReport = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    static let labDoc = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    static let labRejections = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!

    private func repos(_ user: UUID, store: MockStore? = nil) -> (MockRepositories, MockStore) {
        let s = store ?? MockStore(clock: clock)
        return (MockRepositories(store: s, clock: clock, demoUser: user), s)
    }

    // MARK: reports

    @Test("template draft: stable machine keys, required flags, validation")
    func templateDraft() {
        var d = NewReportTemplateDraft()
        d.nameAr = "التقرير الشهري"
        #expect(d.validate()[.departments] != nil, "at least one department")
        d.departmentIDs = [F.lab]
        #expect(d.validate().isEmpty)
        #expect(d.wireFields.map(\.key) == ["f1", "f2", "f3"])
        #expect(d.wireFields.map(\.required) == [true, false, true])
        d.dueDay = 31
        #expect(d.validate()[.dueDay] != nil)
        d.dueDay = 5
        d.fields.append(.init(label: " "))
        #expect(d.validate()[.fields] != nil, "every field needs a label")
    }

    @Test("permissions: the department edits and submits; the director decides only on submissions and never as a member")
    func reportPermissions() async throws {
        let (head, _) = repos(F.headLab)
        let lab = try await head.reports.report(id: Self.labReport)
        let headPerms = lab.permissions(for: MockDirectory.context(for: F.headLab))
        #expect(headPerms.canEdit && headPerms.canSubmit && !headPerms.canDecide && !headPerms.canWaive)

        let (director, _) = repos(F.director)
        let directorCtx = MockDirectory.context(for: F.director)
        let notSubmitted = try await director.reports.report(id: Self.labReport).permissions(for: directorCtx)
        #expect(!notSubmitted.canEdit && !notSubmitted.canDecide && notSubmitted.canWaive)
        let submitted = try await director.reports.report(id: Self.trainingReport).permissions(for: directorCtx)
        #expect(submitted.canDecide)
    }

    @Test("submit checks required fields locally, then saves the draft and submits; first submission time is kept")
    func headSubmitsReport() async throws {
        let (head, _) = repos(F.headLab)
        let model = ReportDetailViewModel(reportID: Self.labReport, repository: head.reports)
        await model.load()
        await model.submit()
        #expect(Set(model.fieldErrors.keys) == ["f1", "f3"], "missing required fields block the submission")
        #expect(model.state.value?.report.status == .notSubmitted)

        model.content = ["f1": "أُنجز التوثيق", "f3": "مراجعة الإجراءات"]
        await model.submit()
        let detail = try #require(model.state.value)
        #expect(model.actionError == nil)
        #expect(detail.report.status == .submitted)
        let first = try #require(detail.report.firstSubmittedAt)
        #expect(detail.latestSubmitted?.content["f1"] == "أُنجز التوثيق")
        #expect(!detail.permissions(for: MockDirectory.context(for: F.headLab)).canEdit, "a submission is frozen")
        #expect(first == clock.now())
    }

    @Test("a retried draft save with the same request id does not create a second revision")
    func draftIdempotency() async throws {
        let (head, _) = repos(F.headLab)
        let request = UUID()
        let a = try await head.reports.saveDraft(reportID: Self.labReport, content: ["f1": "x"], expectedRevisionVersion: nil, requestID: request)
        let b = try await head.reports.saveDraft(reportID: Self.labReport, content: ["f1": "x"], expectedRevisionVersion: nil, requestID: request)
        #expect(a.revisionID == b.revisionID)
        #expect(try await head.reports.report(id: Self.labReport).revisions.count == 1)
        await #expect(throws: AppError.self) {
            _ = try await head.reports.saveDraft(reportID: Self.labReport, content: ["f1": "other"], expectedRevisionVersion: nil,
                                                 requestID: request)
        }
    }

    @Test("director approves a submitted report; returning needs a note")
    func directorDecides() async throws {
        let (director, _) = repos(F.director)
        let detail = try await director.reports.report(id: Self.trainingReport)
        let revision = try #require(detail.latestSubmitted)
        do {
            try await director.reports.decide(reportID: detail.report.id, revisionID: revision.id, decision: .returned,
                                              expectedVersion: detail.report.version, note: nil, requestID: UUID())
            Issue.record("return without a note must fail")
        } catch let e as AppError { #expect(e.code == .validationFailed) }

        let model = ReportDetailViewModel(reportID: Self.trainingReport, repository: director.reports)
        await model.load()
        await model.decide(.approved, note: nil)
        #expect(model.state.value?.report.status == .approved)
        #expect(model.state.value?.reviews.first?.approved == true)
    }

    @Test("a stale version is rejected and the screen reloads the newer record")
    func staleDecision() async throws {
        let (director, _) = repos(F.director)
        let detail = try await director.reports.report(id: Self.trainingReport)
        let revision = try #require(detail.latestSubmitted)
        do {
            try await director.reports.decide(reportID: detail.report.id, revisionID: revision.id, decision: .approved,
                                              expectedVersion: detail.report.version - 1, note: nil, requestID: UUID())
            Issue.record("stale version must fail")
        } catch let e as AppError { #expect(e.code == .versionConflict) }
    }

    @Test("template → schedule → generate creates one report per department, once")
    func scheduleAndGenerate() async throws {
        let (director, _) = repos(F.director)
        var d = NewReportTemplateDraft()
        d.nameAr = "تقرير السلامة"
        d.departmentIDs = [F.lab, F.training]
        let model = NewReportTemplateViewModel(reports: director.reports)
        model.draft = d
        #expect(await model.save() == 2)
        let before = try await director.reports.reports(periodID: F.november).count
        #expect(try await director.reports.generateReports(periodID: F.november) == 2)
        #expect(try await director.reports.generateReports(periodID: F.november) == 0, "generation is idempotent")
        #expect(try await director.reports.reports(periodID: F.november).count == before + 2)

        let (head, _) = repos(F.headLab)
        await #expect(throws: AppError.self) { _ = try await head.reports.createTemplate(d, requestID: UUID()) }
    }

    // MARK: indicators

    private func errors(_ d: MeasurementDraft, ratio: Bool, correction: Bool = false) -> [MeasurementDraft.Field: String] {
        if case .failure(let e) = d.parse(isRatio: ratio, needsCorrectionReason: correction) { return e.fields }
        return [:]
    }

    private func reading(_ d: MeasurementDraft, ratio: Bool) -> Reading? {
        if case .success(let r) = d.parse(isRatio: ratio, needsCorrectionReason: false) { return r }
        return nil
    }

    @Test("reading entry: empty is not zero, ratio sanity, explicit not-applicable, correction reason")
    func measurementDraft() {
        var d = MeasurementDraft()
        #expect(errors(d, ratio: false)[.value] != nil, "an empty value is an error, never a silent zero")
        d.valueText = "٠"
        #expect(reading(d, ratio: false)?.value == 0, "an explicit Arabic-Indic zero is a real reading")
        #expect(errors(d, ratio: false, correction: true)[.correctionReason] != nil)

        var ratio = MeasurementDraft(numeratorText: "11", denominatorText: "10")
        #expect(errors(ratio, ratio: true)[.numerator] != nil, "numerator larger than denominator")
        ratio.numeratorText = "9"
        #expect(reading(ratio, ratio: true)?.denominator == 10)

        var na = MeasurementDraft(mode: .notApplicable)
        #expect(errors(na, ratio: true)[.notApplicableReason] != nil)
        na.notApplicableReason = "القسم مغلق للصيانة"
        let r = reading(na, ratio: true)
        #expect(r?.numerator == nil && r?.notApplicableReason != nil)
    }

    @Test("indicator definition rules mirror §11 checks")
    func indicatorDraft() {
        var d = NewIndicatorDraft(departmentID: F.lab, code: "lab.x", title: "مؤشر تجريبي", unit: "عدد", targetText: "0", dataSource: "سجل")
        #expect(d.validate()[.target] != nil, "target 0 for higher-is-better is rejected")
        d.targetText = "5"
        #expect(d.validate().isEmpty)
        #expect(d.aggregation == .sum)
        d.cumulative = true
        #expect(d.aggregation == .latest)
        d.measurementType = .ratio
        #expect(d.validate()[.numerator] != nil && d.validate()[.denominator] != nil)
        #expect(d.aggregation == .ratioOfSums, "ratios aggregate as sum of numerators over sum of denominators")
        #expect(d.effectiveUnit == "%")
        var z = NewIndicatorDraft(departmentID: F.lab, code: "LAB.Z", title: "أحداث سلبية", unit: "حدث",
                                  direction: .lowerIsBetter, zeroEventRule: true, dataSource: "سجل")
        #expect(z.validate().isEmpty && z.target == 0)
        z.direction = .withinRange
        z.zeroEventRule = false
        z.rangeMinText = "10"; z.rangeMaxText = "5"
        #expect(z.validate()[.range] != nil)
    }

    @Test("the applicable version is the latest approved one starting on or before the period end")
    func applicableVersion() {
        let cal = HospitalCalendar.riyadh.calendar
        func date(_ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: m, day: 1))! }
        func v(_ from: Int, approved: Bool = true) -> IndicatorDefinitionVersion {
            IndicatorDefinitionVersion(id: UUID(), definitionID: F.lab, revision: from, measurementType: .count, unit: "x",
                                       direction: .higherIsBetter, aggregation: .sum, frequency: .monthly, zeroEventRule: false,
                                       numeratorDescription: nil, denominatorDescription: nil, dataSource: "s", target: 1,
                                       rangeMin: nil, rangeMax: nil, rangeInclusive: true, weight: 1, validFrom: date(from),
                                       isApproved: approved)
        }
        let versions = [v(1), v(6), v(12), v(9, approved: false)]
        #expect(IndicatorMath.applicableVersion(versions, periodEnd: date(11))?.revision == 6)
        #expect(IndicatorMath.applicableVersion(versions, periodEnd: cal.date(from: DateComponents(year: 2026, month: 12, day: 31))!)?.revision == 12)
        #expect(IndicatorMath.applicableVersion([v(12)], periodEnd: date(11)) == nil)
    }

    @Test("a pending reading is shown as pending, never as a result")
    func pendingIsNotAResult() async throws {
        let (director, _) = repos(F.director)
        let list = try await director.indicators.indicators(periodID: F.november)
        let doc = try #require(list.first { $0.code == "LAB.DOC" })
        #expect(doc.actual == nil && doc.outcome.outcome == .notUpdated)
        #expect(doc.latestStatus == .submitted)
        let tat = try #require(list.first { $0.code == "LAB.TAT" })
        #expect(tat.actual == 12)
        #expect(tat.outcome.outcome == IndicatorScoring.score(actual: 12, rule: IndicatorRule(direction: .lowerIsBetter, target: 10)))
    }

    @Test("head submits a zero-event reading; the director approves it; the head cannot approve")
    func measurementFlow() async throws {
        let store = MockStore(clock: clock)
        let (head, _) = repos(F.headLab, store: store)
        let headModel = IndicatorDetailViewModel(definitionID: Self.labRejections, periodID: F.november, repository: head.indicators)
        await headModel.load()
        let headCtx = MockDirectory.context(for: F.headLab)
        #expect(headModel.state.value?.permissions(for: headCtx).canSubmit == true)
        headModel.draft.valueText = "0"
        await headModel.submit(user: headCtx)
        #expect(headModel.actionError == nil)
        let pending = try #require(headModel.state.value?.pending)
        #expect(headModel.state.value?.permissions(for: headCtx).canDecide == false, "no self-approval")
        await #expect(throws: AppError.self) {
            try await head.indicators.decideMeasurement(measurementID: pending.id, approve: true, expectedVersion: pending.version,
                                                        note: nil, requestID: UUID())
        }

        let (director, _) = repos(F.director, store: store)
        let model = IndicatorDetailViewModel(definitionID: Self.labRejections, periodID: F.november, repository: director.indicators)
        await model.load()
        await model.decide(approve: true, note: nil)
        #expect(model.state.value?.approved != nil)
        #expect(model.state.value?.summary.outcome.outcome == .score(100), "zero events → 100")
    }

    @Test("replacing an approved reading needs a correction reason")
    func correctionNeedsReason() async throws {
        let (head, _) = repos(F.headLab)
        let tat = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!
        let model = IndicatorDetailViewModel(definitionID: tat, periodID: F.november, repository: head.indicators)
        await model.load()
        #expect(model.state.value?.permissions(for: MockDirectory.context(for: F.headLab)).needsCorrectionReason == true)
        model.draft.valueText = "9"
        await model.submit(user: MockDirectory.context(for: F.headLab))
        #expect(model.fieldErrors[.correctionReason] != nil)
        model.draft.correctionReason = "خطأ في احتساب العينات المؤجلة"
        await model.submit(user: MockDirectory.context(for: F.headLab))
        #expect(model.actionError == nil)
        #expect(model.state.value?.pending?.value == 9)
        #expect(model.state.value?.approved?.value == 12, "the approved value stays until the correction is approved")
    }

    // MARK: wire contracts

    @Test("template versions and report content decode leniently")
    func wireDecoding() throws {
        let version = """
        {"id":"00000000-0000-0000-0000-000000000001","template_id":"00000000-0000-0000-0000-000000000002",
         "field_schema":{"sections":[]},"required_fields":["summary"]}
        """
        let v = try SupabaseCoding.decoder.decode(TemplateVersionRowDTO.self, from: Data(version.utf8))
        #expect(v.fields == [ReportField(key: "summary", label: "summary", required: true)])

        let revision = """
        {"id":"00000000-0000-0000-0000-000000000003","revision":2,"state":"submitted",
         "content":{"f1":"نص","f2":12.5,"f3":null,"f4":{"x":1}},"version":3,"submitted_at":"2026-11-20T10:00:00+00:00"}
        """
        let r = try #require(try SupabaseCoding.decoder.decode(ReportRevisionRowDTO.self, from: Data(revision.utf8)).toDomain())
        #expect(r.content == ["f1": "نص", "f2": "12.5"])
        #expect(r.state == .submitted && r.submittedAt != nil)
    }
}
