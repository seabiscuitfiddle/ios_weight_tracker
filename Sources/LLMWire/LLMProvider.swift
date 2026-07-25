import Foundation

/// The request format a provider speaks.
///
/// Only two exist in practice. OpenAI's Chat Completions shape became the de facto open standard
/// — every provider that came after it either adopted the format or published a "compatible
/// mode" endpoint — and Anthropic's Messages API is the one significant holdout. Supporting both
/// covers essentially the entire hosted market plus every local runner.
public enum WireFormat: String, Hashable, Sendable, Codable, CaseIterable {
    case anthropicMessages
    case openAIChatCompletions
}

/// How a provider will accept a JSON Schema, if at all.
///
/// This is the ugliest portability problem in the whole space and the main reason a naive
/// "just change the base URL" abstraction breaks in production. The same request that returns
/// perfectly conforming JSON from OpenAI returns a 400 from DeepSeek, and prose wrapped in code
/// fences from a local model.
public enum StructuredOutputStyle: String, Hashable, Sendable, Codable, CaseIterable {
    /// Strict schema enforcement by the provider. The reply is guaranteed to match, so the
    /// caller's decoder can be as strict as it likes. OpenAI, OpenRouter (model permitting),
    /// Anthropic.
    case jsonSchema
    /// The provider guarantees syntactically valid JSON but ignores the schema. The schema goes
    /// in the prompt instead, and the caller must tolerate missing or extra fields. DeepSeek,
    /// Qwen, most "compatible mode" endpoints.
    case jsonObject
    /// No JSON guarantee at all. Schema in the prompt, and the reply is scraped for the first
    /// JSON document in it. Self-hosted models, older endpoints.
    case prompt

    /// Whether the schema has to be spelled out in the prompt because the API won't carry it.
    var needsSchemaInPrompt: Bool { self != .jsonSchema }
}

/// How a provider expects the key to be presented.
public enum AuthStyle: String, Hashable, Sendable, Codable {
    /// `Authorization: Bearer <key>`. Everyone except Anthropic.
    case bearer
    /// `x-api-key: <key>`, plus an API version header.
    case anthropicHeader
}

/// A place to send a completion request.
///
/// Values, not subclasses, so a provider the library has never heard of is expressible by the
/// user at runtime — the point of the design. Codable so an app can persist the user's choice,
/// including a custom endpoint, without a second parallel type.
public struct LLMProvider: Hashable, Sendable, Codable, Identifiable {
    /// Stable across releases. Used as a persistence key and as the keychain account name, so
    /// renaming one orphans a stored key.
    public var id: String
    public var displayName: String
    public var wireFormat: WireFormat
    public var authStyle: AuthStyle
    /// The full completion endpoint, not a base path. Providers disagree wildly about path
    /// shape — `/v1/chat/completions`, `/api/paas/v4/chat/completions`,
    /// `/compatible-mode/v1/chat/completions` — so storing the whole thing avoids a guessing
    /// game. Use ``custom(id:displayName:baseURL:)`` to build one from a base URL.
    public var endpoint: URL
    /// OpenAI-compatible model listing endpoint, where the provider has one. Lets the app show
    /// the models a key can actually reach instead of a hardcoded list that rots.
    public var modelsEndpoint: URL?
    public var structuredOutput: StructuredOutputStyle
    /// Whether *any* model here accepts images. The chosen model still has to be a vision model;
    /// this only decides whether offering a photo at all makes sense.
    public var acceptsImages: Bool
    /// Seeds for the model picker, not an exhaustive or authoritative list. Model identifiers
    /// change faster than any shipped app can, which is why ``modelsEndpoint`` exists and why
    /// the picker must always accept free text.
    public var suggestedModels: [String]
    public var defaultModel: String
    /// Sent with every request. OpenRouter uses these for attribution on its dashboards; others
    /// ignore unknown headers.
    public var extraHeaders: [String: String]
    /// Send the token ceiling as `max_completion_tokens` rather than `max_tokens`.
    ///
    /// OpenAI renamed the field and its newer models now *reject* the old one outright rather
    /// than tolerating it, while most compatible-mode endpoints only ever implemented
    /// `max_tokens`. There is no value that works on both, so it has to be declared.
    public var usesMaxCompletionTokens: Bool
    /// Whether `reasoning_effort` may be sent.
    ///
    /// Off by default because compatible-mode endpoints vary in whether they ignore unknown
    /// parameters or reject the whole request, and a 400 that names a field the user never chose
    /// is a miserable thing to debug.
    public var sendsReasoningEffort: Bool
    /// Where a user goes to get a key, linked from settings UI.
    public var consoleURL: URL?
    /// Shown as the key field's placeholder, so an obviously wrong paste is visible immediately.
    public var keyPlaceholder: String
    /// False for anything the user typed in themselves.
    public var isBuiltIn: Bool

