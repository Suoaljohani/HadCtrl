import SwiftUI

struct DepartmentsView: View {
    let dependencies: DependencyContainer
    @State private var state: LoadState<[Department]> = .idle
    @State private var query = ""

    private var filtered: [Department] {
        let items = state.value ?? []
        let q = ArabicSearch.normalize(query)
        guard !q.isEmpty else { return items }
        return items.filter { ArabicSearch.normalize($0.nameAr).contains(q) || $0.code.lowercased().contains(q) }
    }

    var body: some View {
        List {
            switch state {
            case .idle, .loading: ProgressView().frame(maxWidth: .infinity)
            case .failed(let e, _):
                StateView(kind: .error, title: String(localized: "تعذر تحميل الأقسام"), message: e.userMessage) { Task { await load() } }
            case .loaded:
                if filtered.isEmpty {
                    StateView(kind: .empty, title: String(localized: "لا توجد أقسام مطابقة"))
                }
                ForEach(filtered) { dept in
                    NavigationLink(value: AppRoute.department(dept.id)) {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            HStack {
                                Text(dept.nameAr).font(.hcHeadline)
                                Text(dept.code).font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                                    .environment(\.layoutDirection, .leftToRight)
                            }
                            Text(dept.headName ?? String(localized: "لا يوجد رئيس نشط"))
                                .font(.hcFootnote).foregroundStyle(dept.headName == nil ? Color.hcWarning : Color.hcSecondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.hcBackground)
        .searchable(text: $query, prompt: String(localized: "ابحث بالاسم أو الرمز"))
        .navigationTitle(String(localized: "الأقسام"))
        .task { if case .idle = state { await load() } }
        .refreshable { await load() }
    }

    private func load() async {
        state = .loading(previous: state.value)
        do { state = .loaded(try await dependencies.departments.departments()) }
        catch { state = .failed(error as? AppError ?? .network(offline: false), previous: nil) }
    }
}

struct DepartmentDetailView: View {
    let departmentID: UUID
    let context: UserContext
    let dependencies: DependencyContainer
    @State private var department: Department?
    @State private var loadError: AppError?

    var body: some View {
        Group {
            if let department {
                TaskListView(context: context, dependencies: dependencies,
                             initialFilter: TaskFilter(scope: .all, departmentID: department.id))
                    .navigationTitle(department.nameAr)
            } else if let loadError {
                StateView(kind: .notFound, title: String(localized: "القسم غير متاح"), message: loadError.userMessage)
            } else {
                ProgressView()
            }
        }
        .background(Color.hcBackground)
        .task {
            do {
                department = try await dependencies.departments.departments().first { $0.id == departmentID }
                if department == nil { loadError = .server(code: .notFound, fieldErrors: [:], currentVersion: nil, correlationID: nil) }
            } catch {
                loadError = error as? AppError ?? .network(offline: false)
            }
        }
    }
}

/// Light Arabic normalization for matching (spec §17); display keeps the original text.
enum ArabicSearch {
    static func normalize(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let map: [Character: Character] = ["أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا", "ى": "ي", "ة": "ه", "ؤ": "و", "ئ": "ي"]
        s = String(s.map { map[$0] ?? $0 })
        // Strip tatweel and harakat.
        s.unicodeScalars.removeAll { $0 == "\u{0640}" || (0x064B...0x0652).contains($0.value) }
        return s
    }
}
