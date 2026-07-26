import Foundation

/// Whether a provider will take a reasoning-effort hint, and for which of its models.
///
/// A boolean is the wrong shape for this. Effort is a property of the *model*, not of the
/// endpoint: Anthropic and OpenAI both serve models that take the hint and models that reject it
/// from the same URL, so a per-provider yes/no is wrong for half the model picker either way.
///
/// The two ways of being wrong are not equally expensive. Leaving the hint off costs a slightly
/// different amount of thinking on a request that still succeeds; sending it to a model that
/// doesn't take it fails the whole request with a 400 naming a field the user never chose. So
/// anything unrecognised is treated as not supporting it.
public enum EffortSupport: String, Hashable, Sendable, Codable, CaseIterable {
    /// Never send it. The right default for compatible-mode endpoints, which vary in whether they
    /// ignore unknown parameters or reject the whole request over one.
    case never
    /// Send it only to models whose identifier says they accept it — Anthropic's Opus from 4.5
    /// and Sonnet from 4.6, OpenAI's GPT-5 family and o-series.
    case knownModels
    /// Send it for any model. For gateways that normalise parameters across their upstreams and
    /// drop what the chosen model cannot use, rather than passing an unusable field through.
    case always
}

extension LLMProvider {
    /// The value to send as this request's effort hint, or nil to leave the field off entirely.
    ///
    /// Returns a string rather than an ``ChatRequest/Effort`` because the level asked for is not
    /// always a level the model publishes, and quietly stepping to the nearest one it does is
    /// better than a rejected request.
    func effortValue(_ effort: ChatRequest.Effort, model: String) -> String? {
        switch effortSupport {
        case .never:
            return nil
        case .always:
            return effort.rawValue
        case .knownModels:
            switch wireFormat {
            case .anthropicMessages: return ReasoningModel.anthropicEffort(effort, model: model)
            case .openAIChatCompletions: return ReasoningModel.openAIEffort(effort, model: model)
            }
        }
    }
}

/// Which published models take a reasoning-effort hint, and at what values.
///
/// Recognises families and version numbers rather than listing identifiers, for the same reason
/// ``LLMProvider/suggestedModels`` is only a seed: a list of identifiers is wrong within months.
/// A name this doesn't recognise is treated as not supporting effort, which is the cheap way to
/// be wrong — see ``EffortSupport``.
enum ReasoningModel {
    /// Anthropic carries the hint as `output_config.effort`, on Opus from 4.5 and Sonnet from
    /// 4.6. Sonnet 4.5, every Haiku released so far, and everything on the Claude 3 naming scheme
    /// reject it outright — and two of those are in the shipped model picker.
    static func anthropicEffort(_ effort: ChatRequest.Effort, model: String) -> String? {
        guard let name = ClaudeModel(model),
              name.version >= minimumVersion(for: name.family)
        else { return nil }

        // Anthropic's scale runs low through max and has no `minimal`. Asking for the least
        // thinking it can express is much closer to the caller's intent than a 400.
        return effort == .minimal ? ChatRequest.Effort.low.rawValue : effort.rawValue
    }

    private static func minimumVersion(for family: ClaudeModel.Family) -> ClaudeModel.Version {
        switch family {
        case .opus: return (4, 5)
        case .sonnet: return (4, 6)
        // No Haiku takes an effort hint as of 4.5. Pitched at the next major rather than at
        // "never", so that a future one isn't permanently excluded by a line in this file.
        case .haiku: return (5, 0)
        case .fable, .mythos: return (0, 0)
        }
    }

    /// OpenAI carries it as `reasoning_effort`, which only the reasoning models accept: the GPT-5
    /// family and the o-series. GPT-4.1 and GPT-4o reject it, and GPT-4.1 is in the shipped model
    /// picker.
    static func openAIEffort(_ effort: ChatRequest.Effort, model: String) -> String? {
        let name = bareModelName(model)

        // `minimal` arrived with GPT-5 and is not one of the o-series' levels.
        if name.hasPrefix("gpt-5") { return effort.rawValue }
        if isOSeries(name) {
            return effort == .minimal ? ChatRequest.Effort.low.rawValue : effort.rawValue
        }
        return nil
    }

    /// `o3`, `o4-mini`, `o1-preview` — a bare `o` and a number, then a dash or the end of the
    /// name. Deliberately not a prefix match: `openai/…` and `olmo` are not the o-series.
    private static func isOSeries(_ name: String) -> Bool {
        let head = name.prefix { $0 != "-" }
        guard head.first == "o", head.count > 1 else { return false }
        return head.dropFirst().allSatisfy(\.isNumber)
    }
}

/// A Claude model identifier, decomposed far enough to tell which capabilities it has.
struct ClaudeModel {
    typealias Version = (Int, Int)

    enum Family: String, CaseIterable {
        case opus, sonnet, haiku, fable, mythos
    }

    var family: Family
    /// `(0, 0)` when the identifier carries no version after the family, as on
    /// `claude-3-opus-20240229`, whose version sits *before* it. That naming scheme predates
    /// effort entirely, so reading those as version zero lands on the right answer.
    var version: Version

    init?(_ identifier: String) {
        let parts = bareModelName(identifier).split(whereSeparator: { $0 == "-" || $0 == "." })
        guard let familyIndex = parts.firstIndex(where: { Family(rawValue: String($0)) != nil }),
              let family = Family(rawValue: String(parts[familyIndex]))
        else { return nil }

        // Version components follow the family, and an eight-digit run is a release date rather
        // than one of them: `claude-opus-4-20250514` is Opus 4, not Opus 4.20250514.
        let numbers = parts[parts.index(after: familyIndex)...]
            .prefix { $0.count < 8 && $0.allSatisfy(\.isNumber) }
            .compactMap { Int($0) }

        self.family = family
        self.version = (numbers.first ?? 0, numbers.dropFirst().first ?? 0)
    }
}

/// Strips a gateway's routing prefix. OpenRouter names the same model `anthropic/claude-…`, and
/// the family and version it is really pointing at are worth reading through that.
fileprivate func bareModelName(_ identifier: String) -> String {
    let lowered = identifier.lowercased()
    return lowered.split(separator: "/").last.map(String.init) ?? lowered
}
