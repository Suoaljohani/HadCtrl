import SwiftUI

/// Sheets are modelled as one enum so two can never open at once (spec §21).
enum SheetRoute: Identifiable, Hashable {
    case newTask(departmentID: UUID?)
    case settings
    var id: Self { self }
}

/// Five stable tabs, each with its own NavigationStack and path (spec §04).
struct MainTabView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    @Environment(SessionStore.self) private var session
    @State private var selection: AppTab = .home
    @State private var paths: [AppTab: NavigationPath] = Dictionary(uniqueKeysWithValues: AppTab.allCases.map { ($0, NavigationPath()) })
    @State private var sheet: SheetRoute?
    /// One per signed-in session: discarded with this view on sign-out (AC-025).
    @State private var periodSelection: PeriodSelection

    init(context: UserContext, dependencies: DependencyContainer) {
        self.context = context
        self.dependencies = dependencies
        _periodSelection = State(initialValue: PeriodSelection(repository: dependencies.dashboard))
    }

    var body: some View {
        TabView(selection: $selection) {
            tab(.home, title: String(localized: "الرئيسية"), symbol: "house") {
                DashboardView(context: context, dependencies: dependencies, open: open, present: { sheet = $0 })
            }
            tab(.departments, title: String(localized: "الأقسام"), symbol: "building.2") {
                DepartmentsView(dependencies: dependencies)
            }
            tab(.performance, title: String(localized: "الأداء"), symbol: "chart.bar") {
                PerformanceView(dependencies: dependencies)
            }
            tab(.execution, title: String(localized: "التنفيذ"), symbol: "checklist") {
                ExecutionView(context: context, dependencies: dependencies, present: { sheet = $0 })
            }
            tab(.reports, title: String(localized: "التقارير"), symbol: "doc.text") {
                ReportsView(dependencies: dependencies)
            }
        }
        .environment(periodSelection)
        .sheet(item: $sheet) { route in
            switch route {
            case .newTask(let dept):
                NewTaskSheet(context: context, dependencies: dependencies, preselectedDepartment: dept) { created in
                    sheet = nil
                    selection = .execution
                    paths[.execution, default: NavigationPath()].append(AppRoute.task(created.id))
                }
            case .settings:
                SettingsView(context: context, dependencies: dependencies)
            }
        }
        .onChange(of: session.pendingRoute) { _, route in
            guard let route else { return }
            session.pendingRoute = nil
            open(route)
        }
    }

    private func open(_ route: AppRoute) {
        let tab: AppTab
        switch route {
        case .department: tab = .departments
        case .goal, .indicator, .indicatorList: tab = .performance
        case .task, .achievement, .taskList: tab = .execution
        case .report, .reportList: tab = .reports
        }
        selection = tab
        paths[tab, default: NavigationPath()].append(route)
    }

    private func tab<Content: View>(_ tab: AppTab, title: String, symbol: String, @ViewBuilder content: () -> Content) -> some View {
        NavigationStack(path: Binding(get: { paths[tab] ?? NavigationPath() }, set: { paths[tab] = $0 })) {
            content()
                .navigationDestination(for: AppRoute.self) { route in
                    RouteDestination(route: route, context: context, dependencies: dependencies)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { sheet = .settings } label: {
                            Label(String(localized: "الإعدادات"), systemImage: "person.crop.circle")
                        }
                        .accessibilityIdentifier("settingsButton")
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
            ReportsView(dependencies: dependencies)
        case .indicatorList:
            PerformanceView(dependencies: dependencies)
        case .goal, .indicator, .report, .achievement:
            StateView(kind: .empty, title: String(localized: "هذه الشاشة قيد التنفيذ"),
                      message: String(localized: "ستُفعّل مع شريحة التقارير والمؤشرات."))
        }
    }
}
