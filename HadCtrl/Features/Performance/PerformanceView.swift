import SwiftUI

/// Indicators with their measured score and explicit "not updated" / "pending
/// approval" states (spec §10, §11). Each row opens the indicator for the period.
struct PerformanceView: View {
    enum Segment: String, CaseIterable, Identifiable { case indicators, goals; var id: Self { self } }
    let context: UserContext
    let dependencies: DependencyContainer
    @State private var segment: Segment

    init(context: UserContext, dependencies: DependencyContainer, initialSegment: Segment = .indicators) {
        self.context = context
        self.dependencies = dependencies
        _segment = State(initialValue: initialSegment)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "العرض"), selection: $segment) {
                Text(String(localized: "المؤشرات")).tag(Segment.indicators)
                Text(String(localized: "الأهداف")).tag(Segment.goals)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            switch segment {
            case .indicators: IndicatorsListView(dependencies: dependencies)
            case .goals: GoalsListView(context: context, dependencies: dependencies)
            }
        }
        .background(Color.hcBackground)
        .navigationTitle(String(localized: "الأداء"))
    }
}

/// Indicators for the selected period; `departmentID` narrows to one department.
struct IndicatorsListView: View {
    let dependencies: DependencyContainer
    var departmentID: UUID?
    @Environment(PeriodSelection.self) private var periods
    @State private var model: IndicatorListModel

    init(dependencies: DependencyContainer, departmentID: UUID? = nil) {
        self.dependencies = dependencies
        self.departmentID = departmentID
        _model = State(initialValue: IndicatorListModel(repository: dependencies.indicators))
    }

