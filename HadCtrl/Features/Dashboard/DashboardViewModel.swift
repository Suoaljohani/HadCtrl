import Foundation
import Observation

/// Loads the dashboard for the selected period. Only the latest selection may
/// update the screen (AC-004); real failures are shown, never replaced (AC-031).
@MainActor
@Observable
final class DashboardViewModel {
    private(set) var selectedPeriodID: UUID?
    private(set) var state: LoadState<DashboardSnapshot> = .idle

    private let repository: DashboardRepository
    private let gate = LatestRequestGate()
    private var inFlight: Task<Void, Never>?

    init(repository: DashboardRepository) {
        self.repository = repository
    }

    func select(periodID: UUID) {
        selectedPeriodID = periodID
        inFlight?.cancel()
        let token = gate.next()
        // Never show the previous period's numbers under the new period title.
        state = .loading(previous: nil)
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
            state = .loaded(snapshot)
        case .failure(let error):
            state = .failed(error, previous: nil)
        }
    }
}
