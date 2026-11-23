import SwiftUI
import Observation

/// One per signed-in session (owned by MainTabView, discarded on sign-out).
/// Without APNs (D-28) the unread count is refreshed while the app is open:
/// on launch, on return to the foreground and every minute.
@MainActor
@Observable
final class InboxModel {
    private(set) var state: LoadState<[InboxItem]> = .idle
    private(set) var unread = 0
    private(set) var actionError: AppError?
    private let repository: NotificationsRepository
    private let gate = LatestRequestGate()

    init(repository: NotificationsRepository) { self.repository = repository }

    func refreshCount() async {
        if let n = try? await repository.unreadCount() { unread = n }
    }

    func load() async {
        let token = gate.next()
        state = .loading(previous: state.value)
        do {
            let items = try await repository.inbox()
            guard gate.isLatest(token) else { return }
            state = .loaded(items)
            unread = items.filter { !$0.isRead }.count
        } catch {
            guard gate.isLatest(token) else { return }
            state = .failed(error as? AppError ?? .network(offline: false), previous: state.value)
        }
    }

    /// Marks the item read (server first) and returns where to go.
    func open(_ item: InboxItem) async -> AppRoute? {
        if !item.isRead {
            do {
                try await repository.markRead(id: item.id)
                update(item.id) { $0.isRead = true }
                unread = max(0, unread - 1)
            } catch { actionError = error as? AppError ?? .network(offline: false) }
        }
        return item.route
    }

    func markAllRead() async {
        actionError = nil
        do {
            try await repository.markAllRead()
            if case .loaded(let items) = state { state = .loaded(items.map { var i = $0; i.isRead = true; return i }) }
            unread = 0
        } catch { actionError = error as? AppError ?? .network(offline: false) }
    }

    /// Refreshes the count until cancelled (the view's task ends with the session).
    func poll(every interval: Duration = .seconds(60)) async {
        while !Task.isCancelled {
            await refreshCount()
            try? await Task.sleep(for: interval)
        }
    }

    private func update(_ id: UUID, _ change: (inout InboxItem) -> Void) {
        guard case .loaded(var items) = state, let i = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[i])
        state = .loaded(items)
    }
}

struct InboxButton: View {
    let model: InboxModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: model.unread > 0 ? "bell.badge" : "bell")
                .symbolRenderingMode(model.unread > 0 ? .multicolor : .monochrome)
        }
        .accessibilityLabel(model.unread > 0 ? String(localized: "الإشعارات، \(model.unread) غير مقروء")
                                             : String(localized: "الإشعارات"))
        .accessibilityIdentifier("inboxButton")
    }
}

struct InboxView: View {
    let model: InboxModel
    let open: (AppRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    /// nil until checked; device alerts are asked for only from here (permission priming).
    @State private var deviceAlertsOn: Bool?

    var body: some View {
        NavigationStack {
            List {
                if deviceAlertsOn == false {
                    Section {
                        Button {
                            Task { deviceAlertsOn = await DeviceAlerts.requestPermission() }
                        } label: {
                            Label(String(localized: "تفعيل التنبيهات على الجهاز"), systemImage: "bell.and.waves.left.and.right")
                        }
                        .accessibilityIdentifier("inbox.enableAlerts")
                    } footer: {
                        Text(String(localized: "يفحص الجهاز الإشعارات الجديدة في الخلفية حين يسمح iOS بذلك، وقد يتأخر التنبيه. لا تظهر أسماء المهام أو التقارير على شاشة القفل."))
                    }
                }
                if let error = model.actionError {
                    Label(error.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical)
                }
                switch model.state {
                case .idle, .loading(nil): ProgressView().frame(maxWidth: .infinity)
                case .failed(let e, nil):
                    StateView(kind: .error, title: String(localized: "تعذر تحميل الإشعارات"), message: e.userMessage) {
                        Task { await model.load() }
                    }
                case .loaded(let items) where items.isEmpty:
                    StateView(kind: .empty, title: String(localized: "لا توجد إشعارات"),
                              message: String(localized: "ستظهر هنا الإسنادات والمراجعات والمواعيد."))
                case .loaded(let items), .loading(let items?), .failed(_, let items?):
                    ForEach(items) { item in
                        Button { Task { if let route = await model.open(item) { dismiss(); open(route) } } } label: {
                            InboxRow(item: item)
                        }
                        .buttonStyle(.plain)
                        .disabled(item.route == nil && item.isRead)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "الإشعارات"))
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await model.load() }
            .task {
                await model.load()
                deviceAlertsOn = await DeviceAlerts.isAuthorized()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "إغلاق")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button(String(localized: "تحديد الكل كمقروء")) { Task { await model.markAllRead() } }
                        .disabled(model.unread == 0)
                        .accessibilityIdentifier("inbox.markAll")
                }
            }
        }
    }
}

struct InboxRow: View {
    let item: InboxItem

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            Image(systemName: item.kind?.symbol ?? "bell")
                .foregroundStyle((item.kind?.tone ?? .info).color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(item.headline).font(item.isRead ? .hcCallout : .hcHeadline).foregroundStyle(Color.hcInk)
                Text(item.context.isEmpty ? item.title : "\(item.title) · \(item.context)")
                    .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                Text(item.createdAt.formatted(.relative(presentation: .named, unitsStyle: .wide)))
                    .font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
            }
            Spacer(minLength: 0)
            if !item.isRead {
                Circle().fill(Color.hcPrimary).frame(width: 10, height: 10).accessibilityHidden(true)
            }
        }
        .padding(.vertical, Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.isRead ? "" : String(localized: "غير مقروء"))
        .accessibilityIdentifier("inboxRow")
    }
}

extension NotificationKind {
    var symbol: String {
        switch self {
        case .taskOverdue, .reportOverdue: return "exclamationmark.circle"
        case .taskDueSoon, .reportDueSoon: return "clock"
        case .taskCompleted, .reportApproved, .measurementApproved: return "checkmark.seal"
        case .taskReturned, .reportReturned, .measurementReturned: return "arrow.uturn.backward"
        default: return "bell"
        }
    }

    var tone: StatusTone {
        switch self {
        case .taskOverdue, .reportOverdue: return .critical
        case .taskDueSoon, .reportDueSoon, .taskReturned, .reportReturned, .measurementReturned: return .warning
        case .taskCompleted, .reportApproved, .measurementApproved: return .good
        default: return .info
        }
    }
}

