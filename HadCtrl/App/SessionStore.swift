import Foundation
import Observation

/// Launch/session state machine (spec §22): checking → signed out | no access |
/// ready. The role always comes from server-side membership, never a picker.
@MainActor
@Observable
final class SessionStore {
    enum Phase: Equatable {
        case checking
        case signedOut(message: String?)
        case noActiveMembership
        case configurationError(String)
        case ready(UserContext)
    }

    private(set) var phase: Phase = .checking
    /// Deep link received while signed out; re-evaluated after sign-in (§04).
    var pendingRoute: AppRoute?
    private let repository: SessionRepository

    init(repository: SessionRepository) {
        self.repository = repository
    }

    var context: UserContext? {
        if case .ready(let ctx) = phase { return ctx }
        return nil
    }

    func restore() async {
        phase = .checking
        do {
            if let ctx = try await repository.restore() {
                phase = ctx.orgRoles.isEmpty && ctx.departments.isEmpty ? .noActiveMembership : .ready(ctx)
            } else {
                phase = .signedOut(message: nil)
            }
        } catch let error as AppError {
            apply(error)
        } catch {
            phase = .signedOut(message: AppError.network(offline: false).userMessage)
        }
    }

    func signIn(email: String, password: String) async {
        do {
            let ctx = try await repository.signIn(email: email, password: password)
            phase = ctx.orgRoles.isEmpty && ctx.departments.isEmpty ? .noActiveMembership : .ready(ctx)
        } catch let error as AppError {
            apply(error)
        } catch {
            phase = .signedOut(message: AppError.network(offline: false).userMessage)
        }
    }

    func signOut() async {
        await repository.signOut()
        pendingRoute = nil
        phase = .signedOut(message: nil)
    }

    private func apply(_ error: AppError) {
        switch error {
        case .configuration(let detail): phase = .configurationError(detail)
        case .server(.membershipInactive, _, _, _): phase = .noActiveMembership
        default: phase = .signedOut(message: error.userMessage)
        }
    }
}
