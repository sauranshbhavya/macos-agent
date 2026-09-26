import SwiftUI

/// Insights' "Tasks completed this week": one bar a day, Monday first, the busiest day in the
/// accent. Hovering a day shows its count in a pill above the bars.
struct WeeklyCompletionChart: View {
    let counts: [Int]
    @State private var hoveredDayIndex: Int?

    private let days = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    private var maxCount: Int { counts.max() ?? 0 }
    private var peakIndex: Int? {
        guard maxCount > 0 else {
            return nil
        }
        return counts.firstIndex(of: maxCount)
    }

    /// The pill is centred on its column, except at the two ends of the week, where a centred pill
    /// on a narrow column would spill past the card's edge; those lean inward instead.
    private func pillAlignment(for index: Int) -> Alignment {
        if index == 0 { return .topLeading }
        if index == days.count - 1 { return .topTrailing }
        return .top
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SonnySpacing.lg) {
            Text("Tasks completed this week")
                .font(SonnyType.bodyEmphasis)
                .foregroundStyle(SonnyTheme.text)

            HStack(alignment: .bottom, spacing: SonnySpacing.md) {
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: SonnySpacing.sm) {
                        GeometryReader { proxy in
                            VStack {
                                Spacer(minLength: 0)
                                UnevenRoundedRectangle(
                                    topLeadingRadius: SonnyRadius.control,
                                    bottomLeadingRadius: 0,
                                    bottomTrailingRadius: 0,
                                    topTrailingRadius: SonnyRadius.control
                                )
                                .fill(index == peakIndex ? SonnyTheme.accent : SonnyTheme.accentSubtle)
                                .frame(
                                    width: 24,
                                    height: barHeight(for: count(at: index), availableHeight: proxy.size.height)
                                )
                                .opacity(count(at: index) == 0 ? 0 : 1)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .frame(height: 120)
                        .help(dayTaskCountDescription(day: day, index: index))
                        // The day label never changes; the count floats in its own pill above the
                        // whole column, sized to its text so it can't wrap or cover a bar.
                        .overlay(alignment: pillAlignment(for: index)) {
                            if hoveredDayIndex == index {
                                Text(WeeklyCompletionChartPresentation.countLabel(for: count(at: index)))
                                    .font(SonnyType.caption)
                                    .foregroundStyle(SonnyTheme.text)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .padding(.horizontal, SonnySpacing.sm)
                                    .padding(.vertical, SonnySpacing.xs)
                                    .background(SonnyTheme.surfaceRaised2, in: RoundedRectangle(cornerRadius: SonnyRadius.control))
                                    // The pill's bottom edge, plus a gap, is its top guide, so it
                                    // sits wholly above the column whatever its own size.
                                    .alignmentGuide(.top) { dimensions in dimensions[.bottom] + SonnySpacing.xs }
                            }
                        }
                        .sonnyAnimation(SonnyMotion.quick, value: hoveredDayIndex)

                        Text(day)
                            .font(SonnyType.micro)
                            .foregroundStyle(hoveredDayIndex == index ? SonnyTheme.text : SonnyTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { isHovering in
                        hoveredDayIndex = isHovering ? index : (hoveredDayIndex == index ? nil : hoveredDayIndex)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(dayTaskCountDescription(day: day, index: index))
                    .accessibilityValue(WeeklyCompletionChartPresentation.countLabel(for: count(at: index)))
                }
            }
            .frame(maxWidth: .infinity)
            // Headroom for the hover pill, so it never lands on the title.
            .padding(.top, SonnyMetrics.controlRegular)
        }
        .padding(SonnySpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sonnyCard()
    }

    private func count(at index: Int) -> Int {
        counts.indices.contains(index) ? counts[index] : 0
    }

    private func barHeight(for count: Int, availableHeight: CGFloat) -> CGFloat {
        guard maxCount > 0, count > 0 else {
            return 0
        }
        return max(12, CGFloat(count) / CGFloat(maxCount) * availableHeight)
    }

    private func dayTaskCountDescription(day: String, index: Int) -> String {
        let count = count(at: index)
        return "\(day): \(count) completed task\(count == 1 ? "" : "s")"
    }
}

/// The hover pill's wording, kept out of the view so it can be tested.
enum WeeklyCompletionChartPresentation {
    /// "1 task", "0 tasks", "30 tasks".
    static func countLabel(for count: Int) -> String {
        "\(count) task\(count == 1 ? "" : "s")"
    }
}
