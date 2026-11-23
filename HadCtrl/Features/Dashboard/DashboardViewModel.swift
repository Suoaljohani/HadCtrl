import Foundation
import Observation

/// Loads the dashboard for the selected period. Only the latest selection may
/// update the screen (AC-004); real failures are shown, never replaced (AC-031).
///
/// Speed: snapshots are kept per period for this signed-in session, so revisiting
/// a period (or pulling to refresh) shows that period's last loaded numbers with
/// their "last updated" time while the fresh request runs. Another period's numbers
/// are never shown under the selected title.
@MainActor
@Observable
final class DashboardViewModel {
    private(set) var selectedPeriodID: UUID?
    private(set) var state: LoadState<DashboardSnapshot> = .idle

    private let repository: DashboardRepository
    private let gate = LatestRequestGate()
    private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var cache: [UUID: DashboardSnapshot] = [:]

    init(repository: DashboardRepository) {
        self.repository = repository
    }

    /// True while a request runs over numbers already on screen.
    var isRefreshingVisibleData: Bool {
        if case .loading(let previous?) = state { return previous.periodID == selectedPeriodID }
        return false
    }

    func select(periodID: UUID) {
        selectedPeriodID = periodID
        inFlight?.cancel()
        let token = gate.next()
        state = .loading(previous: cache[periodID])
        inFlight = Task { [repository] in
            let result: Result<DashboardSnapshot, AppError>
            do {
                result = .success(try await repository.snapshot(periodID: periodID))
            } catch is CancellationError {
                return
            } catch let error as AppError {
                result = .failure(error)
            } catch {
                result = .failure(.network(offline: false))
            }
            apply(result, token: token, periodID: periodID)
        }
    }

    func refresh() async {
        guard let id = selectedPeriodID else { return }
        select(periodID: id)
        await inFlight?.value
    }

    /// Test hook: wait for the current load.
    func waitForIdle() async { await inFlight?.value }

    private func apply(_ result: Result<DashboardSnapshot, AppError>, token: UInt64, periodID: UUID) {
        guard gate.isLatest(token), selectedPeriodID == periodID else { return }
        switch result {
        case .success(let snapshot):
            guard snapshot.periodID == periodID else { return }
            cache[periodID] = snapshot
            state = .loaded(snapshot)
        case .failure(let error):
            // The last snapshot of this same period stays readable, labelled with its time.
            state = .failed(error, previous: cache[periodID])
        }
    }
}
