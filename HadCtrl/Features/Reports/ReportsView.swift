import SwiftUI

/// Report list with separate filters whose counts match their lists (spec §14).
struct ReportsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case notSubmitted, returned, underReview, approved, all
        var id: Self { self }
        var title: String {
            switch self {
            case .notSubmitted: return String(localized: "لم يُسلّم")
            case .returned: return String(localized: "معاد")
            case .underReview: return String(localized: "للمراجعة")
            case .approved: return String(localized: "معتمد")
            case .all: return String(localized: "الكل")
            }
        }
        func matches(_ r: ReportItem) -> Bool {
            switch self {
            case .notSubmitted: return r.status == .notSubmitted
            case .returned: return r.status == .returned
            case .underReview: return r.status == .underReview || r.status == .submitted
            case .approved: return r.status == .approved
            case .all: return true
            }
        }
    }

    let context: UserContext
    let dependencies: DependencyContainer
    var departmentID: UUID?
    @Environment(PeriodSelection.self) private var periods
    @State private var model: ReportsListModel
    @State private var filter: Filter = .all

    init(context: UserContext, dependencies: DependencyContainer, departmentID: UUID? = nil) {
        self.context = context
        self.dependencies = dependencies
        self.departmentID = departmentID
        _model = State(initialValue: ReportsListModel(repository: dependencies.reports))
    }

    var body: some View {
        List {
            if dependencies.environment.usesMockData && departmentID == nil { DemoDataBanner().listRowBackground(Color.clear) }
            Section {
                Picker(String(localized: "التصفية"), selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text(verbatim: "\(f.title) (\((model.state.value ?? []).filter { departmentID == nil || $0.departmentID == departmentID }.filter(f.matches).count))").tag(f)
                    }
                }
            }
            if let error = model.actionError {
                Section { Label(error.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
            }
            if let confirmation = model.confirmation {
                Section { Label(confirmation, systemImage: "checkmark.circle").foregroundStyle(Color.hcGood) }
                    .accessibilityIdentifier("reports.confirmation")
            }
            switch model.state {
            case .idle, .loading(nil): SkeletonRows()
            case .failed(let e, _): StateView(kind: .error, title: String(localized: "تعذر تحميل التقارير"), message: e.userMessage)
            case .loaded(let all), .loading(let all?):
                let items = all.filter { departmentID == nil || $0.departmentID == departmentID }
                if periods.hasLoaded && periods.periods.isEmpty {
                    StateView(kind: .empty, title: String(localized: "لا توجد فترة تقارير بعد"),
                              message: context.isDirector ? String(localized: "افتح فترة الشهر الحالي لإنشاء التقارير المجدولة.")
                                                          : String(localized: "يفتح مدير المستشفى فترة التقارير."))
                }
                let shown = items.filter(filter.matches)
                if shown.isEmpty && !periods.periods.isEmpty {
                    StateView(kind: .empty, title: String(localized: "لا توجد تقارير ضمن هذه التصفية"))
                }
                ForEach(shown) { report in
                    HCLink(AppRoute.report(report.id)) { ReportRow(report: report) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.hcBackground)
        .modifier(OptionalNavigationTitle(title: departmentID == nil ? String(localized: "التقارير") : nil))
        .toolbar {
            if context.isDirector && departmentID == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await generate() }
                    } label: {
                        Label(periods.periods.isEmpty ? String(localized: "فتح الفترة الحالية") : String(localized: "توليد تقارير الفترة"),
                              systemImage: "calendar.badge.plus")
                    }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("reports.generate")
                }
            }
        }
        .refreshable { await model.load(periodID: periods.selectedID, periodsLoaded: periods.hasLoaded) }
        // Follows the period chosen on the dashboard; reloads when it changes.
        .task(id: periods.selectedID) {
            await periods.loadIfNeeded()
            await model.load(periodID: periods.selectedID, periodsLoaded: periods.hasLoaded)
        }
    }

    private func generate() async {
        let hadPeriods = !periods.periods.isEmpty
        guard let target = await model.generate(periodID: hadPeriods ? periods.selectedID : nil) else { return }
        if !hadPeriods { await periods.reload() }
        if periods.selectedID != target { periods.selectedID = target }
        else { await model.load(periodID: target, periodsLoaded: true) }
    }
}

