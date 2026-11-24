import SwiftUI

/// Director command center (spec §06): decisions first by default, then pulse,
/// six readings, departments — in the order the director chose (D-35). Every
/// number opens the list it was counted from.
///
/// Scroll story (DESIGN_DIRECTION §2): the hospital photo sits behind a parallax
/// hero that stretches on pull-down and drifts slower than the content; the
/// content rises over it as a sheet, and each card settles in as it enters.
struct DashboardView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    let open: (AppRoute) -> Void
    let present: (SheetRoute) -> Void
    @State private var model: DashboardViewModel
    @State private var customizing = false
    @Environment(PeriodSelection.self) private var periods
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.hcMotionEnabled) private var motion

    init(context: UserContext, dependencies: DependencyContainer, open: @escaping (AppRoute) -> Void, present: @escaping (SheetRoute) -> Void) {
        self.context = context
        self.dependencies = dependencies
        self.open = open
        self.present = present
        _model = State(initialValue: DashboardViewModel(repository: dependencies.dashboard))
    }

    /// Which body is on screen; animating on it cross-fades skeleton → content.
    private enum Phase: Hashable { case skeleton, content, error, empty }

    private var phase: Phase {
        if periods.error != nil { return .error }
        if periods.hasLoaded && periods.periods.isEmpty { return .empty }
        switch model.state {
        case .idle, .loading(nil): return .skeleton
        case .failed(_, nil): return .error
        default: return .content
        }
    }

    var body: some View {
        ScrollView {
            // Eager stack: the dashboard is bounded (≤3 actions, 6 readings, departments),
            // and every item must exist for VoiceOver and UI tests, not only once scrolled into view.
            VStack(spacing: 0) {
                DashboardHero(context: context, periods: periods)
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if dependencies.environment.usesMockData { DemoDataBanner() }
                    content
                }
                .padding(.horizontal, Spacing.m)
                .padding(.top, Spacing.l)
                .padding(.bottom, Spacing.xxl)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.hcBackground,
                            in: UnevenRoundedRectangle(topLeadingRadius: Radius.largeCard, topTrailingRadius: Radius.largeCard,
                                                       style: .continuous))
                .padding(.top, -Radius.largeCard)
                .animation(motion ? HCMotion.smooth : nil, value: phase)
                .animation(motion ? HCMotion.smooth : nil, value: preferences.dashboard)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Color.hcBackground)
        .refreshable { await model.refresh() }
        .navigationTitle(String(localized: "الرئيسية"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if context.canCreateAssignments {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { present(.newTask(departmentID: nil)) } label: {
                        Label(String(localized: "تكليف جديد"), systemImage: "plus")
                    }
                    .accessibilityIdentifier("newTaskButton")
                }
            }
        }
        .sheet(isPresented: $customizing) {
            NavigationStack {
                DashboardCustomizeView()
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "تم")) { customizing = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .task { await periods.loadIfNeeded() }
        .onChange(of: periods.selectedID, initial: true) { _, id in
            if let id, id != model.selectedPeriodID { model.select(periodID: id) }
        }
    }

    @ViewBuilder private var content: some View {
        if let error = periods.error {
            StateView(kind: .error, title: String(localized: "تعذر تحميل الفترات"), message: error.userMessage) {
                Task { await periods.reload() }
            }
        } else if periods.hasLoaded && periods.periods.isEmpty {
            StateView(kind: .empty, title: String(localized: "لا توجد فترات تقارير معرّفة بعد"),
                      message: String(localized: "يُنشئ مدير النظام الفترات قبل بدء المتابعة."))
        } else {
            switch model.state {
            case .idle, .loading(nil):
                DashboardSkeleton().transition(.opacity)
            case .loading(let snapshot?):
                loaded(snapshot, refreshing: true)
            case .failed(let error, nil):
                StateView(kind: error == .network(offline: true) ? .offline : .error,
                          title: String(localized: "تعذر تحميل اللوحة"), message: error.userMessage) {
                    Task { await model.refresh() }
                }
                .accessibilityIdentifier("dashboardError")
            case .failed(let error, let snapshot?):
                StaleDataNotice(error: error, generatedAt: snapshot.generatedAt) { Task { await model.refresh() } }
                loaded(snapshot, refreshing: false)
            case .loaded(let snapshot):
                loaded(snapshot, refreshing: false)
            }
        }
    }

    @ViewBuilder private func loaded(_ s: DashboardSnapshot, refreshing: Bool) -> some View {
        HStack(spacing: Spacing.xs) {
            if refreshing { ProgressView().controlSize(.mini).accessibilityHidden(true) }
            Text(String(localized: "آخر تحديث \(HCFormat.dateTime(s.generatedAt))"))
                .font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                .accessibilityIdentifier("generatedAt")
            Spacer(minLength: 0)
            if context.isDirector {
                Button { customizing = true } label: {
                    Label(String(localized: "تخصيص"), systemImage: "slider.horizontal.3")
                        .font(.hcCaption.weight(.semibold))
                }
                .buttonStyle(.bordered).controlSize(.small).buttonBorderShape(.capsule)
                .accessibilityIdentifier("dashboard.customize")
            }
        }
        .hcEntrance(0)

        ForEach(Array(preferences.dashboard.visible.enumerated()), id: \.element) { index, module in
            moduleView(module, s)
                .hcEntrance(index + 1)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    @ViewBuilder private func moduleView(_ module: DashboardModule, _ s: DashboardSnapshot) -> some View {
        switch module {
        case .decisions:
            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionHeader(title: String(localized: "تحتاج قرارك"),
                              trailing: s.topActions.isEmpty ? nil : String(localized: "\(s.topActions.count) بنود"),
                              symbol: "bell.badge")
                if s.topActions.isEmpty {
                    HCCard {
                        HStack(spacing: Spacing.s) {
                            IconBadge(symbol: "checkmark.seal.fill", tone: .good)
                            Text(String(localized: "لا توجد إجراءات معلقة الآن.")).font(.hcCallout).foregroundStyle(Color.hcInk)
                        }
                    }
                    .hcScrollReveal()
                } else {
                    ForEach(s.topActions) { action in
                        Button { open(action.route) } label: { ActionRow(action: action) }
                            .buttonStyle(.hcCard)
                            .hcZoomSourceInEnvironment(action.route)
                            .hcScrollReveal()
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("decisionsSection")
        case .pulse:
            // Measured result AND coverage, never one without the other (§11).
            PulseCard(snapshot: s).hcScrollReveal()
        case .readings:
            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionHeader(title: String(localized: "قراءات الفترة"), symbol: "square.grid.2x2")
                ReadingsGrid(readings: s.readings, compact: preferences.dashboard.compactReadings, open: open)
            }
        case .departments:
            // Vertical cards, no wide table on iPhone.
            VStack(alignment: .leading, spacing: Spacing.s) {
                SectionHeader(title: String(localized: "الأقسام"), trailing: String(localized: "\(s.departments.count) أقسام"),
                              symbol: "building.2")
                ForEach(s.departments) { pulse in
                    let route = AppRoute.department(pulse.department.id)
                    Button { open(route) } label: { DepartmentPulseCard(pulse: pulse) }
                        .buttonStyle(.hcCard)
                        .hcZoomSourceInEnvironment(route)
                        .hcScrollReveal()
                }
            }
        }
    }
}

// MARK: - Hero

/// The hospital photo with greeting, organization and period. The photo drifts at
/// a third of the scroll speed and stretches on pull-down; plain brand colour
/// under Reduce Transparency, static under reduced motion.
private struct DashboardHero: View {
    let context: UserContext
    let periods: PeriodSelection
    @Environment(\.hcMotionEnabled) private var motion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var greeting: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = HospitalCalendar.riyadh.timeZone
        let hour = calendar.component(.hour, from: Date())
        return hour < 12 ? String(localized: "صباح الخير") : String(localized: "مساء الخير")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .center, spacing: Spacing.s) {
                InitialsAvatar(name: context.displayName, size: 46)
                    .background(Circle().fill(Color.hcSurface))
                VStack(alignment: .leading, spacing: 2) {
                    // Verbatim keeps the line right-to-left in Arabic; the separator follows the UI language.
                    Text(verbatim: greeting + (Bundle.main.preferredLocalizations.first == "en" ? ", " : "، ") + context.displayName)
                        .font(.hcFootnote).foregroundStyle(.white.opacity(0.9))
                        .lineLimit(2)
                    Text(context.organizationName)
                        .font(.hcTitle).foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            PeriodBar(periods: periods)
        }
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .padding(.horizontal, Spacing.m)
        .padding(.top, 130)
        .padding(.bottom, Spacing.l + Radius.largeCard)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) { backdrop }
    }

    @ViewBuilder private var backdrop: some View {
        let animate = motion
        ZStack {
            Color.hcInk
            if !reduceTransparency {
                Image("HCHeroBuilding")
                    .resizable()
                    .scaledToFill()
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .clipped()
                    .accessibilityHidden(true)
                    .visualEffect { content, proxy in
                        let minY = proxy.frame(in: .scrollView).minY
                        let pull = max(minY, 0)
                        return content
                            .scaleEffect(animate ? 1 + pull / 320 : 1, anchor: .bottom)
                            .offset(y: animate ? (minY > 0 ? -minY / 2 : -minY * 0.35) : 0)
                    }
                LinearGradient(stops: [.init(color: Color.hcInk.opacity(0.10), location: 0),
                                       .init(color: Color.hcInk.opacity(0.25), location: 0.35),
                                       .init(color: Color.hcInk.opacity(0.85), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            ChevronMotif(spacing: 54).stroke(Color.white.opacity(0.05), lineWidth: 1)
        }
    }
}

/// Today's date and the period selector as one control row on the hero.
private struct PeriodBar: View {
    let periods: PeriodSelection
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.s))
            : AnyLayout(HStackLayout(spacing: Spacing.s))
        layout {
            Label(HCFormat.date(Date()), systemImage: "calendar")
                .font(.hcFootnote).foregroundStyle(.white.opacity(0.9))
                .labelStyle(.titleAndIcon)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            if !periods.periods.isEmpty {
                Menu {
                    ForEach(periods.periods) { period in
                        Button { periods.selectedID = period.id } label: {
                            if period.id == periods.selectedID {
                                Label(period.title, systemImage: "checkmark")
                            } else {
                                Text(period.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: Spacing.xxs) {
                        Image(systemName: "calendar.badge.clock").accessibilityHidden(true)
                        Text(periods.selected?.title ?? String(localized: "الفترة"))
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold)).accessibilityHidden(true)
                    }
                    .font(.hcFootnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.s)
                    .padding(.vertical, Spacing.xs)
                    .hcGlassCapsule()
                    .contentShape(Capsule())
                }
                .accessibilityLabel(String(localized: "الفترة: \(periods.selected?.title ?? "")"))
                .accessibilityIdentifier("periodPicker")
            }
        }
    }
}

/// Shown above the last loaded snapshot of the same period when a refresh fails.
private struct StaleDataNotice: View {
    let error: AppError
    let generatedAt: Date
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: error == .network(offline: true) ? "wifi.slash" : "exclamationmark.triangle")
                .foregroundStyle(Color.hcWarning).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(localized: "تعذر التحديث")).font(.hcSubheadlineBold).foregroundStyle(Color.hcInk)
                Text(String(localized: "تُعرض آخر بيانات محمّلة لهذه الفترة (\(HCFormat.dateTime(generatedAt))). \(error.userMessage)"))
                    .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(String(localized: "إعادة المحاولة"), action: retry).font(.hcFootnote.weight(.semibold))
        }
        .padding(Spacing.s)
        .background(Color.hcWarning.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dashboardStale")
    }
}

