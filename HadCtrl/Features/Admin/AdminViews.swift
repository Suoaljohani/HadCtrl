import SwiftUI
import UIKit

/// Departments and employees for the director / system admin (D-25).
struct AdminHubView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    @State private var model: AdminHubViewModel
    @State private var sheet: Sheet?

    enum Sheet: Identifiable { case department, employee, reportTemplate, indicator
        var id: Self { self } }

    init(context: UserContext, dependencies: DependencyContainer) {
        self.context = context
        self.dependencies = dependencies
        _model = State(initialValue: AdminHubViewModel(admin: dependencies.admin, directory: dependencies.departments))
    }

    var body: some View {
        List {
            Section {
                Button { sheet = .department } label: { Label(String(localized: "إضافة قسم"), systemImage: "plus.rectangle.on.folder") }
                    .accessibilityIdentifier("admin.addDepartment")
                switch model.departments {
                case .idle, .loading(nil): ProgressView()
                case .failed(let e, _): Text(e.userMessage).foregroundStyle(Color.hcCritical)
                case .loaded(let items) where items.isEmpty:
                    Text(String(localized: "لا توجد أقسام بعد")).foregroundStyle(Color.hcSecondaryText)
                case .loaded(let items), .loading(let items?):
                    ForEach(items) { d in
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            HStack {
                                Text(d.nameAr).font(.hcHeadline)
                                Spacer()
                                Text(d.code).font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                                    .environment(\.layoutDirection, .leftToRight)
                            }
                            Text(d.headName.map { String(localized: "الرئيس: \($0)") } ?? String(localized: "بلا رئيس بعد"))
                                .font(.hcFootnote).foregroundStyle(d.headName == nil ? Color.hcWarning : Color.hcSecondaryText)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: { Text(String(localized: "الأقسام")) }

            Section {
                Button { sheet = .employee } label: { Label(String(localized: "إضافة موظف"), systemImage: "person.badge.plus") }
                    .accessibilityIdentifier("admin.addEmployee")
                switch model.people {
                case .idle, .loading(nil): ProgressView()
                case .failed(let e, _): Text(e.userMessage).foregroundStyle(Color.hcCritical)
                case .loaded(let items), .loading(let items?):
                    ForEach(items) { p in PersonRow(person: p) }
                }
            } header: { Text(String(localized: "الموظفون")) }

            // Obligations and measures are defined by the director only (D-29).
            if context.isDirector {
                Section {
                    Button { sheet = .reportTemplate } label: { Label(String(localized: "قالب تقرير دوري جديد"), systemImage: "doc.badge.plus") }
                        .accessibilityIdentifier("admin.addTemplate")
                    Button { sheet = .indicator } label: { Label(String(localized: "مؤشر أداء جديد"), systemImage: "chart.line.uptrend.xyaxis") }
                        .accessibilityIdentifier("admin.addIndicator")
                } header: {
                    Text(String(localized: "التقارير والمؤشرات"))
                } footer: {
                    Text(String(localized: "يُعتمد التعريف عند حفظه، ويسري من بداية الشهر الحالي."))
                }
            }
        }
        .navigationTitle(String(localized: "الأقسام والموظفون"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $sheet, onDismiss: { Task { await model.load() } }) { which in
            switch which {
            case .department: NewDepartmentSheet(admin: dependencies.admin)
            case .employee:
                NewEmployeeSheet(context: context, admin: dependencies.admin,
                                 departments: model.departments.value ?? [])
            case .reportTemplate:
                NewReportTemplateSheet(reports: dependencies.reports, departments: model.departments.value ?? [])
            case .indicator:
                NewIndicatorSheet(indicators: dependencies.indicators, departments: model.departments.value ?? [])
            }
        }
    }
}

struct PersonRow: View {
    let person: PersonSummary

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack {
                Text(person.displayName).font(.hcHeadline)
                if person.mustChangePassword {
                    StatusBadge(text: String(localized: "لم يغيّر كلمة المرور المؤقتة"), tone: .warning)
                }
            }
            if let title = person.jobTitle { Text(title).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText) }
            ForEach(Array(person.assignments.enumerated()), id: \.offset) { _, a in
                Text(verbatim: "\(a.role == .head ? String(localized: "رئيس") : String(localized: "منسق")) — \(a.departmentName)\(a.isPrimary ? String(localized: " (أساسي)") : "")")
                    .font(.hcFootnote)
            }
            if person.orgRoles.contains(.hospitalDirector) { Text(String(localized: "مدير المستشفى")).font(.hcFootnote) }
            if person.orgRoles.contains(.systemAdmin) { Text(String(localized: "مسؤول تقني")).font(.hcFootnote) }
            if person.orgRoles.contains(.executiveViewer) { Text(String(localized: "مشاهد تنفيذي")).font(.hcFootnote) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct NewDepartmentSheet: View {
    @State private var model: NewDepartmentViewModel
    @Environment(\.dismiss) private var dismiss

    init(admin: AdminRepository) { _model = State(initialValue: NewDepartmentViewModel(admin: admin)) }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "اسم القسم"), text: $model.draft.nameAr)
                        .accessibilityIdentifier("department.name")
                    fieldError("name_ar")
                    TextField(String(localized: "الرمز (مثل LAB)"), text: $model.draft.code)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                        .accessibilityIdentifier("department.code")
                    fieldError("code")
                    Picker(String(localized: "التصنيف"), selection: $model.draft.category) {
                        Text(String(localized: "طبي")).tag(DepartmentCategory.medical)
                        Text(String(localized: "فني")).tag(DepartmentCategory.technical)
                        Text(String(localized: "إداري")).tag(DepartmentCategory.administrative)
                    }
                }
                if let e = model.error, model.fieldErrors.isEmpty {
                    Section { Label(e.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                }
            }
            .navigationTitle(String(localized: "قسم جديد"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "إلغاء")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "حفظ")) { Task { if await model.save() != nil { dismiss() } } }
                        .disabled(model.isSaving)
                        .accessibilityIdentifier("department.save")
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

struct NewEmployeeSheet: View {
    let context: UserContext
    let departments: [Department]
    @State private var model: NewEmployeeViewModel
    @State private var result: EmployeeCreationResult?
    @Environment(\.dismiss) private var dismiss

    init(context: UserContext, admin: AdminRepository, departments: [Department]) {
        self.context = context
        self.departments = departments.filter { !$0.isArchived }
        _model = State(initialValue: NewEmployeeViewModel(admin: admin))
    }

    var body: some View {
        NavigationStack {
            if let result {
                TemporaryPasswordView(name: model.draft.displayName, email: model.draft.email, result: result) { dismiss() }
            } else {
                form
            }
        }
        .interactiveDismissDisabled(result != nil)   // the password screen closes only with «تم»
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            Section(String(localized: "الحساب")) {
                TextField(String(localized: "البريد الإلكتروني"), text: $model.draft.email)
                    .keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("employee.email")
                fieldError("email")
                TextField(String(localized: "الاسم"), text: $model.draft.displayName)
                    .accessibilityIdentifier("employee.name")
                fieldError("display_name")
                TextField(String(localized: "المسمى الوظيفي (اختياري)"), text: $model.draft.jobTitle)
            }
            Section(String(localized: "القسم")) {
                Picker(String(localized: "القسم"), selection: $model.draft.departmentID) {
                    Text(String(localized: "بدون قسم")).tag(UUID?.none)
                    ForEach(departments) { d in Text(d.nameAr).tag(UUID?.some(d.id)) }
                }
                .accessibilityIdentifier("employee.department")
                if model.draft.departmentID != nil {
                    Picker(String(localized: "الدور"), selection: $model.draft.departmentRole) {
                        Text(String(localized: "رئيس قسم")).tag(DepartmentRole.head)
                        Text(String(localized: "منسق")).tag(DepartmentRole.coordinator)
                    }
                    .pickerStyle(.segmented)
                    if model.draft.departmentRole == .head {
                        Toggle(String(localized: "الرئيس الأساسي للقسم"), isOn: $model.draft.isPrimaryHead)
                    }
                }
                fieldError("department_id"); fieldError("is_primary")
            }
            Section(String(localized: "صلاحية على مستوى المستشفى")) {
                Picker(String(localized: "الصلاحية"), selection: $model.draft.orgRole) {
                    ForEach(EmployeeOrgRole.allCases.filter { $0 != .systemAdmin || context.isDirector }) { r in
                        Text(r.title).tag(r)
                    }
                }
                Text(String(localized: "لا يُمنح دور مدير المستشفى من التطبيق."))
                    .font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
            }
            if let e = model.error, model.fieldErrors.isEmpty {
                Section { Label(e.userMessage, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) }
                    .accessibilityIdentifier("employee.error")
            }
        }
        .navigationTitle(String(localized: "موظف جديد"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(String(localized: "إلغاء")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "إنشاء الحساب")) { Task { result = await model.save() } }
                    .disabled(model.isSaving)
                    .accessibilityIdentifier("employee.save")
            }
        }
    }

    @ViewBuilder private func fieldError(_ key: String) -> some View {
        if let message = model.fieldErrors[key] {
            Text(message).font(.hcCaption).foregroundStyle(Color.hcCritical)
        }
    }
}

