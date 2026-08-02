import SwiftUI
import TallyCore

@main
struct TallyApp: App {
    // Carries the work a launch owes even when no window is coming — a Health update arrives by
    // waking the app, and that wake connects no scene. See TallyAppDelegate.
    @UIApplicationDelegateAdaptor(TallyAppDelegate.self) private var appDelegate
    // The same instance the delegate wakes, so a background launch and the window on screen share
    // one set of stores rather than opening the database twice.
    @State private var environment = AppEnvironment.shared
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
                // This launch's own reading, wanted straight away because `onChange` below
                // doesn't fire for the phase the app starts in. Only the reading: re-registering
                // background delivery belongs to the launch rather than to the window, since the
                // launches that need it most have no window — see TallyAppDelegate. A no-op
                // unless the user switched activity on.
                .task { await environment.refreshHealthActivity() }
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
