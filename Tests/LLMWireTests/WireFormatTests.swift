import Foundation
import Testing
@testable import LLMWire

@Suite("Anthropic request construction")
struct AnthropicRequestTests {
    private func client(_ transport: StubTransport) -> ChatClient {
        ChatClient(provider: .anthropic, model: "claude-opus-5", transport: transport)
    }

    @Test("sends the documented headers")
    func headers() async throws {
        let transport = StubTransport(json: Recorded.anthropic(#"{"ok":true}"#))
        _ = try? await client(transport).complete(testRequest(), apiKey: "sk-ant-test")

        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test("carries the schema and effort in output_config")
    func structuredOutput() async throws {
        let transport = StubTransport(json: Recorded.anthropic(#"{"ok":true}"#))
        _ = try? await client(transport).complete(testRequest(), apiKey: "k")

        let body = try #require(transport.lastBody)
        let outputConfig = try #require(body["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "low")

        let format = try #require(outputConfig["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect((format["schema"] as? [String: Any])?["additionalProperties"] as? Bool == false)
    }

    /// Thinking must be absent, not disabled. Disabling it on recent models is a documented cause
    /// of format irregularities — including tool calls arriving as plain prose — which would look
    /// like a successful call that silently returned nothing usable.
    @Test("does not disable thinking")
    func doesNotDisableThinking() async throws {
        let transport = StubTransport(json: Recorded.anthropic(#"{"ok":true}"#))
        _ = try? await client(transport).complete(testRequest(), apiKey: "k")

        let body = try #require(transport.lastBody)
        #expect(body["thinking"] == nil)
    }

    @Test("marks the system prompt cacheable")
    func cacheableSystemPrompt() async throws {
        let transport = StubTransport(json: Recorded.anthropic(#"{"ok":true}"#))
        _ = try? await client(transport).complete(testRequest(), apiKey: "k")

        let body = try #require(transport.lastBody)
        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect(system[0]["text"] as? String == "You are terse.")
    }

    @Test("sends a photo as a base64 image block before the text")
    func imageBlock() async throws {
        let transport = StubTransport(json: Recorded.anthropic(#"{"ok":true}"#))
        let pixels = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])
        _ = try? await client(transport).complete(
            testRequest(text: "half eaten", image: pixels), apiKey: "k"
        )

        let body = try #require(transport.lastBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(messages[0]["role"] as? String == "user")
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "image")
        #expect(content[1]["type"] as? String == "text")

        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == pixels.base64EncodedString())
    }

    @Test("honours the configured model, endpoint and token ceiling")
    func honoursConfiguration() async throws {
        let transport = StubTransport(json: Recorded.anthropic(#"{"ok":true}"#))
        var provider = LLMProvider.anthropic
        provider.endpoint = URL(string: "https://example.test/v1/messages")!

        var request = testRequest(effort: .medium)
        request.maxTokens = 1024

        _ = try? await ChatClient(
            provider: provider, model: "claude-sonnet-4-6", transport: transport
        ).complete(request, apiKey: "k")

        let body = try #require(transport.lastBody)
        #expect(body["model"] as? String == "claude-sonnet-4-6")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(transport.lastRequest?.url?.host == "example.test")
    }

    /// The hint is a model capability, not an endpoint one. Sending it to a model that doesn't
    /// publish an effort level fails the whole request over a field the user never chose — and
    /// two of the three models in the shipped picker are in that position.
    @Test(
        "sends effort only to the models that publish a level",
        arguments: [
            ("claude-opus-5", "low"),
            ("claude-opus-4-5-20251101", "low"),
            ("claude-sonnet-5", "low"),
            ("claude-sonnet-4-6", "low"),
            ("claude-fable-5", "low"),
            ("claude-haiku-4-5", nil),
            ("claude-haiku-4-5-20251001", nil),
            ("claude-sonnet-4-5-20250929", nil),
            ("claude-sonnet-4-20250514", nil),
            ("claude-opus-4-1-20250805", nil),
            ("claude-opus-4-20250514", nil),
            ("claude-3-opus-20240229", nil),
            ("claude-3-5-sonnet-20241022", nil),
            ("some-local-model", nil),
        ] as [(String, String?)]
    )
    func effortPerModel(_ model: String, _ expected: String?) async throws {
        let transport = StubTransport(json: Recorded.anthropic(#"{"ok":true}"#))
        _ = try? await ChatClient(provider: .anthropic, model: model, transport: transport)
            .complete(testRequest(effort: .low), apiKey: "k")

        let body = try #require(transport.lastBody)
        let outputConfig = body["output_config"] as? [String: Any]
        #expect(outputConfig?["effort"] as? String == expected)
        // The schema still has to travel, whatever happened to the hint.
        #expect(outputConfig?["format"] != nil)
    }

    /// `minimal` is an OpenAI level. Stepping to the least thinking Anthropic *can* express is
    /// nearer the caller's intent than a rejected request.
    @Test("steps an effort level Anthropic doesn't publish down to one it does")
    func effortLevelClamped() async throws {
        let transport = StubTransport(json: Recorded.anthropic(#"{"ok":true}"#))
        _ = try? await client(transport).complete(testRequest(effort: .minimal), apiKey: "k")

        let body = try #require(transport.lastBody)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "low")
    }
}

@Suite("OpenAI-compatible request construction")
struct OpenAIRequestTests {
    private func client(
        _ transport: StubTransport,
        provider: LLMProvider = .openAI,
        model: String = "gpt-5.2-mini"
    ) -> ChatClient {
        ChatClient(provider: provider, model: model, transport: transport)
    }

    @Test("authenticates with a bearer token")
    func bearerAuth() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        _ = try? await client(transport).complete(testRequest(), apiKey: "sk-proj-test")

        let request = try #require(transport.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-proj-test")
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    }

    @Test("sends the system prompt as its own message")
    func systemMessage() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        _ = try? await client(transport).complete(testRequest(), apiKey: "k")

        let body = try #require(transport.lastBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "You are terse.")
        #expect(messages[1]["role"] as? String == "user")
    }

    @Test("requests a strict schema where the provider enforces one")
    func strictSchema() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        _ = try? await client(transport).complete(testRequest(), apiKey: "k")

        let body = try #require(transport.lastBody)
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")

        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(schema["name"] as? String == "test_schema")
        // Without `strict` the schema is a hint and fields go quietly missing — the exact failure
        // this path exists to prevent.
        #expect(schema["strict"] as? Bool == true)
        #expect((schema["schema"] as? [String: Any])?["type"] as? String == "object")
    }

    /// OpenAI's newer models reject `max_tokens` outright, and most compatible-mode endpoints
    /// never implemented `max_completion_tokens`. No single field works everywhere.
    @Test("names the token ceiling the way each provider expects")
    func tokenCeilingField() async throws {
        let openAI = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        _ = try? await client(openAI).complete(testRequest(), apiKey: "k")
        let openAIBody = try #require(openAI.lastBody)
        #expect(openAIBody["max_completion_tokens"] as? Int == 2048)
        #expect(openAIBody["max_tokens"] == nil)

        let deepSeek = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        _ = try? await client(deepSeek, provider: .deepSeek, model: "deepseek-chat")
            .complete(testRequest(), apiKey: "k")
        let deepSeekBody = try #require(deepSeek.lastBody)
        #expect(deepSeekBody["max_tokens"] as? Int == 2048)
        #expect(deepSeekBody["max_completion_tokens"] == nil)
    }

    /// A compatible-mode endpoint that rejects unknown parameters would fail the whole request
    /// over a hint the user never asked for.
    @Test("sends reasoning effort only where it is supported")
    func reasoningEffort() async throws {
        let openAI = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        _ = try? await client(openAI).complete(testRequest(effort: .low), apiKey: "k")
        let openAIBody = try #require(openAI.lastBody)
        #expect(openAIBody["reasoning_effort"] as? String == "low")

        let deepSeek = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        _ = try? await client(deepSeek, provider: .deepSeek, model: "deepseek-chat")
            .complete(testRequest(effort: .low), apiKey: "k")
        let deepSeekBody = try #require(deepSeek.lastBody)
        #expect(deepSeekBody["reasoning_effort"] == nil)
    }

    /// `reasoning_effort` is a reasoning-model field, and OpenAI serves both kinds from the same
    /// URL — including the GPT-4.1 pair the model picker offers.
    @Test(
        "sends reasoning effort only to the models that take it",
        arguments: [
            ("gpt-5.2-mini", "low"),
            ("gpt-5", "low"),
            ("o3", "low"),
            ("o4-mini", "low"),
            ("gpt-4.1", nil),
            ("gpt-4.1-mini", nil),
            ("gpt-4o", nil),
        ] as [(String, String?)]
    )
    func reasoningEffortPerModel(_ model: String, _ expected: String?) async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        _ = try? await client(transport, model: model)
            .complete(testRequest(effort: .low), apiKey: "k")

        let body = try #require(transport.lastBody)
        #expect(body["reasoning_effort"] as? String == expected)
    }

    /// The one provider where the hint is safe to send blind: OpenRouter drops what the upstream
    /// model can't use rather than passing it through.
    @Test("sends reasoning effort to any model behind a normalising gateway")
    func reasoningEffortThroughGateway() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        _ = try? await client(transport, provider: .openRouter, model: "deepseek/deepseek-chat")
            .complete(testRequest(effort: .low), apiKey: "k")

        let body = try #require(transport.lastBody)
        #expect(body["reasoning_effort"] as? String == "low")
    }

    @Test("sends a photo as a data URI image part")
    func imagePart() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        let pixels = Data([0xFF, 0xD8, 0xFF, 0xE0])
        _ = try? await client(transport).complete(testRequest(image: pixels), apiKey: "k")

        let body = try #require(transport.lastBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "image_url")

        let url = try #require((content[0]["image_url"] as? [String: Any])?["url"] as? String)
        #expect(url == "data:image/jpeg;base64,\(pixels.base64EncodedString())")
    }

    /// Refusing before the request is sent turns an opaque provider 400 into a sentence that
    /// names the actual problem.
    @Test("refuses a photo for a text-only provider without sending it")
    func rejectsImagesUpFront() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))

        await #expect(throws: LLMError.imagesUnsupported) {
            try await client(transport, provider: .deepSeek, model: "deepseek-chat")
                .complete(testRequest(image: Data([0x01])), apiKey: "k")
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("sanitises a schema name the API would reject")
    func schemaNameSanitised() {
        #expect(OpenAIWire.sanitisedName("nutrition log!") == "nutrition_log_")
        #expect(OpenAIWire.sanitisedName("") == "response")
        #expect(OpenAIWire.sanitisedName("nutrition_log") == "nutrition_log")
    }

    /// Local model runners take no key, and several reject a bare `Bearer ` header outright.
    @Test("omits the authorization header when a custom endpoint has no key")
    func noKeyForLocalEndpoint() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        let ollama = LLMProvider.custom(baseURL: URL(string: "http://localhost:11434/v1")!)

        _ = try? await ChatClient(provider: ollama, model: "llama3.2", transport: transport)
            .complete(testRequest(), apiKey: nil)

        #expect(transport.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(
            transport.lastRequest?.url?.absoluteString
                == "http://localhost:11434/v1/chat/completions"
        )
    }
}

@Suite("Structured output portability")
struct StructuredOutputTests {
    /// The whole point of the ``StructuredOutputStyle`` declaration: the caller passes a schema
    /// once, and a provider that cannot carry it natively still gets told what shape to produce.
    @Test("puts the schema in the prompt when the API cannot carry it")
    func schemaInPromptForJSONMode() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        _ = try? await ChatClient(provider: .deepSeek, model: "deepseek-chat", transport: transport)
            .complete(testRequest(), apiKey: "k")

        let body = try #require(transport.lastBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let system = try #require(messages[0]["content"] as? String)

        #expect(system.contains("You are terse."))
        #expect(system.contains("additionalProperties"))
        // json_object mode is rejected outright unless the word appears in the messages — a rule
        // OpenAI wrote and DeepSeek and Qwen copied.
        #expect(system.lowercased().contains("json"))
        #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")
    }

    @Test("asks for no response_format at all when the endpoint supports none")
    func promptOnly() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        let local = LLMProvider.custom(baseURL: URL(string: "http://localhost:1234/v1")!)

        _ = try? await ChatClient(provider: local, model: "local", transport: transport)
            .complete(testRequest(), apiKey: nil)

        let body = try #require(transport.lastBody)
        #expect(body["response_format"] == nil)

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect((messages[0]["content"] as? String)?.contains("additionalProperties") == true)
    }

    /// Sending the schema twice would pay for the same instructions in both the prompt and the
    /// structured-output slot.
    @Test("does not duplicate the schema when the API carries it natively")
    func noDuplicationWhenNative() async throws {
        let transport = StubTransport(json: Recorded.openAI(#"{"ok":true}"#))
        _ = try? await ChatClient(provider: .openAI, model: "gpt-5.2-mini", transport: transport)
            .complete(testRequest(), apiKey: "k")

        let body = try #require(transport.lastBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect((messages[0]["content"] as? String) == "You are terse.")
    }

    /// A model told to produce JSON will still wrap it in a fence or introduce it politely.
    /// Under the two non-strict styles that is the normal case, not a malformed reply.
    @Test("recovers the document from a fenced or chatty reply", arguments: [
        "```json\n{\"ok\":true}\n```",
        "Here's the JSON you asked for:\n{\"ok\":true}",
        "```\n{\"ok\":true}\n```",
        "{\"ok\":true}\n\nLet me know if you'd like anything changed!",
        "{\"ok\":true}",
    ])
    func extractsJSON(_ reply: String) async throws {
        let transport = StubTransport(json: Recorded.openAI(reply))
        let result = try await ChatClient(
            provider: .deepSeek, model: "deepseek-chat", transport: transport
        ).complete(testRequest(), apiKey: "k")

        #expect(result.text == #"{"ok":true}"#)
    }

    /// The naive "first brace to last brace" version swallows trailing prose and miscounts a
    /// brace inside a string literal. Both turn up in real replies.
    @Test("is not fooled by braces inside strings or by trailing prose")
    func extractionEdgeCases() {
        #expect(
            JSONText.extract(from: #"Sure: {"note":"a {weird} label"} — hope that helps"#)
                == #"{"note":"a {weird} label"}"#
        )
        #expect(
            JSONText.extract(from: #"{"note":"quote \" and brace }"}"#)
                == #"{"note":"quote \" and brace }"}"#
        )
        #expect(JSONText.extract(from: "[{\"ok\":true}]") == "[{\"ok\":true}]")
    }

    /// Returning the reply unchanged rather than nil, so the caller's decode error names what
    /// actually arrived instead of a useless "no JSON found".
    @Test("returns the reply unchanged when there is no JSON in it")
    func extractionFallback() {
        #expect(JSONText.extract(from: "I can't help with that.") == "I can't help with that.")
        #expect(JSONText.extract(from: "   ") == "")
    }
}
