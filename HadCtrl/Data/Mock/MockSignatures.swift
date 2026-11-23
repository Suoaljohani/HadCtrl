import Foundation

/// In-memory signatures for demo and UI-testing builds.
actor MockSignatureStore {
    static let shared = MockSignatureStore()
    private var records: [SignatureEntity: [SignatureRecord]] = [:]

    func add(_ record: SignatureRecord, for entity: SignatureEntity) { records[entity, default: []].append(record) }
    func list(_ entity: SignatureEntity) -> [SignatureRecord] { records[entity] ?? [] }
}

struct MockSignaturesRepository: SignaturesRepository {
    let store: MockStore
    let user: UUID

    func isAvailable() async -> Bool { true }

    func sign(_ png: Data, entity: SignatureEntity, purpose: SignaturePurpose, requestID: UUID) async throws {
        try await store.consumeFailure()
        guard !png.isEmpty else {
            throw AppError.server(code: .validationFailed, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        let name = MockDirectory.people.first { $0.id == user }?.displayName ?? "—"
        await MockSignatureStore.shared.add(SignatureRecord(id: requestID, signerName: name, purpose: purpose,
                                                            signedAt: Date(), imageData: png), for: entity)
    }

    func signatures(for entity: SignatureEntity) async throws -> [SignatureRecord] {
        await MockSignatureStore.shared.list(entity)
    }
}
