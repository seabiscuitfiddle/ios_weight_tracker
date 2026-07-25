import Foundation
import Testing
@testable import TallyCore

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let start = Day(year: 2026, month: 6, day: 1)

/// Daily samples starting at `start`, one per day.
private func dailySamples(_ pounds: [Double]) -> [WeightSample] {
    pounds.enumerated().map { offset, value in
        WeightSample(day: start.adding(days: offset, calendar: utc), pounds: value)
    }
}

@Suite("Weight trend")
struct WeightTrendTests {
    @Test("an empty series has no trend")
    func empty() {
        let trend = WeightTrend(samples: [])
        #expect(trend.isEmpty)
        #expect(trend.currentTrendPounds == nil)
        #expect(trend.spannedDays(calendar: utc) == 0)
    }

    /// Seeding on the first reading rather than at zero. Starting from zero would take dozens of
    /// weigh-ins to climb to body weight, showing a badly wrong line for the user's first month.
    @Test("seeds on the first reading")
    func seedsOnFirstReading() {
        let trend = WeightTrend(samples: dailySamples([170]))
        #expect(trend.points.count == 1)
        #expect(trend.points[0].trendPounds == 170)
        #expect(trend.currentTrendPounds == 170)
    }

    /// The whole point of smoothing: a single wild reading barely moves the line. At α = 0.1 a
    /// 10 lb spike moves the trend by 1 lb, while a raw chart would show the full 10.
    @Test("absorbs a one-day spike almost entirely")
    func dampensSpikes() {
        let trend = WeightTrend(samples: dailySamples([170, 170, 170, 180]))

        #expect(trend.latestPounds == 180)
        // 0.1 × 180 + 0.9 × 170 = 171.
        #expect(abs((trend.currentTrendPounds ?? 0) - 171) < 0.001)
    }

    @Test("follows a sustained change, lagging behind it")
    func lagsSustainedChange() {
        // Twenty days holding 160 after a long spell at 170.
        let trend = WeightTrend(samples: dailySamples(
            Array(repeating: 170, count: 10) + Array(repeating: 160, count: 20)
        ))

        let current = trend.currentTrendPounds ?? 0
        // Converging on 160 but not yet arrived — that lag is the tradeoff for the smoothing.
        #expect(current > 160)
        #expect(current < 163)
    }

    @Test("is unaffected by the order samples are supplied in")
    func orderIndependent() {
        let samples = dailySamples([170, 169, 171, 168, 167])
        let inOrder = WeightTrend(samples: samples)
        let shuffled = WeightTrend(samples: samples.reversed())

        #expect(inOrder.points == shuffled.points)
    }

    @Test("a larger alpha tracks raw readings more closely")
    func alphaControlsResponsiveness() {
        let samples = dailySamples([170, 170, 170, 180])
        let slow = WeightTrend(samples: samples, alpha: 0.1)
        let fast = WeightTrend(samples: samples, alpha: 0.5)

        #expect((fast.currentTrendPounds ?? 0) > (slow.currentTrendPounds ?? 0))
        // α = 1 degenerates to the raw series.
        #expect(WeightTrend(samples: samples, alpha: 1).currentTrendPounds == 180)
    }

    @Test("reports the span in days, not the number of readings")
    func spanIsCalendarBased() {
        // Three readings a week apart span 14 days.
        let sparse = [
            WeightSample(day: start, pounds: 170),
            WeightSample(day: start.adding(days: 7, calendar: utc), pounds: 169),
            WeightSample(day: start.adding(days: 14, calendar: utc), pounds: 168),
        ]
        let trend = WeightTrend(samples: sparse)

        #expect(trend.points.count == 3)
        #expect(trend.spannedDays(calendar: utc) == 14)
    }

    @Test("measures trend change across a window")
    func trendChangeOverWindow() {
        let trend = WeightTrend(samples: dailySamples(
            (0..<30).map { 175 - Double($0) * 0.2 }  // a steady 0.2 lb/day decline
        ))

        let change = trend.trendChange(overLast: 14, calendar: utc)
        #expect(change != nil)
        // Declining, so negative.
        #expect((change ?? 0) < 0)
        // Roughly 14 × 0.2 = 2.8 lb, allowing for smoothing lag.
        #expect(abs((change ?? 0) + 2.8) < 0.5)
    }

