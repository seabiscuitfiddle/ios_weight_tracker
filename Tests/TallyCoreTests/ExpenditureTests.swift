import Foundation
import Testing
@testable import TallyCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// A birth date placing the person at exactly `age` on `referenceNow`.
private let referenceNow = utc.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 12))!

private func birthDate(forAge age: Int) -> Date {
    utc.date(byAdding: .year, value: -age, to: referenceNow)!
}

@Suite("Basal metabolic rate")
struct BasalMetabolicRateTests {
    /// Mifflin-St Jeor: 10·kg + 6.25·cm − 5·age + s.
    /// 80 kg, 180 cm, 30 y, male → 800 + 1125 − 150 + 5 = 1780.
    @Test("matches the published formula for a male subject")
    func maleReferenceValue() {
        let bmr = Expenditure.basalMetabolicRate(
            weightPounds: 80 * WeightSample.poundsPerKilogram,
            heightCentimeters: 180,
            ageYears: 30,
            biologicalSex: .male
        )
        #expect(abs(bmr - 1780) < 0.01)
    }

    /// 65 kg, 165 cm, 30 y, female → 650 + 1031.25 − 150 − 161 = 1370.25.
    @Test("matches the published formula for a female subject")
    func femaleReferenceValue() {
        let bmr = Expenditure.basalMetabolicRate(
            weightPounds: 65 * WeightSample.poundsPerKilogram,
            heightCentimeters: 165,
            ageYears: 30,
            biologicalSex: .female
        )
        #expect(abs(bmr - 1370.25) < 0.01)
    }

    /// Declining to state a sex shouldn't quietly get you the male estimate — or the female
    /// one. The constants are averaged, so the result sits exactly between the two.
    @Test("averages the sex constants when unspecified")
    func unspecifiedSitsBetween() {
        func bmr(_ sex: UserProfile.BiologicalSex) -> Double {
            Expenditure.basalMetabolicRate(
                weightPounds: 170, heightCentimeters: 175, ageYears: 40, biologicalSex: sex
            )
        }

        let male = bmr(.male)
        let female = bmr(.female)
        let unspecified = bmr(.unspecified)

        #expect(abs(unspecified - (male + female) / 2) < 0.01)
        #expect(unspecified < male)
        #expect(unspecified > female)
        // The two constants differ by 166, so the midpoint is 83 from each.
        #expect(abs((male - unspecified) - 83) < 0.01)
    }

    @Test("BMR falls with age and rises with weight and height")
    func monotonicity() {
        func bmr(weight: Double = 170, height: Double = 175, age: Int = 40) -> Double {
            Expenditure.basalMetabolicRate(
                weightPounds: weight, heightCentimeters: height,
                ageYears: age, biologicalSex: .male
            )
        }

        #expect(bmr(weight: 180) > bmr(weight: 170))
        #expect(bmr(height: 185) > bmr(height: 175))
        #expect(bmr(age: 50) < bmr(age: 40))
    }
}

@Suite("Formula expenditure estimate")
struct FormulaEstimateTests {
    @Test("scales BMR by the activity multiplier")
    func appliesActivityMultiplier() {
        let profile = UserProfile(
            birthDate: birthDate(forAge: 30),
            heightCentimeters: 180,
            biologicalSex: .male,
            activityLevel: .moderate
        )

        let estimate = Expenditure.formulaEstimate(
            profile: profile,
            weightPounds: 80 * WeightSample.poundsPerKilogram,
            asOf: referenceNow,
            calendar: utc
        )

        // BMR 1780 × 1.55 = 2759.
        #expect(estimate != nil)
        #expect(abs((estimate ?? 0) - 1780 * 1.55) < 0.5)
    }

