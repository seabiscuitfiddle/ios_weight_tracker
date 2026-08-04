"""Running a grid of prompt x model x case, with caching, concurrency, and retries.

Calls cost money and take seconds; a grid of four prompts across five models over thirty cases
is six hundred of them. So every reply is cached on disk under a key derived from everything
that could change it — prompt text, schema, provider, model, effort, temperature, case, repeat
index — and re-running a notebook cell after editing one prompt only pays for that prompt.

Repeats exist because these models are not deterministic and a one-shot comparison of two
prompts is mostly noise. Three repeats is usually enough to see whether a difference is real.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import random
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Any, Iterable, Sequence

import httpx

from tally_eval import client, prompts as prompt_module
from tally_eval.client import LLMError, Reply
from tally_eval.dataset import Case
from tally_eval.parse import ParseResult, parse_reply
from tally_eval.prompts import Prompt, load_prompt
from tally_eval.providers import PROVIDERS, Provider, cost_usd

RESULTS_DIR = Path(__file__).resolve().parent.parent / "results"
CACHE_DIR = RESULTS_DIR / "cache"

SCHEMA_NAME = "nutrition_log"


@dataclass(frozen=True)
class RunConfig:
    """One column of the grid: where to send it and how."""

    provider: str
    model: str
    effort: str | None = "low"
    max_tokens: int = 2048
    temperature: float | None = None
    #: Shown in results instead of `provider/model` when set — useful when the same model is
    #: being compared at two efforts and the identifier alone would not distinguish them.
    label: str = ""

    @property
    def name(self) -> str:
        if self.label:
            return self.label
        suffix = f" ({self.effort})" if self.effort and self._takes_effort else ""
        return f"{self.model}{suffix}"

    @property
    def _takes_effort(self) -> bool:
        return self.resolved_provider.effort_value(self.effort, self.model) is not None

    @property
    def resolved_provider(self) -> Provider:
        try:
            return PROVIDERS[self.provider]
        except KeyError:
            raise KeyError(
                f"Unknown provider {self.provider!r}. Known: {', '.join(sorted(PROVIDERS))}. "
                "For a self-hosted endpoint use `providers.local(...)` and pass it directly."
            ) from None


@dataclass
class Run:
    """One call and everything worth knowing about it."""

    prompt: str
    config: str
    provider: str
    model: str
    case_id: str
    repeat: int
    ok: bool
    error_kind: str | None = None
    error_message: str = ""
    latency_s: float | None = None
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float | None = None
    cached: bool = False
    reply_text: str = ""
    parsed: ParseResult | None = field(default=None, repr=False)

    def as_row(self) -> dict[str, Any]:
        return {
            "prompt": self.prompt,
            "config": self.config,
            "provider": self.provider,
            "model": self.model,
            "case_id": self.case_id,
            "repeat": self.repeat,
            "ok": self.ok,
            "error_kind": self.error_kind,
            "latency_s": self.latency_s,
            "input_tokens": self.input_tokens,
            "output_tokens": self.output_tokens,
            "cost_usd": self.cost_usd,
            "cached": self.cached,
        }


# MARK: Cache


def _cache_key(prompt: Prompt, config: RunConfig, case: Case, repeat: int) -> str:
    material = json.dumps(
        {
            "system": prompt.system,
            "schema": prompt.schema,
            "provider": config.provider,
            "model": config.model,
            "effort": config.effort,
            "max_tokens": config.max_tokens,
            "temperature": config.temperature,
            "case": case.id,
            "text": case.text,
            "weight": case.body_weight_lb,
            "repeat": repeat,
        },
        sort_keys=True,
    )
    return hashlib.sha256(material.encode()).hexdigest()[:24]


def _read_cache(key: str) -> dict[str, Any] | None:
    path = CACHE_DIR / f"{key}.json"
    if not path.exists():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:  # A half-written file from an interrupted run.
        path.unlink(missing_ok=True)
        return None


def _write_cache(key: str, payload: dict[str, Any]) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path = CACHE_DIR / f"{key}.json"
    # Written beside and renamed, so an interrupted notebook never leaves a truncated entry that
    # a later run would happily treat as a real reply.
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    temporary.replace(path)


def clear_cache() -> int:
    """Deletes every cached reply. Returns how many went."""
    if not CACHE_DIR.exists():
        return 0
    files = list(CACHE_DIR.glob("*.json"))
    for path in files:
        path.unlink()
    return len(files)


# MARK: One call


async def _call_once(
    http: httpx.AsyncClient,
    prompt: Prompt,
    config: RunConfig,
    case: Case,
    repeat: int,
    use_cache: bool,
    max_attempts: int,
) -> Run:
    provider = config.resolved_provider
    key = _cache_key(prompt, config, case, repeat)

    if use_cache and (cached := _read_cache(key)) is not None:
        return _run_from_payload(cached, prompt, config, case, repeat, cached=True)

    # Providers without native schema support get it folded into the system prompt, exactly as
    # `ChatClient.adapt(_:)` does — including the lowercase "json" that `json_object` mode
    # requires to appear somewhere in the messages.
    system = (
        prompt_module.schema_in_prompt(prompt.system, prompt.schema_json)
        if provider.needs_schema_in_prompt
        else prompt.system
    )
    user_text = prompt_module.user_instruction(case.text, case.body_weight_lb)

    last_error: LLMError | None = None
    for attempt in range(max_attempts):
        try:
            reply = await client.complete(
                http,
                provider=provider,
                model=config.model,
                system=system,
                user_text=user_text,
                schema=prompt.schema,
                schema_name=SCHEMA_NAME,
                max_tokens=config.max_tokens,
                effort=config.effort,
                temperature=config.temperature,
            )
        except LLMError as error:
            last_error = error
            if not error.is_retryable or attempt == max_attempts - 1:
                break
            # Honour the server's own retry hint when it gave one; otherwise back off with
            # jitter, because a grid hits a rate limit on every worker at once and unjittered
            # retries would simply hit it again together.
            delay = error.retry_after or (2**attempt) + random.uniform(0, 1)
            await asyncio.sleep(min(delay, 30.0))
            continue

        payload = {
            "reply_text": reply.text,
            "latency_s": reply.latency_s,
            "input_tokens": reply.input_tokens,
            "output_tokens": reply.output_tokens,
            "stop": reply.stop,
        }
        if use_cache:
            _write_cache(key, payload)
        return _run_from_payload(payload, prompt, config, case, repeat, cached=False)

    assert last_error is not None
    failure = {"error_kind": last_error.kind, "error_message": last_error.message}
    # Failures are cached too, but only the ones that will not go away: re-running a grid after
    # a rate limit should retry it, while re-running after a typo'd model name should not spend
    # another four hundred requests learning the same thing.
    if use_cache and not last_error.is_retryable:
        _write_cache(key, failure)
    return _run_from_payload(failure, prompt, config, case, repeat, cached=False)


def _run_from_payload(
    payload: dict[str, Any],
    prompt: Prompt,
    config: RunConfig,
    case: Case,
    repeat: int,
    cached: bool,
) -> Run:
    base = dict(
        prompt=prompt.name,
        config=config.name,
        provider=config.provider,
        model=config.model,
        case_id=case.id,
        repeat=repeat,
        cached=cached,
    )

    if "error_kind" in payload:
        return Run(ok=False, error_kind=payload["error_kind"], error_message=payload.get("error_message", ""), **base)

    text = payload["reply_text"]
    parsed = parse_reply(text)
    input_tokens = payload.get("input_tokens", 0)
    output_tokens = payload.get("output_tokens", 0)

    return Run(
        ok=parsed.ok,
        # A reply that arrived but could not be used is a failure of the prompt, not of the
        # network, and keeping the two apart in one column is what makes the error breakdown
        # readable.
        error_kind=None if parsed.ok else (parsed.error or "").split(":")[0],
        error_message=parsed.error or "",
        latency_s=payload.get("latency_s"),
        input_tokens=input_tokens,
        output_tokens=output_tokens,
        cost_usd=cost_usd(config.model, input_tokens, output_tokens),
        reply_text=text,
        parsed=parsed,
        **base,
    )


# MARK: The grid


async def run_grid_async(
    cases: Sequence[Case],
    configs: Sequence[RunConfig],
    prompt_names: Sequence[str] = ("shipped",),
    repeats: int = 1,
    concurrency: int = 8,
    use_cache: bool = True,
    max_attempts: int = 3,
    progress: bool = True,
) -> list[Run]:
    loaded = [load_prompt(name) for name in prompt_names]
    jobs = [
        (prompt, config, case, repeat)
        for prompt in loaded
        for config in configs
        for case in cases
        for repeat in range(repeats)
    ]

    semaphore = asyncio.Semaphore(concurrency)
    done = 0
    started = time.perf_counter()

    async with httpx.AsyncClient(timeout=httpx.Timeout(120.0)) as http:

        async def worker(job) -> Run:
            nonlocal done
            async with semaphore:
                run = await _call_once(http, *job, use_cache=use_cache, max_attempts=max_attempts)
            done += 1
            if progress and (done % 10 == 0 or done == len(jobs)):
                elapsed = time.perf_counter() - started
                print(f"\r{done}/{len(jobs)} calls  ({elapsed:.0f}s)", end="", flush=True)
            return run

        runs = await asyncio.gather(*(worker(job) for job in jobs))

    if progress:
        live = sum(1 for run in runs if not run.cached)
        print(f"\n{len(runs)} results, {live} live calls, {len(runs) - live} from cache.")
    return list(runs)


def run_grid(*args: Any, **kwargs: Any) -> list[Run]:
    """Blocking wrapper, for scripts. In a notebook `await run_grid_async(...)` directly."""
    return asyncio.run(run_grid_async(*args, **kwargs))


def save_runs(runs: Iterable[Run], path: Path | str) -> Path:
    """Writes a run to JSONL, so a result from last week can be reloaded and compared."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for run in runs:
            payload = asdict(run)
            payload.pop("parsed", None)
            handle.write(json.dumps(payload, ensure_ascii=False) + "\n")
    return path
