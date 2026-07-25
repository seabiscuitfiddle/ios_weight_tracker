import Foundation

/// The body facts the Mifflin-St Jeor estimate needs, plus display preferences.
///
/// Every physical field is optional. A user who declines to enter their height and age still
/// gets a working app — the goal engine falls back to an observed estimate or to whatever the
/// user sets by hand, rather than refusing to compute. Onboarding asks, it does not insist.
public struct UserProfile: Hashable, Sendable, Codable {
    public enum BiologicalSex: String, Hashable, Sendable, Codable, CaseIterable {
        case male, female, unspecified

        public var displayName: String {
            switch self {
            case .male: "Male"
            case .female: "Female"
            case .unspecified: "Prefer not to say"
            }
        }
    }

    /// Multipliers applied to BMR to reach total daily expenditure. These are the standard
    /// Harris-Benedict/Mifflin activity factors.
    public enum ActivityLevel: String, Hashable, Sendable, Codable, CaseIterable {
        case sedentary, light, moderate, veryActive, extraActive

        public var multiplier: Double {
            switch self {
            case .sedentary: 1.2
            case .light: 1.375
            case .moderate: 1.55
            case .veryActive: 1.725
            case .extraActive: 1.9
            }
        }

        public var displayName: String {
            switch self {
            case .sedentary: "Sedentary"
            case .light: "Lightly active"
            case .moderate: "Moderately active"
            case .veryActive: "Very active"
            case .extraActive: "Extremely active"
            }
        }

        /// Shown under the picker so the choice is judgeable rather than guessed at.
        ///
        /// Deliberately phrased around everyday movement, not workouts. Tally subtracts logged
        /// exercise from the day's net, so a workout counted here as well would be counted
        /// twice — see ``UserProfile/activityLevel``.
        public var detail: String {
            switch self {
            case .sedentary: "Desk job, mostly sitting"
            case .light: "On your feet some of the day"
            case .moderate: "On your feet most of the day"
            case .veryActive: "Physically demanding job"
            case .extraActive: "Heavy labour, or training as a job"
            }
        }
    }

    public var birthDate: Date?
    public var heightCentimeters: Double?
    public var biologicalSex: BiologicalSex

    /// Everyday movement **excluding** any exercise that gets logged.
    ///
    /// This has to exclude logged workouts, and it isn't a preference. Tally compares the daily
    /// goal against *net* calories (food − exercise), so the expenditure the goal is built from
    /// must be expenditure-before-exercise. Folding workouts into this multiplier as well would
    /// credit them twice: once by raising the goal, once by lowering the net.
    ///
    /// The same reasoning makes the observed estimate consistent — deriving expenditure from
    /// net intake yields a before-exercise number too, so the formula estimate and the observed
    /// one measure the same quantity and can legitimately be blended.
    public var activityLevel: ActivityLevel

    public var massUnit: MassUnit

    /// Display and entry only — ``heightCentimeters`` stays canonical either way.
    public var heightUnit: HeightUnit

    public init(
        birthDate: Date? = nil,
        heightCentimeters: Double? = nil,
        biologicalSex: BiologicalSex = .unspecified,
        activityLevel: ActivityLevel = .light,
        massUnit: MassUnit = .pounds,
        heightUnit: HeightUnit = .feetInches
    ) {
        self.birthDate = birthDate
        self.heightCentimeters = heightCentimeters
        self.biologicalSex = biologicalSex
        self.activityLevel = activityLevel
        self.massUnit = massUnit
        self.heightUnit = heightUnit
    }

    /// Hand-written so that a profile saved before height units were selectable still decodes.
    /// A missing key there isn't corruption, and failing the whole settings load over it would
    /// take the goal engine's height and age down with it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        birthDate = try container.decodeIfPresent(Date.self, forKey: .birthDate)
        heightCentimeters = try container.decodeIfPresent(Double.self, forKey: .heightCentimeters)
        biologicalSex = try container.decode(BiologicalSex.self, forKey: .biologicalSex)
        activityLevel = try container.decode(ActivityLevel.self, forKey: .activityLevel)
        massUnit = try container.decode(MassUnit.self, forKey: .massUnit)
        // Those profiles were entered in centimetres, which is what the field meant at the time.
        heightUnit = try container.decodeIfPresent(HeightUnit.self, forKey: .heightUnit) ?? .centimeters
    }

    public static let `default` = UserProfile()

    /// Age in whole years as of `now`, or nil when no birth date is known.
    public func age(asOf now: Date = Date(), calendar: Calendar = .current) -> Int? {
        guard let birthDate else { return nil }
        return calendar.dateComponents([.year], from: birthDate, to: now).year
    }

    /// True when there is enough to run the Mifflin-St Jeor estimate.
    public func supportsFormulaEstimate(asOf now: Date = Date(), calendar: Calendar = .current) -> Bool {
        heightCentimeters != nil && age(asOf: now, calendar: calendar) != nil
    }
}

/// Target weight, how fast to get there, and the macro targets shown beside the net number.
public struct GoalSettings: Hashable, Sendable, Codable {
    /// The three rates the design's segmented control offers, in pounds per week.
    public enum WeeklyRate: String, Hashable, Sendable, Codable, CaseIterable {
        case gentle, standard, aggressive

        /// Magnitude in pounds per week. Direction comes from target versus current weight.
        public var poundsPerWeek: Double {
            switch self {
            case .gentle: 0.5
            case .standard: 1.0
            case .aggressive: 1.5
            }
        }

        public var displayName: String {
            switch self {
            case .gentle: "0.5"
            case .standard: "1.0"
            case .aggressive: "1.5"
            }
        }
    }

    /// Goal weight in canonical pounds. Nil means "no target yet" — the app then shows
    /// maintenance calories instead of a deficit.
    public var targetPounds: Double?
    public var rate: WeeklyRate
    public var proteinTargetGrams: Double
    public var fiberTargetGrams: Double
    /// When set, this replaces the computed goal entirely. The escape hatch for users who
    /// already know their numbers and don't want them derived.
    public var manualCalorieGoal: Int?

    public init(
        targetPounds: Double? = nil,
        rate: WeeklyRate = .standard,
        proteinTargetGrams: Double = 150,
        fiberTargetGrams: Double = 38,
        manualCalorieGoal: Int? = nil
    ) {
        self.targetPounds = targetPounds
        self.rate = rate
        self.proteinTargetGrams = proteinTargetGrams
        self.fiberTargetGrams = fiberTargetGrams
        self.manualCalorieGoal = manualCalorieGoal
    }

    public static let `default` = GoalSettings()
}
