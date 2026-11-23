import SwiftUI
import Observation

// Per-device user preferences (D-35). Stored in UserDefaults: they shape the
// app's presentation only — never authorization, roles or data, which stay on
// the server.

enum AppearanceMode: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "تلقائي")
        case .light: return String(localized: "نهاري")
        case .dark: return String(localized: "ليلي")
        }
    }
    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, ar, en
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return String(localized: "لغة الجهاز")
        case .ar: return "العربية"
        case .en: return "English"
        }
    }
}

/// Dashboard modules a director can order and hide. "Needs your decision" can be
/// moved but not hidden: the spec puts pending decisions first in importance (§06).
enum DashboardModule: String, CaseIterable, Codable, Identifiable, Sendable {
    case decisions, pulse, readings, departments
    var id: String { rawValue }
    var title: String {
        switch self {
        case .decisions: return String(localized: "تحتاج قرارك")
        case .pulse: return String(localized: "النتيجة المقاسة والتغطية")
        case .readings: return String(localized: "قراءات الفترة")
        case .departments: return String(localized: "الأقسام")
        }
    }
    var symbol: String {
        switch self {
        case .decisions: return "bell.badge.fill"
        case .pulse: return "gauge.with.dots.needle.67percent"
        case .readings: return "square.grid.2x2.fill"
        case .departments: return "building.2.fill"
        }
    }
    var canHide: Bool { self != .decisions }
}

struct DashboardLayout: Codable, Equatable, Sendable {
    var order: [DashboardModule] = DashboardModule.allCases
    var hidden: Set<DashboardModule> = []
    /// Compact reading tiles (no progress tracks, tighter spacing).
    var compactReadings = false

    static let standard = DashboardLayout()

    var visible: [DashboardModule] { normalized.order.filter { !hidden.contains($0) || !$0.canHide } }

    /// Adds modules introduced after the layout was saved and drops unknown ones.
    var normalized: DashboardLayout {
        var copy = self
        var seen = Set<DashboardModule>()
        copy.order = order.filter { seen.insert($0).inserted }
        for m in DashboardModule.allCases where !seen.contains(m) { copy.order.append(m) }
        copy.hidden = hidden.filter(\.canHide)
        return copy
    }
}

@MainActor
@Observable
final class AppPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }
    var language: AppLanguage { didSet { applyLanguage() } }
    var appLock: Bool { didSet { defaults.set(appLock, forKey: Keys.appLock) } }
    /// Seconds in the background before the lock is required again.
    var lockGrace: Int { didSet { defaults.set(lockGrace, forKey: Keys.lockGrace) } }
    var haptics: Bool { didSet { defaults.set(haptics, forKey: Keys.haptics) } }
    var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: Keys.reduceMotion) } }
    var latinDigits: Bool { didSet { defaults.set(latinDigits, forKey: Keys.latinDigits) } }
    var startTab: AppTab { didSet { defaults.set(startTab.rawValue, forKey: Keys.startTab) } }
    var dashboard: DashboardLayout { didSet { save(dashboard) } }
    /// Department preselected when a head with several departments creates a task.
    var defaultDepartmentID: UUID? { didSet { defaults.set(defaultDepartmentID?.uuidString, forKey: Keys.defaultDepartment) } }
    /// The language the running process uses; a change applies on the next launch.
    @ObservationIgnored let launchLanguage: AppLanguage

    enum Keys {
        static let appearance = "hc.pref.appearance", language = "hc.pref.language", appLock = "hc.pref.appLock"
        static let lockGrace = "hc.pref.lockGrace", haptics = "hc.pref.haptics", reduceMotion = "hc.pref.reduceMotion"
        static let latinDigits = "hc.pref.latinDigits", startTab = "hc.pref.startTab", dashboard = "hc.pref.dashboard"
        static let defaultDepartment = "hc.pref.defaultDepartment"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        let lang = AppLanguage(rawValue: defaults.string(forKey: Keys.language) ?? "") ?? .system
        language = lang
        launchLanguage = lang
        appLock = defaults.bool(forKey: Keys.appLock)
        lockGrace = defaults.object(forKey: Keys.lockGrace) as? Int ?? 60
        haptics = defaults.object(forKey: Keys.haptics) as? Bool ?? true
        reduceMotion = defaults.bool(forKey: Keys.reduceMotion)
        latinDigits = defaults.bool(forKey: Keys.latinDigits)
        startTab = AppTab(rawValue: defaults.string(forKey: Keys.startTab) ?? "") ?? .home
        if let data = defaults.data(forKey: Keys.dashboard),
           let layout = try? JSONDecoder().decode(DashboardLayout.self, from: data) {
            dashboard = layout.normalized
        } else {
            dashboard = .standard
        }
        defaultDepartmentID = defaults.string(forKey: Keys.defaultDepartment).flatMap(UUID.init(uuidString:))
    }

    var languageNeedsRestart: Bool { language != launchLanguage }

    func resetDashboard() { dashboard = .standard }

    private func save(_ layout: DashboardLayout) {
        if let data = try? JSONEncoder().encode(layout) { defaults.set(data, forKey: Keys.dashboard) }
    }

    /// iOS reads `AppleLanguages` at launch; the choice applies after a relaunch.
    private func applyLanguage() {
        defaults.set(language.rawValue, forKey: Keys.language)
        switch language {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .ar: defaults.set(["ar"], forKey: "AppleLanguages")
        case .en: defaults.set(["en"], forKey: "AppleLanguages")
        }
        if language == .en, defaults.object(forKey: Keys.latinDigits) == nil { latinDigits = true }
    }
}

private struct HapticsEnabledKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// The in-app haptics switch (outcome and tab feedback).
    var hcHapticsEnabled: Bool {
        get { self[HapticsEnabledKey.self] }
        set { self[HapticsEnabledKey.self] = newValue }
    }
}
