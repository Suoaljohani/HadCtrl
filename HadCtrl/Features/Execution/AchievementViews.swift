import SwiftUI
import Observation

// Achievements (spec §16): list for the selected period, detail with the
// director's decision, and the department's add/edit form.

extension AchievementItem.Status {
    var title: String {
        switch self {
        case .draft: return String(localized: "مسودة")
        case .submitted: return String(localized: "بانتظار الاعتماد")
        case .returned: return String(localized: "معاد للتوضيح")
        case .approved: return String(localized: "معتمد")
        case .rejected: return String(localized: "مرفوض")
        case .archived: return String(localized: "مؤرشف")
        }
    }

    var tone: StatusTone {
        switch self {
        case .approved: return .good
        case .returned: return .warning
        case .rejected: return .critical
        case .submitted: return .info
        case .draft, .archived: return .neutral
        }
    }
}

extension AchievementDecision {
    var title: String {
        switch self {
        case .approved: return String(localized: "اعتُمد")
        case .returned: return String(localized: "أُعيد للتوضيح")
        case .rejected: return String(localized: "رُفض")
        }
    }
}

// MARK: - List

struct AchievementsListView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    var departmentID: UUID?
    @Environment(PeriodSelection.self) private var periods
    @State private var state: LoadState<[AchievementItem]> = .idle
    @State private var creating = false

    private var canCreate: Bool { !context.departments.isEmpty }

    var body: some View {
        List {
            if dependencies.environment.usesMockData { DemoDataBanner().listRowBackground(Color.clear) }
            if canCreate {
                Section {
                    Button { creating = true } label: {
                        Label(String(localized: "توثيق منجز جديد"), systemImage: "rosette")
                    }
                    .disabled(periods.selected == nil || periods.selected?.state == .frozen)
                    .accessibilityIdentifier("achievement.new")
                }
            }
            switch state {
            case .idle, .loading(nil): SkeletonRows()
            case .failed(let e, _): StateView(kind: .error, title: String(localized: "تعذر تحميل المنجزات"), message: e.userMessage)
            case .loaded(let items) where items.isEmpty:
                StateView(kind: .empty, title: String(localized: "لا توجد منجزات لهذه الفترة"))
            case .loaded(let items), .loading(let items?):
                ForEach(items) { a in
                    HCLink(AppRoute.achievement(a.id)) { AchievementRow(item: a) }
                        .hcScrollReveal()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .refreshable { await load() }
        .sheet(isPresented: $creating, onDismiss: { Task { await load() } }) {
            AchievementEditorSheet(context: context, dependencies: dependencies,
                                   initial: AchievementDraft(departmentID: departmentID.flatMap { d in context.departments.first { $0.id == d }?.id }
                                                                 ?? context.departments.first?.id,
                                                             periodID: periods.selected?.id))
        }
        // Follows the period chosen on the dashboard; reloads when it changes.
        .task(id: periods.selectedID) {
            await periods.loadIfNeeded()
            await load()
        }
    }

    private func load() async {
        guard let periodID = periods.selectedID else {
            if periods.hasLoaded { state = .loaded([]) }
            return
        }
        state = .loading(previous: state.value)
        do {
            let all = try await dependencies.achievements.achievements(periodID: periodID)
            state = .loaded(all.filter { departmentID == nil || $0.departmentID == departmentID })
        }
        catch { state = .failed(error as? AppError ?? .network(offline: false), previous: nil) }
    }
}

struct AchievementRow: View {
    let item: AchievementItem

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(item.title).font(.hcHeadline).foregroundStyle(Color.hcInk)
            Text(item.departmentName).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
            if !item.impactSummary.isEmpty { Text(item.impactSummary).font(.hcCallout).lineLimit(2) }
            StatusBadge(text: item.status.title, tone: item.status.tone)
        }
        .accessibilityElement(children: .combine)
        // Identifier by id: interpolated Arabic labels carry bidi isolation marks.
        .accessibilityIdentifier("achievementRow.\(item.id.uuidString)")
    }
}

// MARK: - Detail

