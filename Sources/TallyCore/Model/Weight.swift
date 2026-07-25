import Foundation

/// A body-weight reading.
///
/// Canonically stored in **pounds**. That is a deliberate choice rather than a US bias: the
/// energy arithmetic Tally runs on is the ~3500 kcal-per-pound rule, and the design's rate
/// control is in lb/week, so keeping pounds canonical means the goal engine never converts.
/// Kilogram display and entry convert at the edges via ``kilograms``.
///
/// At most one sample per day. Weight is noisy enough that a single daily reading is all the
/// signal there is; several readings would invite users to chase intraday fluctuation, and the
/// trend that actually drives the goal is smoothed across days regardless.
public struct WeightSample: Identifiable, Hashable, Sendable, Codable {
    public var id: UUID
    public var day: Day
    public var pounds: Double
    public var measuredAt: Date
    public var source: RecordSource
    /// Identifier of the originating HealthKit sample, when imported.
    public var externalIdentifier: String?

    public init(
        id: UUID = UUID(),
        day: Day? = nil,
        pounds: Double,
        measuredAt: Date = Date(),
        source: RecordSource = .manual,
        externalIdentifier: String? = nil,
        calendar: Calendar = .current
    ) {
        self.id = id
        self.day = day ?? Day(date: measuredAt, calendar: calendar)
        self.pounds = pounds
        self.measuredAt = measuredAt
        self.source = source
        self.externalIdentifier = externalIdentifier
    }

    public var kilograms: Double { pounds * WeightSample.kilogramsPerPound }

    public static let kilogramsPerPound = 0.45359237
    public static let poundsPerKilogram = 1 / kilogramsPerPound

    public static func pounds(fromKilograms kg: Double) -> Double { kg * poundsPerKilogram }
}

public enum MassUnit: String, Hashable, Sendable, Codable, CaseIterable {
    case pounds, kilograms

    public var shortName: String {
        switch self {
        case .pounds: "lb"
        case .kilograms: "kg"
        }
    }

    /// Converts a canonical pound value into this unit, for display.
    public func value(fromPounds pounds: Double) -> Double {
        switch self {
        case .pounds: pounds
        case .kilograms: pounds * WeightSample.kilogramsPerPound
        }
    }

    /// Converts a value expressed in this unit back to canonical pounds.
    public func pounds(from value: Double) -> Double {
        switch self {
        case .pounds: value
        case .kilograms: WeightSample.pounds(fromKilograms: value)
        }
    }
}