    public init(
        id: String,
        displayName: String,
        wireFormat: WireFormat,
        authStyle: AuthStyle = .bearer,
        endpoint: URL,
        modelsEndpoint: URL? = nil,
        structuredOutput: StructuredOutputStyle,
        acceptsImages: Bool,
        suggestedModels: [String] = [],
        defaultModel: String,
        extraHeaders: [String: String] = [:],
        usesMaxCompletionTokens: Bool = false,
        sendsReasoningEffort: Bool = false,
        consoleURL: URL? = nil,
        keyPlaceholder: String = "sk-…",
        isBuiltIn: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.wireFormat = wireFormat
        self.authStyle = authStyle
        self.endpoint = endpoint
        self.modelsEndpoint = modelsEndpoint
        self.structuredOutput = structuredOutput
        self.acceptsImages = acceptsImages
        self.suggestedModels = suggestedModels
        self.defaultModel = defaultModel
        self.extraHeaders = extraHeaders
        self.usesMaxCompletionTokens = usesMaxCompletionTokens
        self.sendsReasoningEffort = sendsReasoningEffort
        self.consoleURL = consoleURL
        self.keyPlaceholder = keyPlaceholder
        self.isBuiltIn = isBuiltIn
    }

    /// The host a key is sent to. Worth showing the user verbatim in any screen that asks for a
    /// credential — "sent only to X" is a promise you can only make if you name X.
    public var host: String { endpoint.host ?? endpoint.absoluteString }

    /// Decoded field by field with defaults, rather than by the synthesised initialiser.
    ///
    /// A persisted custom provider outlives the version of the library that wrote it. Synthesised
    /// `Codable` treats any field added later as required and fails the whole decode, which would
    /// silently drop a user's endpoint on upgrade; this reads what is there and defaults the rest.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        endpoint = try container.decode(URL.self, forKey: .endpoint)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
        wireFormat = try container.decodeIfPresent(WireFormat.self, forKey: .wireFormat)
            ?? .openAIChatCompletions
        authStyle = try container.decodeIfPresent(AuthStyle.self, forKey: .authStyle) ?? .bearer
        modelsEndpoint = try container.decodeIfPresent(URL.self, forKey: .modelsEndpoint)
        structuredOutput = try container.decodeIfPresent(
            StructuredOutputStyle.self, forKey: .structuredOutput
        ) ?? .prompt
        acceptsImages = try container.decodeIfPresent(Bool.self, forKey: .acceptsImages) ?? true
        suggestedModels = try container.decodeIfPresent([String].self, forKey: .suggestedModels) ?? []
        defaultModel = try container.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
        extraHeaders = try container.decodeIfPresent(
            [String: String].self, forKey: .extraHeaders
        ) ?? [:]
        usesMaxCompletionTokens = try container.decodeIfPresent(
            Bool.self, forKey: .usesMaxCompletionTokens
        ) ?? false
        sendsReasoningEffort = try container.decodeIfPresent(
            Bool.self, forKey: .sendsReasoningEffort
        ) ?? false
        consoleURL = try container.decodeIfPresent(URL.self, forKey: .consoleURL)
        keyPlaceholder = try container.decodeIfPresent(String.self, forKey: .keyPlaceholder) ?? "sk-…"
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }
}

