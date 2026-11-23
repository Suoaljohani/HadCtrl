import SwiftUI
import UIKit
import UserNotifications
import Observation

/// Receives the APNs token and notification taps (D-36).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushCenter.shared.didReceive(token: hex)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushCenter.shared.registrationFailed()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let hc = info["hc"] as? [String: Any]
        let type = hc?["entity_type"] as? String
        let id = hc?["entity_id"] as? String
        await MainActor.run { PushCenter.shared.open(entityType: type, entityID: id) }
    }
}

/// Push permission, registration and routing. Pushes are a convenience: the
/// in-app inbox stays the reliable channel, and nothing is "received" on the
/// server because a push was sent (§18).
@MainActor
@Observable
final class PushCenter {
    static let shared = PushCenter()

    enum Status: Equatable {
        case unknown, notDetermined, denied, enabled, unavailable
    }

    private(set) var status: Status = .unknown
    /// True once this device's token is bound to the signed-in user on the server.
    private(set) var isRegisteredOnServer = false
    /// Set when the user taps a push; the tab view opens it after unlock.
    var pendingRoute: AppRoute?

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var repository: NotificationsRepository?

    private static let deviceIDKey = "hc.device.id"

    /// Random, app-generated identifier for this installation (never hardware-derived).
    static var deviceID: UUID {
        if let raw = UserDefaults.standard.string(forKey: deviceIDKey), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: deviceIDKey)
        return id
    }

    /// The APNs environment this build is signed for, read from its embedded
    /// provisioning profile; nil when the build cannot receive pushes at all.
    static var apnsEnvironment: String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let keyRange = text.range(of: "<key>aps-environment</key>") else { return nil }
        let tail = text[keyRange.upperBound...]
        guard let open = tail.range(of: "<string>"), let close = tail.range(of: "</string>") else { return nil }
        let value = String(tail[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "production" || value == "development" ? value : nil
    }

    /// Called when a session becomes ready: re-registers silently if allowed before.
    func attach(repository: NotificationsRepository) async {
        self.repository = repository
        await refreshStatus()
        if status == .enabled { UIApplication.shared.registerForRemoteNotifications() }
    }

    func detach() {
        repository = nil
        isRegisteredOnServer = false
        UIApplication.shared.unregisterForRemoteNotifications()
    }

    func refreshStatus() async {
        guard Self.apnsEnvironment != nil else { status = .unavailable; return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: status = .notDetermined
        case .denied: status = .denied
        case .authorized, .provisional, .ephemeral: status = .enabled
        @unknown default: status = .unknown
        }
    }

    /// Asked only from Settings or the inbox, after explaining the benefit (§18).
    func enable() async {
        guard Self.apnsEnvironment != nil else { status = .unavailable; return }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        status = granted ? .enabled : .denied
        if granted { UIApplication.shared.registerForRemoteNotifications() }
    }

    func didReceive(token: String) {
        self.token = token
        Task { await upload() }
    }

    func registrationFailed() {
        isRegisteredOnServer = false
    }

    private func upload() async {
        guard let token, let repository, let environment = Self.apnsEnvironment else { return }
        do {
            try await repository.registerDevice(deviceID: Self.deviceID, token: token, environment: environment)
            isRegisteredOnServer = true
        } catch {
            isRegisteredOnServer = false
        }
    }

    /// Payloads carry only an entity type and id; the record is loaded (and access
    /// re-checked) after the app is open and unlocked.
    func open(entityType: String?, entityID: String?) {
        guard let entityType, let entityID, let url = URL(string: "hadctrl://\(entityType)/\(entityID)"),
              let route = AppRoute(url: url) else { return }
        pendingRoute = route
    }
}
