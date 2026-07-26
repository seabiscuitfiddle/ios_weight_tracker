import Foundation

/// Encoding and decoding for the OpenAI Chat Completions format.
///
/// The important one, because it is no longer only OpenAI's. Chat Completions became the shape
/// every later provider implemented — OpenRouter, DeepSeek, Moonshot, Zhipu, Alibaba, MiniMax,
/// Groq, Together, Ollama, LM Studio — so this single codec plus a base URL reaches almost
/// everything. Where they diverge, they diverge in small documented ways that ``LLMProvider``
/// declares rather than in the message structure itself.
enum OpenAIWire {
    // MARK: Request

    static func body(
        _ request: ChatRequest,
        model: String,
        provider: LLMProvider
    ) throws -> Data {
        var content: [[String: Any]] = []

        for part in request.content {
            switch part {
            case .image(let data, let mediaType):
                // Chat Completions takes an image as a data: URI in an `image_url` part, which
                // looks odd but is the documented way to send bytes rather than a hosted link.
                content.append([
                    "type": "image_url",
                    "image_url": [
                        "url": "data:\(mediaType.rawValue);base64,\(data.base64EncodedString())"
                    ],
                ])
            case .text(let text):
                content.append(["type": "text", "text": text])
            }
        }

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": request.system],
                ["role": "user", "content": content],
            ],
        ]

        body[provider.usesMaxCompletionTokens ? "max_completion_tokens" : "max_tokens"] =
            request.maxTokens

        // Gated on the model as well as the provider: `reasoning_effort` is a reasoning-model
        // field, and the same endpoint serves models that reject it.
        if let effort = request.effort,
           let value = provider.effortValue(effort, model: model) {
            body["reasoning_effort"] = value
        }

        if let temperature = request.temperature {
            body["temperature"] = temperature
        }

        if let schema = request.jsonSchema {
            switch provider.structuredOutput {
            case .jsonSchema:
                body["response_format"] = [
                    "type": "json_schema",
                    "json_schema": [
                        "name": sanitisedName(schema.name),
                        // Without `strict` the schema is treated as a hint and the reply may
                        // quietly omit fields — the failure this whole path exists to prevent.
                        "strict": true,
                        "schema": try schema.object(),
                    ],
                ]
            case .jsonObject:
                // Guarantees valid JSON but ignores the schema, which `ChatClient` has already
                // put in the system prompt.
                body["response_format"] = ["type": "json_object"]
            case .prompt:
                break
            }
        }

        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    /// Schema names are restricted to `[a-zA-Z0-9_-]`, and a request rejected for a stray space
    /// in a name the user never sees would be a maddening thing to diagnose.
    static func sanitisedName(_ name: String) -> String {
        let cleaned = String(name.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
        return cleaned.isEmpty ? "response" : cleaned
    }

    static func headers(apiKey: String, provider: LLMProvider) -> [String: String] {
        var headers = ["Content-Type": "application/json"]
        // Local runners commonly accept no key at all, so an empty one is left off rather than
        // sent as `Bearer ` — which some of them reject outright.
        if !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        for (name, value) in provider.extraHeaders {
            headers[name] = value
        }
        return headers
    }

    // MARK: Response

    static func response(from response: HTTPResponse) throws -> ChatResponse {
        guard (200..<300).contains(response.statusCode) else {
            throw error(from: response)
        }

        let envelope: Completion
        do {
            envelope = try JSONDecoder().decode(Completion.self, from: response.body)
        } catch {
            // A compatible-mode endpoint that is misconfigured, or a proxy in the way, will
            // happily return HTML with a 200. Naming the wire format we expected is what makes
            // that diagnosable.
            throw LLMError.malformedResponse(
                "Reply was not a Chat Completions response: \(error)"
            )
        }

        guard let choice = envelope.choices.first else {
            throw LLMError.malformedResponse("Reply contained no choices.")
        }

        // A refusal is its own field here rather than a stop reason, and it is populated while
        // `content` is null — so reading content first turns a clear refusal into a confusing
        // "empty reply".
        if let refusal = choice.message.refusal, !refusal.isEmpty {
            throw LLMError.refused(refusal)
        }

        let stop: ChatResponse.StopReason = switch choice.finishReason {
        case "length": .maxTokens
        case "content_filter": .refusal(nil)
        case "stop", nil: .stop
        case .some(let other): .other(other)
        }

        if case .refusal(let explanation) = stop { throw LLMError.refused(explanation) }
        if case .maxTokens = stop { throw LLMError.truncated }

        guard let text = choice.message.content, !text.isEmpty else {
            throw LLMError.malformedResponse("Reply contained no message content.")
        }

        return ChatResponse(
            text: text,
            stop: stop,
            usage: envelope.usage.map {
                ChatResponse.Usage(
                    inputTokens: $0.promptTokens ?? 0,
                    outputTokens: $0.completionTokens ?? 0
                )
            }
        )
    }

    static func error(from response: HTTPResponse) -> LLMError {
        let payload = try? JSONDecoder().decode(ErrorResponse.self, from: response.body)
        let message = payload?.error.message
        let code = payload?.error.code ?? payload?.error.type

        // Checked before the status, because the same status means different things at different
        // providers and the code is the more reliable signal when one is present.
        switch code {
        case "insufficient_quota", "billing_hard_limit_reached", "credit_limit_exceeded":
            return .insufficientCredit(message)
        case "model_not_found", "invalid_model", "model_terminated":
            return .unknownModel(message ?? "That model was not found.")
        case "context_length_exceeded", "string_above_max_length":
            return .requestTooLarge
        default:
            break
        }

        return switch response.statusCode {
        case 401:
            .invalidAPIKey
        case 402:
            // OpenRouter's out-of-credit status.
            .insufficientCredit(message)
        case 403:
            // Also the region-blocked status at several providers, so the server's own wording is
            // worth more than anything this code could invent.
            message.map { LLMError.serverError(status: 403, message: $0) } ?? .invalidAPIKey
        case 404:
            .unknownModel(message ?? "That model was not found at this provider.")
        case 413:
            .requestTooLarge
        case 429:
            .rateLimited(retryAfter: response.header("retry-after").flatMap(TimeInterval.init))
        case 502, 503, 529:
            .overloaded
        default:
            .serverError(status: response.statusCode, message: message)
        }
    }

    // MARK: Wire types

    struct Completion: Decodable {
        var choices: [Choice]
        var usage: Usage?

        struct Choice: Decodable {
            var message: Message
            var finishReason: String?

            enum CodingKeys: String, CodingKey {
                case message
                case finishReason = "finish_reason"
            }

            struct Message: Decodable {
                var content: String?
                var refusal: String?
                /// Reasoning models at several providers put the answer in `content` and their
                /// working here. Decoded but unused: it is worth knowing the field exists so a
                /// future caller can surface it, and ignoring an unknown key silently is how you
                /// end up debugging an "empty" reply that wasn't.
                var reasoningContent: String?

                enum CodingKeys: String, CodingKey {
                    case content, refusal
                    case reasoningContent = "reasoning_content"
                }
            }
        }

        struct Usage: Decodable {
            var promptTokens: Int?
            var completionTokens: Int?

            enum CodingKeys: String, CodingKey {
                case promptTokens = "prompt_tokens"
                case completionTokens = "completion_tokens"
            }
        }
    }

    /// Providers differ on whether `code` is a string, a number, or absent, so it is decoded
    /// leniently rather than allowed to fail the whole error path — an error while decoding an
    /// error is the worst possible time to lose the message.
    struct ErrorResponse: Decodable {
        var error: Payload

        struct Payload: Decodable {
            var message: String?
            var type: String?
            var code: String?

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                message = try container.decodeIfPresent(String.self, forKey: .message)
                type = try container.decodeIfPresent(String.self, forKey: .type)
                if let string = try? container.decodeIfPresent(String.self, forKey: .code) {
                    code = string
                } else if let number = try? container.decodeIfPresent(Int.self, forKey: .code) {
                    code = String(number)
                }
            }

            enum CodingKeys: String, CodingKey {
                case message, type, code
            }
        }
    }
}
