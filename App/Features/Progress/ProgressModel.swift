import Foundation
import Observation
import TallyCore

/// The two numbers on the Progress screen that are typed rather than derived.
///
/// Top-level rather than nested in ``ProgressModel`` so it carries no actor isolation: the
/// screen's `@FocusState` needs a plain `Hashable`, and a type nested in a `@MainActor` model
/// isn't one.
enum WeightField: Hashable {
    /// Today's weight, before it is logged.
    case draft
    /// The goal weight, which is written straight through to settings.
    case target
}

@Observable
@MainActor
final class ProgressModel {
    private let stores: StoreBundle
    private let calendar: Calendar

    /// The chart window, and the period the headline change is measured over.
    static let windowDays = 30

    private(set) var unit: MassUnit = .pounds
    private(set) var trend = WeightTrend(samples: [])
    private(set) var goal: DailyGoal?
    private(set) var targetPounds: Double?

    /// The weight about to be logged, in canonical pounds.
    private(set) var draftPounds: Double = 170

    /// That same weight as it sits in the field: in the **displayed** unit, and exactly as typed
    /// until it is committed.
    ///
    /// A buffer rather than a formatted view of ``draftPounds``, because reformatting on every
    /// keystroke fights the person typing — deleting the "0" of "170.0" would immediately put it
    /// back, and "1" on the way to "182" would be read as a one-pound reading.
    var draftText = ""

    /// The goal weight, held the same way. Empty means no target, which is a real setting rather
    /// than a missing one — the app then shows maintenance calories instead of a deficit.
    var targetText = ""

    /// Which field, if either, currently has the keyboard.
    private var editingField: WeightField?

    init(stores: StoreBundle, calendar: Calendar = .current) {
        self.stores = stores
        self.calendar = calendar
    }

    /// The headline weight: the most recent reading, exactly as it was entered.
    ///
    /// The raw weigh-in rather than the smoothed trend. A number labelled "current" that sits a
    /// pound off the scale you just stood on reads as the app being wrong, whatever the smoothing
    /// buys elsewhere — and the person who typed 168.2 has no way to tell 168.4 apart from a bug.
    /// The trend still drives the goal and still draws the chart; it is just named where it is
    /// shown rather than borrowing this label.
    var currentPounds: Double? { trend.latestPounds }

    var currentTrendPounds: Double? { trend.currentTrendPounds }

    /// The smoothed weight, spelled out under the headline so the number the goal is computed
    /// from is on screen and named rather than appearing unexplained beside the target.
    ///
    /// Nil when it would only repeat the headline: the first reading seeds the trend with itself,
    /// and a steady weight keeps the two within a rounding step of each other. Compared at the
    /// precision actually shown, since two values that render identically are the same number as
    /// far as the screen is concerned.
    var trendCaption: String? {
        guard let current = currentPounds, let smoothed = currentTrendPounds else { return nil }
        let text = TallyFormat.weight(pounds: smoothed, unit: unit)
        guard text != TallyFormat.weight(pounds: current, unit: unit) else { return nil }
        return "trend \(text) \(unit.shortName)"
    }

    var changeOverWindow: Double? {
        trend.trendChange(overLast: Self.windowDays, calendar: calendar)
    }

    var windowWeeks: Int { Self.windowDays / 7 }

    /// Trend values inside the window, oldest first, for the chart.
    var chartPoints: [Double] {
        let today = Day.today(calendar: calendar)
        let start = today.adding(days: -Self.windowDays, calendar: calendar)
        return trend.points.filter { $0.day >= start }.map(\.trendPounds)
    }

    /// "173 → 168.4", the caption the design puts above the chart.
    var chartRangeLabel: String? {
        let points = chartPoints
        guard let first = points.first, let last = points.last, points.count >= 2 else {
            return nil
        }
        return "\(TallyFormat.weight(pounds: first, unit: unit)) → \(TallyFormat.weight(pounds: last, unit: unit))"
    }

    func load() {
        do {
            let profile = try stores.settings.profile()
            let settings = try stores.settings.goalSettings()
            unit = profile.massUnit
            targetPounds = settings.targetPounds

            let samples = try stores.weights.allSamples()
            trend = WeightTrend(samples: samples)

            let today = Day.today(calendar: calendar)
            // Seed the field from today's reading if there is one, otherwise the most recent —
            // someone correcting today's entry shouldn't have to retype it from a default.
            draftPounds = try stores.weights.sample(on: today)?.pounds
                ?? stores.weights.latestSample(onOrBefore: today)?.pounds
                ?? 170

            goal = GoalCalculator.dailyGoal(
                try GoalCalculator.Inputs(stores: stores, today: today, calendar: calendar)
            )
        } catch {
            trend = WeightTrend(samples: [])
            goal = nil
        }

        refillFields()
    }

