import SwiftUI
import UIKit

// Semantic tokens backed by the asset catalog (light + dark variants). Screens
// never hard-code hex values (spec §05).
extension Color {
    static let hcInk = Color("HCInk")
    static let hcPrimary = Color("HCPrimary")
    static let hcBackground = Color("HCBackground")
    static let hcSurface = Color("HCSurface")
    static let hcHighlight = Color("HCHighlight")
    static let hcSecondaryText = Color("HCSecondaryText")
    static let hcSeparator = Color("HCSeparator")
    static let hcGood = Color("HCStatusGood")
    static let hcWarning = Color("HCStatusWarning")
    static let hcCritical = Color("HCStatusCritical")
    static let hcNeutral = Color("HCStatusNeutral")
}

/// 4-pt spacing scale.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 20
    static let xl: CGFloat = 28
    static let xxl: CGFloat = 40
}

enum Radius {
    static let card: CGFloat = 24
    static let largeCard: CGFloat = 28
    static let row: CGFloat = 20
    static let field: CGFloat = 12
    static let chip: CGFloat = 10
}

/// Depth without heavy shadows (§05): a hairline plus a soft, low shadow in
/// light mode; dark mode relies on surface contrast only.
enum Elevation {
    static func shadow(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .clear : Color.hcInk.opacity(0.06)
    }
    static let radius: CGFloat = 14
    static let y: CGFloat = 6
}

/// Licensed Janna LT (see Brand/README.md) scaled with Dynamic Type via
/// `relativeTo:`. Falls back to the system font if the face failed to load.
enum HCTypography {
    static func font(_ style: Font.TextStyle, bold: Bool = false, scale: CGFloat = 1) -> Font {
        let name = bold ? "JannaLT-Bold" : "JannaLT-Regular"
        guard UIFont(name: name, size: 12) != nil else {
            return .system(style, weight: bold ? .semibold : .regular)
        }
        return .custom(name, size: baseSize(style) * scale, relativeTo: style)
    }

    private static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 32
        case .title: return 26
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .subheadline: return 15
        case .callout: return 16
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        default: return 17
        }
    }
}

extension Font {
    /// Hero numbers (dashboard score); always used with `.monospacedDigit()`.
    static let hcDisplay = HCTypography.font(.largeTitle, bold: true, scale: 1.45)
    static let hcLargeTitle = HCTypography.font(.largeTitle, bold: true)
    static let hcTitleNumber = HCTypography.font(.title, bold: true)
    static let hcSubheadline = HCTypography.font(.subheadline)
    static let hcSubheadlineBold = HCTypography.font(.subheadline, bold: true)
    static let hcTitle = HCTypography.font(.title2, bold: true)
    static let hcHeadline = HCTypography.font(.headline, bold: true)
    static let hcBody = HCTypography.font(.body)
    static let hcCallout = HCTypography.font(.callout)
    static let hcFootnote = HCTypography.font(.footnote)
    static let hcCaption = HCTypography.font(.caption)
}

/// Status tone: every colour is paired with explicit text (spec §05).
enum StatusTone: Sendable {
    case good, warning, critical, neutral, info

    var color: Color {
        switch self {
        case .good: return .hcGood
        case .warning: return .hcWarning
        case .critical: return .hcCritical
        case .neutral: return .hcNeutral
        case .info: return .hcPrimary
        }
    }
}
