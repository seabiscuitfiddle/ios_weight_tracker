import Foundation

/// The Modernist design system's raw token values.
///
/// These live in TallyCore rather than beside the SwiftUI code for one reason: they can be
/// asserted on a machine with no Xcode. A wrong hex value is invisible to every other kind of
/// test and produces a build that compiles perfectly and looks wrong, so the numbers
/// transcribed from the design system's stylesheet are pinned by tests here, and the app target
/// only wraps them in `Color`.
public enum Palette {
    /// Page background. The design's `--color-bg`.
    public static let background: UInt32 = 0xF3F2F2
    /// Raised panels and inset cells. `--color-surface`.
    public static let surface: UInt32 = 0xEAE9E9
    /// Near-black used for text and for inverted panels. `--color-text`.
    public static let text: UInt32 = 0x201E1D
    /// The single accent: exercise, negative values, the active tab, the send button.
    /// `--color-accent`.
    public static let accent: UInt32 = 0xEC3013
    public static let accentSecondary: UInt32 = 0xE15B47

    /// Hairline rules. The design expresses this as the text colour at 40% opacity rather than
    /// as its own colour, so it stays correct against any background.
    public static let dividerOpacity = 0.4
    /// Secondary label opacity, from the design's repeated `color-mix(... 55%)`.
    public static let secondaryTextOpacity = 0.55
    /// Tertiary/hint opacity, from the design's `... 42%` on inactive tabs.
    public static let tertiaryTextOpacity = 0.42

    public static let neutral100: UInt32 = 0xF8F4F4
    public static let neutral300: UInt32 = 0xD7D3D3
    public static let neutral500: UInt32 = 0x9B9797
    public static let neutral700: UInt32 = 0x605D5D
    public static let neutral900: UInt32 = 0x2D2B2B
}

/// Spacing, line weights, and type sizes.
public enum Metrics {
    /// **Zero, everywhere.** The flat, sharp-cornered geometry is the whole Modernist look —
    /// the design system sets every radius token to 0px. Rounding a corner anywhere breaks the
    /// visual language more than any colour mistake would.
    public static let cornerRadius: Double = 0

    /// Hairline rules between rows and around cards.
    public static let hairline: Double = 1.5
    /// Heavier rule under headers and above the tab bar.
    public static let rule: Double = 2

    public static let space1: Double = 4
    public static let space2: Double = 8
    public static let space3: Double = 12
    public static let space4: Double = 16
    public static let space6: Double = 24
    public static let space8: Double = 32

    /// Screen gutter, from the design's 22px screen padding.
    public static let gutter: Double = 22

    /// Ring stroke width on the Today hero.
    public static let ringStroke: Double = 15
    /// Macro and progress bar height.
    public static let barHeight: Double = 8

    /// Minimum edge of anything tappable — Apple's 44pt floor.
    ///
    /// The design's controls are small, flat glyphs, and a glyph is not a hit area. Sizing the
    /// *frame* to this while the artwork stays small is what keeps the look without making
    /// buttons that have to be aimed at.
    public static let tapTarget: Double = 44
}

/// The type scale. Archivo throughout — 800 for numerals and headings, 600 for labels.
public enum Typography {
    /// Family name as registered by the font files. See README for adding them.
    public static let family = "Archivo"

    /// The all-caps micro-label the design uses everywhere: "NET", "CAL LEFT", "PROTEIN".
    /// Its wide letter-spacing is what makes it read as a label rather than as small text.
    public enum Kicker {
        public static let size: Double = 10
        public static let tracking: Double = 0.16   // em
        public static let weight = 600
    }

    /// Large numerals: the ring value, the current weight, the computed goal.
    public enum Display {
        public static let weight = 800
        /// Tight tracking, from the design's `letter-spacing: -.02em` on large numbers.
        public static let tracking: Double = -0.02
    }

    public static let bodySize: Double = 15
    public static let entryTitleSize: Double = 14
    public static let entryDetailSize: Double = 11
    public static let screenTitleSize: Double = 28
}
