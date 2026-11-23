import SwiftUI
import Observation

/// Puts a handwritten signature in front of a decision (D-37). Screens ask the
/// gate instead of calling the decision directly; when the server supports
/// signatures the user signs first, the signature is sealed on the server, and
/// only then does the decision run. Without server support the decision runs as
/// before (Settings shows that signatures await the server update).
@MainActor
@Observable
final class SignatureGate {
    struct Request: Identifiable {
        let id = UUID()
        let entity: SignatureEntity
        let purpose: SignaturePurpose
        let title: String
        let action: @MainActor () async -> Void
    }

    var current: Request?
    private(set) var isAvailable: Bool?
    @ObservationIgnored let repository: SignaturesRepository

    init(repository: SignaturesRepository) { self.repository = repository }

    func refreshAvailability() async { isAvailable = await repository.isAvailable() }

    func request(_ entity: SignatureEntity, purpose: SignaturePurpose, title: String,
                 action: @escaping @MainActor () async -> Void) {
        Task {
            if isAvailable == nil { await refreshAvailability() }
            if isAvailable == true {
                current = Request(entity: entity, purpose: purpose, title: title, action: action)
            } else {
                await action()
            }
        }
    }

    /// Seals the signature, closes the sheet, then runs the decision.
    func complete(_ request: Request, png: Data) async throws {
        try await repository.sign(png, entity: request.entity, purpose: request.purpose, requestID: request.id)
        current = nil
        await request.action()
    }
}

/// The signing sheet: who signs, what for, and a pad drawn with a finger.
struct SignatureSheet: View {
    let request: SignatureGate.Request
    let gate: SignatureGate
    let signerName: String
    @Environment(\.dismiss) private var dismiss
    @State private var strokes: [[CGPoint]] = []
    @State private var isSaving = false
    @State private var error: String?
    @State private var padSize: CGSize = .zero

    private var inkLength: CGFloat {
        strokes.reduce(0) { total, stroke in
            zip(stroke, stroke.dropFirst()).reduce(total) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        }
    }
    private var canSign: Bool { inkLength > 60 && !isSaving }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(request.title).font(.hcTitle).foregroundStyle(Color.hcInk)
                    Text(verbatim: "\(signerName) · \(HCFormat.dateTime(Date()))")
                        .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                }

                SignaturePad(strokes: $strokes, size: $padSize)
                    .frame(height: 230)

                HStack {
                    Button {
                        withAnimation(HCMotion.snappy) { strokes.removeAll() }
                    } label: {
                        Label(String(localized: "مسح"), systemImage: "eraser")
                    }
                    .disabled(strokes.isEmpty || isSaving)
                    .accessibilityIdentifier("signature.clear")
                    Spacer()
                    Text(String(localized: "وقّع بإصبعك داخل الإطار"))
                        .font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                }

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").font(.hcFootnote).foregroundStyle(Color.hcCritical)
                }

                Text(String(localized: "يُحفظ التوقيع مع القرار في سجل التدقيق ولا يمكن تعديله أو حذفه بعد الاعتماد."))
                    .font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Button {
                    Task { await confirm() }
                } label: {
                    HStack {
                        if isSaving { ProgressView().tint(.white) }
                        Text(String(localized: "توقيع و\(request.purpose.title)"))
                    }
                    .font(.hcHeadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.xs)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSign)
                .accessibilityIdentifier("signature.confirm")
            }
            .padding(Spacing.m)
            .background(Color.hcBackground)
            .navigationTitle(String(localized: "التوقيع"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "إلغاء")) { gate.current = nil }
                        .disabled(isSaving)
                        .accessibilityIdentifier("signature.cancel")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    private func confirm() async {
        guard let png = SignaturePad.render(strokes: strokes, size: padSize) else {
            error = String(localized: "تعذر تجهيز صورة التوقيع.")
            return
        }
        isSaving = true
        error = nil
        do {
            try await gate.complete(request, png: png)
        } catch let e as AppError {
            error = e.userMessage
        } catch {
            self.error = AppError.network(offline: false).userMessage
        }
        isSaving = false
    }
}

