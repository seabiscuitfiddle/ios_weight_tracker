"""Charts for the notebook.

Three of them, because three questions are worth a picture and the rest are worth a table:
how accurate each prompt is, how long each configuration makes the user wait, and which
individual cases a configuration gets wrong and in which direction.

The palette is a validated categorical set — hues assigned to prompts in fixed slot order and
never cycled, so a prompt keeps its colour when you add or drop one from the comparison. Signed
error uses a diverging blue/red pair around a neutral midpoint, because the sign is the point:
under-counting a meal and over-counting it are different failures.
"""

from __future__ import annotations

from typing import Any, Sequence

import matplotlib as mpl
import matplotlib.pyplot as plt
import pandas as pd

#: Categorical slots, in the order they must be assigned. Identity, never rank: a prompt keeps
#: its colour when the comparison gains or loses a column.
CATEGORICAL = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7", "#e34948"]
#: Diverging poles for signed error, with a neutral middle so "no error" reads as nothing.
UNDER, OVER, NEUTRAL = "#2a78d6", "#e34948", "#f0efec"

INK = "#0b0b0b"
INK_SECONDARY = "#52514e"
INK_MUTED = "#8a8880"
SURFACE = "#fcfcfb"
GRID = "#e5e4e0"


def use_style() -> None:
    """Recessive grid, no chartjunk, text in ink rather than in series colour."""
    mpl.rcParams.update(
        {
            "figure.facecolor": SURFACE,
            "axes.facecolor": SURFACE,
            "axes.edgecolor": GRID,
            "axes.labelcolor": INK_SECONDARY,
            "axes.titlecolor": INK,
            "axes.titlesize": 12,
            "axes.titleweight": "medium",
            "axes.titlelocation": "left",
            "axes.titlepad": 12,
            "axes.labelsize": 10,
            "axes.spines.top": False,
            "axes.spines.right": False,
            "axes.grid": True,
            "grid.color": GRID,
            "grid.linewidth": 0.8,
            "text.color": INK,
            "xtick.color": INK_MUTED,
            "ytick.color": INK_MUTED,
            "xtick.labelsize": 9,
            "ytick.labelsize": 9,
            "legend.frameon": False,
            "legend.fontsize": 9,
            "figure.dpi": 120,
            "savefig.facecolor": SURFACE,
            "font.size": 10,
            "lines.linewidth": 2,
        }
    )


def colour_for(names: Sequence[str]) -> dict[str, str]:
    """Fixed slot assignment. Past eight, fold the rest into one muted colour rather than cycle."""
    mapping = {name: CATEGORICAL[index] for index, name in enumerate(names[: len(CATEGORICAL)])}
    for name in names[len(CATEGORICAL) :]:
        mapping[name] = INK_MUTED
    return mapping


# MARK: Accuracy


def accuracy_chart(
    summary: pd.DataFrame,
    metric: str = "total_in_band_rate",
    title: str = "Day totals inside the reference band",
    ax: Any = None,
):
    """Grouped horizontal bars: one group per model, one bar per prompt.

    Horizontal because model identifiers are long and a rotated x-label is a tax on every
    reading of the chart. Values are direct-labelled — there are a dozen bars, not a hundred,
    and the number is the thing being compared.

    `summary` is the frame from `summarise_runs`, indexed by (config, prompt).
    """
    frame = summary[metric].unstack("prompt")
    prompts = list(frame.columns)
    colours = colour_for(prompts)

    if ax is None:
        _, ax = plt.subplots(figsize=(8, 0.45 * len(frame) * max(len(prompts), 1) + 1.6))

    height = 0.8 / len(prompts)
    positions = range(len(frame))

    for index, prompt in enumerate(prompts):
        offsets = [position + index * height - 0.4 + height / 2 for position in positions]
        values = frame[prompt].fillna(0)
        # A 2px surface gap between adjacent bars, so touching bars stay legible as two marks.
        bars = ax.barh(
            offsets, values, height=height * 0.88, color=colours[prompt], label=prompt, zorder=3
        )
        for bar, value in zip(bars, values):
            if pd.isna(value):
                continue
            ax.text(
                value + 0.015,
                bar.get_y() + bar.get_height() / 2,
                f"{value:.0%}",
                va="center",
                fontsize=8,
                color=INK_SECONDARY,
            )

    ax.set_yticks(list(positions))
    ax.set_yticklabels(frame.index, fontsize=9, color=INK)
    ax.set_xlim(0, 1.08)
    ax.xaxis.set_major_formatter(mpl.ticker.PercentFormatter(xmax=1))
    ax.set_xlabel(metric.replace("_", " "))
    ax.set_title(title)
    ax.grid(axis="y", visible=False)
    ax.set_axisbelow(True)
    if len(prompts) > 1:
        ax.legend(loc="lower right", ncols=min(len(prompts), 3))
    return ax