// MARK: - Pulse

/// Score ring + coverage. A score is shown only when coverage allows a verdict;
/// otherwise the ring is empty and says so (missing data is not zero).
private struct PulseCard: View {
    let snapshot: DashboardSnapshot
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme
    private let style = NumberStyle()

    private var score: Decimal? {
        snapshot.verdict == .insufficientData ? nil : snapshot.measuredScore
    }

    private func fraction(_ d: Decimal) -> Double { NSDecimalNumber(decimal: d).doubleValue / 100 }

    var body: some View {
        let s = snapshot
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.l))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.l))
        VStack(alignment: .leading, spacing: Spacing.m) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    Text(String(localized: "النتيجة المقاسة للمؤشرات")).font(.hcHeadline).foregroundStyle(Color.hcInk)
                        .fixedSize()
                    Spacer(minLength: Spacing.xs)
                    StatusBadge(text: s.verdict.title, tone: s.verdict.tone).fixedSize()
                }
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "النتيجة المقاسة للمؤشرات")).font(.hcHeadline).foregroundStyle(Color.hcInk)
                        .fixedSize(horizontal: false, vertical: true)
                    StatusBadge(text: s.verdict.title, tone: s.verdict.tone)
                }
            }
            layout {
                ScoreRing(fraction: score.map { fraction($0) }, tone: s.verdict.tone == .neutral ? .info : s.verdict.tone, lineWidth: 11) {
                    VStack(spacing: 0) {
                        if let score {
                            Text(style.percent(score)).font(.hcLargeTitle).monospacedDigit().foregroundStyle(Color.hcInk)
                                .minimumScaleFactor(0.6).lineLimit(1)
                                .hcNumeric(score)
                        } else {
                            Text(String(localized: "لا حكم إجمالي")).font(.hcFootnote.weight(.semibold))
                                .foregroundStyle(Color.hcSecondaryText).multilineTextAlignment(.center)
                        }
                    }
                    .padding(Spacing.s)
                }
                .frame(width: 128, height: 128)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(String(localized: "تغطية البيانات")).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                    Text(style.percent(s.coverage)).font(.hcTitleNumber).monospacedDigit().foregroundStyle(Color.hcInk)
                        .hcNumeric(s.coverage)
                    ProgressTrack(fraction: fraction(s.coverage), tone: s.coverage >= 80 ? .good : .warning)
                    if let updated = s.departmentsUpdated, let total = s.departmentsTotal {
                        Text(String(localized: "الأقسام المحدّثة \(updated) من \(total)"))
                            .font(.hcFootnote).monospacedDigit().foregroundStyle(Color.hcSecondaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(String(localized: "تُحسب من درجات المؤشرات المعتمدة فقط بأوزانها؛ لا يصدر حكم إجمالي تحت تغطية ٨٠٪."))
                .font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Radius.largeCard, style: .continuous)
                .fill(Color.hcSurface)
                .overlay(
                    LinearGradient(colors: [Color.hcHighlight.opacity(scheme == .dark ? 0.18 : 0.32), .clear],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.largeCard, style: .continuous))
                )
        }
        .overlay(RoundedRectangle(cornerRadius: Radius.largeCard, style: .continuous)
            .strokeBorder(Color.hcSeparator, lineWidth: 0.5))
        .shadow(color: Elevation.shadow(scheme), radius: Elevation.radius, x: 0, y: Elevation.y)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pulseCard")
    }
}

