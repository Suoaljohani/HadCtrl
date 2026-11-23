import SwiftUI

/// Invitation-based sign in (spec §22). No public sign-up, no role picker.
struct SignInView: View {
    let message: String?
    @Environment(SessionStore.self) private var session
    @State private var email = ""
    @State private var password = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text(String(localized: "قيادة")).font(.hcLargeTitle).foregroundStyle(Color.hcInk)
                        Text(String(localized: "الدخول متاح للحسابات المدعوة فقط."))
                            .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                    }
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField(String(localized: "البريد الإلكتروني"), text: $email)
                        .textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .environment(\.layoutDirection, .leftToRight)
                    SecureField(String(localized: "كلمة المرور"), text: $password)
                        .textContentType(.password)
                }
                if let message {
                    Section { Label(message, systemImage: "exclamationmark.circle").foregroundStyle(Color.hcCritical) }
                }
                Section {
                    Button {
                        working = true
                        Task { await session.signIn(email: email, password: password); working = false }
                    } label: {
                        if working { ProgressView() } else { Text(String(localized: "تسجيل الدخول")).frame(maxWidth: .infinity) }
                    }
                    .disabled(working || email.isEmpty || password.isEmpty)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.hcBackground)
        }
    }
}

struct AccessDeniedView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        VStack(spacing: Spacing.m) {
            StateView(kind: .permissionDenied, title: String(localized: "لا توجد عضوية نشطة"),
                      message: String(localized: "حسابك غير مرتبط بمستشفى أو قسم حاليًا. تواصل مع مدير النظام لتفعيل عضويتك."))
            Button(String(localized: "تسجيل الخروج")) { Task { await session.signOut() } }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.hcBackground)
        .accessibilityIdentifier("accessDenied")
    }
}

struct SettingsView: View {
    let context: UserContext
    let environment: AppEnvironment
    @Environment(SessionStore.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "الحساب")) {
                    LabeledContent(String(localized: "الاسم"), value: context.displayName)
                    LabeledContent(String(localized: "المستشفى"), value: context.organizationName)
                    if context.isDirector { Text(String(localized: "مدير المستشفى")) }
                    ForEach(context.departments) { d in
                        Text(String(localized: "\(d.roles.contains(.head) ? String(localized: "رئيس قسم") : String(localized: "منسق")) — \(d.nameAr)"))
                    }
                }
                Section(String(localized: "البيئة")) {
                    LabeledContent(String(localized: "بيئة التشغيل"), value: environment.rawValue)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Section {
                    Button(String(localized: "تسجيل الخروج"), role: .destructive) {
                        dismiss()
                        Task { await session.signOut() }
                    }
                }
            }
            .navigationTitle(String(localized: "الإعدادات"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "تم")) { dismiss() } } }
        }
    }
}
