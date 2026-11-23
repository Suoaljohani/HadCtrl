import SwiftUI

/// Report list with separate filters whose counts match their lists (spec §14).
struct ReportsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case notSubmitted, returned, underReview, approved, all
        var id: Self { self }
        var title: String {
            switch self {
            case .notSubmitted: return String(localized: "لم يُسلّم")
            case .returned: return String(localized: "معاد")
            case .underReview: return String(localized: "للمراجعة")
            case .approved: return String(localized: "معتمد")
            case .all: return String(localized: "الكل")
            }
        }
        func matches(_ r: ReportItem) -> Bool {
            switch self {
            case .notSubmitted: return r.status == .notSubmitted
            case .returned: return r.status == .returned
            case .underReview: return r.status == .underReview || r.status == .submitted
            case .approved: return r.status == .approved
            case .all: return true
            }
        }
    }

    let dependencies: DependencyContainer
    @Environment(PeriodSelection.self) private var periods
    @State private var state: LoadState<[ReportItem]> = .idle
    @State private var filter: Filter = .all

    var body: some View {
        List {
            Section {
                Picker(String(localized: "التصفية"), selection: $filter) {
                    ForEach(Filter.allCases) { f in
                        Text("\(f.title) (\((state.value ?? []).filter(f.matches).count))").tag(f)
                    }
                }
            }
            switch state {
            case .idle, .loading: ProgressView().frame(maxWidth: .infinity)
            case .failed(let e, _): StateView(kind: .error, title: String(localized: "تعذر تحميل التقارير"), message: e.userMessage)
            case .loaded(let items):
                let shown = items.filter(filter.matches)
                if shown.isEmpty { StateView(kind: .empty, title: String(localized: "لا توجد تقارير ضمن هذه التصفية")) }
                ForEach(shown) { report in
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text("\(report.templateName) — \(report.departmentName)").font(.hcHeadline)
                        HStack(spacing: Spacing.xs) {
                            StatusBadge(text: report.status.title, tone: report.status.tone)
                            if let onTime = report.submittedOnTime {
                                StatusBadge(text: onTime ? String(localized: "سُلّم في موعده") : String(localized: "سُلّم متأخرًا"),
                                            tone: onTime ? .good : .warning)
                            }
                        }
                        Text(String(localized: "الاستحقاق \(HCFormat.dateTime(report.dueAt))")).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                        if let first = report.firstSubmittedAt {
                            Text(String(localized: "أول إرسال \(HCFormat.dateTime(first))")).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.hcBackground)
        .navigationTitle(String(localized: "التقارير"))
        // Follows the period chosen on the dashboard; reloads when it changes.
        .task(id: periods.selectedID) {
            await periods.loadIfNeeded()
            guard let periodID = periods.selectedID else {
                if periods.hasLoaded { state = .loaded([]) }
                return
            }
            state = .loading(previous: nil)
            do { state = .loaded(try await dependencies.reports.reports(periodID: periodID)) }
            catch { state = .failed(error as? AppError ?? .network(offline: false), previous: nil) }
        }
    }
}
