import Foundation
import LLMWire

/// Which provider and model to use, and how hard to make it think.
///
/// The provider is a value rather than a type, so adding one is data — a new ``LLMProvider`` —
/// and never a new parser. Settings exposes all of it, because the right trade between cost,
/// speed and quality is the user's to make and not a decision this app should bake in.
public struct ParserConfiguration: Hashable, Sendable {
    public var provider: LLMProvider
    /// Model identifier. Free text on purpose: providers add and retire identifiers constantly,
    /// and a fixed list would make the app wrong within months.
    public var model: String
    /// Reasoning effort, where the provider supports it.
    public var effort: String
    public var maxTokens: Int

    /// The default: a capable model at low effort.
    ///
    /// Extracting numbers from "two eggs and toast" is not an intelligence-limited task, and
    /// someone standing in their kitchen is waiting on the answer — so low effort is the right
    /// trade. Thinking is deliberately left at the model's default rather than disabled:
    /// disabling it on Opus 5 is a documented source of format irregularities, including tool
    /// calls emitted as plain text, which is exactly the failure this code cannot detect.
    public static let `default` = ParserConfiguration(provider: .anthropic)

    public init(
        provider: LLMProvider,
        model: String? = nil,
        effort: String = "low",
        maxTokens: Int = 2048
    ) {
        self.provider = provider
        self.model = model ?? provider.defaultModel
        self.effort = effort
        self.maxTokens = maxTokens
    }

    /// Anthropic with an overridden endpoint.
    ///
    /// Kept because pointing the parser at a recording proxy or a test double is worth one line,
    /// and because it is the shape the app used before providers were configurable.
    public init(model: String, effort: String, maxTokens: Int, baseURL: URL) {
        var provider = LLMProvider.anthropic
        provider.endpoint = baseURL
        self.init(provider: provider, model: model, effort: effort, maxTokens: maxTokens)
    }

    /// Where requests go. Shown in Settings, because a screen that asks for a credential should
    /// name the host it will be sent to.
    public var host: String { provider.host }
}

/// Turns words or a photo into food and exercise numbers, using any configured provider.
///
/// All the vendor-specific work — request shape, error codes, whether a JSON Schema can be sent
/// natively — lives in `LLMWire`. What is left here is the part that is actually about nutrition:
/// the prompt, the schema, and the judgement about which returned numbers are plausible enough
/// to keep.
public struct LLMNutritionParser: NutritionParser {
    private let transport: any HTTPTransport
    private let keyStore: any APIKeyStore
    private let configuration: ParserConfiguration

    /// Names the schema in the request. Cosmetic at every provider, but it appears in OpenAI's
    /// error messages, where "nutrition_log" beats "response".
    static let schemaName = "nutrition_log"

    public init(
        transport: any HTTPTransport,
        keyStore: any APIKeyStore,
        configuration: ParserConfiguration = .default
    ) {
        self.transport = transport
        self.keyStore = keyStore
        self.configuration = configuration
    }

    public func parse(_ input: ParseInput, context: ParseContext) async throws -> ParseResult {
        let client = ChatClient(
            provider: configuration.provider,
            model: configuration.model,
            transport: transport
        )

        // Read at the moment of use so a key is never held in memory longer than one call.
        let key = try keyStore.apiKey()

        let request = ChatRequest(
            system: ParsePrompt.system,
            content: Self.content(for: input, context: context),
            jsonSchema: JSONSchema(name: Self.schemaName, schema: ParsePrompt.outputSchema),
            maxTokens: configuration.maxTokens,
            effort: ChatRequest.Effort(rawValue: configuration.effort)
        )

        do {
            let reply = try await client.complete(request, apiKey: key)
            return try Self.result(fromJSON: reply.text)
        } catch let error as LLMError {
            throw NutritionParserError(error, provider: configuration.provider.displayName)
        }
    }

    // MARK: Request

    /// Image first, then the instruction. Both Anthropic and OpenAI give better results with an
    /// image placed before the text that refers to it.
    static func content(for input: ParseInput, context: ParseContext) -> [ContentPart] {
        var content: [ContentPart] = []

        if case .image(let data, let mediaType, _) = input {
            content.append(
                .image(data: data, mediaType: ImageMediaType(rawValue: mediaType.rawValue) ?? .jpeg)
            )
        }

        content.append(.text(ParsePrompt.userInstruction(for: input, context: context)))
        return content
    }

    // MARK: Response

