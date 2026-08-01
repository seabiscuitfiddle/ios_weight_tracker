import Foundation
import Testing
@testable import Tally

/// The bridge between a system callback and an `await`, which is where voice input crashed on
/// launch for the second time.
///
/// `SystemVoiceEngine` itself still can't be tested — a test process has no microphone and can't
/// grant itself a privacy permission — but the part that crashed can be, because the crash had
/// nothing to do with speech. It was a main-actor-isolated closure being called from TCC's reply
/// queue, and that reproduces with any callback on any background queue.
///
/// Worth knowing before reading a failure here: a regression does not fail an expectation, it
/// takes the whole test process down with a trap. That is precisely what it did to the app.
@Suite("System voice callbacks")
struct SystemVoiceEngineTests {
    /// The crash, in miniature. Called from the main actor — as ``SystemVoiceEngine`` is, being
    /// `@MainActor` — with a handler the system calls back somewhere else entirely.
    @MainActor
    @Test("resumes from a callback delivered off the main actor")
    func resumesFromABackgroundCallback() async {
        let value: Int = await awaitingCallback { handler in
            DispatchQueue.global().async { handler(7) }
        }

        #expect(value == 7)
    }

    /// The path a granted permission takes: TCC has the answer already and says so immediately,
    /// before `awaitingCallback` has suspended. Resuming a continuation that hasn't parked yet is
    /// legal, and this is the case that ran fine for every build where the permission was old.
    @MainActor
    @Test("resumes from a callback delivered before it suspends")
    func resumesFromAnImmediateCallback() async {
        let value: String = await awaitingCallback { handler in
            handler("granted")
        }

        #expect(value == "granted")
    }

    /// Several sessions' worth of permission checks at once, each landing on its own thread. A
    /// continuation resumed twice, or resumed from the wrong one, traps here rather than in
    /// somebody's hands.
    @MainActor
    @Test("keeps concurrent callbacks apart")
    func keepsConcurrentCallbacksApart() async {
        let results = await withTaskGroup(of: Int.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let value: Int = await awaitingCallback { handler in
                        DispatchQueue.global().async { handler(index) }
                    }
                    return value
                }
            }
            var seen = Set<Int>()
            for await value in group { seen.insert(value) }
            return seen
        }

        #expect(results == Set(0..<20))
    }
}