    /// A user who skips the body-measurement questions must still get a working app, so the
    /// estimate reports its own absence instead of substituting invented measurements.
    @Test("is unavailable without a height")
    func requiresHeight() {
        let profile = UserProfile(birthDate: birthDate(forAge: 30), heightCentimeters: nil)
        #expect(Expenditure.formulaEstimate(
            profile: profile, weightPounds: 170, asOf: referenceNow, calendar: utc
        ) == nil)
    }

    @Test("is unavailable without a birth date")
    func requiresAge() {
        let profile = UserProfile(birthDate: nil, heightCentimeters: 180)
        #expect(Expenditure.formulaEstimate(
            profile: profile, weightPounds: 170, asOf: referenceNow, calendar: utc
        ) == nil)
    }

    @Test("rejects nonsensical measurements rather than returning a nonsense estimate")
    func rejectsNonsense() {
        let profile = UserProfile(birthDate: birthDate(forAge: 30), heightCentimeters: 0)
        #expect(Expenditure.formulaEstimate(
            profile: profile, weightPounds: 170, asOf: referenceNow, calendar: utc
        ) == nil)

        let ok = UserProfile(birthDate: birthDate(forAge: 30), heightCentimeters: 180)
        #expect(Expenditure.formulaEstimate(
            profile: ok, weightPounds: 0, asOf: referenceNow, calendar: utc
        ) == nil)
    }

    @Test("every activity level orders as expected")
    func activityOrdering() {
        let levels = UserProfile.ActivityLevel.allCases
        let multipliers = levels.map(\.multiplier)
        #expect(multipliers == multipliers.sorted())
        #expect(multipliers.first == 1.2)
        #expect(multipliers.last == 1.9)
    }

    /// BMR is the same quantity Apple calls Resting Energy, so with Health measuring everything
    /// above it there is nothing left for a multiplier to stand in for.
    @Test("returns BMR alone under measured activity")
    func measuredActivityDropsTheMultiplier() {
        var profile = UserProfile(
            birthDate: birthDate(forAge: 30),
            heightCentimeters: 180,
            biologicalSex: .male,
            activityLevel: .moderate
        )
        profile.health = HealthPreferences(isEnabled: true, usesActivityForExpenditure: true)

        let estimate = Expenditure.formulaEstimate(
            profile: profile,
            weightPounds: 80 * WeightSample.poundsPerKilogram,
            asOf: referenceNow,
            calendar: utc
        )

        #expect(abs((estimate ?? 0) - 1780) < 0.5)
    }
}

@Suite("Health switches")
struct HealthPreferenceTests {
    @Test("a new profile leaves Health alone")
    func defaultsToOff() {
        #expect(UserProfile.default.health.isEnabled == false)
        #expect(UserProfile.default.usesMeasuredActivity == false)
        #expect(UserProfile.default.effectiveActivityMultiplier
            == UserProfile.default.activityLevel.multiplier)
    }

    @Test("measured activity needs both switches")
    func needsBothSwitches() {
        var profile = UserProfile(activityLevel: .moderate)

        profile.health = HealthPreferences(isEnabled: false, usesActivityForExpenditure: true)
        #expect(profile.usesMeasuredActivity == false)
        #expect(profile.effectiveActivityMultiplier == 1.55)

        profile.health = HealthPreferences(isEnabled: true, usesActivityForExpenditure: false)
        #expect(profile.usesMeasuredActivity == false)
        #expect(profile.effectiveActivityMultiplier == 1.55)

        profile.health = HealthPreferences(isEnabled: true, usesActivityForExpenditure: true)
        #expect(profile.usesMeasuredActivity)
        #expect(profile.effectiveActivityMultiplier == 1.0)
    }

    /// Switching Health off leaves the nested flag set. The modelled multiplier has to come
    /// back at that moment, or the day would have no expenditure above resting at all.
    @Test("restores the multiplier when Health is switched off")
    func restoresMultiplierOnSwitchOff() {
        var profile = UserProfile(activityLevel: .veryActive)
        profile.health = HealthPreferences(isEnabled: true, usesActivityForExpenditure: true)
        profile.health.isEnabled = false

        #expect(profile.health.usesActivityForExpenditure)
        #expect(profile.effectiveActivityMultiplier == 1.725)
    }

    /// Health was always reachable before these switches existed, so a stored profile that
    /// predates them must not read as a user who turned it off.
    @Test("a profile saved before the switches keeps Health available")
    func legacyProfilesStayEnabled() throws {
        let legacy = """
            {"biologicalSex":"male","activityLevel":"light","massUnit":"pounds"}
            """
        let decoded = try JSONDecoder().decode(UserProfile.self, from: Data(legacy.utf8))

        #expect(decoded.health.isEnabled)
        #expect(decoded.usesMeasuredActivity == false)
    }

    @Test("survives a round trip")
    func roundTrips() throws {
        var profile = UserProfile(heightCentimeters: 178)
        profile.health = HealthPreferences(
            isEnabled: true,
            usesActivityForExpenditure: true,
            activityTrackingStartDay: Day(year: 2026, month: 8, day: 1)
        )

        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(UserProfile.self, from: data) == profile)
    }
}

