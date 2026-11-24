import Foundation

// Period / department summary export (spec §19, D-40). The document is built from
// data the caller is already allowed to read; it states the hospital, period,
// scope, generation time and whether the data is final. Unapproved results are
// labelled "draft / not final" — the app never calls an export "the official
// approved report".

struct ExportTable: Sendable, Equatable {
    let title: String
    let columns: [String]
    /// Column indexes holding numbers: never prefixed by the formula guard.
    let numericColumns: Set<Int>
    let rows: [[String]]
}

struct ExportDocument: Sendable, Equatable {
    let title: String
    let organization: String
    let periodTitle: String
    let scope: String
    let generatedAt: Date
    let isFinal: Bool
    /// "Draft / not final" or "Final result", plus why.
    let statusNote: String
    let summary: [(label: String, value: String)]
    let tables: [ExportTable]

    static func == (l: Self, r: Self) -> Bool {
        l.title == r.title && l.periodTitle == r.periodTitle && l.scope == r.scope && l.isFinal == r.isFinal
            && l.tables == r.tables && l.summary.map(\.value) == r.summary.map(\.value)
    }
}

enum ExportBuilder {
    /// - Parameters:
    ///   - departmentID: nil for the whole hospital (as far as the caller may see).
    ///   - style: number display for the PDF; CSV always uses Latin digits.
    static func build(organization: String, periodTitle: String, snapshot: DashboardSnapshot,
                      indicators: [IndicatorSummary], reports: [ReportItem], departmentID: UUID?,
                      departmentName: String?, now: Date, style: NumberStyle) -> ExportDocument {
        let inScope: (UUID?) -> Bool = { id in departmentID == nil || id == departmentID }
        let inds = indicators.filter { inScope($0.departmentID) }
        let reps = reports.filter { inScope($0.departmentID) }
        let depts = snapshot.departments.filter { inScope($0.department.id) }
        let pendingReadings = inds.contains { $0.latestStatus == .submitted }
        let openReports = reps.contains { ![.approved, .waived].contains($0.status) }
        let isFinal = snapshot.verdict == .final && !pendingReadings && !openReports

        var notes: [String] = []
        if snapshot.verdict != .final { notes.append(snapshot.verdict.title) }
        if pendingReadings { notes.append(String(localized: "قراءات بانتظار الاعتماد")) }
        if openReports { notes.append(String(localized: "تقارير غير معتمدة بعد")) }
        let statusNote = isFinal
            ? String(localized: "بيانات معتمدة لفترة مكتملة")
            : String(localized: "مسودة / بيانات غير نهائية") + " — " + notes.joined(separator: "، ")

        var summary: [(label: String, value: String)] = []
        if departmentID == nil {
            let score = snapshot.verdict == .insufficientData ? nil : snapshot.measuredScore
            summary.append((String(localized: "النتيجة المقاسة للمؤشرات"), score.map { style.percent($0) } ?? String(localized: "لا حكم إجمالي")))
            summary.append((String(localized: "تغطية البيانات"), style.percent(snapshot.coverage)))
            if let u = snapshot.departmentsUpdated, let t = snapshot.departmentsTotal {
                summary.append((String(localized: "الأقسام المحدّثة"), "\(style.format(Decimal(u), fractionDigits: 0)) / \(style.format(Decimal(t), fractionDigits: 0))"))
            }
            for r in snapshot.readings {
                let v = r.denominator.map { "\(style.format(Decimal(r.numerator), fractionDigits: 0)) / \(style.format(Decimal($0), fractionDigits: 0))" }
                    ?? style.format(Decimal(r.numerator), fractionDigits: 0)
                summary.append((r.metric.title, v))
            }
        } else if let p = depts.first {
            summary.append((String(localized: "مهام مفتوحة"), style.format(Decimal(p.openTasks), fractionDigits: 0)))
            summary.append((String(localized: "مهام متأخرة"), style.format(Decimal(p.overdueTasks), fractionDigits: 0)))
            summary.append((String(localized: "تقارير مستحقة"), style.format(Decimal(p.reportsDue), fractionDigits: 0)))
            summary.append((String(localized: "تغطية البيانات"), p.coverage.map { style.percent($0) } ?? String(localized: "لم يُحدّث")))
        }

        var tables: [ExportTable] = []
        if departmentID == nil && !depts.isEmpty {
            tables.append(ExportTable(
                title: String(localized: "الأقسام"),
                columns: [String(localized: "القسم"), String(localized: "الرئيس"), String(localized: "مهام مفتوحة"),
                          String(localized: "مهام متأخرة"), String(localized: "تقارير مستحقة"), String(localized: "التغطية (%)")],
                numericColumns: [2, 3, 4, 5],
                rows: depts.map { p in
                    [p.department.nameAr, p.department.headName ?? "—", "\(p.openTasks)", "\(p.overdueTasks)", "\(p.reportsDue)",
                     p.coverage.map { NumberStyle(digits: .latin).format($0) } ?? ""]
                }))
        }
        if !inds.isEmpty {
            tables.append(ExportTable(
                title: String(localized: "المؤشرات"),
                columns: [String(localized: "الرمز"), String(localized: "المؤشر"), String(localized: "القسم"),
                          String(localized: "المستهدف"), String(localized: "الفعلي المعتمد"), String(localized: "الوحدة"),
                          String(localized: "الحالة")],
                numericColumns: [3, 4],
                rows: inds.map { i in
                    let latin = NumberStyle(digits: .latin)
                    let status: String
                    if i.latestStatus == .submitted { status = String(localized: "قراءة بانتظار الاعتماد (غير نهائية)") }
                    else if i.actual == nil { status = String(localized: "لم يُحدّث") }
                    else { status = String(localized: "معتمدة") }
                    return [i.code, i.title, i.departmentName, i.target.map { latin.format($0) } ?? "",
                            i.actual.map { latin.format($0) } ?? "", i.unit, status]
                }))
        }
        if !reps.isEmpty {
            tables.append(ExportTable(
                title: String(localized: "التقارير الدورية"),
                columns: [String(localized: "التقرير"), String(localized: "القسم"), String(localized: "الحالة"),
                          String(localized: "الاستحقاق"), String(localized: "أول إرسال"), String(localized: "في الموعد")],
                numericColumns: [],
                rows: reps.map { r in
                    [r.templateName, r.departmentName, r.status.title, HCFormat.dateTime(r.dueAt),
                     r.firstSubmittedAt.map { HCFormat.dateTime($0) } ?? "—",
                     r.submittedOnTime.map { $0 ? String(localized: "نعم") : String(localized: "لا") } ?? "—"]
                }))
        }

        let scope = departmentName.map { String(localized: "قسم: \($0)") } ?? String(localized: "كل الأقسام المصرّح بها")
        return ExportDocument(title: String(localized: "ملخص الأداء والتنفيذ"), organization: organization,
                              periodTitle: periodTitle, scope: scope, generatedAt: now, isFinal: isFinal,
                              statusNote: statusNote, summary: summary, tables: tables)
    }
}

