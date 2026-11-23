import SwiftUI

/// Content card: opaque surface for legibility; glass is reserved for controls (§05).
struct HCCard<Content: View>: View {
    var padding: CGFloat = Spacing.m
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.hcSurface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Color.hcSeparator, lineWidth: 0.5))
    }
}

struct StatusBadge: View {
    let text: String
    let tone: StatusTone
    var symbol: String?

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.hcCaption)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xxs)
        .foregroundStyle(tone.color)
        .background(tone.color.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.hcHeadline).foregroundStyle(Color.hcInk)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing { Text(trailing).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText) }
        }
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
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(Color.hcSecondaryText)
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
    var style = NumberStyle()

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(title).font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
                Text(style.format(Decimal(numerator), fractionDigits: 0))
                    .font(.hcTitle).monospacedDigit().foregroundStyle(Color.hcInk)
                if let denominator {
                    Text(String(localized: "من \(style.format(Decimal(denominator), fractionDigits: 0))"))
                        .font(.hcFootnote).foregroundStyle(Color.hcSecondaryText)
                }
            }
        }
        .padding(Spacing.s)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(Color.hcSurface, in: RoundedRectangle(cornerRadius: Radius.card - 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card - 4, style: .continuous).stroke(Color.hcSeparator, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        if let denominator { return String(localized: "\(title)، \(numerator) من \(denominator)") }
        return String(localized: "\(title)، \(numerator)")
    }
}
