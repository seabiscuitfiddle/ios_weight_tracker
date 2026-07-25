import Foundation
import Testing
@testable import TallyCore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A transport that returns a canned response and remembers what it was asked to send.
///
/// This is what lets the entire LLM path be verified on a machine with no Xcode, no network and
/// no API key: the recorded bodies below are real Messages API response shapes, and the captured
/// request is asserted against the wire format we intend to send.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let responses: [Result<HTTPResponse, any Error>]
    private let lock = NSLock()
    private var index = 0
    private var captured: [URLRequest] = []

    init(_ response: HTTPResponse) {
        self.responses = [.success(response)]
    }

    init(error: any Error) {
        self.responses = [.failure(error)]
    }

    init(sequence: [Result<HTTPResponse, any Error>]) {
        self.responses = sequence
    }

    convenience init(status: Int = 200, json: String, headers: [String: String] = [:]) {
        self.init(HTTPResponse(statusCode: status, body: Data(json.utf8), headers: headers))
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    var lastRequest: URLRequest? { requests.last }

    /// The last request's body, decoded as JSON.
    var lastBody: [String: Any]? {
        guard let data = lastRequest?.httpBody,
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        try record(request).get()
    }

    /// Synchronous so the lock isn't taken from an async context, which Swift 6 disallows —
    /// holding a non-async lock across a suspension point risks deadlocking the executor.
    private func record(_ request: URLRequest) -> Result<HTTPResponse, any Error> {
        lock.lock()
        defer { lock.unlock() }
        captured.append(request)
        let result = responses[min(index, responses.count - 1)]
        index += 1
        return result
    }
}

/// Wraps a JSON payload in the Messages API envelope, the way the real endpoint returns
/// structured output: the JSON document arrives as the text of a content block.
private func messagesEnvelope(_ payload: String, stopReason: String = "end_turn") -> String {
    let escaped = String(
        decoding: try! JSONSerialization.data(withJSONObject: payload, options: .fragmentsAllowed),
        as: UTF8.self
    )
    return """
        {
          "id": "msg_01ABC",
          "type": "message",
          "role": "assistant",
          "model": "claude-opus-5",
          "stop_reason": "\(stopReason)",
          "content": [{ "type": "text", "text": \(escaped) }],
          "usage": { "input_tokens": 620, "output_tokens": 96 }
        }
        """
}

private func makeParser(
    _ transport: StubTransport,
    key: String? = "sk-ant-test",
    configuration: ParserConfiguration = .default
) -> AnthropicNutritionParser {
    AnthropicNutritionParser(
        transport: transport,
        keyStore: StaticAPIKeyStore(key),
        configuration: configuration
    )
}

