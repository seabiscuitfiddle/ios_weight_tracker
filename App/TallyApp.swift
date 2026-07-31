import SwiftUI
import TallyCore

@main
struct TallyApp: App {
    @State private var environment = AppEnvironment()

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
                // The design is a single light theme with a specific paper-white ground;
                // a dark rendering would be a different design, not an inverted one.
                .preferredColorScheme(.light)
        }
    }
}
