import Foundation
import Testing
import TallyCore
@testable import Tally

/// The reported bug: the big number under "current" was the smoothed trend, so it disagreed with
/// the reading the user had just logged and looked like an average of nothing in particular.
/// "Current" now means the latest weigh-in; the trend keeps its own, named line.
@MainActor
@Suite("Progress current weight")
struct ProgressModelTests {
    /// A run of readings ending in a jump, which is exactly the case where a smoothed number and
    /// the scale disagree most visibly.
    private func stores(pounds: [Double]) -> StoreBundle {
        let today = Day.today()
        let samples = pounds.enumerated().map { offset, weight in
            WeightSample(day: today.adding(days: offset - (pounds.count - 1)), pounds: weight)
        }
        return StoreBundle.inMemory(weights: samples)
    }

    @Test("current is the latest reading, not the smoothed trend")
    func currentIsLatestReading() {
        let model = ProgressModel(stores: stores(pounds: [170, 170, 170, 180]))
        model.load()

        #expect(model.currentPounds == 180)
        // Still smoothing underneath — the headline just isn't it any more.
        #expect((model.currentTrendPounds ?? 0) < 175)
    }

    @Test("logging a weight makes it the current weight straight away")
    func loggingUpdatesCurrent() {
        let model = ProgressModel(stores: stores(pounds: [170, 170, 170]))
        model.load()

        model.draftText = "182"
        model.logDraft()

        #expect(model.currentPounds == 182)
    }

    @Test("the trend is shown beside the reading, labelled as the trend")
    func trendIsCaptioned() {
        let model = ProgressModel(stores: stores(pounds: [170, 170, 170, 180]))
        model.load()

        let trend = TallyFormat.weight(pounds: model.currentTrendPounds ?? 0, unit: model.unit)
        #expect(model.trendCaption == "trend \(trend) \(model.unit.shortName)")
    }

    /// A first reading seeds the trend with itself, and a steady weight keeps the two rounding to
    /// the same number. Repeating the headline under it would read as a second, different value.
    @Test("no trend caption when it would only repeat the headline")
    func noCaptionWhenTrendMatches() {
        let single = ProgressModel(stores: stores(pounds: [170]))
        single.load()
        #expect(single.trendCaption == nil)

        let steady = ProgressModel(stores: stores(pounds: [170, 170, 170]))
        steady.load()
        #expect(steady.trendCaption == nil)
    }

    @Test("no weigh-ins means no current weight and no caption")
    func emptyHistory() {
        let model = ProgressModel(stores: .inMemory())
        model.load()

        #expect(model.currentPounds == nil)
        #expect(model.trendCaption == nil)
    }
}
