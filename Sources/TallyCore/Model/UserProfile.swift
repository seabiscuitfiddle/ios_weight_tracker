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
        public var detail: String {
            switch self {
            case .sedentary: "Desk job, little deliberate exercise"
            case .light: "Light exercise 1–3 days a week"
            case .moderate: "Moderate exercise 3–5 days a week"
            case .veryActive: "Hard exercise 6–7 days a week"
            case .extraActive: "Physical job or twice-daily training"
            }
        }
    }

    public var birthDate: Date?
    public var heightCentimeters: Double?
    public var biologicalSex: BiologicalSex
    public var activityLevel: ActivityLevel
    public var massUnit: MassUnit
    /// When true, exercise logged by hand is assumed to already be reflected in
    /// ``activityLevel`` and is not subtracted again. Off by default, because the design's
    /// whole premise is that logged exercise moves the net number.
    public var activityLevelIncludesLoggedExercise: Bool

    public init(
        birthDate: Date? = nil,
        heightCentimeters: Double? = nil,
        biologicalSex: BiologicalSex = .unspecified,
        activityLevel: ActivityLevel = .light,
        massUnit: MassUnit = .pounds,
        activityLevelIncludesLoggedExercise: Bool = false
    ) {
        self.birthDate = birthDate
        self.heightCentimeters = heightCentimeters
        self.biologicalSex = biologicalSex
        self.activityLevel = activityLevel
        self.massUnit = massUnit
        self.activityLevelIncludesLoggedExercise = activityLevelIncludesLoggedExercise
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
