"""Recovering a JSON document from a model that was only *asked* to produce one.

Mirrors `Sources/LLMWire/JSONText.swift`, and kept in its own module for the same reason it is
its own file there: it is pure text handling with no transport in it, so it stays testable on a
checkout with nothing installed.

Needed because strict schema enforcement is not portable. Where the provider guarantees the
reply matches a schema this is a no-op; everywhere else the model may wrap its answer in a
```json fence, preface it with "Here's the JSON:", or append a cheerful closing line — none of
which a decoder will accept, and all of which are perfectly good answers underneath.
"""

from __future__ import annotations


def extract_json(text: str) -> str:
    """The first complete JSON document in `text`, or the text unchanged when there is none.

    Returning the input rather than None on failure is deliberate: the caller is about to try
    decoding anyway, and a decode error naming the actual reply is far more debuggable than a
    generic "no JSON found" that discards it.
    """
    trimmed = text.strip()
    if not trimmed:
        return trimmed
    # Scanned even when the text already begins with a brace, because a model that opens with the
    # document will still sometimes add "Let me know if you'd like anything changed!" after it —
    # and a bare document scans to itself, so nothing is lost.
    unfenced = _strip_code_fence(trimmed)
    return _first_balanced_document(unfenced) or unfenced


def _strip_code_fence(text: str) -> str:
    """Removes a surrounding ``` or ```json fence."""
    if not text.startswith("```"):
        return text
    body = text[3:]
    # The optional language tag: ```json, ```JSON, ```javascript — anything up to the newline.
    newline = body.find("\n")
    if newline != -1 and body[:newline].strip().isalpha():
        body = body[newline + 1 :]
    close = body.rfind("```")
    if close != -1:
        body = body[:close]
    return body.strip()


def _first_balanced_document(text: str) -> str | None:
    """Scans for the first balanced `{…}` or `[…]`, respecting string literals and escapes.

    The naive version — first `{` to last `}` — swallows trailing prose that happens to contain
    a brace, and a brace inside a quoted string throws off any depth count that ignores quoting.
    Both happen often enough in real replies to be worth the state machine.
    """
    depth = 0
    start: int | None = None
    opener: str | None = None
    in_string = False
    escaped = False

    for index, char in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue

        if char == '"':
            # A quote outside any document is ordinary prose, not the start of a literal.
            if start is not None:
                in_string = True
        elif char in "{[":
            if start is None:
                start, opener = index, char
            if opener == char:
                depth += 1
        elif char in "}]":
            if start is None or opener is None:
                continue
            if (opener, char) not in (("{", "}"), ("[", "]")):
                continue
            depth -= 1
            if depth == 0:
                return text[start : index + 1]
    return None