/// Shows the temporary password exactly once (D-25). It lives only in this
/// view's memory; closing the screen discards it.
struct TemporaryPasswordView: View {
    let name: String
    let email: String
    let result: EmployeeCreationResult
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        List {
            if let password = result.temporaryPassword {
                Section {
                    Label(String(localized: "أُنشئ الحساب"), systemImage: "checkmark.seal").foregroundStyle(Color.hcGood)
                    LabeledContent(String(localized: "الاسم"), value: name)
                    LabeledContent(String(localized: "البريد"), value: email).environment(\.layoutDirection, .leftToRight)
                }
                Section {
                    Text(password)
                        .font(.system(.title2, design: .monospaced)).textSelection(.enabled)
                        .environment(\.layoutDirection, .leftToRight)
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("employee.tempPassword")
                        .accessibilityLabel(String(localized: "كلمة المرور المؤقتة"))
                    Button {
                        // Local-only and expiring, so it does not linger or sync to other devices.
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: password]],
                                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                        copied = true
                    } label: { Label(copied ? String(localized: "نُسخت (تُمسح بعد دقيقتين)") : String(localized: "نسخ"), systemImage: "doc.on.doc") }
                } header: { Text(String(localized: "كلمة المرور المؤقتة")) } footer: {
                    Text(String(localized: "تظهر مرة واحدة فقط ولا تُحفظ. سلّمها للموظف بطريقة آمنة؛ سيُطلب منه تغييرها عند أول دخول."))
                }
            } else {
                Section {
                    Label(String(localized: "الحساب موجود مسبقًا وأُضيفت له الصلاحيات"), systemImage: "person.crop.circle.badge.checkmark")
                        .foregroundStyle(Color.hcGood)
                    Text(String(localized: "لم تُنشأ كلمة مرور جديدة. يدخل الموظف بكلمة مروره الحالية."))
                        .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                }
            }
        }
        .navigationTitle(String(localized: "الحساب الجديد"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "تم"), action: done).accessibilityIdentifier("employee.done")
            }
        }
    }
}

