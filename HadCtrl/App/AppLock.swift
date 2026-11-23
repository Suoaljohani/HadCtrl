import SwiftUI
import LocalAuthentication
import Observation

/// Face ID / Touch ID lock over a signed-in session (D-35). The session itself
/// stays in the Keychain; the lock only hides the app until the device owner is
/// verified (biometrics, falling back to the device passcode). It is a privacy
/// screen, not an authorization mechanism: the server still checks every call.
@MainActor
@Observable
final class AppLock {
    enum Biometry: Sendable { case none, faceID, touchID, opticID }

    private(set) var isLocked = false
    private(set) var isAuthenticating = false
    private(set) var lastError: String?
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let enabled: Bool

    /// `enabled` is false in UI-testing builds so tests never meet the lock.
    init(preferences: AppPreferences, enabled: Bool) {
        self.preferences = preferences
        self.enabled = enabled
        isLocked = enabled && preferences.appLock
    }

    static var biometry: Biometry {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return .none }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    /// True when biometrics or at least a device passcode can verify the owner.
    static var canLock: Bool { LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) }

    static var biometryTitle: String {
        switch biometry {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        case .none: return String(localized: "رمز الجهاز")
        }
    }

    static var biometrySymbol: String {
        switch biometry {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        case .none: return "lock.fill"
        }
    }

    func didEnterBackground() {
        backgroundedAt = Date()
    }

    func willEnterForeground() {
        guard enabled, preferences.appLock, !isLocked else { return }
        let away = backgroundedAt.map { Date().timeIntervalSince($0) } ?? .infinity
        if away >= Double(preferences.lockGrace) { isLocked = true }
    }

    /// Verifies the owner; unlocks on success. Safe to call repeatedly.
    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        if await Self.verify(reason: String(localized: "افتح قيادة للمتابعة")) {
            lastError = nil
            withAnimation(.smooth(duration: 0.35)) { isLocked = false }
        } else {
            lastError = String(localized: "لم يتم التحقق. حاول مرة أخرى.")
        }
    }

    /// Turning the lock on requires a successful check first, so the user is never
    /// locked out by a setting they could not satisfy.
    func setEnabled(_ on: Bool) async -> Bool {
        guard on else { preferences.appLock = false; return true }
        guard Self.canLock else { return false }
        let ok = await Self.verify(reason: String(localized: "تأكيد تفعيل قفل التطبيق"))
        if ok { preferences.appLock = true }
        return ok
    }

    func lockOnSignOut() { isLocked = false; backgroundedAt = nil }

    private static func verify(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = String(localized: "إلغاء")
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Full-screen privacy cover shown while locked.
struct LockScreen: View {
    let lock: AppLock
    @Environment(\.hcMotionEnabled) private var motion
    @State private var pulse = false

    var body: some View {
        ZStack {
            BrandBackdrop(image: "HCWallChevron")
            VStack(spacing: Spacing.l) {
                Spacer()
                Image(systemName: AppLock.biometrySymbol)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Color.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: motion && lock.isAuthenticating)
                    .accessibilityHidden(true)
                Text(String(localized: "التطبيق مقفل")).font(.hcLargeTitle).foregroundStyle(.white)
                Text(String(localized: "تحقّق بـ \(AppLock.biometryTitle) للمتابعة"))
                    .font(.hcCallout).foregroundStyle(.white.opacity(0.85))
                if let error = lock.lastError {
                    Text(error).font(.hcFootnote).foregroundStyle(.white).padding(.horizontal, Spacing.m)
                        .padding(.vertical, Spacing.xs).background(.black.opacity(0.25), in: Capsule())
                }
                Spacer()
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label(String(localized: "فتح بـ \(AppLock.biometryTitle)"), systemImage: AppLock.biometrySymbol)
                        .font(.hcHeadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.s)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.hcPrimary)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xxl)
                .accessibilityIdentifier("lock.unlock")
            }
        }
        .task { await lock.unlock() }
    }
}

/// A brand photo darkened into a calm backdrop, with the chevron motif on top.
/// Plain brand colour under Reduce Transparency.
struct BrandBackdrop: View {
    let image: String
    var fullBleed = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color.hcInk
            if !reduceTransparency {
                Image(image).resizable().scaledToFill()
                    .accessibilityHidden(true)
                LinearGradient(colors: [Color.hcInk.opacity(0.55), Color.hcInk.opacity(0.92)],
                               startPoint: .top, endPoint: .bottom)
            }
            ChevronMotif().stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
        .clipped()
        .ignoresSafeArea(edges: fullBleed ? .all : [])
    }
}

/// The diagonal chevron rhythm of the hospital's green wall, as a vector pattern.
struct ChevronMotif: Shape {
    var spacing: CGFloat = 46

    func path(in rect: CGRect) -> Path {
        var p = Path()
        var x = -rect.height
        while x < rect.width + rect.height {
            p.move(to: CGPoint(x: x, y: rect.maxY))
            p.addLine(to: CGPoint(x: x + rect.height * 0.5, y: rect.midY))
            p.addLine(to: CGPoint(x: x + rect.height, y: rect.maxY))
            x += spacing
        }
        return p
    }
}
