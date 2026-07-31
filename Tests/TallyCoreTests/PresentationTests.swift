import Foundation
import Testing
@testable import TallyCore

private let enUS = Locale(identifier: "en_US")
private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.locale = enUS
    return calendar
}()

@Suite("Deep links")
struct DeepLinkTests {
    @Test("every destination round-trips through its URL", arguments: [
        DeepLink.today,
        .log(mode: .text),
        .log(mode: .photo),
        .log(mode: .voice),
        .history(day: nil),
        .history(day: Day(year: 2026, month: 7, day: 23)),
        .progress,
        .settings,
    ])
    func roundTrip(_ link: DeepLink) {
        #expect(DeepLink(url: link.url) == link)
    }

    /// The widget's three quick-log buttons are exactly these URLs. If this breaks, the buttons
    /// silently open the wrong screen.
    @Test("parses the widget's quick-log URLs", arguments: [
        ("tally://log?mode=text", DeepLink.LogMode.text),
        ("tally://log?mode=photo", .photo),
        ("tally://log?mode=voice", .voice),
    ])
    func widgetURLs(_ string: String, _ expected: DeepLink.LogMode) throws {
        let url = try #require(URL(string: string))
        #expect(DeepLink(url: url) == .log(mode: expected))
    }

    @Test("accepts the path form as well as the host form")
    func pathForm() throws {
        let pathForm = try #require(URL(string: "tally:///progress"))
        let hostForm = try #require(URL(string: "tally://progress"))
        #expect(DeepLink(url: pathForm) == .progress)
        #expect(DeepLink(url: hostForm) == .progress)
    }

    @Test("is case-insensitive about scheme and action")
    func caseInsensitive() throws {
        let url = try #require(URL(string: "TALLY://TODAY"))
        #expect(DeepLink(url: url) == .today)
    }

    /// Falling back to text keeps a malformed widget URL useful: text logging always works and
    /// needs no permission, where voice would prompt for a microphone the user didn't ask about.
    @Test("falls back to text for a missing or unknown log mode")
    func logModeFallback() throws {
        let bare = try #require(URL(string: "tally://log"))
        let unknown = try #require(URL(string: "tally://log?mode=telepathy"))
        #expect(DeepLink(url: bare) == .log(mode: .text))
        #expect(DeepLink(url: unknown) == .log(mode: .text))
    }

    /// A URL we don't understand is a bug or a hostile link. Landing the user somewhere
    /// plausible would hide both.
    @Test("rejects foreign or unknown URLs", arguments: [
        "https://example.com/log",
        "tally://unknown",
        "notally://today",
        "mailto:someone@example.com",
    ])
    func rejectsForeignURLs(_ string: String) throws {
        let url = try #require(URL(string: string))
        #expect(DeepLink(url: url) == nil)
    }

    @Test("ignores an unparseable day rather than failing the whole link")
    func badDayFallsBack() throws {
        let url = try #require(URL(string: "tally://history?day=yesterday"))
        #expect(DeepLink(url: url) == .history(day: nil))
    }

    @Test("routes each destination to the right tab")
    func tabRouting() {
        #expect(DeepLink.today.tab == .today)
        #expect(DeepLink.log(mode: .voice).tab == .log)
        #expect(DeepLink.history(day: nil).tab == .history)
        #expect(DeepLink.progress.tab == .progress)
        // Settings opens over Progress, where the design puts the profile button.
        #expect(DeepLink.settings.tab == .progress)
    }
}

@Suite("Formatting")
struct FormattingTests {
    @Test("groups thousands in calorie counts")
    func groupedCalories() {
        #expect(TallyFormat.calories(1220, locale: enUS) == "1,220")
        #expect(TallyFormat.calories(880, locale: enUS) == "880")
        #expect(TallyFormat.calories(0, locale: enUS) == "0")
    }

    /// The design writes exercise as "−320" with a typographic minus, not a hyphen — at these
    /// numeral weights a hyphen is visibly short and sits too low.
    @Test("signs entry calories by kind, using a typographic minus")
    func signedCalories() {
        #expect(TallyFormat.signedCalories(280, kind: .food, locale: enUS) == "+280")
        #expect(TallyFormat.signedCalories(320, kind: .exercise, locale: enUS) == "\u{2212}320")
        #expect(TallyFormat.signedCalories(320, kind: .exercise, locale: enUS).contains("-") == false)
    }

    /// Passing an already-negative magnitude must not produce a double negative — the reason
    /// the API takes a kind rather than a signed number.
    @Test("normalises magnitude regardless of the sign passed in")
    func signedCaloriesIgnoresInputSign() {
        #expect(TallyFormat.signedCalories(-320, kind: .exercise, locale: enUS) == "\u{2212}320")
        #expect(TallyFormat.signedCalories(-280, kind: .food, locale: enUS) == "+280")
    }

