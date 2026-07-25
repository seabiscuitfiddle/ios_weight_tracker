import Foundation
import LLMWire

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A transport that returns a canned response and remembers what it was asked to send.
///
/// This is what lets the entire library be verified on a machine with no Xcode, no network and no
/// API key: the recorded bodies in these tests are real response shapes, and the captured request
/// is asserted against the wire format we intend to send.
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

// MARK: - Recorded response shapes

enum Recorded {
    /// The Anthropic Messages envelope, the way the real endpoint returns structured output: the
    /// JSON document arrives as the text of a content block.
    static func anthropic(_ payload: String, stopReason: String = "end_turn") -> String {
        """
        {
          "id": "msg_01ABC", "type": "message", "role": "assistant", "model": "claude-opus-5",
          "stop_reason": "\(stopReason)",
          "content": [{ "type": "text", "text": \(quoted(payload)) }],
          "usage": { "input_tokens": 620, "output_tokens": 96 }
        }
        """
    }

    /// The Chat Completions envelope, as returned by OpenAI and every compatible-mode endpoint.
    static func openAI(
        _ payload: String,
        finishReason: String = "stop",
        refusal: String? = nil
    ) -> String {
        """
        {
          "id": "chatcmpl-123", "object": "chat.completion", "created": 1784000000,
          "model": "gpt-5.2-mini",
          "choices": [{
            "index": 0,
            "message": {
              "role": "assistant",
              "content": \(quoted(payload)),
              "refusal": \(refusal.map(quoted) ?? "null")
            },
            "finish_reason": "\(finishReason)"
          }],
          "usage": { "prompt_tokens": 600, "completion_tokens": 90, "total_tokens": 690 }
        }
        """
    }

    static func quoted(_ text: String) -> String {
        String(
            decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed),
            as: UTF8.self
        )
    }
}

/// A minimal schema, so tests assert on how a schema is *carried* rather than on Tally's own.
let testSchema = JSONSchema(
    name: "test_schema",
    schema: #"{"type":"object","properties":{"ok":{"type":"boolean"}},"required":["ok"],"additionalProperties":false}"#
)

func testRequest(
    system: String = "You are terse.",
    text: String = "hello",
    image: Data? = nil,
    schema: JSONSchema? = testSchema,
    effort: ChatRequest.Effort? = .low
) -> ChatRequest {
    var content: [ContentPart] = []
    if let image { content.append(.image(data: image, mediaType: .jpeg)) }
    content.append(.text(text))
    return ChatRequest(
        system: system, content: content, jsonSchema: schema, maxTokens: 2048, effort: effort
    )
}
