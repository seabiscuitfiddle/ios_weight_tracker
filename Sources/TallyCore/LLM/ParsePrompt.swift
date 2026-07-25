import Foundation

/// The prompt and output schema sent with every parse request.
///
/// Both are static so they form a stable prefix the API can cache across requests, and so the
/// exact instructions the model receives are reviewable in one place rather than assembled
/// across the call site.
enum ParsePrompt {
    /// Sentinel used for "not an exercise", because structured outputs are far more reliable
    /// with a required enum than with an omittable field.
    static let noExerciseKind = "none"

    static let system = """
        You convert short descriptions of food and exercise into structured data for a calorie \
        tracker. The user is logging what they ate or did, in their own words.

        Return one item per thing the user would want to edit separately. "Eggs, toast and \
        coffee" is three items; a composed dish like "chicken burrito bowl" is one.

        Portions: when no quantity is given, assume one typical adult serving and say what you \
        assumed in `note`. Prefer a decisive estimate to a hedge — every number here is \
        editable, but a refusal is not useful to anyone.

        For food, set `kind` to "food", `exerciseKind` to "\(noExerciseKind)" and \
        `durationMinutes` to 0. Give `calories`, `proteinGrams` and `fiberGrams` for the whole \
        portion described, not per 100g.

        For exercise, set `kind` to "exercise", `calories` to the energy burned as a positive \
        number, `proteinGrams` and `fiberGrams` to 0, and `exerciseKind` to "cardio", \
        "strength" or "other". Set `durationMinutes` when it is stated or clearly implied, \
        otherwise 0. Energy burned scales with body mass, so use the body weight if one is given.

        `confidence`: "high" when both the item and the portion are clear; "medium" when you \
        assumed a portion; "low" when the food itself is ambiguous or a photo is unclear.

        `label`: short and recognisable, phrased the way the user would say it rather than as a \
        database name. Sentence case, no trailing punctuation, roughly 40 characters at most.

        `note`: at most one short sentence, naming the assumption you made. Empty when you \
        assumed nothing worth mentioning.

        If the input contains no food or exercise at all, return an empty `items` array and say \
        why in `note`.
        """

    /// JSON Schema for the reply.
    ///
    /// Written as a literal rather than built from Swift types, because it must match the
    /// documented constraints of structured outputs exactly and those are easier to check
    /// against a schema you can read. Two of those constraints shape the design:
    ///
    ///  - `additionalProperties: false` and a complete `required` list are mandatory, so every
    ///    field is present on every item. That's why "not applicable" is expressed as the
    ///    `none` sentinel and as 0 rather than by omitting fields.
    ///  - Numeric bounds (`minimum`/`maximum`) are not supported, so ranges are enforced in
    ///    Swift when decoding instead — see `AnthropicNutritionParser.item(from:)`.
    static let outputSchema = """
        {
          "type": "object",
          "properties": {
            "items": {
              "type": "array",
              "description": "One entry per food or exercise identified. Empty if none.",
              "items": {
                "type": "object",
                "properties": {
                  "kind": { "type": "string", "enum": ["food", "exercise"] },
                  "label": { "type": "string" },
                  "calories": {
                    "type": "integer",
                    "description": "Energy for the whole portion, or burned by the exercise. Always positive."
                  },
                  "proteinGrams": { "type": "number" },
                  "fiberGrams": { "type": "number" },
                  "exerciseKind": {
                    "type": "string",
                    "enum": ["cardio", "strength", "other", "\(noExerciseKind)"],
                    "description": "\\"\(noExerciseKind)\\" for food."
                  },
                  "durationMinutes": {
                    "type": "integer",
                    "description": "0 when not applicable or unknown."
                  },
                  "confidence": { "type": "string", "enum": ["high", "medium", "low"] }
                },
                "required": [
                  "kind", "label", "calories", "proteinGrams", "fiberGrams",
                  "exerciseKind", "durationMinutes", "confidence"
                ],
                "additionalProperties": false
              }
            },
            "note": {
              "type": "string",
              "description": "One short sentence naming any assumption made, or empty."
            }
          },
          "required": ["items", "note"],
          "additionalProperties": false
        }
        """

    /// The instruction accompanying the input itself.
    static func userInstruction(for input: ParseInput, context: ParseContext) -> String {
        var lines: [String] = []

        if let weight = context.bodyWeightPounds, weight > 0 {
            lines.append("Body weight: \(Int(weight.rounded())) lb.")
        }

        switch input {
        case .text(let text):
            lines.append("Log this: \(text)")
        case .image(_, _, let note):
            if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Log the food in this photo. The user adds: \(note)")
            } else {
                lines.append("Log the food in this photo.")
            }
        }

        return lines.joined(separator: "\n")
    }
}