/// A finger-drawn signature: smooth quadratic strokes in brand ink.
struct SignaturePad: View {
    @Binding var strokes: [[CGPoint]]
    @Binding var size: CGSize
    @State private var current: [CGPoint] = []
    @Environment(\.hcHapticsEnabled) private var haptics

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .fill(Color.hcSurface)
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .strokeBorder(Color.hcPrimary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                // Baseline and the "sign here" mark.
                Path { p in
                    p.move(to: CGPoint(x: 24, y: geo.size.height * 0.72))
                    p.addLine(to: CGPoint(x: geo.size.width - 24, y: geo.size.height * 0.72))
                }
                .stroke(Color.hcSeparator, lineWidth: 1)
                if strokes.isEmpty && current.isEmpty {
                    Image(systemName: "signature")
                        .font(.system(size: 44, weight: .ultraLight))
                        .foregroundStyle(Color.hcSecondaryText.opacity(0.35))
                        .accessibilityHidden(true)
                }
                Canvas { context, _ in
                    for stroke in strokes + [current] {
                        context.stroke(Self.path(stroke), with: .color(Color.hcInk),
                                       style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        let p = value.location
                        guard p.x >= 0, p.y >= 0, p.x <= geo.size.width, p.y <= geo.size.height else { return }
                        current.append(p)
                    }
                    .onEnded { _ in
                        if current.count > 1 { strokes.append(current) }
                        current = []
                    }
            )
            .onAppear { size = geo.size }
            .onChange(of: geo.size) { _, new in size = new }
            .sensoryFeedback(.impact(weight: .light), trigger: strokes.count) { _, _ in haptics }
        }
        .accessibilityElement()
        .accessibilityLabel(String(localized: "مساحة التوقيع"))
        .accessibilityHint(String(localized: "ارسم توقيعك بإصبع واحد"))
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityIdentifier("signature.pad")
    }

    static func path(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        if points.count == 1 { path.addLine(to: first); return path }
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }

    /// Transparent PNG of the strokes, cropped to the ink with a small margin.
    @MainActor static func render(strokes: [[CGPoint]], size: CGSize) -> Data? {
        let all = strokes.flatMap { $0 }
        guard !all.isEmpty, size.width > 0 else { return nil }
        let minX = max((all.map(\.x).min() ?? 0) - 12, 0), maxX = min((all.map(\.x).max() ?? size.width) + 12, size.width)
        let minY = max((all.map(\.y).min() ?? 0) - 12, 0), maxY = min((all.map(\.y).max() ?? size.height) + 12, size.height)
        let box = CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
        let shifted = strokes.map { $0.map { CGPoint(x: $0.x - box.minX, y: $0.y - box.minY) } }
        let view = Canvas { context, _ in
            for stroke in shifted {
                context.stroke(path(stroke), with: .color(Color(red: 0.086, green: 0.204, blue: 0.243)),
                               style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: box.width, height: box.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.isOpaque = false
        return renderer.uiImage?.pngData()
    }
}

/// Signatures recorded on a record, oldest first.
struct SignaturesSection: View {
    let entity: SignatureEntity
    let repository: SignaturesRepository
    /// Changes when a decision is made so the list reloads.
    var refreshKey: Int = 0
    @State private var records: [SignatureRecord] = []

    var body: some View {
        Group {
            if !records.isEmpty {
                Section(String(localized: "التوقيعات")) {
                    ForEach(records) { r in
                        HStack(alignment: .center, spacing: Spacing.s) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: "\(r.purpose.title) · \(r.signerName)").font(.hcSubheadlineBold)
                                Text(HCFormat.dateTime(r.signedAt)).font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                            }
                            Spacer(minLength: 0)
                            if let data = r.imageData, let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .frame(width: 120, height: 48)
                                    .padding(4)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .accessibilityLabel(String(localized: "صورة التوقيع"))
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("signatureRow")
                    }
                }
            }
        }
        .task(id: refreshKey) { records = (try? await repository.signatures(for: entity)) ?? [] }
    }
}

private struct SignatureGateKey: EnvironmentKey {
    static let defaultValue: SignatureGate? = nil
}

extension EnvironmentValues {
    var hcSignatureGate: SignatureGate? {
        get { self[SignatureGateKey.self] }
        set { self[SignatureGateKey.self] = newValue }
    }
}

/// Runs `action` behind the signature gate when one is installed.
@MainActor
func hcSigned(_ gate: SignatureGate?, _ entity: SignatureEntity, purpose: SignaturePurpose, title: String,
              action: @escaping @MainActor () async -> Void) {
    if let gate {
        gate.request(entity, purpose: purpose, title: title, action: action)
    } else {
        Task { await action() }
    }
}
