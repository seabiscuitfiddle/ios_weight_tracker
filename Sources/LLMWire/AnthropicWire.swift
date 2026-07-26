import Foundation

/// Encoding and decoding for Anthropic's Messages API.
///
/// Raw JSON rather than an SDK. The request is one document, going direct means no third-party
/// networking dependency, and — the part that matters for a library like this — the exact wire
/// format stays visible and assertable in tests.
enum AnthropicWire {
    /// The version of the Messages API this code is written against.
    static let apiVersion = "2023-06-01"

    // MARK: Request

    /// Builds the request body.
    ///
    /// Assembled as a dictionary and serialised rather than modelled with `Codable` types. The
    /// body is a wire format, not domain data, and its awkward part — a JSON Schema nested inside
    /// the request — is far clearer embedded as reviewable JSON than expressed through a tower of
    /// `Encodable` wrappers.
    static func body(
        _ request: ChatRequest,
        model: String,
        provider: LLMProvider
    ) throws -> Data {
        var content: [[String: Any]] = []

        for part in request.content {
            switch part {
            case .image(let data, let mediaType):
                content.append([
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": mediaType.rawValue,
                        "data": data.base64EncodedString(),
                    ],
                ])
            case .text(let text):
                content.append(["type": "text", "text": text])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": request.maxTokens,
            // Marked cacheable because the system prompt is byte-identical on every request.
            // Below the model's minimum cacheable length this is simply ignored, so it costs
            // nothing and pays off if the instructions grow.
            "system": [[
                "type": "text",
                "text": request.system,
                "cache_control": ["type": "ephemeral"],
            ]],
            "messages": [["role": "user", "content": content]],
        ]

        var outputConfig: [String: Any] = [:]
        // Only for models that publish an effort level. Sonnet 4.5, every Haiku so far, and all
        // of Claude 3 reject `output_config.effort` outright, and the caller picked the model
        // from a free-text field — so this is decided from the identifier, not assumed.
        if let effort = request.effort,
           let value = provider.effortValue(effort, model: model) {
            outputConfig["effort"] = value
        }
        // Only the native path sets a format here. Under the other styles the schema has already
        // been folded into the system prompt by `ChatClient`, and sending it twice would waste
        // tokens on instructions the model has read once already.
        if let schema = request.jsonSchema, provider.structuredOutput == .jsonSchema {
            outputConfig["format"] = ["type": "json_schema", "schema": try schema.object()]
        }
        if !outputConfig.isEmpty {
            body["output_config"] = outputConfig
        }

        if let temperature = request.temperature {
            body["temperature"] = temperature
        }

        // Sorted keys keep the serialisation deterministic, which makes the cached prefix stable
        // and lets tests assert on the body without depending on dictionary order.
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func headers(apiKey: String) -> [String: String] {
        [
            "Content-Type": "application/json",
            "x-api-key": apiKey,
            "anthropic-version": apiVersion,
        ]
    }

    // MARK: Response

    static func response(from response: HTTPResponse) throws -> ChatResponse {
        guard (200..<300).contains(response.statusCode) else {
            throw error(from: response)
        }

        let envelope: MessageResponse
        do {
            envelope = try JSONDecoder().decode(MessageResponse.self, from: response.body)
        } catch {
            throw LLMError.malformedResponse("Reply was not a Messages API response: \(error)")
        }

        // Checked before reading `content`, which is empty on a pre-output refusal — indexing it
        // first would crash on a perfectly ordinary HTTP 200.
        let stop: ChatResponse.StopReason = switch envelope.stopReason {
        case "refusal": .refusal(envelope.stopDetails?.explanation)
        case "max_tokens": .maxTokens
        case "end_turn", "stop_sequence", nil: .stop
        case .some(let other): .other(other)
        }

        if case .refusal(let explanation) = stop { throw LLMError.refused(explanation) }
        if case .maxTokens = stop { throw LLMError.truncated }

        guard let text = envelope.content.first(where: { $0.type == "text" })?.text,
              !text.isEmpty
        else {
            throw LLMError.malformedResponse("Reply contained no text block.")
        }

        return ChatResponse(
            text: text,
            stop: stop,
            usage: envelope.usage.map {
                ChatResponse.Usage(inputTokens: $0.inputTokens, outputTokens: $0.outputTokens)
            }
        )
    }

    static func error(from response: HTTPResponse) -> LLMError {
        let payload = try? JSONDecoder().decode(ErrorResponse.self, from: response.body)
        let message = payload?.error.message
        let type = payload?.error.type

        return switch response.statusCode {
        case 401, 403:
            .invalidAPIKey
        case 402:
            .insufficientCredit(message)
        case 404:
            .unknownModel(message ?? "That model was not found.")
        case 413:
            .requestTooLarge
        case 429:
            // Anthropic reports an exhausted balance as a 429 with a distinct type, and telling
            // someone to wait when the fix is to top up would send them in circles.
            type == "billing_error"
                ? .insufficientCredit(message)
                : .rateLimited(retryAfter: response.header("retry-after").flatMap(TimeInterval.init))
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
        var usage: Usage?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
            case usage
        }

        struct ContentBlock: Decodable {
            var type: String
            var text: String?
        }

        struct StopDetails: Decodable {
            var explanation: String?
        }

        struct Usage: Decodable {
            var inputTokens: Int
            var outputTokens: Int

            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }

    struct ErrorResponse: Decodable {
        var error: Payload
        struct Payload: Decodable {
            var type: String?
            var message: String?
        }
    }
}
