import SwiftUI

// Motion system (spec §05/§20): calm, short, physically plausible motion that
// carries meaning (a number changed, a record opened). Every effect is gated by
// `hcMotionEnabled`, which is false under Reduce Motion and in UI-testing builds,
// so the static layout is always the source of truth.

enum HCMotion {
    /// Controls and small state changes.
    static let snappy = Animation.snappy(duration: 0.28)
    /// Content appearing or reflowing.
    static let smooth = Animation.smooth(duration: 0.45)
    /// Press feedback.
    static let press = Animation.spring(response: 0.25, dampingFraction: 0.7)
    /// Rings and bars filling to their value.
    static let fill = Animation.spring(response: 0.9, dampingFraction: 0.85)
    /// Delay between staggered siblings; capped so long lists never feel slow.
    static func stagger(_ index: Int) -> Double { min(Double(index), 8) * 0.045 }
}

private struct MotionEnabledKey: EnvironmentKey { static let defaultValue = true }
private struct ZoomNamespaceKey: EnvironmentKey { static let defaultValue: Namespace.ID? = nil }

extension EnvironmentValues {
    /// False under Reduce Motion and in UI-testing builds.
    var hcMotionEnabled: Bool {
        get { self[MotionEnabledKey.self] }
        set { self[MotionEnabledKey.self] = newValue }
    }

    /// Namespace shared by a tab's list rows and its pushed details (zoom transition).
    var hcZoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

/// Installed once at the root: derives `hcMotionEnabled` from the system setting.
struct MotionPolicy: ViewModifier {
    let allowMotion: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.environment(\.hcMotionEnabled, allowMotion && !reduceMotion)
    }
}

// MARK: - Entrance

/// Fades and lifts content in on first appearance, staggered by index.
/// Runs once per view identity; returning to a screen does not replay it.
private struct Entrance: ViewModifier {
    let index: Int
    @Environment(\.hcMotionEnabled) private var motion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(!motion || shown ? 1 : 0)
            .offset(y: !motion || shown ? 0 : 14)
            .onAppear {
                guard motion, !shown else { return }
                withAnimation(HCMotion.smooth.delay(HCMotion.stagger(index))) { shown = true }
            }
    }
}

extension View {
    func hcEntrance(_ index: Int = 0) -> some View { modifier(Entrance(index: index)) }

    /// Animates a number's glyphs when `value` changes (no flicker on reload).
    func hcNumeric<V: Equatable>(_ value: V) -> some View { modifier(NumericChange(value: value)) }
}

private struct NumericChange<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.hcMotionEnabled) private var motion

    func body(content: Content) -> some View {
        content
            .contentTransition(motion ? .numericText() : .identity)
            .animation(motion ? HCMotion.snappy : nil, value: value)
    }
}

// MARK: - Press feedback

/// Card buttons: a slight scale and dim while pressed, like system cells.
struct PressableCardStyle: ButtonStyle {
    @Environment(\.hcMotionEnabled) private var motion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(motion && configuration.isPressed ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(motion ? HCMotion.press : nil, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

extension ButtonStyle where Self == PressableCardStyle {
    static var hcCard: PressableCardStyle { PressableCardStyle() }
}

// MARK: - Navigation zoom (iOS 18+; standard push elsewhere)

extension View {
    /// Marks a row as the origin of the detail it opens.
    @ViewBuilder func hcZoomSource(_ id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let namespace {
            matchedTransitionSource(id: id, in: namespace) { $0.clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)) }
        } else {
            self
        }
    }

    /// Zooms the pushed detail out of its source row when that row is on screen.
    @ViewBuilder func hcZoomDestination(_ id: some Hashable, in namespace: Namespace.ID?, enabled: Bool) -> some View {
        if #available(iOS 18.0, *), let namespace, enabled {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

/// A list row that pushes `route` and is the zoom origin of the detail it opens.
struct HCLink<Label: View>: View {
    let route: AppRoute
    @ViewBuilder var label: Label
    @Environment(\.hcZoomNamespace) private var namespace

    init(_ route: AppRoute, @ViewBuilder label: () -> Label) {
        self.route = route
        self.label = label()
    }

    var body: some View {
        NavigationLink(value: route) { label }
            .hcZoomSource(route, in: namespace)
    }
}

// MARK: - Haptics (meaningful events only, §05)

extension View {
    /// Success when a decision or submission is confirmed by the server; error
    /// when it is refused. Nothing for ordinary taps or loads.
    func hcOutcomeFeedback(confirmation: String?, error: AppError?) -> some View {
        self
            .sensoryFeedback(.success, trigger: confirmation) { _, new in new != nil }
            .sensoryFeedback(.error, trigger: error) { _, new in new != nil }
    }
}
