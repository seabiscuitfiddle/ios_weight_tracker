import Foundation
import Testing
@testable import LLMWire

/// Failures are where providers differ most, and where a unified library is most tempted to
/// flatten everything into "request failed". These check that the distinctions a caller needs to
/// act on — retry, wait, pay, fix a key, pick another model — survive the translation from two
/// unrelated error formats.
@Suite("Anthropic error mapping")
struct AnthropicErrorTests {
    private func client(_ transport: StubTransport) -> ChatClient {
        ChatClient(provider: .anthropic, model: "claude-opus-5", transport: transport)
    }

    private func anthropicError(_ type: String, _ message: String) -> String {
        #"{"type":"error","error":{"type":"\#(type)","message":"\#(message)"}}"#
    }

    /// A refusal arrives as HTTP 200 with an empty content array. Code that reads `content[0]`
    /// before checking `stop_reason` crashes on a perfectly ordinary response.
    @Test("handles a refusal before touching the content array")
    func refusal() async throws {
        let transport = StubTransport(json: """
            {
              "id": "msg_01ABC", "type": "message", "role": "assistant",
              "model": "claude-opus-5", "stop_reason": "refusal",
              "stop_details": { "type": "refusal", "explanation": "Declined." },
              "content": [], "usage": { "input_tokens": 600, "output_tokens": 0 }
            }
            """)

        await #expect(throws: LLMError.refused("Declined.")) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    @Test("reports a truncated reply rather than a decode failure")
    func truncated() async throws {
        let transport = StubTransport(
            json: Recorded.anthropic(#"{"items":[{"label":"Ri"#, stopReason: "max_tokens")
        )

        await #expect(throws: LLMError.truncated) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    @Test("maps auth failures to an invalid key", arguments: [401, 403])
    func invalidKey(_ status: Int) async throws {
        let transport = StubTransport(
            status: status, json: anthropicError("authentication_error", "invalid x-api-key")
        )

        await #expect(throws: LLMError.invalidAPIKey) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    @Test("reads retry-after off a rate limit, whatever its capitalisation")
    func rateLimited() async throws {
        for header in ["retry-after", "Retry-After"] {
            let transport = StubTransport(
                status: 429,
                json: anthropicError("rate_limit_error", "slow down"),
                headers: [header: "42"]
            )

            await #expect(throws: LLMError.rateLimited(retryAfter: 42)) {
                try await client(transport).complete(testRequest(), apiKey: "k")
            }
        }
    }

    @Test("handles a rate limit with no retry-after header")
    func rateLimitedWithoutHeader() async throws {
        let transport = StubTransport(
            status: 429, json: anthropicError("rate_limit_error", "slow down")
        )

        await #expect(throws: LLMError.rateLimited(retryAfter: nil)) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    /// An exhausted balance also arrives as a 429 here. Telling someone to wait when the fix is
    /// to top up sends them in circles.
    @Test("separates an exhausted balance from a rate limit")
    func billingError() async throws {
        let transport = StubTransport(
            status: 429, json: anthropicError("billing_error", "credit balance is too low")
        )

        await #expect(throws: LLMError.insufficientCredit("credit balance is too low")) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    @Test("maps 529 to overloaded and 413 to too-large")
    func otherStatuses() async throws {
        await #expect(throws: LLMError.overloaded) {
            try await client(StubTransport(status: 529, json: "{}")).complete(
                testRequest(), apiKey: "k"
            )
        }
        await #expect(throws: LLMError.requestTooLarge) {
            try await client(StubTransport(status: 413, json: "{}")).complete(
                testRequest(), apiKey: "k"
            )
        }
    }

    @Test("carries the server's message on an unexpected status")
    func serverError() async throws {
        let transport = StubTransport(status: 500, json: anthropicError("api_error", "internal"))

        await #expect(throws: LLMError.serverError(status: 500, message: "internal")) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    @Test("reports an unreadable reply rather than crashing")
    func malformed() async throws {
        await #expect(throws: LLMError.self) {
            try await client(StubTransport(status: 200, json: "not json at all"))
                .complete(testRequest(), apiKey: "k")
        }
        await #expect(throws: LLMError.self) {
            try await client(StubTransport(status: 200, json: """
                {"id":"msg_1","type":"message","role":"assistant","stop_reason":"end_turn",
                 "content":[],"usage":{"input_tokens":1,"output_tokens":1}}
                """)).complete(testRequest(), apiKey: "k")
        }
    }
}

@Suite("OpenAI-compatible error mapping")
struct OpenAIErrorTests {
    private func client(
        _ transport: StubTransport,
        provider: LLMProvider = .openAI
    ) -> ChatClient {
        ChatClient(provider: provider, model: "gpt-5.2-mini", transport: transport)
    }

    private func openAIError(message: String, type: String, code: String?) -> String {
        let codeField = code.map { #""code":"\#($0)""# } ?? #""code":null"#
        return #"{"error":{"message":"\#(message)","type":"\#(type)",\#(codeField)}}"#
    }

    @Test("maps 401 to an invalid key")
    func invalidKey() async throws {
        let transport = StubTransport(
            status: 401,
            json: openAIError(
                message: "Incorrect API key provided",
                type: "invalid_request_error",
                code: "invalid_api_key"
            )
        )

        await #expect(throws: LLMError.invalidAPIKey) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    /// OpenAI reports an empty balance as a 429, which would otherwise be read as "wait a
    /// moment" — advice that never comes true.
    @Test("reads insufficient quota out of a 429")
    func insufficientQuota() async throws {
        let transport = StubTransport(
            status: 429,
            json: openAIError(
                message: "You exceeded your current quota",
                type: "insufficient_quota",
                code: "insufficient_quota"
            )
        )

        await #expect(throws: LLMError.insufficientCredit("You exceeded your current quota")) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    /// OpenRouter's out-of-credit status, which no other provider in the list uses.
    @Test("maps OpenRouter's 402 to insufficient credit")
    func openRouterPaymentRequired() async throws {
        let transport = StubTransport(
            status: 402,
            json: openAIError(
                message: "Insufficient credits", type: "invalid_request_error", code: nil
            )
        )

        await #expect(throws: LLMError.insufficientCredit("Insufficient credits")) {
            try await client(transport, provider: .openRouter).complete(testRequest(), apiKey: "k")
        }
    }

    /// The model is free text, so a typo or a retired identifier is a routine outcome and
    /// deserves better than "the service had a problem".
    @Test("names an unknown model")
    func unknownModel() async throws {
        let transport = StubTransport(
            status: 404,
            json: openAIError(
                message: "The model 'gpt-9' does not exist",
                type: "invalid_request_error",
                code: "model_not_found"
            )
        )

        await #expect(throws: LLMError.unknownModel("The model 'gpt-9' does not exist")) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    @Test("treats an oversized context as too large, not as a server fault")
    func contextLengthExceeded() async throws {
        let transport = StubTransport(
            status: 400,
            json: openAIError(
                message: "maximum context length",
                type: "invalid_request_error",
                code: "context_length_exceeded"
            )
        )

        await #expect(throws: LLMError.requestTooLarge) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    @Test("maps gateway statuses to overloaded", arguments: [502, 503, 529])
    func overloaded(_ status: Int) async throws {
        await #expect(throws: LLMError.overloaded) {
            try await client(StubTransport(status: status, json: "{}"))
                .complete(testRequest(), apiKey: "k")
        }
    }

    /// A refusal is its own field here, populated while `content` is null, so reading content
    /// first turns a clear refusal into a confusing "empty reply".
    @Test("reads a refusal out of its own field")
    func refusal() async throws {
        let transport = StubTransport(
            json: Recorded.openAI("", refusal: "I can't help with that.")
        )

        await #expect(throws: LLMError.refused("I can't help with that.")) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    @Test("reports a length-limited reply as truncated")
    func truncated() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok"#, finishReason: "length"))

        await #expect(throws: LLMError.truncated) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    /// A misconfigured compatible-mode endpoint or a captive portal returns HTML with a 200.
    /// Saying which format was expected is what makes that diagnosable.
    @Test("reports an HTML reply as malformed rather than crashing")
    func htmlReply() async throws {
        let transport = StubTransport(status: 200, json: "<html><body>404</body></html>")

        await #expect(throws: LLMError.self) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }

    /// Providers disagree on whether `code` is a string or a number, and an error thrown while
    /// decoding an error is the worst possible time to lose the message.
    @Test("survives a numeric error code")
    func numericErrorCode() async throws {
        let transport = StubTransport(
            status: 500, json: #"{"error":{"message":"boom","type":"server_error","code":500}}"#
        )

        await #expect(throws: LLMError.serverError(status: 500, message: "boom")) {
            try await client(transport).complete(testRequest(), apiKey: "k")
        }
    }
}

@Suite("Key and model preconditions")
struct PreconditionTests {
    /// No key means no request at all — the client must not send an unauthenticated call and let
    /// the server say no.
    @Test("does not call a hosted provider without a key", arguments: [nil, "", "   ", "\n"])
    func requiresKey(_ key: String?) async throws {
        let transport = StubTransport(json: Recorded.anthropic(#"{"ok":true}"#))

        await #expect(throws: LLMError.missingAPIKey) {
            try await ChatClient(provider: .anthropic, model: "m", transport: transport)
                .complete(testRequest(), apiKey: key)
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("trims whitespace pasted around a key")
    func trimsKey() async throws {
        let transport = StubTransport(json: Recorded.anthropic(#"{"ok":true}"#))
        _ = try? await ChatClient(provider: .anthropic, model: "m", transport: transport)
            .complete(testRequest(), apiKey: "  sk-ant-test\n")

        #expect(transport.lastRequest?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
    }

    /// Reachable now that the model is free text: a custom provider saved before a model was
    /// picked would otherwise send an empty identifier and get an opaque 400 back.
    @Test("refuses to send without a model")
    func requiresModel() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))

        await #expect(throws: LLMError.self) {
            try await ChatClient(provider: .openAI, model: "  ", transport: transport)
                .complete(testRequest(), apiKey: "k")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("passes a transport failure through untouched")
    func transportFailure() async throws {
        let transport = StubTransport(error: LLMError.offline("no route to host"))

        await #expect(throws: LLMError.offline("no route to host")) {
            try await ChatClient(provider: .openAI, model: "m", transport: transport)
                .complete(testRequest(), apiKey: "k")
        }
    }

    @Test("classifies which errors are worth retrying")
    func retryClassification() {
        #expect(LLMError.rateLimited(retryAfter: nil).isRetryable)
        #expect(LLMError.overloaded.isRetryable)
        #expect(LLMError.offline("x").isRetryable)
        #expect(LLMError.truncated.isRetryable)

        #expect(LLMError.missingAPIKey.isRetryable == false)
        #expect(LLMError.invalidAPIKey.isRetryable == false)
        #expect(LLMError.insufficientCredit(nil).isRetryable == false)
        #expect(LLMError.unknownModel("x").isRetryable == false)
        #expect(LLMError.imagesUnsupported.isRetryable == false)
    }
}

@Suite("Provider definitions")
struct ProviderTests {
    /// The id is a persistence key and a keychain account name, so a collision would have one
    /// provider reading another's stored key.
    @Test("built-in ids are unique and every provider has a usable default")
    func builtInIntegrity() {
        let ids = LLMProvider.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)

        for provider in LLMProvider.builtIn {
            #expect(!provider.defaultModel.isEmpty)
            #expect(provider.suggestedModels.contains(provider.defaultModel))
            #expect(provider.endpoint.scheme == "https")
            #expect(provider.isBuiltIn)
        }
    }

    /// Users paste whichever form their provider's documentation showed them, and being wrong
    /// about it produces a bewildering 404.
    @Test("accepts a custom endpoint as either a base URL or a full path")
    func customEndpointForms() {
        let fromBase = LLMProvider.custom(baseURL: URL(string: "https://api.groq.com/openai/v1")!)
        #expect(
            fromBase.endpoint.absoluteString == "https://api.groq.com/openai/v1/chat/completions"
        )
        #expect(fromBase.modelsEndpoint?.absoluteString == "https://api.groq.com/openai/v1/models")

        let fromFull = LLMProvider.custom(
            baseURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!
        )
        #expect(fromFull.endpoint == fromBase.endpoint)
        #expect(fromFull.modelsEndpoint == fromBase.modelsEndpoint)
    }

    /// A custom provider outlives the version of the library that wrote it, and a field added
    /// later must not silently discard the user's endpoint on upgrade.
    @Test("decodes a persisted provider that predates newer fields")
    func lenientDecoding() throws {
        let stored = #"{"id":"custom","endpoint":"https://example.test/v1/chat/completions"}"#
        let provider = try JSONDecoder().decode(LLMProvider.self, from: Data(stored.utf8))

        #expect(provider.id == "custom")
        #expect(provider.endpoint.host == "example.test")
        #expect(provider.structuredOutput == .prompt)
        #expect(provider.isBuiltIn == false)
    }

    @Test("round-trips through Codable")
    func codableRoundTrip() throws {
        let original = LLMProvider.custom(
            baseURL: URL(string: "http://localhost:11434/v1")!,
            structuredOutput: .jsonObject,
            defaultModel: "llama3.2"
        )
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(LLMProvider.self, from: data) == original)
    }
}

@Suite("Model catalogue")
struct ModelCatalogTests {
    /// A hardcoded model list is wrong within months. Asking the provider is one request.
    @Test("lists the models a key can reach")
    func lists() async throws {
        let transport = StubTransport(json: """
            {"object":"list","data":[
              {"id":"gpt-5.2-mini","object":"model"},
              {"id":"gpt-4.1","object":"model"}
            ]}
            """)

        let models = try await ModelCatalog(transport: transport)
            .models(for: .openAI, apiKey: "k")

        #expect(models == ["gpt-4.1", "gpt-5.2-mini"])
        #expect(transport.lastRequest?.httpMethod == "GET")
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
    }

    @Test("authenticates a model listing the way the provider expects")
    func anthropicAuth() async throws {
        let transport = StubTransport(json: #"{"data":[{"id":"claude-opus-5"}]}"#)
        _ = try await ModelCatalog(transport: transport).models(for: .anthropic, apiKey: "k")

        #expect(transport.lastRequest?.value(forHTTPHeaderField: "x-api-key") == "k")
        #expect(transport.lastRequest?.value(forHTTPHeaderField: "anthropic-version") != nil)
    }

    /// So a caller can fall back to the suggested list rather than showing an empty picker.
    @Test("reports a provider that publishes no list")
    func noListingEndpoint() async throws {
        let transport = StubTransport(json: "{}")

        await #expect(throws: LLMError.self) {
            try await ModelCatalog(transport: transport).models(for: .zhipu, apiKey: "k")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("surfaces a rejected key rather than an empty list")
    func rejectedKey() async throws {
        let transport = StubTransport(
            status: 401, json: #"{"error":{"message":"bad key","type":"invalid_request_error"}}"#
        )

        await #expect(throws: LLMError.invalidAPIKey) {
            try await ModelCatalog(transport: transport).models(for: .openAI, apiKey: "nope")
        }
    }
}