@Suite("Parse request construction")
struct ParseRequestTests {
    @Test("sends the documented headers")
    func headers() async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))
        _ = try? await makeParser(transport).parse(.text("toast"))

        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test("requests structured output with the schema and effort")
    func structuredOutput() async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))
        _ = try? await makeParser(transport).parse(.text("toast"))

        let body = try #require(transport.lastBody)
        #expect(body["model"] as? String == "claude-opus-5")

        let outputConfig = try #require(body["output_config"] as? [String: Any])
        #expect(outputConfig["effort"] as? String == "low")

        let format = try #require(outputConfig["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")

        let schema = try #require(format["schema"] as? [String: Any])
        // Structured outputs require these two, and omitting either makes the reply
        // unreliable in ways this code has no way to detect.
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(schema["required"] as? [String] == ["items", "note"])
    }

    /// Thinking must be absent, not disabled. Disabling it on Opus 5 is a documented cause of
    /// format irregularities — including tool calls arriving as plain prose — which would look
    /// like a successful call that silently logged nothing.
    @Test("does not disable thinking")
    func doesNotDisableThinking() async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))
        _ = try? await makeParser(transport).parse(.text("toast"))

        let body = try #require(transport.lastBody)
        #expect(body["thinking"] == nil)
    }

    @Test("marks the system prompt cacheable")
    func systemPromptIsCacheable() async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))
        _ = try? await makeParser(transport).parse(.text("toast"))

        let body = try #require(transport.lastBody)
        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect((system[0]["text"] as? String)?.isEmpty == false)
    }

    @Test("puts the user's words in the message content")
    func includesUserText() async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))
        _ = try? await makeParser(transport).parse(.text("two scrambled eggs and sourdough"))

        let body = try #require(transport.lastBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        let text = try #require(content.compactMap { $0["text"] as? String }.first)

        #expect(text.contains("two scrambled eggs and sourdough"))
        #expect(messages[0]["role"] as? String == "user")
    }

    @Test("sends a photo as a base64 image block before the instruction")
    func imageRequest() async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))
        let pixels = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02])

        _ = try? await makeParser(transport).parse(
            .image(data: pixels, mediaType: .jpeg, note: "half of it was left over")
        )

        let body = try #require(transport.lastBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])

        // Image first — Anthropic's guidance is that images placed before the related text
        // give better results.
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "image")
        #expect(content[1]["type"] as? String == "text")

        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/jpeg")
        #expect(source["data"] as? String == pixels.base64EncodedString())

        // The user's accompanying note travels with it.
        #expect((content[1]["text"] as? String)?.contains("half of it was left over") == true)
    }

    /// Energy burned scales with body mass, so the same run is a different number for different
    /// people. When the app knows the weight it should say so.
    @Test("includes body weight when known")
    func includesBodyWeight() async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))
        _ = try? await makeParser(transport).parse(
            .text("ran 38 minutes"),
            context: ParseContext(bodyWeightPounds: 168.4)
        )

        let body = try #require(transport.lastBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        let text = try #require(content.compactMap { $0["text"] as? String }.first)

        #expect(text.contains("168"))
    }

    @Test("omits body weight when unknown")
    func omitsUnknownBodyWeight() async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))
        _ = try? await makeParser(transport).parse(.text("ran 38 minutes"))

        let body = try #require(transport.lastBody)
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        let text = try #require(content.compactMap { $0["text"] as? String }.first)

        #expect(text.lowercased().contains("body weight") == false)
    }

    @Test("honours a configured model and effort")
    func honoursConfiguration() async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))
        let configuration = ParserConfiguration(
            model: "claude-haiku-4-5",
            effort: "medium",
            maxTokens: 1024,
            baseURL: URL(string: "https://example.test/v1/messages")!
        )

        _ = try? await makeParser(transport, configuration: configuration).parse(.text("toast"))

        let body = try #require(transport.lastBody)
        #expect(body["model"] as? String == "claude-haiku-4-5")
        #expect(body["max_tokens"] as? Int == 1024)
        #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "medium")
        #expect(transport.lastRequest?.url?.host == "example.test")
    }

    /// No key means no request at all — the parser must not send an unauthenticated call and
    /// let the server say no.
    @Test("does not call the API without a key")
    func requiresKey() async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))

        await #expect(throws: NutritionParserError.missingAPIKey) {
            try await makeParser(transport, key: nil).parse(.text("toast"))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("treats a blank key as missing", arguments: ["", "   ", "\n"])
    func blankKeyIsMissing(_ key: String) async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))

        await #expect(throws: NutritionParserError.missingAPIKey) {
            try await makeParser(transport, key: key).parse(.text("toast"))
        }
        #expect(transport.requests.isEmpty)
    }

    @Test("trims whitespace pasted around a key")
    func trimsKey() async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[],"note":""}"#))
        _ = try? await makeParser(transport, key: "  sk-ant-test\n").parse(.text("toast"))

        #expect(transport.lastRequest?.value(forHTTPHeaderField: "x-api-key") == "sk-ant-test")
    }
}

