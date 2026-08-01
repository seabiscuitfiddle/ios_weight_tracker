import Foundation

/// The net-calorie ring's geometry, derived from the diameter it is actually drawn at.
///
/// Here rather than beside the SwiftUI for the same reason as ``Palette``: it can be asserted on
/// a machine with no Xcode. The failure this exists to prevent is a visual one — the number in
/// the middle drawn wider than the hole it sits in, so the digits cross the stroke — but the
/// part of it that decides the outcome is arithmetic, and arithmetic is testable. So the
/// arithmetic all lives here and the widget only turns the results into fonts and frames.
///
/// Every dimension is a fraction of the diameter rather than a point size, because the two
/// home-screen widgets draw this ring at different sizes and the 2×2 one's size changes with the
/// device and with Display Zoom. A number that fits one of them overlaps the stroke in another.
public struct RingMetrics: Equatable, Sendable {
    /// Stroke width as a fraction of the diameter. The design draws a 104pt ring with an 11.2pt
    /// stroke; holding the ratio is what makes it read as the same ring at every size.
    public static let strokeRatio = 0.108

    /// The centred number's point size, as a fraction of the diameter.
    public static let valueRatio = 0.20

    /// The caption's, floored at ``minimumLabelSize``: an all-caps tracked kicker stops being
    /// readable well before it stops being drawable.
    public static let labelRatio = 0.09
    public static let minimumLabelSize = 8.0

    /// Line height as a multiple of point size. Deliberately a little above SF Pro's ~1.2, so
    /// that the box this yields is roomier than the type that goes in it and never tighter.
    static let lineHeightRatio = 1.25

    /// The share of the ring's inner diameter the type may span. The remainder is the air
    /// between the digits and the stroke — without it the two merely fail to overlap, which
    /// still looks like a mistake.
    static let clearance = 0.9

    /// Outer diameter of the ring, in points: the ring is drawn *inside* this, not centred on
    /// it, so nothing bleeds past the frame the layout gave it.
    public let diameter: Double
    /// Stroke width of the track and of the progress arc alike.
    public let lineWidth: Double
    /// Point size for the number.
    public let valueFontSize: Double
    /// Point size for the caption under it.
    public let labelFontSize: Double
    /// Width the centred text may occupy. Anything wider crosses the stroke.
    public let contentWidth: Double
    /// Height it may occupy, for the same reason.
    public let contentHeight: Double

    /// The diameter of the hole: what is left after the stroke takes its bite from both sides.
    public var innerDiameter: Double { max(0, diameter - 2 * lineWidth) }

    public init(diameter: Double) {
        let diameter = max(0, diameter)
        self.diameter = diameter
        lineWidth = diameter * Self.strokeRatio
        valueFontSize = diameter * Self.valueRatio
        labelFontSize = max(Self.minimumLabelSize, diameter * Self.labelRatio)
        contentHeight = (valueFontSize + labelFontSize) * Self.lineHeightRatio

        // The type sits in the widest rectangle of that height that fits inside the hole, so the
        // corners land on the circle rather than through it: (w/2)² + (h/2)² = r². Solved for
        // the width, since the height is whatever two lines of type need. The `max` matters at
        // diameters too small to hold the floored caption at all — there the honest answer is
        // "no room", and a square root of a negative number would be a NaN passed to a frame.
        let usableRadius = Self.clearance * (diameter - 2 * lineWidth) / 2
        let halfHeight = contentHeight / 2
        let halfWidthSquared = usableRadius * usableRadius - halfHeight * halfHeight
        contentWidth = 2 * max(0, halfWidthSquared).squareRoot()
    }
}
