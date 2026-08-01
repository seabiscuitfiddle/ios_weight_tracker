import Foundation
import Testing
@testable import TallyCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let today = Day(year: 2026, month: 7, day: 23)
private let now = utc.date(from: DateComponents(year: 2026, month: 7, day: 23, hour: 9, minute: 41))!

private func birthDate(forAge age: Int) -> Date {
    utc.date(byAdding: .year, value: -age, to: now)!
}

/// A profile that supports the formula estimate.
private func profile(
    age: Int = 35,
    heightCm: Double = 178,
    sex: UserProfile.BiologicalSex = .male,
    activity: UserProfile.ActivityLevel = .light
) -> UserProfile {
    UserProfile(
        birthDate: birthDate(forAge: age),
        heightCentimeters: heightCm,
        biologicalSex: sex,
        activityLevel: activity
    )
}

/// `count` daily weight readings ending today, declining by `perDay` pounds.
private func decliningWeights(
    from startPounds: Double,
    perDay: Double,
    count: Int
) -> [WeightSample] {
    (0..<count).map { offset in
        WeightSample(
            day: today.adding(days: -(count - 1 - offset), calendar: utc),
            pounds: startPounds - perDay * Double(offset)
        )
    }
}

/// A constant net intake on every one of the `count` days ending today.
private func netIntake(_ calories: Int, days count: Int) -> [Day: Int] {
    Dictionary(uniqueKeysWithValues: (0..<count).map {
        (today.adding(days: -$0, calendar: utc), calories)
    })
}

private func inputs(
    profile: UserProfile = profile(),
    settings: GoalSettings = GoalSettings(),
    weights: [WeightSample] = [],
    net: [Day: Int] = [:],
    validFrom: Day? = nil
) -> GoalCalculator.Inputs {
    GoalCalculator.Inputs(
        profile: profile,
        settings: settings,
        weightSamples: weights,
        dailyNetCalories: net,
        netCaloriesValidFrom: validFrom,
        today: today,
        now: now,
        calendar: utc
    )
}

@Suite("Goal derivation")
struct GoalDerivationTests {
    /// The design's own numbers: 2,600 maintenance at a pound a week is a 500 kcal deficit and
    /// a 2,100 target, shown as "−500 / day" beside a goal of 2,100.
    @Test("reproduces the design's worked example")
    func designFixture() {
        let target = GoalCalculator.target(
            maintenanceCalories: 2600,
            direction: .lose,
            rate: .standard,
            floorCalories: 1200
        )

        #expect(target.calories == 2100)
        #expect(target.adjustment == -500)
        #expect(target.wasClampedToFloor == false)
    }

    @Test("each rate produces the deficit it advertises", arguments: [
        (GoalSettings.WeeklyRate.gentle, -250),
        (GoalSettings.WeeklyRate.standard, -500),
        (GoalSettings.WeeklyRate.aggressive, -750),
    ])
    func ratesMapToDeficits(_ rate: GoalSettings.WeeklyRate, _ expected: Int) {
        let target = GoalCalculator.target(
            maintenanceCalories: 2600, direction: .lose, rate: rate, floorCalories: 1200
        )
        #expect(target.adjustment == expected)
        #expect(target.calories == 2600 + expected)
    }

    @Test("gaining adds the same magnitude it would have subtracted")
    func gainingIsSymmetric() {
        let losing = GoalCalculator.target(
            maintenanceCalories: 2600, direction: .lose, rate: .standard, floorCalories: 1200
        )
        let gaining = GoalCalculator.target(
            maintenanceCalories: 2600, direction: .gain, rate: .standard, floorCalories: 1200
        )

        #expect(losing.adjustment == -500)
        #expect(gaining.adjustment == 500)
        #expect(gaining.calories == 3100)
    }

    @Test("maintaining applies no adjustment whatever the rate")
    func maintenanceIgnoresRate() {
        for rate in GoalSettings.WeeklyRate.allCases {
            let target = GoalCalculator.target(
                maintenanceCalories: 2600, direction: .maintain, rate: rate, floorCalories: 1200
            )
            #expect(target.calories == 2600)
            #expect(target.adjustment == 0)
        }
    }

