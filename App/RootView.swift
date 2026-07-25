import SwiftUI
import TallyCore

/// The four-tab shell every screen sits in.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            if let startupError = environment.startupError {
                StartupErrorBanner(detail: startupError)
            }

            // Content and tab bar are stacked by hand rather than using `TabView`, because the
            // design's tab bar has a square accent tile on the Log tab and heavy top rule that
            // `TabView`'s chrome does not allow.
            ZStack {
                switch environment.selectedTab {
                case .today: TodayScreen()
                case .log: LogScreen()
                case .history: HistoryScreen()
                case .progress: ProgressScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            TallyTabBar(selection: Binding(
                get: { environment.selectedTab },
                set: { environment.selectedTab = $0 }
            ))
        }
        .background(Color.tallyBackground)
    }
}

/// The bottom tab bar: Today · Log · History · Progress, with Log accented.
struct TallyTabBar: View {
    @Binding var selection: DeepLink.Tab

    var body: some View {
        VStack(spacing: 0) {
            TallyRule(weight: Metrics.rule)

            HStack(alignment: .top, spacing: 0) {
                ForEach(DeepLink.Tab.allCases, id: \.self) { tab in
                    TabButton(
                        tab: tab,
                        isSelected: selection == tab,
                        action: { selection = tab }
                    )
                }
            }
            .padding(.top, 9)
            .padding(.horizontal, Metrics.space1)
        }
        .background(Color.tallyBackground)
    }

    private struct TabButton: View {
        let tab: DeepLink.Tab
        let isSelected: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(spacing: Metrics.space1) {
                    icon
                    Text(tab.title)
                        .font(.tallyScaled(10, weight: isSelected ? .bold : .semibold,
                                           relativeTo: .caption2))
                        .tracking(0.04 * 10)
                        .textCase(.uppercase)
                }
                .foregroundStyle(isSelected ? Color.tallyAccent : Color.tallyTertiaryText)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
            // Tests target this rather than the visible title, so renaming a tab is a copy
            // change and not a test failure.
            .accessibilityIdentifier("tab.\(tab.rawValue)")
        }

        @ViewBuilder private var icon: some View {
            // Log is the app's primary action, so the design gives it a filled accent tile
            // rather than an outline glyph — it reads as a button among labels.
            if tab == .log {
                ZStack {
                    Rectangle().fill(Color.tallyAccent)
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .heavy))
                        .foregroundStyle(Color.tallyInverted)
                }
                .frame(width: 30, height: 30)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                    .frame(height: 30)
            }
        }

        private var systemImage: String {
            switch tab {
            case .today: "house"
            case .log: "plus"
            case .history: "list.bullet"
            case .progress: "chart.line.uptrend.xyaxis"
            }
        }
    }
}

/// Shown when the database could not be opened.
///
/// Deliberately loud and specific. The near-certain cause is an App Group that doesn't match the
/// developer portal, and the failure is otherwise invisible — the app would look like it works
/// while saving nothing.
struct StartupErrorBanner: View {
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            Text("Entries are not being saved")
                .font(.tallyScaled(13, weight: .heavy))
            Text(detail)
                .font(.tallyScaled(11, weight: .regular, relativeTo: .caption))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.tallyInverted)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.space3)
        .background(Color.tallyAccent)
        .accessibilityElement(children: .combine)
    }
}
