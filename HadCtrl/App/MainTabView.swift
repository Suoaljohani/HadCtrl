import SwiftUI

/// Sheets are modelled as one enum so two can never open at once (spec §21).
enum SheetRoute: Identifiable, Hashable {
    case newTask(departmentID: UUID?)
    case settings
    case inbox
    case search
    var id: Self { self }
}

/// Five stable tabs, each with its own NavigationStack and path (spec §04).
struct MainTabView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    let lock: AppLock
    @Environment(SessionStore.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.hcHapticsEnabled) private var haptics
    @State private var selection: AppTab
    @State private var paths: [AppTab: NavigationPath] = Dictionary(uniqueKeysWithValues: AppTab.allCases.map { ($0, NavigationPath()) })
    @State private var sheet: SheetRoute?
    /// One per signed-in session: discarded with this view on sign-out (AC-025).
    @State private var periodSelection: PeriodSelection
    @State private var inbox: InboxModel
    @State private var signatureGate: SignatureGate
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.hcMotionEnabled) private var motion
    /// Rows and details in a tab share this namespace for the zoom transition.
    @Namespace private var zoom
    /// Routes opened without an on-screen origin (inbox, links) use the standard push.
    @State private var pushedWithoutSource: Set<AppRoute> = []

    init(context: UserContext, dependencies: DependencyContainer, lock: AppLock, startTab: AppTab = .home) {
        self.context = context
        self.dependencies = dependencies
        self.lock = lock
        _selection = State(initialValue: startTab)
        _periodSelection = State(initialValue: PeriodSelection(repository: dependencies.dashboard))
        _inbox = State(initialValue: InboxModel(repository: dependencies.notifications))
        _signatureGate = State(initialValue: SignatureGate(repository: dependencies.signatures))
    }

    var body: some View {
        TabView(selection: $selection) {
            tab(.home, title: String(localized: "الرئيسية"), symbol: "house") {
                DashboardView(context: context, dependencies: dependencies, open: { push($0, in: .home) }, present: { sheet = $0 })
            }
            tab(.departments, title: String(localized: "الأقسام"), symbol: "building.2") {
                DepartmentsView(dependencies: dependencies)
            }
            tab(.performance, title: String(localized: "الأداء"), symbol: "chart.bar") {
                PerformanceView(context: context, dependencies: dependencies)
            }
            tab(.execution, title: String(localized: "التنفيذ"), symbol: "checklist") {
                ExecutionView(context: context, dependencies: dependencies, present: { sheet = $0 })
            }
            tab(.reports, title: String(localized: "التقارير"), symbol: "doc.text") {
                ReportsView(context: context, dependencies: dependencies)
            }
        }
        .environment(periodSelection)
        .environment(\.hcZoomNamespace, zoom)
        .environment(\.hcSignatureGate, signatureGate)
        .sheet(item: Binding(get: { signatureGate.current }, set: { signatureGate.current = $0 })) { request in
            SignatureSheet(request: request, gate: signatureGate, signerName: context.displayName)
                .presentationDetents([.large])
        }
        .sensoryFeedback(.selection, trigger: selection) { _, _ in haptics }
        .sheet(item: $sheet) { route in
            switch route {
            case .newTask(let dept):
                NewTaskSheet(context: context, dependencies: dependencies, preselectedDepartment: dept ?? preferences.defaultDepartmentID) { created in
                    sheet = nil
                    selection = .execution
                    paths[.execution, default: NavigationPath()].append(AppRoute.task(created.id))
                }
            case .settings:
                SettingsView(context: context, dependencies: dependencies, lock: lock)
            case .inbox:
                InboxView(model: inbox) { route in open(route) }
            case .search:
                SearchView(repository: dependencies.search, periodID: { [periodSelection] in periodSelection.selectedID }) { route in
                    open(route)
                }
            }
        }
        // No APNs (D-28): the unread count is refreshed while the app is open.
        .task { await inbox.poll() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await inbox.refreshCount() }
            case .background:
                DeviceAlerts.markSeen()        // what was on screen needs no alert
                DeviceAlerts.scheduleRefresh()
            default: break
            }
        }
        .task { await PushCenter.shared.attach(repository: dependencies.notifications) }
        .onChange(of: PushCenter.shared.pendingRoute) { _, route in
            guard let route else { return }
            PushCenter.shared.pendingRoute = nil
            open(route)
        }
        .onChange(of: session.pendingRoute) { _, route in
            guard let route else { return }
            session.pendingRoute = nil
            open(route)
        }
    }

    /// Opens a record from where the user is: the detail is pushed onto the
    /// current tab so Back returns to the same place (spec §04, connected details).
    private func push(_ route: AppRoute, in tab: AppTab) {
        pushedWithoutSource.remove(route)
        paths[tab, default: NavigationPath()].append(route)
    }

    /// Opens a record in its own tab (inbox, links): there is no on-screen origin.
    private func open(_ route: AppRoute) {
        let tab: AppTab
        switch route {
        case .department: tab = .departments
        case .goal, .indicator, .indicatorList, .goalList: tab = .performance
        case .task, .achievement, .taskList, .achievementList: tab = .execution
        case .report, .reportList: tab = .reports
        }
        selection = tab
        pushedWithoutSource.insert(route)
        paths[tab, default: NavigationPath()].append(route)
    }

    private func tab<Content: View>(_ tab: AppTab, title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: Binding(get: { paths[tab] ?? NavigationPath() }, set: { paths[tab] = $0 })) {
            content()
                .navigationDestination(for: AppRoute.self) { route in
                    RouteDestination(route: route, context: context, dependencies: dependencies)
                        .hcZoomDestination(route, in: zoom, enabled: motion && !pushedWithoutSource.contains(route))
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { sheet = .settings } label: {
                            InitialsAvatar(name: context.displayName, size: 30)
                        }
                        .accessibilityLabel(String(localized: "الإعدادات"))
                        .accessibilityIdentifier("settingsButton")
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        InboxButton(model: inbox) { sheet = .inbox }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button { sheet = .search } label: {
                            Label(String(localized: "البحث"), systemImage: "magnifyingglass")
                        }
                        .accessibilityIdentifier("searchButton")
                    }
                }
        }
        .tabItem { Label(title, systemImage: symbol) }
        .tag(tab)
        .accessibilityIdentifier("tab.\(tab.rawValue)")
    }
}

