import Foundation

/// Recovering a JSON document from a model that was only *asked* to produce one.
///
/// Needed because strict schema enforcement is not portable. Where the provider guarantees the
/// reply matches a schema this is a no-op; everywhere else the model may wrap its answer in a
/// ```json fence, preface it with "Here's the JSON:", or append a cheerful closing line — none
/// of which a decoder will accept, and all of which are perfectly good answers underneath.
public enum JSONText {
    /// The first complete JSON object or array in `text`, or the text unchanged when none is
    /// found.
    ///
    /// Returning the input rather than nil on failure is deliberate: the caller is about to try
    /// decoding anyway, and a decode error naming the actual reply is far more debuggable than a
    /// generic "no JSON found" that discards it.
    public static func extract(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // Scanned even when the text already begins with a brace, because a model that opens with
        // the document will still sometimes add "Let me know if you'd like anything changed!"
        // after it — and a bare document scans to itself, so nothing is lost.
        let unfenced = stripCodeFence(trimmed)
        return firstBalancedDocument(in: unfenced) ?? unfenced
    }

    /// Removes a surrounding ``` or ```json fence.
    private static func stripCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }

        var body = text.dropFirst(3)
        // The optional language tag: ```json, ```JSON, ```javascript — anything up to the newline.
        if let newline = body.firstIndex(of: "\n") {
            let tag = body[body.startIndex..<newline]
            if tag.allSatisfy({ $0.isLetter }) {
                body = body[body.index(after: newline)...]
            }
        }
        if let close = body.range(of: "```", options: .backwards) {
            body = body[body.startIndex..<close.lowerBound]
        }
        return String(body).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Scans for the first balanced `{…}` or `[…]`, respecting string literals and escapes.
    ///
    /// The naive version — first `{` to last `}` — swallows trailing prose that happens to
    /// contain a brace, and a brace inside a quoted string throws off any depth count that
    /// ignores quoting. Both happen often enough in real replies to be worth the state machine.
    private static func firstBalancedDocument(in text: String) -> String? {
        var depth = 0
        var start: String.Index?
        var opener: Character?
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]

            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }

            switch character {
            case "\"":
                // A quote outside any document is ordinary prose, not the start of a literal.
                if start != nil { inString = true }
            case "{", "[":
                if start == nil {
                    start = index
                    opener = character
                }
                if opener == character { depth += 1 }
            case "}", "]":
                guard let opener, start != nil else { continue }
                let matches = (opener == "{" && character == "}") || (opener == "[" && character == "]")
                guard matches else { continue }
                depth -= 1
                if depth == 0, let start {
                    return String(text[start...index])
                }
            default:
                continue
            }
        }
        return nil
    }
}
