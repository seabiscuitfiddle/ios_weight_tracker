import Foundation

/// Estimates of how much energy the user spends per day, before logged exercise.
///
/// "Before logged exercise" is the load-bearing part. Tally's goal is compared against net
/// calories (food − exercise), so every expenditure figure here must exclude workouts that get
/// logged, or they'd be credited twice. See ``UserProfile/activityLevel``.
public enum Expenditure {
    /// Energy in one pound of body fat, the constant behind every deficit calculation here.
    ///
    /// It is an approximation — real tissue change isn't purely fat, and adaptation shifts the
    /// number over time. That's precisely why Tally doesn't rely on it alone: the observed
    /// estimate below measures what actually happened, and the blend moves toward it.
    public static let caloriesPerPound = 3500.0

    // MARK: Formula estimate

    /// Basal metabolic rate by Mifflin-St Jeor, in kcal/day.
    ///
    /// `BMR = 10·kg + 6.25·cm − 5·years + s`, where `s` is +5 for male and −161 for female.
    /// For an unspecified sex the two constants are averaged (−78) rather than defaulting to
    /// one of them, so the estimate is not silently biased by declining to answer.
    public static func basalMetabolicRate(
        weightPounds: Double,
        heightCentimeters: Double,
        ageYears: Int,
        biologicalSex: UserProfile.BiologicalSex
    ) -> Double {
        let kilograms = weightPounds * WeightSample.kilogramsPerPound
        let sexConstant: Double = switch biologicalSex {
        case .male: 5
        case .female: -161
        case .unspecified: (5 - 161) / 2
        }
        return 10 * kilograms + 6.25 * heightCentimeters - 5 * Double(ageYears) + sexConstant
    }

    /// Formula-based daily expenditure: BMR scaled by everyday activity.
    ///
    /// Returns nil when the profile lacks a height or birth date, which is a legitimate state —
    /// the caller then falls back to the observed estimate or to a manual goal rather than
    /// inventing body measurements.
    public static func formulaEstimate(
        profile: UserProfile,
        weightPounds: Double,
        asOf now: Date = Date(),
        calendar: Calendar = .current
    ) -> Double? {
        guard let height = profile.heightCentimeters,
              let age = profile.age(asOf: now, calendar: calendar),
              height > 0, age > 0, weightPounds > 0
        else { return nil }

        let bmr = basalMetabolicRate(
            weightPounds: weightPounds,
            heightCentimeters: height,
            ageYears: age,
            biologicalSex: profile.biologicalSex
        )
        return bmr * profile.activityLevel.multiplier
    }

    // MARK: Observed estimate

    /// What the data says expenditure actually is, from energy balance.
    ///
    /// Over a window of `days`, weight change and intake are related by
    ///
    ///     poundsChange · 3500 = days · meanNetIntake − days · expenditure
    ///
    /// rearranged to
    ///
    ///     expenditure = meanNetIntake − poundsChange · 3500 / days
    ///
    /// So someone eating a net 2,000/day who lost a pound over a week was spending
    /// `2000 − (−1 · 3500 / 7) = 2500`.
    ///
    /// `poundsChange` must come from the smoothed ``WeightTrend`` rather than from two raw
    /// weigh-ins. Day-to-day weight moves by several pounds on water alone, and at this
    /// leverage — 3500 kcal per pound over a two-week window — a single noisy endpoint would
    /// swing the estimate by hundreds of calories.
    ///
    /// - Parameters:
    ///   - meanNetIntake: Average daily net calories (food − exercise) across the window.
    ///   - poundsChange: Trend weight at the end minus trend weight at the start. Negative
    ///     means weight was lost.
    ///   - days: Length of the window. Must be positive.
    public static func observedEstimate(
        meanNetIntake: Double,
        poundsChange: Double,
        days: Int
    ) -> Double? {
        guard days > 0 else { return nil }
        return meanNetIntake - poundsChange * caloriesPerPound / Double(days)
    }

    // MARK: Blending

    /// The minimum window before an observed estimate is trusted at all.
    ///
    /// Under two weeks, a normal fluctuation in the trend still dominates the signal.
    public static let minimumObservedDays = 14

    /// The window at which the observed estimate is trusted completely.
    public static let fullyObservedDays = 42

    /// How much weight the observed estimate carries, from 0 to 1.
    ///
    /// Zero below ``minimumObservedDays``, then ramping linearly to 1 at
    /// ``fullyObservedDays``. The ramp exists so the goal doesn't lurch on the day the
    /// threshold is crossed — a visible jump in the number would read as a bug, and the
    /// estimate genuinely does get more trustworthy with more days rather than all at once.
    public static func observedWeight(forDays days: Int) -> Double {
        guard days >= minimumObservedDays else { return 0 }
        let span = Double(fullyObservedDays - minimumObservedDays)
        guard span > 0 else { return 1 }
        return min(1, Double(days - minimumObservedDays) / span)
    }

    /// Combines the two estimates according to how much history supports the observed one.
    ///
    /// When only one is available it is used as-is; when neither is, the result is nil and the
    /// caller falls back to a manual goal.
    public static func blendedEstimate(
        formula: Double?,
        observed: Double?,
        observedDays: Int
    ) -> Double? {
        switch (formula, observed) {
        case (nil, nil):
            nil
        case (let formula?, nil):
            formula
        case (nil, let observed?):
            observed
        case (let formula?, let observed?):
            {
                let weight = observedWeight(forDays: observedDays)
                return formula * (1 - weight) + observed * weight
            }()
        }
    }
}
