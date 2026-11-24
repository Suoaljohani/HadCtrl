import SwiftUI
import UIKit
import QuickLook

/// Paginated A4 PDF with real (searchable) text, right-to-left tables, a header row
/// repeated on every page and "page i of N" footers (spec §19). Not a screenshot.
@MainActor
enum PDFExporter {
    static let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
    static let margin: CGFloat = 36

    private enum Op {
        case text(NSAttributedString, CGRect)
        case fill(UIColor, CGRect)
        case line(CGFloat)   // horizontal rule at y
    }

    private static func font(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? "JannaLT-Bold" : "JannaLT-Regular", size: size)
            ?? (bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size))
    }

    private static func attr(_ s: String, _ font: UIFont, _ color: UIColor = .black, rtl: Bool,
                             align: NSTextAlignment? = nil) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        p.alignment = align ?? (rtl ? .right : .left)
        p.lineBreakMode = .byWordWrapping
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    private static func height(_ a: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(a.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                            options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).height)
    }

    static func data(_ doc: ExportDocument, rightToLeft rtl: Bool) -> Data {
        let content = pageRect.insetBy(dx: margin, dy: margin)
        let bottom = content.maxY - 22   // footer space
        var pages: [[Op]] = [[]]
        var y = content.minY

        func newPage() { pages.append([]); y = content.minY }
        func add(_ op: Op) { pages[pages.count - 1].append(op) }
        func paragraph(_ a: NSAttributedString, gap: CGFloat = 4) {
            let h = height(a, width: content.width)
            if y + h > bottom { newPage() }
            add(.text(a, CGRect(x: content.minX, y: y, width: content.width, height: h)))
            y += h + gap
        }

        // Header
        paragraph(attr(doc.title, font(18, bold: true), rtl: rtl), gap: 2)
        paragraph(attr("\(doc.organization) — \(doc.periodTitle)", font(11), .darkGray, rtl: rtl), gap: 2)
        paragraph(attr(doc.scope, font(10), .darkGray, rtl: rtl), gap: 2)
        paragraph(attr(String(localized: "أُنشئ في \(HCFormat.dateTime(doc.generatedAt))"), font(9), .gray, rtl: rtl), gap: 8)
        // Status banner: draft data is never presented as final.
        let banner = attr(doc.statusNote, font(10, bold: true), doc.isFinal ? UIColor(red: 0.12, green: 0.42, blue: 0.27, alpha: 1)
                                                                   : UIColor(red: 0.55, green: 0.33, blue: 0.0, alpha: 1), rtl: rtl)
        let bh = height(banner, width: content.width - 16) + 12
        add(.fill(doc.isFinal ? UIColor(red: 0.88, green: 0.96, blue: 0.91, alpha: 1) : UIColor(red: 1, green: 0.95, blue: 0.85, alpha: 1),
                  CGRect(x: content.minX, y: y, width: content.width, height: bh)))
        add(.text(banner, CGRect(x: content.minX + 8, y: y + 6, width: content.width - 16, height: bh - 12)))
        y += bh + 12

        // Summary as a two-column key/value list.
        if !doc.summary.isEmpty {
            paragraph(attr(String(localized: "الملخص"), font(13, bold: true), rtl: rtl), gap: 4)
            for item in doc.summary {
                let label = attr(item.label, font(10), .darkGray, rtl: rtl)
                let value = attr(item.value, font(10, bold: true), rtl: rtl, align: rtl ? .left : .right)
                let h = max(height(label, width: content.width * 0.6), height(value, width: content.width * 0.4))
                if y + h > bottom { newPage() }
                let labelX = rtl ? content.minX + content.width * 0.4 : content.minX
                let valueX = rtl ? content.minX : content.minX + content.width * 0.6
                add(.text(label, CGRect(x: labelX, y: y, width: content.width * 0.6, height: h)))
                add(.text(value, CGRect(x: valueX, y: y, width: content.width * 0.4, height: h)))
                y += h + 3
                add(.line(y))
                y += 3
            }
            y += 10
        }

        // Tables with the header row repeated after every page break.
        for table in doc.tables {
            let weights: [CGFloat] = table.columns.indices.map { i in
                let lengths = [table.columns[i].count] + table.rows.prefix(40).map { $0.indices.contains(i) ? $0[i].count : 0 }
                return CGFloat(min(max(lengths.reduce(0, +) / max(lengths.count, 1), 4), 28))
            }
            let total = weights.reduce(0, +)
            let widths = weights.map { content.width * $0 / total }
            func columnX(_ i: Int) -> CGFloat {
                let before = widths.prefix(i).reduce(0, +)
                return rtl ? content.maxX - before - widths[i] : content.minX + before
            }
            func row(_ cells: [String], bold: Bool, shade: UIColor?) {
                let attrs = cells.enumerated().map { i, c in
                    attr(c, font(8.5, bold: bold), rtl: rtl, align: table.numericColumns.contains(i) ? .center : nil)
                }
                let h = (attrs.enumerated().map { height($0.element, width: widths[$0.offset] - 6) }.max() ?? 10) + 6
                if let shade { add(.fill(shade, CGRect(x: content.minX, y: y, width: content.width, height: h))) }
                for (i, a) in attrs.enumerated() {
                    add(.text(a, CGRect(x: columnX(i) + 3, y: y + 3, width: widths[i] - 6, height: h - 6)))
                }
                y += h
                add(.line(y))
            }
            let header = UIColor(red: 0.90, green: 0.94, blue: 0.95, alpha: 1)
            func titleAndHeader(continued: Bool) {
                let title = continued ? table.title + " " + String(localized: "(تابع)") : table.title
                paragraph(attr(title, font(13, bold: true), rtl: rtl), gap: 4)
                row(table.columns, bold: true, shade: header)
            }
            if y + 70 > bottom { newPage() }
            titleAndHeader(continued: false)
            for cells in table.rows {
                let estimate = (cells.enumerated().map {
                    height(attr($0.element, font(8.5), rtl: rtl), width: widths[min($0.offset, widths.count - 1)] - 6)
                }.max() ?? 10) + 6
                if y + estimate > bottom { newPage(); titleAndHeader(continued: true) }
                row(cells, bold: false, shade: nil)
            }
            y += 14
        }

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect, format: {
            let f = UIGraphicsPDFRendererFormat()
            f.documentInfo = [kCGPDFContextTitle as String: doc.title, kCGPDFContextCreator as String: "HadCtrl"]
            return f
        }())
        return renderer.pdfData { ctx in
            for (index, ops) in pages.enumerated() {
                ctx.beginPage()
                for op in ops {
                    switch op {
                    case .text(let a, let r):
                        a.draw(with: r, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                    case .fill(let color, let r):
                        color.setFill(); UIBezierPath(roundedRect: r, cornerRadius: 4).fill()
                    case .line(let ly):
                        UIColor(white: 0.85, alpha: 1).setStroke()
                        let p = UIBezierPath(); p.move(to: CGPoint(x: content.minX, y: ly)); p.addLine(to: CGPoint(x: content.maxX, y: ly))
                        p.lineWidth = 0.5; p.stroke()
                    }
                }
                let footer = attr(String(localized: "صفحة \(index + 1) من \(pages.count)") + " · HadCtrl · " + doc.periodTitle,
                                  font(8), .gray, rtl: rtl, align: .center)
                footer.draw(with: CGRect(x: content.minX, y: content.maxY - 12, width: content.width, height: 14),
                            options: [.usesLineFragmentOrigin], context: nil)
            }
        }
    }
}

