import SwiftUI
import TallyCore

/// The four-tab shell every screen sits in.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(spacing: 0) {
            if let banner = environment.visibleBanner {
                StorageBanner(detail: banner.detail, severity: banner.severity) {
                    environment.dismissBanner(banner.severity)
                }
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

/// Explains a storage problem, at the severity it actually warrants.
///
/// Two levels, because conflating them would be its own bug. "Nothing is being saved" is an
/// emergency and has to be loud. "Saved, but the widget can't see it" is a setup detail that
/// shouldn't look like data loss — but must still be said, or it resurfaces later as a widget
/// that mysteriously stays blank.
///
/// Either can be closed. Both describe conditions the user may have decided to live with — a
/// simulator build with no App Group, most of all — and a permanent bar across the top of every
/// screen is soon read as furniture rather than as a warning. Installing a new version brings it
/// back; see ``BannerDismissals``.
struct StorageBanner: View {
    /// Raw values are persisted as dismissal keys, so renaming one re-shows that banner once.
    enum Severity: String {
        /// No database at all; entries will be lost.
        case notSaving
        /// Persisting locally, but outside the shared container the widget reads.
        case widgetOnly

        var title: String {
            switch self {
            case .notSaving: "Entries are not being saved"
            case .widgetOnly: "The widget won't show your data"
            }
        }

        var background: Color {
            switch self {
            case .notSaving: .tallyAccent
            case .widgetOnly: .tallySurface
            }
        }

        var foreground: Color {
            switch self {
            case .notSaving: .tallyInverted
            case .widgetOnly: .tallyText
            }
        }
    }

    let detail: String
    let severity: Severity
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.space2) {
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(severity.title)
                    .font(.tallyScaled(13, weight: .heavy))
                Text(detail)
                    .font(.tallyScaled(11, weight: .regular, relativeTo: .caption))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Combined so VoiceOver reads the warning as one sentence — but applied to the text
            // alone, or it would swallow the close button along with it.
            .accessibilityElement(children: .combine)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .heavy))
                    // The glyph is small; the hit area isn't. A close button that's awkward to
                    // hit reads as a banner that won't go away.
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("banner.dismiss")
            // Pulls the oversized hit area back so the glyph optically aligns with the title
            // and the banner's own padding.
            .padding(.top, -Metrics.space2)
            .padding(.trailing, -Metrics.space2)
        }
        .foregroundStyle(severity.foreground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.space3)
        .background(severity.background)
        .overlay(alignment: .bottom) {
            if severity == .widgetOnly { TallyRule() }
        }
    }
}