@Suite("Observed expenditure estimate")
struct ObservedEstimateTests {
    /// The worked example: netting 2,000 a day and losing a pound over a week means about
    /// 2,500 a day was being spent.
    @Test("recovers expenditure from intake and weight change")
    func workedExample() {
        let estimate = Expenditure.observedEstimate(
            meanNetIntake: 2000, poundsChange: -1, days: 7
        )
        #expect(estimate == 2500)
    }

    @Test("weight held steady means intake equalled expenditure")
    func maintenanceCase() {
        #expect(Expenditure.observedEstimate(
            meanNetIntake: 2200, poundsChange: 0, days: 28
        ) == 2200)
    }

    @Test("weight gained means expenditure was below intake")
    func gainCase() {
        // +1 lb over 7 days on 3,000/day → 3000 − 500 = 2500.
        #expect(Expenditure.observedEstimate(
            meanNetIntake: 3000, poundsChange: 1, days: 7
        ) == 2500)
    }

    /// The same pound of change over a longer window implies a smaller daily gap. Getting this
    /// backwards would make the goal over-correct on long windows.
    @Test("divides the energy gap across the window length")
    func scalesWithWindow() {
        let overOneWeek = Expenditure.observedEstimate(
            meanNetIntake: 2000, poundsChange: -1, days: 7
        )!
        let overFourWeeks = Expenditure.observedEstimate(
            meanNetIntake: 2000, poundsChange: -1, days: 28
        )!

        #expect(overOneWeek == 2500)
        #expect(overFourWeeks == 2125)
        #expect(overFourWeeks < overOneWeek)
    }

    @Test("rejects a non-positive window")
    func rejectsEmptyWindow() {
        #expect(Expenditure.observedEstimate(meanNetIntake: 2000, poundsChange: -1, days: 0) == nil)
        #expect(Expenditure.observedEstimate(meanNetIntake: 2000, poundsChange: -1, days: -7) == nil)
    }
}

@Suite("Blending the two estimates")
struct BlendTests {
    @Test("ignores the observed estimate below the minimum window")
    func noTrustBeforeTwoWeeks() {
        #expect(Expenditure.observedWeight(forDays: 0) == 0)
        #expect(Expenditure.observedWeight(forDays: 13) == 0)
    }

    /// The ramp starts at zero on day 14 rather than jumping. A step change would move the
    /// user's goal by hundreds of calories overnight, which reads as a bug.
    @Test("ramps from zero trust at two weeks to full trust at six")
    func rampShape() {
        #expect(Expenditure.observedWeight(forDays: 14) == 0)
        #expect(abs(Expenditure.observedWeight(forDays: 28) - 0.5) < 0.001)
        #expect(Expenditure.observedWeight(forDays: 42) == 1)
        // Stays saturated rather than exceeding 1.
        #expect(Expenditure.observedWeight(forDays: 400) == 1)
    }

    @Test("the ramp never decreases")
    func rampIsMonotonic() {
        let weights = (0...60).map(Expenditure.observedWeight(forDays:))
        #expect(weights == weights.sorted())
    }

    @Test("blends according to the ramp weight")
    func blendsProportionally() {
        // At 28 days the weight is 0.5, so the result is the midpoint.
        let blended = Expenditure.blendedEstimate(formula: 2000, observed: 3000, observedDays: 28)
        #expect(abs((blended ?? 0) - 2500) < 1)

        // At 42 days the observed estimate wins outright.
        #expect(Expenditure.blendedEstimate(formula: 2000, observed: 3000, observedDays: 42) == 3000)
        // At 14 days the formula still does.
        #expect(Expenditure.blendedEstimate(formula: 2000, observed: 3000, observedDays: 14) == 2000)
    }

    @Test("falls back to whichever estimate exists")
    func singleSidedFallback() {
        #expect(Expenditure.blendedEstimate(formula: 2200, observed: nil, observedDays: 100) == 2200)
        #expect(Expenditure.blendedEstimate(formula: nil, observed: 2400, observedDays: 100) == 2400)
        #expect(Expenditure.blendedEstimate(formula: nil, observed: nil, observedDays: 100) == nil)
    }
}
