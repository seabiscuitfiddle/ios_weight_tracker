import SwiftUI
import TallyCore

// The SwiftUI face of the design tokens. The values themselves live in TallyCore/Palette.swift
// so they can be unit-tested on any platform; this file only translates them into SwiftUI types.
// Nothing here should contain a literal colour or size — if a number appears in this file that
// isn't in Palette or Metrics, it is unreviewable and untestable.

extension Color {
    /// Builds a colour from a `0xRRGGBB` token.
    init(token: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((token >> 16) & 0xFF) / 255,
            green: Double((token >> 8) & 0xFF) / 255,
            blue: Double(token & 0xFF) / 255,
            opacity: opacity
        )
    }

    static let tallyBackground = Color(token: Palette.background)
    static let tallySurface = Color(token: Palette.surface)
    static let tallyText = Color(token: Palette.text)
    static let tallyAccent = Color(token: Palette.accent)

    /// Hairline rules. Expressed as the text colour at low opacity, exactly as the design does,
    /// so rules stay correct over both the page background and a surface panel.
    static let tallyDivider = Color(token: Palette.text, opacity: Palette.dividerOpacity)
    static let tallySecondaryText = Color(token: Palette.text, opacity: Palette.secondaryTextOpacity)
    static let tallyTertiaryText = Color(token: Palette.text, opacity: Palette.tertiaryTextOpacity)

    /// Text and icons drawn on an accent or inverted panel.
    static let tallyInverted = Color(token: Palette.background)
}

extension Font {
    /// Archivo at a fixed size.
    ///
    /// Used for the large numerals, where the design's tight tracking and optical alignment
    /// depend on the size being what it says. `Font.custom` silently falls back to the system
    /// font when Archivo isn't installed, which is why a missing font file makes Tally look
    /// wrong rather than crash.
    static func tallyFixed(_ size: Double, weight: Font.Weight) -> Font {
        .custom(Typography.family, fixedSize: size).weight(weight)
    }

    /// Archivo that scales with the user's chosen text size.
    ///
    /// The default for anything the user reads as prose. Ignoring Dynamic Type would make the
    /// app unusable for people who need larger text, which is a worse failure than a layout
    /// that grows.
    static func tallyScaled(
        _ size: Double,
        weight: Font.Weight,
        relativeTo style: Font.TextStyle = .body
    ) -> Font {
        .custom(Typography.family, size: size, relativeTo: style).weight(weight)
    }

    /// The all-caps micro-label: "NET", "CAL LEFT", "TODAY'S LOG".
    static var tallyKicker: Font {
        .tallyScaled(Typography.Kicker.size, weight: .semibold, relativeTo: .caption2)
    }

    /// Large numerals — the ring value, current weight, the computed goal.
    static func tallyDisplay(_ size: Double) -> Font {
        .tallyFixed(size, weight: .heavy)
    }

    static var tallyScreenTitle: Font {
        .tallyScaled(Typography.screenTitleSize, weight: .heavy, relativeTo: .largeTitle)
    }

    static var tallyEntryTitle: Font {
        .tallyScaled(Typography.entryTitleSize, weight: .semibold, relativeTo: .subheadline)
    }

    static var tallyEntryDetail: Font {
        .tallyScaled(Typography.entryDetailSize, weight: .regular, relativeTo: .caption)
    }

    static var tallyBody: Font {
        .tallyScaled(Typography.bodySize, weight: .regular, relativeTo: .body)
    }
}

extension View {
    /// Styles text as the design's kicker: caps, wide tracking, muted.
    ///
    /// The tracking is what makes it read as a label rather than as small text, so it is applied
    /// here rather than left to call sites to remember.
    func tallyKickerStyle(color: Color = .tallySecondaryText) -> some View {
        self
            .font(.tallyKicker)
            .tracking(Typography.Kicker.tracking * Typography.Kicker.size)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    /// A hairline rule, as the design draws them.
    func tallyHairlineBorder() -> some View {
        overlay(
            Rectangle()
                .strokeBorder(Color.tallyDivider, lineWidth: Metrics.hairline)
        )
    }
}

/// A horizontal rule. Rectangle rather than `Divider` because the design's rules have specific
/// weights and colours that `Divider` does not let you set reliably.
struct TallyRule: View {
    var weight: Double = Metrics.hairline

    var body: some View {
        Rectangle()
            .fill(Color.tallyDivider)
            .frame(height: weight)
            .accessibilityHidden(true)
    }
}
