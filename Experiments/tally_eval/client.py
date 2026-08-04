"""Sending one prompt to one provider, mirroring `Sources/LLMWire/`.

Two wire formats cover essentially the whole market — Anthropic's Messages API and the OpenAI
Chat Completions shape everyone else adopted — so this is two encoders, two decoders, and one
`complete()` that hides which is in play. Same division as the Swift, and for the same reason:
callers should never branch on vendor.

Requests go out over `httpx.AsyncClient` so a grid of a few hundred calls finishes in the time
one of them takes.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from typing import Any

import httpx

from tally_eval.jsontext import extract_json
from tally_eval.providers import Provider

ANTHROPIC_API_VERSION = "2023-06-01"


class LLMError(RuntimeError):
    """A call that failed, classified the way `LLMError.swift` classifies it.

    `kind` is the app's own vocabulary — `invalid_api_key`, `rate_limited`, `truncated`,
    `refused` — because an experiment's most interesting rows are usually the failures, and
    "HTTP 400" does not tell you which of five very different things went wrong.
    """

    def __init__(self, kind: str, message: str = "", status: int | None = None, retry_after: float | None = None):
        super().__init__(f"{kind}: {message}" if message else kind)
        self.kind = kind
        self.message = message
        self.status = status
        self.retry_after = retry_after

    @property
    def is_retryable(self) -> bool:
        return self.kind in {"rate_limited", "overloaded", "offline", "server_error", "truncated"}


@dataclass
class Reply:
    """What came back, plus what it cost to get it."""

    text: str
    stop: str
    input_tokens: int = 0
    output_tokens: int = 0
    #: Wall-clock seconds for the HTTP round trip. The number a user standing in their kitchen
    #: actually experiences, so it is measured around the request and nothing else.
    latency_s: float = 0.0
    raw: dict[str, Any] = field(default_factory=dict)


# MARK: Request bodies


def anthropic_body(
    system: str,
    user_text: str,
    schema: dict | None,
    model: str,
    provider: Provider,
    max_tokens: int,
    effort: str | None,
    temperature: float | None,
) -> dict:
    body: dict[str, Any] = {
        "model": model,
        "max_tokens": max_tokens,
        # Marked cacheable because the system prompt is byte-identical across a whole run. Below
        # the model's minimum cacheable length it is simply ignored, so it costs nothing — and in
        # a grid of a few hundred calls sharing one prefix, it pays off immediately.
        "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        "messages": [{"role": "user", "content": [{"type": "text", "text": user_text}]}],
    }

    output_config: dict[str, Any] = {}
    if (value := provider.effort_value(effort, model)) is not None:
        output_config["effort"] = value
    # Only the native path sets a format. Under the other styles the schema is already in the
    # system prompt and sending it twice pays for instructions the model has read once.
    if schema is not None and provider.structured_output == "json_schema":
        output_config["format"] = {"type": "json_schema", "schema": schema}
    if output_config:
        body["output_config"] = output_config

    if temperature is not None:
        body["temperature"] = temperature
    return body


def openai_body(
    system: str,
    user_text: str,
    schema: dict | None,
    schema_name: str,
    model: str,
    provider: Provider,
    max_tokens: int,
    effort: str | None,
    temperature: float | None,
) -> dict:
    body: dict[str, Any] = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": [{"type": "text", "text": user_text}]},
        ],
    }
    body["max_completion_tokens" if provider.uses_max_completion_tokens else "max_tokens"] = max_tokens

    if (value := provider.effort_value(effort, model)) is not None:
        body["reasoning_effort"] = value
    if temperature is not None:
        body["temperature"] = temperature

    if schema is not None:
        if provider.structured_output == "json_schema":
            body["response_format"] = {
                "type": "json_schema",
                "json_schema": {
                    "name": _sanitised_name(schema_name),
                    # Without `strict` the schema is a hint and the reply may quietly omit
                    # fields — the failure the whole native path exists to prevent.
                    "strict": True,
                    "schema": schema,
                },
            }
        elif provider.structured_output == "json_object":
            body["response_format"] = {"type": "json_object"}

    return body


def _sanitised_name(name: str) -> str:
    """Schema names are restricted to `[A-Za-z0-9_-]` and a stray space is a confusing 400."""
    cleaned = "".join(c if (c.isalnum() or c in "_-") else "_" for c in name)
    return cleaned or "response"


def headers_for(provider: Provider, api_key: str) -> dict[str, str]:
    if provider.anthropic_auth:
        return {
            "Content-Type": "application/json",
            "x-api-key": api_key,
            "anthropic-version": ANTHROPIC_API_VERSION,
        }
    headers = {"Content-Type": "application/json"}
    # Local runners commonly take no key, and some reject a bare `Bearer `.
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    headers.update(provider.extra_headers)
    return headers


# MARK: Response decoding


def _anthropic_reply(response: httpx.Response) -> Reply:
    payload = response.json()

    # Checked before reading `content`, which is empty on a pre-output refusal — indexing it
    # first would crash on a perfectly ordinary HTTP 200.
    stop_reason = payload.get("stop_reason")
    if stop_reason == "refusal":
        raise LLMError("refused", (payload.get("stop_details") or {}).get("explanation") or "")
    if stop_reason == "max_tokens":
        raise LLMError("truncated", "Reply hit the token ceiling mid-JSON.")

    text = next(
        (block.get("text", "") for block in payload.get("content", []) if block.get("type") == "text"),
        "",
    )
    if not text:
        raise LLMError("malformed_response", "Reply contained no text block.")

    usage = payload.get("usage") or {}
    return Reply(
        text=text,
        stop=stop_reason or "stop",
        input_tokens=usage.get("input_tokens", 0),
        output_tokens=usage.get("output_tokens", 0),
        raw=payload,
    )


def _openai_reply(response: httpx.Response) -> Reply:
    payload = response.json()
    choices = payload.get("choices") or []
    if not choices:
        raise LLMError("malformed_response", "Reply contained no choices.")

    message = choices[0].get("message") or {}
    # A refusal is its own field here rather than a stop reason, and it is populated while
    # `content` is null — so reading content first turns a clear refusal into "empty reply".
    if refusal := message.get("refusal"):
        raise LLMError("refused", refusal)

    finish = choices[0].get("finish_reason")
    if finish == "length":
        raise LLMError("truncated", "Reply hit the token ceiling mid-JSON.")
    if finish == "content_filter":
        raise LLMError("refused", "Stopped by a content filter.")

    text = message.get("content")
    if not text:
        raise LLMError("malformed_response", "Reply contained no message content.")

    usage = payload.get("usage") or {}
    return Reply(
        text=text,
        stop=finish or "stop",
        input_tokens=usage.get("prompt_tokens") or 0,
        output_tokens=usage.get("completion_tokens") or 0,
        raw=payload,
    )


def _error(response: httpx.Response, provider: Provider) -> LLMError:
    try:
        payload = response.json().get("error") or {}
    except ValueError:  # HTML from a proxy, most often.
        payload = {}
    message = payload.get("message") or response.text[:500]
    code = payload.get("code") or payload.get("type")
    status = response.status_code
    retry_after = _float_or_none(response.headers.get("retry-after"))

    # The provider's own code beats the status: the same status means different things at
    # different providers, and the code is the more reliable signal when one is present.
    if code in {"insufficient_quota", "billing_hard_limit_reached", "credit_limit_exceeded"}:
        return LLMError("insufficient_credit", message, status)
    if code in {"model_not_found", "invalid_model", "model_terminated"}:
        return LLMError("unknown_model", message, status)
    if code in {"context_length_exceeded", "string_above_max_length"}:
        return LLMError("request_too_large", message, status)

    if status in (401, 403):
        # 403 is also the region-blocked status at several providers, where the server's own
        # wording is worth more than anything this code could invent.
        if status == 403 and message:
            return LLMError("server_error", message, status)
        return LLMError("invalid_api_key", message, status)
    if status == 402:
        return LLMError("insufficient_credit", message, status)
    if status == 404:
        return LLMError("unknown_model", message or "That model was not found.", status)
    if status == 413:
        return LLMError("request_too_large", message, status)
    if status == 429:
        # Anthropic reports an exhausted balance as a 429 with a distinct type, and telling
        # someone to wait when the fix is to top up sends them in circles.
        if provider.anthropic_auth and code == "billing_error":
            return LLMError("insufficient_credit", message, status)
        return LLMError("rate_limited", message, status, retry_after)
    if status in (502, 503, 529):
        return LLMError("overloaded", message, status)
    return LLMError("server_error", message, status)


def _float_or_none(value: str | None) -> float | None:
    try:
        return float(value) if value is not None else None
    except ValueError:
        return None


# MARK: The one entry point


async def complete(
    http: httpx.AsyncClient,
    provider: Provider,
    model: str,
    system: str,
    user_text: str,
    schema: dict | None = None,
    schema_name: str = "nutrition_log",
    max_tokens: int = 2048,
    effort: str | None = "low",
    temperature: float | None = None,
    timeout: float = 120.0,
) -> Reply:
    """Sends one prompt and returns the reply.

    `system` should already have the schema folded in where the provider needs it — see
    `prompts.schema_in_prompt`; `runner.py` does that for you.
    """
    api_key = provider.api_key()
    if not api_key and provider.id in {"anthropic", "openai", "openrouter", "deepseek", "moonshot", "zhipu", "dashscope"}:
        # No key means no request at all. Sending an unauthenticated call and letting the server
        # say no would waste a round trip and report a worse error.
        raise LLMError("missing_api_key", f"Set {provider.key_env} to call {provider.display_name}.")
    if not model.strip():
        raise LLMError("unknown_model", f"No model selected for {provider.display_name}.")

    if provider.wire_format == "anthropic_messages":
        body = anthropic_body(system, user_text, schema, model, provider, max_tokens, effort, temperature)
    else:
        body = openai_body(system, user_text, schema, schema_name, model, provider, max_tokens, effort, temperature)

    started = time.perf_counter()
    try:
        response = await http.post(
            provider.endpoint,
            headers=headers_for(provider, api_key),
            content=json.dumps(body, sort_keys=True),
            timeout=timeout,
        )
    except httpx.TimeoutException as error:
        raise LLMError("offline", f"Timed out after {timeout}s: {error}") from error
    except httpx.HTTPError as error:
        raise LLMError("offline", str(error)) from error
    elapsed = time.perf_counter() - started

    if not 200 <= response.status_code < 300:
        raise _error(response, provider)

    try:
        reply = _anthropic_reply(response) if provider.wire_format == "anthropic_messages" else _openai_reply(response)
    except ValueError as error:
        raise LLMError("malformed_response", f"Reply was not JSON: {error}") from error

    reply.latency_s = elapsed
    if schema is not None:
        # Harmless when the provider enforced the schema, and the difference between working and
        # not when it merely promised to try.
        reply.text = extract_json(reply.text)
    return reply
