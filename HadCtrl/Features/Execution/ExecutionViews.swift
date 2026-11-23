import SwiftUI

/// "Execution" holds tasks and achievements as two clear destinations (spec §04).
struct ExecutionView: View {
    enum Segment: String, CaseIterable, Identifiable { case tasks, achievements; var id: Self { self } }
    let context: UserContext
    let dependencies: DependencyContainer
    let present: (SheetRoute) -> Void
    @State private var segment: Segment = .tasks

    var body: some View {
        VStack(spacing: 0) {
            Picker(String(localized: "العرض"), selection: $segment) {
                Text(String(localized: "المهام")).tag(Segment.tasks)
                Text(String(localized: "المنجزات")).tag(Segment.achievements)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Spacing.m)
            .padding(.vertical, Spacing.xs)
            switch segment {
            case .tasks: TaskListView(context: context, dependencies: dependencies, initialFilter: TaskFilter())
            case .achievements: AchievementsListView(dependencies: dependencies)
            }
        }
        .background(Color.hcBackground)
        .navigationTitle(String(localized: "التنفيذ"))
        .toolbar {
            if context.canCreateAssignments {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { present(.newTask(departmentID: nil)) } label: {
                        Label(String(localized: "تكليف جديد"), systemImage: "plus.circle.fill")
                    }
                }
            }
        }
    }
}

struct TaskListView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    @State private var model: TaskListViewModel

    init(context: UserContext, dependencies: DependencyContainer, initialFilter: TaskFilter) {
        self.context = context
        self.dependencies = dependencies
        _model = State(initialValue: TaskListViewModel(repository: dependencies.tasks, filter: initialFilter))
    }

    var body: some View {
        List {
            Section {
                Picker(String(localized: "التصفية"), selection: $model.filter.scope) {
                    Text(String(localized: "الكل")).tag(TaskFilter.Scope.all)
                    Text(String(localized: "المسندة إليّ")).tag(TaskFilter.Scope.assignedToMe)
                    Text(String(localized: "المتأخرة")).tag(TaskFilter.Scope.overdue)
                    Text(String(localized: "للاعتماد")).tag(TaskFilter.Scope.awaitingApproval)
                }
                .accessibilityIdentifier("taskFilter")
            }
            switch model.state {
            case .idle, .loading(nil):
                ProgressView().frame(maxWidth: .infinity)
            case .failed(let error, _):
                StateView(kind: .error, title: String(localized: "تعذر تحميل المهام"), message: error.userMessage) { model.reload() }
            case .loaded(let items) where items.isEmpty:
                StateView(kind: .empty, title: String(localized: "لا توجد مهام ضمن هذه التصفية"))
            case .loaded(let items), .loading(let items?):
                ForEach(items) { task in
                    NavigationLink(value: AppRoute.task(task.id)) { TaskRow(task: task, now: dependencies.clock.now()) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.hcBackground)
        .refreshable { model.reload(); await model.waitForIdle() }
        .task { if case .idle = model.state { model.reload() } }
        .accessibilityIdentifier("taskList")
    }
}

struct TaskRow: View {
    let task: TaskItem
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(task.title).font(.hcHeadline).foregroundStyle(Color.hcInk)
            Text("\(task.departmentName) · \(task.assigneeName ?? String(localized: "بلا مسؤول"))")
                .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
            HStack(spacing: Spacing.xs) {
                StatusBadge(text: task.status.title, tone: task.status.tone)
                if task.isOverdue(now: now) {
                    StatusBadge(text: String(localized: "متأخرة"), tone: .critical, symbol: "clock")
                }
                if let due = task.dueAt {
                    Text(HCFormat.date(due)).font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                }
            }
        }
        .padding(.vertical, Spacing.xxs)
        .accessibilityElement(children: .combine)
    }
}

