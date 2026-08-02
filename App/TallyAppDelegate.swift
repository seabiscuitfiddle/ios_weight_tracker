import UIKit

/// The app's launch hook.
///
/// SwiftUI's scene lifecycle has nowhere to put work that has to happen on a launch with no
/// window, and HealthKit background delivery produces exactly that launch — see
/// ``AppEnvironment/handleLaunch()`` for what depends on it. `didFinishLaunchingWithOptions` is
/// the one entry point a background launch and a tapped icon have in common, which is the only
/// reason an otherwise scene-based app carries a delegate at all.
@MainActor
final class TallyAppDelegate: NSObject, UIApplicationDelegate {
    /// The work itself, injectable for the same reason ``WidgetRefresher/reload`` is: the real one
    /// reaches HealthKit, which no test can. What a test can still prove is that a launch runs it
    /// without a scene having to appear first, which is the whole of the fix.
    var launch: @MainActor @Sendable () async -> Void = {
        await AppEnvironment.shared.handleLaunch()
    }

    /// The task ``launch`` runs in. Unstructured because the system is waiting on this callback
    /// and it has to return promptly; held so a test has something to await.
    private(set) var launchTask: Task<Void, Never>?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        launchTask = Task { await self.launch() }
        return true
    }
}
