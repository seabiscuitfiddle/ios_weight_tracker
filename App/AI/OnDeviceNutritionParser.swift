import Foundation
import LLMWire
import TallyCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Parses food and exercise with Apple's on-device model.
///
/// The only provider that is free, works on a plane, and sends nothing anywhere — which for a food
/// diary is not a small thing. The trade is that it is a small model: portion estimates are
/// noticeably weaker than a frontier model's, and it cannot read a photo, so it is offered rather
/// than defaulted to.
///
/// Compiled conditionally and gated at runtime, because the framework exists only from iOS 26 and
/// the model itself is absent on ineligible devices and when Apple Intelligence is switched off.
/// Tally's deployment target is iOS 17, so this path must be entirely optional at both compile
/// and run time.
enum OnDeviceModel {
    /// Whether an on-device parse would work right now.
    ///
    /// Checked before the setting is offered rather than after it is chosen: a toggle that can be
    /// switched on and then fails every request is worse than one that isn't there.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    /// Why it can't be used, phrased for a settings footer. Nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(.deviceNotEligible):
                return "This device doesn't support Apple Intelligence."
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Turn on Apple Intelligence in Settings to log without an API key."
            case .unavailable(.modelNotReady):
                return "The on-device model is still downloading. Try again later."
            case .unavailable:
                return "The on-device model isn't available right now."
            }
        }
        #endif
        return "On-device logging needs iOS 26 or later."
    }

    static func makeParser() -> (any NutritionParser)? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *), isAvailable {
            return OnDeviceNutritionParser()
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)

@available(iOS 26.0, macOS 26.0, *)
struct OnDeviceNutritionParser: NutritionParser {
    /// Roughly what a few items of food need, and low enough that a runaway generation fails
    /// quickly rather than holding the user at a spinner.
    private let maximumResponseTokens = 1200

    func parse(_ input: ParseInput, context: ParseContext) async throws -> ParseResult {
        // No vision on this path. Caught here so the message names the reason rather than letting
        // the photo be silently ignored and an empty result blamed on the food.
        guard case .text = input else {
            throw NutritionParserError.imagesUnsupported(provider: "The on-device model")
        }

        let session = LanguageModelSession(instructions: Self.instructions)

        do {
            let response = try await session.respond(
                to: ParsePrompt.userInstruction(for: input, context: context),
                options: GenerationOptions(maximumResponseTokens: maximumResponseTokens)
            )
            // Nothing constrains the output here, so the same tolerant path the JSON-mode
            // providers use applies: strip any fence or preamble, then decode leniently.
            return try LLMNutritionParser.result(fromJSON: JSONText.extract(from: response.content))
        } catch let error as NutritionParserError {
            throw error
        } catch {
            // The framework's own errors — a guardrail trip, an exceeded context window — are
            // typed but not worth mapping one by one: none of them are retryable, and the model's
            // own description is more specific than anything invented here.
            throw NutritionParserError.refused(
                "The on-device model couldn't handle that. \(error.localizedDescription)"
            )
        }
    }

    /// The shared prompt plus the schema, since this path has no structured-output slot to put it
    /// in — the same fallback used for providers that only offer JSON mode.
    private static let instructions = """
        \(ParsePrompt.system)

        Reply with a single json object and nothing else: no explanation before it, no commentary \
        after it, and no markdown code fence around it. The object must conform to this JSON \
        Schema, including every property listed as required:

        \(ParsePrompt.outputSchema)
        """
}

#endif