struct TaskDetailView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    @State private var model: TaskDetailViewModel
    @State private var noteFor: TaskTransition?
    @State private var note = ""

    init(taskID: UUID, context: UserContext, dependencies: DependencyContainer) {
        self.context = context
        self.dependencies = dependencies
        _model = State(initialValue: TaskDetailViewModel(taskID: taskID, repository: dependencies.tasks))
    }

    var body: some View {
        Group {
            switch model.state {
            case .idle, .loading(nil):
                ProgressView()
            case .failed(let error, _):
                StateView(kind: error.code == .notFound ? .notFound : .error,
                          title: error.code == .notFound ? String(localized: "السجل غير متاح") : String(localized: "تعذر التحميل"),
                          message: error.userMessage) { Task { await model.load() } }
            case .loaded(let task), .loading(let task?):
                detail(task)
            }
        }
        .background(Color.hcBackground)
        .navigationTitle(String(localized: "تفاصيل المهمة"))
        .navigationBarTitleDisplayMode(.inline)
        .task { if case .idle = model.state { await model.load() } }
        .sheet(item: $noteFor) { transition in
            NoteSheet(title: transition.title, note: $note) {
                let text = note
                noteFor = nil
                Task { await model.perform(transition, note: text) }
            }
        }
    }

    private func detail(_ task: TaskItem) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(task.title).font(.hcTitle).foregroundStyle(Color.hcInk)
                    HStack {
                        StatusBadge(text: task.status.title, tone: task.status.tone)
                        if task.isOverdue(now: dependencies.clock.now()) {
                            StatusBadge(text: String(localized: "متأخرة"), tone: .critical, symbol: "clock")
                        }
                    }
                    .accessibilityIdentifier("taskStatus")
                    if !task.details.isEmpty { Text(task.details).font(.hcBody) }
                }
            }
            Section(String(localized: "المسؤولية والموعد")) {
                LabeledContent(String(localized: "القسم"), value: task.departmentName)
                LabeledContent(String(localized: "المسؤول"), value: task.assigneeName ?? "—")
                LabeledContent(String(localized: "الأولوية"), value: task.priority.title)
                if let due = task.dueAt { LabeledContent(String(localized: "الاستحقاق الحالي"), value: HCFormat.dateTime(due)) }
                if let original = task.originalDueAt, original != task.dueAt {
                    LabeledContent(String(localized: "الاستحقاق الأصلي"), value: HCFormat.dateTime(original))
                }
                if let first = task.firstSubmittedAt {
                    LabeledContent(String(localized: "أول رفع"), value: HCFormat.dateTime(first))
                }
            }
            if let error = model.actionError {
                Section { Label(error.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                    .accessibilityIdentifier("actionError")
            }
            if let confirmation = model.lastConfirmation {
                Section { Label(confirmation, systemImage: "checkmark.circle").foregroundStyle(Color.hcGood) }
            }
            let actions = task.availableTransitions(for: context)
            if !actions.isEmpty {
                Section(String(localized: "الإجراءات")) {
                    ForEach(actions, id: \.self) { transition in
                        Button {
                            if transition.requiresNote { note = ""; noteFor = transition }
                            else { Task { await model.perform(transition, note: nil) } }
                        } label: {
                            Text(transition.title).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(model.isSubmitting)
                        .accessibilityIdentifier("action.\(transition.rawValue)")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}

extension TaskTransition: Identifiable { var id: String { rawValue } }

struct NoteSheet: View {
    let title: String
    @Binding var note: String
    let confirm: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "الملاحظة (إلزامية)")) {
                    TextField(String(localized: "اكتب السبب أو الملاحظة"), text: $note, axis: .vertical)
                        .lineLimit(3...8)
                        .accessibilityIdentifier("noteField")
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "إلغاء")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "تأكيد"), action: confirm)
                        .disabled(note.trimmingCharacters(in: .whitespaces).count < 3)
                        .accessibilityIdentifier("confirmNote")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct NewTaskSheet: View {
    let context: UserContext
    let onCreated: (TaskItem) -> Void
    @State private var model: NewTaskViewModel
    @State private var confirmDiscard = false
    @State private var allDepartments: [Department] = []
    @Environment(\.dismiss) private var dismiss
    private let dependencies: DependencyContainer

    init(context: UserContext, dependencies: DependencyContainer, preselectedDepartment: UUID?, onCreated: @escaping (TaskItem) -> Void) {
        self.context = context
        self.dependencies = dependencies
        self.onCreated = onCreated
        _model = State(initialValue: NewTaskViewModel(tasks: dependencies.tasks, departments: dependencies.departments,
                                                      clock: dependencies.clock, preselectedDepartment: preselectedDepartment))
    }

    /// Departments the user may assign in: all for the director, headed ones otherwise.
    private struct DepartmentOption: Identifiable { let id: UUID; let name: String }

    private var departments: [DepartmentOption] {
        if context.isDirector {
            return allDepartments.filter { !$0.isArchived }.map { DepartmentOption(id: $0.id, name: $0.nameAr) }
        }
        return context.headedDepartments.map { DepartmentOption(id: $0.id, name: $0.nameAr) }
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker(String(localized: "القسم"), selection: $model.draft.departmentID) {
                        Text(String(localized: "اختر")).tag(UUID?.none)
                        ForEach(departments) { d in Text(d.name).tag(UUID?.some(d.id)) }
                    }
                    .accessibilityIdentifier("departmentPicker")
                    fieldError(.department)
                    Picker(String(localized: "المسؤول"), selection: $model.draft.assigneeID) {
                        Text(String(localized: "اختر")).tag(UUID?.none)
                        ForEach(model.assignees) { a in Text(a.name).tag(UUID?.some(a.id)) }
                    }
                    .disabled(model.draft.departmentID == nil)
                    .accessibilityIdentifier("assigneePicker")
                    fieldError(.assignee)
                }
                Section {
                    TextField(String(localized: "عنوان التكليف"), text: $model.draft.title)
                        .accessibilityIdentifier("titleField")
                    fieldError(.title)
                    TextField(String(localized: "المخرج المتوقع"), text: $model.draft.details, axis: .vertical).lineLimit(2...6)
                }
                Section {
                    DatePicker(String(localized: "موعد الاستحقاق"),
                               selection: Binding(get: { model.draft.dueDate ?? dependencies.clock.now().addingTimeInterval(7 * 86_400) },
                                                  set: { model.draft.dueDate = $0 }),
                               in: dependencies.clock.now()..., displayedComponents: .date)
                        .accessibilityIdentifier("duePicker")
                    Text(String(localized: "يُحتسب الموعد حتى نهاية اليوم بتوقيت المستشفى."))
                        .font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                    fieldError(.dueDate)
                    Picker(String(localized: "الأولوية"), selection: $model.draft.priority) {
                        ForEach(Priority.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                if let error = model.serverError {
                    Section { Label(error.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                }
            }
            .navigationTitle(String(localized: "تكليف جديد"))
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(model.hasChanges)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "إلغاء")) { if model.hasChanges { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "إسناد")) {
                        if model.draft.dueDate == nil { model.draft.dueDate = dependencies.clock.now().addingTimeInterval(7 * 86_400) }
                        Task { if let task = await model.save() { onCreated(task) } }
                    }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("saveTask")
                }
            }
            .confirmationDialog(String(localized: "تجاهل التغييرات؟"), isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button(String(localized: "تجاهل"), role: .destructive) { dismiss() }
            }
            .task { allDepartments = (try? await dependencies.departments.departments()) ?? [] }
            .task(id: model.draft.departmentID) { await model.loadAssignees() }
        }
    }

    @ViewBuilder private func fieldError(_ field: NewTaskDraft.Field) -> some View {
        if let message = model.fieldErrors[field] {
            Text(message).font(.hcCaption).foregroundStyle(Color.hcCritical)
                .accessibilityIdentifier("error.\(field.rawValue)")
        }
    }
}

