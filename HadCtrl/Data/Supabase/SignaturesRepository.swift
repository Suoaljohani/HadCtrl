import Foundation
import Supabase

/// Two-step signature upload (prepare → Storage upload → finalize), API-16/17.
struct SupabaseSignaturesRepository: SignaturesRepository {
    let backend: SupabaseBackend
    static let bucket = "hadctrl-signatures"

    private actor Availability {
        var known: Bool?
        func get() -> Bool? { known }
        func set(_ v: Bool) { known = v }
    }
    private static let availability = Availability()

    func isAvailable() async -> Bool {
        if let known = await Self.availability.get() { return known }
        struct Row: Decodable, Sendable { let id: UUID }
        do {
            let _: [Row] = try await backend.client.from("approval_signatures").select("id").limit(1).execute().value
            await Self.availability.set(true)
            return true
        } catch let error as PostgrestError where error.code == "PGRST205" || error.code == "42P01" {
            // The table does not exist on this server yet.
            await Self.availability.set(false)
            return false
        } catch {
            // Unknown (e.g. offline): try the signature flow; real errors surface there.
            return true
        }
    }

    func sign(_ png: Data, entity: SignatureEntity, purpose: SignaturePurpose, requestID: UUID) async throws {
        struct Prepare: Encodable, Sendable {
            let p_entity_type: String; let p_entity_id: UUID; let p_purpose: String; let p_request_id: UUID
        }
        struct Prepared: Decodable, Sendable { let id: UUID; let path: String }
        struct Finalize: Encodable, Sendable { let p_signature_id: UUID; let p_request_id: UUID }
        let prepared: Prepared = try await backend.call {
            try await backend.client.rpc("prepare_signature", params: Prepare(
                p_entity_type: entity.type, p_entity_id: entity.id, p_purpose: purpose.rawValue, p_request_id: requestID)).execute().value
        }
        do {
            try await backend.client.storage.from(Self.bucket)
                .upload(prepared.path, data: png, options: FileOptions(contentType: "image/png", upsert: false))
        } catch {
            // A replayed prepare returns the same path; an object already there is the earlier attempt's upload.
            let text = String(describing: error).lowercased()
            if !(text.contains("duplicate") || text.contains("already exists")) { throw SupabaseErrorMapper.map(error) }
        }
        _ = try await backend.call {
            try await backend.client.rpc("finalize_signature", params: Finalize(
                p_signature_id: prepared.id,
                p_request_id: SupabaseAttachmentsRepository.derivedID(requestID, suffix: "s"))).execute()
        }
    }

    func signatures(for entity: SignatureEntity) async throws -> [SignatureRecord] {
        guard await isAvailable() else { return [] }
        struct Row: Decodable, Sendable {
            let id: UUID; let signer_id: UUID; let purpose: String; let signed_at: Date; let object_path: String
        }
        let rows: [Row] = try await backend.call {
            try await backend.client.from("approval_signatures").select("id,signer_id,purpose,signed_at,object_path")
                .eq("entity_type", value: entity.type).eq("entity_id", value: entity.id.uuidString)
                .eq("lifecycle", value: "signed").order("signed_at").execute().value
        }
        let names = try await backend.displayNames(Set(rows.map(\.signer_id)))
        var out: [SignatureRecord] = []
        for row in rows {
            var image: Data?
            if let url = try? await backend.client.storage.from(Self.bucket).createSignedURL(path: row.object_path, expiresIn: 60) {
                image = try? await URLSession.shared.data(from: url).0
            }
            out.append(SignatureRecord(id: row.id, signerName: names[row.signer_id] ?? "—",
                                       purpose: SignaturePurpose(rawValue: row.purpose) ?? .approve,
                                       signedAt: row.signed_at, imageData: image))
        }
        return out
    }
}
