import Foundation

// In-app inbox (D-28, D-30; spec §18). Rows are produced on the server in the
// same transaction as the change they describe; the app only reads them.

enum NotificationKind: String, Sendable, CaseIterable {
    case taskAssigned = "task_assigned", taskSubmitted = "task_submitted", taskReturned = "task_returned"
    case taskCompleted = "task_completed", taskDueSoon = "task_due_soon", taskOverdue = "task_overdue"
    case reportDueSoon = "report_due_soon", reportOverdue = "report_overdue", reportReturned = "report_returned"
    case reportApproved = "report_approved", reportSubmitted = "report_submitted"
    case extensionRequested = "extension_requested", extensionDecided = "extension_decided"
    case achievementDecided = "achievement_decided", decisionNeeded = "decision_needed"
    case measurementSubmitted = "measurement_submitted", measurementApproved = "measurement_approved"
    case measurementReturned = "measurement_returned"

    var headline: String {
        switch self {
        case .taskAssigned: return String(localized: "أُسندت إليك مهمة")
        case .taskSubmitted: return String(localized: "مهمة مرفوعة بانتظار اعتمادك")
        case .taskReturned: return String(localized: "أُعيدت مهمتك للاستكمال")
        case .taskCompleted: return String(localized: "اعتُمدت مهمتك")
        case .taskDueSoon: return String(localized: "مهمة يقترب موعدها")
        case .taskOverdue: return String(localized: "مهمة تجاوزت موعدها")
        case .reportDueSoon: return String(localized: "تقرير يقترب موعده")
        case .reportOverdue: return String(localized: "تقرير تجاوز موعده")
        case .reportReturned: return String(localized: "أُعيد التقرير للاستكمال")
        case .reportApproved: return String(localized: "اعتُمد التقرير")
        case .reportSubmitted: return String(localized: "تقرير بانتظار مراجعتك")
        case .extensionRequested: return String(localized: "طلب تمديد بانتظار قرارك")
        case .extensionDecided: return String(localized: "صدر قرار طلب التمديد")
        case .achievementDecided: return String(localized: "صدر قرار الإنجاز")
        case .decisionNeeded: return String(localized: "قرار مطلوب منك")
        case .measurementSubmitted: return String(localized: "قراءة مؤشر بانتظار اعتمادك")
        case .measurementApproved: return String(localized: "اعتُمدت قراءة المؤشر")
        case .measurementReturned: return String(localized: "أُعيدت قراءة المؤشر للقسم")
        }
    }
}

struct InboxItem: Sendable, Hashable, Identifiable {
    let id: UUID
    /// nil for an event type this build does not know (shown generically).
    let kind: NotificationKind?
    /// What the item is about, e.g. the task title; "no longer available" when RLS hides it.
    let title: String
    let context: String
    let createdAt: Date
    var isRead: Bool
    /// Where tapping goes; nil when the record is no longer visible.
    let route: AppRoute?

    var headline: String { kind?.headline ?? String(localized: "إشعار") }
}

protocol NotificationsRepository: Sendable {
    /// Newest first, at most 100.
    func inbox() async throws -> [InboxItem]
    func unreadCount() async throws -> Int
    func markRead(id: UUID) async throws
    @discardableResult func markAllRead() async throws -> Int
}
