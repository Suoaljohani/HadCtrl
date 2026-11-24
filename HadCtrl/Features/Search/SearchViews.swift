import SwiftUI
import Observation

/// Debounced, cancellable search with categories (spec §17). Only the latest query
/// may update the screen; recent queries stay on this device and are cleared on sign-out.
@MainActor
@Observable
final class SearchModel {
    var query = "" { didSet { schedule() } }
    var currentPeriodOnly = false { didSet { schedule(immediately: true) } }
    private(set) var state: LoadState<SearchResults> = .idle
    private(set) var recent: [String] = SearchHistory.load()

    @ObservationIgnored private let repository: SearchRepository
    @ObservationIgnored private let periodID: () -> UUID?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let gate = LatestRequestGate()
    @ObservationIgnored private let debounce: Duration

    init(repository: SearchRepository, periodID: @escaping () -> UUID?, debounce: Duration = .milliseconds(300)) {
        self.repository = repository
        self.periodID = periodID
        self.debounce = debounce
    }

    var isTooShort: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty && SearchQuery.usable(query) == nil }

    private func schedule(immediately: Bool = false) {
        pending?.cancel()
        guard let q = SearchQuery.usable(query) else { state = .idle; return }
        let token = gate.next()
        let delay = immediately ? Duration.zero : debounce
        let scoped = currentPeriodOnly ? periodID() : nil
        let routePeriod = periodID()
        state = .loading(previous: state.value)
        pending = Task { [repository] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            do {
                let results = try await repository.search(q, periodID: scoped, routePeriodID: routePeriod)
                guard gate.isLatest(token), !Task.isCancelled else { return }
                state = .loaded(results)
            } catch is CancellationError {
            } catch {
                guard gate.isLatest(token) else { return }
                state = .failed(error as? AppError ?? .network(offline: false), previous: nil)
            }
        }
    }

    /// Test hook.
    func waitForIdle() async { await pending?.value }

    func remember() {
        guard let q = SearchQuery.usable(query) else { return }
        recent = SearchHistory.add(q)
    }

    func clearRecent() {
        SearchHistory.clear()
        recent = []
    }
}

/// On-device recent queries (no analytics, no server). Cleared on sign-out.
enum SearchHistory {
    private static let key = "hc.search.recent"

    static func load() -> [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    @discardableResult static func add(_ q: String) -> [String] {
        var list = load().filter { $0 != q }
        list.insert(q, at: 0)
        list = Array(list.prefix(8))
        UserDefaults.standard.set(list, forKey: key)
        return list
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

struct SearchView: View {
    @State private var model: SearchModel
    let open: (AppRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.hcMotionEnabled) private var motion

    init(repository: SearchRepository, periodID: @escaping () -> UUID?, open: @escaping (AppRoute) -> Void) {
        _model = State(initialValue: SearchModel(repository: repository, periodID: periodID))
        self.open = open
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $model.currentPeriodOnly) {
                        Label(String(localized: "التقارير والمنجزات في الفترة الحالية فقط"), systemImage: "calendar")
                            .font(.hcFootnote)
                    }
                    .accessibilityIdentifier("search.periodOnly")
                } footer: {
                    Text(model.currentPeriodOnly
                         ? String(localized: "تُبحث المهام والأهداف والأقسام والمؤشرات دائمًا؛ يقتصر التقييد على التقارير والمنجزات.")
                         : String(localized: "يشمل البحث كل الفترات المصرّح لك بها."))
                }
                content
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.hcBackground)
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: String(localized: "ابحث في الأقسام والأهداف والمهام والتقارير…"))
            .onSubmit(of: .search) { model.remember() }
            .navigationTitle(String(localized: "البحث"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "إغلاق")) { dismiss() } } }
            .animation(motion ? HCMotion.snappy : nil, value: model.state.value)
        }
        .accessibilityIdentifier("searchView")
    }

    @ViewBuilder private var content: some View {
        if model.query.trimmingCharacters(in: .whitespaces).isEmpty {
            if !model.recent.isEmpty {
                Section {
                    ForEach(model.recent, id: \.self) { q in
                        Button { model.query = q } label: {
                            Label(q, systemImage: "clock.arrow.circlepath").foregroundStyle(Color.hcInk)
                        }
                    }
                } header: {
                    HStack {
                        Text(String(localized: "عمليات البحث الأخيرة"))
                        Spacer()
                        Button(String(localized: "مسح")) { model.clearRecent() }.font(.hcCaption)
                    }
                }
            } else {
                StateView(kind: .empty, title: String(localized: "ابحث بالاسم أو الرمز"),
                          message: String(localized: "يبدأ البحث بعد حرفين؛ تُطابق الألف والياء والتاء المربوطة بأشكالها."))
                    .listRowBackground(Color.clear)
            }
        } else if model.isTooShort {
            Text(String(localized: "اكتب حرفين على الأقل")).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
        } else {
            switch model.state {
            case .idle, .loading(nil):
                SkeletonRows(rows: 3)
            case .failed(let e, _):
                StateView(kind: .error, title: String(localized: "تعذر البحث"), message: e.userMessage)
                    .listRowBackground(Color.clear)
            case .loaded(let r), .loading(let r?):
                if r.isEmpty {
                    StateView(kind: .empty, title: String(localized: "لا نتائج مطابقة"),
                              message: String(localized: "جرّب كلمة أخرى أو وسّع البحث لكل الفترات."))
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("search.noResults")
                } else {
                    ForEach(r.groups, id: \.category) { group in
                        Section {
                            ForEach(group.hits) { hit in
                                Button {
                                    model.remember()
                                    guard let route = hit.route else { return }
                                    dismiss()
                                    open(route)
                                } label: { SearchHitRow(hit: hit) }
                                .disabled(hit.route == nil)
                                .accessibilityIdentifier("searchHit.\(hit.id.uuidString)")
                            }
                        } header: {
                            Label(group.category.title, systemImage: group.category.symbol)
                        }
                    }
                }
            }
        }
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    private var statusText: String? {
        guard let s = hit.status else { return nil }
        switch hit.category {
        case .tasks: return TaskStatus(rawValue: s)?.title
        case .reports: return ReportStatus(rawValue: s)?.title
        case .achievements: return AchievementItem.Status(rawValue: s)?.title
        case .goals: return GoalLifecycle(rawValue: s)?.title
        case .departments: return s == "archived" ? String(localized: "مؤرشف") : nil
        case .indicators: return nil
        }
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            IconBadge(symbol: hit.category.symbol, tone: .info, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.title).font(.hcHeadline).foregroundStyle(Color.hcInk).lineLimit(2)
                if !hit.subtitle.isEmpty {
                    Text(hit.subtitle).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                }
            }
            Spacer(minLength: 0)
            if let statusText { StatusBadge(text: statusText, tone: .neutral) }
        }
        .accessibilityElement(children: .combine)
    }
}
