"""Turning a reply into numbers you can compare across prompts and models.

Three levels, because they answer different questions and disagree more often than you would
expect:

  * **Case level** — did the app end up with something usable at all, and is the day's total
    right? This is the metric that matters most and the one most robust to a defensible
    difference of opinion: a model that returns "oatmeal with blueberries and honey" as one item
    and a model that returns three are both correct, and both should total the same.
  * **Item level** — were the individual things identified, split, and labelled the way the
    prompt asks? This is where prompt wording actually shows up, and where a model that totals
    correctly can still be doing the wrong thing.
  * **Field level** — calories, protein, fiber, kind, and whether `sourceText` carries the
    user's own words for that item alone.

Scores are "inside the band or not" rather than squared error. There is no true calorie count
for a bowl of chili, and a metric that pretends otherwise ranks prompts by how closely they
agree with one person's guess.
"""

from __future__ import annotations

import difflib
import statistics
from dataclasses import dataclass, field
from typing import Any, Iterable

from tally_eval.dataset import Case, ExpectedItem
from tally_eval.parse import ParsedItem, ParseResult

#: Below this, two labels are different foods rather than differently worded ones.
LABEL_SIMILARITY_FLOOR = 0.6


@dataclass
class ItemScore:
    expected_label: str
    actual_label: str | None
    matched: bool
    kind_ok: bool | None = None
    exercise_kind_ok: bool | None = None
    calories_ok: bool | None = None
    calorie_error: float | None = None
    protein_ok: bool | None = None
    fiber_ok: bool | None = None
    source_text_ok: bool | None = None
    actual_calories: int | None = None
    expected_calories: float | None = None


@dataclass
class CaseScore:
    case_id: str
    tags: list[str]
    #: The reply was usable: it decoded, and it produced items where items were wanted.
    ok: bool
    error: str | None = None
    total_calories: int | None = None
    expected_total: float | None = None
    total_in_band: bool | None = None
    #: Signed fractional error on the day's total. The number to plot.
    total_error: float | None = None
    item_count: int = 0
    expected_item_count: int = 0
    matched_count: int = 0
    missing: list[str] = field(default_factory=list)
    extra: list[str] = field(default_factory=list)
    dropped_count: int = 0
    items: list[ItemScore] = field(default_factory=list)

    def as_row(self) -> dict[str, Any]:
        """Flat, for a DataFrame."""
        field_scores = [
            ("calories_ok", [i.calories_ok for i in self.items]),
            ("protein_ok", [i.protein_ok for i in self.items]),
            ("fiber_ok", [i.fiber_ok for i in self.items]),
            ("kind_ok", [i.kind_ok for i in self.items]),
            ("source_text_ok", [i.source_text_ok for i in self.items]),
        ]
        row: dict[str, Any] = {
            "case_id": self.case_id,
            "tags": ",".join(self.tags),
            "ok": self.ok,
            "error": self.error,
            "total_calories": self.total_calories,
            "expected_total": self.expected_total,
            "total_in_band": self.total_in_band,
            "total_error": self.total_error,
            "item_count": self.item_count,
            "expected_item_count": self.expected_item_count,
            "item_count_delta": self.item_count - self.expected_item_count,
            "matched_count": self.matched_count,
            "missing": ",".join(self.missing),
            "extra": ",".join(self.extra),
            "dropped_count": self.dropped_count,
        }
        for name, values in field_scores:
            present = [v for v in values if v is not None]
            row[f"{name}_rate"] = sum(present) / len(present) if present else None
        return row


# MARK: Matching expected items to returned ones


def _affinity(expected: ExpectedItem, item: ParsedItem) -> float:
    """How well one returned item answers one expected item; 0 when it plainly does not.

    Keyword hits beat fuzzy label similarity, because the keywords were written to identify the
    item across every reasonable phrasing and the label was written to read nicely.
    """
    haystack = f"{item.label} {item.source_text or ''}".lower()
    if any(keyword.lower() in haystack for keyword in expected.match):
        return 1.0 + difflib.SequenceMatcher(None, expected.label.lower(), item.label.lower()).ratio()

    similarity = difflib.SequenceMatcher(None, expected.label.lower(), item.label.lower()).ratio()
    return similarity if similarity >= LABEL_SIMILARITY_FLOOR else 0.0


def match_items(
    expected_items: Iterable[ExpectedItem], items: Iterable[ParsedItem]
) -> tuple[list[tuple[ExpectedItem, ParsedItem]], list[ExpectedItem], list[ParsedItem]]:
    """Greedy best-first pairing. Returns pairs, unmatched expectations, and unexpected items.

    Greedy rather than optimal: the lists are three items long, the affinity gaps are wide, and
    an assignment algorithm here would be precision the data does not support.
    """
    expected_list = list(expected_items)
    item_list = list(items)

    candidates = sorted(
        (
            (_affinity(expected, item), e_index, i_index)
            for e_index, expected in enumerate(expected_list)
            for i_index, item in enumerate(item_list)
        ),
        key=lambda triple: triple[0],
        reverse=True,
    )

    pairs: list[tuple[ExpectedItem, ParsedItem]] = []
    used_expected: set[int] = set()
    used_items: set[int] = set()
    for affinity, e_index, i_index in candidates:
        if affinity <= 0 or e_index in used_expected or i_index in used_items:
            continue
        used_expected.add(e_index)
        used_items.add(i_index)
        pairs.append((expected_list[e_index], item_list[i_index]))

    missing = [e for index, e in enumerate(expected_list) if index not in used_expected]
    extra = [i for index, i in enumerate(item_list) if index not in used_items]
    return pairs, missing, extra


# MARK: Scoring one case


