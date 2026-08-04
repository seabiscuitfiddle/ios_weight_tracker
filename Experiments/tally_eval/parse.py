"""Turning a reply into items, mirroring `LLMNutritionParser.result(fromJSON:)`.

This has to match the Swift closely or the harness measures the wrong thing. The app does not
score the model's raw JSON — it decodes leniently, enforces bounds the schema cannot express,
and *drops* items it cannot make sense of. A prompt that produces one absurd item out of four
loses that item in the app, so it should lose that item here too.

Everything dropped is recorded rather than discarded, because "which items did the app throw
away" is exactly the question a prompt experiment wants answered.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any

MAX_CALORIES = 20_000
MAX_GRAMS = 1_000
KINDS = {"food", "exercise"}
EXERCISE_KINDS = {"cardio", "strength", "other"}
CONFIDENCES = {"high", "medium", "low"}
NO_EXERCISE_KIND = "none"


@dataclass
class ParsedItem:
    kind: str
    label: str
    calories: int
    protein_grams: float = 0.0
    fiber_grams: float = 0.0
    source_text: str | None = None
    exercise_kind: str | None = None
    duration_minutes: int | None = None
    confidence: str = "low"

    def as_dict(self) -> dict[str, Any]:
        return {
            "kind": self.kind,
            "label": self.label,
            "calories": self.calories,
            "protein_grams": self.protein_grams,
            "fiber_grams": self.fiber_grams,
            "source_text": self.source_text,
            "exercise_kind": self.exercise_kind,
            "duration_minutes": self.duration_minutes,
            "confidence": self.confidence,
        }


@dataclass
class ParseResult:
    items: list[ParsedItem] = field(default_factory=list)
    note: str | None = None
    #: Items the app would have silently dropped, each with the reason. The most useful column
    #: in the whole harness when a provider without native schema enforcement is in play.
    dropped: list[dict[str, Any]] = field(default_factory=list)
    #: Set when the reply could not be used at all — the app's `nothingRecognized` and
    #: `malformedResponse` cases.
    error: str | None = None

    @property
    def ok(self) -> bool:
        return self.error is None


# MARK: Lenient scalars, mirroring `decodeLenient`


def _lenient_str(value: Any) -> str | None:
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return str(value)
    return None


def _lenient_int(value: Any) -> int | None:
    """Models under JSON-mode-only providers return `"280"`, `280.0` and `280` interchangeably."""
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return round(value)
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            try:
                return round(float(value))
            except ValueError:
                return None
    return None


def _lenient_float(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        try:
            return float(value)
        except ValueError:
            return None
    return None


# MARK: One item, mirroring `item(from:)`


def item_from_wire(wire: dict[str, Any]) -> tuple[ParsedItem | None, str | None]:
    """Converts one wire item, or explains why the app would drop it."""
    if not isinstance(wire, dict):
        return None, "item was not an object"

    kind = _lenient_str(wire.get("kind")) or ""
    if kind not in KINDS:
        return None, f"unknown kind {kind!r}"

    label = (_lenient_str(wire.get("label")) or "").strip()
    if not label:
        return None, "blank label"

    calories = _lenient_int(wire.get("calories"))
    if calories is None:
        return None, "calories missing or not a number"
    # A day's eating tops out well below the ceiling; anything beyond is a decimal-point error,
    # and silently logging 40,000 calories would wreck the trend the goal engine reads.
    if not 0 <= calories <= MAX_CALORIES:
        return None, f"calories out of range ({calories})"

    # Blank is the documented answer for "no words behind this one", and it is also what a
    # provider that ignored the field leaves behind. Both mean the same thing here.
    source_text = (_lenient_str(wire.get("source_text") or wire.get("sourceText")) or "").strip()

    exercise_kind = None
    if kind == "exercise":
        raw = _lenient_str(wire.get("exercise_kind") or wire.get("exerciseKind")) or ""
        exercise_kind = raw if raw in EXERCISE_KINDS else "other"

    duration = _lenient_int(wire.get("duration_minutes") or wire.get("durationMinutes")) or 0
    confidence = _lenient_str(wire.get("confidence")) or ""

    is_food = kind == "food"
    return (
        ParsedItem(
            kind=kind,
            label=label,
            calories=calories,
            protein_grams=_clamp(_lenient_float(wire.get("protein_grams") or wire.get("proteinGrams")) or 0.0) if is_food else 0.0,
            fiber_grams=_clamp(_lenient_float(wire.get("fiber_grams") or wire.get("fiberGrams")) or 0.0) if is_food else 0.0,
            source_text=source_text or None,
            exercise_kind=exercise_kind,
            duration_minutes=duration if duration > 0 else None,
            confidence=confidence if confidence in CONFIDENCES else "low",
        ),
        None,
    )


def _clamp(value: float) -> float:
    return max(0.0, min(value, MAX_GRAMS))


# MARK: The whole reply


def parse_reply(text: str) -> ParseResult:
    """Decodes a reply the way the app does, keeping the reasons for anything lost."""
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as error:
        return ParseResult(error=f"malformed_response: not JSON ({error})")

    if not isinstance(payload, dict):
        return ParseResult(error="malformed_response: top level was not an object")

    note = payload.get("note")
    note = note.strip() if isinstance(note, str) else None

    raw_items = payload.get("items")
    if not isinstance(raw_items, list):
        return ParseResult(note=note or None, error="malformed_response: `items` was not an array")

    items: list[ParsedItem] = []
    dropped: list[dict[str, Any]] = []
    for raw in raw_items:
        item, reason = item_from_wire(raw)
        if item is None:
            dropped.append({"reason": reason, "item": raw})
        else:
            items.append(item)

    if not items:
        # The app's `nothingRecognized`, which it shows to the user as an error rather than as an
        # empty log — so it is a failed case here too, whatever the model's intent was.
        return ParseResult(
            note=note or None,
            dropped=dropped,
            error=f"nothing_recognized: {note}" if note else "nothing_recognized",
        )

    return ParseResult(items=items, note=note or None, dropped=dropped)
