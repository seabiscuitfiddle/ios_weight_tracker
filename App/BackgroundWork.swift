import Foundation
import UIKit

/// Runs work the user is waiting on so that leaving the app doesn't throw it away.
///
/// iOS suspends an app a few moments after it stops being on screen — the home button, a switch
/// to another app, the lock button — and a suspended process's network connections go with it.
/// For anything instant that is invisible; for a request to a model that takes several seconds it
/// is the reported failure: a meal is described, the phone is pocketed, and the parse that was
/// nearly done is silently lost.
///
/// The fix is the assertion this wraps. `beginBackgroundTask` tells the system the app is in the
/// middle of something and buys roughly half a minute past the moment it leaves the screen —
/// comfortably more than a parse needs, and no entitlement or background mode is required for it.
///
/// The bargain has a second half that has to be honoured: the assertion must be ended, whether the
/// work succeeded, failed, or ran out of time. An app that lets one lapse is not suspended, it is
/// killed.
enum BackgroundWork {
    /// Holds the app awake for the length of `operation`.
    ///
    /// - Parameter name: shown in system energy logs, so name the work rather than the caller.
    /// - Returns: whatever `operation` returned.
    /// - Throws: ``Expired`` when the system took its time back first, and otherwise whatever
    ///   `operation` threw.
    static func run<Value: Sendable>(
        _ name: String,
        host: any BackgroundExecutionHost = UIKitBackgroundExecutionHost(),
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let expiry = ExpiryFlag()
        // Started before the assertion is asked for, because the expiration handler's whole job
        // is to stop this task and it therefore has to exist first. The window is a few
        // microseconds of an app that is still in the foreground, which is not a window in which
        // anything can be suspended.
        let work = Task { try await operation() }
        let token = await host.begin(name) {
            expiry.raise()
            work.cancel()
        }

        do {
            // The cancellation handler is what connects the caller's task to this one: `work` is
            // unstructured, so without it a screen that goes away would leave the request running
            // with nobody waiting for the answer.
            let value = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            await host.end(token)
            return value
        } catch {
            await host.end(token)
            // On expiry the operation reports how it stopped — a cancelled socket, usually —
            // which describes the symptom and not the cause. The caller can say something true
            // about being put to sleep only if it is told that is what happened.
            if expiry.isRaised { throw Expired() }
            throw error
        }
    }

    /// The system reclaimed the extra time before the work finished.
    struct Expired: Error {}

    /// Set from the expiration handler, read by whoever is waiting. A class with a lock rather
    /// than a captured variable because the two happen on different threads.
    private final class ExpiryFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false

        func raise() {
            lock.lock()
            defer { lock.unlock() }
            raised = true
        }

        var isRaised: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raised
        }
    }
}

/// The system facility ``BackgroundWork`` leans on, named as a protocol so it can be observed.
///
/// `UIApplication` is the only real implementation and it cannot be driven from a test: an
/// assertion granted to a running app expires when the system decides it does, which is the one
/// case worth having a test for. Everything above this line is exercised against a fake instead.
protocol BackgroundExecutionHost: Sendable {
    /// Asks for extra execution time.
    ///
    /// - Parameter expired: called when the system wants the time back. The work has to stop.
    func begin(
        _ name: String,
        expired: @escaping @Sendable () -> Void
    ) async -> BackgroundWorkToken

    /// Returns the time. Required after every ``begin(_:expired:)``, including an expired one.
    func end(_ token: BackgroundWorkToken) async
}

/// One outstanding assertion.
struct BackgroundWorkToken: Hashable, Sendable {
    let rawValue: Int

    /// What a system that refused the request hands back — the user has switched background
    /// activity off, or the app is out of budget.
    static let refused = BackgroundWorkToken(rawValue: UIBackgroundTaskIdentifier.invalid.rawValue)
}

/// The real thing.
struct UIKitBackgroundExecutionHost: BackgroundExecutionHost {
    func begin(
        _ name: String,
        expired: @escaping @Sendable () -> Void
    ) async -> BackgroundWorkToken {
        await MainActor.run {
            BackgroundWorkToken(
                rawValue: UIApplication.shared
                    .beginBackgroundTask(withName: name, expirationHandler: expired)
                    .rawValue
            )
        }
    }

    func end(_ token: BackgroundWorkToken) async {
        // Ending an assertion that was never granted is not a no-op — UIKit treats it as a
        // programming error and traps — so a refusal is dropped here rather than passed on.
        guard token != .refused else { return }
        await MainActor.run {
            UIApplication.shared.endBackgroundTask(
                UIBackgroundTaskIdentifier(rawValue: token.rawValue)
            )
        }
    }
}
