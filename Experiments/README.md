# Experiments

An offline harness for the prompt Tally sends when someone logs a meal by text — for profiling
it, tweaking it, and measuring what a change actually does to accuracy across models.

The app's Swift is the source of truth for all of it. This directory does not reimplement the
parser so much as re-run it: same system prompt, same JSON Schema, same per-provider quirks
about who accepts a schema natively, same lenient decoding, and the same bounds on what the app
is willing to believe. The point is that a number measured here is a number the app would have
got.

## Setup

```sh
cd Experiments
python3 -m venv .venv && source .venv/bin/activate   # see "If venv is missing" below
pip install -r requirements.txt

cp .env.example .env         # fill in keys for the providers you want to measure
cp pricing.example.json pricing.json   # optional, for cost columns — strip its comment lines

jupyter lab notebooks/nutrition_prompt_lab.ipynb
```

`.env` is already covered by the repository's `.gitignore`, which excludes `.env` and `.env.*`
while keeping the tracked template. No key should ever land in a notebook cell.

**If `venv` is missing.** On a Debian or Ubuntu box the stdlib module is packaged separately and
`python3 -m venv` fails with an `ensurepip` error:

```sh
sudo apt install python3.12-venv
```

## Layout

```
prompts/          one system prompt per file — the thing being varied
  shipped.md          generated from ParsePrompt.swift; the baseline. Do not hand-edit.
  shipped.schema.json generated likewise
  <name>.md           a variant; inherits the baseline schema unless it ships its own
  <name>.notes.txt    what the variant is testing and what to watch
datasets/
  known_entries.jsonl the cases, with banded reference values
tally_eval/       the harness
notebooks/
  nutrition_prompt_lab.ipynb
tests/
  test_offline.py   checks the harness still matches the Swift. No network, no key.
results/          cached replies and saved runs (gitignored)
```

## The baseline is generated, not copied

`prompts/shipped.md` and `prompts/shipped.schema.json` are extracted from
`Sources/TallyCore/LLM/ParsePrompt.swift` — Swift multiline literals, line continuations joined
and interpolations resolved, so the file holds the exact text the model receives.

```sh
python -m tally_eval.sync_prompt           # regenerate
python -m tally_eval.sync_prompt --check    # fail if stale; the CI-friendly form
```

A hand-copied baseline is accurate on the day it is written and quietly wrong afterwards, which
would make every comparison in this directory a comparison against a prompt the app no longer
sends. Run the tests after touching the Swift:

```sh
python -m unittest discover -s tests -t .
```

They need nothing installed — stdlib only — which is what makes them safe to wire into CI on a
runner that has no Python packages and no API key.

## What gets measured

Three levels, because they answer different questions and disagree more often than you'd expect.

**Case level.** Did the app end up with something usable, and is the day's total right? The
headline metric, and the one most robust to a defensible difference of opinion: a model that
returns "oatmeal with blueberries and honey" as one item and a model that returns three are both
correct, and both should total the same.

**Item level.** Were the individual things identified, split, and labelled the way the prompt
asks? This is where wording shows up, and where a model that totals correctly can still be doing
the wrong thing.

**Field level.** Calories, protein, fiber, kind, and whether `sourceText` carries the user's own
words for that item alone — the field the shipped prompt spends its longest paragraph on.

Scores are "inside the band or not" rather than squared error. There is no true calorie count for
a bowl of chili, and a metric that pretends otherwise ranks prompts by how closely they agree
with one person's guess.

## The reference values are a starting point

The numbers in `datasets/known_entries.jsonl` are seed estimates from common published values —
USDA-style entries for whole foods, published nutrition data for the branded items. They are
banded, not exact, and they are not authoritative. Where you disagree with one, edit it: the
whole harness reads that file, so a corrected reference propagates to every result immediately.

Two case groups are worth keeping whatever else changes:

- `adversarial` — `almonds-200g` catches a per-100g answer, which is the most damaging error mode
  because it is wrong by a factor rather than by a margin, and the app's 20,000 kcal ceiling does
  not catch it.
- `empty` — `not-a-log` and `weight-not-food` catch an invented entry. A tracker that logs a meal
  nobody ate is worse than one that logs nothing.

## Cost and caching

Every reply is cached on disk under a key derived from everything that could change it — prompt
text, schema, provider, model, effort, temperature, case, repeat index. Re-running a notebook
after editing one prompt only pays for that prompt. Non-retryable failures are cached too, so a
typo'd model identifier costs one request rather than four hundred; rate limits are not, so a
re-run after one retries properly. `clear_cache()` when you want fresh numbers.

`cost_per_call_usd` stays blank until you fill `pricing.json`. Blank means unknown, not free —
list prices move often enough that a table baked into the repository would be a reliable source
of confidently wrong cost columns.

## Keeping it honest

Repeats exist because these models are not deterministic and a one-shot comparison of two prompts
is mostly noise. Three is usually enough to tell a real difference from a coin flip.

Repeats are pooled rather than averaged per case: a model that answers a case correctly two times
in three contributes both outcomes, because the user gets one roll of the dice and not the
average of three.

Photo inputs are out of scope here. The app sends them, `tally_eval` does not — adding them means
a fixture directory of images and a decision about what a reference value even means for a photo,
and neither is needed to work on the wording.
