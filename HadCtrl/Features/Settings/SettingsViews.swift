import SwiftUI
import UIKit

extension AppTab {
    var title: String {
        switch self {
        case .home: return String(localized: "الرئيسية")
        case .departments: return String(localized: "الأقسام")
        case .performance: return String(localized: "الأداء")
        case .execution: return String(localized: "التنفيذ")
        case .reports: return String(localized: "التقارير")
        }
    }
    var symbol: String {
        switch self {
        case .home: return "house"
        case .departments: return "building.2"
        case .performance: return "chart.bar"
        case .execution: return "checklist"
        case .reports: return "doc.text"
        }
    }
}

/// Settings (D-35): personal presentation, security and notifications for
/// everyone, plus sections that depend on the server-provided role.
struct SettingsView: View {
    let context: UserContext
    let dependencies: DependencyContainer
    let lock: AppLock
    @Environment(SessionStore.self) private var session
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss
    @State private var lockError: String?
    @State private var confirmSignOut = false
    @State private var signaturesAvailable: Bool?
    private let push = PushCenter.shared

    var body: some View {
        @Bindable var prefs = preferences
        NavigationStack {
            List {
                Section {
                    ProfileHeader(context: context)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                appearanceSection($prefs)
                languageSection($prefs)
                securitySection($prefs)
                notificationsSection
                workspaceSection($prefs)

                if context.canManageOrganization {
                    Section {
                        NavigationLink {
                            AdminHubView(context: context, dependencies: dependencies)
                        } label: {
                            SettingsRow(symbol: "person.2.badge.gearshape.fill", tint: .indigo,
                                        title: String(localized: "الأقسام والموظفون"),
                                        subtitle: String(localized: "إنشاء الأقسام والحسابات والقوالب والمؤشرات"))
                        }
                        .accessibilityIdentifier("settings.admin")
                    } header: { Text(String(localized: "الإدارة")) }
                }

                Section {
                    LabeledContent(String(localized: "الإصدار"), value: Self.versionText)
                        .environment(\.layoutDirection, .leftToRight)
                    LabeledContent(String(localized: "بيئة التشغيل"), value: dependencies.environment.rawValue)
                        .environment(\.layoutDirection, .leftToRight)
                } header: { Text(String(localized: "حول التطبيق")) }

                Section {
                    Button(role: .destructive) { confirmSignOut = true } label: {
                        Label(String(localized: "تسجيل الخروج"), systemImage: "rectangle.portrait.and.arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("settings.signOut")
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.hcBackground)
            .navigationTitle(String(localized: "الإعدادات"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(String(localized: "تم")) { dismiss() } } }
            .confirmationDialog(String(localized: "تسجيل الخروج من هذا الجهاز؟"), isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button(String(localized: "تسجيل الخروج"), role: .destructive) {
                    dismiss()
                    Task { await session.signOut() }
                }
            }
            .task { await push.refreshStatus() }
        }
    }

    private static var versionText: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(v) (\(b))"
    }

    // MARK: Appearance

    @ViewBuilder private func appearanceSection(_ prefs: Bindable<AppPreferences>) -> some View {
        Section {
            AppearancePicker(selection: prefs.appearance)
                .listRowInsets(EdgeInsets(top: Spacing.s, leading: Spacing.m, bottom: Spacing.s, trailing: Spacing.m))
            Toggle(isOn: prefs.latinDigits) {
                SettingsRow(symbol: "textformat.123", tint: .teal, title: String(localized: "أرقام لاتينية"),
                            subtitle: String(localized: "عرض الأرقام بصيغة 123 بدل ١٢٣"))
            }
            .accessibilityIdentifier("settings.latinDigits")
            Toggle(isOn: prefs.reduceMotion) {
                SettingsRow(symbol: "figure.walk.motion", tint: .orange, title: String(localized: "تقليل الحركة"),
                            subtitle: String(localized: "إيقاف الحركات الزخرفية داخل التطبيق"))
            }
            .accessibilityIdentifier("settings.reduceMotion")
            Toggle(isOn: prefs.haptics) {
                SettingsRow(symbol: "hand.tap.fill", tint: .pink, title: String(localized: "الاهتزاز اللمسي"),
                            subtitle: String(localized: "عند الاعتماد والإرجاع وتبديل التبويب"))
            }
            .accessibilityIdentifier("settings.haptics")
        } header: { Text(String(localized: "المظهر")) }
    }

    // MARK: Language

    @ViewBuilder private func languageSection(_ prefs: Bindable<AppPreferences>) -> some View {
        Section {
            Picker(selection: prefs.language) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
            } label: {
                SettingsRow(symbol: "globe", tint: .blue, title: String(localized: "لغة التطبيق"))
            }
            .pickerStyle(.navigationLink)
            .accessibilityIdentifier("settings.language")
        } header: {
            Text(String(localized: "اللغة"))
        } footer: {
            if preferences.languageNeedsRestart {
                Label(String(localized: "أغلق التطبيق من مبدّل التطبيقات ثم افتحه لتطبيق اللغة واتجاه الواجهة."),
                      systemImage: "arrow.clockwise")
                    .foregroundStyle(Color.hcWarning)
            }
        }
    }

    // MARK: Security

    @ViewBuilder private func securitySection(_ prefs: Bindable<AppPreferences>) -> some View {
        Section {
            Toggle(isOn: Binding(get: { preferences.appLock }, set: { on in
                Task {
                    let ok = await lock.setEnabled(on)
                    lockError = ok ? nil : String(localized: "تعذر التحقق؛ لم يتغير القفل.")
                }
            })) {
                SettingsRow(symbol: AppLock.biometrySymbol, tint: .green,
                            title: String(localized: "قفل التطبيق بـ \(AppLock.biometryTitle)"),
                            subtitle: String(localized: "يطلب التحقق عند فتح التطبيق"))
            }
            .disabled(!AppLock.canLock)
            .accessibilityIdentifier("settings.appLock")
            HStack {
                SettingsRow(symbol: "signature", tint: .indigo, title: String(localized: "التوقيع اليدوي على الاعتمادات"),
                            subtitle: signaturesAvailable == false
                                ? String(localized: "بانتظار تحديث الخادم (ترحيل التوقيعات)؛ تُعتمد القرارات حاليًا دون توقيع")
                                : String(localized: "يُطلب توقيعك بإصبعك قبل كل اعتماد ويُحفظ مع القرار"))
                Spacer(minLength: 0)
                if signaturesAvailable == true {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.hcGood).accessibilityHidden(true)
                }
            }
            .accessibilityElement(children: .combine)
            .task { signaturesAvailable = await dependencies.signatures.isAvailable() }
            if preferences.appLock {
                Picker(selection: prefs.lockGrace) {
                    Text(String(localized: "فورًا")).tag(0)
                    Text(String(localized: "بعد دقيقة")).tag(60)
                    Text(String(localized: "بعد ٥ دقائق")).tag(300)
                    Text(String(localized: "بعد ١٥ دقيقة")).tag(900)
                } label: {
                    SettingsRow(symbol: "timer", tint: .gray, title: String(localized: "طلب التحقق"))
                }
            }
        } header: {
            Text(String(localized: "الأمان"))
        } footer: {
            if let lockError {
                Text(lockError).foregroundStyle(Color.hcCritical)
            } else if !AppLock.canLock {
                Text(String(localized: "فعّل رمز الجهاز أو Face ID من إعدادات iPhone لاستخدام القفل."))
            }
        }
    }

    // MARK: Notifications

    @ViewBuilder private var notificationsSection: some View {
        Section {
            HStack {
                SettingsRow(symbol: "bell.badge.fill", tint: .red, title: String(localized: "الإشعارات الفورية"),
                            subtitle: pushSubtitle)
                Spacer(minLength: 0)
                switch push.status {
                case .notDetermined, .unknown:
                    Button(String(localized: "تفعيل")) { Task { await push.enable() } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .accessibilityIdentifier("settings.enablePush")
                case .denied:
                    Button(String(localized: "الإعدادات")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                case .enabled:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.hcGood)
                        .accessibilityLabel(String(localized: "مفعّلة"))
                case .unavailable:
                    EmptyView()
                }
            }
        } header: {
            Text(String(localized: "الإشعارات"))
        } footer: {
            Text(String(localized: "يبقى صندوق الإشعارات داخل التطبيق هو المرجع؛ تظهر على شاشة القفل عبارة عامة دون أسماء أو تفاصيل."))
        }
    }

    private var pushSubtitle: String {
        switch push.status {
        case .enabled: return push.isRegisteredOnServer ? String(localized: "مفعّلة ومسجّلة لهذا الجهاز") : String(localized: "مفعّلة")
        case .denied: return String(localized: "مرفوضة من إعدادات النظام")
        case .unavailable: return String(localized: "غير متاحة في هذا البناء؛ تتطلب توقيعًا بحساب مطوّر يدعم الإشعارات")
        case .notDetermined, .unknown: return String(localized: "تنبيه فوري عند إسناد أو اعتماد أو إرجاع")
        }
    }

    // MARK: Workspace (role-aware)

    @ViewBuilder private func workspaceSection(_ prefs: Bindable<AppPreferences>) -> some View {
        Section {
            if context.isDirector {
                NavigationLink {
                    DashboardCustomizeView()
                } label: {
                    SettingsRow(symbol: "rectangle.3.group.fill", tint: Color.hcPrimary,
                                title: String(localized: "تخصيص لوحة القيادة"),
                                subtitle: String(localized: "ترتيب الأقسام وإظهارها وكثافة القراءات"))
                }
                .accessibilityIdentifier("settings.customizeDashboard")
            }
            Picker(selection: prefs.startTab) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            } label: {
                SettingsRow(symbol: "square.stack.3d.up.fill", tint: .purple, title: String(localized: "شاشة البداية"))
            }
            if context.headedDepartments.count > 1 {
                Picker(selection: prefs.defaultDepartmentID) {
                    Text(String(localized: "اسألني كل مرة")).tag(UUID?.none)
                    ForEach(context.headedDepartments) { d in Text(d.nameAr).tag(UUID?.some(d.id)) }
                } label: {
                    SettingsRow(symbol: "building.2.fill", tint: .brown, title: String(localized: "القسم الافتراضي للتكليف"))
                }
            }
        } header: {
            Text(context.isDirector ? String(localized: "مساحة عمل المدير")
                 : context.headedDepartments.isEmpty ? String(localized: "مساحة العمل") : String(localized: "مساحة عمل رئيس القسم"))
        }
    }
}

/// A settings row: tinted rounded-square icon, title and optional explanation.
struct SettingsRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String?
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 30

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: iconSize * 0.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: iconSize, height: iconSize)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: iconSize * 0.27, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.hcBody).foregroundStyle(Color.hcInk)
                if let subtitle {
                    Text(subtitle).font(.hcCaption).foregroundStyle(Color.hcSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Identity card at the top of Settings: who you are, as the server says.
private struct ProfileHeader: View {
    let context: UserContext

    private var roles: [String] {
        var out: [String] = []
        if context.isDirector { out.append(String(localized: "مدير المستشفى")) }
        if context.orgRoles.contains(.systemAdmin) { out.append(String(localized: "مدير النظام")) }
        for d in context.departments {
            let role = d.roles.contains(.head) ? String(localized: "رئيس") : String(localized: "منسق")
            out.append("\(role) · \(d.nameAr)")
        }
        return out
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BrandBackdrop(image: "HCWallCorridor", fullBleed: false)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: Radius.largeCard, style: .continuous))
            HStack(alignment: .center, spacing: Spacing.m) {
                InitialsAvatar(name: context.displayName, size: 64)
                    .background(Circle().fill(Color.hcSurface))
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(context.displayName).font(.hcTitle).foregroundStyle(.white)
                    Text(context.organizationName).font(.hcFootnote).foregroundStyle(.white.opacity(0.85))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.xxs) {
                            ForEach(roles, id: \.self) { r in
                                Text(verbatim: r).font(.hcCaption.weight(.semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, Spacing.xs).padding(.vertical, 3)
                                    .background(.white.opacity(0.18), in: Capsule())
                            }
                        }
                    }
                }
            }
            .padding(Spacing.m)
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.profile")
    }
}