    /// The safety property. Someone small choosing the fastest rate can arithmetically land
    /// under 1,200 kcal; obeying that silently would be actively harmful, so the goal is held
    /// at the floor and flagged for the UI to explain.
    @Test("holds at the floor instead of prescribing a starvation target")
    func clampsAtFloor() {
        let target = GoalCalculator.target(
            maintenanceCalories: 1700, direction: .lose, rate: .aggressive, floorCalories: 1400
        )

        // 1700 − 750 = 950 would have been the naive answer.
        #expect(target.calories == 1400)
        #expect(target.adjustment == -300)
        #expect(target.wasClampedToFloor)
    }

    @Test("does not flag clamping when the floor is not reached")
    func noFalseClampFlag() {
        let target = GoalCalculator.target(
            maintenanceCalories: 2600, direction: .lose, rate: .aggressive, floorCalories: 1200
        )
        #expect(target.wasClampedToFloor == false)
        #expect(target.calories == 1850)
    }
}

@Suite("Goal floor")
struct GoalFloorTests {
    /// The floor is the greater of 1,200 and the user's own BMR — a tall or heavy person's BMR
    /// exceeds 1,200, and eating under it is the thing worth preventing.
    @Test("uses BMR when it exceeds the absolute floor")
    func bmrRaisesTheFloor() {
        let floor = GoalCalculator.floorCalories(
            inputs: inputs(profile: profile(age: 30, heightCm: 190, sex: .male)),
            currentPounds: 220
        )
        #expect(floor > GoalCalculator.absoluteFloorCalories)
    }

    @Test("falls back to the absolute floor without body measurements")
    func absoluteFloorWithoutProfile() {
        let bare = UserProfile()
        #expect(GoalCalculator.floorCalories(
            inputs: inputs(profile: bare), currentPounds: 170
        ) == GoalCalculator.absoluteFloorCalories)

        // Also when there's no weight to compute BMR from.
        #expect(GoalCalculator.floorCalories(
            inputs: inputs(profile: profile()), currentPounds: nil
        ) == GoalCalculator.absoluteFloorCalories)
    }

    @Test("never drops below the absolute floor for a very small BMR")
    func neverBelowAbsoluteFloor() {
        // A small, elderly profile whose BMR lands under 1,200.
        let floor = GoalCalculator.floorCalories(
            inputs: inputs(profile: profile(age: 80, heightCm: 145, sex: .female)),
            currentPounds: 95
        )
        #expect(floor == GoalCalculator.absoluteFloorCalories)
    }
}

@Suite("Goal direction")
struct GoalDirectionTests {
    @Test("chooses direction from target versus current weight")
    func directionFromTarget() {
        #expect(GoalCalculator.direction(currentPounds: 168.4, targetPounds: 155) == .lose)
        #expect(GoalCalculator.direction(currentPounds: 140, targetPounds: 155) == .gain)
    }

    /// Within half a pound the trend itself moves more than the gap, so chasing it would be
    /// chasing noise.
    @Test("treats a near-identical target as maintenance")
    func maintenanceBand() {
        #expect(GoalCalculator.direction(currentPounds: 155.0, targetPounds: 155.0) == .maintain)
        #expect(GoalCalculator.direction(currentPounds: 155.4, targetPounds: 155.0) == .maintain)
        #expect(GoalCalculator.direction(currentPounds: 155.6, targetPounds: 155.0) == .lose)
    }

    @Test("maintains when there is no target at all")
    func noTargetMeansMaintenance() {
        #expect(GoalCalculator.direction(currentPounds: 168, targetPounds: nil) == .maintain)
        #expect(GoalCalculator.direction(currentPounds: nil, targetPounds: 155) == .maintain)
    }
}

@Suite("Goal projection")
struct GoalProjectionTests
{
    /// 13.4 lb to lose at a pound a week is 13.4 weeks — about 94 days, landing in late
    /// October. The design shows exactly this kind of "Goal by" date.
    @Test("projects a completion date from the effective rate")
    func projectsDate() {
        let day = GoalCalculator.projectedGoalDay(
            poundsToTarget: 13.4, poundsPerWeek: 1.0, from: today, calendar: utc
        )
        #expect(day == today.adding(days: 94, calendar: utc))
    }

