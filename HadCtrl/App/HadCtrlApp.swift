import SwiftUI

@main
struct HadCtrlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session: SessionStore
    @State private var preferences: AppPreferences
    @State private var lock: AppLock
    private let dependencies: DependencyContainer

    init() {
        let environment = AppEnvironment.resolve()
        let deps = DependencyContainer.make(environment: environment)
        dependencies = deps
        _session = State(initialValue: SessionStore(repository: deps.session))
        // UI tests get a fresh, throw-away preference store on every launch.
        let defaults: UserDefaults
        if environment == .uiTesting, let suite = UserDefaults(suiteName: "hc.uitesting") {
            suite.removePersistentDomain(forName: "hc.uitesting")
            defaults = suite
        } else {
            defaults = .standard
        }
        let prefs = AppPreferences(defaults: defaults)
        _preferences = State(initialValue: prefs)
        _lock = State(initialValue: AppLock(preferences: prefs, enabled: environment != .uiTesting))
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
            RootView(dependencies: dependencies, lock: lock)
                .environment(session)
                .environment(preferences)
                .tint(Color.hcPrimary)
                .preferredColorScheme(Self.forcedScheme(dependencies.environment))
                .onChange(of: preferences.appearance, initial: true) { _, mode in
                    if Self.forcedScheme(dependencies.environment) == nil { WindowAppearance.apply(mode) }
                }
                // UI tests run without decorative motion so they see the final layout;
                // users can also turn decorative motion off in Settings.
                .modifier(MotionPolicy(allowMotion: dependencies.environment != .uiTesting && !preferences.reduceMotion))
                .environment(\.hcHapticsEnabled, preferences.haptics)
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
    let lock: AppLock
    @Environment(SessionStore.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase

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
                MainTabView(context: ctx, dependencies: dependencies, lock: lock, startTab: preferences.startTab)
                    .overlay {
                        if lock.isLocked {
                            LockScreen(lock: lock).transition(.opacity).zIndex(1)
                        }
                    }
            case .mustChangePassword:
                ChangePasswordView()
            }
        }
        .task { await session.restore() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: lock.didEnterBackground()
            case .active: lock.willEnterForeground()
            default: break
            }
        }
        .onOpenURL { url in
            guard let route = AppRoute(url: url) else { return }
            session.pendingRoute = route
        }
    }
}

/// Applies the in-app appearance to every window, sheets included, immediately.
enum WindowAppearance {
    @MainActor static func apply(_ mode: AppearanceMode) {
        let style: UIUserInterfaceStyle = switch mode {
            case .system: .unspecified
            case .light: .light
            case .dark: .dark
        }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}