    func observeChanges() async {
        for await _ in stores.changes.stream(for: [.weights, .entries, .settings]) {
            load()
        }
    }

    // MARK: Editing

    /// Tracks which field holds the keyboard, committing whichever one has just given it up.
    ///
    /// Driven by the screen's `@FocusState` rather than by the fields themselves, so a tap
    /// straight from one to the other still commits the one being left.
    func focusChanged(from previous: WeightField?, to current: WeightField?) {
        editingField = current
        switch previous {
        case .draft: commitDraft()
        case .target: commitTarget()
        case nil: break
        }
    }

    /// Steps the draft by `delta` **in the displayed unit**, so a tap moves the number the user
    /// sees by a consistent amount rather than by a converted fraction.
    ///
    /// Steps from what is in the field, not from the last committed value: after typing 182, a
    /// tap on + has to produce 182.2 rather than reverting to the seeded weight.
    func adjustDraft(by delta: Double) {
        adoptDraftText()
        let displayed = unit.value(fromPounds: draftPounds) + delta
        draftPounds = max(0, unit.pounds(from: displayed))
        draftText = TallyFormat.editableWeight(pounds: draftPounds, unit: unit)
    }

    /// Reads the typed weight back into ``draftPounds`` and normalises what the field shows.
    ///
    /// A field that isn't a weight — empty, or "18." abandoned mid-edit — leaves the previous
    /// value standing rather than being taken as zero. There is no error to raise: re-rendering
    /// the field from the value actually held says what happened without a banner.
    func commitDraft() {
        adoptDraftText()
        draftText = TallyFormat.editableWeight(pounds: draftPounds, unit: unit)
    }

    /// Writes the typed goal weight through to settings.
    ///
    /// Saved on leaving the field rather than behind a button: the target is one number, and the
    /// projection beside it is the confirmation that it landed. Emptying the field clears the
    /// target, which is what an empty goal weight has always meant — unlike the weight being
    /// logged, "no goal weight" is a state the user is entitled to ask for.
    func commitTarget() {
        let typed = TallyFormat.number(from: targetText).map { unit.pounds(from: $0) }

        // Compared at the precision the field shows, not in canonical pounds: a kilogram round
        // trip lands a fraction away from where it started, and treating that as an edit would
        // rewrite settings — and nudge the stored weight — every time the field was merely
        // tapped into and left.
        guard fieldText(forPounds: typed) != fieldText(forPounds: targetPounds) else {
            targetText = fieldText(forPounds: targetPounds)
            return
        }

        do {
            var settings = try stores.settings.goalSettings()
            settings.targetPounds = typed
            try stores.settings.save(settings)
        } catch {
            // Nothing to say to the user that the reload below won't show: the field comes back
            // holding whatever is really stored.
        }
        load()
    }

    func logDraft() {
        // Committed here as well as on focus change, because tapping Log is the one way to
        // leave the field that doesn't have to involve dismissing the keyboard first.
        adoptDraftText()

        let today = Day.today(calendar: calendar)
        try? stores.weights.save(WeightSample(
            day: today,
            pounds: draftPounds,
            measuredAt: Date(),
            source: .manual,
            calendar: calendar
        ))
        load()
    }

    // MARK: Field text

    /// Folds whatever has been typed into the weight field back into ``draftPounds``. Text that
    /// isn't a weight leaves the last good value alone — see ``commitDraft()``.
    private func adoptDraftText() {
        guard let typed = TallyFormat.number(from: draftText) else { return }
        draftPounds = unit.pounds(from: typed)
    }

    /// Re-seeds both fields from what is stored, skipping whichever one has the keyboard: a
    /// background write — a Health import, a log from the widget — must not replace a
    /// half-typed number under the user's fingers.
    private func refillFields() {
        if editingField != .draft {
            draftText = TallyFormat.editableWeight(pounds: draftPounds, unit: unit)
        }
        if editingField != .target {
            targetText = fieldText(forPounds: targetPounds)
        }
    }

    /// An optional weight as its field holds it, where no weight is an empty field.
    private func fieldText(forPounds pounds: Double?) -> String {
        pounds.map { TallyFormat.editableWeight(pounds: $0, unit: unit) } ?? ""
    }
}