/// Resolves a route to the screen that loads the authorized record by id.
struct RouteDestination: View {
    let route: AppRoute
    let context: UserContext
    let dependencies: DependencyContainer

    var body: some View {
        switch route {
        case .task(let id):
            TaskDetailView(taskID: id, context: context, dependencies: dependencies)
        case .taskList(let filter):
            TaskListView(context: context, dependencies: dependencies, initialFilter: filter)
        case .department(let id):
            DepartmentDetailView(departmentID: id, context: context, dependencies: dependencies)
        case .reportList:
            ReportsView(context: context, dependencies: dependencies)
        case .indicatorList:
            PerformanceView(context: context, dependencies: dependencies)
        case .goalList:
            PerformanceView(context: context, dependencies: dependencies, initialSegment: .goals)
        case .goal(let id):
            GoalDetailView(goalID: id, context: context, dependencies: dependencies)
        case .report(let id):
            ReportDetailView(reportID: id, context: context, dependencies: dependencies)
        case .indicator(let id, let periodID):
            IndicatorDetailView(definitionID: id, periodID: periodID, context: context, dependencies: dependencies)
        case .achievement(let id):
            AchievementDetailView(achievementID: id, context: context, dependencies: dependencies)
        case .achievementList:
            AchievementsListView(context: context, dependencies: dependencies)
                .navigationTitle(String(localized: "المنجزات"))
        }
    }
}