@MainActor
@Observable
final class AchievementDetailViewModel {
    private(set) var state: LoadState<AchievementDetail> = .idle
    private(set) var isWorking = false
    private(set) var actionError: AppError?
    private(set) var confirmation: String?
    @ObservationIgnored private var pending: (key: String, id: UUID)?
    let achievementID: UUID
    private let repository: AchievementsRepository

    init(achievementID: UUID, repository: AchievementsRepository) {
        self.achievementID = achievementID
        self.repository = repository
    }

    func load() async {
        state = .loading(previous: state.value)
        do { state = .loaded(try await repository.achievement(id: achievementID)) }
        catch { state = .failed(error as? AppError ?? .network(offline: false), previous: nil) }
    }

    func submit() async {
        guard let d = state.value else { return }
        await run("submit|\(d.item.version)", done: String(localized: "أُرسل المنجز لاعتماد المدير")) { id in
            try await self.repository.submit(id: d.item.id, expectedVersion: d.item.version, requestID: id)
        }
    }

    func decide(_ decision: AchievementDecision, note: String?) async {
        guard let d = state.value else { return }
        await run("decide|\(decision.rawValue)|\(d.item.version)|\(note ?? "")", done: decision.title) { id in
            try await self.repository.decide(id: d.item.id, decision: decision, expectedVersion: d.item.version,
                                             note: note, requestID: id)
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

struct AchievementDetailView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    @Environment(\.hcSignatureGate) private var signatures
    @State private var model: AchievementDetailViewModel
    @State private var editing = false
    @State private var noteFor: AchievementDecision?
    @State private var note = ""

    init(achievementID: UUID, context: UserContext, dependencies: DependencyContainer) {
        self.context = context
        self.dependencies = dependencies
        _model = State(initialValue: AchievementDetailViewModel(achievementID: achievementID, repository: dependencies.achievements))
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading(nil): DetailSkeleton()
            case .failed(let error, _):
                StateView(kind: error.code == .notFound ? .notFound : .error,
                          title: error.code == .notFound ? String(localized: "السجل غير متاح") : String(localized: "تعذر التحميل"),
                          message: error.userMessage) { Task { await model.load() } }
            case .loaded(let d), .loading(let d?):
                content(d)
            }
        }
        .background(Color.hcBackground)
        .navigationTitle(String(localized: "المنجز"))
        .hcOutcomeFeedback(confirmation: model.confirmation, error: model.actionError)
        .navigationBarTitleDisplayMode(.inline)
        .task { if case .idle = model.state { await model.load() } }
        .sheet(isPresented: $editing, onDismiss: { Task { await model.load() } }) {
            if let d = model.state.value {
                AchievementEditorSheet(context: context, dependencies: dependencies, initial: d.draft)
            }
        }
        .sheet(item: $noteFor) { decision in
            NoteSheet(title: decision == .rejected ? String(localized: "رفض المنجز") : String(localized: "إعادة للتوضيح"),
                      note: $note) {
                let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
                noteFor = nil
                Task { await model.decide(decision, note: text) }
            }
        }
    }

