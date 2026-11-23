import Foundation

// Evidence attachments (spec §26). The server decides who may attach to which
// record and verifies every upload; these rules only stop obvious mistakes early.

enum AttachmentTarget: Sendable, Hashable {
    case task(UUID)
    case reportRevision(UUID)
    case achievement(UUID)

    var wireType: String {
        switch self {
        case .task: return "task"
        case .reportRevision: return "report_revision"
        case .achievement: return "achievement"
        }
    }
    var id: UUID {
        switch self { case .task(let id), .reportRevision(let id), .achievement(let id): return id }
    }
    /// attachment_links column for this target.
    var linkColumn: String {
        switch self {
        case .task: return "task_id"
        case .reportRevision: return "report_revision_id"
        case .achievement: return "achievement_id"
        }
    }
}

struct Attachment: Sendable, Hashable, Identifiable {
    let id: UUID
    let displayName: String
    let mimeType: String
    let sizeBytes: Int64
    let objectPath: String
    let uploaderID: UUID
    let createdAt: Date
}

enum AttachmentRules {
    static let maxBytes: Int64 = 20 * 1024 * 1024
    static let maxPerRecord = 10
    static let allowedTypes: [String: String] = [
        "pdf": "application/pdf", "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "heic": "image/heic",
        "csv": "text/csv", "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    ]

    static func mimeType(forExtension ext: String) -> String? { allowedTypes[ext.lowercased()] }

    /// A display name without path or control characters, at most 200 characters.
    static func safeName(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\" && $0 != ":" }
        let name = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(name.prefix(200))
        return trimmed.isEmpty ? "file" : trimmed
    }

    enum Problem: Equatable, Sendable { case type, size, tooMany }

    static func check(mimeType: String?, size: Int64, existing: Int) -> Problem? {
        guard let mimeType, allowedTypes.values.contains(mimeType) else { return .type }
        guard size > 0, size <= maxBytes else { return .size }
        guard existing < maxPerRecord else { return .tooMany }
        return nil
    }

    static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

protocol AttachmentsRepository: Sendable {
    func attachments(for target: AttachmentTarget) async throws -> [Attachment]
    /// prepare → upload to the reserved path → finalize (verified by the server).
    func upload(_ data: Data, fileName: String, mimeType: String, to target: AttachmentTarget, requestID: UUID) async throws -> Attachment
    /// A short-lived signed URL; issued only if the server lets the user read the record.
    func signedURL(for attachment: Attachment) async throws -> URL
    func remove(_ attachment: Attachment, requestID: UUID) async throws
}
