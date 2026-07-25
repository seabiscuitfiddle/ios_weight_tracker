import Foundation
import LLMWire
import TallyCore

/// Builds the parser the user's settings describe.
///
/// The one place that turns a stored choice into a working object, so the app and its App Intents
/// cannot drift into using different providers — the failure that would be hardest to notice,
/// since both would appear to work while billing different accounts.
enum ParserFactory {
    static func make(_ settings: AISettings, bundle: Bundle = .main) -> any NutritionParser {
        // Preferred but not required: if Apple Intelligence is off or the device is ineligible,
        // falling through to the configured provider is better than failing every request over a
        // preference the user set months ago on a different phone.
        if settings.prefersOnDevice, let onDevice = OnDeviceModel.makeParser() {
            return onDevice
        }

        return LLMNutritionParser(
            transport: URLSessionTransport.makeDefault(),
            keyStore: KeychainAPIKeyStore.forCurrentBundle(
                providerID: settings.providerID, bundle: bundle
            ),
            configuration: settings.parserConfiguration
        )
    }
}
