import Foundation

/// Demo/test reports and indicators (HC_APP_ENV=demo/ui-testing only). Mirrors
/// the server rules used by the screens: editable only while not submitted or
/// returned, required fields, versions, no self-approval, corrections need a reason.
actor MockPerformanceStore {
    typealias F = MockStore.Fixture

    private struct MockReport {
        var detail: ReportDetail
        let periodID: UUID
    }
    private struct MockIndicator {
        let info: IndicatorDefinitionInfo
        let version: IndicatorDefinitionVersion
        var measurements: [UUID: [MeasurementRevision]] = [:]   // by period
    }

    private let clock: HCClock
    private var reports: [UUID: MockReport] = [:]
    private var indicators: [UUID: MockIndicator] = [:]
    private var templates: [UUID: (name: String, fields: [ReportField])] = [:]
    private var schedules: [(template: UUID, department: UUID, dueDay: Int)] = []
    private var replies: [UUID: String] = [:]   // request id → content hash (idempotency)

    static let fields = [
        ReportField(key: "f1", label: "ملخص الإنجاز", required: true),
        ReportField(key: "f2", label: "العوائق والاحتياجات", required: false),
        ReportField(key: "f3", label: "خطة الفترة القادمة", required: true),
    ]

    init(clock: HCClock) {
        self.clock = clock
        let now = clock.now()
        let day: TimeInterval = 86_400
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000002%02d", n))! }
        func report(_ n: Int, _ dept: UUID, _ name: String, status: ReportStatus, due: TimeInterval, period: UUID,
                    revisions: [ReportRevision] = [], reviews: [ReportReviewEntry] = []) -> MockReport {
            let first = revisions.compactMap(\.submittedAt).min()
            let item = ReportItem(id: id(n), departmentName: name, templateName: "التقرير الشهري",
                                  periodTitle: period == F.november ? "نوفمبر ٢٠٢٦" : "أكتوبر ٢٠٢٦",
                                  dueAt: now.addingTimeInterval(due), firstSubmittedAt: first, status: status,
                                  waiverReason: nil, departmentID: dept, version: 1)
            return MockReport(detail: ReportDetail(report: item, departmentID: dept, fields: Self.fields, revisions: revisions,
                                                   reviews: reviews, latestRevisionID: revisions.first { $0.state != .draft }?.id),
                              periodID: period)
        }
        let submittedTRN = ReportRevision(id: id(51), revision: 1, state: .submitted,
                                          content: ["f1": "نُفذت أربعة برامج تدريبية", "f3": "برنامج الإنعاش المتقدم"],
                                          version: 1, submittedAt: now.addingTimeInterval(-day))
        let returnedQLT = ReportRevision(id: id(52), revision: 1, state: .returned, content: ["f1": "مراجعة جزئية"],
                                         version: 1, submittedAt: now.addingTimeInterval(-2 * day))
        let seed = [
            report(1, F.lab, "المختبر", status: .notSubmitted, due: 3 * day, period: F.november),
            report(2, F.training, "التدريب", status: .submitted, due: 2 * day, period: F.november, revisions: [submittedTRN]),
            report(3, F.quality, "الجودة", status: .returned, due: -1 * day, period: F.november, revisions: [returnedQLT],
                   reviews: [ReportReviewEntry(id: id(61), revisionID: returnedQLT.id, approved: false,
                                               note: "أكمل خطة الفترة القادمة", decidedAt: now.addingTimeInterval(-day),
                                               reviewerName: "مدير المستشفى")]),
        ]
        for r in seed { reports[r.detail.report.id] = r }

        func did(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000003%02d", n))! }
        let start = HospitalCalendar.riyadh.calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        func version(_ n: Int, _ type: MeasurementType, _ unit: String, _ dir: ImprovementDirection, _ agg: AggregationRule,
                     target: Decimal?, zero: Bool = false, num: String? = nil, den: String? = nil, source: String) -> IndicatorDefinitionVersion {
            IndicatorDefinitionVersion(id: did(n + 10), definitionID: did(n), revision: 1, measurementType: type, unit: unit,
                                       direction: dir, aggregation: agg, frequency: .monthly, zeroEventRule: zero,
                                       numeratorDescription: num, denominatorDescription: den, dataSource: source,
                                       target: target, rangeMin: nil, rangeMax: nil, rangeInclusive: true, weight: 1,
                                       validFrom: start, isApproved: true)
        }
        func m(_ n: Int, status: MeasurementStatus, value: Decimal? = nil, num: Decimal? = nil, den: Decimal? = nil,
               by user: UUID) -> MeasurementRevision {
            MeasurementRevision(id: did(n + 20), revision: 1, status: status, value: value, numerator: num, denominator: den,
                                notApplicableReason: nil, sourceNote: nil, enteredBy: user,
                                submittedAt: now.addingTimeInterval(-day), approvedAt: status == .approved ? now : nil, version: 1)
        }
        let defs: [MockIndicator] = [
            MockIndicator(info: .init(id: did(1), departmentID: F.lab, code: "LAB.DOC", title: "اكتمال توثيق العينات", description: ""),
                          version: version(1, .ratio, "%", .higherIsBetter, .ratioOfSums, target: 95,
                                           num: "العينات الموثقة كاملة", den: "كل العينات المستلمة في الفترة", source: "نظام المختبر"),
                          measurements: [F.november: [m(1, status: .submitted, num: 90, den: 100, by: F.headLab)]]),
            MockIndicator(info: .init(id: did(2), departmentID: F.lab, code: "LAB.TAT", title: "زمن إصدار النتائج",
                                      description: "من استلام العينة إلى اعتماد النتيجة، متوسط الفترة."),
                          version: version(2, .duration, "ساعة", .lowerIsBetter, .weightedMean, target: 10, source: "نظام المختبر"),
                          measurements: [F.november: [m(2, status: .approved, value: 12, by: F.headLab)]]),
            MockIndicator(info: .init(id: did(3), departmentID: F.lab, code: "LAB.REJ", title: "العينات المرفوضة لخطأ في التعريف",
                                      description: "أحداث يجب ألا تقع."),
                          version: version(3, .count, "عينة", .lowerIsBetter, .sum, target: 0, zero: true, source: "سجل الجودة")),
            MockIndicator(info: .init(id: did(4), departmentID: F.training, code: "TRN.PROG", title: "البرامج التدريبية المنفذة",
                                      description: "عداد تراكمي منذ بداية العام؛ يُجمع بآخر قراءة."),
                          version: version(4, .count, "برنامج", .higherIsBetter, .latest, target: 11, source: "سجل التدريب")),
        ]
        for d in defs { indicators[d.info.id] = d }
    }

    private func fail(_ code: HCErrorCode, _ fields: [String: String] = [:], version: Int? = nil) -> AppError {
        .server(code: code, fieldErrors: fields, currentVersion: version, correlationID: nil)
    }

    /// Replays with the same request id and payload succeed without repeating the change.
    private func isReplay(_ requestID: UUID, _ payload: String) throws -> Bool {
        if let prior = replies[requestID] {
            guard prior == payload else { throw fail(.idempotencyMismatch) }
            return true
        }
        return false
    }

    private func canRead(_ r: MockReport, _ user: UserContext) -> Bool {
        user.isDirector || user.departments.contains { $0.id == r.detail.departmentID }
    }

    // MARK: reports

    func reportList(periodID: UUID, user: UserContext) -> [ReportItem] {
        reports.values.filter { $0.periodID == periodID && canRead($0, user) }.map(\.detail.report)
            .sorted { ($0.dueAt, $0.id.uuidString) < ($1.dueAt, $1.id.uuidString) }
    }

    func report(id: UUID, user: UserContext) throws -> ReportDetail {
        guard let r = reports[id], canRead(r, user) else { throw fail(.notFound) }
        var d = r.detail
        // Drafts are visible to the department only (RLS).
        if !user.departments.contains(where: { $0.id == d.departmentID }) {
            d = ReportDetail(report: d.report, departmentID: d.departmentID, fields: d.fields,
                             revisions: d.revisions.filter { $0.state != .draft }, reviews: d.reviews,
                             latestRevisionID: d.latestRevisionID)
        }
        return d
    }

    func saveDraft(reportID: UUID, content: [String: String], expectedRevisionVersion: Int?, requestID: UUID,
                   user: UserContext) throws -> SavedDraft {
        guard var r = reports[reportID], canRead(r, user) else { throw fail(.notFound) }
        let payload = "draft|\(reportID)|\(content.sorted { $0.key < $1.key })|\(expectedRevisionVersion ?? -1)"
        if try isReplay(requestID, payload), let draft = r.detail.openDraft {
            return SavedDraft(revisionID: draft.id, revisionVersion: draft.version, reportVersion: r.detail.report.version)
        }
        guard r.detail.permissions(for: user).canEdit else {
            if user.departments.contains(where: { $0.id == r.detail.departmentID }) { throw fail(.validationFailed, ["status": "not_editable"]) }
            throw fail(.forbidden)
        }
        var revisions = r.detail.revisions
        let draft: ReportRevision
        if let index = revisions.firstIndex(where: { $0.state == .draft }) {
            guard revisions[index].version == expectedRevisionVersion else { throw fail(.versionConflict, version: revisions[index].version) }
            draft = ReportRevision(id: revisions[index].id, revision: revisions[index].revision, state: .draft, content: content,
                                   version: revisions[index].version + 1, submittedAt: nil)
            revisions[index] = draft
        } else {
            draft = ReportRevision(id: UUID(), revision: (revisions.map(\.revision).max() ?? 0) + 1, state: .draft,
                                   content: content, version: 1, submittedAt: nil)
            revisions.insert(draft, at: 0)
        }
        r.detail = ReportDetail(report: r.detail.report, departmentID: r.detail.departmentID, fields: r.detail.fields,
                                revisions: revisions, reviews: r.detail.reviews, latestRevisionID: r.detail.latestRevisionID)
        reports[reportID] = r
        replies[requestID] = payload
        return SavedDraft(revisionID: draft.id, revisionVersion: draft.version, reportVersion: r.detail.report.version)
    }

    func submit(reportID: UUID, draftRevisionID: UUID, expectedVersion: Int, requestID: UUID, user: UserContext) throws {
        guard var r = reports[reportID], canRead(r, user) else { throw fail(.notFound) }
        let payload = "submit|\(reportID)|\(draftRevisionID)|\(expectedVersion)"
        if try isReplay(requestID, payload) { return }
        guard r.detail.permissions(for: user).canSubmit else { throw fail(.forbidden) }
        guard r.detail.report.version == expectedVersion else { throw fail(.versionConflict, version: r.detail.report.version) }
        guard let index = r.detail.revisions.firstIndex(where: { $0.id == draftRevisionID && $0.state == .draft }) else {
            throw fail(.validationFailed, ["draft_revision_id": "not_open_draft"])
        }
        let draft = r.detail.revisions[index]
        let missing = r.detail.missingRequired(in: draft.content)
        guard missing.isEmpty else {
            throw fail(.validationFailed, Dictionary(uniqueKeysWithValues: missing.map { ($0, "required") }))
        }
        let now = clock.now()
        var revisions = r.detail.revisions
        revisions[index] = ReportRevision(id: draft.id, revision: draft.revision, state: .submitted, content: draft.content,
                                          version: draft.version + 1, submittedAt: now)
        var item = r.detail.report
        item = ReportItem(id: item.id, departmentName: item.departmentName, templateName: item.templateName,
                          periodTitle: item.periodTitle, dueAt: item.dueAt, firstSubmittedAt: item.firstSubmittedAt ?? now,
                          status: .submitted, waiverReason: nil, departmentID: item.departmentID, version: item.version + 1)
        r.detail = ReportDetail(report: item, departmentID: r.detail.departmentID, fields: r.detail.fields,
                                revisions: revisions, reviews: r.detail.reviews, latestRevisionID: draft.id)
        reports[reportID] = r
        replies[requestID] = payload
    }

    func decide(reportID: UUID, revisionID: UUID, decision: ReportDecision, expectedVersion: Int, note: String?,
                requestID: UUID, user: UserContext) throws {
        guard var r = reports[reportID], canRead(r, user) else { throw fail(.notFound) }
        let payload = "decide|\(reportID)|\(revisionID)|\(decision.rawValue)|\(expectedVersion)|\(note ?? "")"
        if try isReplay(requestID, payload) { return }
        guard r.detail.permissions(for: user).canDecide else { throw fail(.forbidden) }
        if decision == .returned, (note ?? "").trimmingCharacters(in: .whitespaces).count < 3 { throw fail(.validationFailed, ["note": "required"]) }
        guard r.detail.report.version == expectedVersion, r.detail.latestRevisionID == revisionID else {
            throw fail(.versionConflict, version: r.detail.report.version)
        }
        var revisions = r.detail.revisions
        if let i = revisions.firstIndex(where: { $0.id == revisionID }) {
            let old = revisions[i]
            revisions[i] = ReportRevision(id: old.id, revision: old.revision, state: decision == .approved ? .approved : .returned,
                                          content: old.content, version: old.version + 1, submittedAt: old.submittedAt)
        }
        let item = r.detail.report
        let updated = ReportItem(id: item.id, departmentName: item.departmentName, templateName: item.templateName,
                                 periodTitle: item.periodTitle, dueAt: item.dueAt, firstSubmittedAt: item.firstSubmittedAt,
                                 status: decision == .approved ? .approved : .returned, waiverReason: nil,
                                 departmentID: item.departmentID, version: item.version + 1)
        let review = ReportReviewEntry(id: UUID(), revisionID: revisionID, approved: decision == .approved, note: note,
                                       decidedAt: clock.now(), reviewerName: user.displayName)
        r.detail = ReportDetail(report: updated, departmentID: r.detail.departmentID, fields: r.detail.fields,
                                revisions: revisions, reviews: [review] + r.detail.reviews, latestRevisionID: revisionID)
        reports[reportID] = r
        replies[requestID] = payload
    }

    func waive(reportID: UUID, reason: String, expectedVersion: Int, requestID: UUID, user: UserContext) throws {
        guard var r = reports[reportID], canRead(r, user) else { throw fail(.notFound) }
        let payload = "waive|\(reportID)|\(reason)|\(expectedVersion)"
        if try isReplay(requestID, payload) { return }
        guard r.detail.permissions(for: user).canWaive else { throw fail(.forbidden) }
        guard reason.trimmingCharacters(in: .whitespaces).count >= 3 else { throw fail(.validationFailed, ["reason": "required"]) }
        guard r.detail.report.version == expectedVersion else { throw fail(.versionConflict, version: r.detail.report.version) }
        let item = r.detail.report
        let updated = ReportItem(id: item.id, departmentName: item.departmentName, templateName: item.templateName,
                                 periodTitle: item.periodTitle, dueAt: item.dueAt, firstSubmittedAt: item.firstSubmittedAt,
                                 status: .waived, waiverReason: reason, departmentID: item.departmentID, version: item.version + 1)
        r.detail = ReportDetail(report: updated, departmentID: r.detail.departmentID, fields: r.detail.fields,
                                revisions: r.detail.revisions, reviews: r.detail.reviews, latestRevisionID: r.detail.latestRevisionID)
        reports[reportID] = r
        replies[requestID] = payload
    }

    func createTemplate(_ draft: NewReportTemplateDraft, requestID: UUID, user: UserContext) throws -> UUID {
        guard user.isDirector else { throw fail(.forbidden) }
        let errors = draft.validate().filter { $0.key != .departments && $0.key != .dueDay }
        guard errors.isEmpty else {
            throw fail(.validationFailed, Dictionary(uniqueKeysWithValues: errors.map { ($0.key.rawValue, $0.value) }))
        }
        if let prior = replies[requestID], let id = UUID(uuidString: prior) { return id }
        let id = UUID()
        templates[id] = (draft.nameAr, draft.wireFields)
        replies[requestID] = id.uuidString
        return id
    }

    func schedule(templateID: UUID, departmentIDs: [UUID], dueDay: Int, requestID: UUID, user: UserContext) throws -> Int {
        guard user.isDirector else { throw fail(.forbidden) }
        guard templates[templateID] != nil else { throw fail(.notFound) }
        guard (1...28).contains(dueDay), !departmentIDs.isEmpty else { throw fail(.validationFailed, ["due_day": "between_1_and_28"]) }
        if replies[requestID] != nil { return departmentIDs.count }
        for d in departmentIDs where !schedules.contains(where: { $0.template == templateID && $0.department == d }) {
            schedules.append((templateID, d, dueDay))
        }
        replies[requestID] = "scheduled"
        return departmentIDs.count
    }

    func generate(periodID: UUID, user: UserContext, departmentNames: [UUID: String]) throws -> Int {
        guard user.isDirector else { throw fail(.forbidden) }
        var created = 0
        let cal = HospitalCalendar.riyadh
        for s in schedules {
            let exists = reports.values.contains {
                $0.periodID == periodID && $0.detail.departmentID == s.department && $0.detail.report.templateName == templates[s.template]?.name
            }
            guard !exists, let template = templates[s.template] else { continue }
            let due = cal.endOfDay(containing: clock.now().addingTimeInterval(Double(s.dueDay) * 86_400))
            let item = ReportItem(id: UUID(), departmentName: departmentNames[s.department] ?? "—", templateName: template.name,
                                  periodTitle: "", dueAt: due, firstSubmittedAt: nil, status: .notSubmitted, waiverReason: nil,
                                  departmentID: s.department, version: 1)
            reports[item.id] = MockReport(detail: ReportDetail(report: item, departmentID: s.department, fields: template.fields,
                                                               revisions: [], reviews: [], latestRevisionID: nil),
                                          periodID: periodID)
            created += 1
        }
        return created
    }

    // MARK: indicators

    private func summary(_ ind: MockIndicator, periodID: UUID) -> IndicatorSummary {
        IndicatorMath.summary(definition: ind.info, version: ind.version, departmentName: MockDirectory.name(of: ind.info.departmentID),
                              measurements: ind.measurements[periodID] ?? [])
    }

    func indicatorList(periodID: UUID, user: UserContext) -> [IndicatorSummary] {
        indicators.values.filter { ind in user.isDirector || user.departments.contains { $0.id == ind.info.departmentID } }
            .sorted { $0.info.code < $1.info.code }
            .map { summary($0, periodID: periodID) }
    }

    func indicator(definitionID: UUID, period: ReportingPeriod, user: UserContext) throws -> IndicatorDetail {
        guard let ind = indicators[definitionID],
              user.isDirector || user.departments.contains(where: { $0.id == ind.info.departmentID }) else { throw fail(.notFound) }
        return IndicatorDetail(definition: ind.info, version: ind.version, period: period,
                               measurements: (ind.measurements[period.id] ?? []).sorted { $0.revision > $1.revision },
                               summary: summary(ind, periodID: period.id))
    }

    func submitMeasurement(definitionVersionID: UUID, period: ReportingPeriod, reading: Reading, correctionReason: String?,
                           requestID: UUID, user: UserContext) throws {
        guard var ind = indicators.values.first(where: { $0.version.id == definitionVersionID }) else { throw fail(.notFound) }
        let payload = "m|\(definitionVersionID)|\(period.id)|\(reading)|\(correctionReason ?? "")"
        if try isReplay(requestID, payload) { return }
        let detail = try indicator(definitionID: ind.info.id, period: period, user: user)
        let p = detail.permissions(for: user)
        guard p.canSubmit else {
            if detail.pending != nil { throw fail(.validationFailed, ["period_id": "open_revision_exists"]) }
            if period.state == .frozen { throw fail(.periodFrozen) }
            throw fail(.forbidden, ["reason": "only_department_head_submits"])
        }
        if p.needsCorrectionReason, (correctionReason ?? "").trimmingCharacters(in: .whitespaces).count < 3 {
            throw fail(.validationFailed, ["correction_reason": "required_to_replace_approved"])
        }
        var list = ind.measurements[period.id] ?? []
        list.append(MeasurementRevision(id: UUID(), revision: (list.map(\.revision).max() ?? 0) + 1, status: .submitted,
                                        value: reading.value, numerator: reading.numerator, denominator: reading.denominator,
                                        notApplicableReason: reading.notApplicableReason, sourceNote: nil, enteredBy: user.userID,
                                        submittedAt: clock.now(), approvedAt: nil, version: 1))
        ind.measurements[period.id] = list
        indicators[ind.info.id] = ind
        replies[requestID] = payload
    }

    func decideMeasurement(measurementID: UUID, approve: Bool, expectedVersion: Int, note: String?, requestID: UUID,
                           user: UserContext) throws {
        guard var ind = indicators.values.first(where: { $0.measurements.values.contains { $0.contains { $0.id == measurementID } } }),
              let periodID = ind.measurements.first(where: { $0.value.contains { $0.id == measurementID } })?.key,
              var list = ind.measurements[periodID], let index = list.firstIndex(where: { $0.id == measurementID }) else {
            throw fail(.notFound)
        }
        let payload = "d|\(measurementID)|\(approve)|\(expectedVersion)|\(note ?? "")"
        if try isReplay(requestID, payload) { return }
        let m = list[index]
        guard user.isDirector, !user.departments.contains(where: { $0.id == ind.info.departmentID }), m.enteredBy != user.userID else {
            throw fail(.forbidden)
        }
        guard m.version == expectedVersion else { throw fail(.versionConflict, version: m.version) }
        guard m.status == .submitted else { throw fail(.validationFailed, ["status": "not_submitted"]) }
        if !approve, (note ?? "").trimmingCharacters(in: .whitespaces).count < 3 { throw fail(.validationFailed, ["note": "required"]) }
        func with(_ r: MeasurementRevision, _ s: MeasurementStatus) -> MeasurementRevision {
            MeasurementRevision(id: r.id, revision: r.revision, status: s, value: r.value, numerator: r.numerator,
                                denominator: r.denominator, notApplicableReason: r.notApplicableReason, sourceNote: r.sourceNote,
                                enteredBy: r.enteredBy, submittedAt: r.submittedAt,
                                approvedAt: s == .approved ? clock.now() : r.approvedAt, version: r.version + 1)
        }
        if approve {
            list = list.map { $0.status == .approved ? with($0, .superseded) : $0 }
            list[index] = with(m, .approved)
        } else {
            list[index] = with(m, .returned)
        }
        ind.measurements[periodID] = list
        indicators[ind.info.id] = ind
        replies[requestID] = payload
    }

    func createIndicator(_ draft: NewIndicatorDraft, requestID: UUID, user: UserContext) throws -> UUID {
        guard user.isDirector else { throw fail(.forbidden) }
        if let prior = replies[requestID], let id = UUID(uuidString: prior) { return id }
        var errors = Dictionary(uniqueKeysWithValues: draft.validate().map { ($0.key.rawValue, $0.value) })
        let code = draft.code.trimmingCharacters(in: .whitespaces).uppercased()
        if indicators.values.contains(where: { $0.info.code == code }) { errors["code"] = String(localized: "الرمز مستخدم") }
        guard errors.isEmpty, let dept = draft.departmentID else { throw fail(.validationFailed, errors) }
        let id = UUID()
        let start = HospitalCalendar.riyadh.calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let within = draft.direction == .withinRange
        let version = IndicatorDefinitionVersion(
            id: UUID(), definitionID: id, revision: 1, measurementType: draft.measurementType, unit: draft.effectiveUnit,
            direction: draft.direction, aggregation: draft.aggregation, frequency: .monthly, zeroEventRule: draft.zeroEventRule,
            numeratorDescription: draft.numeratorDescription.nonEmpty, denominatorDescription: draft.denominatorDescription.nonEmpty,
            dataSource: draft.dataSource, target: within ? nil : draft.target,
            rangeMin: within ? NumberInput.parseDecimal(draft.rangeMinText) : nil,
            rangeMax: within ? NumberInput.parseDecimal(draft.rangeMaxText) : nil,
            rangeInclusive: true, weight: 1, validFrom: start, isApproved: true)
        indicators[id] = MockIndicator(info: .init(id: id, departmentID: dept, code: code, title: draft.title,
                                                   description: draft.description), version: version)
        replies[requestID] = id.uuidString
        return id
    }
}

struct MockReportsRepository: ReportsRepository {
    let store: MockStore
    let user: UUID
    private var ctx: UserContext { MockDirectory.context(for: user) }
    private var perf: MockPerformanceStore { store.performance }

    func reports(periodID: UUID) async throws -> [ReportItem] {
        try await store.consumeFailure()
        return await perf.reportList(periodID: periodID, user: ctx)
    }
    func report(id: UUID) async throws -> ReportDetail { try await perf.report(id: id, user: ctx) }
    func saveDraft(reportID: UUID, content: [String: String], expectedRevisionVersion: Int?, requestID: UUID) async throws -> SavedDraft {
        try await store.consumeFailure()
        return try await perf.saveDraft(reportID: reportID, content: content, expectedRevisionVersion: expectedRevisionVersion,
                                        requestID: requestID, user: ctx)
    }
    func submit(reportID: UUID, draftRevisionID: UUID, expectedVersion: Int, requestID: UUID) async throws {
        try await perf.submit(reportID: reportID, draftRevisionID: draftRevisionID, expectedVersion: expectedVersion,
                              requestID: requestID, user: ctx)
    }
    func decide(reportID: UUID, revisionID: UUID, decision: ReportDecision, expectedVersion: Int, note: String?, requestID: UUID) async throws {
        try await perf.decide(reportID: reportID, revisionID: revisionID, decision: decision, expectedVersion: expectedVersion,
                              note: note, requestID: requestID, user: ctx)
    }
    func waive(reportID: UUID, reason: String, expectedVersion: Int, requestID: UUID) async throws {
        try await perf.waive(reportID: reportID, reason: reason, expectedVersion: expectedVersion, requestID: requestID, user: ctx)
    }
    func createTemplate(_ draft: NewReportTemplateDraft, requestID: UUID) async throws -> UUID {
        try await perf.createTemplate(draft, requestID: requestID, user: ctx)
    }
    func schedule(templateID: UUID, departmentIDs: [UUID], dueDay: Int, requestID: UUID) async throws -> Int {
        try await perf.schedule(templateID: templateID, departmentIDs: departmentIDs, dueDay: dueDay, requestID: requestID, user: ctx)
    }
    func ensureCurrentPeriod() async throws -> UUID {
        guard ctx.isDirector else { throw AppError.server(code: .forbidden, fieldErrors: [:], currentVersion: nil, correlationID: nil) }
        return MockStore.Fixture.november
    }
    func generateReports(periodID: UUID) async throws -> Int {
        let departments = await store.departments
        let names = Dictionary(departments.map { ($0.id, $0.nameAr) }, uniquingKeysWith: { a, _ in a })
        return try await perf.generate(periodID: periodID, user: ctx, departmentNames: names)
    }
}

struct MockIndicatorsRepository: IndicatorsRepository {
    let store: MockStore
    let user: UUID
    let periods: MockDashboardRepository
    private var ctx: UserContext { MockDirectory.context(for: user) }
    private var perf: MockPerformanceStore { store.performance }

    private func period(_ id: UUID) async throws -> ReportingPeriod {
        guard let p = try await periods.periods().first(where: { $0.id == id }) else {
            throw AppError.server(code: .notFound, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        return p
    }

    func indicators(periodID: UUID) async throws -> [IndicatorSummary] {
        try await store.consumeFailure()
        return await perf.indicatorList(periodID: periodID, user: ctx)
    }
    func indicator(definitionID: UUID, periodID: UUID) async throws -> IndicatorDetail {
        let p = try await period(periodID)
        return try await perf.indicator(definitionID: definitionID, period: p, user: ctx)
    }
    func submitMeasurement(definitionVersionID: UUID, periodID: UUID, reading: Reading, sourceNote: String?,
                           correctionReason: String?, requestID: UUID) async throws {
        let p = try await period(periodID)
        try await perf.submitMeasurement(definitionVersionID: definitionVersionID, period: p,
                                         reading: reading, correctionReason: correctionReason, requestID: requestID, user: ctx)
    }
    func decideMeasurement(measurementID: UUID, approve: Bool, expectedVersion: Int, note: String?, requestID: UUID) async throws {
        try await perf.decideMeasurement(measurementID: measurementID, approve: approve, expectedVersion: expectedVersion,
                                         note: note, requestID: requestID, user: ctx)
    }
    func createIndicator(_ draft: NewIndicatorDraft, requestID: UUID) async throws -> UUID {
        try await perf.createIndicator(draft, requestID: requestID, user: ctx)
    }
}
