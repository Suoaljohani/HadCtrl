import SwiftUI
import Observation

// Goals (spec §09): list, detail with the two numbers (raw vs capped),
// expected-to-date and gap, milestones, director decisions, and the new-goal form.

extension GoalLifecycle {
    var title: String {
        switch self {
        case .draft: return String(localized: "مسودة بانتظار الاعتماد")
        case .active: return String(localized: "نشط")
        case .completionPending: return String(localized: "طلب إقفال")
        case .completed: return String(localized: "مكتمل")
        case .cancelled: return String(localized: "ملغى")
        case .archived: return String(localized: "مؤرشف")
        }
    }
    var tone: StatusTone {
        switch self {
        case .completed: return .good
        case .completionPending, .draft: return .info
        case .cancelled, .archived: return .neutral
        case .active: return .warning
        }
    }
}

extension GoalProgress.Track {
    var title: String {
        switch self {
        case .onTrack: return String(localized: "ضمن المسار")
        case .behind: return String(localized: "متأخر عن الخطة")
        case .noData: return String(localized: "لا توجد قراءة معتمدة")
        case .notStarted: return String(localized: "لم يبدأ")
        }
    }
    var tone: StatusTone {
        switch self {
        case .onTrack: return .good
        case .behind: return .critical
        case .noData, .notStarted: return .neutral
        }
    }
}

enum GoalText {
    static func progressLine(_ p: GoalProgress, unit: String, style: NumberStyle = NumberStyle()) -> String {
        let actual = p.actual.map { style.format($0) } ?? String(localized: "لم يُحدّث")
        let target = p.target.map { style.format($0) } ?? "—"
        return String(localized: "الفعلي \(actual) من \(target) \(unit)")
    }
}

// MARK: - List