@Suite("Parse response decoding")
struct ParseResponseTests {
    @Test("decodes a single food item")
    func singleFood() async throws {
        let transport = StubTransport(json: messagesEnvelope("""
            {"items":[{"kind":"food","label":"Greek yogurt & berries","calories":280,
            "proteinGrams":24,"fiberGrams":4,"exerciseKind":"none","durationMinutes":0,
            "confidence":"high"}],"note":""}
            """))

        let result = try await makeParser(transport).parse(.text("greek yogurt with berries"))

        #expect(result.items.count == 1)
        let item = try #require(result.items.first)
        #expect(item.kind == .food)
        #expect(item.label == "Greek yogurt & berries")
        #expect(item.calories == 280)
        #expect(item.proteinGrams == 24)
        #expect(item.fiberGrams == 4)
        #expect(item.confidence == .high)
        // The "none" sentinel becomes a real absence once inside the domain.
        #expect(item.exerciseKind == nil)
        // As does a zero duration.
        #expect(item.durationMinutes == nil)
        #expect(result.note == nil)
    }

    @Test("decodes an exercise item")
    func exercise() async throws {
        let transport = StubTransport(json: messagesEnvelope("""
            {"items":[{"kind":"exercise","label":"Zone 2 run","calories":320,
            "proteinGrams":0,"fiberGrams":0,"exerciseKind":"cardio","durationMinutes":38,
            "confidence":"medium"}],"note":"Assumed an easy pace."}
            """))

        let result = try await makeParser(transport).parse(.text("ran about 38 minutes, easy pace"))

        let item = try #require(result.items.first)
        #expect(item.kind == .exercise)
        #expect(item.calories == 320)
        #expect(item.exerciseKind == .cardio)
        #expect(item.durationMinutes == 38)
        #expect(result.note == "Assumed an easy pace.")
    }

    @Test("decodes several items from one description")
    func multipleItems() async throws {
        let transport = StubTransport(json: messagesEnvelope("""
            {"items":[
              {"kind":"food","label":"Scrambled eggs","calories":180,"proteinGrams":12,
               "fiberGrams":0,"exerciseKind":"none","durationMinutes":0,"confidence":"high"},
              {"kind":"food","label":"Sourdough toast with butter","calories":160,
               "proteinGrams":5,"fiberGrams":2,"exerciseKind":"none","durationMinutes":0,
               "confidence":"medium"},
              {"kind":"food","label":"Black coffee","calories":5,"proteinGrams":0,
               "fiberGrams":0,"exerciseKind":"none","durationMinutes":0,"confidence":"high"}
            ],"note":"Assumed two eggs and one slice."}
            """))

        let result = try await makeParser(transport)
            .parse(.text("two scrambled eggs, sourdough toast with butter, black coffee"))

        #expect(result.items.count == 3)
        #expect(result.items.map(\.calories) == [180, 160, 5])
        #expect(result.note == "Assumed two eggs and one slice.")
    }