def score_case(case: Case, result: ParseResult) -> CaseScore:
    if case.expect_empty:
        return _score_empty_case(case, result)

    if not result.ok:
        return CaseScore(
            case_id=case.id,
            tags=case.tags,
            ok=False,
            error=result.error,
            expected_item_count=len(case.required_items),
            expected_total=_expected_total(case),
            dropped_count=len(result.dropped),
        )

    pairs, missing, extra = match_items(case.expected_items, result.items)

    item_scores = [_score_item(expected, item) for expected, item in pairs]
    item_scores += [
        ItemScore(expected_label=expected.label, actual_label=None, matched=False)
        for expected in missing
        if not expected.optional
    ]

    total = sum(item.calories for item in result.items)
    expected_total = _expected_total(case)
    band = _total_band(case)

    return CaseScore(
        case_id=case.id,
        tags=case.tags,
        ok=True,
        total_calories=total,
        expected_total=expected_total,
        total_in_band=None if band is None else band[0] <= total <= band[1],
        total_error=None if not expected_total else (total - expected_total) / expected_total,
        item_count=len(result.items),
        expected_item_count=len(case.required_items),
        matched_count=len(pairs),
        missing=[expected.label for expected in missing if not expected.optional],
        extra=[item.label for item in extra],
        dropped_count=len(result.dropped),
        items=item_scores,
    )


def _score_empty_case(case: Case, result: ParseResult) -> CaseScore:
    """A case whose right answer is "there is nothing here".

    The app surfaces an empty reply as `nothingRecognized` and shows the model's note, so both an
    explicit empty `items` array and that error count as correct. Anything else means an entry
    the user never asked for got logged.
    """
    invented = result.ok and bool(result.items)
    return CaseScore(
        case_id=case.id,
        tags=case.tags,
        ok=not invented,
        error=None if not invented else f"invented {len(result.items)} item(s)",
        item_count=len(result.items) if result.ok else 0,
        expected_item_count=0,
        extra=[item.label for item in result.items] if result.ok else [],
        dropped_count=len(result.dropped),
    )


def _score_item(expected: ExpectedItem, item: ParsedItem) -> ItemScore:
    score = ItemScore(
        expected_label=expected.label,
        actual_label=item.label,
        matched=True,
        kind_ok=item.kind == expected.kind,
        actual_calories=item.calories,
        expected_calories=expected.calories,
    )

    if expected.exercise_kind is not None:
        score.exercise_kind_ok = item.exercise_kind == expected.exercise_kind

    if (band := expected.calorie_band()) is not None and expected.calories:
        score.calories_ok = band[0] <= item.calories <= band[1]
        score.calorie_error = (item.calories - expected.calories) / expected.calories

    if expected.protein_grams is not None:
        low, high = expected.macro_band(expected.protein_grams)
        score.protein_ok = low <= item.protein_grams <= high

    if expected.fiber_grams is not None:
        low, high = expected.macro_band(expected.fiber_grams)
        score.fiber_ok = low <= item.fiber_grams <= high

    if expected.source_text is not None:
        # The prompt asks for the user's own words for this item alone. Checking that the
        # fragment is present catches a model that returned nothing; checking it is shorter than
        # the whole input catches the far more common failure of echoing the entire sentence
        # onto every item.
        score.source_text_ok = bool(
            item.source_text and expected.source_text.lower() in item.source_text.lower()
        )

    return score


def _expected_total(case: Case) -> float | None:
    values = [item.calories for item in case.expected_items if item.calories is not None]
    return float(sum(values)) if values else None


def _total_band(case: Case) -> tuple[float, float] | None:
    """The day-total band, as the sum of the per-item bands.

    Additive rather than a percentage of the total: it keeps a case's tight items tight, and it
    is the honest reading of "each of these could be off by this much".
    """
    bands = [item.calorie_band() for item in case.expected_items]
    present = [band for band in bands if band is not None]
    if not present:
        return None
    return sum(low for low, _ in present), sum(high for _, high in present)


# MARK: Aggregating a run


def summarise(scores: list[CaseScore]) -> dict[str, Any]:
    """Headline numbers for one (prompt, model) cell.

    `total_mape` is the median absolute error on the day's total, not the mean: one case where a
    model answered per-100g would otherwise dominate the average and hide everything else.
    """
    if not scores:
        return {}

    usable = [score for score in scores if score.ok]
    totals = [abs(score.total_error) for score in usable if score.total_error is not None]
    in_band = [score.total_in_band for score in usable if score.total_in_band is not None]

    matched = sum(score.matched_count for score in scores)
    expected_items = sum(score.expected_item_count for score in scores)
    returned_items = sum(score.item_count for score in scores)

    precision = matched / returned_items if returned_items else 0.0
    recall = matched / expected_items if expected_items else 0.0

    return {
        "cases": len(scores),
        "usable_rate": len(usable) / len(scores),
        "total_in_band_rate": (sum(in_band) / len(in_band)) if in_band else None,
        "total_mape": statistics.median(totals) if totals else None,
        "item_precision": precision,
        "item_recall": recall,
        "item_f1": (2 * precision * recall / (precision + recall)) if (precision + recall) else 0.0,
        "calories_ok_rate": _field_rate(scores, "calories_ok"),
        "protein_ok_rate": _field_rate(scores, "protein_ok"),
        "fiber_ok_rate": _field_rate(scores, "fiber_ok"),
        "source_text_ok_rate": _field_rate(scores, "source_text_ok"),
        "dropped_items": sum(score.dropped_count for score in scores),
    }


def _field_rate(scores: list[CaseScore], attribute: str) -> float | None:
    values = [
        getattr(item, attribute)
        for score in scores
        for item in score.items
        if getattr(item, attribute) is not None
    ]
    return sum(values) / len(values) if values else None
