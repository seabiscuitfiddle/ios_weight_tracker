import Foundation
import Testing
import TallyCore
@testable import Tally

/// A stand-in for `UIApplication`'s background assertion.
///
/// The real one can't be tested against: a test process can't be granted an assertion on demand,
/// and it certainly can't be made to run out of time — which is the case worth having a test for,
/// since it only shows up on a real phone after half a minute in someone's pocket.
private actor FakeExecutionHost: BackgroundExecutionHost {
    enum Behaviour {
        /// The ordinary case: time is granted and lasts long enough.
        case grants
        /// The system wants it back at once — a device that is out of background budget, or the
        /// half minute expiring under a slow parse.
        case expiresImmediately
        /// No time at all. Background App Refresh off, or Low Power Mode.
        case refuses
    }

    private let behaviour: Behaviour
    private(set) var begun: [String] = []
    private(set) var ended: [BackgroundWorkToken] = []
    private var nextToken = 1

    init(_ behaviour: Behaviour = .grants) {
        self.behaviour = behaviour
    }

    /// True while an assertion has been taken out and not yet returned.
    var isHolding: Bool { begun.count > ended.count }

    func begin(
        _ name: String,
        expired: @escaping @Sendable () -> Void
    ) async -> BackgroundWorkToken {
        begun.append(name)
        guard behaviour != .refuses else { return .refused }

        let token = BackgroundWorkToken(rawValue: nextToken)
        nextToken += 1
        if behaviour == .expiresImmediately { expired() }
        return token
    }

    func end(_ token: BackgroundWorkToken) async {
        ended.append(token)
    }
}

/// Still working when the system's patience runs out.
private struct SlowNutritionParser: NutritionParser {
    func parse(_ input: ParseInput, context: ParseContext) async throws -> ParseResult {
        // Far longer than any assertion, and cancelled long before it elapses in these tests.
        try await Task.sleep(for: .seconds(5))
        return ParseResult(items: [])
    }
}

private struct Boom: Error {}

@Suite("Background work")
struct BackgroundWorkTests {
    /// The point of the whole thing: while the request is in flight the app is holding the system
    /// off, and the moment it isn't, it lets go. An assertion left open is worse than none —
    /// iOS kills an app that keeps one.
    @Test("holds an assertion for as long as the work runs, and gives it back after")
    func holdsWhileWorking() async throws {
        let host = FakeExecutionHost()

        let heldDuringWork = try await BackgroundWork.run("Parse", host: host) {
            // The assertion is asked for immediately after this work is started, so wait for it
            // rather than racing it.
            while await host.begun.isEmpty { await Task.yield() }
            return await host.isHolding
        }

        #expect(heldDuringWork)
        let begun = await host.begun
        let ended = await host.ended
        #expect(begun == ["Parse"])
        #expect(ended.count == 1)
    }

    @Test("gives the time back when the work fails")
    func endsAfterAFailure() async {
        let host = FakeExecutionHost()

        await #expect(throws: Boom.self) {
            try await BackgroundWork.run("Parse", host: host) { () async throws -> Int in
                throw Boom()
            }
        }

        let ended = await host.ended
        #expect(ended.count == 1)
    }

    /// Expiry has to be told apart from an ordinary failure. The work stops either way, but only
    /// here is the reason "the phone put us to sleep" rather than anything about the request.
    @Test("reports expiry as its own failure, and still hands the time back")
    func expiryStopsTheWork() async {
        let host = FakeExecutionHost(.expiresImmediately)

        await #expect(throws: BackgroundWork.Expired.self) {
            try await BackgroundWork.run("Parse", host: host) {
                try await Task.sleep(for: .seconds(5))
                return "finished anyway"
            }
        }

        let ended = await host.ended
        #expect(ended.count == 1)
    }

    /// A refused assertion is a normal state — Low Power Mode grants nothing — and must not stop
    /// the app doing the thing the user asked for while it is still on screen.
    @Test("runs the work anyway when the system grants no time")
    func refusalIsNotAFailure() async throws {
        let host = FakeExecutionHost(.refuses)

        let value = try await BackgroundWork.run("Parse", host: host) { 7 }

        #expect(value == 7)
    }
}

@Suite("Backgrounded parser")
struct BackgroundedNutritionParserTests {
    @Test("a parse runs inside a background assertion")
    func parseIsHeldAwake() async throws {
        let host = FakeExecutionHost()
        let parser = BackgroundedNutritionParser(wrapped: StubNutritionParser(), host: host)

        let result = try await parser.parse(.text("two eggs and toast"))

        #expect(result.items.count == 1)
        let begun = await host.begun
        let ended = await host.ended
        #expect(begun.count == 1)
        #expect(ended.count == 1)
    }

    /// The cancelled request reports itself as a dead socket, which would reach the user as "no
    /// connection" — advice that sends them to check a network that was never the problem.
    @Test("a parse cut short by the system is reported as an interruption")
    func expiryBecomesInterrupted() async {
        let host = FakeExecutionHost(.expiresImmediately)
        let parser = BackgroundedNutritionParser(wrapped: SlowNutritionParser(), host: host)

        await #expect(throws: NutritionParserError.interrupted) {
            try await parser.parse(.text("two eggs and toast"))
        }
    }

    /// The wiring, which is the part that would go quietly wrong: a parser built without this
    /// wrapper works perfectly on screen and loses every request made from a pocket.
    @Test("every parser the app builds is wrapped")
    func factoryWrapsWhatItBuilds() {
        #expect(ParserFactory.make(.default) is BackgroundedNutritionParser)
    }
}

@MainActor
@Suite("Interrupted logging")
struct InterruptedLogTests {
    /// What the user actually sees on coming back: nothing was saved, and the screen offers to
    /// send it again rather than leaving the send to be retyped.
    @Test("an interrupted parse leaves the Log screen offering a retry")
    func interruptedParseOffersRetry() async throws {
        let host = FakeExecutionHost(.expiresImmediately)
        let stores = StoreBundle.inMemory()
        let model = LogModel(
            stores: stores,
            parser: BackgroundedNutritionParser(wrapped: SlowNutritionParser(), host: host)
        )

        await model.log(text: "two eggs and toast")

        #expect(model.errorMessage == NutritionParserError.interrupted.userMessage)
        #expect(model.canRetry)
        #expect(model.needsAPIKey == false)
        #expect(model.justAdded.isEmpty)
        #expect(try stores.entries.entries(on: Day.today()).isEmpty)
    }
}
