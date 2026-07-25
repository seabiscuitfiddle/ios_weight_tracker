import Foundation

/// A computed daily calorie target, with everything the UI needs to explain it.
///
/// The design's Weight & Goal screen shows the goal, the deficit that produced it, and the date
/// it implies — so the goal cannot just be a number. Carrying the reasoning here also means the
/// app can be honest when a target isn't achievable, instead of quietly issuing a smaller number.
public struct DailyGoal: Hashable, Sendable {
    public enum Direction: String, Hashable, Sendable {
        case lose, gain, maintain
    }

    /// Where the maintenance figure came from, so the UI can say how much to trust it.
    public enum Basis: Hashable, Sendable {
        /// The user set the number themselves; nothing was estimated.
        case manual
        /// Mifflin-St Jeor only — not enough history yet to check it against reality.
        case formula
        /// Entirely from observed energy balance; the formula wasn't available.
        case observed
        /// A mix, weighted by how much history supports the observed estimate.
        case blended(observedWeight: Double)

        /// Short phrase for the UI, e.g. under the computed goal panel.
        public var explanation: String {
            switch self {
            case .manual:
                "Set by you"
            case .formula:
                "Estimated from your height, age, and activity"
            case .observed:
                "Measured from your logging and weight trend"
            case .blended(let weight):
                weight < 0.5
                    ? "Estimated from your profile, adjusting to your logged results"
                    : "Measured from your logged results, checked against your profile"
            }
        }
    }

    /// The number to eat to, compared against the day's **net** calories.
    public var calories: Int
    /// Estimated expenditure before logged exercise — what eating this much would maintain.
    public var maintenanceCalories: Int
    /// `calories − maintenanceCalories`. Negative for a deficit, which is what the design
    /// renders as "−500 / day".
    public var dailyAdjustment: Int
    public var direction: Direction
    public var basis: Basis

    /// The lowest number Tally is willing to ask anyone to eat.
    public var floorCalories: Int
    /// True when the chosen rate would have gone below ``floorCalories`` and was held there.
    /// The UI must say so — the user picked a rate they are not actually going to achieve.
    public var wasClampedToFloor: Bool

    /// The rate this goal will really produce, after any clamping. Positive means losing.
    /// This is what the projection uses, so the date shown is achievable rather than requested.
    public var effectivePoundsPerWeek: Double
    /// Pounds between current trend weight and the target, unsigned.
    public var poundsToTarget: Double?
    /// When the target should be reached at ``effectivePoundsPerWeek``.
    public var projectedGoalDay: Day?

    public init(
        calories: Int,
        maintenanceCalories: Int,
        dailyAdjustment: Int,
        direction: Direction,
        basis: Basis,
        floorCalories: Int,
        wasClampedToFloor: Bool,
        effectivePoundsPerWeek: Double,
        poundsToTarget: Double? = nil,
        projectedGoalDay: Day? = nil
    ) {
        self.calories = calories
        self.maintenanceCalories = maintenanceCalories
        self.dailyAdjustment = dailyAdjustment
        self.direction = direction
        self.basis = basis
        self.floorCalories = floorCalories
        self.wasClampedToFloor = wasClampedToFloor
        self.effectivePoundsPerWeek = effectivePoundsPerWeek
        self.poundsToTarget = poundsToTarget
        self.projectedGoalDay = projectedGoalDay
    }
}

/// Turns a profile, a target, and the logged history into a daily goal.
///
/// Every method is a pure function of its inputs — no storage, no clock beyond what's passed in
/// — which is what makes the arithmetic here exhaustively testable.
public enum GoalCalculator {
    /// Never ask anyone to eat less than this, whatever their target says.
    ///
    /// 1,200 kcal is the conventional floor for adults, and Tally additionally refuses to go
    /// below estimated BMR. A tracker that silently obeys an aggressive target is doing the
    /// user harm while looking like it's helping; when the numbers don't allow the requested
    /// rate, saying so is the only honest option.
    public static let absoluteFloorCalories = 1200

    /// The most recent stretch used to measure observed expenditure.
    ///
    /// Shorter than the blend ramp on purpose: the *estimate* should reflect current
    /// metabolism and habits, while how much we *trust* it grows with total history.
    public static let observedWindowDays = 28

    /// Minimum share of days in the window that must have entries before the observed estimate
    /// is used.
    ///
    /// Unlogged days are the trap here. They cannot be treated as zero-calorie days — doing so
    /// would drag the mean intake down and inflate estimated expenditure by hundreds of
    /// calories. They're excluded from the mean instead, but that only holds up if most days
    /// are actually logged.
    public static let minimumLoggingCoverage = 0.7

