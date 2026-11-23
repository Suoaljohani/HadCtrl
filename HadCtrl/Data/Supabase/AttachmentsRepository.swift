import Foundation
import CryptoKit
import Supabase

// Evidence over the 001700 RPCs and the private Storage bucket (§26).

struct SupabaseAttachmentsRepository: AttachmentsRepository {
    let backend: SupabaseBackend
    static let bucket = "hadctrl-evidence"
    /// Signed read URLs live one minute (§26: short, issued after the permission check).
    static let signedURLSeconds = 60

    private struct LinkRow: Decodable, Sendable { let attachment_id: UUID }
    private struct Row: Decodable, Sendable {
        let id: UUID; let display_name: String; let mime_type: String; let size_bytes: Int64
        let object_path: String; let uploader_id: UUID; let created_at: Date
        var domain: Attachment {
            Attachment(id: id, displayName: display_name, mimeType: mime_type, sizeBytes: size_bytes,
                       objectPath: object_path, uploaderID: uploader_id, createdAt: created_at)
        }
    }
    private struct Prepared: Decodable, Sendable { let attachment_id: UUID; let object_path: String }
    private struct Finalized: Decodable, Sendable { let attachment_id: UUID; let lifecycle: String }

    func attachments(for target: AttachmentTarget) async throws -> [Attachment] {
        let links: [LinkRow] = try await backend.call {
            try await backend.client.from("attachment_links").select("attachment_id")
                .eq(target.linkColumn, value: target.id).execute().value
        }
        guard !links.isEmpty else { return [] }
        let rows: [Row] = try await backend.call {
            try await backend.client.from("attachments").select("id,display_name,mime_type,size_bytes,object_path,uploader_id,created_at")
                .in("id", values: links.map(\.attachment_id.uuidString)).eq("lifecycle", value: "ready")
                .order("created_at").execute().value
        }
        return rows.map(\.domain)
    }

    func upload(_ data: Data, fileName: String, mimeType: String, to target: AttachmentTarget, requestID: UUID) async throws -> Attachment {
        struct PrepareParams: Encodable, Sendable {
            let p_target_type: String, p_target_id: UUID, p_display_name: String, p_mime_type: String
            let p_size_bytes: Int64, p_request_id: UUID
        }
        struct FinalizeParams: Encodable, Sendable { let p_attachment_id: UUID, p_checksum_sha256: String, p_request_id: UUID }
        let name = AttachmentRules.safeName(fileName)
        let prepared: Prepared = try await backend.call {
            try await backend.client.rpc("prepare_attachment", params: PrepareParams(
                p_target_type: target.wireType, p_target_id: target.id, p_display_name: name, p_mime_type: mimeType,
                p_size_bytes: Int64(data.count), p_request_id: requestID)).execute().value
        }
        do {
            try await backend.client.storage.from(Self.bucket)
                .upload(prepared.object_path, data: data, options: FileOptions(contentType: mimeType, upsert: false))
        } catch {
            // A replayed prepare returns the same path; an object already there is the earlier attempt's upload.
            let text = String(describing: error).lowercased()
            if !(text.contains("duplicate") || text.contains("already exists")) {
                throw AppError.server(code: .attachmentIncomplete, fieldErrors: [:], currentVersion: nil, correlationID: nil)
            }
        }
        let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let _: Finalized = try await backend.call {
            try await backend.client.rpc("finalize_attachment", params: FinalizeParams(
                p_attachment_id: prepared.attachment_id, p_checksum_sha256: checksum,
                p_request_id: Self.derivedID(requestID, suffix: "f"))).execute().value
        }
        let uploader = await backend.cache.context?.userID ?? UUID()
        return Attachment(id: prepared.attachment_id, displayName: name, mimeType: mimeType, sizeBytes: Int64(data.count),
                          objectPath: prepared.object_path, uploaderID: uploader, createdAt: Date())
    }

    func signedURL(for attachment: Attachment) async throws -> URL {
        try await backend.call {
            try await backend.client.storage.from(Self.bucket).createSignedURL(path: attachment.objectPath,
                                                                               expiresIn: Self.signedURLSeconds)
        }
    }

    func remove(_ attachment: Attachment, requestID: UUID) async throws {
        struct Params: Encodable, Sendable { let p_attachment_id: UUID, p_request_id: UUID }
        let _: Finalized = try await backend.call {
            try await backend.client.rpc("remove_attachment", params: Params(p_attachment_id: attachment.id,
                                                                            p_request_id: requestID)).execute().value
        }
    }

    /// A stable second request id for the finalize step of the same upload.
    static func derivedID(_ id: UUID, suffix: Character) -> UUID {
        var bytes = id.uuid
        bytes.15 ^= suffix.asciiValue ?? 0x66
        return UUID(uuid: bytes)
    }
}
