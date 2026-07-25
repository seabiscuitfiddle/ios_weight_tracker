import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Which model to use and how hard to make it think.
public struct ParserConfiguration: Hashable, Sendable {
    /// Model identifier. Settings exposes this so a user can trade cost for quality.
    public var model: String
    /// Effort level passed in `output_config`.
    public var effort: String
    public var maxTokens: Int
    public var baseURL: URL

    /// Models offered in Settings, best first.
    public static let availableModels = ["claude-opus-5", "claude-haiku-4-5"]

    /// The default: a capable model at low effort.
    ///
    /// Extracting numbers from "two eggs and toast" is not an intelligence-limited task, and
    /// someone standing in their kitchen is waiting on the answer — so low effort is the right
    /// trade. Thinking is deliberately left at the model's default rather than disabled:
    /// disabling it on Opus 5 is a documented source of format irregularities, including tool
    /// calls emitted as plain text, which is exactly the failure this code cannot detect.
    public static let `default` = ParserConfiguration(
        model: "claude-opus-5",
        effort: "low",
        maxTokens: 2048,
        baseURL: URL(string: "https://api.anthropic.com/v1/messages")!
    )

    public init(model: String, effort: String, maxTokens: Int, baseURL: URL) {
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
        self.baseURL = baseURL
    }
}

/// Parses food and exercise using the Anthropic Messages API.
///
/// Raw HTTP rather than an SDK, because there is no official Anthropic Swift SDK. That is not
/// much of a loss here: the request is one JSON document, and going direct means the app carries
/// no third-party networking dependency and the exact wire format stays visible and testable.
public struct AnthropicNutritionParser: NutritionParser {
    private let transport: any HTTPTransport
    private let keyStore: any APIKeyStore
    private let configuration: ParserConfiguration

    /// The version of the Messages API this code is written against.
    static let apiVersion = "2023-06-01"

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
        guard let apiKey = try keyStore.apiKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty
        else { throw NutritionParserError.missingAPIKey }

        let request = try makeRequest(input: input, context: context, apiKey: apiKey)
        let response = try await transport.send(request)
        return try Self.result(from: response)
    }

    // MARK: Request

    func makeRequest(input: ParseInput, context: ParseContext, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try Self.body(input: input, context: context, configuration: configuration)
        return request
    }

    /// Builds the request body.
    ///
    /// Assembled as a dictionary and serialised rather than modelled with `Codable` types. The
    /// body is a wire format, not domain data, and its awkward part — a JSON Schema nested
    /// inside the request — is far clearer embedded as reviewable JSON than expressed through
    /// a tower of `Encodable` wrappers.
    static func body(
        input: ParseInput,
        context: ParseContext,
        configuration: ParserConfiguration
    ) throws -> Data {
        guard let schema = try JSONSerialization.jsonObject(
            with: Data(ParsePrompt.outputSchema.utf8)
        ) as? [String: Any] else {
            throw NutritionParserError.malformedResponse("Built-in output schema is not valid JSON.")
        }

        var content: [[String: Any]] = []

        // Image first, then the instruction. Anthropic's guidance is that images placed before
        // the text they relate to give better results.
        if case .image(let data, let mediaType, _) = input {
            content.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": mediaType.rawValue,
                    "data": data.base64EncodedString(),
                ],
            ])
        }

        content.append([
            "type": "text",
            "text": ParsePrompt.userInstruction(for: input, context: context),
        ])

        let body: [String: Any] = [
            "model": configuration.model,
            "max_tokens": configuration.maxTokens,
            // Marked cacheable because the prompt and schema are byte-identical on every
            // request. Below the model's minimum cacheable length this is simply ignored, so
            // it costs nothing and pays off if the instructions grow.
            "system": [[
                "type": "text",
                "text": ParsePrompt.system,
                "cache_control": ["type": "ephemeral"],
            ]],
            "output_config": [
                "effort": configuration.effort,
                "format": ["type": "json_schema", "schema": schema],
            ],
            "messages": [["role": "user", "content": content]],
        ]

        // Sorted keys keep the serialisation deterministic, which makes the cached prefix
        // stable and lets tests assert on the body without depending on dictionary order.
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    // MARK: Response

    static func result(from response: HTTPResponse) throws -> ParseResult {
        guard (200..<300).contains(response.statusCode) else {
            throw error(from: response)
        }

        let envelope: MessageResponse
        do {
            envelope = try JSONDecoder().decode(MessageResponse.self, from: response.body)
        } catch {
            throw NutritionParserError.malformedResponse(
                "Reply was not a Messages API response: \(error)"
            )
        }

        // Checked before reading `content`, which is empty on a pre-output refusal — indexing it
        // first would crash on a perfectly ordinary HTTP 200.
        if envelope.stopReason == "refusal" {
            throw NutritionParserError.refused(envelope.stopDetails?.explanation)
        }
        if envelope.stopReason == "max_tokens" {
            throw NutritionParserError.truncated
        }

        guard let json = envelope.content.first(where: { $0.type == "text" })?.text,
              !json.isEmpty
        else {
            throw NutritionParserError.malformedResponse("Reply contained no text block.")
        }

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

    static func error(from response: HTTPResponse) -> NutritionParserError {
        let message = (try? JSONDecoder().decode(ErrorResponse.self, from: response.body))?
            .error.message

        return switch response.statusCode {
        case 401, 403:
            .invalidAPIKey
        case 413:
            .requestTooLarge
        case 429:
            .rateLimited(retryAfter: response.header("retry-after").flatMap(TimeInterval.init))
        case 529:
            .overloaded
        default:
            .serverError(status: response.statusCode, message: message)
        }
    }

    // MARK: Wire types

    struct MessageResponse: Decodable {
        var content: [ContentBlock]
        var stopReason: String?
        var stopDetails: StopDetails?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
        }

        struct ContentBlock: Decodable {
            var type: String
            var text: String?
        }

        struct StopDetails: Decodable {
            var explanation: String?
        }
    }

    struct ParsePayload: Decodable {
        var items: [WireItem]
        var note: String?
    }

    struct WireItem: Decodable {
        var kind: String
        var label: String
        var calories: Int
        var proteinGrams: Double
        var fiberGrams: Double
        var exerciseKind: String
        var durationMinutes: Int
        var confidence: String
    }

    struct ErrorResponse: Decodable {
        var error: Payload
        struct Payload: Decodable {
            var type: String?
            var message: String?
        }
    }
}
