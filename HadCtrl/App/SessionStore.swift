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
        /// Account created with a temporary password: must set its own first (D-25).
        case mustChangePassword(UserContext)
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
                phase = Self.phase(for: ctx)
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
            phase = Self.phase(for: ctx)
        } catch let error as AppError {
            apply(error)
        } catch {
            phase = .signedOut(message: AppError.network(offline: false).userMessage)
        }
    }

    func changePassword(_ newPassword: String) async throws {
        let ctx = try await repository.changePassword(newPassword)
        phase = Self.phase(for: ctx)
    }

    private static func phase(for ctx: UserContext) -> Phase {
        if ctx.orgRoles.isEmpty && ctx.departments.isEmpty { return .noActiveMembership }
        return ctx.mustChangePassword ? .mustChangePassword(ctx) : .ready(ctx)
    }

    func signOut() async {
        await repository.signOut()
        await DeviceAlerts.reset()
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