    /// Exercise carries no macros. Letting a stray value through would inflate the protein bar
    /// on the Today screen.
    @Test("zeroes macros on exercise even if the model supplies them")
    func exerciseMacrosAreZeroed() async throws {
        let transport = StubTransport(json: messagesEnvelope("""
            {"items":[{"kind":"exercise","label":"Lifting","calories":200,
            "proteinGrams":30,"fiberGrams":5,"exerciseKind":"strength","durationMinutes":45,
            "confidence":"high"}],"note":""}
            """))

        let item = try #require(
            try await makeParser(transport).parse(.text("lifted for 45 min")).items.first
        )
        #expect(item.proteinGrams == 0)
        #expect(item.fiberGrams == 0)
    }

    @Test("maps an unknown exercise kind to other rather than dropping the entry")
    func unknownExerciseKind() async throws {
        let transport = StubTransport(json: messagesEnvelope("""
            {"items":[{"kind":"exercise","label":"Padel","calories":300,"proteinGrams":0,
            "fiberGrams":0,"exerciseKind":"racquet_sports","durationMinutes":60,
            "confidence":"medium"}],"note":""}
            """))

        let item = try #require(
            try await makeParser(transport).parse(.text("padel for an hour")).items.first
        )
        #expect(item.exerciseKind == .other)
        #expect(item.calories == 300)
    }

    @Test("treats an unrecognised confidence as low rather than failing")
    func unknownConfidence() async throws {
        let transport = StubTransport(json: messagesEnvelope("""
            {"items":[{"kind":"food","label":"Soup","calories":150,"proteinGrams":5,
            "fiberGrams":2,"exerciseKind":"none","durationMinutes":0,"confidence":"unsure"}],
            "note":""}
            """))

        let item = try #require(
            try await makeParser(transport).parse(.text("soup")).items.first
        )
        #expect(item.confidence == .low)
    }

    /// The schema cannot express numeric bounds, so implausible values have to be caught here.
    /// A mis-decimalled 40,000 calorie entry would distort the weight trend the goal engine
    /// reads, which is much worse than dropping the item.
    @Test("drops items with implausible or invalid values", arguments: [
        (#"{"kind":"food","label":"Rice","calories":-200,"proteinGrams":4,"fiberGrams":1,"exerciseKind":"none","durationMinutes":0,"confidence":"high"}"#, "negative calories"),
        (#"{"kind":"food","label":"Rice","calories":400000,"proteinGrams":4,"fiberGrams":1,"exerciseKind":"none","durationMinutes":0,"confidence":"high"}"#, "absurd calories"),
        (#"{"kind":"food","label":"   ","calories":200,"proteinGrams":4,"fiberGrams":1,"exerciseKind":"none","durationMinutes":0,"confidence":"high"}"#, "blank label"),
        (#"{"kind":"snack","label":"Rice","calories":200,"proteinGrams":4,"fiberGrams":1,"exerciseKind":"none","durationMinutes":0,"confidence":"high"}"#, "unknown kind"),
    ])
    func dropsInvalidItems(_ item: String, _ reason: String) async throws {
        let transport = StubTransport(json: messagesEnvelope(#"{"items":[\#(item)],"note":""}"#))

        await #expect(throws: NutritionParserError.self, "should reject: \(reason)") {
            try await makeParser(transport).parse(.text("rice"))
        }
    }

    /// One bad item shouldn't cost the user the three good ones alongside it.
    @Test("keeps the valid items when one is unusable")
    func keepsValidItemsAlongsideBadOnes() async throws {
        let transport = StubTransport(json: messagesEnvelope("""
            {"items":[
              {"kind":"food","label":"Rice","calories":200,"proteinGrams":4,"fiberGrams":1,
               "exerciseKind":"none","durationMinutes":0,"confidence":"high"},
              {"kind":"food","label":"","calories":-5,"proteinGrams":0,"fiberGrams":0,
               "exerciseKind":"none","durationMinutes":0,"confidence":"high"},
              {"kind":"food","label":"Beans","calories":150,"proteinGrams":9,"fiberGrams":7,
               "exerciseKind":"none","durationMinutes":0,"confidence":"high"}
            ],"note":""}
            """))

        let result = try await makeParser(transport).parse(.text("rice and beans"))
        #expect(result.items.map(\.label) == ["Rice", "Beans"])
    }

    @Test("clamps absurd macro values instead of dropping the item")
    func clampsMacros() async throws {
        let transport = StubTransport(json: messagesEnvelope("""
            {"items":[{"kind":"food","label":"Protein shake","calories":300,
            "proteinGrams":99999,"fiberGrams":-4,"exerciseKind":"none","durationMinutes":0,
            "confidence":"high"}],"note":""}
            """))

        let item = try #require(
            try await makeParser(transport).parse(.text("protein shake")).items.first
        )
        #expect(item.calories == 300)
        #expect(item.proteinGrams == 1000)
        #expect(item.fiberGrams == 0)
    }

    @Test("reports nothing recognised, carrying the explanation")
    func nothingRecognised() async throws {
        let transport = StubTransport(json: messagesEnvelope(
            #"{"items":[],"note":"That doesn't describe any food or exercise."}"#
        ))

        await #expect(throws: NutritionParserError.nothingRecognized(
            "That doesn't describe any food or exercise."
        )) {
            try await makeParser(transport).parse(.text("asdfgh"))
        }
    }
}

@Suite("Parse error handling")
struct ParseErrorTests {
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

        await #expect(throws: NutritionParserError.refused("Declined.")) {
            try await makeParser(transport).parse(.text("something"))
        }
    }

    @Test("reports a truncated reply rather than a decode failure")
    func truncated() async throws {
        // Valid envelope, but the JSON document inside was cut off mid-object.
        let transport = StubTransport(json: messagesEnvelope(
            #"{"items":[{"kind":"food","label":"Ri"#, stopReason: "max_tokens"
        ))

        await #expect(throws: NutritionParserError.truncated) {
            try await makeParser(transport).parse(.text("a very long list"))
        }
    }

    @Test("maps auth failures to an invalid-key error", arguments: [401, 403])
    func invalidKey(_ status: Int) async throws {
        let transport = StubTransport(
            status: status,
            json: #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
        )

        await #expect(throws: NutritionParserError.invalidAPIKey) {
            try await makeParser(transport).parse(.text("toast"))
        }
    }

    @Test("reads retry-after off a rate-limit response")
    func rateLimited() async throws {
        let transport = StubTransport(
            status: 429,
            json: #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#,
            headers: ["retry-after": "42"]
        )

        await #expect(throws: NutritionParserError.rateLimited(retryAfter: 42)) {
            try await makeParser(transport).parse(.text("toast"))
        }
    }

    @Test("finds retry-after regardless of header capitalisation")
    func retryAfterCaseInsensitive() async throws {
        let transport = StubTransport(
            status: 429,
            json: #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#,
            headers: ["Retry-After": "7"]
        )

        await #expect(throws: NutritionParserError.rateLimited(retryAfter: 7)) {
            try await makeParser(transport).parse(.text("toast"))
        }
    }

    @Test("handles a rate limit with no retry-after header")
    func rateLimitedWithoutHeader() async throws {
        let transport = StubTransport(
            status: 429,
            json: #"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#
        )

        await #expect(throws: NutritionParserError.rateLimited(retryAfter: nil)) {
            try await makeParser(transport).parse(.text("toast"))
        }
    }

    @Test("maps 529 to overloaded and 413 to too-large")
    func otherStatuses() async throws {
        await #expect(throws: NutritionParserError.overloaded) {
            try await makeParser(StubTransport(status: 529, json: "{}")).parse(.text("toast"))
        }
        await #expect(throws: NutritionParserError.requestTooLarge) {
            try await makeParser(StubTransport(status: 413, json: "{}")).parse(.text("toast"))
        }
    }

    @Test("carries the server's message on an unexpected status")
    func serverError() async throws {
        let transport = StubTransport(
            status: 500,
            json: #"{"type":"error","error":{"type":"api_error","message":"internal"}}"#
        )

        await #expect(throws: NutritionParserError.serverError(status: 500, message: "internal")) {
            try await makeParser(transport).parse(.text("toast"))
        }
    }

    @Test("reports malformed JSON as a bad reply, not a crash")
    func malformedJSON() async throws {
        let transport = StubTransport(status: 200, json: "not json at all")

        await #expect(throws: NutritionParserError.self) {
            try await makeParser(transport).parse(.text("toast"))
        }
    }

    @Test("reports an envelope with no text block")
    func noTextBlock() async throws {
        let transport = StubTransport(status: 200, json: """
            {"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5",
             "stop_reason":"end_turn","content":[],"usage":{"input_tokens":1,"output_tokens":1}}
            """)

        await #expect(throws: NutritionParserError.self) {
            try await makeParser(transport).parse(.text("toast"))
        }
    }

    @Test("surfaces a transport failure as offline")
    func transportFailure() async throws {
        let transport = StubTransport(error: NutritionParserError.offline("no route to host"))

        await #expect(throws: NutritionParserError.offline("no route to host")) {
            try await makeParser(transport).parse(.text("toast"))
        }
    }
}

