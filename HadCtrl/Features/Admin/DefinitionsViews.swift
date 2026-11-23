import SwiftUI
import Observation

// Director-only definitions (D-29): recurring report templates with their
// schedule, and indicators. The server re-checks the director role.

@MainActor
@Observable
final class NewReportTemplateViewModel {
    var draft = NewReportTemplateDraft()
    private(set) var fieldErrors: [String: String] = [:]
    private(set) var error: AppError?
    private(set) var isSaving = false
    /// Set once the template exists, so a failed schedule step is retried alone.
    private(set) var templateID: UUID?
    @ObservationIgnored private var createRequest: (key: String, id: UUID)?
    @ObservationIgnored private var scheduleRequest: (key: String, id: UUID)?
    private let reports: ReportsRepository

    init(reports: ReportsRepository) { self.reports = reports }

    /// Returns the number of departments scheduled, or nil with errors shown.
    func save() async -> Int? {
        fieldErrors = Dictionary(uniqueKeysWithValues: draft.validate().map { ($0.key.rawValue, $0.value) })
        guard fieldErrors.isEmpty else { return nil }
        isSaving = true; error = nil
        defer { isSaving = false }
        do {
            let id: UUID
            if let templateID { id = templateID } else {
                let key = "\(draft.nameAr)|\(draft.frequency.rawValue)|\(draft.wireFields)"
                if createRequest?.key != key { createRequest = (key, UUID()) }
                id = try await reports.createTemplate(draft, requestID: createRequest!.id)
                templateID = id
            }
            let departments = draft.departmentIDs.sorted { $0.uuidString < $1.uuidString }
            let key = "\(id)|\(departments)|\(draft.dueDay)"
            if scheduleRequest?.key != key { scheduleRequest = (key, UUID()) }
            return try await reports.schedule(templateID: id, departmentIDs: departments, dueDay: draft.dueDay,
                                              requestID: scheduleRequest!.id)
        } catch let e as AppError {
            error = e
            if case .server(_, let fields, _, _) = e { fieldErrors.merge(fields) { _, server in server } }
            return nil
        } catch { self.error = .network(offline: false); return nil }
    }
}

@MainActor
@Observable
final class NewIndicatorViewModel {
    var draft = NewIndicatorDraft()
    private(set) var fieldErrors: [String: String] = [:]
    private(set) var error: AppError?
    private(set) var isSaving = false
    @ObservationIgnored private var requestID = UUID()
    @ObservationIgnored private var lastDraft: NewIndicatorDraft?
    private let indicators: IndicatorsRepository

    init(indicators: IndicatorsRepository) { self.indicators = indicators }

    func save() async -> UUID? {
        fieldErrors = Dictionary(uniqueKeysWithValues: draft.validate().map { ($0.key.rawValue, $0.value) })
        guard fieldErrors.isEmpty else { return nil }
        if lastDraft != draft { requestID = UUID(); lastDraft = draft }
        isSaving = true; error = nil
        defer { isSaving = false }
        do { return try await indicators.createIndicator(draft, requestID: requestID) }
        catch let e as AppError {
            error = e
            if case .server(_, let fields, _, _) = e {
                // "definition":"inconsistent_rule" comes from the table's rule checks (§11).
                fieldErrors.merge(fields.mapValues { $0 == "inconsistent_rule" ? String(localized: "قاعدة الاحتساب غير متسقة") : $0 }) { _, s in s }
            }
            return nil
        } catch { self.error = .network(offline: false); return nil }
    }
}

struct NewReportTemplateSheet: View {
    let departments: [Department]
    @State private var model: NewReportTemplateViewModel
    @State private var scheduled: Int?
    @Environment(\.dismiss) private var dismiss

    init(reports: ReportsRepository, departments: [Department]) {
        self.departments = departments.filter { !$0.isArchived }
        _model = State(initialValue: NewReportTemplateViewModel(reports: reports))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                if let scheduled {
                    Section {
                        Label(String(localized: "أُنشئ القالب وجُدول لـ \(scheduled) قسم. تُولَّد التقارير من تبويب التقارير أو تلقائيًا يوميًا."),
                              systemImage: "checkmark.circle").foregroundStyle(Color.hcGood)
                    }
                    .accessibilityIdentifier("template.done")
                }
                Section(String(localized: "التقرير")) {
                    TextField(String(localized: "اسم التقرير (مثل التقرير الشهري)"), text: $model.draft.nameAr)
                        .accessibilityIdentifier("template.name")
                        .disabled(model.templateID != nil)
                    fieldError("name_ar")
                    LabeledContent(String(localized: "التكرار"), value: String(localized: "شهري"))
                }
                Section {
                    ForEach($model.draft.fields) { $field in
                        HStack {
                            TextField(String(localized: "عنوان الحقل"), text: $field.label)
                            Toggle(String(localized: "إلزامي"), isOn: $field.required).labelsHidden()
                                .accessibilityLabel(String(localized: "إلزامي"))
                        }
                    }
                    .onDelete { model.draft.fields.remove(atOffsets: $0) }
                    Button(String(localized: "إضافة حقل")) { model.draft.fields.append(.init()) }
                    fieldError("fields")
                } header: {
                    Text(String(localized: "الحقول"))
                } footer: {
                    Text(String(localized: "المفتاح بجانب كل حقل يحدد ما إذا كان إلزاميًا قبل الإرسال."))
                }
                .disabled(model.templateID != nil)
                Section(String(localized: "الأقسام المطالَبة")) {
                    ForEach(departments) { d in
                        Toggle(d.nameAr, isOn: Binding(get: { model.draft.departmentIDs.contains(d.id) },
                                                       set: { on in
                                                           if on { model.draft.departmentIDs.insert(d.id) }
                                                           else { model.draft.departmentIDs.remove(d.id) }
                                                       }))
                        .accessibilityIdentifier("template.department.\(d.code)")
                    }
                    if departments.isEmpty { Text(String(localized: "أضف قسمًا أولًا")).foregroundStyle(Color.hcSecondaryText) }
                    fieldError("department_ids")
                    Stepper(String(localized: "الاستحقاق: يوم \(model.draft.dueDay) من الشهر التالي"),
                            value: $model.draft.dueDay, in: 1...28)
                    fieldError("due_day")
                }
                if let e = model.error {
                    Section { Label(e.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                }
            }
            .navigationTitle(String(localized: "قالب تقرير جديد"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(scheduled == nil ? String(localized: "إلغاء") : String(localized: "تم")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "حفظ وجدولة")) { Task { if let n = await model.save() { scheduled = n } } }
                        .disabled(model.isSaving || scheduled != nil)
                        .accessibilityIdentifier("template.save")
                }
            }
        }
    }

    @ViewBuilder private func fieldError(_ key: String) -> some View {
        if let message = model.fieldErrors[key] {
            Text(message).font(.hcCaption).foregroundStyle(Color.hcCritical)
        }
    }
}