    var body: some View {
        List {
            switch model.state {
            case .idle, .loading: ProgressView().frame(maxWidth: .infinity)
            case .failed(let e, _):
                StateView(kind: .error, title: String(localized: "تعذر تحميل المؤشرات"), message: e.userMessage)
            case .loaded(let items) where items.isEmpty:
                StateView(kind: .empty, title: String(localized: "لا توجد مؤشرات معرّفة لهذه الفترة"),
                          message: String(localized: "يعرّف مدير المستشفى المؤشرات من الإعدادات ← الإدارة."))
            case .loaded(let all):
                let items = all.filter { departmentID == nil || $0.departmentID == departmentID }
                if dependencies.environment.usesMockData && departmentID == nil { DemoDataBanner().listRowBackground(Color.clear) }
                if items.isEmpty { StateView(kind: .empty, title: String(localized: "لا توجد مؤشرات لهذا القسم")) }
                ForEach(items) { item in
                    if let periodID = periods.selectedID {
                        NavigationLink(value: AppRoute.indicator(item.id, periodID: periodID)) { IndicatorRow(item: item) }
                    } else {
                        IndicatorRow(item: item)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await model.load(periodID: periods.selectedID, periodsLoaded: periods.hasLoaded) }
        // Follows the period chosen on the dashboard; reloads when it changes.
        .task(id: periods.selectedID) {
            await periods.loadIfNeeded()
            await model.load(periodID: periods.selectedID, periodsLoaded: periods.hasLoaded)
        }
    }
}

struct IndicatorRow: View {
    let item: IndicatorSummary
    private let style = NumberStyle()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Text(item.title).font(.hcHeadline).foregroundStyle(Color.hcInk)
                Spacer()
                IndicatorOutcomeBadge(outcome: item.outcome.outcome)
            }
            Text("\(item.departmentName) · \(item.code)").font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
            HStack(spacing: Spacing.m) {
                Text(String(localized: "الفعلي: \(item.actual.map { style.format($0) } ?? String(localized: "لم يُحدّث")) \(item.unit)"))
                Text(IndicatorText.targetLine(item, style: style))
            }
            .font(.hcCallout).monospacedDigit()
            if item.latestStatus == .submitted {
                StatusBadge(text: String(localized: "قراءة بانتظار الاعتماد"), tone: .info, symbol: "hourglass")
            } else if item.latestStatus == .returned {
                StatusBadge(text: String(localized: "قراءة معادة للقسم"), tone: .warning)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("indicatorRow.\(item.code)")
    }
}

struct IndicatorOutcomeBadge: View {
    let outcome: ScoreOutcome
    private let style = NumberStyle()

    var body: some View {
        switch outcome {
        case .score(let v):
            StatusBadge(text: style.percent(v), tone: v >= 100 ? .good : (v >= 80 ? .warning : .critical))
        case .notUpdated:
            StatusBadge(text: String(localized: "لم يُحدّث"), tone: .neutral)
        case .notComputable(let reason):
            StatusBadge(text: reason == .notApplicable ? String(localized: "لا ينطبق") : String(localized: "غير قابل للحساب"),
                        tone: .neutral)
        case .outOfRange:
            StatusBadge(text: String(localized: "خارج النطاق"), tone: .critical)
        }
    }
}

enum IndicatorText {
    static func targetLine(_ item: IndicatorSummary, style: NumberStyle) -> String {
        if item.direction == .withinRange, let lo = item.rangeMin, let hi = item.rangeMax {
            return String(localized: "النطاق: \(style.format(lo))–\(style.format(hi)) \(item.unit)")
        }
        return String(localized: "المستهدف: \(item.target.map { style.format($0) } ?? "—") \(item.unit)")
    }

    static func rule(for direction: ImprovementDirection, zeroEvent: Bool = false) -> String {
        switch direction {
        case .higherIsBetter: return String(localized: "الأعلى أفضل: الدرجة = الأدنى بين ١٠٠ و(الفعلي ÷ المستهدف × ١٠٠).")
        case .lowerIsBetter:
            if zeroEvent { return String(localized: "صفر أحداث: صفر يعطي ١٠٠، وأي حدث يعطي صفرًا.") }
            return String(localized: "الأقل أفضل: الدرجة = الأدنى بين ١٠٠ و(المستهدف ÷ الفعلي × ١٠٠)، والصفر يعطي ١٠٠.")
        case .withinRange: return String(localized: "ضمن نطاق: ١٠٠ داخل النطاق المعتمد، وخارج النطاق يظهر صراحة.")
        }
    }

    static func aggregation(_ rule: AggregationRule) -> String {
        switch rule {
        case .sum: return String(localized: "مجموع القراءات")
        case .latest: return String(localized: "آخر قراءة (عداد تراكمي)")
        case .ratioOfSums: return String(localized: "مجموع البسط ÷ مجموع المقام (لا متوسط نسب)")
        case .weightedMean: return String(localized: "متوسط موزون")
        }
    }

    static func type(_ t: MeasurementType) -> String {
        switch t {
        case .ratio: return String(localized: "نسبة (بسط ÷ مقام)")
        case .count: return String(localized: "عدد")
        case .duration: return String(localized: "مدة")
        case .milestones: return String(localized: "مراحل")
        }
    }

    static func direction(_ d: ImprovementDirection) -> String {
        switch d {
        case .higherIsBetter: return String(localized: "الأعلى أفضل")
        case .lowerIsBetter: return String(localized: "الأقل أفضل")
        case .withinRange: return String(localized: "ضمن نطاق")
        }
    }
}

extension MeasurementStatus {
    var title: String {
        switch self {
        case .draft: return String(localized: "مسودة")
        case .submitted: return String(localized: "بانتظار الاعتماد")
        case .returned: return String(localized: "معادة للقسم")
        case .approved: return String(localized: "معتمدة")
        case .superseded: return String(localized: "مستبدلة بتصحيح")
        }
    }

    var tone: StatusTone {
        switch self {
        case .approved: return .good
        case .returned: return .warning
        case .submitted: return .info
        case .draft, .superseded: return .neutral
        }
    }
}

/// Indicator for the selected period (spec §10): definition, readings history,
/// entry for the department head, approve / return for the director.
struct IndicatorDetailView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    @State private var model: IndicatorDetailViewModel
    @State private var returning = false
    @State private var note = ""
    private let style = NumberStyle()

    init(definitionID: UUID, periodID: UUID, context: UserContext, dependencies: DependencyContainer) {
        self.context = context
        self.dependencies = dependencies
        _model = State(initialValue: IndicatorDetailViewModel(definitionID: definitionID, periodID: periodID,
                                                              repository: dependencies.indicators))
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading(nil): ProgressView()
            case .failed(let error, _):
                StateView(kind: error.code == .notFound ? .notFound : .error,
                          title: error.code == .notFound ? String(localized: "السجل غير متاح") : String(localized: "تعذر التحميل"),
                          message: error.userMessage) { Task { await model.load() } }
            case .loaded(let detail), .loading(let detail?):
                content(detail)
            }
        }
        .background(Color.hcBackground)
        .navigationTitle(String(localized: "المؤشر"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if case .idle = model.state { await model.load() } }
        .sheet(isPresented: $returning) {
            NoteSheet(title: String(localized: "إعادة القراءة للقسم"), note: $note) {
                let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                returning = false
                Task { await model.decide(approve: false, note: text) }
            }
        }
    }