    @Test("renders the x / y pair the design leads with")
    func progressPair() {
        #expect(TallyFormat.progressPair(1220, of: 2100, locale: enUS) == "1,220 / 2,100")
    }

    @Test("renders the daily adjustment")
    func dailyAdjustment() {
        #expect(TallyFormat.dailyAdjustment(-500, locale: enUS) == "\u{2212}500 / day")
        #expect(TallyFormat.dailyAdjustment(250, locale: enUS) == "+250 / day")
    }

    @Test("renders macros against their target")
    func macroPair() {
        #expect(TallyFormat.macroPair(96, of: 150, locale: enUS) == "96 / 150g")
        #expect(TallyFormat.macroPair(22.4, of: 38, locale: enUS) == "22 / 38g")
    }

    @Test("shows weight to one decimal place in the chosen unit")
    func weight() {
        #expect(TallyFormat.weight(pounds: 168.4, unit: .pounds, locale: enUS) == "168.4")
        #expect(TallyFormat.weightWithUnit(pounds: 168.4, unit: .pounds, locale: enUS) == "168.4 lb")

        // 168.4 lb ≈ 76.4 kg.
        let metric = TallyFormat.weightWithUnit(pounds: 168.4, unit: .kilograms, locale: enUS)
        #expect(metric.hasSuffix(" kg"))
        #expect(metric.hasPrefix("76."))
    }

    @Test("rounds a whole weight to one decimal rather than dropping it")
    func weightAlwaysShowsDecimal() {
        #expect(TallyFormat.weight(pounds: 170, unit: .pounds, locale: enUS) == "170.0")
    }

    /// What the editable fields put in the box has to survive being read back out of it, or a
    /// weight the user never touched changes the moment they tap in and out of the field.
    @Test("round-trips an editable weight through its own reader")
    func editableWeightRoundTrips() {
        let text = TallyFormat.editableWeight(pounds: 168.4, unit: .pounds)

        #expect(text == "168.4")
        #expect(TallyFormat.number(from: text) == 168.4)
        // Including the four-figure weights a grouping separator would otherwise break.
        let heavy = TallyFormat.editableWeight(pounds: 1234.5, unit: .pounds)
        #expect(heavy == "1234.5")
        #expect(TallyFormat.number(from: heavy) == 1234.5)
    }

    @Test("reads a typed number leniently")
    func typedNumbers() {
        #expect(TallyFormat.number(from: "170") == 170)
        #expect(TallyFormat.number(from: " 170.4 ") == 170.4)
        // A comma is a decimal point, not a grouping separator.
        #expect(TallyFormat.number(from: "81,5") == 81.5)
        // Units typed into the field alongside the number.
        #expect(TallyFormat.number(from: "178 cm") == 178)
        #expect(TallyFormat.number(from: "155 lb") == 155)
    }

    /// Nil is the answer for a field with no usable number in it — for a goal weight that means
    /// "no target", which is a setting rather than a failure.
    @Test("has no number for an empty or unusable field", arguments: ["", "   ", "abc", "0", "."])
    func unusableInput(_ text: String) {
        #expect(TallyFormat.number(from: text) == nil)
    }

    @Test("shows weight change with a direction arrow")
    func weightChange() {
        #expect(TallyFormat.weightChange(pounds: -4.6, unit: .pounds, locale: enUS) == "↓ 4.6 lb")
        #expect(TallyFormat.weightChange(pounds: 1.2, unit: .pounds, locale: enUS) == "↑ 1.2 lb")
    }

    /// A change under a tenth would render as "↓ 0.0 lb", which reads as a bug.
    @Test("says no change rather than showing a rounded zero")
    func negligibleWeightChange() {
        #expect(TallyFormat.weightChange(pounds: 0, unit: .pounds, locale: enUS) == "No change")
        #expect(TallyFormat.weightChange(pounds: 0.02, unit: .pounds, locale: enUS) == "No change")
    }

    @Test("renders the date kicker in caps")
    func dayKicker() {
        let day = Day(year: 2026, month: 7, day: 23)  // a Thursday
        let kicker = TallyFormat.dayKicker(day, locale: enUS, calendar: utc)

        #expect(kicker.contains("THU"))
        #expect(kicker.contains("JUL"))
        #expect(kicker.contains("23"))
        #expect(kicker == kicker.uppercased())
    }

