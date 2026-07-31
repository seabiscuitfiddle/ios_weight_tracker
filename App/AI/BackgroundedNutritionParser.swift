import Foundation
import TallyCore

/// Any parser, plus the execution time needed to finish what it started.
///
/// A parse is the one thing the app does that the user is expected to wait several seconds for,
/// and waiting is exactly when a phone gets pocketed or locked. Without the assertion this holds,
/// the process is suspended mid-request and the answer never arrives — the entry is not saved, and
/// nothing on screen explains why when the app comes back.
///
/// Wrapping the parser rather than the screens is deliberate: every route into a parse — the Log
/// screen, correcting an entry, a Siri intent, and the on-device model as much as a hosted one —
/// goes through ``ParserFactory``, so this is one decision rather than one per caller, and a new
/// caller inherits it by existing. See ``BackgroundWork`` for what the assertion actually is.
struct BackgroundedNutritionParser: NutritionParser {
    let wrapped: any NutritionParser
    var host: any BackgroundExecutionHost = UIKitBackgroundExecutionHost()

    func parse(_ input: ParseInput, context: ParseContext) async throws -> ParseResult {
        let parser = wrapped
        do {
            return try await BackgroundWork.run("Nutrition parse", host: host) {
                try await parser.parse(input, context: context)
            }
        } catch is BackgroundWork.Expired {
            // Half a minute wasn't enough, or the phone had no time to spare. Reported as its own
            // failure so the message offers a retry instead of blaming the network, which was
            // fine — see ``NutritionParserError/interrupted``.
            throw NutritionParserError.interrupted
        }
    }
}
