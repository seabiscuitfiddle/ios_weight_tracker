import SwiftUI
import TallyCore
import WidgetKit

/// Lock-screen widget: net calories against the goal. Design screen 1a.
///
/// `accessoryRectangular` is the two-slot family that sits beside the circular Weather and Wind
/// complications in the design's four-slot row.
struct NetCaloriesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NetCalories", provider: TallyTimelineProvider()) { entry in
            NetCaloriesView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Net calories")
        .description("Today's net calories against your goal.")
        .supportedFamilies([.accessoryRectangular])
    }
}

struct NetCaloriesView: View {
    let entry: TallySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                // The lock screen renders widgets as a monochrome stencil, so the accent colour
                // can't carry meaning here — the mark reads by shape instead.
                Text("T")
                    .font(.system(size: 10, weight: .black))
                    .frame(width: 15, height: 15)
                    .background(.tertiary)
                Text("NET CALORIES")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(TallyFormat.calories(entry.totals.netCalories))
                    .font(.system(size: 24, weight: .heavy))
                if let goal = entry.goalCalories {
                    Text("/ \(TallyFormat.calories(goal))")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            if entry.goalCalories != nil {
                ProgressView(value: entry.progress)
                    .progressViewStyle(.linear)
                    .tint(.primary)
            }
        }
        .widgetURL(DeepLink.today.url)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Net calories")
        .accessibilityValue(
            entry.goalCalories.map {
                TallyFormat.progressPair(entry.totals.netCalories, of: $0)
            } ?? TallyFormat.calories(entry.totals.netCalories)
        )
    }
}

/// Home-screen widget: the ring, macro bars, and a quick-log strip. Design screen 1b.
struct TallySummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TallySummary", provider: TallyTimelineProvider()) { entry in
            TallySummaryView(entry: entry)
                .containerBackground(Color(token: Palette.background), for: .widget)
        }
        .configurationDisplayName("Tally")
        .description("Net calories, protein and fiber, with quick logging.")
        .supportedFamilies([.systemMedium])
    }
}

struct TallySummaryView: View {
    let entry: TallySnapshot

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ring
                bars
            }
            .padding(.horizontal, 4)

            Spacer(minLength: 10)

            quickLogStrip
        }
    }

    @ViewBuilder private var ring: some View {
        ZStack {
            Circle()
                .stroke(Color(token: Palette.text, opacity: Palette.dividerOpacity), lineWidth: 13)
            Circle()
                .trim(from: 0, to: entry.progress)
                .stroke(
                    Color(token: Palette.accent),
                    style: StrokeStyle(lineWidth: 13, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text(TallyFormat.calories(entry.remaining ?? entry.totals.netCalories))
                    .font(.system(size: 26, weight: .black))
                Text(entry.remaining == nil ? "NET" : "CAL LEFT")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color(token: Palette.text, opacity: Palette.secondaryTextOpacity))
            }
        }
        .frame(width: 104, height: 104)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var bars: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let goal = entry.goalCalories {
                bar("NET", value: Double(entry.totals.netCalories), target: Double(goal),
                    text: TallyFormat.progressPair(entry.totals.netCalories, of: goal),
                    fill: Color(token: Palette.accent))
            }
            bar("PROTEIN", value: entry.totals.proteinGrams, target: entry.proteinTarget,
                text: TallyFormat.macroPair(entry.totals.proteinGrams, of: entry.proteinTarget),
                fill: Color(token: Palette.text))
            bar("FIBER", value: entry.totals.fiberGrams, target: entry.fiberTarget,
                text: TallyFormat.macroPair(entry.totals.fiberGrams, of: entry.fiberTarget),
                fill: Color(token: Palette.text))
        }
    }

    @ViewBuilder
    private func bar(
        _ label: String, value: Double, target: Double, text: String, fill: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color(token: Palette.text, opacity: Palette.secondaryTextOpacity))
                Spacer()
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(token: Palette.text))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color(token: Palette.text, opacity: Palette.dividerOpacity))
                    Rectangle()
                        .fill(fill)
                        .frame(width: geometry.size.width * min(1, max(0, target > 0 ? value / target : 0)))
                }
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(text)
    }

    /// Text · Photo · Voice, each a deep link into the matching compose mode.
    ///
    /// `Link` rather than an interactive `Button`: all three need the app in the foreground —
    /// for a keyboard, a camera, or a microphone — so running an intent in the widget process
    /// would just have to launch the app anyway.
    @ViewBuilder private var quickLogStrip: some View {
        HStack(spacing: 0) {
            quickLogButton("Text", systemImage: "text.alignleft", mode: .text, accented: false)
            divider
            quickLogButton("Photo", systemImage: "camera", mode: .photo, accented: false)
            divider
            quickLogButton("Voice", systemImage: "mic", mode: .voice, accented: true)
        }
        .frame(height: 38)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color(token: Palette.text, opacity: Palette.dividerOpacity))
                .frame(height: 1.5)
        }
    }

    @ViewBuilder private var divider: some View {
        Rectangle()
            .fill(Color(token: Palette.text, opacity: Palette.dividerOpacity))
            .frame(width: 1.5)
    }

    @ViewBuilder
    private func quickLogButton(
        _ title: String, systemImage: String, mode: DeepLink.LogMode, accented: Bool
    ) -> some View {
        Link(destination: DeepLink.log(mode: mode).url) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
            }
            .foregroundStyle(accented ? Color(token: Palette.background) : Color(token: Palette.text))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(accented ? Color(token: Palette.accent) : Color.clear)
        }
        .accessibilityLabel("Log by \(title.lowercased())")
    }
}

/// Local copy of the token-to-Color bridge. Duplicated from the app target rather than shared,
/// because the app's version lives in a file the widget doesn't compile — and the alternative,
/// a third module for four lines, costs more than it saves.
extension Color {
    init(token: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((token >> 16) & 0xFF) / 255,
            green: Double((token >> 8) & 0xFF) / 255,
            blue: Double(token & 0xFF) / 255,
            opacity: opacity
        )
    }
}
