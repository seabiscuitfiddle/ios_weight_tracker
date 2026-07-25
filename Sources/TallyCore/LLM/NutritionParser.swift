import Foundation

/// What the user gave us to interpret.
public enum ParseInput: Hashable, Sendable {
    /// Typed text, or a voice note already transcribed on the device.
    case text(String)
    /// A photo of a meal, plus any accompanying words.
    case image(data: Data, mediaType: ImageMediaType, note: String?)

    public enum ImageMediaType: String, Hashable, Sendable {
        case jpeg = "image/jpeg"
        case png = "image/png"
        case webp = "image/webp"
        case heic = "image/heic"
    }

    /// The user's own words, for showing back on the saved card so an estimate can be judged
    /// against what was actually said.
    public var transcript: String? {
        switch self {
        case .text(let text): text
        case .image(_, _, let note): note
        }
    }
}

/// One food or exercise the parser identified. Deliberately not an ``Entry``: this is a
/// proposal, and it becomes an entry only once it has been given a day and a source.
public struct ParsedItem: Hashable, Sendable {
    public var kind: Entry.Kind
    public var label: String
    public var calories: Int
    public var proteinGrams: Double
    public var fiberGrams: Double
    public var exerciseKind: ExerciseKind?
    public var durationMinutes: Int?
    public var confidence: ParseConfidence

    public init(
        kind: Entry.Kind,
        label: String,
        calories: Int,
        proteinGrams: Double = 0,
        fiberGrams: Double = 0,
        exerciseKind: ExerciseKind? = nil,
        durationMinutes: Int? = nil,
        confidence: ParseConfidence = .medium
    ) {
        self.kind = kind
        self.label = label
        self.calories = calories
        self.proteinGrams = proteinGrams
        self.fiberGrams = fiberGrams
        self.exerciseKind = exerciseKind
        self.durationMinutes = durationMinutes
        self.confidence = confidence
    }

    /// Turns the proposal into a storable entry.
    public func entry(
        on day: Day,
        loggedAt: Date,
        source: RecordSource,
        rawInput: String?,
        calendar: Calendar = .current
    ) -> Entry {
        Entry(
            kind: kind,
            label: label,
            calories: calories,
            proteinGrams: proteinGrams,
            fiberGrams: fiberGrams,
            exerciseKind: exerciseKind,
            durationMinutes: durationMinutes,
            loggedAt: loggedAt,
            day: day,
            source: source,
            rawInput: rawInput,
            confidence: confidence,
            calendar: calendar
        )
    }
}

public struct ParseResult: Hashable, Sendable {
    public var items: [ParsedItem]
    /// A short remark from the parser — usually the assumption it had to make, e.g. "assumed a
    /// medium apple". Shown so the user can correct a wrong assumption rather than a wrong
    /// number.
    public var note: String?

    public init(items: [ParsedItem], note: String? = nil) {
        self.items = items
        self.note = note
    }
}

/// What the app knows that helps interpret the input.
public struct ParseContext: Hashable, Sendable {
    /// Current trend weight, when known.
    ///
    /// Worth sending because energy burned in exercise scales roughly with body mass — the same
    /// half-hour run is a meaningfully different number for a 130 lb and a 220 lb person. Food
    /// estimates don't need it, so this is nil-safe rather than required.
    public var bodyWeightPounds: Double?

    public init(bodyWeightPounds: Double? = nil) {
        self.bodyWeightPounds = bodyWeightPounds
    }

    public static let empty = ParseContext()
}

/// Turns words or a photo into food and exercise numbers.
///
/// A protocol so the app depends on the capability rather than on Anthropic specifically: the
/// screens are testable against a stub, and swapping providers — or adding an on-device
/// estimator later — touches nothing above this line.
public protocol NutritionParser: Sendable {
    func parse(_ input: ParseInput, context: ParseContext) async throws -> ParseResult
}

extension NutritionParser {
    public func parse(_ input: ParseInput) async throws -> ParseResult {
        try await parse(input, context: .empty)
    }
}

/// Where the user's API key lives.
///
/// A protocol because the real implementation is the iOS Keychain, which does not exist on
/// Linux and cannot be exercised in the package's tests. The parser only ever reads the key at
/// the moment it builds a request, so a key is never held in memory longer than one call.
public protocol APIKeyStore: Sendable {
    /// The stored key, or nil if the user hasn't set one.
    func apiKey() throws -> String?
}

/// A fixed key, for tests and previews.
public struct StaticAPIKeyStore: APIKeyStore {
    private let key: String?
    public init(_ key: String?) { self.key = key }
    public func apiKey() throws -> String? { key }
}

/// Everything that can go wrong, phrased so the UI can show it directly.
///
/// Each case carries a ``userMessage`` because "an error occurred" is useless to someone who
/// just photographed their lunch. The distinction that matters most to the user is whether to
/// retry, fix something, or give up and type it by hand.
public enum NutritionParserError: Error, Hashable, Sendable {
    /// No key configured. Not really an error — the expected state until setup.
    case missingAPIKey
    case invalidAPIKey
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case requestTooLarge
    case offline(String)
    /// The model declined. Rare for food, but it is a documented outcome and reading
    /// `content` without checking would crash on an empty array.
    case refused(String?)
    /// The reply hit the token ceiling mid-JSON, so it cannot be parsed.
    case truncated
    /// The reply arrived but wasn't the shape the schema promised.
    case malformedResponse(String)
    /// The model understood the request but found no food or exercise in it.
    case nothingRecognized(String?)
    case serverError(status: Int, message: String?)

    /// Whether trying the same request again could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .offline, .serverError, .truncated: true
        case .missingAPIKey, .invalidAPIKey, .requestTooLarge, .refused,
             .malformedResponse, .nothingRecognized: false
        }
    }

    public var userMessage: String {
        switch self {
        case .missingAPIKey:
            "Add an Anthropic API key in Settings to log by text, photo, or voice."
        case .invalidAPIKey:
            "That API key was rejected. Check it in Settings."
        case .rateLimited(let retryAfter):
            if let retryAfter, retryAfter > 0 {
                "Rate limited. Try again in about \(Int(retryAfter.rounded())) seconds."
            } else {
                "Rate limited. Try again shortly."
            }
        case .overloaded:
            "The service is busy. Try again in a moment."
        case .requestTooLarge:
            "That photo is too large. Try a smaller one."
        case .offline:
            "No connection. You can still add this entry by hand."
        case .refused(let explanation):
            explanation ?? "That request was declined. Try describing the food differently."
        case .truncated:
            "The reply was cut off. Try again, or split it into separate entries."
        case .malformedResponse:
            "Couldn't read the reply. Try again, or add this entry by hand."
        case .nothingRecognized(let note):
            note ?? "No food or exercise found in that. Try naming what you ate."
        case .serverError:
            "The service had a problem. Try again in a moment."
        }
    }
}