# MARK: Latency


def latency_chart(runs: pd.DataFrame, title: str = "Time to a parsed reply", ax: Any = None):
    """Median latency per configuration, with the p50–p95 span behind it.

    A dot with a span rather than a box plot: the two numbers anyone acts on are "usually this
    fast" and "occasionally this slow", and a box plot spends most of its ink on quartiles
    nobody will use. One series, so no legend — the title names it.
    """
    live = runs[runs["latency_s"].notna()]
    stats = (
        live.groupby("config")["latency_s"]
        .agg(p50="median", p95=lambda values: values.quantile(0.95))
        .sort_values("p50")
    )

    if ax is None:
        _, ax = plt.subplots(figsize=(8, 0.4 * len(stats) + 1.6))

    positions = range(len(stats))
    ax.hlines(list(positions), stats["p50"], stats["p95"], color=GRID, linewidth=6, zorder=2)
    ax.scatter(stats["p50"], list(positions), s=64, color=CATEGORICAL[0], zorder=3)

    for position, (p50, p95) in enumerate(zip(stats["p50"], stats["p95"])):
        ax.text(p95 + 0.15, position, f"p50 {p50:.1f}s · p95 {p95:.1f}s", va="center", fontsize=8, color=INK_SECONDARY)

    ax.set_yticks(list(positions))
    ax.set_yticklabels(stats.index, fontsize=9, color=INK)
    ax.set_xlabel("seconds")
    ax.set_xlim(left=0)
    ax.margins(x=0.28)
    ax.set_title(title)
    ax.grid(axis="y", visible=False)
    ax.set_axisbelow(True)
    return ax


# MARK: Per-case error


def error_chart(
    scores: pd.DataFrame,
    config: str,
    prompt: str = "shipped",
    title: str | None = None,
    ax: Any = None,
):
    """Signed error on each case's day total, for one (prompt, model) cell.

    Diverging around zero because the direction matters: a tracker that reads low every day
    tells someone they can eat more, which is the more damaging way to be wrong. Cases are
    sorted by error rather than by name so the tails are adjacent and readable.
    """
    cell = scores[(scores["config"] == config) & (scores["prompt"] == prompt)]
    cell = cell[cell["total_error"].notna()].sort_values("total_error")
    if cell.empty:
        raise ValueError(f"No scored cases for prompt={prompt!r}, config={config!r}.")

    if ax is None:
        _, ax = plt.subplots(figsize=(8, 0.3 * len(cell) + 1.8))

    colours = [OVER if value > 0 else UNDER for value in cell["total_error"]]
    positions = range(len(cell))
    ax.barh(list(positions), cell["total_error"], color=colours, height=0.7, zorder=3)
    ax.axvline(0, color=INK_MUTED, linewidth=1, zorder=4)

    ax.set_yticks(list(positions))
    ax.set_yticklabels(cell["case_id"], fontsize=8, color=INK)
    ax.xaxis.set_major_formatter(mpl.ticker.PercentFormatter(xmax=1))
    ax.set_xlabel("error on the day total  ← under · over →")
    ax.set_title(title or f"{prompt} · {config}")
    ax.grid(axis="y", visible=False)
    ax.set_axisbelow(True)
    return ax