    @Test("a faster rate arrives sooner")
    func fasterIsSooner() {
        let slow = GoalCalculator.projectedGoalDay(
            poundsToTarget: 10, poundsPerWeek: 0.5, from: today, calendar: utc
        )!
        let fast = GoalCalculator.projectedGoalDay(
            poundsToTarget: 10, poundsPerWeek: 1.5, from: today, calendar: utc
        )!
        #expect(fast < slow)
    }

    @Test("has no date when not moving toward the target")
    func noDateWithoutProgress() {
        #expect(GoalCalculator.projectedGoalDay(
            poundsToTarget: 10, poundsPerWeek: 0, from: today, calendar: utc
        ) == nil)
        #expect(GoalCalculator.projectedGoalDay(
            poundsToTarget: nil, poundsPerWeek: 1, from: today, calendar: utc
        ) == nil)
        #expect(GoalCalculator.projectedGoalDay(
            poundsToTarget: 0, poundsPerWeek: 1, from: today, calendar: utc
        ) == nil)
    }

    /// A near-zero rate implies a date decades out, which is not information — better to show
    /// nothing than "Goal by March 2071".
    @Test("declines to project absurdly distant dates")
    func rejectsAbsurdProjections() {
        #expect(GoalCalculator.projectedGoalDay(
            poundsToTarget: 50, poundsPerWeek: 0.01, from: today, calendar: utc
        ) == nil)
    }
}

@Suite("Goal calculation end to end")
struct GoalCalculationTests {
    /// With nothing known — no measurements, no history, no manual number — the honest answer
    /// is "I can't tell you", so the UI can ask instead of showing an invented target.
    @Test("returns nothing when there is nothing to compute from")
    func unavailableWithoutAnything() {
        let goal = GoalCalculator.dailyGoal(inputs(profile: UserProfile()))
        #expect(goal == nil)
    }

