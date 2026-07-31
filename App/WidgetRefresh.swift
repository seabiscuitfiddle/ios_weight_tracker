import Foundation
import TallyCore
import WidgetKit

/// Asks WidgetKit to rebuild the Lock Screen and Home Screen widgets after a write.
///
/// The widget process reads the shared database once per timeline and then schedules its next
/// refresh for midnight — deliberately, because polling a database that only changes when the
/// user logs something would burn the system's refresh budget for nothing. That leaves the
/// writing side owning the other half of the bargain: without a reload request, a widget keeps
/// showing whatever the numbers were when its timeline was last built, which is exactly the
/// "initial setup shows up but nothing after it does" the widgets were reported doing.
///
/// It hangs off ``DataChangeBroadcaster`` rather than being called from each screen, so a new
/// write path gets widget freshness by existing rather than by remembering. Writes made outside
/// the running app — a Siri intent, which finishes and exits before any observer could see it —
/// call ``reload`` directly instead.
struct WidgetRefresher: Sendable {
    /// The reload itself, injectable so the app's own tests can prove a write reaches it.
    /// `WidgetCenter` needs a real widget host, so it cannot be observed from a test.
    var reload: @Sendable () -> Void = { WidgetCenter.shared.reloadAllTimelines() }

    /// Reloads once per change, until the surrounding task is cancelled.
    ///
    /// Takes the stream rather than the broadcaster so the subscription is made by the caller,
    /// synchronously: starting it inside the task instead would drop any write that landed
    /// before the task got a chance to run.
    func observe(_ changes: AsyncStream<DataChange>) async {
        for await _ in changes { reload() }
    }
}
