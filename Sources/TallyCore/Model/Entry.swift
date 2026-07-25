import Foundation

/// Where a record came from. Kept on every entry and weight sample so the UI can show
/// provenance, and so the HealthKit importer can recognise its own prior work and avoid
/// double-counting a workout it has already brought across.
public enum RecordSource: String, Hashable, Sendable, Codable, CaseIterable {
    case manual
    case llmText
    case llmPhoto
    case llmVoice
    case healthKit

    /// True when a model produced the numbers, so the UI can invite the user to check them.
    public var isEstimated: Bool {
        switch self {
        case .llmText, .llmPhoto, .llmVoice: true
        case .manual, .healthKit: false
        }
    }
}

/// How confident the parser was. Surfaced so a low-confidence guess reads as a guess
/// rather than as a measurement.
public enum ParseConfidence: String, Hashable, Sendable, Codable, CaseIterable {
    case high, medium, low
}

public enum ExerciseKind: String, Hashable, Sendable, Codable, CaseIterable {
    case cardio, strength, other

    public var displayName: String {
        switch self {
        case .cardio: "Cardio"
        case .strength: "Strength"
        case .other: "Other"
        }
    }
}

/// One logged thing: food eaten or exercise performed.
///
/// `calories` is always a positive magnitude; `kind` decides which way it points. Storing a
/// signed number instead would mean every write site has to remember the convention, and one
/// that forgets silently inverts a day's total. Read the sign off ``signedCalories``.
public struct Entry: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case food, exercise
    }

    public var id: UUID
    public var kind: Kind
    /// Short human label, e.g. "Greek yogurt & berries" or "Zone 2 run · 38 min".
    public var label: String
    /// Positive magnitude in kilocalories. Never negative — see ``signedCalories``.
    public var calories: Int
    public var proteinGrams: Double
    public var fiberGrams: Double
    /// Set for exercise entries, nil for food.
    public var exerciseKind: ExerciseKind?
    /// Set for exercise entries when known.
    public var durationMinutes: Int?
    /// The instant the entry applies to — drives the "8:20 AM" timestamps in the log.
    public var loggedAt: Date
    /// Local day this entry counts towards. Denormalised from `loggedAt` at capture time so
    /// that a later timezone change cannot silently move history between days.
    public var day: Day
    public var source: RecordSource
    /// The user's original words, when there were any. The Log screen shows these back
    /// verbatim on the saved cards, so an estimate can be judged against what was said.
    public var rawInput: String?
    public var confidence: ParseConfidence?
    /// Identifier of the originating HealthKit sample, when imported. The importer uses this
    /// to skip anything it has already brought across.
    public var externalIdentifier: String?

    public init(
        id: UUID = UUID(),
        kind: Kind,
        label: String,
        calories: Int,
        proteinGrams: Double = 0,
        fiberGrams: Double = 0,
        exerciseKind: ExerciseKind? = nil,
        durationMinutes: Int? = nil,
        loggedAt: Date = Date(),
        day: Day? = nil,
        source: RecordSource = .manual,
        rawInput: String? = nil,
        confidence: ParseConfidence? = nil,
        externalIdentifier: String? = nil,
        calendar: Calendar = .current
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.calories = max(0, calories)
        self.proteinGrams = max(0, proteinGrams)
        self.fiberGrams = max(0, fiberGrams)
        self.exerciseKind = kind == .exercise ? (exerciseKind ?? .other) : nil
        self.durationMinutes = durationMinutes
        self.loggedAt = loggedAt
        self.day = day ?? Day(date: loggedAt, calendar: calendar)
        self.source = source
        self.rawInput = rawInput
        self.confidence = confidence
        self.externalIdentifier = externalIdentifier
    }

    /// Calories as they contribute to the day's net: food adds, exercise subtracts.
    public var signedCalories: Int {
        switch kind {
        case .food: calories
        case .exercise: -calories
        }
    }
}

/// A day's rolled-up numbers. The three the design leads with everywhere are
/// ``netCalories``, ``proteinGrams`` and ``fiberGrams``.
public struct DayTotals: Hashable, Sendable, Codable {
    public var foodCalories: Int
    public var exerciseCalories: Int
    public var proteinGrams: Double
    public var fiberGrams: Double
    public var entryCount: Int

    public init(
        foodCalories: Int = 0,
        exerciseCalories: Int = 0,
        proteinGrams: Double = 0,
        fiberGrams: Double = 0,
        entryCount: Int = 0
    ) {
        self.foodCalories = foodCalories
        self.exerciseCalories = exerciseCalories
        self.proteinGrams = proteinGrams
        self.fiberGrams = fiberGrams
        self.entryCount = entryCount
    }

    public static let empty = DayTotals()

    /// The number Tally is built around: food minus exercise.
    public var netCalories: Int { foodCalories - exerciseCalories }

    public var isEmpty: Bool { entryCount == 0 }

    /// Calories left against `goal`. Goes negative once the goal is passed, which the UI
    /// shows rather than hides.
    public func remaining(against goal: Int) -> Int { goal - netCalories }

    /// Net as a fraction of `goal`, clamped to 0...1 for ring and bar geometry.
    /// Unclamped comparisons should use ``netCalories`` directly.
    public func progress(against goal: Int) -> Double {
        guard goal > 0 else { return 0 }
        return min(1, max(0, Double(netCalories) / Double(goal)))
    }

    public static func summing(_ entries: some Sequence<Entry>) -> DayTotals {
        var totals = DayTotals()
        for entry in entries {
            switch entry.kind {
            case .food:
                totals.foodCalories += entry.calories
                // Only food carries macros; exercise entries have none to contribute.
                totals.proteinGrams += entry.proteinGrams
                totals.fiberGrams += entry.fiberGrams
            case .exercise:
                totals.exerciseCalories += entry.calories
            }
            totals.entryCount += 1
        }
        return totals
    }
}
