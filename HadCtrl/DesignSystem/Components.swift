import SwiftUI

/// Content card: opaque surface for legibility; glass is reserved for controls (§05).
/// Depth comes from a hairline and a soft low shadow, never a heavy drop shadow.
struct HCCard<Content: View>: View {
    var padding: CGFloat = Spacing.m
    var radius: CGFloat = Radius.card
    @ViewBuilder var content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hcSurface(radius: radius, scheme: scheme)
    }
}

extension View {
    /// The shared card surface: fill, hairline and elevation.
    func hcSurface(radius: CGFloat = Radius.card, scheme: ColorScheme) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(Color.hcSurface, in: shape)
            .overlay(shape.strokeBorder(Color.hcSeparator.opacity(scheme == .dark ? 1 : 0.8), lineWidth: 0.5))
            .shadow(color: Elevation.shadow(scheme), radius: Elevation.radius, x: 0, y: Elevation.y)
    }
}

/// A tinted circle holding an SF Symbol; the tone also appears as text nearby.
struct IconBadge: View {
    let symbol: String
    var tone: StatusTone = .info
    var size: CGFloat = 34
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45 * scale, weight: .semibold))
            .foregroundStyle(tone.color)
            .frame(width: size * scale, height: size * scale)
            .background(tone.color.opacity(0.13), in: Circle())
            .accessibilityHidden(true)
    }
}

/// The user's initials in a tinted circle (dashboard header).
struct InitialsAvatar: View {
    let name: String
    private let baseSize: CGFloat
    @ScaledMetric(relativeTo: .headline) private var scale: CGFloat = 1

    init(name: String, size: CGFloat = 40) {
        self.name = name
        self.baseSize = size
    }

    private var size: CGFloat { baseSize * min(scale, 1.6) }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map { String($0) } }.joined(separator: " ")
    }

    var body: some View {
        Text(initials.isEmpty ? "؟" : initials)
            .font(.system(size: size * 0.36, weight: .bold))
            .foregroundStyle(Color.hcPrimary)
            .frame(width: size, height: size)
            .background(Color.hcHighlight.opacity(0.55), in: Circle())
            .overlay(Circle().strokeBorder(Color.hcPrimary.opacity(0.25), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

/// A ring that fills to `fraction` (0…1); nil draws an empty dashed ring
/// ("no score"), never a zero (spec: missing data is not zero).
struct ScoreRing<Center: View>: View {
    let fraction: Double?
    var tone: StatusTone = .info
    var lineWidth: CGFloat = 12
    @ViewBuilder var center: Center
    @Environment(\.hcMotionEnabled) private var motion
    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Color.hcSeparator.opacity(0.8),
                            style: StrokeStyle(lineWidth: lineWidth, dash: fraction == nil ? [4, 6] : []))
            if fraction != nil {
                Circle()
                    .trim(from: 0, to: shown)
                    .stroke(AngularGradient(colors: [tone.color.opacity(0.65), tone.color], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360 * max(shown, 0.01))),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            center
        }
        .onAppear { update(animated: motion) }
        .onChange(of: fraction) { _, _ in update(animated: motion) }
        .accessibilityElement(children: .combine)
    }

    private func update(animated: Bool) {
        let target = min(max(fraction ?? 0, 0), 1)
        if animated { withAnimation(HCMotion.fill) { shown = target } } else { shown = target }
    }
}

/// A thin horizontal bar for a share (coverage, progress). Paired with text.
struct ProgressTrack: View {
    let fraction: Double?
    var tone: StatusTone = .info
    var height: CGFloat = 6
    @Environment(\.hcMotionEnabled) private var motion
    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.hcSeparator.opacity(0.8))
                if fraction != nil {
                    Capsule().fill(tone.color).frame(width: max(height, geo.size.width * shown))
                }
            }
        }
        .frame(height: height)
        .onAppear { update() }
        .onChange(of: fraction) { _, _ in update() }
        .accessibilityHidden(true)
    }

    private func update() {
        let target = min(max(fraction ?? 0, 0), 1)
        if motion { withAnimation(HCMotion.fill) { shown = target } } else { shown = target }
    }
}

