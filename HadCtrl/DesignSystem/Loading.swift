import SwiftUI

// Skeleton placeholders (spec §20: "skeleton loading instead of number
// flicker"). They show the shape of what is coming, never fake numbers, and are
// hidden from VoiceOver behind one "loading" label.

/// A soft highlight sweeping across placeholder shapes; static under Reduce Motion.
private struct Shimmer: ViewModifier {
    @Environment(\.hcMotionEnabled) private var motion
    @Environment(\.layoutDirection) private var direction
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if motion {
                    GeometryReader { geo in
                        LinearGradient(colors: [.clear, Color.hcSurface.opacity(0.55), .clear],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.6)
                            .offset(x: phase * geo.size.width * (direction == .rightToLeft ? -1 : 1))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                guard motion else { return }
                withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) { phase = 1.4 }
            }
    }
}

extension View {
    func hcShimmer() -> some View { modifier(Shimmer()) }
}

/// One placeholder bar.
struct SkeletonBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = 12
    var body: some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.hcSeparator.opacity(0.7))
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }
}

/// Placeholder rows for a list screen while its first load runs.
struct SkeletonList: View {
    var rows = 5
    var body: some View {
        VStack(spacing: Spacing.s) {
            ForEach(0..<rows, id: \.self) { i in
                HStack(alignment: .top, spacing: Spacing.s) {
                    Circle().fill(Color.hcSeparator.opacity(0.7)).frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        SkeletonBar(width: i.isMultiple(of: 2) ? 190 : 150, height: 14)
                        SkeletonBar(width: 110, height: 10)
                    }
                    Spacer(minLength: 0)
                    SkeletonBar(width: 54, height: 20)
                }
                .padding(Spacing.m)
                .background(Color.hcSurface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            }
        }
        .hcShimmer()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "جارٍ التحميل"))
        .accessibilityIdentifier("skeleton")
    }
}

/// List-row form for `List` screens: a few placeholder rows without cell chrome.
struct SkeletonRows: View {
    var rows = 4
    var body: some View {
        ForEach(0..<rows, id: \.self) { i in
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SkeletonBar(width: i.isMultiple(of: 2) ? 200 : 160, height: 14)
                SkeletonBar(width: 120, height: 10)
            }
            .padding(.vertical, Spacing.xxs)
            .hcShimmer()
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(i > 0)
            .accessibilityLabel(String(localized: "جارٍ التحميل"))
        }
    }
}

/// A detail screen's shape (title, status, sections) while its record loads.
struct DetailSkeleton: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    SkeletonBar(width: 230, height: 20)
                    SkeletonBar(width: 90, height: 22)
                    SkeletonBar(height: 10)
                    SkeletonBar(width: 200, height: 10)
                }
                .padding(Spacing.m)
                .background(Color.hcSurface, in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
                SkeletonList(rows: 3)
            }
            .padding(Spacing.m)
            .hcShimmer()
        }
        .scrollDisabled(true)
        .background(Color.hcBackground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "جارٍ التحميل"))
        .accessibilityIdentifier("skeleton")
    }
}
