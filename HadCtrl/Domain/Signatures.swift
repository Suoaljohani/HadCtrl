import Foundation

// Handwritten approval signatures (D-37). A signature accompanies a decision;
// it never authorizes one — the decision RPCs keep their own checks.

enum SignatureEntity: Hashable, Sendable {
    case task(UUID), report(UUID), measurement(UUID), achievement(UUID), goal(UUID)

    var type: String {
        switch self {
        case .task: return "task"
        case .report: return "report"
        case .measurement: return "measurement"
        case .achievement: return "achievement"
        case .goal: return "goal"
        }
    }

    var id: UUID {
        switch self {
        case .task(let id), .report(let id), .measurement(let id), .achievement(let id), .goal(let id): return id
        }
    }
}

enum SignaturePurpose: String, Sendable {
    case approve, activate, complete

    var title: String {
        switch self {
        case .approve: return String(localized: "اعتماد")
        case .activate: return String(localized: "تفعيل")
        case .complete: return String(localized: "إقفال")
        }
    }
}

struct SignatureRecord: Identifiable, Sendable, Hashable {
    let id: UUID
    let signerName: String
    let purpose: SignaturePurpose
    let signedAt: Date
    let imageData: Data?
}

protocol SignaturesRepository: Sendable {
    /// False while the server has not been updated with signature support
    /// (migration 001800): approvals then proceed without a signature step.
    func isAvailable() async -> Bool
    /// Uploads the PNG and seals it on the server; throws if it was not recorded.
    func sign(_ png: Data, entity: SignatureEntity, purpose: SignaturePurpose, requestID: UUID) async throws
    func signatures(for entity: SignatureEntity) async throws -> [SignatureRecord]
}
