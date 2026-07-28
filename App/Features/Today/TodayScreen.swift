import SwiftUI
import TallyCore

/// The dashboard: ring hero, the food/exercise/net arithmetic spelled out, macro bars, and
/// today's entries. Design screen 1d.
struct TodayScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: TodayModel?
    /// The entry being corrected, if any.
    @State private var editing: Entry?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(kicker: TallyFormat.dayKicker(model?.day ?? Day.today()), title: "Today") {
                Button {
                    environment.isShowingSettings = true
                } label: {
                    Image(systemName: "person")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.tallyText)
                        .frame(width: 38, height: 38)
                        .tallyHairlineBorder()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }

            if let model {
                content(model)
            } else {
                Spacer()
            }
        }
        .background(Color.tallyBackground)
        .task {
            // Built here rather than in an initialiser so it can use the injected environment.
            if model == nil {
                model = TodayModel(stores: environment.stores)
            }
            model?.load()
            await model?.observeChanges()
        }
        .sheet(isPresented: Binding(
            get: { environment.isShowingSettings },
            set: { environment.isShowingSettings = $0 }
        )) {
            SettingsScreen()
        }
        .sheet(item: $editing) { entry in
            EntryEditorSheet(entry: entry)
        }
    }

    @ViewBuilder
    private func content(_ model: TodayModel) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if model.needsGoalSetup {
                    GoalSetupPrompt { environment.isShowingSettings = true }
                } else {
                    hero(model)
                    macros(model)
                }

                TallyRule()
                    .padding(.vertical, Metrics.space4)

                logSection(model)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.space6)
            .padding(.bottom, Metrics.space8)
        }
    }

    // MARK: Hero

    @ViewBuilder
    private func hero(_ model: TodayModel) -> some View {
        HStack(alignment: .center, spacing: Metrics.space6 - 4) {
            ZStack {
                NetRing(progress: model.progress)
                VStack(spacing: 3) {
                    // "Remaining" leads, because that's the number that answers "can I eat
                    // this?" — the question someone opens the app to settle.
                    Text(TallyFormat.calories(model.remaining ?? 0))
                        .font(.tallyDisplay(44))
                        .tracking(Typography.Display.tracking * 44)
                        .foregroundStyle(Color.tallyText)
                    Kicker("cal left")
                }
            }
            .frame(width: 150, height: 150)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Calories remaining")
            .accessibilityValue("\(model.remaining ?? 0) of \(model.goal?.calories ?? 0)")

            VStack(spacing: Metrics.space2 + 2) {
                breakdownRow("goal", value: TallyFormat.calories(model.goal?.calories ?? 0))
                breakdownRow("food", value: "+\(TallyFormat.calories(model.totals.foodCalories))")
                breakdownRow(
                    "exercise",
                    value: TallyFormat.signedCalories(model.totals.exerciseCalories, kind: .exercise),
                    color: .tallyAccent
                )
                breakdownRow(
                    "net",
                    value: TallyFormat.calories(model.totals.netCalories),
                    showRule: false
                )
            }
        }
    }

    /// One line of the food/exercise/net arithmetic. Spelling the sum out is the design's way of
    /// making the ring's single number auditable rather than magic.
    @ViewBuilder
    private func breakdownRow(
        _ label: String,
        value: String,
        color: Color = .tallyText,
        showRule: Bool = true
    ) -> some View {
        VStack(spacing: Metrics.space2 - 1) {
            HStack(alignment: .firstTextBaseline) {
                Kicker(label)
                Spacer(minLength: Metrics.space2)
                Text(value)
                    .font(.tallyFixed(17, weight: .heavy))
                    .foregroundStyle(color)
            }
            if showRule { TallyRule() }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Macros

    @ViewBuilder
    private func macros(_ model: TodayModel) -> some View {
        HStack(alignment: .top, spacing: Metrics.space6 - 2) {
            MacroBar(
                label: "protein",
                value: model.totals.proteinGrams,
                target: model.goalSettings.proteinTargetGrams
            )
            MacroBar(
                label: "fiber",
                value: model.totals.fiberGrams,
                target: model.goalSettings.fiberTargetGrams
            )
        }
        .padding(.top, Metrics.space6 - 2)
    }

    // MARK: Log

    @ViewBuilder
    private func logSection(_ model: TodayModel) -> some View {
        HStack {
            Kicker("today's log")
            Spacer()
            if !model.entries.isEmpty {
                Button("See all") { environment.selectedTab = .history }
                    .font(.tallyScaled(12, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(Color.tallyAccent)
            }
        }
        .padding(.bottom, Metrics.space3)

        if model.entries.isEmpty {
            EmptyStateView(
                message: "Nothing logged yet today.",
                actionTitle: "Log something",
                action: { environment.selectedTab = .log }
            )
        } else {
            // As on History: `.swipeActions` was here and was inert — it only does anything
            // inside a `List`, and this is a `VStack` in a `ScrollView`.
            ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                EditableEntryRow(entry: entry) { editing = entry }
                if index < model.entries.count - 1 { TallyRule() }
            }
        }
    }
}

/// Shown in place of the ring when there isn't enough information to compute a goal.
///
/// The alternative — inventing a plausible 2,000 kcal target — would present a guess as a
/// prescription, so the screen asks instead.
struct GoalSetupPrompt: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space3) {
            Kicker("set up your goal", color: .tallyAccent)
            Text("Add your height, age, and a goal weight and Tally will work out your daily calories.")
                .font(.tallyBody)
                .foregroundStyle(Color.tallyText)
                .fixedSize(horizontal: false, vertical: true)
            TallyPrimaryButton(title: "Set up", action: action)
        }
        .padding(Metrics.space4)
        .tallyHairlineBorder()
    }
}

#Preview {
    let day = Day.today()
    return RootView()
        .environment(AppEnvironment(previewStores: .inMemory(
            entries: [
                Entry(kind: .exercise, label: "Zone 2 run · 38 min", calories: 320,
                      exerciseKind: .cardio, durationMinutes: 38, day: day),
                Entry(kind: .food, label: "Greek yogurt & berries", calories: 280,
                      proteinGrams: 24, fiberGrams: 4, day: day),
                Entry(kind: .food, label: "Chicken bowl, avocado", calories: 640,
                      proteinGrams: 48, fiberGrams: 9, day: day),
            ],
            weights: [WeightSample(day: day, pounds: 168.4)],
            profile: UserProfile(
                birthDate: Calendar.current.date(byAdding: .year, value: -35, to: Date()),
                heightCentimeters: 178,
                biologicalSex: .male
            ),
            goal: GoalSettings(targetPounds: 155)
        )))
}