@Suite("Parser error presentation")
struct ParserErrorPresentationTests {
    /// Every error reaches a user, so each needs sentence-shaped copy — "an error occurred" is
    /// useless to someone who just photographed their lunch.
    @Test("every error has a usable message", arguments: [
        NutritionParserError.missingAPIKey,
        .invalidAPIKey,
        .rateLimited(retryAfter: 30),
        .rateLimited(retryAfter: nil),
        .overloaded,
        .requestTooLarge,
        .offline("x"),
        .refused(nil),
        .truncated,
        .malformedResponse("x"),
        .nothingRecognized(nil),
        .serverError(status: 500, message: nil),
    ])
    func messagesExist(_ error: NutritionParserError) {
        #expect(error.userMessage.count > 15)
        #expect(error.userMessage.hasSuffix(".") || error.userMessage.hasSuffix("!"))
    }

    /// Drives whether the UI offers "Try again" or tells the user to fix something, so getting
    /// it backwards would send people in circles.
    @Test("classifies which errors are worth retrying")
    func retryClassification() {
        #expect(NutritionParserError.rateLimited(retryAfter: nil).isRetryable)
        #expect(NutritionParserError.overloaded.isRetryable)
        #expect(NutritionParserError.offline("x").isRetryable)
        #expect(NutritionParserError.truncated.isRetryable)

        #expect(NutritionParserError.missingAPIKey.isRetryable == false)
        #expect(NutritionParserError.invalidAPIKey.isRetryable == false)
        #expect(NutritionParserError.nothingRecognized(nil).isRetryable == false)
        #expect(NutritionParserError.refused(nil).isRetryable == false)
    }

