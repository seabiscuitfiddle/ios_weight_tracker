import Foundation
import Testing
@testable import TallyCore

@Suite("Day")
struct DayTests {
    /// A fixed non-UTC calendar, so tests can't pass only because the machine runs in UTC.
    static func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    @Test("round-trips through its string form")
    func stringRoundTrip() {
        let day = Day(year: 2026, month: 7, day: 4)
        #expect(day.description == "2026-07-04")
        #expect(Day("2026-07-04") == day)
    }

    @Test("rejects malformed day strings", arguments: [
        "", "2026-7-4", "2026-07", "not-a-day", "2026-13-01", "2026-07-32", "20260704",
    ])
    func rejectsMalformed(_ text: String) {
        #expect(Day(text) == nil)
    }

    @Test("sorts chronologically, not lexically by component")
    func ordering() {
        let days = [
            Day(year: 2026, month: 1, day: 9),
            Day(year: 2025, month: 12, day: 31),
            Day(year: 2026, month: 1, day: 10),
            Day(year: 2026, month: 2, day: 1),
        ]
        #expect(days.sorted().map(\.description) == [
            "2025-12-31", "2026-01-09", "2026-01-10", "2026-02-01",
        ])
    }

    /// The reason `Day` exists. An instant late in the evening in New York is already the next
    /// day in UTC, so asking "what day is this?" without pinning the timezone gives an answer
    /// that drifts with the device.
    @Test("resolves an instant to different days in different timezones")
    func timezoneSensitivity() {
        // 2026-07-04 23:30 in New York == 2026-07-05 03:30 UTC.
        let newYork = Self.calendar("America/New_York")
        let instant = newYork.date(from: DateComponents(
            year: 2026, month: 7, day: 4, hour: 23, minute: 30
        ))!

        #expect(Day(date: instant, calendar: newYork) == Day(year: 2026, month: 7, day: 4))
        #expect(Day(date: instant, calendar: Self.calendar("UTC")) == Day(year: 2026, month: 7, day: 5))
    }

    @Test("day arithmetic crosses month and year boundaries")
    func arithmetic() {
        let calendar = Self.calendar("America/New_York")
        let newYearsEve = Day(year: 2025, month: 12, day: 31)

        #expect(newYearsEve.adding(days: 1, calendar: calendar) == Day(year: 2026, month: 1, day: 1))
        #expect(newYearsEve.adding(days: -1, calendar: calendar) == Day(year: 2025, month: 12, day: 30))
        #expect(newYearsEve.adding(days: 0, calendar: calendar) == newYearsEve)
    }

    @Test("counts days between dates across a leap day")
    func distance() {
        let calendar = Self.calendar("America/New_York")
        let before = Day(year: 2028, month: 2, day: 28)
        let after = Day(year: 2028, month: 3, day: 1)
        // 2028 is a leap year, so the 29th sits between them.
        #expect(before.days(until: after, calendar: calendar) == 2)
        #expect(after.days(until: before, calendar: calendar) == -2)
        #expect(before.days(until: before, calendar: calendar) == 0)
    }

    /// A spring-forward transition deletes a wall-clock hour. Midnight survives in most zones,
    /// but `noon` is the accessor the rest of the code uses precisely because no transition can
    /// erase it — this pins that guarantee.
    @Test("noon exists on daylight-saving transition days")
    func noonSurvivesDSTTransitions() {
        let calendar = Self.calendar("America/New_York")
        // 2026-03-08 is the US spring-forward date; 02:00 does not exist locally.
        let springForward = Day(year: 2026, month: 3, day: 8)
        #expect(springForward.noon(calendar: calendar) != nil)

        // 2026-11-01 is fall-back, where 01:00 happens twice.
        let fallBack = Day(year: 2026, month: 11, day: 1)
        #expect(fallBack.noon(calendar: calendar) != nil)
    }

    @Test("day arithmetic is stable across a DST transition")
    func arithmeticAcrossDST() {
        let calendar = Self.calendar("America/New_York")
        let dayBefore = Day(year: 2026, month: 3, day: 7)
        // Naively adding 86,400 seconds across spring-forward lands on the wrong day;
        // going through calendar components does not.
        #expect(dayBefore.adding(days: 1, calendar: calendar) == Day(year: 2026, month: 3, day: 8))
        #expect(dayBefore.adding(days: 2, calendar: calendar) == Day(year: 2026, month: 3, day: 9))
        #expect(dayBefore.days(until: Day(year: 2026, month: 3, day: 9), calendar: calendar) == 2)
    }

    @Test("trailing window is oldest-first and inclusive of the end day")
    func trailingWindow() {
        let calendar = Self.calendar("America/New_York")
        let end = Day(year: 2026, month: 1, day: 3)
        let window = Day.trailing(3, endingOn: end, calendar: calendar)

        #expect(window.map(\.description) == ["2026-01-01", "2026-01-02", "2026-01-03"])
        #expect(Day.trailing(0, endingOn: end, calendar: calendar).isEmpty)
        #expect(Day.trailing(1, endingOn: end, calendar: calendar) == [end])
    }

    @Test("encodes as a bare string, not an object")
    func codableForm() throws {
        let day = Day(year: 2026, month: 7, day: 4)
        let data = try JSONEncoder().encode(day)
        #expect(String(decoding: data, as: UTF8.self) == "\"2026-07-04\"")
        #expect(try JSONDecoder().decode(Day.self, from: data) == day)
    }

    @Test("fails to decode a malformed day rather than substituting a default")
    func codableRejectsGarbage() {
        let data = Data("\"yesterday\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Day.self, from: data)
        }
    }
}