// MARK: - Built-in providers

extension LLMProvider {
    /// Anthropic's Messages API — the one non-OpenAI wire format worth carrying.
    public static let anthropic = LLMProvider(
        id: "anthropic",
        displayName: "Anthropic",
        wireFormat: .anthropicMessages,
        authStyle: .anthropicHeader,
        endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
        modelsEndpoint: URL(string: "https://api.anthropic.com/v1/models")!,
        structuredOutput: .jsonSchema,
        acceptsImages: true,
        suggestedModels: ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"],
        defaultModel: "claude-opus-5",
        consoleURL: URL(string: "https://console.anthropic.com/settings/keys"),
        keyPlaceholder: "sk-ant-…"
    )

    public static let openAI = LLMProvider(
        id: "openai",
        displayName: "OpenAI",
        wireFormat: .openAIChatCompletions,
        endpoint: URL(string: "https://api.openai.com/v1/chat/completions")!,
        modelsEndpoint: URL(string: "https://api.openai.com/v1/models")!,
        structuredOutput: .jsonSchema,
        acceptsImages: true,
        suggestedModels: ["gpt-5.2", "gpt-5.2-mini", "gpt-4.1", "gpt-4.1-mini"],
        defaultModel: "gpt-5.2-mini",
        usesMaxCompletionTokens: true,
        sendsReasoningEffort: true,
        consoleURL: URL(string: "https://platform.openai.com/api-keys"),
        keyPlaceholder: "sk-proj-…"
    )

    /// One key, several hundred models, including every Chinese lab worth trying.
    ///
    /// The pragmatic default for anyone who wants to experiment: no separate account per lab, no
    /// mainland-China payment method, and a single bill. The trade is a small routing margin and
    /// that structured-output support depends on which upstream provider serves the request.
    public static let openRouter = LLMProvider(
        id: "openrouter",
        displayName: "OpenRouter",
        wireFormat: .openAIChatCompletions,
        endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        modelsEndpoint: URL(string: "https://openrouter.ai/api/v1/models")!,
        structuredOutput: .jsonSchema,
        acceptsImages: true,
        suggestedModels: [
            "deepseek/deepseek-chat",
            "qwen/qwen3-vl-plus",
            "moonshotai/kimi-k2",
            "z-ai/glm-4.6",
            "openai/gpt-5.2-mini",
            "anthropic/claude-haiku-4.5",
        ],
        defaultModel: "deepseek/deepseek-chat",
        // OpenRouter normalises OpenAI's parameters across every upstream it routes to, so the
        // effort hint is safe to send here even when the model behind it is not an OpenAI one.
        sendsReasoningEffort: true,
        consoleURL: URL(string: "https://openrouter.ai/keys"),
        keyPlaceholder: "sk-or-v1-…"
    )

    /// Text-only, and only `json_object` — so the schema travels in the prompt and the decoder
    /// has to be forgiving. Very cheap.
    public static let deepSeek = LLMProvider(
        id: "deepseek",
        displayName: "DeepSeek",
        wireFormat: .openAIChatCompletions,
        endpoint: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
        modelsEndpoint: URL(string: "https://api.deepseek.com/v1/models")!,
        structuredOutput: .jsonObject,
        acceptsImages: false,
        suggestedModels: ["deepseek-chat", "deepseek-reasoner"],
        defaultModel: "deepseek-chat",
        consoleURL: URL(string: "https://platform.deepseek.com/api_keys")
    )