/// CSV for spreadsheets (§19): UTF-8 with BOM so Arabic opens correctly, RFC 4180
/// quoting, and a guard against formula injection in free-text cells.
enum CSVWriter {
    static func data(_ doc: ExportDocument) -> Data {
        var lines: [[String]] = []
        lines.append([doc.title])
        lines.append([String(localized: "المستشفى"), doc.organization])
        lines.append([String(localized: "الفترة"), doc.periodTitle])
        lines.append([String(localized: "النطاق"), doc.scope])
        lines.append([String(localized: "وقت الإنشاء"), ISO8601DateFormatter().string(from: doc.generatedAt)])
        lines.append([String(localized: "حالة البيانات"), doc.statusNote])
        lines.append([])
        for item in doc.summary { lines.append([item.label, item.value]) }
        var text = lines.map { row in row.map { cell($0, numeric: false) }.joined(separator: ",") }.joined(separator: "\r\n")
        for table in doc.tables {
            text += "\r\n\r\n" + cell(table.title, numeric: false)
            text += "\r\n" + table.columns.map { cell($0, numeric: false) }.joined(separator: ",")
            for row in table.rows {
                text += "\r\n" + row.enumerated().map { cell($0.element, numeric: table.numericColumns.contains($0.offset)) }
                    .joined(separator: ",")
            }
        }
        return Data([0xEF, 0xBB, 0xBF]) + Data((text + "\r\n").utf8)
    }

    /// One CSV field. Text starting with = + - @ tab or CR gets a leading apostrophe so
    /// spreadsheets do not evaluate it; numeric columns keep negative numbers intact.
    static func cell(_ raw: String, numeric: Bool) -> String {
        var s = raw
        if !numeric, let first = s.unicodeScalars.first, ["=", "+", "-", "@", "\t", "\r"].contains(first) {
            s = "'" + s
        }
        if s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") || s.hasPrefix(" ") || s.hasSuffix(" ") {
            s = "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}