    private func content(_ d: AchievementDetail) -> some View {
        let perms = d.permissions(for: context)
        return List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(d.item.title).font(.hcTitle).foregroundStyle(Color.hcInk)
                    Text(verbatim: "\(d.item.departmentName) · \(d.item.periodTitle)").font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                    StatusBadge(text: d.item.status.title, tone: d.item.status.tone)
                        .accessibilityIdentifier("achievementStatusBadge")
                }
            }
            Section(String(localized: "الأثر")) {
                Text(d.impact.isEmpty ? String(localized: "لم يُكتب الأثر بعد") : d.impact)
                    .foregroundStyle(d.impact.isEmpty ? Color.hcWarning : Color.hcInk)
                if !d.description.isEmpty { Text(d.description).font(.hcCallout) }
                if let b = d.beneficiary { LabeledContent(String(localized: "المستفيد"), value: b) }
            }
            if d.linkedTask != nil || !d.contributors.isEmpty {
                Section(String(localized: "الروابط والمشاركة")) {
                    if let t = d.linkedTask { LabeledContent(String(localized: "المهمة المرتبطة"), value: t.name) }
                    if !d.contributors.isEmpty {
                        LabeledContent(String(localized: "أقسام مشاركة"), value: d.contributors.map(\.name).joined(separator: "، "))
                    }
                }
            }
            SignaturesSection(entity: .achievement(d.item.id), repository: dependencies.signatures, refreshKey: d.item.version)
            AttachmentsSection(target: .achievement(d.item.id), canEdit: perms.canEdit, repository: dependencies.attachments,
                               note: perms.canEdit ? String(localized: "الشاهد يثبت الأثر؛ لا تُرفق صور أشخاص أو نشاط لا تثبت النتيجة.") : nil)
                .id("\(d.item.id)-\(perms.canEdit)")
            if let error = model.actionError {
                Section { Label(error.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                    .accessibilityIdentifier("actionError")
            }
            if let c = model.confirmation {
                Section { Label(c, systemImage: "checkmark.circle").foregroundStyle(Color.hcGood) }
            }
            if perms.canEdit || perms.canSubmit {
                Section {
                    if perms.canEdit {
                        Button(String(localized: "تعديل")) { editing = true }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("achievement.edit")
                    }
                    if perms.canSubmit {
                        Button(String(localized: "إرسال للاعتماد")) { Task { await model.submit() } }
                            .disabled(model.isWorking)
                            .accessibilityIdentifier("achievement.submit")
                    } else if perms.canEdit {
                        Text(String(localized: "يرسل رئيس القسم المنجز للاعتماد.")).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                    }
                }
            }
            if perms.canDecide {
                Section(String(localized: "قرار المدير")) {
                    Button(String(localized: "اعتماد ونشر")) {
                        hcSigned(signatures, .achievement(d.item.id), purpose: .approve,
                                 title: String(localized: "اعتماد المنجز: \(d.item.title)")) {
                            await model.decide(.approved, note: nil)
                        }
                    }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("achievement.approve")
                    Button(String(localized: "إعادة لطلب توضيح أو شاهد")) { note = ""; noteFor = .returned }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("achievement.return")
                    Button(String(localized: "رفض"), role: .destructive) { note = ""; noteFor = .rejected }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("achievement.reject")
                }
            }
            if !d.reviews.isEmpty {
                Section(String(localized: "سجل القرارات")) {
                    ForEach(d.reviews) { r in
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            HStack {
                                Text(r.decision.title).font(.hcHeadline)
                                Spacer()
                                Text(HCFormat.dateTime(r.decidedAt)).font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                            }
                            if let n = r.note { Text(n).font(.hcBody) }
                            if let name = r.reviewerName { Text(name).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText) }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

extension AchievementDecision: Identifiable { var id: String { rawValue } }

// MARK: - Editor

@MainActor
@Observable
final class AchievementEditorViewModel {
    var draft: AchievementDraft
    private(set) var fieldErrors: [String: String] = [:]
    private(set) var error: AppError?
    private(set) var isSaving = false
    private(set) var tasks: [TaskItem] = []
    private(set) var otherDepartments: [Department] = []
    @ObservationIgnored private var saveRequest: (draft: AchievementDraft, id: UUID)?
    @ObservationIgnored private var submitRequest: (key: String, id: UUID)?
    private let repository: AchievementsRepository
    private let directory: DepartmentsRepository

    init(draft: AchievementDraft, repository: AchievementsRepository, directory: DepartmentsRepository) {
        self.draft = draft
        self.repository = repository
        self.directory = directory
    }

    func loadChoices() async {
        guard let dept = draft.departmentID else { return }
        tasks = (try? await repository.linkableTasks(departmentID: dept)) ?? []
        otherDepartments = ((try? await directory.departments()) ?? []).filter { $0.id != dept && !$0.isArchived }
        if let linked = draft.linkedTaskID, !tasks.contains(where: { $0.id == linked }) { draft.linkedTaskID = nil }
        draft.contributorIDs.remove(dept)
    }

    /// Saves (and optionally submits). Returns true when done; input is kept on failure.
    func save(submit: Bool) async -> Bool {
        fieldErrors = Dictionary(uniqueKeysWithValues: draft.validate(forSubmission: submit).map { ($0.key.rawValue, $0.value) })
        guard fieldErrors.isEmpty else { return false }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            if saveRequest?.draft != draft { saveRequest = (draft, UUID()) }
            let id = try await repository.save(draft, requestID: saveRequest!.id)
            guard submit else { return true }
            let saved = try await repository.achievement(id: id)
            // Later edits in this sheet are edits of the saved record.
            draft.id = id
            draft.expectedVersion = saved.item.version
            saveRequest = (draft, saveRequest!.id)
            let key = "\(id)|\(saved.item.version)"
            if submitRequest?.key != key { submitRequest = (key, UUID()) }
            try await repository.submit(id: id, expectedVersion: saved.item.version, requestID: submitRequest!.id)
            return true
        } catch let e as AppError {
            error = e
            if case .server(_, let fields, _, _) = e {
                fieldErrors.merge(fields.mapValues { $0 == "required" ? String(localized: "حقل إلزامي") : $0 }) { _, s in s }
            }
            return false
        } catch {
            self.error = .network(offline: false)
            return false
        }
    }
}

struct AchievementEditorSheet: View {
    let context: UserContext
    @State private var model: AchievementEditorViewModel
    @Environment(\.dismiss) private var dismiss

    init(context: UserContext, dependencies: DependencyContainer, initial: AchievementDraft) {
        self.context = context
        _model = State(initialValue: AchievementEditorViewModel(draft: initial, repository: dependencies.achievements,
                                                                directory: dependencies.departments))
    }

    private var isHead: Bool {
        context.departments.first { $0.id == model.draft.departmentID }?.roles.contains(.head) ?? false
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section(String(localized: "المنجز")) {
                    if model.draft.id == nil && context.departments.count > 1 {
                        Picker(String(localized: "القسم"), selection: $model.draft.departmentID) {
                            ForEach(context.departments) { d in Text(d.nameAr).tag(UUID?.some(d.id)) }
                        }
                    }
                    TextField(String(localized: "عنوان مختصر"), text: $model.draft.title)
                        .accessibilityIdentifier("achievement.title")
                    fieldError("title")
                    TextField(String(localized: "الأثر (رقم من قراءة معتمدة أو نتيجة موثقة)"), text: $model.draft.impact, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("achievement.impact")
                    fieldError("impact_text")
                    TextField(String(localized: "الوصف (اختياري)"), text: $model.draft.description, axis: .vertical)
                        .lineLimit(2...6)
                    TextField(String(localized: "المستفيد (اختياري)"), text: $model.draft.beneficiary)
                }
                Section {
                    Picker(String(localized: "مهمة مكتملة مرتبطة"), selection: $model.draft.linkedTaskID) {
                        Text(String(localized: "بدون")).tag(UUID?.none)
                        ForEach(model.tasks) { t in Text(t.title).tag(UUID?.some(t.id)) }
                    }
                    fieldError("linked_task_id")
                    ForEach(model.otherDepartments) { d in
                        Toggle(d.nameAr, isOn: Binding(get: { model.draft.contributorIDs.contains(d.id) },
                                                       set: { on in
                                                           if on { model.draft.contributorIDs.insert(d.id) }
                                                           else { model.draft.contributorIDs.remove(d.id) }
                                                       }))
                    }
                    fieldError("contributor_department_ids")
                } header: {
                    Text(String(localized: "الروابط والأقسام المشاركة"))
                } footer: {
                    Text(String(localized: "لا تُنشر المهمة نفسها كأكثر من منجز في الفترة نفسها. المنجز المشترك يُعد مرة واحدة."))
                }
                if let e = model.error, model.fieldErrors.isEmpty {
                    Section { Label(e.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                }
                if isHead {
                    Section {
                        Button(String(localized: "حفظ وإرسال للاعتماد")) {
                            Task { if await model.save(submit: true) { dismiss() } }
                        }
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("achievement.saveAndSubmit")
                    }
                }
            }
            .navigationTitle(model.draft.id == nil ? String(localized: "منجز جديد") : String(localized: "تعديل المنجز"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "إلغاء")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "حفظ مسودة")) { Task { if await model.save(submit: false) { dismiss() } } }
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("achievement.saveDraft")
                }
            }
            .task(id: model.draft.departmentID) { await model.loadChoices() }
        }
    }

    @ViewBuilder private func fieldError(_ key: String) -> some View {
        if let message = model.fieldErrors[key] {
            Text(message).font(.hcCaption).foregroundStyle(Color.hcCritical)
        }
    }
}
