import Foundation
import LLMWire

/// Which AI service the user chose, and which model at it.
///
/// Persisted rather than held in memory because Siri reaches the parser through an App Intent,
/// with no app process and no view hierarchy to read a setting from. A choice that lived only in
/// `AppEnvironment` would mean "log 300 calories" quietly used a different provider — and billed
/// a different account — than the same words typed into the app.
public struct AISettings: Hashable, Sendable, Codable {
    /// Matches ``LLMProvider/id``. Stored rather than the whole provider so that a shipped
    /// correction — a moved endpoint, a provider that gained strict schema support — reaches
    /// users who already chose it, instead of being frozen at the moment they picked.
    public var providerID: String
    /// Free text. Providers add and retire identifiers constantly, so this is never validated
    /// against a fixed list; a wrong one produces ``NutritionParserError/unknownModel(_:)``,
    /// which says so plainly.
    public var model: String
    public var effort: String
    public var maxTokens: Int
    /// The user's own OpenAI-compatible endpoint, when they configured one. Stored whole, since
    /// nothing shipped can reconstruct it.
    public var customProvider: LLMProvider?
    /// Prefer the on-device model when the OS provides one.
    ///
    /// Separate from `providerID` because it isn't a provider in the same sense: it needs no key,
    /// no account and no network, it exists only on new enough systems, and the sensible
    /// behaviour when it is unavailable is to fall through to the configured provider rather than
    /// to fail.
    public var prefersOnDevice: Bool

    public static let `default` = AISettings(
        providerID: LLMProvider.anthropic.id,
        model: LLMProvider.anthropic.defaultModel,
        effort: "low",
        maxTokens: 2048,
        customProvider: nil,
        prefersOnDevice: false
    )

    public init(
        providerID: String,
        model: String,
        effort: String = "low",
        maxTokens: Int = 2048,
        customProvider: LLMProvider? = nil,
        prefersOnDevice: Bool = false
    ) {
        self.providerID = providerID
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.customProvider = customProvider
        self.prefersOnDevice = prefersOnDevice
    }

    /// The chosen provider, or Anthropic if the stored id names one that no longer exists.
    ///
    /// Falling back rather than failing: a provider this app has dropped should leave the user
    /// with a working default and a wrong-looking setting, not with a parser that throws on every
    /// call and a screen that can't explain why.
    public var provider: LLMProvider {
        if let customProvider, customProvider.id == providerID { return customProvider }
        return LLMProvider.builtIn(id: providerID) ?? .anthropic
    }

    public var parserConfiguration: ParserConfiguration {
        ParserConfiguration(
            provider: provider,
            model: model.isEmpty ? provider.defaultModel : model,
            effort: effort,
            maxTokens: maxTokens
        )
    }

    /// Switches provider, moving the model to that provider's default.
    ///
    /// Carrying the old model across would be worse than useless: `claude-opus-5` at OpenAI is a
    /// 404, and the error would arrive halfway through logging a meal rather than at the moment
    /// the choice was made.
    public mutating func select(_ provider: LLMProvider) {
        providerID = provider.id
        model = provider.defaultModel
        if !provider.isBuiltIn { customProvider = provider }
    }

    /// Decoded leniently so a settings document written by an older build — one that predates
    /// on-device support, or providers entirely — still opens.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try container.decodeIfPresent(String.self, forKey: .providerID)
            ?? Self.default.providerID
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? Self.default.model
        effort = try container.decodeIfPresent(String.self, forKey: .effort) ?? Self.default.effort
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
            ?? Self.default.maxTokens
        customProvider = try container.decodeIfPresent(LLMProvider.self, forKey: .customProvider)
        prefersOnDevice = try container.decodeIfPresent(Bool.self, forKey: .prefersOnDevice) ?? false
    }
}