// MARK: - Rows and tiles

struct ActionRow: View {
    let action: ActionItem

    var body: some View {
        HCCard(radius: Radius.row) {
            HStack(alignment: .center, spacing: Spacing.s) {
                IconBadge(symbol: symbol, tone: tone, size: 38)
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title).font(.hcHeadline).foregroundStyle(Color.hcInk)
                        .multilineTextAlignment(.leading)
                    Text(action.reason).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                    Label(action.departmentName, systemImage: "building.2")
                        .font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                    if let due = action.dueAt {
                        Label(String(localized: "الموعد \(HCFormat.date(due))"), systemImage: "clock")
                            .font(.hcCaption.weight(.semibold)).foregroundStyle(tone.color)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.hcSecondaryText.opacity(0.7)).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var symbol: String {
        switch action.kind {
        case .urgentBlocker: return "exclamationmark.octagon.fill"
        case .overdueSubmission: return "clock.badge.exclamationmark.fill"
        case .readyForApproval: return "checkmark.circle.fill"
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
        HCCard(radius: Radius.row) {
            HStack(alignment: .top, spacing: Spacing.s) {
                IconBadge(symbol: "building.2.fill", tone: .info, size: 36)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(pulse.department.nameAr).font(.hcHeadline).foregroundStyle(Color.hcInk)
                    if let head = pulse.department.headName {
                        Text(head).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                    } else if pulse.department.headVisible {
                        Text(String(localized: "لا يوجد رئيس نشط")).font(.hcFootnote).foregroundStyle(Color.hcWarning)
                    }
                }
                Spacer(minLength: 0)
                if pulse.overdueTasks > 0 {
                    StatusBadge(text: String(localized: "\(pulse.overdueTasks) متأخرة"), tone: .critical, symbol: "clock")
                }
            }
            HStack(spacing: Spacing.m) {
                Label(String(localized: "\(pulse.openTasks) مهام مفتوحة"), systemImage: "checklist")
                Spacer(minLength: 0)
                if let c = pulse.coverage {
                    Text(String(localized: "تغطية \(style.percent(c))")).monospacedDigit()
                } else {
                    Text(String(localized: "لم يُحدّث"))
                }
            }
            .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
            ProgressTrack(fraction: pulse.coverage.map { NSDecimalNumber(decimal: $0).doubleValue / 100 },
                          tone: (pulse.coverage ?? 0) >= 80 ? .good : .warning, height: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

extension DashboardReading.Metric {
    var symbol: String {
        switch self {
        case .goalsAchieved: return "target"
        case .indicatorsUpdated: return "chart.line.uptrend.xyaxis"
        case .reportsReceived: return "doc.text.fill"
        case .tasksCompleted: return "checkmark.circle.fill"
        case .achievementsApproved: return "rosette"
        case .awaitingDirector: return "tray.full.fill"
        }
    }

    var tone: StatusTone {
        switch self {
        case .awaitingDirector: return .warning
        case .achievementsApproved, .tasksCompleted: return .good
        default: return .info
        }
    }
}

/// Six readings in two columns, or one column at accessibility text sizes (§20).
/// Built eagerly so every tile is in the accessibility tree.
struct ReadingsGrid: View {
    let readings: [DashboardReading]
    var compact = false
    let open: (AppRoute) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    private var rows: [[DashboardReading]] {
        let perRow = typeSize.isAccessibilitySize ? 1 : 2
        return stride(from: 0, to: readings.count, by: perRow).map { Array(readings[$0..<min($0 + perRow, readings.count)]) }
    }

    var body: some View {
        VStack(spacing: Spacing.s) {
            ForEach(rows, id: \.first?.id) { row in
                HStack(alignment: .top, spacing: Spacing.s) {
                    ForEach(row) { r in
                        let tile = MetricTile(title: r.metric.title, numerator: r.numerator, denominator: r.denominator,
                                              tone: r.metric.tone, symbol: r.metric.symbol, compact: compact)
                        Button { open(r.route) } label: { tile }
                            .buttonStyle(.hcCard)
                            .hcZoomSourceInEnvironment(r.route)
                            .accessibilityLabel(tile.accessibilityText)
                            .accessibilityIdentifier("reading.\(r.metric.rawValue)")
                    }
                    if row.count == 1 && !typeSize.isAccessibilitySize {
                        Color.clear.frame(maxWidth: .infinity).accessibilityHidden(true)
                    }
                }
                .hcScrollReveal()
            }
        }
    }
}

// MARK: - Skeleton

/// The dashboard's shape while the first snapshot loads: no numbers, no flicker.
private struct DashboardSkeleton: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            SkeletonBar(width: 140, height: 10)
            VStack(alignment: .leading, spacing: Spacing.s) {
                SkeletonBar(width: 110, height: 16)
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: Spacing.s) {
                        Circle().fill(Color.hcSeparator.opacity(0.7)).frame(width: 38, height: 38)
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            SkeletonBar(width: 200, height: 14)
                            SkeletonBar(width: 140, height: 10)
                        }
                    }
                    .padding(Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hcSurface(radius: Radius.row, scheme: scheme)
                }
            }
            HStack(spacing: Spacing.l) {
                Circle().stroke(Color.hcSeparator.opacity(0.8), lineWidth: 11).frame(width: 128, height: 128)
                VStack(alignment: .leading, spacing: Spacing.s) {
                    SkeletonBar(width: 90, height: 10)
                    SkeletonBar(width: 70, height: 22)
                    SkeletonBar(height: 6)
                }
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hcSurface(radius: Radius.largeCard, scheme: scheme)
            Grid(horizontalSpacing: Spacing.s, verticalSpacing: Spacing.s) {
                ForEach(0..<2, id: \.self) { _ in
                    GridRow {
                        ForEach(0..<2, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: Spacing.s) {
                                Circle().fill(Color.hcSeparator.opacity(0.7)).frame(width: 28, height: 28)
                                SkeletonBar(width: 90, height: 10)
                                SkeletonBar(width: 50, height: 20)
                            }
                            .padding(Spacing.s + 2)
                            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                            .hcSurface(radius: Radius.row, scheme: scheme)
                        }
                    }
                }
            }
        }
        .hcShimmer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "جارٍ تحميل اللوحة"))
        .accessibilityIdentifier("dashboardSkeleton")
    }
}

extension View {
    /// Zoom origin using the tab's namespace from the environment.
    func hcZoomSourceInEnvironment(_ route: AppRoute) -> some View { modifier(ZoomSourceFromEnvironment(route: route)) }
}

private struct ZoomSourceFromEnvironment: ViewModifier {
    let route: AppRoute
    @Environment(\.hcZoomNamespace) private var namespace
    func body(content: Content) -> some View { content.hcZoomSource(route, in: namespace) }
}