struct ReportRow: View {
    let report: ReportItem

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(verbatim: "\(report.templateName) — \(report.departmentName)").font(.hcHeadline)
            HStack(spacing: Spacing.xs) {
                StatusBadge(text: report.status.title, tone: report.status.tone)
                if let onTime = report.submittedOnTime {
                    StatusBadge(text: onTime ? String(localized: "سُلّم في موعده") : String(localized: "سُلّم متأخرًا"),
                                tone: onTime ? .good : .warning)
                }
            }
            Text(String(localized: "الاستحقاق \(HCFormat.dateTime(report.dueAt))")).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
            if let first = report.firstSubmittedAt {
                Text(String(localized: "أول إرسال \(HCFormat.dateTime(first))")).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
            }
        }
        .accessibilityElement(children: .combine)
        // Identifier by id: interpolated Arabic labels carry bidi isolation marks.
        .accessibilityIdentifier("reportRow.\(report.id.uuidString)")
    }
}

/// One report (spec §14): fill and submit (department), approve / return / waive (director).
struct ReportDetailView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    @State private var model: ReportDetailViewModel
    @State private var noteSheet: NoteIntent?
    @State private var note = ""
    @FocusState private var focusedField: String?

    enum NoteIntent: String, Identifiable { case returnReport, waive
        var id: String { rawValue } }

    init(reportID: UUID, context: UserContext, dependencies: DependencyContainer) {
        self.context = context
        self.dependencies = dependencies
        _model = State(initialValue: ReportDetailViewModel(reportID: reportID, repository: dependencies.reports))
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading(nil): DetailSkeleton()
            case .failed(let error, _):
                StateView(kind: error.code == .notFound ? .notFound : .error,
                          title: error.code == .notFound ? String(localized: "السجل غير متاح") : String(localized: "تعذر التحميل"),
                          message: error.userMessage) { Task { await model.load() } }
            case .loaded(let detail), .loading(let detail?):
                content(detail)
            }
        }
        .background(Color.hcBackground)
        .navigationTitle(String(localized: "تفاصيل التقرير"))
        .hcOutcomeFeedback(confirmation: model.confirmation, error: model.actionError)
        .navigationBarTitleDisplayMode(.inline)
        .task { if case .idle = model.state { await model.load() } }
        .sheet(item: $noteSheet) { intent in
            NoteSheet(title: intent == .waive ? String(localized: "إعفاء من التقرير") : String(localized: "إعادة للاستكمال"),
                      note: $note) {
                let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                noteSheet = nil
                Task {
                    if intent == .waive { await model.waive(reason: text) }
                    else { await model.decide(.returned, note: text) }
                }
            }
        }
    }

    private func content(_ detail: ReportDetail) -> some View {
        let perms = detail.permissions(for: context)
        return List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(detail.report.templateName).font(.hcTitle).foregroundStyle(Color.hcInk)
                    Text(verbatim: "\(detail.report.departmentName) · \(detail.report.periodTitle)")
                        .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                    HStack {
                        StatusBadge(text: detail.report.status.title, tone: detail.report.status.tone)
                            .accessibilityIdentifier("reportStatusBadge")
                        if let onTime = detail.report.submittedOnTime {
                            StatusBadge(text: onTime ? String(localized: "سُلّم في موعده") : String(localized: "سُلّم متأخرًا"),
                                        tone: onTime ? .good : .warning)
                        }
                    }
                }
                LabeledContent(String(localized: "الاستحقاق"), value: HCFormat.dateTime(detail.report.dueAt))
                // Compliance uses the first submission, never the approval time (AC-015).
                if let first = detail.report.firstSubmittedAt {
                    LabeledContent(String(localized: "أول إرسال"), value: HCFormat.dateTime(first))
                }
                if let reason = detail.report.waiverReason {
                    LabeledContent(String(localized: "سبب الإعفاء"), value: reason)
                }
            }

            if let error = model.actionError {
                Section { Label(error.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                    .accessibilityIdentifier("actionError")
            }
            if let confirmation = model.confirmation {
                Section { Label(confirmation, systemImage: "checkmark.circle").foregroundStyle(Color.hcGood) }
            }

            if perms.canEdit {
                editor(detail, canSubmit: perms.canSubmit)
            } else {
                submitted(detail)
            }

            if perms.canDecide || perms.canWaive {
                Section(String(localized: "قرار المدير")) {
                    if perms.canDecide {
                        Button(String(localized: "اعتماد التقرير")) { Task { await model.decide(.approved, note: nil) } }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("report.approve")
                        Button(String(localized: "إعادة للاستكمال")) { note = ""; noteSheet = .returnReport }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("report.return")
                    }
                    if perms.canWaive {
                        Button(String(localized: "إعفاء القسم من هذا التقرير"), role: .destructive) { note = ""; noteSheet = .waive }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("report.waive")
                    }
                }
            }

            if !detail.reviews.isEmpty {
                Section(String(localized: "سجل المراجعة")) {
                    ForEach(detail.reviews) { review in
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            HStack {
                                StatusBadge(text: review.approved ? String(localized: "اعتُمد") : String(localized: "أُعيد"),
                                            tone: review.approved ? .good : .warning)
                                Spacer()
                                Text(HCFormat.dateTime(review.decidedAt)).font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                            }
                            if let note = review.note { Text(note).font(.hcBody) }
                            if let name = review.reviewerName { Text(name).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(String(localized: "تم")) { focusedField = nil }
                    .accessibilityIdentifier("keyboard.done")
            }
        }
    }

    @ViewBuilder private func editor(_ detail: ReportDetail, canSubmit: Bool) -> some View {
        Section {
            ForEach(detail.fields) { field in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(field.required ? "\(field.label) *" : field.label).font(.hcCallout).foregroundStyle(Color.hcInk)
                    TextField(field.label, text: Binding(get: { model.content[field.key] ?? "" },
                                                         set: { model.content[field.key] = $0 }), axis: .vertical)
                        .lineLimit(2...8)
                        .focused($focusedField, equals: field.key)
                        .accessibilityIdentifier("reportField.\(field.key)")
                    if let error = model.fieldErrors[field.key] {
                        Text(error).font(.hcFootnote).foregroundStyle(Color.hcCritical)
                    }
                }
            }
            if detail.fields.isEmpty {
                Text(String(localized: "لا يحتوي القالب على حقول")).foregroundStyle(Color.hcSecondaryText)
            }
        } header: {
            Text(String(localized: "محتوى التقرير"))
        } footer: {
            Text(String(localized: "الحقول المعلّمة بـ * إلزامية. المسودة لا تُعد تسليمًا حتى تُرسل."))
        }
        if let draft = detail.openDraft {
            AttachmentsSection(target: .reportRevision(draft.id), canEdit: true, repository: dependencies.attachments,
                               note: String(localized: "تُرسل الشواهد مع التقرير، ولا تُحذف بعد الإرسال."))
                .id(draft.id)
        } else {
            Section(String(localized: "الشواهد والمرفقات")) {
                Text(String(localized: "احفظ المسودة أولًا لإرفاق الشواهد.")).foregroundStyle(Color.hcSecondaryText)
            }
        }
        Section {
            Button(String(localized: "حفظ مسودة")) { Task { await model.saveDraft() } }
                .disabled(model.isWorking || !model.hasUnsavedChanges)
                .accessibilityIdentifier("report.saveDraft")
            if canSubmit {
                Button(String(localized: "إرسال التقرير")) { Task { await model.submit() } }
                    .disabled(model.isWorking)
                    .accessibilityIdentifier("report.submit")
            } else {
                Text(String(localized: "يرسل رئيس القسم التقرير بعد اكتماله.")).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
            }
        }
    }

    @ViewBuilder private func submitted(_ detail: ReportDetail) -> some View {
        Section(String(localized: "المحتوى المرسل")) {
            if let revision = detail.latestSubmitted {
                ForEach(detail.fields) { field in
                    LabeledContent(field.label, value: revision.content[field.key] ?? "—")
                }
                if let at = revision.submittedAt {
                    Text(String(localized: "النسخة \(revision.revision) — أُرسلت \(HCFormat.dateTime(at))"))
                        .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                }
            } else {
                Text(String(localized: "لم يُرسل محتوى بعد")).foregroundStyle(Color.hcSecondaryText)
            }
        }
        if let revision = detail.latestSubmitted {
            AttachmentsSection(target: .reportRevision(revision.id), canEdit: false, repository: dependencies.attachments)
                .id(revision.id)
        }
    }
}

/// Sets a navigation title only when given, so an embedded list keeps its host's title.
struct OptionalNavigationTitle: ViewModifier {
    let title: String?
    @ViewBuilder func body(content: Content) -> some View {
        if let title { content.navigationTitle(title) } else { content }
    }
}
