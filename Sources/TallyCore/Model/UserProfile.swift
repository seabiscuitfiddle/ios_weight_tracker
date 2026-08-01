import Foundation

/// How much of Tally's Apple Health integration the user has switched on.
///
/// Two switches rather than one, because they answer different questions. ``isEnabled`` is
/// consent: with it off, Tally never calls into HealthKit at all — no authorization request, no
/// queries, no background delivery. ``usesActivityForExpenditure`` is a modelling choice made
/// *within* that consent, and changes where the day's movement comes from.
public struct HealthPreferences: Hashable, Sendable, Codable {
    /// The master switch. Nothing in the app may touch HealthKit while this is false.
    public var isEnabled: Bool

    /// Take expenditure from measured activity instead of the activity-level multiplier.
    ///
    /// Meaningless on its own — a user who turns Health off entirely leaves this set, and the
    /// modelled multiplier has to come back. Read ``UserProfile/usesMeasuredActivity`` rather
    /// than this, so no call site can act on it while Health is off.
    public var usesActivityForExpenditure: Bool

    /// The day measured activity was switched on.
    ///
    /// Days before it were logged without any activity credit, so their net calories measure a
    /// different quantity. The goal engine excludes them from the observed window rather than
    /// averaging across the boundary — see ``GoalCalculator/Inputs/netCaloriesValidFrom``.
    public var activityTrackingStartDay: Day?

    public init(
        isEnabled: Bool = false,
        usesActivityForExpenditure: Bool = false,
        activityTrackingStartDay: Day? = nil
    ) {
        self.isEnabled = isEnabled
        self.usesActivityForExpenditure = usesActivityForExpenditure
        self.activityTrackingStartDay = activityTrackingStartDay
    }

    /// What a profile saved before these switches existed means.
    ///
    /// Health was always reachable then — the Settings section was shown whenever the device
    /// had HealthKit — so `isEnabled: true` is what that user already had. Defaulting them to
    /// off instead would silently remove a feature they were using.
    public static let legacyDefault = HealthPreferences(isEnabled: true)
}

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
    ///
    /// Ignored entirely while ``usesMeasuredActivity`` is true: Apple Health then reports the
    /// movement instead of this standing in for it. The value is kept rather than cleared, so
    /// switching measured activity back off restores the level the user chose.
    public var activityLevel: ActivityLevel

    public var massUnit: MassUnit

    /// Display and entry only — ``heightCentimeters`` stays canonical either way.
    public var heightUnit: HeightUnit

    public var health: HealthPreferences

    public init(
        birthDate: Date? = nil,
        heightCentimeters: Double? = nil,
        biologicalSex: BiologicalSex = .unspecified,
        activityLevel: ActivityLevel = .light,
        massUnit: MassUnit = .pounds,
        heightUnit: HeightUnit = .feetInches,
        health: HealthPreferences = HealthPreferences()
    ) {
        self.birthDate = birthDate
        self.heightCentimeters = heightCentimeters
        self.biologicalSex = biologicalSex
        self.activityLevel = activityLevel
        self.massUnit = massUnit
        self.heightUnit = heightUnit
        self.health = health
    }

    /// True when the day's movement is measured by Apple Health rather than modelled.
    ///
    /// The only form of the question the rest of the app should ask. Collapsing both switches
    /// into one property is what stops a call site acting on
    /// ``HealthPreferences/usesActivityForExpenditure`` while Health itself is off.
    public var usesMeasuredActivity: Bool {
        health.isEnabled && health.usesActivityForExpenditure
    }

    /// What to multiply BMR by to reach expenditure before logged exercise.
    ///
    /// 1.0 under measured activity, and that is the whole point: Mifflin-St Jeor BMR is the
    /// same quantity as Apple's Resting Energy, so everything above it — workouts and everyday
    /// movement alike — arrives as entries on the net side instead. Applying an activity
    /// multiplier as well would credit that movement twice.
    ///
    /// Neither path accounts for the thermic effect of food, roughly 10% of intake. A fudge
    /// factor here would be inventing a number; the observed estimate measures the shortfall
    /// from real data within a few weeks and the blend moves onto it.
    public var effectiveActivityMultiplier: Double {
        usesMeasuredActivity ? 1.0 : activityLevel.multiplier
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
        // A missing block means Health predates the switches, when it was always available —
        // see ``HealthPreferences/legacyDefault``.
        health = try container.decodeIfPresent(HealthPreferences.self, forKey: .health)
            ?? .legacyDefault
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