/// Three live previews of the light, dark and automatic appearance.
private struct AppearancePicker: View {
    @Binding var selection: AppearanceMode
    @Environment(\.hcHapticsEnabled) private var haptics

    var body: some View {
        HStack(spacing: Spacing.s) {
            ForEach(AppearanceMode.allCases) { mode in
                Button { withAnimation(HCMotion.snappy) { selection = mode } } label: {
                    VStack(spacing: Spacing.xs) {
                        preview(mode)
                            .frame(height: 74)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(selection == mode ? Color.hcPrimary : Color.hcSeparator,
                                              lineWidth: selection == mode ? 2.5 : 1))
                        HStack(spacing: 4) {
                            Image(systemName: mode.symbol).accessibilityHidden(true)
                            Text(mode.title).lineLimit(1).minimumScaleFactor(0.75)
                        }
                        .font(.hcCaption.weight(selection == mode ? .bold : .regular))
                        .foregroundStyle(selection == mode ? Color.hcPrimary : Color.hcSecondaryText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
                .accessibilityIdentifier("appearance.\(mode.rawValue)")
            }
        }
        .sensoryFeedback(.selection, trigger: selection) { _, _ in haptics }
    }

    @ViewBuilder private func preview(_ mode: AppearanceMode) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        switch mode {
        case .light: miniScreen(dark: false).clipShape(shape)
        case .dark: miniScreen(dark: true).clipShape(shape)
        case .system:
            HStack(spacing: 0) { miniScreen(dark: false); miniScreen(dark: true) }.clipShape(shape)
        }
    }

    private func miniScreen(dark: Bool) -> some View {
        let bg = dark ? Color(white: 0.09) : Color(white: 0.96)
        let card = dark ? Color(white: 0.17) : .white
        return ZStack(alignment: .topLeading) {
            bg
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(Color.hcPrimary).frame(width: 26, height: 5)
                RoundedRectangle(cornerRadius: 5).fill(card).frame(height: 18)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 4).fill(card)
                    RoundedRectangle(cornerRadius: 4).fill(card)
                }
                .frame(height: 16)
            }
            .padding(8)
        }
        .environment(\.colorScheme, dark ? .dark : .light)
    }
}

