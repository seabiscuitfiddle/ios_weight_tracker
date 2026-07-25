import SwiftUI
import TallyCore

/// The all-caps micro-label used throughout the design.
struct Kicker: View {
    let text: String
    var color: Color = .tallySecondaryText

    init(_ text: String, color: Color = .tallySecondaryText) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text).tallyKickerStyle(color: color)
    }
}

/// The net-calorie ring on the Today screen and the home widget.
///
/// Square-capped strokes, matching the design's flat geometry — a rounded cap would read as a
/// different design language even at this size.
struct NetRing: View {
    /// 0...1. Callers pass `DayTotals.progress(against:)`, which is already clamped.
    let progress: Double
    var lineWidth: Double = Metrics.ringStroke

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.tallyDivider, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(0, min(1, progress)))
                .stroke(Color.tallyAccent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                // Trim starts at 3 o'clock; the design starts the arc at the top.
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

/// A labelled progress bar, used for protein and fiber.
struct MacroBar: View {
    let label: String
    let value: Double
    let target: Double
    /// Macros use the text colour; only net calories and exercise get the accent, which is what
    /// keeps the accent meaningful.
    var fill: Color = .tallyText

    private var progress: Double {
        guard target > 0 else { return 0 }
        return min(1, max(0, value / target))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1 + 2) {
            HStack(alignment: .firstTextBaseline) {
                Kicker(label)
                Spacer(minLength: Metrics.space2)
                Text(TallyFormat.macroPair(value, of: target))
                    .font(.tallyScaled(12, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(Color.tallyText)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.tallyDivider)
                    Rectangle().fill(fill).frame(width: geometry.size.width * progress)
                }
            }
            .frame(height: Metrics.barHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(TallyFormat.macroPair(value, of: target))
    }
}

/// One row in the Today or History log.
struct EntryRow: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: Metrics.space3) {
            // Exercise gets a filled accent tile, food a neutral surface one — the design's way
            // of making the direction of an entry readable before you read the number.
            ZStack {
                Rectangle()
                    .fill(entry.kind == .exercise ? Color.tallyAccent : Color.tallySurface)
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(entry.kind == .exercise ? Color.tallyInverted : Color.tallyText)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.label)
                    .font(.tallyEntryTitle)
                    .foregroundStyle(Color.tallyText)
                    .lineLimit(2)
                Text(TallyFormat.entryDetail(entry))
                    .font(.tallyEntryDetail)
                    .foregroundStyle(Color.tallySecondaryText)
            }

            Spacer(minLength: Metrics.space2)

            Text(TallyFormat.signedCalories(entry.calories, kind: entry.kind))
                .font(.tallyFixed(16, weight: .heavy))
                .foregroundStyle(entry.kind == .exercise ? Color.tallyAccent : Color.tallyText)
        }
        .padding(.vertical, Metrics.space2 + 1)
        .accessibilityElement(children: .combine)
    }

    private var iconName: String {
        switch entry.kind {
        case .exercise: "bolt.fill"
        case .food:
            switch entry.source {
            case .llmPhoto: "camera"
            case .llmVoice: "mic"
            default: "fork.knife"
            }
        }
    }
}

/// A screen header: accent kicker over a heavy title, with a heavy rule beneath.
struct ScreenHeader<Trailing: View>: View {
    let kicker: String
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Kicker(kicker, color: .tallyAccent)
                    Text(title)
                        .font(.tallyScreenTitle)
                        .foregroundStyle(Color.tallyText)
                }
                Spacer(minLength: Metrics.space2)
                trailing
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.bottom, Metrics.space3)

            TallyRule(weight: Metrics.rule)
        }
    }
}

extension ScreenHeader where Trailing == EmptyView {
    init(kicker: String, title: String) {
        self.init(kicker: kicker, title: title, trailing: { EmptyView() })
    }
}

/// A square-cornered button in the accent colour — the design's primary action.
struct TallyPrimaryButton: View {
    let title: String
    let action: () -> Void
    var isEnabled = true

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.tallyFixed(13, weight: .heavy))
                .tracking(0.04 * 13)
                .textCase(.uppercase)
                .foregroundStyle(Color.tallyInverted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Metrics.space3)
                .background(isEnabled ? Color.tallyAccent : Color.tallyDivider)
        }
        .disabled(!isEnabled)
        .buttonStyle(.plain)
    }
}

/// Shown wherever a list has nothing in it yet.
///
/// Empty states get a component of their own because they are the first thing a new user sees,
/// and "no data" rendered as a blank rectangle reads as a broken screen.
struct EmptyStateView: View {
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Metrics.space3) {
            Text(message)
                .font(.tallyBody)
                .foregroundStyle(Color.tallySecondaryText)
                .multilineTextAlignment(.center)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.tallyScaled(13, weight: .semibold))
                    .foregroundStyle(Color.tallyAccent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metrics.space8)
        .padding(.horizontal, Metrics.gutter)
    }
}