    @Test("uses the formula alone on the first day of logging")
    func formulaOnlyAtTheStart() throws {
        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155),
            weights: [WeightSample(day: today, pounds: 168.4)]
        )))

        #expect(goal.basis == .formula)
        #expect(goal.direction == .lose)
        #expect(goal.dailyAdjustment == -500)
        #expect(goal.calories == goal.maintenanceCalories - 500)
        #expect(goal.effectivePoundsPerWeek == 1.0)
    }

    @Test("a manual goal overrides the computed one but keeps the estimate visible")
    func manualOverride() throws {
        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155, manualCalorieGoal: 1900),
            weights: [WeightSample(day: today, pounds: 168.4)]
        )))

        #expect(goal.basis == .manual)
        #expect(goal.calories == 1900)
        // Maintenance is still reported, so the UI can show how far the manual number sits
        // from it.
        #expect(goal.maintenanceCalories > 1900)
        #expect(goal.dailyAdjustment == 1900 - goal.maintenanceCalories)
    }

    @Test("a manual goal works even with no profile at all")
    func manualWithoutProfile() throws {
        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            profile: UserProfile(),
            settings: GoalSettings(manualCalorieGoal: 2000)
        )))

        #expect(goal.calories == 2000)
        #expect(goal.basis == .manual)
    }

    /// After six weeks of consistent logging the observed estimate should be trusted fully, and
    /// it should reflect what actually happened rather than the formula's guess.
    @Test("shifts to the observed estimate once there is enough history")
    func blendsTowardObserved() throws {
        // Six weeks of daily weigh-ins declining 1 lb/week, with net intake at 2,000.
        // Energy balance says expenditure was about 2,500.
        let weights = decliningWeights(from: 175, perDay: 1.0 / 7.0, count: 43)
        let net = netIntake(2000, days: 43)

        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155),
            weights: weights,
            net: net
        )))

        guard case .blended(let observedWeight) = goal.basis else {
            Issue.record("expected a blended basis, got \(goal.basis)")
            return
        }
        #expect(observedWeight == 1.0)
        // Should land near the observed 2,500 rather than the formula's estimate.
        #expect(abs(goal.maintenanceCalories - 2500) < 150)
    }

    /// Unlogged days must not be read as zero-calorie days. Treating them as zeroes would drag
    /// mean intake down and inflate estimated expenditure by hundreds of calories, quietly
    /// handing the user a goal that is far too high.
    @Test("ignores the observed estimate when too few days are logged")
    func requiresLoggingCoverage() throws {
        let weights = decliningWeights(from: 175, perDay: 1.0 / 7.0, count: 43)
        // Only every third day logged — well under the coverage threshold.
        let sparse = Dictionary(uniqueKeysWithValues: stride(from: 0, to: 43, by: 3).map {
            (today.adding(days: -$0, calendar: utc), 2000)
        })

        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155),
            weights: weights,
            net: sparse
        )))

        #expect(goal.basis == .formula)
    }

    @Test("ignores the observed estimate before two weeks of weight history")
    func requiresTwoWeeksOfWeights() throws {
        let weights = decliningWeights(from: 175, perDay: 1.0 / 7.0, count: 10)
        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155),
            weights: weights,
            net: netIntake(2000, days: 10)
        )))

        #expect(goal.basis == .formula)
    }

    /// Severely under-logged food produces an implausibly low observed estimate. Using it would
    /// drive the goal into the floor, so the formula is preferred instead.
    @Test("rejects an implausibly low observed estimate")
    func rejectsImplausibleObservation() throws {
        // Weight perfectly flat while claiming to eat 400 a day: the numbers cannot both be
        // true, and the likely explanation is unlogged food.
        let weights = (0..<43).map {
            WeightSample(day: today.adding(days: -$0, calendar: utc), pounds: 170)
        }

        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155),
            weights: weights,
            net: netIntake(400, days: 43)
        )))

        #expect(goal.basis == .formula)
    }

    /// Switching to measured activity changes what a day's net calories *mean*: movement now
    /// comes off the net instead of being folded into the multiplier. Averaging across that
    /// boundary would inflate maintenance for a month.
    @Test("ignores net calories logged before they became comparable")
    func excludesDaysBeforeTheBoundary() throws {
        let weights = decliningWeights(from: 175, perDay: 1.0 / 7.0, count: 43)

        let withoutBoundary = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155),
            weights: weights,
            net: netIntake(2000, days: 43)
        )))
        #expect(withoutBoundary.basis != .formula)

        // Only three days of comparable history: not enough to observe anything.
        let withBoundary = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155),
            weights: weights,
            net: netIntake(2000, days: 43),
            validFrom: today.adding(days: -3, calendar: utc)
        )))
        #expect(withBoundary.basis == .formula)
    }

    @Test("observes again once two weeks of comparable days accumulate")
    func observesAfterTheRamp() throws {
        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155),
            weights: decliningWeights(from: 175, perDay: 1.0 / 7.0, count: 43),
            net: netIntake(2000, days: 43),
            validFrom: today.adding(days: -Expenditure.minimumObservedDays, calendar: utc)
        )))

        #expect(goal.basis != .formula)
    }

    /// The trust ramp measures how much history supports the observed estimate. History that
    /// measured a different quantity doesn't support it, however long the weight line is.
    @Test("ramps trust from the boundary, not from the first weigh-in")
    func rampsTrustFromTheBoundary() throws {
        let weights = decliningWeights(from: 175, perDay: 1.0 / 7.0, count: 60)
        let net = netIntake(2000, days: 60)

        let fullHistory = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155), weights: weights, net: net
        )))
        let sinceBoundary = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155), weights: weights, net: net,
            validFrom: today.adding(days: -20, calendar: utc)
        )))

        guard case .blended(let fullWeight) = fullHistory.basis,
              case .blended(let boundedWeight) = sinceBoundary.basis
        else {
            Issue.record("expected both goals to be blended")
            return
        }

        #expect(fullWeight == 1)
        #expect(boundedWeight < fullWeight)
    }

    /// A goal built on Health's activity figure shouldn't claim to have estimated it.
    @Test("says when activity was measured rather than estimated")
    func explainsMeasuredActivity() throws {
        var measured = profile()
        measured.health = HealthPreferences(isEnabled: true, usesActivityForExpenditure: true)

        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            profile: measured,
            settings: GoalSettings(targetPounds: 155),
            weights: [WeightSample(day: today, pounds: 168.4)]
        )))

        #expect(goal.basis == .measuredActivity)
        #expect(goal.basis.explanation.contains("Apple Health"))
    }

    /// BMR alone, because everything above it now arrives as an entry. A goal that kept the
    /// multiplier as well would credit the same movement twice.
    @Test("drops the activity multiplier under measured activity")
    func dropsTheMultiplier() throws {
        let modelled = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155),
            weights: [WeightSample(day: today, pounds: 168.4)]
        )))

        var measured = profile()
        measured.health = HealthPreferences(isEnabled: true, usesActivityForExpenditure: true)
        let health = try #require(GoalCalculator.dailyGoal(inputs(
            profile: measured,
            settings: GoalSettings(targetPounds: 155),
            weights: [WeightSample(day: today, pounds: 168.4)]
        )))

        let bmr = Expenditure.basalMetabolicRate(
            weightPounds: 168.4, heightCentimeters: 178, ageYears: 35, biologicalSex: .male
        )
        #expect(health.maintenanceCalories == Int(bmr.rounded()))
        #expect(health.maintenanceCalories < modelled.maintenanceCalories)
    }

    @Test("carries the distance to target and a projected date")
    func reportsProgressFigures() throws {
        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 155, rate: .standard),
            weights: [WeightSample(day: today, pounds: 168.4)]
        )))

        #expect(abs((goal.poundsToTarget ?? 0) - 13.4) < 0.01)
        #expect(goal.projectedGoalDay != nil)
        #expect((goal.projectedGoalDay ?? today) > today)
    }

    /// When the rate is clamped, the projection must use the rate that will actually happen.
    /// Showing the requested date would promise a result the goal cannot deliver.
    @Test("projects from the achievable rate, not the requested one")
    func projectionUsesEffectiveRate() throws {
        // A small, older profile choosing the most aggressive rate — the floor will bite.
        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            profile: profile(age: 70, heightCm: 152, sex: .female, activity: .sedentary),
            settings: GoalSettings(targetPounds: 110, rate: .aggressive),
            weights: [WeightSample(day: today, pounds: 130)]
        )))

        #expect(goal.wasClampedToFloor)
        #expect(goal.calories == goal.floorCalories)
        // The achievable rate is below the 1.5 lb/wk requested.
        #expect(goal.effectivePoundsPerWeek < 1.5)
        #expect(goal.effectivePoundsPerWeek > 0)

        // And the date reflects that slower reality.
        let honest = GoalCalculator.projectedGoalDay(
            poundsToTarget: goal.poundsToTarget, poundsPerWeek: goal.effectivePoundsPerWeek,
            from: today, calendar: utc
        )
        #expect(goal.projectedGoalDay == honest)
    }

    @Test("no target weight means a maintenance goal")
    func maintenanceWithoutTarget() throws {
        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: nil),
            weights: [WeightSample(day: today, pounds: 168.4)]
        )))

        #expect(goal.direction == .maintain)
        #expect(goal.dailyAdjustment == 0)
        #expect(goal.calories == goal.maintenanceCalories)
        #expect(goal.projectedGoalDay == nil)
    }

    @Test("a gain target raises the goal above maintenance")
    func gainRaisesGoal() throws {
        let goal = try #require(GoalCalculator.dailyGoal(inputs(
            settings: GoalSettings(targetPounds: 180, rate: .gentle),
            weights: [WeightSample(day: today, pounds: 168.4)]
        )))

        #expect(goal.direction == .gain)
        #expect(goal.dailyAdjustment == 250)
        #expect(goal.calories > goal.maintenanceCalories)
    }

    /// Weight comes from the smoothed trend, not the last reading, so one heavy morning cannot
    /// move the day's goal.
    @Test("a single noisy weigh-in barely moves the goal")
    func goalIsStableAgainstNoise() throws {
        let steady = (0..<20).map {
            WeightSample(day: today.adding(days: -(19 - $0), calendar: utc), pounds: 170)
        }
        var spiked = steady
        spiked[spiked.count - 1] = WeightSample(day: today, pounds: 178)

        let settings = GoalSettings(targetPounds: 155)
        let calm = try #require(GoalCalculator.dailyGoal(inputs(settings: settings, weights: steady)))
        let noisy = try #require(GoalCalculator.dailyGoal(inputs(settings: settings, weights: spiked)))

        // An 8 lb spike would move a raw-weight goal by roughly 60 kcal; smoothed, it's a
        // fraction of that.
        #expect(abs(calm.calories - noisy.calories) <= 10)
    }
}