/// App-owned temporary export files: replaced on each export and removed on sign-out.
enum ExportFiles {
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("hc-exports", isDirectory: true) }

    static func clear() { try? FileManager.default.removeItem(at: directory) }

    static func write(_ data: Data, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
}

/// Director's export (spec §19): choose scope and format, build, preview, share.
struct ExportSheet: View {
    let context: UserContext
    let dependencies: DependencyContainer
    let periodID: UUID?
    let periodTitle: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.layoutDirection) private var direction
    @State private var departments: [Department] = []
    @State private var departmentID: UUID?
    @State private var includePDF = true
    @State private var includeCSV = true
    @State private var working = false
    @State private var files: [URL] = []
    @State private var error: String?
    @State private var preview: URL?
    @State private var isDraft = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(String(localized: "الفترة"), value: periodTitle)
                    Picker(String(localized: "النطاق"), selection: $departmentID) {
                        Text(String(localized: "كل الأقسام")).tag(UUID?.none)
                        ForEach(departments) { d in Text(d.nameAr).tag(UUID?.some(d.id)) }
                    }
                    .accessibilityIdentifier("export.scope")
                } footer: {
                    Text(String(localized: "يشمل الملف ما يحق لك رؤيته فقط، مع اسم المستشفى والفترة ووقت الإنشاء وحالة اعتماد البيانات."))
                }
                Section(String(localized: "الصيغة")) {
                    Toggle(isOn: $includePDF) { Label("PDF", systemImage: "doc.richtext") }
                        .accessibilityIdentifier("export.pdf")
                    Toggle(isOn: $includeCSV) { Label("CSV", systemImage: "tablecells") }
                        .accessibilityIdentifier("export.csv")
                }
                Section {
                    Button {
                        Task { await build() }
                    } label: {
                        HStack {
                            if working { ProgressView() }
                            Text(String(localized: "إنشاء الملفات")).frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(working || periodID == nil || (!includePDF && !includeCSV))
                    .accessibilityIdentifier("export.build")
                }
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                }
                if !files.isEmpty {
                    Section {
                        if isDraft {
                            Label(String(localized: "تحتوي الملفات على بيانات غير نهائية ومعلّمة بذلك."), systemImage: "exclamationmark.circle")
                                .foregroundStyle(Color.hcWarning).font(.hcFootnote)
                        }
                        ForEach(files, id: \.self) { url in
                            HStack {
                                Label(url.lastPathComponent, systemImage: url.pathExtension == "pdf" ? "doc.richtext" : "tablecells")
                                    .font(.hcFootnote).lineLimit(1)
                                Spacer()
                                Button(String(localized: "معاينة")) { preview = url }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        ShareLink(items: files) {
                            Label(String(localized: "مشاركة"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("export.share")
                    } header: { Text(String(localized: "الملفات الجاهزة")) }
                    .accessibilityIdentifier("export.ready")
                }
            }
            .navigationTitle(String(localized: "تصدير ملخص"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(String(localized: "إغلاق")) { dismiss() } } }
            .quickLookPreview($preview)
            .task { departments = ((try? await dependencies.departments.departments()) ?? []).filter { !$0.isArchived } }
        }
    }

    private func build() async {
        guard let periodID else { return }
        working = true; error = nil; files = []
        defer { working = false }
        do {
            let dashboardRepo = dependencies.dashboard, indicatorRepo = dependencies.indicators, reportRepo = dependencies.reports
            async let snapshotRequest = dashboardRepo.snapshot(periodID: periodID)
            async let indicatorRequest = indicatorRepo.indicators(periodID: periodID)
            async let reportRequest = reportRepo.reports(periodID: periodID)
            let snapshot = try await snapshotRequest
            let indicators = try await indicatorRequest
            let reports = try await reportRequest
            let doc = ExportBuilder.build(
                organization: context.organizationName, periodTitle: periodTitle, snapshot: snapshot,
                indicators: indicators, reports: reports, departmentID: departmentID,
                departmentName: departments.first { $0.id == departmentID }?.nameAr, now: Date(), style: NumberStyle())
            isDraft = !doc.isFinal
            ExportFiles.clear()
            let stamp = Self.stamp.string(from: doc.generatedAt)
            let base = "HadCtrl-\(departments.first { $0.id == departmentID }?.code ?? "ALL")-\(stamp)"
            var out: [URL] = []
            if includePDF {
                out.append(try ExportFiles.write(PDFExporter.data(doc, rightToLeft: direction == .rightToLeft), name: base + ".pdf"))
            }
            if includeCSV { out.append(try ExportFiles.write(CSVWriter.data(doc), name: base + ".csv")) }
            files = out
        } catch let e as AppError {
            error = e.userMessage
        } catch {
            self.error = AppError.network(offline: false).userMessage
        }
    }

    private static var stamp: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmm"
        return f
    }
}