    public static func result(fromJSON json: String) throws -> ParseResult {
        let payload: ParsePayload
        do {
            payload = try JSONDecoder().decode(ParsePayload.self, from: Data(json.utf8))
        } catch {
            throw NutritionParserError.malformedResponse(
                "Reply did not match the requested schema: \(error)"
            )
        }

        let note = payload.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = payload.items.compactMap(item(from:))

        guard !items.isEmpty else {
            throw NutritionParserError.nothingRecognized(note?.isEmpty == false ? note : nil)
        }

        return ParseResult(items: items, note: note?.isEmpty == false ? note : nil)
    }

    /// Converts one wire item, or drops it.
    ///
    /// Returns nil for items that cannot be made sensible — an unknown `kind`, a blank label, a
    /// negative or absurd calorie count. The schema cannot express numeric bounds, so this is
    /// where they're enforced; and dropping a single bad item is better than failing the whole
    /// log when the other three were fine.
    ///
    /// It matters more now than it did with one provider. Under
    /// ``StructuredOutputStyle/jsonObject`` and ``StructuredOutputStyle/prompt`` nothing enforces
    /// the schema at all, so a model that returns a string where a number belongs, or invents a
    /// fourth `kind`, is a routine outcome rather than a broken provider.
    static func item(from wire: WireItem) -> ParsedItem? {
        guard let kind = Entry.Kind(rawValue: wire.kind) else { return nil }

        let label = wire.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }

        // A day's eating tops out well below this; anything beyond is a decimal-point error,
        // and silently logging 40,000 calories would wreck the trend the goal engine reads.
        let calories = wire.calories
        guard calories >= 0, calories <= 20000 else { return nil }

        let exerciseKind: ExerciseKind? = switch kind {
        case .exercise: ExerciseKind(rawValue: wire.exerciseKind) ?? .other
        case .food: nil
        }

        return ParsedItem(
            kind: kind,
            label: label,
            calories: calories,
            proteinGrams: kind == .food ? max(0, min(wire.proteinGrams, 1000)) : 0,
            fiberGrams: kind == .food ? max(0, min(wire.fiberGrams, 1000)) : 0,
            exerciseKind: exerciseKind,
            durationMinutes: wire.durationMinutes > 0 ? wire.durationMinutes : nil,
            confidence: ParseConfidence(rawValue: wire.confidence) ?? .low
        )
    }

    // MARK: Wire types

    struct ParsePayload: Decodable {
        var items: [WireItem]
        var note: String?
    }

    /// Every field is decoded leniently, because only one of the three structured-output styles
    /// guarantees the reply matches the schema. A missing `fiberGrams` or a `calories` that
    /// arrived as `"280"` should cost one field, not the whole meal.
    struct WireItem: Decodable {
        var kind: String
        var label: String
        var calories: Int
        var proteinGrams: Double
        var fiberGrams: Double
        var exerciseKind: String
        var durationMinutes: Int
        var confidence: String

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decodeLenient(String.self, forKey: .kind) ?? ""
            label = try container.decodeLenient(String.self, forKey: .label) ?? ""
            calories = try container.decodeLenient(Int.self, forKey: .calories) ?? 0
            proteinGrams = try container.decodeLenient(Double.self, forKey: .proteinGrams) ?? 0
            fiberGrams = try container.decodeLenient(Double.self, forKey: .fiberGrams) ?? 0
            exerciseKind = try container.decodeLenient(String.self, forKey: .exerciseKind)
                ?? ParsePrompt.noExerciseKind
            durationMinutes = try container.decodeLenient(Int.self, forKey: .durationMinutes) ?? 0
            confidence = try container.decodeLenient(String.self, forKey: .confidence) ?? "low"
        }

        enum CodingKeys: String, CodingKey {
            case kind, label, calories, proteinGrams, fiberGrams
            case exerciseKind, durationMinutes, confidence
        }
    }
}

/// Decoding that survives a model's idea of a number.
///
/// Models under JSON-mode-only providers return `"280"`, `280.0` and `280` interchangeably for
/// the same field, and a strict decoder turns any of those into a total failure of a meal the
/// user has already described correctly.
extension KeyedDecodingContainer {
    fileprivate func decodeLenient(_: String.Type, forKey key: Key) throws -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        return nil
    }

    fileprivate func decodeLenient(_: Int.Type, forKey key: Key) throws -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value.rounded()) }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return Int(text) ?? Double(text).map { Int($0.rounded()) }
        }
        return nil
    }

    fileprivate func decodeLenient(_: Double.Type, forKey key: Key) throws -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }
}