    public struct Inputs: Sendable {
        public var profile: UserProfile
        public var settings: GoalSettings
        /// All weight readings; order doesn't matter.
        public var weightSamples: [WeightSample]
        /// Net calories per day, for days that have at least one entry. Days absent from this
        /// dictionary are treated as unlogged, **not** as zero.
        public var dailyNetCalories: [Day: Int]
        public var today: Day
        public var now: Date
        public var calendar: Calendar

        public init(
            profile: UserProfile,
            settings: GoalSettings,
            weightSamples: [WeightSample],
            dailyNetCalories: [Day: Int],
            today: Day = Day.today(),
            now: Date = Date(),
            calendar: Calendar = .current
        ) {
            self.profile = profile
            self.settings = settings
            self.weightSamples = weightSamples
            self.dailyNetCalories = dailyNetCalories
            self.today = today
            self.now = now
            self.calendar = calendar
        }
    }

    /// The goal, or nil when there is genuinely nothing to compute it from.
    ///
    /// Returning nil rather than a plausible-looking default is deliberate. A tracker that
    /// invents 2,000 kcal for a user it knows nothing about is presenting a guess as a
    /// prescription; the app should ask for a height or a goal weight instead.
    public static func dailyGoal(_ inputs: Inputs) -> DailyGoal? {
        let trend = WeightTrend(samples: inputs.weightSamples)
        let currentPounds = trend.currentTrendPounds

        let formula = currentPounds.flatMap {
            Expenditure.formulaEstimate(
                profile: inputs.profile,
                weightPounds: $0,
                asOf: inputs.now,
                calendar: inputs.calendar
            )
        }
        let observation = observedExpenditure(inputs, trend: trend)
        let maintenance = Expenditure.blendedEstimate(
            formula: formula,
            observed: observation?.estimate,
            observedDays: trend.spannedDays(calendar: inputs.calendar)
        )

        // With no maintenance estimate, a manual goal is the only thing that can still produce
        // a usable target.
        guard let maintenance else {
            guard let manual = inputs.settings.manualCalorieGoal else { return nil }
            return DailyGoal(
                calories: manual,
                maintenanceCalories: manual,
                dailyAdjustment: 0,
                direction: .maintain,
                basis: .manual,
                floorCalories: absoluteFloorCalories,
                wasClampedToFloor: false,
                effectivePoundsPerWeek: 0
            )
        }

        let basis = self.basis(
            formula: formula,
            observed: observation?.estimate,
            observedDays: trend.spannedDays(calendar: inputs.calendar)
        )

        let direction = self.direction(
            currentPounds: currentPounds,
            targetPounds: inputs.settings.targetPounds
        )

        let floor = floorCalories(inputs: inputs, currentPounds: currentPounds)
        let maintenanceRounded = Int(maintenance.rounded())

        // A manual goal replaces the computed target but keeps the estimate around, so the UI
        // can still show what maintenance looks like and how far the manual number sits from it.
        if let manual = inputs.settings.manualCalorieGoal {
            let adjustment = manual - maintenanceRounded
            return DailyGoal(
                calories: manual,
                maintenanceCalories: maintenanceRounded,
                dailyAdjustment: adjustment,
                direction: direction,
                basis: .manual,
                floorCalories: floor,
                wasClampedToFloor: false,
                effectivePoundsPerWeek: poundsPerWeek(fromDailyAdjustment: -adjustment),
                poundsToTarget: poundsToTarget(inputs, currentPounds: currentPounds),
                projectedGoalDay: nil
            )
        }

        let target = self.target(
            maintenanceCalories: maintenanceRounded,
            direction: direction,
            rate: inputs.settings.rate,
            floorCalories: floor
        )

        let effectiveRate = poundsPerWeek(fromDailyAdjustment: -target.adjustment)
        let toTarget = poundsToTarget(inputs, currentPounds: currentPounds)

        return DailyGoal(
            calories: target.calories,
            maintenanceCalories: maintenanceRounded,
            dailyAdjustment: target.adjustment,
            direction: direction,
            basis: basis,
            floorCalories: floor,
            wasClampedToFloor: target.wasClampedToFloor,
            effectivePoundsPerWeek: effectiveRate,
            poundsToTarget: toTarget,
            projectedGoalDay: projectedGoalDay(
                poundsToTarget: toTarget,
                poundsPerWeek: effectiveRate,
                from: inputs.today,
                calendar: inputs.calendar
            )
        )
    }

