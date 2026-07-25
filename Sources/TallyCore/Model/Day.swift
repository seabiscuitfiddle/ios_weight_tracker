import Foundation

/// A calendar date with no time component and no timezone — the unit Tally buckets by.
///
/// Everything the user sees is "per day": today's net calories, a day's entries, a weight
/// reading. A `Date` is the wrong type for that, because "which day is this?" depends on the
/// calendar and timezone you ask in, and the answer can change while the data doesn't.
/// `Day` fixes the answer once, at the moment of capture, in the user's then-current timezone.
///
/// Persisted as `"YYYY-MM-DD"`, which sorts correctly as a plain string, survives timezone
/// changes untouched, and is legible when reading the database by hand.
public struct Day: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on, as seen in `calendar` (which carries the timezone).
    public init(date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = parts.year ?? 1
        self.month = parts.month ?? 1
        self.day = parts.day ?? 1
    }

    public static func today(calendar: Calendar = .current, now: Date = Date()) -> Day {
        Day(date: now, calendar: calendar)
    }

    /// Midnight at the start of this day in `calendar`'s timezone.
    ///
    /// Returns nil only if the components don't name a real instant, which in practice means a
    /// wall-clock time skipped by a daylight-saving jump. Callers that need a definite instant
    /// should fall back to `noon`, which no DST transition can erase.
    public func startOfDay(calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// Midday on this day. Unlike `startOfDay` this always exists, so it is the safe choice
    /// when a day needs to be turned back into an instant for arithmetic or for charting.
    public func noon(calendar: Calendar = .current) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    /// The day `count` days after this one (negative counts move backwards).
    public func adding(days count: Int, calendar: Calendar = .current) -> Day {
        guard let base = noon(calendar: calendar),
              let shifted = calendar.date(byAdding: .day, value: count, to: base)
        else { return self }
        return Day(date: shifted, calendar: calendar)
    }

    /// Number of days from this day to `other`; negative when `other` is earlier.
    public func days(until other: Day, calendar: Calendar = .current) -> Int {
        guard let from = noon(calendar: calendar), let to = other.noon(calendar: calendar)
        else { return 0 }
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    // MARK: Comparable

    public static func < (lhs: Day, rhs: Day) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: String representation

    /// `"YYYY-MM-DD"`. This is also the persisted form.
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Parses `"YYYY-MM-DD"`. Rejects anything else, including partially numeric input.
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    // MARK: Codable — as the "YYYY-MM-DD" string, not as three fields

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = Day(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "Expected a YYYY-MM-DD day, got \(text.debugDescription)")
            )
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension Day {
    /// The inclusive range of days ending today and reaching `count` days back, oldest first.
    /// `count` is the total number of days, so `trailing(30)` is today plus the 29 before it.
    public static func trailing(
        _ count: Int,
        endingOn end: Day,
        calendar: Calendar = .current
    ) -> [Day] {
        guard count > 0 else { return [] }
        return (0..<count).reversed().map { end.adding(days: -$0, calendar: calendar) }
    }
}
