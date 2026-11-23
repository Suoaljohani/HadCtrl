import SwiftUI

/// Director command center (spec §06): decisions first, then pulse, six
/// readings, departments. Every number opens the list it was counted from.
struct DashboardView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    let open: (AppRoute) -> Void
    let present: (SheetRoute) -> Void
    @State private var model: DashboardViewModel
    private let style = NumberStyle()

    init(context: UserContext, dependencies: DependencyContainer, open: @escaping (AppRoute) -> Void, present: @escaping (SheetRoute) -> Void) {
        self.context = context
        self.dependencies = dependencies
        self.open = open
        self.present = present
        _model = State(initialValue: DashboardViewModel(repository: dependencies.dashboard))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.l) {
                header
                if dependencies.environment.usesMockData { DemoDataBanner() }
                content
            }
            .padding(.horizontal, Spacing.m)
            .padding(.bottom, Spacing.xxl)
        }
        .background(Color.hcBackground)
        .refreshable { await model.refresh() }
        .navigationTitle(String(localized: "الرئيسية"))
        .toolbar {
            if context.canCreateAssignments {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { present(.newTask(departmentID: nil)) } label: {
                        Label(String(localized: "تكليف جديد"), systemImage: "plus.circle.fill")
                    }
                    .accessibilityIdentifier("newTaskButton")
                }
            }
        }
        .task { await model.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(context.organizationName).font(.hcHeadline).foregroundStyle(Color.hcInk)
            HStack {
                Text(HCFormat.date(Date())).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                Spacer()
                periodPicker
            }
        }
        .padding(.top, Spacing.xs)
    }

    @ViewBuilder private var periodPicker: some View {
        if !model.periods.isEmpty {
            Menu {
                ForEach(model.periods) { period in
                    Button(period.title) { model.select(periodID: period.id) }
                }
            } label: {
                Label(model.periods.first { $0.id == model.selectedPeriodID }?.title ?? String(localized: "الفترة"),
                      systemImage: "calendar")
                    .font(.hcFootnote)
            }
            .accessibilityIdentifier("periodPicker")
        }
    }

    @ViewBuilder private var content: some View {
        if let error = model.periodsError {
            StateView(kind: .error, title: String(localized: "تعذر تحميل الفترات"), message: error.userMessage) {
                Task { await model.start() }
            }
        } else {
            switch model.state {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                    .accessibilityLabel(String(localized: "جارٍ تحميل اللوحة"))
            case .failed(let error, _):
                StateView(kind: error == .network(offline: true) ? .offline : .error,
                          title: String(localized: "تعذر تحميل اللوحة"), message: error.userMessage) {
                    Task { await model.refresh() }
                }
                .accessibilityIdentifier("dashboardError")
            case .loaded(let snapshot):
                loaded(snapshot)
            }
        }
    }

    @ViewBuilder private func loaded(_ s: DashboardSnapshot) -> some View {
        Text(String(localized: "آخر تحديث \(HCFormat.dateTime(s.generatedAt))"))
            .font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
            .accessibilityIdentifier("generatedAt")

        // 1. Needs your decision
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader(title: String(localized: "تحتاج قرارك"))
            if s.topActions.isEmpty {
                HCCard {
                    Label(String(localized: "لا توجد إجراءات معلقة الآن."), systemImage: "checkmark.seal")
                        .font(.hcCallout).foregroundStyle(Color.hcGood)
                }
            } else {
                ForEach(s.topActions) { action in
                    Button { open(action.route) } label: { ActionRow(action: action) }
                        .buttonStyle(.plain)
                }
            }
        }
        .accessibilityIdentifier("decisionsSection")

        // 2. Pulse: measured result AND coverage, never one without the other (§11).
        HCCard(padding: Spacing.l) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(localized: "النتيجة المقاسة للمؤشرات")).font(.hcHeadline).foregroundStyle(Color.hcInk)
                Spacer()
                StatusBadge(text: s.verdict.title, tone: s.verdict.tone)
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                if let score = s.measuredScore, s.verdict != .insufficientData {
                    Text(style.percent(score)).font(.hcLargeTitle).monospacedDigit().foregroundStyle(Color.hcInk)
                } else {
                    Text(String(localized: "لا حكم إجمالي")).font(.hcTitle).foregroundStyle(Color.hcSecondaryText)
                }
            }
            Text(String(localized: "تغطية البيانات \(style.percent(s.coverage)) · الأقسام المحدّثة \(s.departmentsUpdated) من \(s.departmentsTotal)"))
                .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
            Text(String(localized: "تُحسب من درجات المؤشرات المعتمدة فقط بأوزانها؛ لا يصدر حكم إجمالي تحت تغطية ٨٠٪."))
                .font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pulseCard")

        // 3. Six readings
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Spacing.s)], spacing: Spacing.s) {
            ForEach(s.readings) { r in
                Button { open(r.route) } label: {
                    MetricTile(title: r.metric.title, numerator: r.numerator, denominator: r.denominator)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("reading.\(r.metric.rawValue)")
            }
        }

        // 4. Departments (vertical cards, no wide table on iPhone)
        SectionHeader(title: String(localized: "الأقسام"), trailing: String(localized: "\(s.departments.count) أقسام"))
        ForEach(s.departments) { pulse in
            Button { open(.department(pulse.department.id)) } label: { DepartmentPulseCard(pulse: pulse) }
                .buttonStyle(.plain)
        }
    }
}

struct ActionRow: View {
    let action: ActionItem

    var body: some View {
        HCCard {
            HStack(alignment: .top, spacing: Spacing.s) {
                Image(systemName: symbol).foregroundStyle(tone.color).font(.title3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(action.title).font(.hcHeadline).foregroundStyle(Color.hcInk)
                    Text("\(action.departmentName) · \(action.reason)").font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                    if let due = action.dueAt {
                        Text(String(localized: "الموعد \(HCFormat.date(due))")).font(.hcCaption).foregroundStyle(tone.color)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").foregroundStyle(Color.hcSecondaryText).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var symbol: String {
        switch action.kind {
        case .urgentBlocker: return "exclamationmark.octagon"
        case .overdueSubmission: return "clock.badge.exclamationmark"
        case .readyForApproval: return "checkmark.circle"
        case .dueSoon: return "calendar"
        }
    }

    private var tone: StatusTone {
        switch action.kind {
        case .urgentBlocker, .overdueSubmission: return .critical
        case .readyForApproval: return .info
        case .dueSoon: return .warning
        }
    }
}

struct DepartmentPulseCard: View {
    let pulse: DepartmentPulse
    private let style = NumberStyle()

    var body: some View {
        HCCard {
            HStack {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(pulse.department.nameAr).font(.hcHeadline).foregroundStyle(Color.hcInk)
                    Text(pulse.department.headName ?? String(localized: "لا يوجد رئيس نشط"))
                        .font(.hcFootnote).foregroundStyle(pulse.department.headName == nil ? Color.hcWarning : Color.hcSecondaryText)
                }
                Spacer()
                if pulse.overdueTasks > 0 {
                    StatusBadge(text: String(localized: "\(pulse.overdueTasks) متأخرة"), tone: .critical, symbol: "clock")
                }
            }
            HStack(spacing: Spacing.m) {
                Label(String(localized: "\(pulse.openTasks) مهام مفتوحة"), systemImage: "checklist")
                if let c = pulse.coverage {
                    Label(String(localized: "تغطية \(style.percent(c))"), systemImage: "chart.bar")
                } else {
                    Label(String(localized: "لم يُحدّث"), systemImage: "chart.bar")
                }
            }
            .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
