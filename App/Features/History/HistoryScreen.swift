import Observation
import SwiftUI
import TallyCore

/// A day at a time: weekday selector, the day's net heading it, then ruled entry rows.
/// Design screen 1h.
struct HistoryScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: HistoryModel?
    /// The entry being corrected, if any. The list is where mistakes are noticed, so it is also
    /// where they get fixed.
    @State private var editing: Entry?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(kicker: "history", title: "Log")

            if let model {
                weekSelector(model)
                dayHeader(model)
                entries(model)
            } else {
                Spacer()
            }
        }
        .background(Color.tallyBackground)
        .task {
            if model == nil {
                model = HistoryModel(stores: environment.stores)
            }
            model?.load()
            await model?.observeChanges()
        }
        .sheet(item: $editing) { entry in
            EntryEditorSheet(entry: entry)
        }
    }

    @ViewBuilder
    private func weekSelector(_ model: HistoryModel) -> some View {
        HStack(spacing: 0) {
            ForEach(model.visibleDays, id: \.self) { day in
                let isSelected = day == model.selectedDay
                Button {
                    model.select(day)
                } label: {
                    Text(TallyFormat.weekdayAbbreviation(day))
                        .font(.tallyScaled(12, weight: isSelected ? .bold : .semibold,
                                           relativeTo: .caption))
                        .foregroundStyle(isSelected ? Color.tallyText : Color.tallySecondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .overlay(alignment: .bottom) {
                            // A heavy accent underline marks the selection — the design's
                            // alternative to a filled pill, keeping the row flat.
                            Rectangle()
                                .fill(isSelected ? Color.tallyAccent : Color.clear)
                                .frame(height: 3)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(TallyFormat.dayKicker(day))
                .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            }
        }
        .overlay(alignment: .bottom) { TallyRule() }
    }

    @ViewBuilder
    private func dayHeader(_ model: HistoryModel) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Kicker(model.selectedDay == model.today ? "net today" : "net")
                HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
                    Text(TallyFormat.calories(model.totals.netCalories))
                        .font(.tallyDisplay(32))
                        .tracking(Typography.Display.tracking * 32)
                        .foregroundStyle(Color.tallyText)
                    if let goal = model.goal {
                        Text("/ \(TallyFormat.calories(goal))")
                            .font(.tallyScaled(13, weight: .semibold))
                            .foregroundStyle(Color.tallySecondaryText)
                    }
                }
            }

            Spacer(minLength: Metrics.space2)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(TallyFormat.grams(model.totals.proteinGrams))g protein")
                Text("\(TallyFormat.grams(model.totals.fiberGrams))g fiber")
            }
            .font(.tallyScaled(12, weight: .semibold, relativeTo: .caption))
            .foregroundStyle(Color.tallyText)
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.space4)
        .frame(maxWidth: .infinity)
        .background(Color.tallySurface)
        .overlay(alignment: .bottom) { TallyRule(weight: Metrics.rule) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func entries(_ model: HistoryModel) -> some View {
        if model.entries.isEmpty {
            EmptyStateView(message: "Nothing logged on this day.")
            Spacer()
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Tap to edit, rather than swipe to delete. `.swipeActions` was here and did
                    // nothing at all: it is a `List` modifier, and these rows are a LazyVStack —
                    // so the only way to remove an entry silently didn't exist.
                    ForEach(model.entries) { entry in
                        EditableEntryRow(entry: entry) { editing = entry }
                            .padding(.horizontal, Metrics.gutter)
                        TallyRule()
                    }
                }
            }
        }
    }
}

@Observable
@MainActor
final class HistoryModel {
    private let stores: StoreBundle
    private let calendar: Calendar

    let today: Day
    private(set) var selectedDay: Day
    private(set) var entries: [Entry] = []
    private(set) var totals: DayTotals = .empty
    private(set) var goal: Int?

    /// The trailing week, oldest first — the design shows five weekday columns, and a week
    /// covers "what did I do on Tuesday?" without a date picker.
    private(set) var visibleDays: [Day] = []

    init(stores: StoreBundle, calendar: Calendar = .current) {
        self.stores = stores
        self.calendar = calendar
        let today = Day.today(calendar: calendar)
        self.today = today
        self.selectedDay = today
        self.visibleDays = Day.trailing(7, endingOn: today, calendar: calendar)
    }

    func select(_ day: Day) {
        selectedDay = day
        load()
    }

    func load() {
        do {
            entries = try stores.entries.entries(on: selectedDay)
            totals = DayTotals.summing(entries)

            // The goal shown is today's, which is an approximation for past days — the goal that
            // applied back then isn't stored. Better than showing nothing, and the net is the
            // number that actually matters on a historical day.
            goal = GoalCalculator.dailyGoal(
                try GoalCalculator.Inputs(stores: stores, today: today, calendar: calendar)
            )?.calories
        } catch {
            entries = []
            totals = .empty
        }
    }

    func observeChanges() async {
        for await _ in stores.changes.stream(for: [.entries, .settings]) {
            load()
        }
    }

    func delete(_ entry: Entry) {
        try? stores.entries.delete(id: entry.id)
        load()
    }
}