    public static let moonshot = LLMProvider(
        id: "moonshot",
        displayName: "Moonshot (Kimi)",
        wireFormat: .openAIChatCompletions,
        endpoint: URL(string: "https://api.moonshot.ai/v1/chat/completions")!,
        modelsEndpoint: URL(string: "https://api.moonshot.ai/v1/models")!,
        structuredOutput: .jsonObject,
        acceptsImages: true,
        suggestedModels: ["kimi-k2-turbo-preview", "moonshot-v1-8k-vision-preview"],
        defaultModel: "kimi-k2-turbo-preview",
        consoleURL: URL(string: "https://platform.moonshot.ai/console/api-keys")
    )

    /// Zhipu's international endpoint. The mainland one is `open.bigmodel.cn`; users inside China
    /// should switch to it with a custom provider, since the two are separate accounts.
    public static let zhipu = LLMProvider(
        id: "zhipu",
        displayName: "Zhipu (GLM)",
        wireFormat: .openAIChatCompletions,
        endpoint: URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!,
        structuredOutput: .jsonObject,
        acceptsImages: true,
        suggestedModels: ["glm-4.6", "glm-4.6v", "glm-4.5-air"],
        defaultModel: "glm-4.6",
        consoleURL: URL(string: "https://z.ai/manage-apikey/apikey-list")
    )

    /// Alibaba Model Studio's OpenAI-compatible mode, international region. Mainland accounts use
    /// `dashscope.aliyuncs.com` — again a separate account, so a custom provider is the route.
    public static let dashScope = LLMProvider(
        id: "dashscope",
        displayName: "Alibaba (Qwen)",
        wireFormat: .openAIChatCompletions,
        endpoint: URL(
            string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions"
        )!,
        modelsEndpoint: URL(
            string: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/models"
        ),
        structuredOutput: .jsonObject,
        acceptsImages: true,
        suggestedModels: ["qwen-plus", "qwen-max", "qwen-vl-max"],
        defaultModel: "qwen-plus",
        consoleURL: URL(string: "https://modelstudio.console.alibabacloud.com/"),
        keyPlaceholder: "sk-…"
    )

    /// Everything shipped, in the order a picker should show them.
    public static let builtIn: [LLMProvider] = [
        .anthropic, .openAI, .openRouter, .deepSeek, .moonshot, .zhipu, .dashScope,
    ]

    public static func builtIn(id: String) -> LLMProvider? {
        builtIn.first { $0.id == id }
    }

    /// A user-supplied OpenAI-compatible endpoint: self-hosted, a gateway, Groq, Together, or
    /// Ollama and LM Studio on the local network.
    ///
    /// Accepts either a base URL (`http://localhost:11434/v1`) or a full endpoint, because users
    /// paste whichever their provider's docs showed them and being wrong about it produces a
    /// bewildering 404. Structured output defaults to ``StructuredOutputStyle/prompt``: the
    /// pessimistic choice works everywhere, where guessing `jsonSchema` fails with an opaque 400
    /// on endpoints that don't implement it.
    public static func custom(
        id: String = "custom",
        displayName: String = "Custom",
        baseURL: URL,
        structuredOutput: StructuredOutputStyle = .prompt,
        acceptsImages: Bool = true,
        defaultModel: String = ""
    ) -> LLMProvider {
        let endpoint = baseURL.path.hasSuffix("/chat/completions")
            ? baseURL
            : baseURL.appendingPathComponent("chat/completions")

        return LLMProvider(
            id: id,
            displayName: displayName,
            wireFormat: .openAIChatCompletions,
            endpoint: endpoint,
            modelsEndpoint: baseURL.path.hasSuffix("/chat/completions")
                ? baseURL.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent("models")
                : baseURL.appendingPathComponent("models"),
            structuredOutput: structuredOutput,
            acceptsImages: acceptsImages,
            defaultModel: defaultModel,
            keyPlaceholder: "optional for local models",
            isBuiltIn: false
        )
    }
}
