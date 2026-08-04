"""Offline harness for Tally's nutrition-parsing prompt.

Mirrors the request the app sends — same system prompt, same JSON Schema, same per-provider
quirks — so that a number measured here is a number the app would have got. The Swift is the
source of truth for all of it; this package's job is to make it cheap to vary one thing at a
time and see what happens.

The seams are the same ones the Swift draws, for the same reason:

    prompts.py     what to say          — a directory of files, not literals in code
    providers.py   where to send it     — data, so a new provider is a dict and not a class
    client.py      how to send it       — one encoder per wire format, behind `complete()`
    parse.py       what came back       — the app's leniency and bounds, reimplemented
    dataset.py     what is true         — known entries with reference values
    scoring.py     how wrong it was     — item matching and per-field error
    runner.py      all of it, in bulk   — a grid of prompt x model, with caching
    sync_prompt.py the baseline         — regenerates prompts/shipped.* from the Swift

Names are exported lazily so that `sync_prompt` — the one piece worth running in CI — keeps
working on a checkout with no third-party packages installed at all.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

_EXPORTS = {
    "Case": "tally_eval.dataset",
    "ExpectedItem": "tally_eval.dataset",
    "load_dataset": "tally_eval.dataset",
    "save_dataset": "tally_eval.dataset",
    "ParseResult": "tally_eval.parse",
    "ParsedItem": "tally_eval.parse",
    "parse_reply": "tally_eval.parse",
    "Prompt": "tally_eval.prompts",
    "available_prompts": "tally_eval.prompts",
    "load_prompt": "tally_eval.prompts",
    "user_instruction": "tally_eval.prompts",
    "PROVIDERS": "tally_eval.providers",
    "Provider": "tally_eval.providers",
    "cost_usd": "tally_eval.providers",
    "local": "tally_eval.providers",
    "Run": "tally_eval.runner",
    "RunConfig": "tally_eval.runner",
    "clear_cache": "tally_eval.runner",
    "run_grid": "tally_eval.runner",
    "run_grid_async": "tally_eval.runner",
    "save_runs": "tally_eval.runner",
    "CaseScore": "tally_eval.scoring",
    "score_case": "tally_eval.scoring",
    "summarise": "tally_eval.scoring",
}

__all__ = sorted(_EXPORTS)


def __getattr__(name: str):
    module_name = _EXPORTS.get(name)
    if module_name is None:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    from importlib import import_module

    return getattr(import_module(module_name), name)


def __dir__() -> list[str]:
    return __all__


if TYPE_CHECKING:  # For editors and type checkers, which cannot follow the lazy path.
    from tally_eval.dataset import Case, ExpectedItem, load_dataset, save_dataset
    from tally_eval.parse import ParsedItem, ParseResult, parse_reply
    from tally_eval.prompts import Prompt, available_prompts, load_prompt, user_instruction
    from tally_eval.providers import PROVIDERS, Provider, cost_usd, local
    from tally_eval.runner import Run, RunConfig, clear_cache, run_grid, run_grid_async, save_runs
    from tally_eval.scoring import CaseScore, score_case, summarise
