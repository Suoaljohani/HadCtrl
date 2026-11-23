import SwiftUI

/// Indicators with their measured score, explicit "not updated" states and a
/// "how is it measured?" explanation on every row (spec §10, §11).
struct PerformanceView: View {
    let dependencies: DependencyContainer
    @State private var state: LoadState<[IndicatorSummary]> = .idle
    @State private var explaining: IndicatorSummary?
    private let style = NumberStyle()

    var body: some View {
        List {
            switch state {
            case .idle, .loading: ProgressView().frame(maxWidth: .infinity)
            case .failed(let e, _):
                StateView(kind: .error, title: String(localized: "تعذر تحميل المؤشرات"), message: e.userMessage)
            case .loaded(let items) where items.isEmpty:
                StateView(kind: .empty, title: String(localized: "لا توجد مؤشرات معرّفة لهذه الفترة"))
            case .loaded(let items):
                if dependencies.environment.usesMockData { DemoDataBanner().listRowBackground(Color.clear) }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        HStack {
                            Text(item.title).font(.hcHeadline).foregroundStyle(Color.hcInk)
                            Spacer()
                            outcomeBadge(item.outcome.outcome)
                        }
                        Text("\(item.departmentName) · \(item.code)").font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                        HStack(spacing: Spacing.m) {
                            Text(String(localized: "الفعلي: \(item.actual.map { style.format($0) } ?? String(localized: "لم يُحدّث")) \(item.unit)"))
                            Text(String(localized: "المستهدف: \(item.target.map { style.format($0) } ?? "—") \(item.unit)"))
                        }
                        .font(.hcCallout).monospacedDigit()
                        Button(String(localized: "كيف يُقاس؟")) { explaining = item }
                            .font(.hcFootnote)
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, Spacing.xxs)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.hcBackground)
        .navigationTitle(String(localized: "الأداء"))
        .sheet(item: $explaining) { item in
            NavigationStack {
                List {
                    Section(String(localized: "التعريف")) { Text(item.howMeasured) }
                    Section(String(localized: "قاعدة الاحتساب")) { Text(rule(for: item.direction)) }
                }
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
        .task {
            state = .loading(previous: nil)
            do { state = .loaded(try await dependencies.indicators.indicators(periodID: MockStore.Fixture.november)) }
            catch { state = .failed(error as? AppError ?? .network(offline: false), previous: nil) }
        }
    }

    @ViewBuilder private func outcomeBadge(_ outcome: ScoreOutcome) -> some View {
        switch outcome {
        case .score(let v):
            StatusBadge(text: style.percent(v), tone: v >= 100 ? .good : (v >= 80 ? .warning : .critical))
        case .notUpdated:
            StatusBadge(text: String(localized: "لم يُحدّث"), tone: .neutral)
        case .notComputable:
            StatusBadge(text: String(localized: "غير قابل للحساب"), tone: .neutral)
        case .outOfRange:
            StatusBadge(text: String(localized: "خارج النطاق"), tone: .critical)
        }
    }

    private func rule(for direction: ImprovementDirection) -> String {
        switch direction {
        case .higherIsBetter: return String(localized: "الأعلى أفضل: الدرجة = الأدنى بين ١٠٠ و(الفعلي ÷ المستهدف × ١٠٠).")
        case .lowerIsBetter: return String(localized: "الأقل أفضل: الدرجة = الأدنى بين ١٠٠ و(المستهدف ÷ الفعلي × ١٠٠)، والصفر يعطي ١٠٠.")
        case .withinRange: return String(localized: "ضمن نطاق: ١٠٠ داخل النطاق المعتمد، وخارج النطاق يظهر صراحة.")
        }
    }
}
