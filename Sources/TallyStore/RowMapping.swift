import Foundation
import GRDB
import TallyCore

/// Something on disk didn't match what the code expects.
///
/// Distinct from GRDB's own errors: these mean the row was read fine but its *contents* are
/// not valid Tally data — an enum value from a future version, an unparseable day. Worth
/// surfacing rather than silently defaulting, because quietly substituting a value would turn
/// one corrupt row into wrong numbers on a screen.
public enum StoreDecodingError: Error, CustomStringConvertible {
    case malformedDay(String)
    case unknownEnumValue(column: String, value: String)
    case malformedSettingsJSON(String)

    public var description: String {
        switch self {
        case .malformedDay(let text):
            "Stored day \(text.debugDescription) is not in YYYY-MM-DD form."
        case .unknownEnumValue(let column, let value):
            "Column \(column) holds unrecognised value \(value.debugDescription)."
        case .malformedSettingsJSON(let detail):
            "Stored settings could not be decoded: \(detail)"
        }
    }
}

// MARK: - Reading

extension Row {
    /// Reads a `Day` from a text column.
    func day(_ column: String) throws -> Day {
        let text: String = self[column]
        guard let day = Day(text) else { throw StoreDecodingError.malformedDay(text) }
        return day
    }

    /// Reads a string-backed enum, failing loudly on a value this build doesn't know.
    func decodable<T: RawRepresentable>(_ column: String, as type: T.Type) throws -> T
    where T.RawValue == String {
        let raw: String = self[column]
        guard let value = T(rawValue: raw) else {
            throw StoreDecodingError.unknownEnumValue(column: column, value: raw)
        }
        return value
    }

    /// As above, for a nullable column. A NULL is absence, which is valid; a *present* but
    /// unrecognised value is still an error.
    func decodableIfPresent<T: RawRepresentable>(_ column: String, as type: T.Type) throws -> T?
    where T.RawValue == String {
        guard let raw: String = self[column] else { return nil }
        guard let value = T(rawValue: raw) else {
            throw StoreDecodingError.unknownEnumValue(column: column, value: raw)
        }
        return value
    }

    /// Reads a date stored as Unix epoch seconds.
    func epochDate(_ column: String) -> Date {
        Date(timeIntervalSince1970: self[column])
    }
}

extension Entry {
    init(row: Row) throws {
        self.init(
            id: UUID(uuidString: row["id"]) ?? UUID(),
            kind: try row.decodable("kind", as: Entry.Kind.self),
            label: row["label"],
            calories: row["calories"],
            proteinGrams: row["proteinGrams"],
            fiberGrams: row["fiberGrams"],
            exerciseKind: try row.decodableIfPresent("exerciseKind", as: ExerciseKind.self),
            durationMinutes: row["durationMinutes"],
            loggedAt: row.epochDate("loggedAt"),
            day: try row.day("day"),
            source: try row.decodable("source", as: RecordSource.self),
            rawInput: row["rawInput"],
            confidence: try row.decodableIfPresent("confidence", as: ParseConfidence.self),
            externalIdentifier: row["externalIdentifier"]
        )
    }

    /// Column values for insert/update, in a single place so writes and the schema can't drift.
    var databaseArguments: StatementArguments {
        [
            "id": id.uuidString,
            "kind": kind.rawValue,
            "label": label,
            "calories": calories,
            "proteinGrams": proteinGrams,
            "fiberGrams": fiberGrams,
            "exerciseKind": exerciseKind?.rawValue,
            "durationMinutes": durationMinutes,
            "loggedAt": loggedAt.timeIntervalSince1970,
            "day": day.description,
            "source": source.rawValue,
            "rawInput": rawInput,
            "confidence": confidence?.rawValue,
            "externalIdentifier": externalIdentifier,
        ]
    }
}

extension WeightSample {
    init(row: Row) throws {
        self.init(
            id: UUID(uuidString: row["id"]) ?? UUID(),
            day: try row.day("day"),
            pounds: row["pounds"],
            measuredAt: row.epochDate("measuredAt"),
            source: try row.decodable("source", as: RecordSource.self),
            externalIdentifier: row["externalIdentifier"]
        )
    }

    var databaseArguments: StatementArguments {
        [
            "id": id.uuidString,
            "day": day.description,
            "pounds": pounds,
            "measuredAt": measuredAt.timeIntervalSince1970,
            "source": source.rawValue,
            "externalIdentifier": externalIdentifier,
        ]
    }
}