    /// Without a reading at or before the window start, any "change" would just be measuring
    /// the seeding artefact of the first point, so it reports nil instead.
    @Test("declines to report change without a reading at the window start")
    func needsAnchorReading() {
        let trend = WeightTrend(samples: dailySamples([170, 169, 168]))
        #expect(trend.trendChange(overLast: 30, calendar: utc) == nil)
        #expect(trend.trendChange(overLast: 2, calendar: utc) != nil)
    }

    /// On a steady decline the smoothing lag is a constant offset, so it cancels when measuring
    /// a *change* between two points that are both past the seeding transient. That is what
    /// makes the trend usable for the observed-expenditure estimate: it recovers the true rate,
    /// it just can't tell you today's exact weight.
    @Test("recovers the true weekly rate once past the seeding transient")
    func weeklyRate() {
        let trend = WeightTrend(samples: dailySamples(
            (0..<90).map { 190 - Double($0) * (1.0 / 7.0) }  // exactly 1 lb/week
        ))

        let rate = trend.poundsPerWeek(overLast: 21, calendar: utc)
        #expect(rate != nil)
        #expect(abs((rate ?? 0) + 1.0) < 0.02)
    }

    /// The flip side of the above, pinned so it isn't mistaken for a bug later: a window whose
    /// start sits in the first couple of weeks of data straddles the seeding transient, where
    /// the trend is still climbing toward the real line, so the measured change understates the
    /// truth. It's the reason the observed estimate requires two weeks of history before it is
    /// trusted at all.
    @Test("understates the rate while the window overlaps the seeding transient")
    func seedingTransientUnderstatesRate() {
        let short = WeightTrend(samples: dailySamples(
            (0..<30).map { 175 - Double($0) * (1.0 / 7.0) }
        ))

        let measured = short.poundsPerWeek(overLast: 21, calendar: utc) ?? 0
        // Directionally right, but short of the true 1 lb/week.
        #expect(measured < 0)
        #expect(abs(measured) < 1.0)
        #expect(abs(measured) > 0.75)
    }

    @Test("finds the trend value at or before a given day")
    func lookupOnOrBefore() {
        let trend = WeightTrend(samples: [
            WeightSample(day: start, pounds: 170),
            WeightSample(day: start.adding(days: 10, calendar: utc), pounds: 168),
        ])

        #expect(trend.trendPounds(onOrBefore: start) == 170)
        // Falls back to the earlier reading for a day with none of its own.
        #expect(trend.trendPounds(onOrBefore: start.adding(days: 5, calendar: utc)) == 170)
        #expect(trend.trendPounds(onOrBefore: start.adding(days: 20, calendar: utc)) != 170)
        // Nothing recorded that early.
        #expect(trend.trendPounds(onOrBefore: start.adding(days: -1, calendar: utc)) == nil)
    }

    @Test("the trend line is smoother than the raw series it came from")
    func trendIsSmootherThanRaw() {
        // Alternating readings: heavy day-to-day noise around a flat mean.
        let noisy = dailySamples((0..<40).map { $0.isMultiple(of: 2) ? 172.0 : 168.0 })
        let trend = WeightTrend(samples: noisy)

        func meanAbsoluteChange(_ values: [Double]) -> Double {
            guard values.count > 1 else { return 0 }
            let deltas = zip(values.dropFirst(), values).map { abs($0 - $1) }
            return deltas.reduce(0, +) / Double(deltas.count)
        }

        let rawVolatility = meanAbsoluteChange(trend.points.map(\.pounds))
        let trendVolatility = meanAbsoluteChange(trend.points.map(\.trendPounds))

        #expect(rawVolatility > 3.5)      // raw swings the full 4 lb every day
        #expect(trendVolatility < 1.0)    // the trend barely moves
    }
}
