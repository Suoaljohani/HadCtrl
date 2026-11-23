import Foundation
import Observation

/// The reporting period chosen on the dashboard, shared by every tab so all
/// screens describe the same period (§06). Loaded from the server per session.
@MainActor
@Observable
final class PeriodSelection {
    private(set) var periods: [ReportingPeriod] = []
    private(set) var error: AppError?
    private(set) var hasLoaded = false
    var selectedID: UUID?
    private let repository: DashboardRepository

    init(repository: DashboardRepository) {
        self.repository = repository
    }

    var selected: ReportingPeriod? { periods.first { $0.id == selectedID } }

    func loadIfNeeded() async {
        guard periods.isEmpty else { return }
        do {
            periods = try await repository.periods()
            error = nil
            hasLoaded = true
            // Default: the current open period, else the most recent one.
            selectedID = selectedID ?? (periods.first { $0.state == .open } ?? periods.first)?.id
        } catch {
            self.error = error as? AppError ?? .network(offline: false)
        }
    }

    func reload() async {
        periods = []
        hasLoaded = false
        await loadIfNeeded()
    }
}
