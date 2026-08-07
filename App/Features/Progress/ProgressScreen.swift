import Observation
import SwiftUI
import TallyCore

/// Weight and goal. Design screen 1g.
struct ProgressScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: ProgressModel?

    /// One focus state for both weight fields, so the model is told which one it is losing as
    /// well as which one it is gaining.
    @FocusState private var focusedField: WeightField?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(kicker: "progress", title: "Weight & Goal") {
                Button {
                    environment.isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Color.tallyText)
                        .frame(width: 38, height: 38)
                        .tallyHairlineBorder()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }

            if let model {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.space4 - 2) {
                        currentWeight(model)
                        weightEntry(model)
                        trendChart(model)
                        TallyRule()
                        goalPanel(model)
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.space4 + 4)
                }
                // A decimal keypad has no return key, so scrolling the screen away is one of the
                // two ways off it. The other is the Done button on the keyboard's own bar.
                .scrollDismissesKeyboard(.interactively)
            } else {
                Spacer()
            }
        }
        .background(Color.tallyBackground)
        .onChange(of: focusedField) { previous, current in
            model?.focusChanged(from: previous, to: current)
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .task {
            if model == nil {
                model = ProgressModel(stores: environment.stores)
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
    }

    // MARK: Current

    @ViewBuilder
    private func currentWeight(_ model: ProgressModel) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Kicker("current")
                if let pounds = model.currentPounds {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.space1) {
                        Text(TallyFormat.weight(pounds: pounds, unit: model.unit))
                            .font(.tallyDisplay(46))
                            .tracking(Typography.Display.tracking * 46)
                            .foregroundStyle(Color.tallyText)
                        Text(model.unit.shortName)
                            .font(.tallyScaled(16, weight: .semibold))
                            .foregroundStyle(Color.tallyText)
                    }
                } else {
                    Text("—")
                        .font(.tallyDisplay(46))
                        .foregroundStyle(Color.tallySecondaryText)
                }

                // The smoothed number, named. It is what the goal and the chart are built from,
                // so it has to stay visible — but as the trend it is, under the reading it was
                // smoothed from, rather than as the headline it used to be.
                if let caption = model.trendCaption {
                    Text(caption)
                        .font(.tallyScaled(12, weight: .semibold, relativeTo: .caption))
                        .foregroundStyle(Color.tallySecondaryText)
                }
            }

            Spacer(minLength: Metrics.space2)

            if let change = model.changeOverWindow {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(TallyFormat.weightChange(pounds: change, unit: model.unit))
                        .foregroundStyle(change <= 0 ? Color.tallyAccent : Color.tallyText)
                    Text("in \(model.windowWeeks) weeks")
                        .foregroundStyle(Color.tallySecondaryText)
                }
                .font(.tallyScaled(12, weight: .semibold, relativeTo: .caption))
                .padding(.bottom, 3)
            }
        }
    }

    // MARK: Entry

    /// The number itself is a field, not a label.
    ///
    /// The steppers stay — a tenth either way after standing on the scale is exactly what they're
    /// for — but they cannot be the only way in. Weight moves in jumps the arrows can't reach: a
    /// first reading, a scale you haven't stood on in a month, a unit switch. Two hundred taps to
    /// enter a number you already know is not an interaction, and the arrows now step from
    /// whatever has been typed rather than from the value they were seeded with.
    @ViewBuilder
    private func weightEntry(_ model: ProgressModel) -> some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: 7) {
            Kicker("log today's weight")

            HStack(spacing: 0) {
                stepperButton("−") { model.adjustDraft(by: -0.2) }

                // Both halves take equal space, which centres the number-and-unit pair the way a
                // single centred label did — while making the whole middle of the row the field's
                // hit area rather than just the glyphs.
                HStack(alignment: .firstTextBaseline, spacing: Metrics.space1) {
                    TextField("", text: $model.draftText)
                        .font(.tallyDisplay(24))
                        .tracking(Typography.Display.tracking * 24)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .focused($focusedField, equals: .draft)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("Weight to log")
                        .accessibilityIdentifier("progress.weightField")
                    Text(model.unit.shortName)
                        .font(.tallyScaled(13, weight: .semibold))
                        .foregroundStyle(Color.tallySecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 11)

                stepperButton("+") { model.adjustDraft(by: 0.2) }

                Button {
                    // Gives the keyboard up first, so the row ends up showing the reading that
                    // was just logged rather than a field still open over it.
                    focusedField = nil
                    model.logDraft()
                } label: {
                    Text("Log")
                        .font(.tallyFixed(13, weight: .heavy))
                        .tracking(0.04 * 13)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.tallyInverted)
                        .padding(.horizontal, Metrics.space6 - 4)
                        .frame(maxHeight: .infinity)
                        .background(Color.tallyAccent)
                }
                .buttonStyle(.plain)
            }
            .fixedSize(horizontal: false, vertical: true)
            .tallyHairlineBorder()
        }
    }

    @ViewBuilder
    private func stepperButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(symbol)
                .font(.tallyFixed(22, weight: .heavy))
                .foregroundStyle(Color.tallyText)
                .frame(width: 50)
                .frame(maxHeight: .infinity)
                .background(Color.tallySurface)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "+" ? "Increase" : "Decrease")
    }

    // MARK: Chart

    @ViewBuilder
    private func trendChart(_ model: ProgressModel) -> some View {
        VStack(alignment: .leading, spacing: Metrics.space2 + 2) {
            HStack {
                Kicker("last 30 days")
                Spacer()
                if let range = model.chartRangeLabel {
                    Kicker(range)
                }
            }

            if model.chartPoints.count >= 2 {
                TrendLine(values: model.chartPoints)
                    .stroke(Color.tallyAccent, lineWidth: 3)
                    .frame(height: 66)
                    .accessibilityLabel("Weight trend over the last 30 days")
            } else {
                Text("Log your weight for a few days to see a trend.")
                    .font(.tallyScaled(12, weight: .regular, relativeTo: .caption))
                    .foregroundStyle(Color.tallySecondaryText)
                    .frame(height: 66, alignment: .center)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, Metrics.space3)
        .tallyHairlineBorder()
    }

    // MARK: Goal

    @ViewBuilder
    private func goalPanel(_ model: ProgressModel) -> some View {
        if let goal = model.goal {
            VStack(alignment: .leading, spacing: Metrics.space3) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Target")
                        .font(.tallyFixed(17, weight: .heavy))
                        .foregroundStyle(Color.tallyText)
                    Spacer(minLength: Metrics.space2)
                    // The trend rather than the latest reading, because the trend is what the
                    // projection below is computed from — showing the scale's number here would
                    // put a date under a starting point it wasn't measured against. It's the
                    // same number the caption at the top of the screen names.
                    if let current = model.currentTrendPounds {
                        Text("\(TallyFormat.weight(pounds: current, unit: model.unit)) →")
                            .font(.tallyScaled(13, weight: .semibold))
                            .foregroundStyle(Color.tallySecondaryText)
                    }
                    targetField(model)
                }

                // Inverted panel — the design's way of marking the one derived number that
                // everything else on the screen feeds into.
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Kicker("daily calorie goal", color: Color.tallyInverted.opacity(0.6))
                        Text(TallyFormat.calories(goal.calories))
                            .font(.tallyDisplay(30))
                            .tracking(Typography.Display.tracking * 30)
                            .foregroundStyle(Color.tallyInverted)
                    }

                    Spacer(minLength: Metrics.space2)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(TallyFormat.dailyAdjustment(goal.dailyAdjustment))
                        if let day = goal.projectedGoalDay {
                            Text("Goal by")
                            Text(TallyFormat.shortDate(day))
                                .foregroundStyle(Color.tallyInverted)
                                .fontWeight(.heavy)
                        }
                    }
                    .font(.tallyScaled(12, weight: .semibold, relativeTo: .caption))
                    .foregroundStyle(Color.tallyInverted.opacity(0.7))
                }
                .padding(.horizontal, Metrics.space4)
                .padding(.vertical, Metrics.space3 + 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.tallyText)
                .accessibilityElement(children: .combine)

                // Says plainly when the requested rate isn't achievable, rather than quietly
                // issuing a smaller deficit and letting the user wonder why progress is slow.
                if goal.wasClampedToFloor {
                    Text("""
                        That rate would put you below a safe minimum, so your goal is held at \
                        \(TallyFormat.calories(goal.floorCalories)) and you'll lose weight a \
                        little more slowly.
                        """)
                        .font(.tallyScaled(12, weight: .regular, relativeTo: .caption))
                        .foregroundStyle(Color.tallyAccent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(goal.basis.explanation)
                    .font(.tallyScaled(11, weight: .regular, relativeTo: .caption2))
                    .foregroundStyle(Color.tallySecondaryText)
            }
        } else {
            GoalSetupPrompt { environment.isShowingSettings = true }
        }
    }

    /// The goal weight, edited where it is read.
    ///
    /// Settings still holds it, and has to — it belongs beside the rate that works with it. But
    /// this is the screen that shows what the target implies, and changing "168 → 155" to
    /// "168 → 150" is a different act from opening Settings and hunting for a row: the projected
    /// date under it moves as soon as the field is left, which is the whole answer to "what would
    /// that mean?".
    ///
    /// Bordered rather than bare because an unadorned number in a panel of numbers gives no
    /// indication it can be touched.
    @ViewBuilder
    private func targetField(_ model: ProgressModel) -> some View {
        @Bindable var model = model

        HStack(alignment: .firstTextBaseline, spacing: Metrics.space1) {
            TextField(model.unit.shortName, text: $model.targetText)
                .font(.tallyScaled(13, weight: .semibold))
                .foregroundStyle(Color.tallyText)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .focused($focusedField, equals: .target)
                // Wide enough for "155.0" at the label size, and fixed so the panel's heading
                // doesn't reflow with every keystroke.
                .frame(width: 56)
                .accessibilityLabel("Goal weight")
                .accessibilityIdentifier("progress.goalWeightField")
            Text(model.unit.shortName)
                .font(.tallyScaled(13, weight: .semibold))
                .foregroundStyle(Color.tallySecondaryText)
        }
        .padding(.horizontal, Metrics.space2)
        .padding(.vertical, Metrics.space1 + 1)
        .background(Color.tallySurface)
        .tallyHairlineBorder()
    }
}

/// The 30-day trend polyline.
///
/// A hand-drawn `Shape` rather than Swift Charts: the design wants a bare accent-coloured line
/// with no axes, gridlines, or interaction, and stripping Charts back to that is more work than
/// drawing it — and would still fight the framework's defaults on every OS update.
struct TrendLine: Shape {
    /// Trend weights, oldest first.
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count >= 2 else { return path }

        let lowest = values.min() ?? 0
        let highest = values.max() ?? 1
        // A flat series would divide by zero; padding the span also stops a half-pound
        // fluctuation from being drawn as a dramatic cliff.
        let span = max(highest - lowest, 0.5)

        let stepX = rect.width / CGFloat(values.count - 1)

        for (index, value) in values.enumerated() {
            let x = rect.minX + CGFloat(index) * stepX
            let normalized = (value - lowest) / span
            // Flipped: higher weight sits higher on screen.
            let y = rect.maxY - CGFloat(normalized) * rect.height

            if index == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }

        return path
    }
}