    private func content(_ detail: IndicatorDetail) -> some View {
        let perms = detail.permissions(for: context)
        let s = detail.summary
        return List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(s.title).font(.hcTitle).foregroundStyle(Color.hcInk)
                    Text("\(s.departmentName) · \(s.code) · \(detail.period.title)").font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                    HStack {
                        IndicatorOutcomeBadge(outcome: s.outcome.outcome).accessibilityIdentifier("indicatorOutcome")
                        if detail.period.state == .frozen {
                            StatusBadge(text: String(localized: "الفترة مجمّدة"), tone: .neutral, symbol: "lock")
                        }
                    }
                }
                LabeledContent(String(localized: "الفعلي المعتمد"),
                               value: s.actual.map { "\(style.format($0)) \(s.unit)" } ?? String(localized: "لم يُحدّث"))
                Text(IndicatorText.targetLine(s, style: style)).font(.hcCallout)
            }

            if let error = model.actionError {
                Section { Label(error.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                    .accessibilityIdentifier("actionError")
            }
            if let confirmation = model.confirmation {
                Section { Label(confirmation, systemImage: "checkmark.circle").foregroundStyle(Color.hcGood) }
                    .accessibilityIdentifier("indicator.confirmation")
            }

            if let pending = detail.pending, perms.canDecide {
                Section(String(localized: "قراءة بانتظار اعتمادك")) {
                    Text(readingText(pending, detail)).font(.hcHeadline).monospacedDigit()
                    Button(String(localized: "اعتماد القراءة")) { Task { await model.decide(approve: true, note: nil) } }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("indicator.approve")
                    Button(String(localized: "إعادة للقسم")) { note = ""; returning = true }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("indicator.return")
                }
            }

            if perms.canSubmit, let version = detail.version {
                entry(version: version, needsCorrection: perms.needsCorrectionReason)
            } else if detail.pending != nil && !perms.canDecide {
                Section { Text(String(localized: "توجد قراءة بانتظار الاعتماد لهذه الفترة.")).foregroundStyle(Color.hcSecondaryText) }
            }

            Section(String(localized: "القراءات في هذه الفترة")) {
                if detail.measurements.isEmpty {
                    Text(String(localized: "لا توجد قراءات بعد")).foregroundStyle(Color.hcSecondaryText)
                }
                ForEach(detail.measurements) { m in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack {
                            Text(readingText(m, detail)).font(.hcCallout).monospacedDigit()
                            Spacer()
                            StatusBadge(text: m.status.title, tone: m.status.tone)
                        }
                        if let at = m.submittedAt {
                            Text(String(localized: "النسخة \(m.revision) — \(HCFormat.dateTime(at))"))
                                .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                        }
                        if let note = m.sourceNote, !note.isEmpty { Text(note).font(.hcFootnote) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Section(String(localized: "كيف يُقاس؟")) {
                if !s.howMeasured.isEmpty { Text(s.howMeasured) }
                if let v = detail.version {
                    LabeledContent(String(localized: "النوع"), value: IndicatorText.type(v.measurementType))
                    LabeledContent(String(localized: "الاتجاه"), value: IndicatorText.direction(v.direction))
                    LabeledContent(String(localized: "التجميع"), value: IndicatorText.aggregation(v.aggregation))
                    Text(IndicatorText.rule(for: v.direction, zeroEvent: v.zeroEventRule)).font(.hcFootnote)
                } else {
                    Text(String(localized: "لا توجد نسخة معتمدة من التعريف تنطبق على هذه الفترة."))
                        .foregroundStyle(Color.hcWarning)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    @ViewBuilder private func entry(version: IndicatorDefinitionVersion, needsCorrection: Bool) -> some View {
        Section {
            Picker(String(localized: "نوع الإدخال"), selection: $model.draft.mode) {
                Text(String(localized: "قيمة")).tag(MeasurementDraft.Mode.value)
                Text(String(localized: "لا ينطبق")).tag(MeasurementDraft.Mode.notApplicable)
            }
            .pickerStyle(.segmented)
            if model.draft.mode == .notApplicable {
                field(String(localized: "سبب عدم الانطباق"), text: $model.draft.notApplicableReason, id: "notApplicableReason",
                      error: model.fieldErrors[.notApplicableReason], numeric: false)
            } else if version.isRatio {
                field(version.numeratorDescription ?? String(localized: "البسط"), text: $model.draft.numeratorText,
                      id: "numerator", error: model.fieldErrors[.numerator], numeric: true)
                field(version.denominatorDescription ?? String(localized: "المقام"), text: $model.draft.denominatorText,
                      id: "denominator", error: model.fieldErrors[.denominator], numeric: true)
            } else {
                field(String(localized: "القيمة (\(version.unit))"), text: $model.draft.valueText, id: "value",
                      error: model.fieldErrors[.value], numeric: true)
            }
            field(String(localized: "ملاحظة المصدر (اختياري)"), text: $model.draft.sourceNote, id: "sourceNote", error: nil, numeric: false)
            if needsCorrection {
                field(String(localized: "سبب التصحيح"), text: $model.draft.correctionReason, id: "correctionReason",
                      error: model.fieldErrors[.correctionReason], numeric: false)
            }
            Button(needsCorrection ? String(localized: "إرسال تصحيح") : String(localized: "إرسال القراءة")) {
                Task { await model.submit(user: context) }
            }
            .disabled(model.isWorking)
            .accessibilityIdentifier("indicator.submit")
        } header: {
            Text(needsCorrection ? String(localized: "تصحيح القراءة المعتمدة") : String(localized: "إدخال قراءة الفترة"))
        } footer: {
            Text(String(localized: "الحقل الفارغ لا يُحسب صفرًا. اختر «لا ينطبق» مع السبب إن لم تنطبق الفترة."))
        }
    }

    private func field(_ title: String, text: Binding<String>, id: String, error: String?, numeric: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            TextField(title, text: text)
                .keyboardType(numeric ? .decimalPad : .default)
                .accessibilityIdentifier("measurement.\(id)")
            if let error { Text(error).font(.hcFootnote).foregroundStyle(Color.hcCritical) }
        }
    }

    private func readingText(_ m: MeasurementRevision, _ detail: IndicatorDetail) -> String {
        if let reason = m.notApplicableReason { return String(localized: "لا ينطبق: \(reason)") }
        if detail.version?.isRatio == true, let n = m.numerator, let d = m.denominator {
            let pct: String
            if case .success(let a) = IndicatorScoring.actual(of: m.reading, isRatio: true) { pct = style.percent(a) }
            else { pct = "—" }
            return "\(style.format(n)) ÷ \(style.format(d)) = \(pct)"
        }
        return m.value.map { "\(style.format($0)) \(detail.version?.unit ?? "")" } ?? "—"
    }
}
