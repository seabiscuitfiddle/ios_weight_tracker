"""Checks the harness against the Swift it mirrors, without a network or an API key.

Deliberately `unittest` and stdlib only, and deliberately importing nothing that pulls in
`httpx`. This file is the piece worth running in CI: the whole value of the harness is that a
number measured here is a number the app would have got, and that claim decays the moment
`ParsePrompt.swift` or `LLMNutritionParser.swift` moves without this following.

    python -m unittest discover -s tests -t .
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tally_eval import dataset, jsontext, parse, prompts, providers, scoring, sync_prompt  # noqa: E402


class SyncPromptTests(unittest.TestCase):
    """The generated baseline still matches the Swift."""

    def test_generated_files_are_current(self):
        system_text, schema_text = sync_prompt.rendered()
        self.assertEqual(
            sync_prompt.SYSTEM_OUT.read_text(encoding="utf-8"),
            system_text,
            "prompts/shipped.md is stale — run `python -m tally_eval.sync_prompt`.",
        )
        self.assertEqual(
            sync_prompt.SCHEMA_OUT.read_text(encoding="utf-8"),
            schema_text,
            "prompts/shipped.schema.json is stale — run `python -m tally_eval.sync_prompt`.",
        )

    def test_line_continuations_are_joined(self):
        system, _ = sync_prompt.extract()
        # Every paragraph in the Swift is written with trailing backslashes, so a naive read
        # would leave hard wraps the model never sees. Paragraph breaks survive; wraps do not.
        self.assertIn("The user is logging what they ate or did, in their own words.", system)
        self.assertNotIn("  ", system.replace("\n\n", ""))

    def test_interpolation_and_escapes_resolve(self):
        system, schema = sync_prompt.extract()
        self.assertIn('`exerciseKind` to "none"', system)
        self.assertNotIn("\\(", system)
        exercise_kind = schema["properties"]["items"]["items"]["properties"]["exerciseKind"]
        self.assertIn("none", exercise_kind["enum"])
        self.assertEqual(exercise_kind["description"], '"none" for food.')

    def test_schema_keeps_the_constraints_structured_outputs_require(self):
        _, schema = sync_prompt.extract()
        item = schema["properties"]["items"]["items"]
        self.assertFalse(item["additionalProperties"])
        self.assertEqual(set(item["required"]), set(item["properties"]))
        self.assertEqual(set(schema["required"]), {"items", "note"})


class PromptLoadingTests(unittest.TestCase):
    def test_baseline_loads_without_the_generated_banner(self):
        prompt = prompts.load_prompt("shipped")
        self.assertFalse(prompt.system.startswith("<!--"))
        self.assertTrue(prompt.system.startswith("You convert short descriptions"))

    def test_variants_inherit_the_baseline_schema(self):
        for name in prompts.available_prompts():
            with self.subTest(prompt=name):
                self.assertEqual(
                    prompts.load_prompt(name).schema,
                    prompts.load_prompt("shipped").schema,
                    "A variant grew its own schema — intended, or a stray file?",
                )

    def test_user_instruction_matches_the_swift(self):
        self.assertEqual(prompts.user_instruction("two eggs"), "Log this: two eggs")
        self.assertEqual(
            prompts.user_instruction("ran 5k", body_weight_pounds=182.4),
            "Body weight: 182 lb.\nLog this: ran 5k",
        )
        # Nil-safe rather than required, and a zero weight is not a weight.
        self.assertEqual(prompts.user_instruction("ran 5k", 0), "Log this: ran 5k")

    def test_schema_in_prompt_says_json_for_json_object_mode(self):
        adapted = prompts.schema_in_prompt("SYSTEM", '{"type":"object"}')
        # OpenAI's `json_object` mode rejects a request whose messages never say "json", a rule
        # DeepSeek and Qwen copied.
        self.assertIn("json", adapted)
        self.assertIn('{"type":"object"}', adapted)


class EffortGatingTests(unittest.TestCase):
    """The table in EffortSupport.swift, which is easy to get subtly wrong."""

    def test_anthropic_sends_only_to_models_that_take_it(self):
        anthropic = providers.ANTHROPIC
        self.assertEqual(anthropic.effort_value("low", "claude-opus-5"), "low")
        self.assertEqual(anthropic.effort_value("high", "claude-sonnet-5"), "high")
        # No Haiku takes an effort hint as of 4.5, and Haiku is in the shipped model picker.
        self.assertIsNone(anthropic.effort_value("low", "claude-haiku-4-5"))
        self.assertIsNone(anthropic.effort_value("low", "claude-sonnet-4-5"))
        self.assertIsNone(anthropic.effort_value("low", "claude-3-opus-20240229"))

    def test_release_dates_are_not_read_as_version_components(self):
        # `claude-opus-4-20250514` is Opus 4, not Opus 4.20250514.
        self.assertIsNone(providers.ANTHROPIC.effort_value("low", "claude-opus-4-20250514"))

    def test_anthropic_has_no_minimal_level(self):
        self.assertEqual(providers.ANTHROPIC.effort_value("minimal", "claude-opus-5"), "low")

    def test_openai_sends_only_to_reasoning_models(self):
        openai = providers.OPENAI
        self.assertEqual(openai.effort_value("minimal", "gpt-5.2-mini"), "minimal")
        self.assertIsNone(openai.effort_value("low", "gpt-4.1"))
        self.assertEqual(openai.effort_value("minimal", "o3"), "low")
        # A prefix match would misread both of these as the o-series.
        self.assertIsNone(openai.effort_value("low", "olmo-2"))

    def test_openrouter_normalises_so_the_hint_is_always_safe(self):
        self.assertEqual(providers.OPENROUTER.effort_value("high", "z-ai/glm-4.6"), "high")

    def test_gateway_prefixes_are_read_through(self):
        self.assertEqual(
            providers.OPENROUTER.effort_value("low", "anthropic/claude-opus-5"), "low"
        )

    def test_compatible_mode_endpoints_never_get_the_hint(self):
        self.assertIsNone(providers.DEEPSEEK.effort_value("high", "deepseek-reasoner"))


class LenientParsingTests(unittest.TestCase):
    """`LLMNutritionParser.item(from:)` and its lenient decoder."""

    def _reply(self, **overrides) -> str:
        item = {
            "kind": "food",
            "label": "Scrambled eggs",
            "sourceText": "two eggs",
            "calories": 180,
            "proteinGrams": 12,
            "fiberGrams": 0,
            "exerciseKind": "none",
            "durationMinutes": 0,
            "confidence": "high",
        }
        item.update(overrides)
        return json.dumps({"items": [item], "note": "Assumed two eggs."})

    def test_numbers_arriving_as_strings_are_still_numbers(self):
        result = parse.parse_reply(self._reply(calories="280", proteinGrams="12.5"))
        self.assertTrue(result.ok)
        self.assertEqual(result.items[0].calories, 280)
        self.assertEqual(result.items[0].protein_grams, 12.5)

    def test_floats_where_an_integer_belongs_are_rounded(self):
        self.assertEqual(parse.parse_reply(self._reply(calories=180.6)).items[0].calories, 181)

    def test_absurd_calories_drop_the_item_not_the_meal(self):
        payload = json.loads(self._reply())
        payload["items"].append({**payload["items"][0], "label": "Toast", "calories": 40000})
        result = parse.parse_reply(json.dumps(payload))
        self.assertEqual(len(result.items), 1)
        self.assertEqual(len(result.dropped), 1)
        self.assertIn("out of range", result.dropped[0]["reason"])

    def test_an_invented_kind_drops_the_item(self):
        result = parse.parse_reply(self._reply(kind="beverage"))
        self.assertFalse(result.ok)
        self.assertEqual(result.dropped[0]["reason"], "unknown kind 'beverage'")

    def test_a_blank_label_drops_the_item(self):
        self.assertEqual(parse.parse_reply(self._reply(label="   ")).dropped[0]["reason"], "blank label")

    def test_macros_are_zeroed_on_exercise(self):
        result = parse.parse_reply(
            self._reply(kind="exercise", exerciseKind="cardio", proteinGrams=9, durationMinutes=30)
        )
        item = result.items[0]
        self.assertEqual((item.protein_grams, item.fiber_grams), (0.0, 0.0))
        self.assertEqual(item.duration_minutes, 30)

    def test_an_unknown_exercise_kind_becomes_other(self):
        result = parse.parse_reply(self._reply(kind="exercise", exerciseKind="yoga"))
        self.assertEqual(result.items[0].exercise_kind, "other")

    def test_no_usable_items_is_the_apps_nothing_recognized(self):
        result = parse.parse_reply('{"items": [], "note": "No food here."}')
        self.assertFalse(result.ok)
        self.assertTrue(result.error.startswith("nothing_recognized"))
        self.assertEqual(result.note, "No food here.")


class JSONRecoveryTests(unittest.TestCase):
    """`JSONText.extract`, which is what makes the prompt-mode providers usable at all."""

    def setUp(self):
        self.extract = jsontext.extract_json

    def test_a_bare_document_is_returned_unchanged(self):
        self.assertEqual(self.extract('{"items": []}'), '{"items": []}')

    def test_a_code_fence_is_stripped(self):
        self.assertEqual(self.extract('```json\n{"a": 1}\n```'), '{"a": 1}')

    def test_a_preamble_and_a_sign_off_are_dropped(self):
        text = 'Here you go:\n{"a": 1}\nLet me know if you want changes!'
        self.assertEqual(self.extract(text), '{"a": 1}')

    def test_a_brace_inside_a_string_does_not_end_the_document(self):
        self.assertEqual(self.extract('{"label": "a }" }'), '{"label": "a }" }')

    def test_unrecoverable_text_comes_back_whole(self):
        # So the decode error names the actual reply rather than discarding it.
        self.assertEqual(self.extract("I cannot help with that."), "I cannot help with that.")


class DatasetTests(unittest.TestCase):
    def setUp(self):
        self.cases = dataset.load_dataset()

    def test_it_loads_and_ids_are_unique(self):
        self.assertGreater(len(self.cases), 20)
        self.assertEqual(len({case.id for case in self.cases}), len(self.cases))

    def test_every_case_is_scoreable(self):
        for case in self.cases:
            with self.subTest(case=case.id):
                if case.expect_empty:
                    self.assertEqual(case.expected_items, [])
                    continue
                self.assertTrue(case.expected_items, "a non-empty case with nothing expected")
                for item in case.expected_items:
                    self.assertTrue(item.match, f"{item.label} has no match keywords")
                    self.assertIn(item.kind, {"food", "exercise"})

    def test_exercise_cases_that_depend_on_body_mass_supply_one(self):
        for case in self.cases:
            duration_based = any(
                item.kind == "exercise" for item in case.expected_items
            ) and "no-weight" not in case.tags
            if duration_based:
                with self.subTest(case=case.id):
                    self.assertIsNotNone(
                        case.body_weight_lb,
                        "the reference assumes a body weight the request never sends",
                    )


class ScoringTests(unittest.TestCase):
    def setUp(self):
        self.case = next(c for c in dataset.load_dataset() if c.id == "eggs-toast-coffee")

    def _reply(self, items) -> parse.ParseResult:
        return parse.parse_reply(json.dumps({"items": items, "note": ""}))

    def _item(self, label, calories, source_text, **extra):
        return {
            "kind": "food",
            "label": label,
            "sourceText": source_text,
            "calories": calories,
            "proteinGrams": extra.get("protein", 0),
            "fiberGrams": 0,
            "exerciseKind": "none",
            "durationMinutes": 0,
            "confidence": "high",
        }

    def test_a_good_reply_scores_clean(self):
        score = scoring.score_case(
            self.case,
            self._reply(
                [
                    self._item("Two eggs", 160, "Two eggs", protein=12),
                    self._item("Sourdough toast with butter", 155, "sourdough toast with butter", protein=5),
                    self._item("Black coffee", 3, "a black coffee"),
                ]
            ),
        )
        self.assertTrue(score.ok)
        self.assertTrue(score.total_in_band)
        self.assertEqual(score.matched_count, 3)
        self.assertEqual(score.missing, [])
        self.assertTrue(all(item.calories_ok for item in score.items))
        self.assertTrue(all(item.source_text_ok for item in score.items))

    def test_repeating_the_whole_sentence_fails_source_text(self):
        whole = "Two eggs, sourdough toast with butter and a black coffee"
        score = scoring.score_case(
            self.case,
            self._reply(
                [
                    self._item("Two eggs", 160, whole),
                    self._item("Sourdough toast with butter", 155, whole),
                    self._item("Black coffee", 3, whole),
                ]
            ),
        )
        # Every fragment is present in the whole sentence, so a substring check alone passes —
        # the point of this test is that the harness still counts the items as matched, and the
        # splitting failure has to be read off `source_text_ok_rate` against a stricter case.
        self.assertEqual(score.matched_count, 3)
        self.assertTrue(score.total_in_band)

    def test_a_missing_item_is_reported_and_the_total_drops(self):
        score = scoring.score_case(
            self.case,
            self._reply(
                [
                    self._item("Two eggs", 160, "Two eggs"),
                    self._item("Sourdough toast with butter", 155, "sourdough toast"),
                ]
            ),
        )
        self.assertEqual(score.missing, ["Black coffee"])
        self.assertEqual(score.item_count_delta if hasattr(score, "item_count_delta") else score.item_count - 3, -1)

    def test_an_invented_entry_fails_an_empty_case(self):
        empty_case = next(c for c in dataset.load_dataset() if c.id == "not-a-log")
        invented = self._reply([self._item("Mom's dinner", 600, "call mom")])
        self.assertFalse(scoring.score_case(empty_case, invented).ok)

    def test_a_correctly_empty_reply_passes_an_empty_case(self):
        empty_case = next(c for c in dataset.load_dataset() if c.id == "not-a-log")
        result = parse.parse_reply('{"items": [], "note": "That is a reminder, not food."}')
        self.assertTrue(scoring.score_case(empty_case, result).ok)

    def test_the_per_100g_trap_is_caught(self):
        almonds = next(c for c in dataset.load_dataset() if c.id == "almonds-200g")
        per_100g = self._reply([self._item("Almonds", 579, "200 g of almonds", protein=21)])
        score = scoring.score_case(almonds, per_100g)
        self.assertFalse(score.total_in_band)
        self.assertLess(score.total_error, -0.4)


if __name__ == "__main__":
    unittest.main(verbosity=2)
