"""Loading prompts and schemas from `Experiments/prompts/`.

A prompt is a file, never a Python literal. That is what lets a variant be created by copying
one and editing prose, diffed in review like anything else, and named in a results table without
the name being a lie about which text was sent.

    prompts/shipped.md            the app's prompt, generated from Swift — see sync_prompt.py
    prompts/shipped.schema.json   the app's output schema, likewise
    prompts/<name>.md             a variant
    prompts/<name>.schema.json    that variant's schema, if it needs its own

A variant with no schema file of its own uses `shipped.schema.json`, because most experiments
are about wording and changing the schema underneath them would confound the comparison.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

PROMPTS_DIR = Path(__file__).resolve().parent.parent / "prompts"
BASELINE = "shipped"

_HTML_COMMENT = re.compile(r"<!--.*?-->\s*", re.DOTALL)


@dataclass(frozen=True)
class Prompt:
    """One system prompt plus the reply schema it was written for."""

    name: str
    system: str
    schema: dict[str, Any]
    #: Free-form, for the results table — "baseline", "no few-shot", whatever you are testing.
    notes: str = ""
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def schema_json(self) -> str:
        """The schema as the text a request carries. Sorted so a diff of two runs is readable."""
        return json.dumps(self.schema, indent=2, sort_keys=True)

    def __str__(self) -> str:
        return f"Prompt({self.name!r}, {len(self.system)} chars)"


def available_prompts() -> list[str]:
    """Every prompt in the directory, baseline first and the rest alphabetical."""
    names = sorted(path.stem for path in PROMPTS_DIR.glob("*.md"))
    if BASELINE in names:
        names.remove(BASELINE)
        names.insert(0, BASELINE)
    return names


@lru_cache(maxsize=None)
def load_prompt(name: str = BASELINE) -> Prompt:
    """Reads `<name>.md`, falling back to the baseline schema when it has none of its own."""
    system_path = PROMPTS_DIR / f"{name}.md"
    if not system_path.exists():
        raise FileNotFoundError(
            f"No prompt named {name!r} in {PROMPTS_DIR}. Available: {', '.join(available_prompts())}"
        )

    text = system_path.read_text(encoding="utf-8")
    # The generated-file banner is an instruction to a human reading the repository, not to the
    # model, so it is stripped rather than sent.
    system = _HTML_COMMENT.sub("", text, count=1).strip()

    schema_path = PROMPTS_DIR / f"{name}.schema.json"
    if not schema_path.exists():
        schema_path = PROMPTS_DIR / f"{BASELINE}.schema.json"
    if not schema_path.exists():
        raise FileNotFoundError(
            f"No schema for {name!r} and no baseline schema at {schema_path}. "
            "Run `python -m tally_eval.sync_prompt`."
        )

    schema = json.loads(schema_path.read_text(encoding="utf-8"))

    notes_path = PROMPTS_DIR / f"{name}.notes.txt"
    notes = notes_path.read_text(encoding="utf-8").strip() if notes_path.exists() else ""

    return Prompt(name=name, system=system, schema=schema, notes=notes)


def user_instruction(text: str, body_weight_pounds: float | None = None) -> str:
    """The user turn, exactly as `ParsePrompt.userInstruction(for:context:)` builds it.

    Kept in step with the Swift by hand, because it is four lines and generating it would cost
    more than it saves — but it is the one piece here that can silently drift, so it is worth
    re-reading when the Swift changes. Photo inputs are out of scope for this harness.
    """
    lines: list[str] = []
    if body_weight_pounds is not None and body_weight_pounds > 0:
        lines.append(f"Body weight: {round(body_weight_pounds)} lb.")
    lines.append(f"Log this: {text}")
    return "\n".join(lines)


def schema_in_prompt(system: str, schema_json: str) -> str:
    """The system prompt as `ChatClient.adapt(_:)` rewrites it for providers without native schema.

    Word for word from the Swift, including the lowercase "json" that OpenAI's `json_object`
    mode requires to appear somewhere in the messages.
    """
    return (
        f"{system}\n\n"
        "Reply with a single json object and nothing else: no explanation before it, no "
        "commentary after it, and no markdown code fence around it. The object must conform "
        "to this JSON Schema, including every property listed as required:\n\n"
        f"{schema_json}"
    )