struct NewIndicatorSheet: View {
    let departments: [Department]
    @State private var model: NewIndicatorViewModel
    @Environment(\.dismiss) private var dismiss

    init(indicators: IndicatorsRepository, departments: [Department]) {
        self.departments = departments.filter { !$0.isArchived }
        _model = State(initialValue: NewIndicatorViewModel(indicators: indicators))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section(String(localized: "المؤشر")) {
                    Picker(String(localized: "القسم"), selection: $model.draft.departmentID) {
                        Text(String(localized: "اختر")).tag(UUID?.none)
                        ForEach(departments) { d in Text(d.nameAr).tag(UUID?.some(d.id)) }
                    }
                    fieldError("department_id")
                    TextField(String(localized: "اسم المؤشر"), text: $model.draft.title)
                        .accessibilityIdentifier("indicator.title")
                    fieldError("title")
                    TextField(String(localized: "الرمز (مثل LAB.TAT)"), text: $model.draft.code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityIdentifier("indicator.code")
                    fieldError("code")
                    TextField(String(localized: "وصف مختصر (اختياري)"), text: $model.draft.description, axis: .vertical)
                }
                Section(String(localized: "طريقة القياس")) {
                    Picker(String(localized: "النوع"), selection: $model.draft.measurementType) {
                        ForEach([MeasurementType.count, .ratio, .duration]) { t in Text(IndicatorText.type(t)).tag(t) }
                    }
                    if model.draft.measurementType == .ratio {
                        TextField(String(localized: "البسط (ماذا يُعد؟)"), text: $model.draft.numeratorDescription)
                        fieldError("numerator")
                        TextField(String(localized: "المقام (من أي مجموع؟)"), text: $model.draft.denominatorDescription)
                        fieldError("denominator")
                    } else {
                        TextField(String(localized: "الوحدة (مثل ساعة، عينة)"), text: $model.draft.unit)
                        fieldError("unit")
                        Toggle(String(localized: "عداد تراكمي (يُحسب بآخر قراءة)"), isOn: $model.draft.cumulative)
                    }
                    TextField(String(localized: "مصدر البيانات"), text: $model.draft.dataSource)
                        .accessibilityIdentifier("indicator.source")
                    fieldError("data_source")
                }
                Section(String(localized: "المستهدف")) {
                    Picker(String(localized: "الاتجاه"), selection: $model.draft.direction) {
                        ForEach([ImprovementDirection.higherIsBetter, .lowerIsBetter, .withinRange], id: \.self) { d in
                            Text(IndicatorText.direction(d)).tag(d)
                        }
                    }
                    switch model.draft.direction {
                    case .withinRange:
                        TextField(String(localized: "الحد الأدنى"), text: $model.draft.rangeMinText).keyboardType(.decimalPad)
                        TextField(String(localized: "الحد الأعلى"), text: $model.draft.rangeMaxText).keyboardType(.decimalPad)
                        fieldError("range")
                    case .lowerIsBetter:
                        Toggle(String(localized: "صفر أحداث (المستهدف صفر)"), isOn: $model.draft.zeroEventRule)
                        if !model.draft.zeroEventRule {
                            TextField(String(localized: "المستهدف"), text: $model.draft.targetText).keyboardType(.decimalPad)
                        }
                        fieldError("target")
                    case .higherIsBetter:
                        TextField(String(localized: "المستهدف"), text: $model.draft.targetText).keyboardType(.decimalPad)
                            .accessibilityIdentifier("indicator.target")
                        fieldError("target")
                    }
                    Text(IndicatorText.rule(for: model.draft.direction, zeroEvent: model.draft.zeroEventRule)).font(.hcFootnote)
                    fieldError("definition")
                }
                if let e = model.error, model.fieldErrors.isEmpty {
                    Section { Label(e.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                }
            }
            .onChange(of: model.draft.direction) { _, d in if d != .lowerIsBetter { model.draft.zeroEventRule = false } }
            .navigationTitle(String(localized: "مؤشر جديد"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "إلغاء")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "حفظ")) { Task { if await model.save() != nil { dismiss() } } }
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("indicator.save")
                }
            }
        }
    }

    @ViewBuilder private func fieldError(_ key: String) -> some View {
        if let message = model.fieldErrors[key] {
            Text(message).font(.hcCaption).foregroundStyle(Color.hcCritical)
        }
    }
}
