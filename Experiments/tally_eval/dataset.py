"""The known entries a prompt is scored against.

One JSONL file, one case per line, so a case can be added mid-experiment by appending a line and
the diff of "what changed about the dataset" is readable in review.

A case says what the user typed and what the app should have ended up with. It deliberately does
not pin exact numbers: there is no true calorie count for "a bowl of chili", only a range a
reasonable person would accept. So every expected item carries a tolerance, and scoring asks
whether the estimate landed inside it rather than whether it matched to the calorie.

    id                 stable, used as the cache key and the row label
    text               exactly what the user typed
    body_weight_lb     when set, sent as context — exercise energy scales with body mass
    tags               free-form, for slicing results ("splitting", "exercise", "no-portion")
    expected_items     what should come back, in no particular order
    expect_empty       true when the right answer is "there is no food or exercise here"
    reference          where the numbers came from, so a disputed one can be traced

Each expected item:

    label              a human-readable name, for reading the results table
    match              lowercase substrings that identify this item in a reply; any one matches
    kind               "food" or "exercise"
    calories           the reference value
    calorie_tolerance  fractional band, defaulting to CALORIE_TOLERANCE
    calorie_floor      absolute band in kcal, so a 2 kcal coffee is not scored on percentages
    protein_grams      reference, or null to skip scoring protein for this item
    fiber_grams        reference, or null to skip
    source_text        substring the item's `sourceText` should contain, or null to skip
    optional           true when a reply that folds this into another item is still acceptable
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

DATASETS_DIR = Path(__file__).resolve().parent.parent / "datasets"
DEFAULT_DATASET = DATASETS_DIR / "known_entries.jsonl"

#: Default band on calories. Wide on purpose: the app's own copy says every number is editable,
#: and a prompt that lands within a third of a reasonable reference has done its job. Tighten it
#: per case where the true answer really is narrow — a boiled egg, a labelled packet.
CALORIE_TOLERANCE = 0.30
#: Absolute floor, so small numbers are not scored on percentages. 30% of a 5 kcal coffee is
#: 1.5 kcal, which no model should be asked to hit.
CALORIE_FLOOR = 25.0
#: Macros are estimated far more loosely than energy across every model, so their band is wider.
MACRO_TOLERANCE = 0.50
MACRO_FLOOR = 4.0


@dataclass
class ExpectedItem:
    label: str
    match: list[str]
    kind: str = "food"
    calories: float | None = None
    calorie_tolerance: float = CALORIE_TOLERANCE
    calorie_floor: float = CALORIE_FLOOR
    protein_grams: float | None = None
    fiber_grams: float | None = None
    source_text: str | None = None
    exercise_kind: str | None = None
    optional: bool = False

    def calorie_band(self) -> tuple[float, float] | None:
        if self.calories is None:
            return None
        width = max(self.calories * self.calorie_tolerance, self.calorie_floor)
        return max(0.0, self.calories - width), self.calories + width

    def macro_band(self, reference: float) -> tuple[float, float]:
        width = max(reference * MACRO_TOLERANCE, MACRO_FLOOR)
        return max(0.0, reference - width), reference + width

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> ExpectedItem:
        known = {f for f in cls.__dataclass_fields__}
        unknown = set(raw) - known
        if unknown:
            raise ValueError(f"Unknown keys on expected item {raw.get('label')!r}: {sorted(unknown)}")
        return cls(**raw)


@dataclass
class Case:
    id: str
    text: str
    expected_items: list[ExpectedItem] = field(default_factory=list)
    body_weight_lb: float | None = None
    tags: list[str] = field(default_factory=list)
    expect_empty: bool = False
    reference: str = ""

    @property
    def required_items(self) -> list[ExpectedItem]:
        return [item for item in self.expected_items if not item.optional]

    @classmethod
    def from_dict(cls, raw: dict[str, Any]) -> Case:
        raw = dict(raw)
        items = [ExpectedItem.from_dict(item) for item in raw.pop("expected_items", [])]
        known = {f for f in cls.__dataclass_fields__} - {"expected_items"}
        unknown = set(raw) - known
        if unknown:
            raise ValueError(f"Unknown keys on case {raw.get('id')!r}: {sorted(unknown)}")
        return cls(expected_items=items, **raw)


def load_dataset(path: Path | str = DEFAULT_DATASET, tags: list[str] | None = None) -> list[Case]:
    """Reads the JSONL dataset, optionally keeping only cases carrying one of `tags`.

    Blank lines and `#` comments are skipped so the file can be annotated in place — which is
    where the reasoning about a disputed reference value belongs.
    """
    path = Path(path)
    cases: list[Case] = []
    seen: set[str] = set()

    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        try:
            case = Case.from_dict(json.loads(stripped))
        except (json.JSONDecodeError, ValueError, TypeError) as error:
            raise ValueError(f"{path.name}:{number}: {error}") from error
        if case.id in seen:
            # Ids are cache keys and row labels; a duplicate silently overwrites results.
            raise ValueError(f"{path.name}:{number}: duplicate case id {case.id!r}")
        seen.add(case.id)
        cases.append(case)

    if tags:
        wanted = set(tags)
        cases = [case for case in cases if wanted & set(case.tags)]
    return cases


def save_dataset(cases: list[Case], path: Path | str = DEFAULT_DATASET) -> None:
    """Writes cases back out, one compact line each.

    Useful after correcting reference values in a notebook — but note it drops any comments the
    file carried, so prefer editing the file directly when you are only changing a number.
    """
    path = Path(path)
    lines = []
    for case in cases:
        payload: dict[str, Any] = {"id": case.id, "text": case.text}
        if case.body_weight_lb is not None:
            payload["body_weight_lb"] = case.body_weight_lb
        if case.tags:
            payload["tags"] = case.tags
        if case.expect_empty:
            payload["expect_empty"] = True
        payload["expected_items"] = [
            {
                key: value
                for key, value in item.__dict__.items()
                if value != ExpectedItem.__dataclass_fields__[key].default or key in {"label", "match"}
            }
            for item in case.expected_items
        ]
        if case.reference:
            payload["reference"] = case.reference
        lines.append(json.dumps(payload, ensure_ascii=False))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