/// Required before anything else for accounts created with a temporary password.
struct ChangePasswordView: View {
    @Environment(SessionStore.self) private var session
    @State private var password = ""
    @State private var confirmation = ""
    @State private var working = false
    @State private var error: String?

    private var problems: [String] { PasswordRules.problems(password, confirmation: confirmation) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(String(localized: "أُنشئ حسابك بكلمة مرور مؤقتة. اختر كلمة مرور خاصة بك للمتابعة."))
                        .font(.hcCallout)
                }
                Section {
                    SecureField(String(localized: "كلمة المرور الجديدة"), text: $password)
                        .textContentType(.newPassword).accessibilityIdentifier("password.new")
                    SecureField(String(localized: "تأكيد كلمة المرور"), text: $confirmation)
                        .textContentType(.newPassword).accessibilityIdentifier("password.confirm")
                    ForEach(problems, id: \.self) { Text($0).font(.hcCaption).foregroundStyle(Color.hcWarning) }
                }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(Color.hcCritical) } }
                Section {
                    Button {
                        working = true; error = nil
                        Task {
                            do { try await session.changePassword(password) }
                            catch { self.error = (error as? AppError)?.userMessage ?? String(localized: "تعذر تغيير كلمة المرور.") }
                            working = false
                        }
                    } label: {
                        if working { ProgressView() } else { Text(String(localized: "حفظ كلمة المرور")).frame(maxWidth: .infinity) }
                    }
                    .disabled(working || !problems.isEmpty || confirmation.isEmpty)
                    .accessibilityIdentifier("password.save")
                    Button(String(localized: "تسجيل الخروج"), role: .destructive) { Task { await session.signOut() } }
                }
            }
            .navigationTitle(String(localized: "كلمة مرور جديدة"))
            .scrollContentBackground(.hidden)
            .background(Color.hcBackground)
        }
    }
}
