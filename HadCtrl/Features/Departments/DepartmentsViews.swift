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
            case .idle, .loading(nil): SkeletonRows()
            case .failed(let e, _):
                StateView(kind: .error, title: String(localized: "تعذر تحميل الأقسام"), message: e.userMessage) { Task { await load() } }
            case .loaded, .loading(.some(_)):
                if filtered.isEmpty {
                    StateView(kind: .empty, title: String(localized: "لا توجد أقسام مطابقة"))
                }
                ForEach(filtered) { dept in
                    HCLink(AppRoute.department(dept.id)) {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            HStack {
                                Text(dept.nameAr).font(.hcHeadline)
                                Text(dept.code).font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                                    .environment(\.layoutDirection, .leftToRight)
                            }
                            if let head = dept.headName {
                                Text(head).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                            } else if dept.headVisible {
                                Text(String(localized: "لا يوجد رئيس نشط")).font(.hcFootnote).foregroundStyle(Color.hcWarning)
                            }
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

/// Department card (spec §08): who leads it, then internal sections for goals,
/// indicators, tasks, reports and achievements of the selected period.
struct DepartmentDetailView: View {
    enum Part: String, CaseIterable, Identifiable {
        case goals, indicators, tasks, reports, achievements
        var id: Self { self }
        var title: String {
            switch self {
            case .goals: return String(localized: "الأهداف")
            case .indicators: return String(localized: "المؤشرات")
            case .tasks: return String(localized: "المهام")
            case .reports: return String(localized: "التقارير")
            case .achievements: return String(localized: "المنجزات")
            }
        }
    }

    let departmentID: UUID
    let context: UserContext
    let dependencies: DependencyContainer
    @State private var department: Department?
    @State private var loadError: AppError?
    @State private var section: Part = .goals

    var body: some View {
        Group {
            if let department {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(department.headVisible
                             ? (department.headName.map { String(localized: "الرئيس: \($0)") } ?? String(localized: "بلا رئيس نشط"))
                             : String(localized: "الرئيس غير ظاهر لصلاحيتك"))
                            .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                        Picker(String(localized: "القسم الداخلي"), selection: $section) {
                            ForEach(Part.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("department.sections")
                    }
                    .padding(.horizontal, Spacing.m)
                    .padding(.vertical, Spacing.xs)
                    switch section {
                    case .goals: GoalsListView(context: context, dependencies: dependencies, departmentID: department.id)
                    case .indicators: IndicatorsListView(dependencies: dependencies, departmentID: department.id)
                    case .tasks:
                        TaskListView(context: context, dependencies: dependencies,
                                     initialFilter: TaskFilter(scope: .all, departmentID: department.id))
                    case .reports: ReportsView(context: context, dependencies: dependencies, departmentID: department.id)
                    case .achievements: AchievementsListView(context: context, dependencies: dependencies, departmentID: department.id)
                    }
                }
                .navigationTitle(department.nameAr)
            } else if let loadError {
                StateView(kind: .notFound, title: String(localized: "القسم غير متاح"), message: loadError.userMessage)
            } else {
                DetailSkeleton()
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
