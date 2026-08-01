import SwiftUI
import TallyCore

@main
struct TallyApp: App {
    @State private var environment = AppEnvironment()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                // Handles tally:// URLs from the widget's quick-log buttons and from Siri.
                .onOpenURL { environment.handle($0) }
                // An App Intent that foregrounds the app records where it wanted to go before
                // the UI existed; this collects it once there is somewhere to navigate.
                .task { environment.consumePendingIntentLink() }
                // Keeps the widgets in step with what's been logged. Attached to the scene's
                // root rather than to a screen: whichever tab is on show, a write from any of
                // them has to reach the widget.
                .task {
                    await WidgetRefresher().observe(environment.stores.changes.stream())
                }
                // Background delivery has to be re-registered every launch — the system keeps
                // the subscription, not the query — and this launch's own reading is wanted
                // straight away, since `onChange` below doesn't fire for the phase the app
                // starts in. Both are no-ops unless the user switched activity on.
                .task {
                    await environment.startActivityMonitorIfEnabled()
                    await environment.refreshHealthActivity()
                }
                // Background delivery is hourly at best, so returning to the app is what makes
                // the day's activity look live. Cheap when nothing has moved: unchanged days
                // aren't written, so this usually costs one Health read and no widget reload.
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await environment.refreshHealthActivity() }
                }
                // The design is a single light theme with a specific paper-white ground;
                // a dark rendering would be a different design, not an inverted one.
                .preferredColorScheme(.light)
        }
    }
}
