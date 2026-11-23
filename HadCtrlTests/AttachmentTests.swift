import Foundation
import Testing
@testable import HadCtrl

@Suite("Evidence attachments (§26)", .serialized)
@MainActor
struct AttachmentTests {
    let clock = FixedClock(date: ISO8601DateFormatter().date(from: "2026-11-23T09:00:00Z")!)

    @Test("allowed types, 20 MB and 10 files per record are checked before any upload")
    func rules() {
        #expect(AttachmentRules.check(mimeType: "application/pdf", size: 1_000, existing: 0) == nil)
        #expect(AttachmentRules.check(mimeType: "application/x-msdownload", size: 1_000, existing: 0) == .type)
        #expect(AttachmentRules.check(mimeType: nil, size: 1_000, existing: 0) == .type)
        #expect(AttachmentRules.check(mimeType: "image/png", size: AttachmentRules.maxBytes + 1, existing: 0) == .size)
        #expect(AttachmentRules.check(mimeType: "image/png", size: 0, existing: 0) == .size)
        #expect(AttachmentRules.check(mimeType: "image/png", size: 10, existing: 10) == .tooMany)
        #expect(AttachmentRules.mimeType(forExtension: "PDF") == "application/pdf")
        #expect(AttachmentRules.mimeType(forExtension: "exe") == nil)
    }

    @Test("display names never carry paths or control characters")
    func safeNames() {
        #expect(AttachmentRules.safeName("../../etc/passwd") == "....etcpasswd")
        #expect(AttachmentRules.safeName("محضر\u{0007}الاجتماع.pdf") == "محضرالاجتماع.pdf")
        #expect(AttachmentRules.safeName("  ") == "file")
        #expect(AttachmentRules.safeName(String(repeating: "أ", count: 300)).count == 200)
    }

    @Test("the finalize step uses a stable request id derived from the upload's id")
    func derivedRequestID() {
        let id = UUID()
        #expect(SupabaseAttachmentsRepository.derivedID(id, suffix: "f") == SupabaseAttachmentsRepository.derivedID(id, suffix: "f"))
        #expect(SupabaseAttachmentsRepository.derivedID(id, suffix: "f") != id)
    }

    @Test("an upload retried with the same request id adds one file; the model reports rule problems")
    func uploadAndRetry() async throws {
        let store = MockStore(clock: clock)
        let repo = MockRepositories(store: store, clock: clock, demoUser: MockStore.Fixture.headLab).attachments
        let target = AttachmentTarget.achievement(MockAchievementStore.id(3))
        let request = UUID()
        let data = Data("%PDF-1.4 test".utf8)
        let a = try await repo.upload(data, fileName: "شاهد.pdf", mimeType: "application/pdf", to: target, requestID: request)
        let b = try await repo.upload(data, fileName: "شاهد.pdf", mimeType: "application/pdf", to: target, requestID: request)
        #expect(a.id == b.id)
        #expect(try await repo.attachments(for: target).count == 1)

        let model = AttachmentsModel(target: target, repository: repo)
        await model.load()
        await model.add(Data([0x4D, 0x5A]), name: "x.exe", mimeType: nil)
        #expect(model.error != nil, "unsupported types are refused before upload")
        #expect(model.items.value?.count == 1)
        await model.add(Data([0x89, 0x50]), name: "صورة.png", mimeType: "image/png")
        #expect(model.items.value?.count == 2)
    }
}
