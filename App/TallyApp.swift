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
                // The design is a single light theme with a specific paper-white ground;
                // a dark rendering would be a different design, not an inverted one.
                .preferredColorScheme(.light)
        }
    }
}
