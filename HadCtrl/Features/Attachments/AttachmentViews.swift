import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import Observation

/// App-owned temporary copies for Quick Look; removed on sign-out (§26).
enum AttachmentPreviewCache {
    static var directory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hc-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func clear() { try? FileManager.default.removeItem(at: directory) }

    /// Downloads a signed URL into the cache (file URLs, as in demo mode, are used directly).
    static func localCopy(of url: URL, name: String) async throws -> URL {
        if url.isFileURL { return url }
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AppError.server(code: .notFound, fieldErrors: [:], currentVersion: nil, correlationID: nil)
        }
        let target = directory.appendingPathComponent(UUID().uuidString + "-" + AttachmentRules.safeName(name))
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }
}

@MainActor
@Observable
final class AttachmentsModel {
    private(set) var items: LoadState<[Attachment]> = .idle
    private(set) var isUploading = false
    private(set) var error: String?
    var previewURL: URL?
    let target: AttachmentTarget
    private let repository: AttachmentsRepository

    init(target: AttachmentTarget, repository: AttachmentsRepository) {
        self.target = target
        self.repository = repository
    }

    func load() async {
        items = .loading(previous: items.value)
        do { items = .loaded(try await repository.attachments(for: target)) }
        catch { items = .failed(error as? AppError ?? .network(offline: false), previous: items.value) }
    }

    func add(_ data: Data, name: String, mimeType: String?) async {
        error = nil
        switch AttachmentRules.check(mimeType: mimeType, size: Int64(data.count), existing: items.value?.count ?? 0) {
        case .type?: error = String(localized: "نوع الملف غير مسموح (PDF أو صورة أو جدول)."); return
        case .size?: error = String(localized: "الحد الأقصى ٢٠ ميغابايت للملف."); return
        case .tooMany?: error = String(localized: "الحد الأقصى ١٠ ملفات لكل سجل."); return
        case nil: break
        }
        isUploading = true
        defer { isUploading = false }
        do {
            _ = try await repository.upload(data, fileName: name, mimeType: mimeType!, to: target, requestID: UUID())
            await load()
        } catch {
            self.error = (error as? AppError ?? .network(offline: false)).userMessage
        }
    }

    func open(_ a: Attachment) async {
        error = nil
        do {
            let signed = try await repository.signedURL(for: a)
            previewURL = try await AttachmentPreviewCache.localCopy(of: signed, name: a.displayName)
        } catch {
            self.error = (error as? AppError)?.userMessage ?? String(localized: "تعذر فتح الملف.")
        }
    }

    func remove(_ a: Attachment) async {
        error = nil
        do { try await repository.remove(a, requestID: UUID()); await load() }
        catch { self.error = (error as? AppError ?? .network(offline: false)).userMessage }
    }
}

/// A list section with the record's evidence; adding/removing only when `canEdit`.
struct AttachmentsSection: View {
    let canEdit: Bool
    var note: String?
    @State private var model: AttachmentsModel
    @State private var photo: PhotosPickerItem?
    @State private var importing = false

    init(target: AttachmentTarget, canEdit: Bool, repository: AttachmentsRepository, note: String? = nil) {
        self.canEdit = canEdit
        self.note = note
        _model = State(initialValue: AttachmentsModel(target: target, repository: repository))
    }

    var body: some View {
        Section {
            switch model.items {
            case .idle, .loading(nil): SkeletonRows(rows: 1)
            case .failed(let e, nil): Text(e.userMessage).foregroundStyle(Color.hcCritical)
            case .loaded(let list), .loading(let list?), .failed(_, let list?):
                if list.isEmpty { Text(String(localized: "لا توجد شواهد مرفقة")).foregroundStyle(Color.hcSecondaryText) }
                ForEach(list) { a in
                    Button { Task { await model.open(a) } } label: { row(a) }
                        .buttonStyle(.plain)
                        .swipeActions {
                            if canEdit {
                                Button(String(localized: "حذف"), role: .destructive) { Task { await model.remove(a) } }
                            }
                        }
                        .accessibilityIdentifier("attachment.\(a.displayName)")
                }
            }
            if model.isUploading { HStack { ProgressView(); Text(String(localized: "جارٍ رفع الملف والتحقق منه…")) } }
            if let error = model.error { Text(error).font(.hcFootnote).foregroundStyle(Color.hcCritical) }
            if canEdit {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(String(localized: "إرفاق صورة"), systemImage: "photo")
                }
                .disabled(model.isUploading)
                Button { importing = true } label: { Label(String(localized: "إرفاق ملف (PDF أو جدول)"), systemImage: "doc") }
                    .disabled(model.isUploading)
                    .accessibilityIdentifier("attachment.addFile")
            }
        } header: {
            Text(String(localized: "الشواهد والمرفقات"))
        } footer: {
            if let note { Text(note) }
        }
        .task { if case .idle = model.items { await model.load() } }
        .quickLookPreview($model.previewURL)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                defer { photo = nil }
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
                let ext = type?.preferredFilenameExtension ?? "jpg"
                await model.add(data, name: "صورة-\(Int(Date().timeIntervalSince1970)).\(ext)",
                                mimeType: type?.preferredMIMEType.flatMap { AttachmentRules.allowedTypes.values.contains($0) ? $0 : nil }
                                    ?? AttachmentRules.mimeType(forExtension: ext))
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes) { result in
            guard case .success(let url) = result else { return }
            Task {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                await model.add(data, name: url.lastPathComponent, mimeType: AttachmentRules.mimeType(forExtension: url.pathExtension))
            }
        }
    }

    private static var importTypes: [UTType] {
        [.pdf, .jpeg, .png, .heic, .commaSeparatedText] + [UTType(filenameExtension: "xlsx")].compactMap { $0 }
    }

    private func row(_ a: Attachment) -> some View {
        HStack {
            Image(systemName: a.mimeType == "application/pdf" ? "doc.richtext" : (a.mimeType.hasPrefix("image/") ? "photo" : "tablecells"))
                .foregroundStyle(Color.hcPrimary).accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(a.displayName).lineLimit(1)
                Text(AttachmentRules.sizeText(a.sizeBytes)).font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
            }
            Spacer()
            Image(systemName: "eye").foregroundStyle(Color.hcSecondaryText).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(String(localized: "يفتح معاينة الملف"))
    }
}
