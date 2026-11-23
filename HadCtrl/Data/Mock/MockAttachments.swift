import Foundation

/// Demo/test evidence (HC_APP_ENV=demo/ui-testing only); files live in memory.
actor MockAttachmentStore {
    private var byTarget: [AttachmentTarget: [Attachment]] = [:]
    private var files: [UUID: Data] = [:]
    private var replies: [UUID: UUID] = [:]

    init() {
        // One existing file on the approved LAB achievement.
        let a = Attachment(id: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!, displayName: "قراءة LAB.TAT المعتمدة.pdf",
                           mimeType: "application/pdf", sizeBytes: 48_213, objectPath: "demo/lab/701",
                           uploaderID: MockStore.Fixture.headLab, createdAt: Date(timeIntervalSince1970: 1_795_000_000))
        byTarget[.achievement(UUID(uuidString: "00000000-0000-0000-0000-000000000401")!)] = [a]
        files[a.id] = Data("%PDF-1.4 demo".utf8)
    }

    func list(_ target: AttachmentTarget) -> [Attachment] { byTarget[target] ?? [] }

    func add(_ data: Data, name: String, mime: String, target: AttachmentTarget, requestID: UUID, uploader: UUID) throws -> Attachment {
        if let prior = replies[requestID], let existing = byTarget[target]?.first(where: { $0.id == prior }) { return existing }
        if let problem = AttachmentRules.check(mimeType: mime, size: Int64(data.count), existing: byTarget[target]?.count ?? 0) {
            throw AppError.server(code: .validationFailed, fieldErrors: ["file": "\(problem)"], currentVersion: nil, correlationID: nil)
        }
        let a = Attachment(id: UUID(), displayName: AttachmentRules.safeName(name), mimeType: mime, sizeBytes: Int64(data.count),
                           objectPath: "demo/\(UUID().uuidString)", uploaderID: uploader, createdAt: Date())
        byTarget[target, default: []].append(a)
        files[a.id] = data
        replies[requestID] = a.id
        return a
    }

    func data(_ id: UUID) -> Data? { files[id] }

    func remove(_ id: UUID) {
        for (k, v) in byTarget { byTarget[k] = v.filter { $0.id != id } }
        files[id] = nil
    }
}

struct MockAttachmentsRepository: AttachmentsRepository {
    let store: MockStore
    let user: UUID
    func attachments(for target: AttachmentTarget) async throws -> [Attachment] { await store.attachmentStore.list(target) }
    func upload(_ data: Data, fileName: String, mimeType: String, to target: AttachmentTarget, requestID: UUID) async throws -> Attachment {
        try await store.consumeFailure()
        return try await store.attachmentStore.add(data, name: fileName, mime: mimeType, target: target, requestID: requestID, uploader: user)
    }
    /// Writes the demo bytes to a temporary file so previews work offline.
    func signedURL(for attachment: Attachment) async throws -> URL {
        guard let data = await store.attachmentStore.data(attachment.id) else {
            throw AppError.server(code: .notFound, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        let url = AttachmentPreviewCache.directory.appendingPathComponent(attachment.id.uuidString + "-" + attachment.displayName)
        try data.write(to: url)
        return url
    }
    func remove(_ attachment: Attachment, requestID: UUID) async throws { await store.attachmentStore.remove(attachment.id) }
}