/// Director's dashboard arrangement (D-35): order, visibility and density.
struct DashboardCustomizeView: View {
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        @Bindable var prefs = preferences
        List {
            Section {
                ForEach(preferences.dashboard.order) { module in
                    HStack(spacing: Spacing.s) {
                        SettingsRow(symbol: module.symbol, tint: Color.hcPrimary, title: module.title,
                                    subtitle: module.canHide ? nil : String(localized: "يبقى ظاهرًا دائمًا"))
                        Spacer(minLength: 0)
                        if module.canHide {
                            Toggle("", isOn: Binding(
                                get: { !preferences.dashboard.hidden.contains(module) },
                                set: { on in
                                    withAnimation(HCMotion.snappy) {
                                        if on { preferences.dashboard.hidden.remove(module) }
                                        else { preferences.dashboard.hidden.insert(module) }
                                    }
                                }))
                            .labelsHidden()
                            .accessibilityLabel(String(localized: "إظهار \(module.title)"))
                            .accessibilityIdentifier("customize.toggle.\(module.rawValue)")
                        } else {
                            Image(systemName: "lock.fill").foregroundStyle(Color.hcSecondaryText).accessibilityHidden(true)
                        }
                    }
                }
                .onMove { from, to in
                    withAnimation(HCMotion.snappy) { preferences.dashboard.order.move(fromOffsets: from, toOffset: to) }
                }
            } header: {
                Text(String(localized: "اسحب لإعادة الترتيب"))
            }
            Section {
                Toggle(isOn: $prefs.dashboard.compactReadings) {
                    SettingsRow(symbol: "rectangle.compress.vertical", tint: .teal, title: String(localized: "قراءات مضغوطة"),
                                subtitle: String(localized: "بطاقات أصغر دون أشرطة التقدم"))
                }
                Button(String(localized: "استعادة الترتيب الافتراضي")) {
                    withAnimation(HCMotion.snappy) { preferences.resetDashboard() }
                }
            }
        }
        .environment(\.editMode, .constant(.active))
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.hcBackground)
        .navigationTitle(String(localized: "تخصيص لوحة القيادة"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
