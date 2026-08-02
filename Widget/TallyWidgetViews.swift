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

    /// Fixed, unlike the 2×2 widget's ring, because here the ring shares its row with the bars —
    /// a ring that sized itself to the row would have to be measured before the bars could be
    /// laid out beside it. 80pt is what the shortest medium widget can spare once the footer and
    /// the system's content margins have taken theirs, and it lands within a point or two of the
    /// bars' own height, which is what makes the two halves of the row read as one block.
    private let ringDiameter: Double = 80

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                ring
                bars
            }
            .padding(.horizontal, 4)

            Spacer(minLength: 6)

            quickLogStrip
        }
        // The default foreground, pinned. Every other colour here is already a palette token,
        // but the ring's number wasn't: it inherited SwiftUI's default, which follows the
        // system colour scheme and turns near-white in dark mode — on top of a container
        // background that is a fixed light surface, so the biggest number on the widget was
        // the one that disappeared. Setting the default at the root also means a `Text` added
        // later can't reintroduce the same bug by leaving its colour unstated.
        .foregroundStyle(Color(token: Palette.text))
    }

    @ViewBuilder private var ring: some View {
        let content = entry.ringContent

        NetCalorieRing(value: content.value, label: content.label, progress: entry.progress)
            .frame(width: ringDiameter, height: ringDiameter)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var bars: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        VStack(alignment: .leading, spacing: 3) {
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
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(text)
    }

    /// Text · Photo · Voice, each a deep link into the matching compose mode.
    @ViewBuilder private var quickLogStrip: some View {
        QuickLogStrip(height: 34) {
            QuickLogButton(title: "Text", systemImage: "text.alignleft", mode: .text)
            WidgetDivider()
            QuickLogButton(title: "Photo", systemImage: "camera", mode: .photo)
            WidgetDivider()
            QuickLogButton(title: "Voice", systemImage: "mic", mode: .voice, accented: true)
        }
    }
}

/// Home-screen widget: the ring alone, plus a two-target quick-log footer. Design screen 2a/2b.
///
/// The same data and the same provider as ``TallySummaryWidget`` — this is the compact slot, so
/// the macro bars drop away and only the net ring survives. Photo goes too: at 2×2 there is room
/// for two footer targets, and the design keeps the two that are fastest to start from cold.
struct NetRingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TallyNetRing", provider: TallyTimelineProvider()) { entry in
            NetRingView(entry: entry)
                .containerBackground(Color(token: Palette.background), for: .widget)
        }
        .configurationDisplayName("Net calories ring")
        .description("Today's net calories against your goal, with quick logging.")
        .supportedFamilies([.systemSmall])
    }
}

struct NetRingView: View {
    let entry: TallySnapshot

    var body: some View {
        VStack(spacing: 0) {
            // The ring takes whatever the footer leaves rather than a fixed size. A 2×2 tile is
            // the tightest slot in the system and its content area differs across devices and
            // Display Zoom, so a hardcoded diameter is the one thing here that can overflow.
            // ``NetCalorieRing`` inscribes itself in whatever it is given — and scales its type
            // to match — so this stays circular, and legible, at any size.
            ring
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 8)

            QuickLogStrip(height: 34) {
                QuickLogButton(title: "Text", systemImage: "text.alignleft", mode: .text)
                WidgetDivider()
                QuickLogButton(title: "Voice", systemImage: "mic", mode: .voice, accented: true)
            }
        }
        // Pinned for the same reason as the summary widget: the container background is a fixed
        // light surface, so an unstated foreground would invert to near-white in dark mode.
        .foregroundStyle(Color(token: Palette.text))
    }

    /// The same number, the same kicker and the same wording as the wide widget's ring — the
    /// point of ``NetRingContent``. The goal itself is no longer spelled out beneath the number:
    /// "OF 2,100" under a count of what's *left* read as a day already eaten, and the arc around
    /// it is what carries the goal here, exactly as it does on the wide tile.
    @ViewBuilder private var ring: some View {
        let content = entry.ringContent

        NetCalorieRing(value: content.value, label: content.label, progress: entry.progress)
            // Unlike the summary widget, the ring is not decorative here — there are no bars
            // behind it carrying the same numbers, so it has to be the accessible element.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.accessibilityLabel)
            .accessibilityValue(content.accessibilityValue)
    }
}

/// The ring both home-screen widgets lead with: a track, the progress arc, and the number that
/// sits inside them.
///
/// Nothing here is a point size. The view measures the box it was given, takes the largest circle
/// that fits, and asks ``RingMetrics`` what belongs at that diameter — so the same ring is correct
/// in the 2×2 tile, in the medium tile, and at whatever size Display Zoom leaves behind.
///
/// The type is confined to ``RingMetrics/contentWidth``, which is the reason the digits stay off
/// the stroke. Sizing it against the whole frame instead is what let them collide: the frame is
/// wider than the hole in the ring, and `minimumScaleFactor` shrinks text against the width it is
/// handed, so it saw no reason to shrink anything. `strokeBorder` rather than `stroke` for a
/// related reason: a plain stroke straddles the circle's edge and spills half its width outside
/// the frame, over whatever the layout put next to it.
struct NetCalorieRing: View {
    let value: String
    let label: String
    /// 0...1. `TallySnapshot.progress` is already clamped.
    let progress: Double

    var body: some View {
        GeometryReader { geometry in
            let metrics = RingMetrics(diameter: min(geometry.size.width, geometry.size.height))

            ZStack {
                Circle()
                    .strokeBorder(
                        Color(token: Palette.text, opacity: Palette.dividerOpacity),
                        lineWidth: metrics.lineWidth
                    )
                Circle()
                    .inset(by: metrics.lineWidth / 2)
                    .trim(from: 0, to: progress)
                    .stroke(
                        Color(token: Palette.accent),
                        style: StrokeStyle(lineWidth: metrics.lineWidth, lineCap: .butt)
                    )
                    // Trim starts at 3 o'clock; the design starts the arc at the top.
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 0) {
                    Text(value)
                        .font(.system(size: metrics.valueFontSize, weight: .black))
                        // The backstop for a number wider than its slot — a five-digit total, or
                        // a locale whose group separator is wider than a comma.
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(label)
                        .font(.system(size: metrics.labelFontSize, weight: .semibold))
                        .tracking(0.8)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(Color(token: Palette.text, opacity: Palette.secondaryTextOpacity))
                }
                .frame(width: metrics.contentWidth, height: metrics.contentHeight)
            }
            .frame(width: metrics.diameter, height: metrics.diameter)
            // A `GeometryReader` pins its content to the top leading corner; this centres the
            // circle in the — usually wider than tall — box the layout gave it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The quick-log footer: a flush row of targets under a hairline rule.
///
/// `Link` rather than an interactive `Button` throughout: every mode needs the app in the
/// foreground — for a keyboard, a camera, or a microphone — so running an intent in the widget
/// process would just have to launch the app anyway. The design calls these iOS 17 interactive
/// widget buttons; the interaction is the same, but the work cannot happen in-process.
struct QuickLogStrip<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .frame(height: height)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(token: Palette.text, opacity: Palette.dividerOpacity))
                    .frame(height: 1.5)
            }
    }
}

struct WidgetDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(token: Palette.text, opacity: Palette.dividerOpacity))
            .frame(width: 1.5)
    }
}

struct QuickLogButton: View {
    let title: String
    let systemImage: String
    let mode: DeepLink.LogMode
    var accented: Bool = false

    var body: some View {
        Link(destination: DeepLink.log(mode: mode).url) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
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