struct GoalsListView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    var departmentID: UUID?
    @State private var state: LoadState<[GoalSummary]> = .idle
    @State private var creating = false

    private var canCreate: Bool { context.isDirector || !context.headedDepartments.isEmpty }

    var body: some View {
        List {
            if dependencies.environment.usesMockData && departmentID == nil { DemoDataBanner().listRowBackground(Color.clear) }
            if canCreate {
                Section {
                    Button { creating = true } label: { Label(String(localized: "هدف جديد"), systemImage: "target") }
                        .accessibilityIdentifier("goal.new")
                }
            }
            switch state {
            case .idle, .loading(nil): SkeletonRows()
            case .failed(let e, _): StateView(kind: .error, title: String(localized: "تعذر تحميل الأهداف"), message: e.userMessage)
            case .loaded(let items) where items.isEmpty:
                StateView(kind: .empty, title: String(localized: "لا توجد أهداف بعد"))
            case .loaded(let items), .loading(let items?):
                ForEach(items) { g in
                    HCLink(AppRoute.goal(g.id)) { GoalRow(goal: g) }
                        .hcScrollReveal()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
        .task { if case .idle = state { await load() } }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
            NewGoalSheet(context: context, dependencies: dependencies, departmentID: departmentID)
        }
    }

    private func load() async {
        state = .loading(previous: state.value)
        do { state = .loaded(try await dependencies.goals.goals(departmentID: departmentID, asOf: dependencies.clock.now())) }
        catch { state = .failed(error as? AppError ?? .network(offline: false), previous: nil) }
    }
}

struct GoalRow: View {
    let goal: GoalSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(goal.title).font(.hcHeadline).foregroundStyle(Color.hcInk)
            Text(goal.departmentName).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
            Text(GoalText.progressLine(goal.progress, unit: goal.unit)).font(.hcCallout).monospacedDigit()
            HStack(spacing: Spacing.xs) {
                StatusBadge(text: goal.lifecycle.title, tone: goal.lifecycle.tone)
                if goal.lifecycle == .active || goal.lifecycle == .completionPending {
                    StatusBadge(text: goal.progress.track.title, tone: goal.progress.track.tone)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("goalRow.\(goal.id.uuidString)")
    }
}

// MARK: - Detail

@MainActor
@Observable
final class GoalDetailViewModel {
    private(set) var state: LoadState<GoalDetail> = .idle
    private(set) var isWorking = false
    private(set) var actionError: AppError?
    private(set) var confirmation: String?
    @ObservationIgnored private var pending: (key: String, id: UUID)?
    let goalID: UUID
    private let repository: GoalsRepository
    private let clock: HCClock

    init(goalID: UUID, repository: GoalsRepository, clock: HCClock) {
        self.goalID = goalID
        self.repository = repository
        self.clock = clock
    }

    func load() async {
        state = .loading(previous: state.value)
        do { state = .loaded(try await repository.goal(id: goalID, asOf: clock.now())) }
        catch { state = .failed(error as? AppError ?? .network(offline: false), previous: nil) }
    }

    func decide(_ decision: GoalDecision, note: String?) async {
        guard let g = state.value else { return }
        await run("decide|\(decision.rawValue)|\(g.summary.version)|\(note ?? "")", done: String(localized: "سُجّل القرار")) { id in
            try await self.repository.decide(id: g.summary.id, decision: decision, expectedVersion: g.summary.version,
                                             note: note, requestID: id)
        }
    }

    func requestCompletion() async {
        guard let g = state.value else { return }
        await run("complete|\(g.summary.version)", done: String(localized: "أُرسل طلب الإقفال للمدير")) { id in
            try await self.repository.requestCompletion(id: g.summary.id, expectedVersion: g.summary.version, note: nil, requestID: id)
        }
    }

    func milestone(_ m: GoalMilestone, approve: Bool) async {
        await run("ms|\(m.id)|\(approve)", done: approve ? String(localized: "اعتُمدت المرحلة") : String(localized: "سُجّل إنجاز المرحلة")) { id in
            try await self.repository.setMilestone(id: m.id, approve: approve, requestID: id)
        }
    }

    private func run(_ key: String, done: String, _ body: (UUID) async throws -> Void) async {
        guard !isWorking else { return }
        let requestID: UUID
        if let p = pending, p.key == key { requestID = p.id } else { requestID = UUID(); pending = (key, requestID) }
        isWorking = true; actionError = nil; confirmation = nil
        defer { isWorking = false }
        do {
            try await body(requestID)
            pending = nil
            confirmation = done
            await load()
        } catch {
            let e = error as? AppError ?? .network(offline: false)
            actionError = e
            if e.code == .versionConflict { pending = nil; await load() }
            if !e.isRetryable { pending = nil }
        }
    }
}

extension GoalDecision: Identifiable { var id: String { rawValue } }

struct GoalDetailView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    @Environment(\.hcSignatureGate) private var signatures
    @Environment(PeriodSelection.self) private var periods
    @State private var model: GoalDetailViewModel
    @State private var noteFor: GoalDecision?
    @State private var note = ""
    private let style = NumberStyle()

    init(goalID: UUID, context: UserContext, dependencies: DependencyContainer) {
        self.context = context
        self.dependencies = dependencies
        _model = State(initialValue: GoalDetailViewModel(goalID: goalID, repository: dependencies.goals, clock: dependencies.clock))
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading(nil): DetailSkeleton()
            case .failed(let error, _):
                StateView(kind: error.code == .notFound ? .notFound : .error,
                          title: error.code == .notFound ? String(localized: "السجل غير متاح") : String(localized: "تعذر التحميل"),
                          message: error.userMessage) { Task { await model.load() } }
            case .loaded(let g), .loading(let g?):
                content(g)
            }
        }
        .background(Color.hcBackground)
        .navigationTitle(String(localized: "الهدف"))
        .hcOutcomeFeedback(confirmation: model.confirmation, error: model.actionError)
        .navigationBarTitleDisplayMode(.inline)
        .task { if case .idle = model.state { await model.load() } }
        .sheet(item: $noteFor) { decision in
            NoteSheet(title: decision.title, note: $note) {
                let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                noteFor = nil
                Task { await model.decide(decision, note: text) }
            }
        }
    }

    private func content(_ g: GoalDetail) -> some View {
        let p = g.permissions(for: context)
        let s = g.summary
        return List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(s.title).font(.hcTitle).foregroundStyle(Color.hcInk)
                    Text(verbatim: "\(s.departmentName) · \(HCFormat.date(s.startAt)) – \(HCFormat.date(s.dueAt))")
                        .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                    HStack {
                        StatusBadge(text: s.lifecycle.title, tone: s.lifecycle.tone).accessibilityIdentifier("goalStatusBadge")
                        if s.lifecycle == .active || s.lifecycle == .completionPending {
                            StatusBadge(text: s.progress.track.title, tone: s.progress.track.tone)
                        }
                    }
                }
                if !g.description.isEmpty { Text(g.description) }
                if let owner = g.ownerName { LabeledContent(String(localized: "المسؤول"), value: owner) }
                if let reason = g.cancelReason { LabeledContent(String(localized: "سبب الإلغاء"), value: reason) }
            }
            Section {
                LabeledContent(String(localized: "الفعلي"), value: s.progress.actual.map { "\(style.format($0)) \(s.unit)" } ?? String(localized: "لم يُحدّث"))
                LabeledContent(String(localized: "المستهدف"), value: s.progress.target.map { "\(style.format($0)) \(s.unit)" } ?? "—")
                if let e = s.progress.expectedToDate {
                    LabeledContent(String(localized: "المتوقع حتى اليوم"), value: "\(style.format(e)) \(s.unit)")
                    if let a = s.progress.actual, a < e {
                        LabeledContent(String(localized: "الفجوة"), value: "\(style.format(e - a)) \(s.unit)")
                            .foregroundStyle(Color.hcCritical)
                    }
                }
                if let raw = s.progress.raw, let capped = s.progress.capped {
                    LabeledContent(String(localized: "الإنجاز الخام"), value: style.percent(raw))
                    LabeledContent(String(localized: "المحتسب في التجميع"), value: style.percent(capped))
                }
            } header: {
                Text(String(localized: "التقدم"))
            } footer: {
                Text(s.measurementType == .milestones
                     ? String(localized: "يُحسب من أوزان المراحل المعتمدة فقط.")
                     : String(localized: "يُحسب من القراءات المعتمدة للمؤشر المقيس، لا من اكتمال المهام. الإنجاز الخام قد يتجاوز ١٠٠٪ والمحتسب له سقف ١٠٠٪."))
            }

            if !g.plan.isEmpty || g.planIsLinear {
                Section(String(localized: "خطة التقدم")) {
                    if g.planIsLinear { Text(String(localized: "توزيع خطي معتمد من البداية إلى النهاية")).font(.hcFootnote) }
                    ForEach(g.plan, id: \.at) { point in
                        LabeledContent(HCFormat.date(point.at), value: "\(style.format(point.expected)) \(s.unit)")
                    }
                }
            }

            if !g.milestones.isEmpty {
                Section(String(localized: "المراحل")) {
                    ForEach(g.milestones) { m in
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            HStack {
                                Text(verbatim: "\(m.ordinal). \(m.title)").font(.hcHeadline)
                                Spacer()
                                Text(style.percent(m.weight)).font(.hcCaption).monospacedDigit()
                            }
                            Text(m.criterion).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                            StatusBadge(text: m.approved ? String(localized: "معتمدة") : (m.completedAt != nil ? String(localized: "منجزة بانتظار الاعتماد") : String(localized: "لم تُنجز")),
                                        tone: m.approved ? .good : (m.completedAt != nil ? .info : .neutral))
                            if p.canCompleteMilestone && m.completedAt == nil {
                                Button(String(localized: "تسجيل إنجاز المرحلة")) { Task { await model.milestone(m, approve: false) } }
                                    .buttonStyle(.borderless).disabled(model.isWorking)
                                    .accessibilityIdentifier("milestone.complete.\(m.ordinal)")
                            }
                            if p.canApproveMilestone && m.completedAt != nil && !m.approved {
                                Button(String(localized: "اعتماد المرحلة")) { Task { await model.milestone(m, approve: true) } }
                                    .buttonStyle(.borderless).disabled(model.isWorking)
                                    .accessibilityIdentifier("milestone.approve.\(m.ordinal)")
                            }
                        }
                    }
                }
            }

            if !g.indicators.isEmpty {
                Section(String(localized: "المؤشرات المرتبطة")) {
                    ForEach(g.indicators) { link in
                        if let periodID = periods.selectedID {
                            HCLink(AppRoute.indicator(link.id, periodID: periodID)) { indicatorLabel(link) }
                        } else {
                            indicatorLabel(link)
                        }
                    }
                }
            }

            if let error = model.actionError {
                Section { Label(error.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                    .accessibilityIdentifier("actionError")
            }
            if let c = model.confirmation {
                Section { Label(c, systemImage: "checkmark.circle").foregroundStyle(Color.hcGood) }
            }

            if p.canRequestCompletion {
                Section {
                    Button(String(localized: "طلب إقفال الهدف")) { Task { await model.requestCompletion() } }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("goal.requestCompletion")
                } footer: {
                    Text(String(localized: "يقرر المدير الإقفال وفق تعريف الهدف؛ اكتمال المهام وحده لا يكفي."))
                }
            }
            SignaturesSection(entity: .goal(model.goalID), repository: dependencies.signatures,
                              refreshKey: model.confirmation?.hashValue ?? 0)
            if p.canActivate || p.canDecideCompletion || p.canCancel {
                Section(String(localized: "قرار المدير")) {
                    if p.canActivate {
                        Button(String(localized: "اعتماد التعريف وتفعيل الهدف")) {
                            hcSigned(signatures, .goal(model.goalID), purpose: .activate,
                                     title: String(localized: "اعتماد الهدف وتفعيله")) {
                                await model.decide(.activate, note: nil)
                            }
                        }
                            .disabled(model.isWorking).accessibilityIdentifier("goal.activate")
                        Button(String(localized: "إعادة للقسم مع ملاحظة")) { note = ""; noteFor = .return }
                            .disabled(model.isWorking).accessibilityIdentifier("goal.return")
                    }
                    if p.canDecideCompletion {
                        Button(String(localized: "إقفال الهدف كمكتمل")) {
                            hcSigned(signatures, .goal(model.goalID), purpose: .complete,
                                     title: String(localized: "إقفال الهدف كمكتمل")) {
                                await model.decide(.complete, note: nil)
                            }
                        }
                            .disabled(model.isWorking).accessibilityIdentifier("goal.complete")
                        Button(String(localized: "رفض الإقفال")) { note = ""; noteFor = .rejectCompletion }
                            .disabled(model.isWorking).accessibilityIdentifier("goal.rejectCompletion")
                    }
                    if p.canCancel {
                        Button(String(localized: "إلغاء الهدف بسبب موثق"), role: .destructive) { note = ""; noteFor = .cancel }
                            .disabled(model.isWorking).accessibilityIdentifier("goal.cancel")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func indicatorLabel(_ link: GoalIndicatorLink) -> some View {
        VStack(alignment: .leading) {
            Text(link.title)
            Text(link.measuresOutcome ? String(localized: "يقيس النتيجة") : String(localized: "مساند"))
                .font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
        }
    }
}

extension GoalDecision {
    var title: String {
        switch self {
        case .activate: return String(localized: "تفعيل الهدف")
        case .return: return String(localized: "إعادة للقسم")
        case .complete: return String(localized: "إقفال الهدف")
        case .rejectCompletion: return String(localized: "رفض الإقفال")
        case .cancel: return String(localized: "إلغاء الهدف")
        }
    }
}

// MARK: - New goal

@MainActor
@Observable
final class NewGoalViewModel {
    var draft: NewGoalDraft
    private(set) var fieldErrors: [String: String] = [:]
    private(set) var error: AppError?
    private(set) var isSaving = false
    private(set) var indicators: [IndicatorSummary] = []
    @ObservationIgnored private var request: (draft: NewGoalDraft, id: UUID)?
    private let goals: GoalsRepository
    private let indicatorsRepo: IndicatorsRepository

    init(draft: NewGoalDraft, goals: GoalsRepository, indicators: IndicatorsRepository) {
        self.draft = draft
        self.goals = goals
        self.indicatorsRepo = indicators
    }

    func loadIndicators(periodID: UUID?) async {
        guard let periodID, let dept = draft.departmentID else { indicators = []; return }
        indicators = ((try? await indicatorsRepo.indicators(periodID: periodID)) ?? []).filter { $0.departmentID == dept }
        draft.measuringIndicatorIDs = draft.measuringIndicatorIDs.filter { id in indicators.contains { $0.id == id } }
    }

    func save() async -> Bool {
        fieldErrors = Dictionary(uniqueKeysWithValues: draft.validate().map { ($0.key.rawValue, $0.value) })
        guard fieldErrors.isEmpty else { return false }
        if request?.draft != draft { request = (draft, UUID()) }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            _ = try await goals.create(draft, requestID: request!.id)
            return true
        } catch let e as AppError {
            error = e
            if case .server(_, let fields, _, _) = e { fieldErrors.merge(fields) { _, s in s } }
            return false
        } catch {
            self.error = .network(offline: false)
            return false
        }
    }
}

struct NewGoalSheet: View {
    let context: UserContext
    @Environment(PeriodSelection.self) private var periods
    @State private var model: NewGoalViewModel
    @Environment(\.dismiss) private var dismiss

    /// The director may define goals for any department; a head for the departments they lead.
    init(context: UserContext, dependencies: DependencyContainer, departmentID: UUID?) {
        self.context = context
        var draft = NewGoalDraft()
        draft.departmentID = departmentID ?? context.headedDepartments.first?.id
        _model = State(initialValue: NewGoalViewModel(draft: draft, goals: dependencies.goals, indicators: dependencies.indicators))
        directoryDepartments = dependencies.departments
    }
    private let directoryDepartments: DepartmentsRepository
    @State private var allDepartments: [Department] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section(String(localized: "الهدف")) {
                    Picker(String(localized: "القسم"), selection: $model.draft.departmentID) {
                        Text(String(localized: "اختر")).tag(UUID?.none)
                        if context.isDirector {
                            ForEach(allDepartments) { d in Text(d.nameAr).tag(UUID?.some(d.id)) }
                        } else {
                            ForEach(context.headedDepartments) { d in Text(d.nameAr).tag(UUID?.some(d.id)) }
                        }
                    }
                    fieldError("department_id")
                    TextField(String(localized: "العنوان (النتيجة المتوقعة)"), text: $model.draft.title)
                        .accessibilityIdentifier("goal.title")
                    fieldError("title")
                    TextField(String(localized: "الوصف (اختياري)"), text: $model.draft.description, axis: .vertical)
                    DatePicker(String(localized: "البداية"), selection: $model.draft.startDate, displayedComponents: .date)
                    DatePicker(String(localized: "النهاية"), selection: $model.draft.dueDate, displayedComponents: .date)
                    fieldError("due_date")
                    Picker(String(localized: "الأولوية"), selection: $model.draft.priority) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    Picker(String(localized: "نوع القياس"), selection: $model.draft.measurementType) {
                        Text(String(localized: "عدد")).tag(MeasurementType.count)
                        Text(String(localized: "نسبة")).tag(MeasurementType.ratio)
                        Text(String(localized: "مدة")).tag(MeasurementType.duration)
                        Text(String(localized: "مراحل")).tag(MeasurementType.milestones)
                    }
                    if model.draft.measurementType == .milestones {
                        ForEach($model.draft.milestones) { $m in
                            VStack(alignment: .leading) {
                                TextField(String(localized: "عنوان المرحلة"), text: $m.title)
                                TextField(String(localized: "معيار الإنجاز"), text: $m.criterion)
                                TextField(String(localized: "الوزن من ١٠٠"), text: $m.weightText).keyboardType(.decimalPad)
                            }
                        }
                        .onDelete { model.draft.milestones.remove(atOffsets: $0) }
                        Button(String(localized: "إضافة مرحلة")) { model.draft.milestones.append(.init()) }
                        fieldError("milestones")
                    } else {
                        if model.draft.measurementType != .ratio {
                            TextField(String(localized: "الوحدة (مثل برنامج، ساعة)"), text: $model.draft.unit)
                                .accessibilityIdentifier("goal.unit")
                            fieldError("unit")
                        }
                        TextField(String(localized: "خط الأساس (اختياري)"), text: $model.draft.baselineText).keyboardType(.decimalPad)
                        TextField(String(localized: "القيمة المستهدفة"), text: $model.draft.targetText).keyboardType(.decimalPad)
                            .accessibilityIdentifier("goal.target")
                        fieldError("target")
                    }
                } header: {
                    Text(String(localized: "ما معنى الإنجاز؟"))
                } footer: {
                    Text(String(localized: "لا يوجد «١٠٠٪» افتراضي: حدد قيمة مستهدفة أو مراحل بأوزان مجموعها ١٠٠."))
                }
                if model.draft.measurementType != .milestones {
                    Section {
                        Toggle(String(localized: "توزيع خطي (عند ملاءمته فقط)"), isOn: $model.draft.planIsLinear)
                        ForEach($model.draft.plan) { $row in
                            HStack {
                                DatePicker("", selection: $row.at, displayedComponents: .date).labelsHidden()
                                TextField(String(localized: "المتوقع"), text: $row.expectedText).keyboardType(.decimalPad)
                            }
                        }
                        .onDelete { model.draft.plan.remove(atOffsets: $0) }
                        Button(String(localized: "إضافة نقطة في الخطة")) { model.draft.plan.append(.init(at: model.draft.dueDate)) }
                        fieldError("plan")
                    } header: {
                        Text(String(localized: "خطة التقدم الزمنية"))
                    }
                    Section(String(localized: "المؤشر الذي يقيس النتيجة")) {
                        if model.indicators.isEmpty {
                            Text(String(localized: "لا توجد مؤشرات لهذا القسم بعد")).foregroundStyle(Color.hcSecondaryText)
                        }
                        ForEach(model.indicators) { i in
                            Toggle(i.title, isOn: Binding(get: { model.draft.measuringIndicatorIDs.contains(i.id) },
                                                          set: { on in
                                                              if on { model.draft.measuringIndicatorIDs.insert(i.id) }
                                                              else { model.draft.measuringIndicatorIDs.remove(i.id) }
                                                          }))
                        }
                    }
                }
                if let e = model.error, model.fieldErrors.isEmpty {
                    Section { Label(e.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                }
            }
            .navigationTitle(String(localized: "هدف جديد"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "إلغاء")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "حفظ")) { Task { if await model.save() { dismiss() } } }
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("goal.save")
                }
            }
            .task {
                if context.isDirector { allDepartments = ((try? await directoryDepartments.departments()) ?? []).filter { !$0.isArchived } }
            }
            .task(id: model.draft.departmentID) { await model.loadIndicators(periodID: periods.selectedID) }
        }
    }

    @ViewBuilder private func fieldError(_ key: String) -> some View {
        if let message = model.fieldErrors[key] {
            Text(message).font(.hcCaption).foregroundStyle(Color.hcCritical)
        }
    }
}
