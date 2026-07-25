import Observation
import SwiftUI
import TallyCore

/// Weight and goal. Design screen 1g.
struct ProgressScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: ProgressModel?

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
            } else {
                Spacer()
            }
        }
        .background(Color.tallyBackground)
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
                if let pounds = model.currentTrendPounds {
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

    @ViewBuilder
    private func weightEntry(_ model: ProgressModel) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Kicker("log today's weight")

            HStack(spacing: 0) {
                stepperButton("−") { model.adjustDraft(by: -0.2) }

                HStack(alignment: .firstTextBaseline, spacing: Metrics.space1) {
                    Text(TallyFormat.weight(pounds: model.draftPounds, unit: model.unit))
                        .font(.tallyDisplay(24))
                        .tracking(Typography.Display.tracking * 24)
                    Text(model.unit.shortName)
                        .font(.tallyScaled(13, weight: .semibold))
                        .foregroundStyle(Color.tallySecondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .accessibilityLabel("Weight to log")
                .accessibilityValue(TallyFormat.weightWithUnit(
                    pounds: model.draftPounds, unit: model.unit
                ))

                stepperButton("+") { model.adjustDraft(by: 0.2) }

                Button { model.logDraft() } label: {
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
                    Spacer()
                    if let target = model.targetPounds, let current = model.currentTrendPounds {
                        Text("\(TallyFormat.weight(pounds: current, unit: model.unit)) → \(TallyFormat.weightWithUnit(pounds: target, unit: model.unit))")
                            .font(.tallyScaled(13, weight: .semibold))
                            .foregroundStyle(Color.tallyText)
                    }
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
