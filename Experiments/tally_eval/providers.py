"""The provider table, mirroring `Sources/LLMWire/LLMProvider.swift`.

Data, not classes, for the same reason it is data in the Swift: adding a provider should be a
dict, and the awkward differences between them — who takes a JSON Schema natively, who renamed
`max_tokens`, who accepts a reasoning-effort hint and for which models — should be declared in
one readable place rather than discovered as a 400 mid-experiment.

Keep this in step with the Swift when the Swift changes. A difference here is not a bug in the
harness so much as a measurement of a provider the app does not actually talk to.
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

EXPERIMENTS_DIR = Path(__file__).resolve().parent.parent

WireFormat = Literal["anthropic_messages", "openai_chat_completions"]
StructuredOutputStyle = Literal["json_schema", "json_object", "prompt"]
EffortSupport = Literal["never", "known_models", "always"]


@dataclass(frozen=True)
class Provider:
    id: str
    display_name: str
    wire_format: WireFormat
    endpoint: str
    structured_output: StructuredOutputStyle
    accepts_images: bool
    default_model: str
    suggested_models: tuple[str, ...] = ()
    #: `x-api-key` plus a version header for Anthropic, `Authorization: Bearer` for everyone else.
    anthropic_auth: bool = False
    #: OpenAI's newer models reject `max_tokens`; most compatible-mode endpoints only know it.
    uses_max_completion_tokens: bool = False
    effort_support: EffortSupport = "never"
    extra_headers: dict[str, str] = field(default_factory=dict)
    #: Environment variable holding the key. One per provider so several can be live at once.
    key_env: str = ""

    @property
    def needs_schema_in_prompt(self) -> bool:
        return self.structured_output != "json_schema"

    def api_key(self) -> str:
        """The key from the environment. Empty is allowed — local runners take no key."""
        return os.environ.get(self.key_env, "").strip()

    def effort_value(self, effort: str | None, model: str) -> str | None:
        """The value to send as the effort hint, or None to leave the field off entirely.

        Same asymmetry the Swift reasons about: omitting the hint costs a slightly different
        amount of thinking on a request that still succeeds, while sending it to a model that
        does not take it fails the whole request. So anything unrecognised gets None.
        """
        if effort is None or self.effort_support == "never":
            return None
        if self.effort_support == "always":
            return effort
        if self.wire_format == "anthropic_messages":
            return _anthropic_effort(effort, model)
        return _openai_effort(effort, model)


# MARK: Effort, mirroring EffortSupport.swift

_MINIMUM_EFFORT_VERSION = {"opus": (4, 5), "sonnet": (4, 6), "haiku": (5, 0), "fable": (0, 0)}


def _bare_model_name(identifier: str) -> str:
    """Strips a gateway's routing prefix — OpenRouter's `anthropic/claude-…`."""
    return identifier.lower().split("/")[-1]


def _claude_version(model: str) -> tuple[str, tuple[int, int]] | None:
    """The family and version of a Claude identifier, or None if it is not one."""
    parts = re.split(r"[-.]", _bare_model_name(model))
    for index, part in enumerate(parts):
        if part in _MINIMUM_EFFORT_VERSION:
            numbers: list[int] = []
            # An eight-digit run is a release date, not a version component: `claude-opus-4-20250514`
            # is Opus 4, not Opus 4.20250514.
            for candidate in parts[index + 1 :]:
                if not candidate.isdigit() or len(candidate) >= 8:
                    break
                numbers.append(int(candidate))
            major = numbers[0] if numbers else 0
            minor = numbers[1] if len(numbers) > 1 else 0
            return part, (major, minor)
    return None


def _anthropic_effort(effort: str, model: str) -> str | None:
    name = _claude_version(model)
    if name is None:
        return None
    family, version = name
    if version < _MINIMUM_EFFORT_VERSION[family]:
        return None
    # Anthropic's scale runs low through max and has no `minimal`.
    return "low" if effort == "minimal" else effort


def _openai_effort(effort: str, model: str) -> str | None:
    name = _bare_model_name(model)
    if name.startswith("gpt-5"):
        return effort
    head = name.split("-")[0]
    is_o_series = head.startswith("o") and len(head) > 1 and head[1:].isdigit()
    if is_o_series:
        return "low" if effort == "minimal" else effort
    return None


# MARK: Built-in providers

ANTHROPIC = Provider(
    id="anthropic",
    display_name="Anthropic",
    wire_format="anthropic_messages",
    endpoint="https://api.anthropic.com/v1/messages",
    structured_output="json_schema",
    accepts_images=True,
    default_model="claude-opus-5",
    suggested_models=("claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"),
    anthropic_auth=True,
    effort_support="known_models",
    key_env="ANTHROPIC_API_KEY",
)

OPENAI = Provider(
    id="openai",
    display_name="OpenAI",
    wire_format="openai_chat_completions",
    endpoint="https://api.openai.com/v1/chat/completions",
    structured_output="json_schema",
    accepts_images=True,
    default_model="gpt-5.2-mini",
    suggested_models=("gpt-5.2", "gpt-5.2-mini", "gpt-4.1", "gpt-4.1-mini"),
    uses_max_completion_tokens=True,
    effort_support="known_models",
    key_env="OPENAI_API_KEY",
)

OPENROUTER = Provider(
    id="openrouter",
    display_name="OpenRouter",
    wire_format="openai_chat_completions",
    endpoint="https://openrouter.ai/api/v1/chat/completions",
    structured_output="json_schema",
    accepts_images=True,
    default_model="deepseek/deepseek-chat",
    suggested_models=(
        "deepseek/deepseek-chat",
        "qwen/qwen3-vl-plus",
        "moonshotai/kimi-k2",
        "z-ai/glm-4.6",
        "openai/gpt-5.2-mini",
        "anthropic/claude-haiku-4.5",
    ),
    # OpenRouter normalises parameters across upstreams and drops what the chosen model cannot
    # use, so it is the one provider where sending the hint unconditionally is safe.
    effort_support="always",
    key_env="OPENROUTER_API_KEY",
)

DEEPSEEK = Provider(
    id="deepseek",
    display_name="DeepSeek",
    wire_format="openai_chat_completions",
    endpoint="https://api.deepseek.com/v1/chat/completions",
    structured_output="json_object",
    accepts_images=False,
    default_model="deepseek-chat",
    suggested_models=("deepseek-chat", "deepseek-reasoner"),
    key_env="DEEPSEEK_API_KEY",
)

MOONSHOT = Provider(
    id="moonshot",
    display_name="Moonshot (Kimi)",
    wire_format="openai_chat_completions",
    endpoint="https://api.moonshot.ai/v1/chat/completions",
    structured_output="json_object",
    accepts_images=True,
    default_model="kimi-k2-turbo-preview",
    suggested_models=("kimi-k2-turbo-preview", "moonshot-v1-8k-vision-preview"),
    key_env="MOONSHOT_API_KEY",
)

ZHIPU = Provider(
    id="zhipu",
    display_name="Zhipu (GLM)",
    wire_format="openai_chat_completions",
    endpoint="https://api.z.ai/api/paas/v4/chat/completions",
    structured_output="json_object",
    accepts_images=True,
    default_model="glm-4.6",
    suggested_models=("glm-4.6", "glm-4.6v", "glm-4.5-air"),
    key_env="ZHIPU_API_KEY",
)

DASHSCOPE = Provider(
    id="dashscope",
    display_name="Alibaba (Qwen)",
    wire_format="openai_chat_completions",
    endpoint="https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",
    structured_output="json_object",
    accepts_images=True,
    default_model="qwen-plus",
    suggested_models=("qwen-plus", "qwen-max", "qwen-vl-max"),
    key_env="DASHSCOPE_API_KEY",
)

PROVIDERS: dict[str, Provider] = {
    provider.id: provider
    for provider in (ANTHROPIC, OPENAI, OPENROUTER, DEEPSEEK, MOONSHOT, ZHIPU, DASHSCOPE)
}


def local(
    base_url: str,
    id: str = "local",
    display_name: str = "Local",
    structured_output: StructuredOutputStyle = "prompt",
    default_model: str = "",
) -> Provider:
    """An OpenAI-compatible endpoint you are running yourself — Ollama, LM Studio, vLLM.

    Structured output defaults to `prompt` for the reason the Swift gives: the pessimistic
    choice works everywhere, where guessing `json_schema` fails with an opaque 400 on endpoints
    that never implemented it.
    """
    endpoint = base_url if base_url.endswith("/chat/completions") else base_url.rstrip("/") + "/chat/completions"
    return Provider(
        id=id,
        display_name=display_name,
        wire_format="openai_chat_completions",
        endpoint=endpoint,
        structured_output=structured_output,
        accepts_images=True,
        default_model=default_model,
        key_env=f"{id.upper()}_API_KEY",
    )


# MARK: Pricing

PRICING_PATH = EXPERIMENTS_DIR / "pricing.json"


def pricing() -> dict[str, dict[str, float]]:
    """Per-model USD per million tokens, read from `Experiments/pricing.json`.

    Deliberately not baked into this file. List prices change often enough that a hardcoded
    table is a source of confidently wrong cost columns, which is worse than blank ones — so an
    unlisted model reports no cost rather than a guessed one. Copy `pricing.example.json` and
    fill it from each provider's own pricing page.

    Keys are model identifiers as you send them; values are `{"input": …, "output": …}`.
    """
    if not PRICING_PATH.exists():
        return {}
    return json.loads(PRICING_PATH.read_text(encoding="utf-8"))


def cost_usd(model: str, input_tokens: int, output_tokens: int) -> float | None:
    """Cost of one call, or None when the model has no entry in `pricing.json`."""
    rates = pricing().get(model) or pricing().get(_bare_model_name(model))
    if not rates:
        return None
    return (input_tokens * rates["input"] + output_tokens * rates["output"]) / 1_000_000
