import Foundation
import BackgroundTasks
import UserNotifications

/// Best-effort device alerts without APNs (D-30). When iOS grants the app a
/// background refresh, it reads the inbox and posts local notifications for
/// unread items created since the last check. iOS decides when (or whether)
/// that happens, so this never replaces the in-app inbox.
/// Lock-screen text is generic: no task, report or indicator names (§18, §22).
enum DeviceAlerts {
    static let refreshTaskID = "hadctrl.inbox.refresh"
    private static let lastAlertedKey = "hc.inbox.lastAlertedAt"   // a timestamp only

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    /// Asked only when the user turns alerts on from the inbox (permission priming).
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
    }

    /// Everything up to now has been seen in the app; only newer items may alert.
    static func markSeen(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: lastAlertedKey)
    }

    static func deliverNew(using repository: NotificationsRepository) async {
        guard await isAuthorized(), let items = try? await repository.inbox() else { return }
        let center = UNUserNotificationCenter.current()
        let unread = items.filter { !$0.isRead }
        try? await center.setBadgeCount(unread.count)
        guard let last = UserDefaults.standard.object(forKey: lastAlertedKey) as? Date else {
            markSeen()   // first run: never flood with history
            return
        }
        let fresh = unread.filter { $0.createdAt > last }.sorted { $0.createdAt > $1.createdAt }
        for item in fresh.prefix(3) {
            let content = UNMutableNotificationContent()
            content.title = item.headline
            content.body = String(localized: "افتح قيادة لعرض التفاصيل")
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil))
        }
        if fresh.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "لديك \(fresh.count) إشعارات جديدة")
            content.body = String(localized: "افتح قيادة لعرض التفاصيل")
            try? await center.add(UNNotificationRequest(identifier: "hc.inbox.summary", content: content, trigger: nil))
        }
        if let newest = fresh.first?.createdAt { markSeen(now: newest) }
    }

    /// Sign-out: nothing from this account stays on the device (AC-025).
    static func reset() async {
        UserDefaults.standard.removeObject(forKey: lastAlertedKey)
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
        try? await center.setBadgeCount(0)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshTaskID)
    }
}
