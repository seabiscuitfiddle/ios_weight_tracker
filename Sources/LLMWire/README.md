# LLMWire

One call, any provider — over the two wire formats the industry actually speaks.

`LLMWire` is a dependency-free Swift library for talking to hosted language models. It knows two
request formats — **Anthropic Messages** and **OpenAI Chat Completions** — and that turns out to
be enough for nearly the whole market, because OpenAI's `/v1/chat/completions` has become the de
facto open standard. OpenRouter, DeepSeek, Moonshot (Kimi), Zhipu (GLM), Alibaba (Qwen),
MiniMax, Groq, Together, Ollama and LM Studio all speak it.

**MIT licensed**, and deliberately self-contained: nothing in this directory knows what the
calling app is for. It is kept in a form that can be lifted into its own repository with a
`git mv`.

## What it is not

Not an agent framework. There are no tools, no chains, no conversation memory, no streaming.
It sends one prompt and gives you back one string, with the errors distinguished well enough
that a UI can decide whether to say "try again" or "fix your key".

## Usage

```swift
let client = ChatClient(
    provider: .openRouter,
    model: "deepseek/deepseek-chat",
    transport: URLSessionTransport.makeDefault()
)

let reply = try await client.complete(
    ChatRequest(
        system: "You extract structured data.",
        content: [.text("two eggs and toast")],
        jsonSchema: JSONSchema(name: "nutrition", schema: schemaJSON),
        maxTokens: 2048
    ),
    apiKey: key
)

print(reply.text)   // a JSON document matching the schema
```

## The part worth knowing

**Structured output is not portable, and this library papers over that.** OpenAI and OpenRouter
support strict `json_schema`. Anthropic supports it under a different key. DeepSeek and Qwen
support only `{"type": "json_object"}` and want the schema in the prompt. Self-hosted endpoints
may support neither.

So each provider declares a ``StructuredOutputStyle``, and ``ChatClient`` adapts: it sends the
schema natively where that works, falls back to JSON mode plus a schema in the system prompt
where it doesn't, and always parses the reply tolerantly — code fences and surrounding prose are
stripped before the JSON is handed back. Callers pass a schema once and don't branch.

## Testing

Every request goes through the ``HTTPTransport`` protocol, so the whole library — request
construction and response handling for both wire formats — is testable with no network, no key
and no Xcode. See `Tests/LLMWireTests`.
