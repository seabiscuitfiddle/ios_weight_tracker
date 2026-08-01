import SwiftUI
import TallyCore
import TallyStore
import WidgetKit

@main
struct TallyWidgetBundle: WidgetBundle {
    var body: some Widget {
        NetCaloriesWidget()
        TallySummaryWidget()
        NetRingWidget()
    }
}

/// A day's numbers, read fresh for each timeline entry.
struct TallySnapshot: TimelineEntry {
    var date: Date
    var totals: DayTotals
    var goalCalories: Int?
    var proteinTarget: Double
    var fiberTarget: Double

    var remaining: Int? { goalCalories.map { totals.remaining(against: $0) } }
    var progress: Double { goalCalories.map { totals.progress(against: $0) } ?? 0 }

    /// Shown in the widget gallery and while the real data loads.
    static let placeholder = TallySnapshot(
        date: Date(),
        totals: DayTotals(
            foodCalories: 1540, exerciseCalories: 320,
            proteinGrams: 96, fiberGrams: 22, entryCount: 5
        ),
        goalCalories: 2100,
        proteinTarget: 150,
        fiberTarget: 38
    )
}

/// Reads the shared database.
///
/// **Read-only**, deliberately: a widget timeline has no business migrating a schema or writing
/// a row, and opening read-only makes that structural rather than a rule to remember.
struct TallyTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> TallySnapshot { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (TallySnapshot) -> Void) {
        completion(context.isPreview ? .placeholder : load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TallySnapshot>) -> Void) {
        let snapshot = load()

        // Refresh at the next midnight, when the numbers reset to a new day. Everything else
        // that changes the totals is a write from the app, which reloads timelines explicitly —
        // so there's no reason to burn the system's refresh budget on polling.
        let nextMidnight = Calendar.current.nextDate(
            after: Date(),
            matching: DateComponents(hour: 0, minute: 0),
            matchingPolicy: .nextTime
        ) ?? Date().addingTimeInterval(3600)

        completion(Timeline(entries: [snapshot], policy: .after(nextMidnight)))
    }

    private func load() -> TallySnapshot {
        // Any failure here shows the empty state rather than stale or invented numbers: a widget
        // that quietly displays yesterday's total is worse than one that shows a dash.
        guard let url = TallyDatabase.url(forAppGroup: TallyDatabase.appGroupIdentifier()),
              let reader = try? TallyDatabase.openReadOnly(at: url)
        else {
            return TallySnapshot(
                date: Date(), totals: .empty, goalCalories: nil,
                proteinTarget: 150, fiberTarget: 38
            )
        }

        let stores = TallyDatabase.readOnlyStores(reader: reader)
        let today = Day.today()

        let totals = (try? stores.entries.totals(on: today)) ?? .empty
        let settings = (try? stores.settings.goalSettings()) ?? .default

        // The same inputs the app builds, so the widget's number cannot drift from the one on
        // the Today screen. A failed read leaves the goal nil, which the views render as a dash.
        let goal = (try? GoalCalculator.Inputs(stores: stores, today: today))
            .flatMap(GoalCalculator.dailyGoal)

        return TallySnapshot(
            date: Date(),
            totals: totals,
            goalCalories: goal?.calories,
            proteinTarget: settings.proteinTargetGrams,
            fiberTarget: settings.fiberTargetGrams
        )
    }
}