struct StatusBadge: View {
    let text: String
    let tone: StatusTone
    var symbol: String?
    @Environment(\.hcMotionEnabled) private var motion

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.hcCaption.weight(.semibold))
        .padding(.horizontal, Spacing.xs + 2)
        .padding(.vertical, Spacing.xxs)
        .foregroundStyle(tone.color)
        .background(tone.color.opacity(0.13), in: Capsule())
        .overlay(Capsule().strokeBorder(tone.color.opacity(0.18), lineWidth: 0.5))
        .animation(motion ? HCMotion.snappy : nil, value: text)
        .accessibilityElement(children: .combine)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            if let symbol {
                Image(systemName: symbol).font(.hcFootnote.weight(.semibold)).foregroundStyle(Color.hcPrimary)
                    .accessibilityHidden(true)
            }
            Text(title).font(.hcHeadline).foregroundStyle(Color.hcInk)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing { Text(trailing).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText) }
        }
        .padding(.top, Spacing.xs)
    }
}

/// Banner shown whenever synthetic data is on screen (HC-004).
struct DemoDataBanner: View {
    var body: some View {
        Label(String(localized: "بيانات تجريبية — ليست نتائج تشغيلية"), systemImage: "testtube.2")
            .font(.hcFootnote)
            .foregroundStyle(Color.hcWarning)
            .padding(.horizontal, Spacing.s)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity)
            .background(Color.hcWarning.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.chip, style: .continuous))
            .accessibilityIdentifier("demoBanner")
    }
}

/// Uniform empty / error / offline / permission states (spec §20).
struct StateView: View {
    enum Kind { case empty, error, offline, permissionDenied, notFound }
    let kind: Kind
    let title: String
    var message: String?
    var retry: (() -> Void)?

    private var symbol: String {
        switch kind {
        case .empty: return "tray"
        case .error: return "exclamationmark.triangle"
        case .offline: return "wifi.slash"
        case .permissionDenied: return "lock"
        case .notFound: return "questionmark.folder"
        }
    }

    var body: some View {
        VStack(spacing: Spacing.s) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(kind == .error || kind == .offline ? Color.hcWarning : Color.hcPrimary)
                .frame(width: 64, height: 64)
                .background((kind == .error || kind == .offline ? Color.hcWarning : Color.hcPrimary).opacity(0.1), in: Circle())
                .accessibilityHidden(true)
            Text(title).font(.hcHeadline).foregroundStyle(Color.hcInk).multilineTextAlignment(.center)
            if let message {
                Text(message).font(.hcCallout).foregroundStyle(Color.hcSecondaryText).multilineTextAlignment(.center)
            }
            if let retry {
                Button(String(localized: "إعادة المحاولة"), action: retry).buttonStyle(.borderedProminent)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

/// Loading/loaded/failed for a scoped request.
enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading(previous: Value?)
    case loaded(Value)
    case failed(AppError, previous: Value?)

    var value: Value? {
        switch self {
        case .idle: return nil
        case .loading(let p): return p
        case .loaded(let v): return v
        case .failed(_, let p): return p
        }
    }

    var error: AppError? {
        if case .failed(let e, _) = self { return e }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

/// A metric shown with its numerator and denominator, never a bare ratio (§06, §20).
struct MetricTile: View {
    let title: String
    let numerator: Int
    let denominator: Int?
    var tone: StatusTone = .info
    var symbol: String?
    var style = NumberStyle()
    @Environment(\.colorScheme) private var scheme

    private var fraction: Double? {
        guard let denominator, denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .top, spacing: Spacing.xs) {
                if let symbol { IconBadge(symbol: symbol, tone: tone, size: 28) }
                Spacer(minLength: 0)
                Image(systemName: "chevron.forward").font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.hcSecondaryText.opacity(0.7)).accessibilityHidden(true)
            }
            Text(title).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
                Text(style.format(Decimal(numerator), fractionDigits: 0))
                    .font(.hcTitleNumber).monospacedDigit().foregroundStyle(Color.hcInk)
                    .hcNumeric(numerator)
                if let denominator {
                    Text(String(localized: "من \(style.format(Decimal(denominator), fractionDigits: 0))"))
                        .font(.hcFootnote).monospacedDigit().foregroundStyle(Color.hcSecondaryText)
                }
            }
            if denominator != nil { ProgressTrack(fraction: fraction, tone: tone, height: 4) }
        }
        .padding(Spacing.s + 2)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .hcSurface(radius: Radius.row, scheme: scheme)
    }

    /// Spoken form with numerator and denominator; applied by the containing control.
    var accessibilityText: String {
        if let denominator { return String(localized: "\(title)، \(numerator) من \(denominator)") }
        return String(localized: "\(title)، \(numerator)")
    }
}
