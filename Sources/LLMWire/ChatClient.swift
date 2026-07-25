import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one prompt to one provider.
///
/// The single entry point, and the place the awkward differences between providers are absorbed
/// so callers don't branch on vendor. Cheap to construct — hold a provider and a model, build one
/// of these per call if that's convenient.
public struct ChatClient: Sendable {
    public let provider: LLMProvider
    public let model: String
    private let transport: any HTTPTransport

    public init(provider: LLMProvider, model: String, transport: any HTTPTransport) {
        self.provider = provider
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    /// Sends `request` and returns the reply.
    ///
    /// - Parameter apiKey: The user's key. Trimmed before use, because a key pasted from a
    ///   console arrives with a trailing newline more often than not. May be empty only for
    ///   providers that don't need one — a local model runner.
    public func complete(_ request: ChatRequest, apiKey: String?) async throws -> ChatResponse {
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty || !provider.requiresAPIKey else {
            // No key means no request at all. Sending an unauthenticated call and letting the
            // server say no would waste a round trip and report a worse error.
            throw LLMError.missingAPIKey
        }

        guard !model.isEmpty else {
            throw LLMError.unknownModel("No model is selected for \(provider.displayName).")
        }

        guard provider.acceptsImages || !request.hasImage else {
            throw LLMError.imagesUnsupported
        }

        let prepared = adapt(request)
        let response = try await transport.send(try urlRequest(for: prepared, apiKey: key))

        var reply = try decode(response)
        if request.jsonSchema != nil {
            // Harmless when the provider enforced the schema, and the difference between working
            // and not when it merely promised to try.
            reply.text = JSONText.extract(from: reply.text)
        }
        return reply
    }

    // MARK: Adapting the request to the provider

    /// Folds the schema into the system prompt for providers that cannot carry it natively.
    ///
    /// The instruction is worded to satisfy two constraints at once. OpenAI's `json_object` mode
    /// *requires* the word "json" to appear somewhere in the messages and rejects the request
    /// otherwise — a rule DeepSeek and Qwen copied — and models given a schema without being told
    /// to skip the preamble will cheerfully write "Here's the JSON you asked for:" first.
    func adapt(_ request: ChatRequest) -> ChatRequest {
        guard let schema = request.jsonSchema,
              provider.structuredOutput.needsSchemaInPrompt
        else { return request }

        var adapted = request
        adapted.system = """
            \(request.system)

            Reply with a single json object and nothing else: no explanation before it, no \
            commentary after it, and no markdown code fence around it. The object must conform \
            to this JSON Schema, including every property listed as required:

            \(schema.schema)
            """
        return adapted
    }

    private func urlRequest(for request: ChatRequest, apiKey: String) throws -> URLRequest {
        var urlRequest = URLRequest(url: provider.endpoint)
        urlRequest.httpMethod = "POST"

        let headers: [String: String]
        switch provider.wireFormat {
        case .anthropicMessages:
            headers = AnthropicWire.headers(apiKey: apiKey)
            urlRequest.httpBody = try AnthropicWire.body(
                request, model: model, provider: provider
            )
        case .openAIChatCompletions:
            headers = OpenAIWire.headers(apiKey: apiKey, provider: provider)
            urlRequest.httpBody = try OpenAIWire.body(
                request, model: model, provider: provider
            )
        }

        for (name, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }

    private func decode(_ response: HTTPResponse) throws -> ChatResponse {
        switch provider.wireFormat {
        case .anthropicMessages: try AnthropicWire.response(from: response)
        case .openAIChatCompletions: try OpenAIWire.response(from: response)
        }
    }
}

extension LLMProvider {
    /// Whether a call without a key is worth refusing before it is sent.
    ///
    /// Every hosted provider needs one. A custom endpoint often does not — Ollama and LM Studio
    /// take no key at all — and demanding one there would block the configuration that most
    /// wants supporting.
    public var requiresAPIKey: Bool { isBuiltIn }
}