struct AchievementsListView: View {
    let dependencies: DependencyContainer
    @Environment(PeriodSelection.self) private var periods
    @State private var state: LoadState<[AchievementItem]> = .idle

    var body: some View {
        List {
            switch state {
            case .idle, .loading: ProgressView().frame(maxWidth: .infinity)
            case .failed(let e, _): StateView(kind: .error, title: String(localized: "تعذر تحميل المنجزات"), message: e.userMessage)
            case .loaded(let items) where items.isEmpty: StateView(kind: .empty, title: String(localized: "لا توجد منجزات لهذه الفترة"))
            case .loaded(let items):
                ForEach(items) { a in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(a.title).font(.hcHeadline)
                        Text("\(a.departmentName) · \(a.periodTitle)").font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                        Text(a.impactSummary).font(.hcCallout)
                        StatusBadge(text: a.status == .approved ? String(localized: "معتمد") : String(localized: "بانتظار الاعتماد"),
                                    tone: a.status == .approved ? .good : .info)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        // Follows the period chosen on the dashboard; reloads when it changes.
        .task(id: periods.selectedID) {
            await periods.loadIfNeeded()
            guard let periodID = periods.selectedID else {
                if periods.hasLoaded { state = .loaded([]) }
                return
            }
            state = .loading(previous: nil)
            do { state = .loaded(try await dependencies.achievements.achievements(periodID: periodID)) }
            catch { state = .failed(error as? AppError ?? .network(offline: false), previous: nil) }
        }
    }
}