    @Test("a rate-limit message mentions the wait when known")
    func rateLimitMessageIncludesDelay() {
        #expect(NutritionParserError.rateLimited(retryAfter: 42).userMessage.contains("42"))
        #expect(NutritionParserError.rateLimited(retryAfter: nil).userMessage.contains("shortly"))
    }

    @Test("a refusal prefers the model's own explanation")
    func refusalUsesExplanation() {
        #expect(NutritionParserError.refused("Specific reason.").userMessage == "Specific reason.")
        #expect(NutritionParserError.refused(nil).userMessage.isEmpty == false)
    }
}

@Suite("Parsed item conversion")
struct ParsedItemConversionTests {
    @Test("becomes an entry carrying day, source and the original words")
    func toEntry() {
        let day = Day(year: 2026, month: 7, day: 23)
        let when = Date(timeIntervalSince1970: 1_784_000_000)
        let item = ParsedItem(
            kind: .food, label: "Toast", calories: 160,
            proteinGrams: 5, fiberGrams: 2, confidence: .medium
        )

        let entry = item.entry(
            on: day, loggedAt: when, source: .llmText, rawInput: "toast with butter"
        )

        #expect(entry.kind == .food)
        #expect(entry.label == "Toast")
        #expect(entry.calories == 160)
        #expect(entry.day == day)
        #expect(entry.loggedAt == when)
        #expect(entry.source == .llmText)
        #expect(entry.rawInput == "toast with butter")
        #expect(entry.confidence == .medium)
        #expect(entry.signedCalories == 160)
    }

    @Test("an exercise item becomes an entry that subtracts")
    func exerciseEntrySubtracts() {
        let item = ParsedItem(
            kind: .exercise, label: "Run", calories: 320,
            exerciseKind: .cardio, durationMinutes: 38
        )
        let entry = item.entry(
            on: Day(year: 2026, month: 7, day: 23), loggedAt: Date(),
            source: .llmVoice, rawInput: "ran 38 min"
        )

        #expect(entry.signedCalories == -320)
        #expect(entry.exerciseKind == .cardio)
        #expect(entry.durationMinutes == 38)
    }
}
