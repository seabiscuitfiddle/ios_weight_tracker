import Foundation

/// How a height is shown and entered.
///
/// Height is stored canonically in centimetres — Mifflin-St Jeor takes centimetres, so keeping
/// them canonical means the goal engine never converts. This is purely a display and entry
/// preference, and it is deliberately separate from ``MassUnit``: plenty of people weigh
/// themselves in kilograms and still think of themselves as five foot ten.
public enum HeightUnit: String, Hashable, Sendable, Codable, CaseIterable {
    case feetInches, centimeters

    public var displayName: String {
        switch self {
        case .feetInches: "ft / in"
        case .centimeters: "cm"
        }
    }
}

/// Conversions between canonical centimetres and the foot/inch pair the picker works in.
public enum Height {
    public static let centimetersPerInch = 2.54
    public static let inchesPerFoot = 12

    /// The feet a person could plausibly be. Wide enough to be nobody's edge case, narrow
    /// enough that the menu stays a menu rather than a scroll.
    public static let feetRange = 2...8

    /// Splits centimetres into whole feet and inches, rounded to the nearest inch.
    ///
    /// Rounding is done on the total inches rather than per component so that 182.9 cm comes
    /// back as 6′0″ and not 5′12″.
    public static func feetAndInches(fromCentimeters centimeters: Double) -> (feet: Int, inches: Int) {
        let totalInches = max(0, Int((centimeters / centimetersPerInch).rounded()))
        return (totalInches / inchesPerFoot, totalInches % inchesPerFoot)
    }

    public static func centimeters(feet: Int, inches: Int) -> Double {
        Double(feet * inchesPerFoot + inches) * centimetersPerInch
    }
}
