import Foundation

/// Demo/test inbox (HC_APP_ENV=demo/ui-testing only), seeded per demo user.
actor MockInboxStore {
    typealias F = MockStore.Fixture
    private var items: [UUID: [InboxItem]] = [:]

    init(clock: HCClock) {
        let now = clock.now()
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-0000000005%02d", n))! }
        func uuid(_ s: String) -> UUID { UUID(uuidString: s)! }
        items[F.director] = [
            InboxItem(id: id(1), kind: .measurementSubmitted, title: "اكتمال توثيق العينات", context: "المختبر",
                      createdAt: now.addingTimeInterval(-600), isRead: false,
                      route: .indicator(uuid("00000000-0000-0000-0000-000000000301"), periodID: F.november)),
            InboxItem(id: id(2), kind: .reportSubmitted, title: "التقرير الشهري", context: "التدريب",
                      createdAt: now.addingTimeInterval(-3_600), isRead: false,
                      route: .report(uuid("00000000-0000-0000-0000-000000000202"))),
            InboxItem(id: id(3), kind: .taskSubmitted, title: "تحديث إجراءات استلام العينات", context: "المختبر",
                      createdAt: now.addingTimeInterval(-86_400), isRead: true,
                      route: .task(uuid("00000000-0000-0000-0000-000000000101"))),
        ]
        items[F.headLab] = [
            InboxItem(id: id(11), kind: .reportDueSoon, title: "التقرير الشهري", context: "المختبر",
                      createdAt: now.addingTimeInterval(-1_800), isRead: false,
                      route: .report(uuid("00000000-0000-0000-0000-000000000201"))),
            InboxItem(id: id(12), kind: .taskAssigned, title: "مراجعة مؤشرات الجودة الشهرية", context: "المختبر",
                      createdAt: now.addingTimeInterval(-7_200), isRead: false,
                      route: .task(uuid("00000000-0000-0000-0000-000000000103"))),
        ]
    }

    func inbox(for user: UUID) -> [InboxItem] { (items[user] ?? []).sorted { $0.createdAt > $1.createdAt } }

    func markRead(_ id: UUID, user: UUID) throws {
        guard let index = items[user]?.firstIndex(where: { $0.id == id }) else {
            throw AppError.server(code: .notFound, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        items[user]?[index].isRead = true
    }

    func markAll(user: UUID) -> Int {
        let unread = (items[user] ?? []).filter { !$0.isRead }.count
        items[user] = items[user]?.map { var i = $0; i.isRead = true; return i }
        return unread
    }
}

struct MockNotificationsRepository: NotificationsRepository {
    let store: MockStore
    let user: UUID
    func inbox() async throws -> [InboxItem] {
        try await store.consumeFailure()
        return await store.inbox.inbox(for: user)
    }
    func unreadCount() async throws -> Int { await store.inbox.inbox(for: user).filter { !$0.isRead }.count }
    func markRead(id: UUID) async throws { try await store.inbox.markRead(id, user: user) }
    @discardableResult func markAllRead() async throws -> Int { await store.inbox.markAll(user: user) }
    /// Demo builds never contact APNs; registration is accepted and discarded.
    func registerDevice(deviceID: UUID, token: String, environment: String) async throws {}
    func unregisterDevice(deviceID: UUID) async throws {}
}