    @Test("abbreviates weekdays for the History selector")
    func weekdayAbbreviation() {
        // 2026-07-20 is a Monday.
        #expect(TallyFormat.weekdayAbbreviation(
            Day(year: 2026, month: 7, day: 20), locale: enUS, calendar: utc
        ) == "MON")
        #expect(TallyFormat.weekdayAbbreviation(
            Day(year: 2026, month: 7, day: 23), locale: enUS, calendar: utc
        ) == "THU")
    }

    @Test("names today and yesterday rather than dating them")
    func relativeDayTitles() {
        let today = Day(year: 2026, month: 7, day: 23)

        #expect(TallyFormat.dayTitle(today, today: today, locale: enUS, calendar: utc) == "Today")
        #expect(TallyFormat.dayTitle(
            today.adding(days: -1, calendar: utc), today: today, locale: enUS, calendar: utc
        ) == "Yesterday")

        let older = TallyFormat.dayTitle(
            today.adding(days: -5, calendar: utc), today: today, locale: enUS, calendar: utc
        )
        #expect(older.contains("18"))
    }

    @Test("formats a short target date")
    func shortDate() {
        let date = TallyFormat.shortDate(
            Day(year: 2026, month: 10, day: 1), locale: enUS, calendar: utc
        )
        #expect(date.contains("Oct"))
        #expect(date.contains("1"))
    }

    @Test("formats entry times")
    func entryTime() {
        let morning = utc.date(from: DateComponents(
            year: 2026, month: 7, day: 23, hour: 8, minute: 20
        ))!
        let formatted = TallyFormat.time(morning, locale: enUS, calendar: utc)

        #expect(formatted.contains("8:20"))
        #expect(formatted.uppercased().contains("AM"))
    }

    @Test("builds the entry detail line for food and exercise")
    func entryDetail() {
        let at8_20 = utc.date(from: DateComponents(
            year: 2026, month: 7, day: 23, hour: 8, minute: 20
        ))!

        let food = Entry(
            kind: .food, label: "Greek yogurt & berries", calories: 280,
            proteinGrams: 24, fiberGrams: 4, loggedAt: at8_20, calendar: utc
        )
        let foodDetail = TallyFormat.entryDetail(food, locale: enUS, calendar: utc)
        #expect(foodDetail.contains("8:20"))
        #expect(foodDetail.contains("24g protein"))

        let run = Entry(
            kind: .exercise, label: "Zone 2 run", calories: 320,
            exerciseKind: .cardio, durationMinutes: 38, loggedAt: at8_20, calendar: utc
        )
        let runDetail = TallyFormat.entryDetail(run, locale: enUS, calendar: utc)
        #expect(runDetail.contains("38 min"))

        // Exercise with no duration still says what it is.
        let untimed = Entry(
            kind: .exercise, label: "Walk", calories: 100,
            exerciseKind: .cardio, loggedAt: at8_20, calendar: utc
        )
        #expect(TallyFormat.entryDetail(untimed, locale: enUS, calendar: utc).contains("exercise"))
    }

    @Test("omits a negligible protein figure from the detail line")
    func omitsTinyProtein() {
        let coffee = Entry(kind: .food, label: "Black coffee", calories: 5, proteinGrams: 0.2)
        let detail = TallyFormat.entryDetail(coffee, locale: enUS, calendar: utc)
        #expect(detail.contains("protein") == false)
    }
}

@Suite("Design tokens")
struct DesignTokenTests {
    /// Transcribed by hand from the design system's stylesheet. A wrong hex compiles perfectly
    /// and simply looks wrong, which no other test in this project could catch — and I cannot
    /// see the rendered result, so these values are pinned here instead.
    @Test("match the Modernist stylesheet")
    func paletteValues() {
        #expect(Palette.background == 0xF3F2F2)
        #expect(Palette.surface == 0xEAE9E9)
        #expect(Palette.text == 0x201E1D)
        #expect(Palette.accent == 0xEC3013)
        #expect(Palette.accentSecondary == 0xE15B47)
    }

    /// The flat, sharp-cornered geometry is the design language. Rounding a corner anywhere
    /// breaks it more thoroughly than any colour mistake would.
    @Test("keep every corner square")
    func zeroCornerRadius() {
        #expect(Metrics.cornerRadius == 0)
    }

    @Test("keep rules hairline-thin and headers heavier")
    func ruleWeights() {
        #expect(Metrics.hairline == 1.5)
        #expect(Metrics.rule == 2)
        #expect(Metrics.rule > Metrics.hairline)
    }

    @Test("space scale ascends")
    func spacingScale() {
        let scale = [
            Metrics.space1, Metrics.space2, Metrics.space3,
            Metrics.space4, Metrics.space6, Metrics.space8,
        ]
        #expect(scale == scale.sorted())
        #expect(Metrics.space1 == 4)
        #expect(Metrics.space8 == 32)
    }

    /// The wide letter-spacing is what makes the kicker read as a label rather than as small
    /// text; losing it would flatten the type hierarchy the design depends on.
    @Test("keep the kicker's wide tracking and the display's tight tracking")
    func trackingDirections() {
        #expect(Typography.Kicker.tracking > 0)
        #expect(Typography.Display.tracking < 0)
        #expect(Typography.Kicker.size == 10)
    }

    @Test("name the Archivo family")
    func fontFamily() {
        #expect(Typography.family == "Archivo")
    }
}
