"""Turning a list of `Run`s into tables you can read.

The bridge between `scoring.py`, which is stdlib-only so it stays testable anywhere, and the
notebook, which wants DataFrames. Nothing here decides what is correct — it only arranges.
"""

from __future__ import annotations

from typing import Iterable, Sequence

import pandas as pd

from tally_eval.dataset import Case
from tally_eval.runner import Run
from tally_eval.scoring import score_case, summarise


def runs_frame(runs: Iterable[Run]) -> pd.DataFrame:
    """One row per call: latency, tokens, cost, and whether it produced anything usable."""
    return pd.DataFrame([run.as_row() for run in runs])


def scores_frame(runs: Iterable[Run], cases: Sequence[Case]) -> pd.DataFrame:
    """One row per (prompt, config, case, repeat), scored against the reference values."""
    by_id = {case.id: case for case in cases}
    rows = []

    for run in runs:
        case = by_id.get(run.case_id)
        if case is None:
            continue

        if run.parsed is None:
            # The call never returned a reply — a transport or credential failure, not a
            # judgement about the prompt. Kept as a row so the cell's denominator is honest.
            row = {
                "case_id": run.case_id,
                "tags": ",".join(case.tags),
                "ok": False,
                "error": run.error_kind,
                "total_calories": None,
                "expected_total": None,
                "total_in_band": None,
                "total_error": None,
                "item_count": 0,
                "expected_item_count": len(case.required_items),
                "item_count_delta": -len(case.required_items),
                "matched_count": 0,
                "missing": "",
                "extra": "",
                "dropped_count": 0,
            }
        else:
            row = score_case(case, run.parsed).as_row()

        rows.append({"prompt": run.prompt, "config": run.config, "repeat": run.repeat, **row})

    frame = pd.DataFrame(rows, columns=_SCORE_COLUMNS)
    # Nullable dtypes rather than object, so `groupby(...).mean()` on a column holding
    # True/False/None works instead of raising — which is how every by-tag table is built.
    for column in ("ok", "total_in_band"):
        frame[column] = frame[column].astype("boolean")
    for column in ("total_calories", "expected_total", "total_error"):
        frame[column] = pd.to_numeric(frame[column], errors="coerce")
    return frame


_SCORE_COLUMNS = [
    "prompt", "config", "repeat", "case_id", "tags", "ok", "error",
    "total_calories", "expected_total", "total_in_band", "total_error",
    "item_count", "expected_item_count", "item_count_delta", "matched_count",
    "missing", "extra", "dropped_count",
    "calories_ok_rate", "protein_ok_rate", "fiber_ok_rate", "kind_ok_rate", "source_text_ok_rate",
]


def summary_frame(runs: Iterable[Run], cases: Sequence[Case]) -> pd.DataFrame:
    """Headline numbers per (config, prompt) — the table to read first.

    Repeats are pooled rather than averaged per case, so a model that answers a case correctly
    two times in three contributes both outcomes. That is the honest reading: the user gets one
    roll of the dice, not the average of three.
    """
    by_id = {case.id: case for case in cases}
    runs = list(runs)

    rows = []
    for (config, prompt), group in _grouped(runs):
        scored = [score_case(by_id[run.case_id], run.parsed) for run in group if run.parsed is not None and run.case_id in by_id]
        summary = summarise(scored)

        latencies = [run.latency_s for run in group if run.latency_s is not None]
        costs = [run.cost_usd for run in group if run.cost_usd is not None]
        transport_failures = sum(1 for run in group if run.parsed is None)

        rows.append(
            {
                "config": config,
                "prompt": prompt,
                **summary,
                "calls": len(group),
                "transport_failures": transport_failures,
                "p50_latency_s": pd.Series(latencies).median() if latencies else None,
                "p95_latency_s": pd.Series(latencies).quantile(0.95) if latencies else None,
                "mean_output_tokens": pd.Series([r.output_tokens for r in group]).mean(),
                # None rather than 0 when pricing.json has no entry, so a blank cell reads as
                # "unknown" instead of "free".
                "cost_per_call_usd": (sum(costs) / len(costs)) if costs else None,
            }
        )

    frame = pd.DataFrame(rows)
    return frame.set_index(["config", "prompt"]).sort_index() if not frame.empty else frame


def _grouped(runs: list[Run]):
    keys = sorted({(run.config, run.prompt) for run in runs})
    for key in keys:
        yield key, [run for run in runs if (run.config, run.prompt) == key]


def failures(runs: Iterable[Run], cases: Sequence[Case], limit: int | None = None) -> pd.DataFrame:
    """Every case that went wrong, with enough of the reply attached to see why.

    The most useful table in the notebook. A summary tells you prompt A beat prompt B; this
    tells you that B invented an entry for "weighed in at 183" and A did not.
    """
    by_id = {case.id: case for case in cases}
    rows = []

    for run in runs:
        case = by_id.get(run.case_id)
        if case is None:
            continue

        if run.parsed is None:
            rows.append(
                {
                    "prompt": run.prompt,
                    "config": run.config,
                    "case_id": run.case_id,
                    "text": case.text,
                    "problem": f"call failed: {run.error_kind}",
                    "detail": run.error_message[:200],
                    "reply": "",
                }
            )
            continue

        score = score_case(case, run.parsed)
        problems = []
        if not score.ok:
            problems.append(score.error or "unusable reply")
        if score.total_in_band is False:
            problems.append(f"total {score.total_calories} vs {score.expected_total:.0f} ({score.total_error:+.0%})")
        if score.missing:
            problems.append(f"missing: {', '.join(score.missing)}")
        if score.extra:
            problems.append(f"unexpected: {', '.join(score.extra)}")
        if score.dropped_count:
            problems.append(f"{score.dropped_count} item(s) the app would drop")

        if problems:
            rows.append(
                {
                    "prompt": run.prompt,
                    "config": run.config,
                    "case_id": run.case_id,
                    "text": case.text,
                    "problem": "; ".join(problems),
                    "detail": "; ".join(
                        f"{item.label} {item.calories}kcal" for item in run.parsed.items
                    ),
                    "reply": run.reply_text[:400],
                }
            )

    # Named columns even when there is nothing to report, so a clean run groups and filters like
    # any other rather than raising a KeyError on the happiest possible result.
    frame = pd.DataFrame(rows, columns=["prompt", "config", "case_id", "text", "problem", "detail", "reply"])
    return frame.head(limit) if limit else frame


def replies_for(runs: Iterable[Run], case_id: str) -> pd.DataFrame:
    """Every configuration's items for one case, side by side.

    For the moment in an experiment where the aggregate says two prompts differ and you want to
    see what that actually looked like.
    """
    rows = []
    for run in runs:
        if run.case_id != case_id or run.parsed is None:
            continue
        for item in run.parsed.items:
            rows.append(
                {
                    "prompt": run.prompt,
                    "config": run.config,
                    "repeat": run.repeat,
                    "label": item.label,
                    "kind": item.kind,
                    "calories": item.calories,
                    "protein_g": item.protein_grams,
                    "fiber_g": item.fiber_grams,
                    "duration_min": item.duration_minutes,
                    "confidence": item.confidence,
                    "source_text": item.source_text,
                }
            )
    return pd.DataFrame(rows)
