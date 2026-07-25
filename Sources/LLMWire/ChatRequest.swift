import Foundation

/// One prompt, in provider-neutral terms.
///
/// Deliberately single-turn. Multi-turn conversation, tool calls and streaming are all real
/// features, and all of them multiply the ways two providers differ; a library that skips them
/// can guarantee the same behaviour everywhere, which is the whole point of this one.
public struct ChatRequest: Hashable, Sendable {
    /// System instruction. Sent in whatever slot the wire format provides for it.
    public var system: String
    /// The user turn, in order. Order matters: both Anthropic and OpenAI produce better results
    /// with an image placed before the text that refers to it.
    public var content: [ContentPart]
    /// The shape the reply must take. How it is enforced — or whether it is enforced at all —
    /// depends on the provider's ``StructuredOutputStyle``; the caller doesn't branch on that.
    public var jsonSchema: JSONSchema?
    public var maxTokens: Int
    /// Reasoning effort, for models that expose it. Ignored by providers that don't.
    public var effort: Effort?
    /// Left nil by default. Providers disagree on the default value and on whether it may be
    /// combined with reasoning — several now reject any explicit temperature on reasoning
    /// models — so sending nothing is the portable choice.
    public var temperature: Double?

    public init(
        system: String,
        content: [ContentPart],
        jsonSchema: JSONSchema? = nil,
        maxTokens: Int = 2048,
        effort: Effort? = nil,
        temperature: Double? = nil
    ) {
        self.system = system
        self.content = content
        self.jsonSchema = jsonSchema
        self.maxTokens = maxTokens
        self.effort = effort
        self.temperature = temperature
    }

    public var hasImage: Bool {
        content.contains { if case .image = $0 { true } else { false } }
    }

    public var text: String {
        content.compactMap { if case .text(let value) = $0 { value } else { nil } }
            .joined(separator: "\n")
    }

    public enum Effort: String, Hashable, Sendable, Codable, CaseIterable {
        case minimal, low, medium, high
    }
}

public enum ContentPart: Hashable, Sendable {
    case text(String)
    case image(data: Data, mediaType: ImageMediaType)
}

public enum ImageMediaType: String, Hashable, Sendable, Codable, CaseIterable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case webp = "image/webp"
    case heic = "image/heic"
}

/// A JSON Schema plus the name providers insist on attaching to it.
public struct JSONSchema: Hashable, Sendable {
    /// Identifier for the schema. OpenAI requires one and rejects names outside
    /// `[a-zA-Z0-9_-]`; Anthropic ignores it.
    public var name: String
    /// The schema itself, as JSON text.
    ///
    /// Text rather than a Swift type on purpose. A schema has to satisfy each provider's exact
    /// documented constraints — `additionalProperties: false`, a complete `required` list, no
    /// numeric bounds — and those are far easier to check against a schema you can read than
    /// against a tower of `Encodable` wrappers that generates one.
    public var schema: String

    public init(name: String, schema: String) {
        self.name = name
        self.schema = schema
    }

    /// Parsed for embedding in a request body.
    func object() throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(schema.utf8))
            as? [String: Any]
        else {
            throw LLMError.malformedResponse("The supplied output schema is not a JSON object.")
        }
        return object
    }
}

/// What came back.
public struct ChatResponse: Hashable, Sendable {
    /// The assistant's text. When a schema was requested this is the JSON document, already
    /// stripped of any code fence or surrounding prose the model added.
    public var text: String
    public var stop: StopReason
    /// Token counts, when the provider reported them. Advisory only — providers count
    /// differently and some omit it entirely.
    public var usage: Usage?

    public init(text: String, stop: StopReason = .stop, usage: Usage? = nil) {
        self.text = text
        self.stop = stop
        self.usage = usage
    }

    public enum StopReason: Hashable, Sendable {
        case stop
        case maxTokens
        case refusal(String?)
        case other(String)
    }

    public struct Usage: Hashable, Sendable {
        public var inputTokens: Int
        public var outputTokens: Int

        public init(inputTokens: Int, outputTokens: Int) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }
    }
}
