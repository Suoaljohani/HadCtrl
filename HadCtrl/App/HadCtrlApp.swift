import SwiftUI

@main
struct HadCtrlApp: App {
    @State private var session: SessionStore
    private let dependencies: DependencyContainer

    init() {
        let environment = AppEnvironment.resolve()
        let deps = DependencyContainer.make(environment: environment)
        dependencies = deps
        _session = State(initialValue: SessionStore(repository: deps.session))
    }

    /// Screenshot runs force an appearance; never honoured in production.
    private static func forcedScheme(_ env: AppEnvironment) -> ColorScheme? {
        guard env.usesMockData else { return nil }
        switch ProcessInfo.processInfo.environment["HC_FORCE_SCHEME"] {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(dependencies: dependencies)
                .environment(session)
                .tint(Color.hcPrimary)
                .preferredColorScheme(Self.forcedScheme(dependencies.environment))
        }
        // iOS-scheduled refresh (D-30): reads the inbox, posts generic local alerts.
        .backgroundTask(.appRefresh(DeviceAlerts.refreshTaskID)) { [dependencies] in
            DeviceAlerts.scheduleRefresh()
            await DeviceAlerts.deliverNew(using: dependencies.notifications)
        }
    }
}

struct RootView: View {
    let dependencies: DependencyContainer
    @Environment(SessionStore.self) private var session

    var body: some View {
        Group {
            switch session.phase {
            case .checking:
                ProgressView(String(localized: "جارٍ التحقق من الجلسة…"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.hcBackground)
            case .signedOut(let message):
                SignInView(message: message)
            case .noActiveMembership:
                AccessDeniedView()
            case .configurationError(let detail):
                StateView(kind: .error, title: String(localized: "إعداد غير مكتمل"),
                          message: AppError.configuration(detail).userMessage)
            case .ready(let ctx):
                MainTabView(context: ctx, dependencies: dependencies)
            case .mustChangePassword:
                ChangePasswordView()
            }
        }
        .task { await session.restore() }
        .onOpenURL { url in
            guard let route = AppRoute(url: url) else { return }
            session.pendingRoute = route
        }
    }
}