    /// Applies a rate to a maintenance figure and enforces the floor.
    ///
    /// Separated out because this is the arithmetic users can check by hand — 2,600 maintenance
    /// at a pound a week is a 500 kcal deficit and a 2,100 goal — and it should be assertable
    /// without going through weight-trend estimation to get there.
    ///
    /// - Returns: the target, the signed adjustment actually applied (negative for a deficit),
    ///   and whether the floor bit.
    public static func target(
        maintenanceCalories: Int,
        direction: DailyGoal.Direction,
        rate: GoalSettings.WeeklyRate,
        floorCalories: Int
    ) -> (calories: Int, adjustment: Int, wasClampedToFloor: Bool) {
        let magnitude = Int((rate.poundsPerWeek * Expenditure.caloriesPerPound / 7).rounded())

        let requestedAdjustment: Int = switch direction {
        case .maintain: 0
        case .lose: -magnitude
        case .gain: magnitude
        }

        let requested = maintenanceCalories + requestedAdjustment
        let clamped = max(requested, floorCalories)
        return (clamped, clamped - maintenanceCalories, clamped != requested)
    }

    // MARK: Pieces

    /// The observed estimate plus the window it came from, or nil when there isn't enough
    /// logging to support one.
    public static func observedExpenditure(
        _ inputs: Inputs,
        trend: WeightTrend
    ) -> (estimate: Double, windowDays: Int, coverage: Double)? {
        let span = trend.spannedDays(calendar: inputs.calendar)
        guard span >= Expenditure.minimumObservedDays else { return nil }

        let windowDays = min(span, observedWindowDays)
        guard let change = trend.trendChange(overLast: windowDays, calendar: inputs.calendar),
              let lastDay = trend.lastDay
        else { return nil }

        let windowStart = lastDay.adding(days: -windowDays, calendar: inputs.calendar)
        let days = Day.trailing(windowDays, endingOn: lastDay, calendar: inputs.calendar)
            .filter { $0 > windowStart }

        let logged = days.compactMap { inputs.dailyNetCalories[$0] }
        guard !logged.isEmpty else { return nil }

        let coverage = Double(logged.count) / Double(max(days.count, 1))
        guard coverage >= minimumLoggingCoverage else { return nil }

        let meanNetIntake = Double(logged.reduce(0, +)) / Double(logged.count)
        guard let estimate = Expenditure.observedEstimate(
            meanNetIntake: meanNetIntake,
            poundsChange: change,
            days: windowDays
        ) else { return nil }

        // An estimate below BMR-ish territory means the inputs are inconsistent — usually
        // heavily under-logged food. Better to fall back to the formula than to hand back a
        // number that would drive the goal into the floor.
        guard estimate > Double(absoluteFloorCalories) else { return nil }

        return (estimate, windowDays, coverage)
    }

    static func basis(formula: Double?, observed: Double?, observedDays: Int) -> DailyGoal.Basis {
        switch (formula, observed) {
        case (_, nil): .formula
        case (nil, _): .observed
        default: .blended(observedWeight: Expenditure.observedWeight(forDays: observedDays))
        }
    }

    /// Below this difference, chasing a target is noise — the trend itself moves more than
    /// half a pound — so the goal becomes maintenance.
    static let maintenanceThresholdPounds = 0.5

    static func direction(currentPounds: Double?, targetPounds: Double?) -> DailyGoal.Direction {
        guard let currentPounds, let targetPounds else { return .maintain }
        let difference = targetPounds - currentPounds
        if abs(difference) < maintenanceThresholdPounds { return .maintain }
        return difference < 0 ? .lose : .gain
    }

    /// The floor for this user: never below 1,200, and never below their own BMR.
    static func floorCalories(inputs: Inputs, currentPounds: Double?) -> Int {
        guard let currentPounds,
              let height = inputs.profile.heightCentimeters,
              let age = inputs.profile.age(asOf: inputs.now, calendar: inputs.calendar)
        else { return absoluteFloorCalories }

        let bmr = Expenditure.basalMetabolicRate(
            weightPounds: currentPounds,
            heightCentimeters: height,
            ageYears: age,
            biologicalSex: inputs.profile.biologicalSex
        )
        return max(absoluteFloorCalories, Int(bmr.rounded()))
    }

    static func poundsToTarget(_ inputs: Inputs, currentPounds: Double?) -> Double? {
        guard let currentPounds, let target = inputs.settings.targetPounds else { return nil }
        return abs(target - currentPounds)
    }

    /// Converts a daily deficit into the weekly weight change it implies.
    static func poundsPerWeek(fromDailyAdjustment deficit: Int) -> Double {
        Double(deficit) * 7 / Expenditure.caloriesPerPound
    }

    static func projectedGoalDay(
        poundsToTarget: Double?,
        poundsPerWeek: Double,
        from today: Day,
        calendar: Calendar
    ) -> Day? {
        guard let poundsToTarget, poundsToTarget > 0, poundsPerWeek > 0 else { return nil }
        let weeks = poundsToTarget / poundsPerWeek
        let days = Int((weeks * 7).rounded(.up))
        // Guard against absurd projections from a near-zero rate; "some time in the next
        // decade" is not information worth showing.
        guard days <= 3650 else { return nil }
        return today.adding(days: days, calendar: calendar)
    }
}
