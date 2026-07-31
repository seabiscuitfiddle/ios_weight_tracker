import Foundation

/// Display formatting shared by the app and the widget.
///
/// Shared deliberately: the design's premise is that "the number you glance at on the lock
/// screen is the number you edit in the app", and that falls apart if the widget renders 1220
/// while the app renders 1,220. Keeping it in TallyCore also makes it testable without Xcode.
///
/// Every function takes a `Locale` so the tests can pin output rather than depending on the
/// machine's region.
public enum TallyFormat {
    /// A typographic minus (U+2212), not a hyphen.
    ///
    /// The design shows exercise as "−320". At the weights used for the numerals a hyphen is
    /// visibly too short and sits at the wrong height, so this is a real typographic choice
    /// rather than pedantry.
    public static let minusSign = "\u{2212}"

    // MARK: Calories

    /// Grouped whole calories: `1220` → `"1,220"`.
    public static func calories(_ value: Int, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Calories with an explicit sign, the way the log rows read: `"+280"`, `"−320"`.
    ///
    /// Takes an ``Entry`` kind rather than a signed number so callers can't accidentally pass a
    /// pre-negated value and end up with a double negative.
    public static func signedCalories(
        _ magnitude: Int,
        kind: Entry.Kind,
        locale: Locale = .current
    ) -> String {
        let number = calories(abs(magnitude), locale: locale)
        return switch kind {
        case .food: "+\(number)"
        case .exercise: "\(minusSign)\(number)"
        }
    }

    /// The `x / y` pair the design leads with: `"1,220 / 2,100"`.
    public static func progressPair(_ value: Int, of goal: Int, locale: Locale = .current) -> String {
        "\(calories(value, locale: locale)) / \(calories(goal, locale: locale))"
    }

    /// A daily adjustment as the goal panel shows it: `"−500 / day"`.
    public static func dailyAdjustment(_ value: Int, locale: Locale = .current) -> String {
        let magnitude = calories(abs(value), locale: locale)
        let sign = value < 0 ? minusSign : "+"
        return "\(sign)\(magnitude) / day"
    }

    // MARK: Macros

    /// Macro grams, rounded: `96.4` → `"96"`.
    public static func grams(_ value: Double, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value.rounded())) ?? "\(Int(value.rounded()))"
    }

    /// Macro against its target: `"96 / 150g"`.
    public static func macroPair(_ value: Double, of target: Double, locale: Locale = .current) -> String {
        "\(grams(value, locale: locale)) / \(grams(target, locale: locale))g"
    }

    // MARK: Weight

    /// Weight to one decimal place in the user's unit: `"168.4"`.
    ///
    /// One decimal is deliberate. Scales report more precision than is meaningful, and showing
    /// it invites people to read noise as progress — but rounding to whole pounds would hide
    /// genuine week-to-week movement.
    public static func weight(
        pounds: Double,
        unit: MassUnit,
        locale: Locale = .current
    ) -> String {
        let converted = unit.value(fromPounds: pounds)
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: converted)) ?? String(format: "%.1f", converted)
    }

    /// Weight with its unit: `"168.4 lb"`.
    public static func weightWithUnit(
        pounds: Double,
        unit: MassUnit,
        locale: Locale = .current
    ) -> String {
        "\(weight(pounds: pounds, unit: unit, locale: locale)) \(unit.shortName)"
    }

    /// A weight change with direction: `"↓ 4.6 lb"`, `"↑ 1.2 lb"`, `"No change"`.
    public static func weightChange(
        pounds: Double,
        unit: MassUnit,
        locale: Locale = .current
    ) -> String {
        // Below a tenth of a unit the rendered number would read "0.0", which looks like a bug.
        guard abs(unit.value(fromPounds: pounds)) >= 0.05 else { return "No change" }
        let arrow = pounds < 0 ? "↓" : "↑"
        return "\(arrow) \(weightWithUnit(pounds: abs(pounds), unit: unit, locale: locale))"
    }

    // MARK: Reading numbers back

    /// Reads the number out of what somebody typed into a weight or height field.
    ///
    /// Deliberately lenient, and shared by every such field so they all forgive the same things.
    /// "178 cm", "81,5" and a stray trailing space are all unmistakably numbers; refusing them
    /// would be pedantry that lands on the user as a value which silently declines to save. A
    /// comma is read as a decimal point rather than as a grouping separator — at the magnitudes
    /// these fields hold nobody types a grouped number, and most of the world writes "81,5" for
    /// what the US writes as "81.5".
    ///
    /// - Returns: the number, or nil when there isn't a positive one in there. Nil is a real
    ///   answer here rather than a failure: an empty goal weight means "no target".
    public static func number(from text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." }
        guard !cleaned.isEmpty, let value = Double(cleaned), value > 0 else { return nil }
        return value
    }

    /// A weight as an editable field holds it: plain digits in the displayed unit, no grouping
    /// separator.
    ///
    /// Distinct from ``weight(pounds:unit:locale:)`` on purpose. That renders a number for
    /// reading; this one has to survive being read back by ``number(from:)``, and a grouped
    /// "1,234.5" would not.
    public static func editableWeight(pounds: Double, unit: MassUnit) -> String {
        String(format: "%.1f", unit.value(fromPounds: pounds))
    }

    // MARK: Dates

    /// The design's date kicker: `"THU · JUL 23"`.
    public static func dayKicker(
        _ day: Day,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        guard let date = day.noon(calendar: calendar) else { return day.description }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter.string(from: date).uppercased(with: locale)
    }

    /// Short weekday for the History day selector: `"THU"`.
    public static func weekdayAbbreviation(
        _ day: Day,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        guard let date = day.noon(calendar: calendar) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: date).uppercased(with: locale)
    }

    /// A short target date: `"Oct 1"`.
    public static func shortDate(
        _ day: Day,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        guard let date = day.noon(calendar: calendar) else { return day.description }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter.string(from: date)
    }

    /// Entry timestamp: `"8:20 AM"`, or 24-hour where the locale prefers it.
    public static func time(
        _ date: Date,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    /// Relative day naming for headers: `"Today"`, `"Yesterday"`, else a short date.
    public static func dayTitle(
        _ day: Day,
        today: Day,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        switch day.days(until: today, calendar: calendar) {
        case 0: "Today"
        case 1: "Yesterday"
        default: shortDate(day, locale: locale, calendar: calendar)
        }
    }

    // MARK: Entry detail

    /// The secondary line under an entry: `"8:20 AM · 24g protein"`, `"6:30 AM · exercise"`.
    public static func entryDetail(
        _ entry: Entry,
        locale: Locale = .current,
        calendar: Calendar = .current
    ) -> String {
        var parts = [time(entry.loggedAt, locale: locale, calendar: calendar)]

        switch entry.kind {
        case .food:
            if entry.proteinGrams >= 1 {
                parts.append("\(grams(entry.proteinGrams, locale: locale))g protein")
            }
        case .exercise:
            if let minutes = entry.durationMinutes, minutes > 0 {
                parts.append("\(minutes) min")
            } else {
                parts.append("exercise")
            }
        }

        return parts.joined(separator: " · ")
    }
}
