import Foundation
import Testing
@testable import HadCtrl

@Suite("In-app inbox (D-30)", .serialized)
@MainActor
struct InboxTests {
    typealias F = MockStore.Fixture
    let clock = FixedClock(date: ISO8601DateFormatter().date(from: "2026-11-23T09:00:00Z")!)

    @Test("rows map to items; a record the user can no longer read has no route; unknown types stay generic")
    func mapping() {
        let task = UUID(), hidden = UUID()
        let rows = [
            NotificationRowDTO(id: UUID(), event_type: "task_assigned", entity_type: "task", entity_id: task, read_at: nil,
                               created_at: clock.now()),
            NotificationRowDTO(id: UUID(), event_type: "report_returned", entity_type: "report", entity_id: hidden,
                               read_at: clock.now(), created_at: clock.now()),
            NotificationRowDTO(id: UUID(), event_type: "future_event", entity_type: "task", entity_id: task, read_at: nil,
                               created_at: clock.now()),
        ]
        let items = InboxMapper.map(rows, targets: [task: InboxTarget(title: "مهمة", context: "المختبر", route: .task(task))])
        #expect(items[0].kind == .taskAssigned && items[0].route == .task(task) && !items[0].isRead)
        #expect(items[1].route == nil && items[1].isRead, "hidden record: no route, nothing leaked")
        #expect(items[1].title == String(localized: "سجل لم يعد متاحًا لك"))
        #expect(items[2].kind == nil && items[2].headline == String(localized: "إشعار"))
    }

    @Test("every server event type has an Arabic headline")
    func everyKindHasHeadline() {
        let server = ["task_assigned", "task_submitted", "task_returned", "task_completed", "task_due_soon", "task_overdue",
                      "report_due_soon", "report_overdue", "report_returned", "report_approved", "report_submitted",
                      "extension_requested", "extension_decided", "achievement_decided", "decision_needed",
                      "measurement_submitted", "measurement_approved", "measurement_returned", "goal_decided"]
        #expect(Set(server) == Set(NotificationKind.allCases.map(\.rawValue)), "matches notifications_event_type_check")
        #expect(NotificationKind.allCases.allSatisfy { !$0.headline.isEmpty })
    }

    @Test("opening an item marks it read on the server and returns its route; mark all clears the count")
    func openAndMarkAll() async throws {
        let store = MockStore(clock: clock)
        let repos = MockRepositories(store: store, clock: clock, demoUser: F.director)
        let model = InboxModel(repository: repos.notifications)
        await model.load()
        #expect(model.unread == 2)
        let first = try #require(model.state.value?.first { !$0.isRead })
        let route = await model.open(first)
        #expect(route == first.route)
        #expect(model.unread == 1)
        #expect(try await repos.notifications.unreadCount() == 1, "read state is kept by the repository, not only the screen")
        await model.markAllRead()
        #expect(model.unread == 0)
        #expect(model.state.value?.allSatisfy(\.isRead) == true)
        #expect(try await repos.notifications.unreadCount() == 0)
    }

    @Test("each user sees only their own inbox")
    func perUser() async throws {
        let store = MockStore(clock: clock)
        let head = MockRepositories(store: store, clock: clock, demoUser: F.headLab).notifications
        let director = MockRepositories(store: store, clock: clock, demoUser: F.director).notifications
        let headIDs = Set(try await head.inbox().map(\.id))
        let directorIDs = Set(try await director.inbox().map(\.id))
        #expect(headIDs.isDisjoint(with: directorIDs))
    }
}
