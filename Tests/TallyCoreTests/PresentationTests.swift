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
        // Protein leads, the way the macros are ordered everywhere else in the design.
        #expect(foodDetail.hasSuffix("· 24g protein · 4g fiber"))

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

    @Test("omits negligible macro figures from the detail line")
    func omitsTinyMacros() {
        let coffee = Entry(
            kind: .food, label: "Black coffee", calories: 5,
            proteinGrams: 0.2, fiberGrams: 0.1
        )
        let detail = TallyFormat.entryDetail(coffee, locale: enUS, calendar: utc)
        #expect(detail.contains("protein") == false)
        #expect(detail.contains("fiber") == false)
    }

    @Test("shows fiber on its own when an entry carries no protein worth naming")
    func fiberWithoutProtein() {
        let apple = Entry(kind: .food, label: "Apple", calories: 95, fiberGrams: 4.4)
        let detail = TallyFormat.entryDetail(apple, locale: enUS, calendar: utc)
        #expect(detail.contains("4g fiber"))
        #expect(detail.contains("protein") == false)
    }

    @Test("leaves macros off exercise entries")
    func exerciseCarriesNoMacros() {
        let run = Entry(kind: .exercise, label: "Zone 2 run", calories: 320,
                        exerciseKind: .cardio, durationMinutes: 38)
        let detail = TallyFormat.entryDetail(run, locale: enUS, calendar: utc)
        #expect(detail.contains("fiber") == false)
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

    /// Contrast, pinned for the same reason as the hex values above: it is a property of the
    /// rendered result that nothing else here can see.
    ///
    /// It matters most in the home-screen widget, which paints `background` into its container
    /// and then draws every label in `text` — nothing there adapts to the system colour scheme,
    /// so this ratio *is* the widget's legibility. Lighten `text` and the widget's numbers wash
    /// out with no other test to notice.
    @Test("keep text legible against the background")
    func textContrast() {
        let body = contrastRatio(Palette.text, on: Palette.background)
        #expect(body >= 7)  // WCAG AAA.

        // Secondary labels — the kickers under the ring and above each bar — are deliberately
        // quieter, but stay above the 3:1 floor that keeps them readable rather than decorative.
        let secondary = contrastRatio(
            Palette.text, on: Palette.background, opacity: Palette.secondaryTextOpacity
        )
        #expect(secondary >= 3)
        #expect(secondary < body)
    }
}

/// The diameters the home-screen widgets actually draw the ring at: 80pt fixed in the medium
/// tile, and roughly 84–100pt in the 2×2 one, which takes whatever its footer leaves on the
/// device it lands on. The ends are padded a little for the sizes Display Zoom can produce.
private let drawnRingDiameters: [Double] = [72, 80, 88, 96, 104, 120]

/// The widest value these widgets show is a four-digit calorie count with its group separator —
/// "1,738". SF Pro's heavy digits run about 0.6em with a comma around 0.3em, so the string needs
/// roughly 2.7 × its point size.
private let widestValueEms = 2.7

@Suite("Widget ring metrics")
struct RingMetricsTests {
    /// The assertion this suite exists for. A number wider than the hole in the ring draws
    /// straight over the stroke, which is a rendering fault no simulator-free test could see —
    /// but the arithmetic that decides it is right here, so this can.
    @Test("keep the type inside the stroke, with air around it", arguments: drawnRingDiameters)
    func typeFitsTheHole(_ diameter: Double) {
        let metrics = RingMetrics(diameter: diameter)
        let halfWidth = metrics.contentWidth / 2
        let halfHeight = metrics.contentHeight / 2
        // The corner of the text box is its furthest point from the centre, so it is the first
        // thing to touch the stroke.
        let corner = (halfWidth * halfWidth + halfHeight * halfHeight).squareRoot()

        #expect(corner <= metrics.innerDiameter / 2)
        // Merely not overlapping still reads as a mistake; the design wants visible air.
        #expect(corner <= metrics.innerDiameter / 2 * 0.95)
    }

    @Test("leave room for the widest number they show", arguments: drawnRingDiameters)
    func widestValueFits(_ diameter: Double) {
        let metrics = RingMetrics(diameter: diameter)
        #expect(metrics.contentWidth >= metrics.valueFontSize * widestValueEms)
    }

    @Test("keep the caption readable and secondary", arguments: drawnRingDiameters)
    func captionStaysReadable(_ diameter: Double) {
        let metrics = RingMetrics(diameter: diameter)
        #expect(metrics.labelFontSize >= RingMetrics.minimumLabelSize)
        #expect(metrics.labelFontSize < metrics.valueFontSize)
    }

    /// Nothing may be a fixed point size: the two widgets draw this ring at different diameters,
    /// and the 2×2 one's diameter changes with the device and with Display Zoom.
    @Test("scale every dimension with the diameter")
    func everythingScales() throws {
        let metrics = drawnRingDiameters.map(RingMetrics.init(diameter:))

        #expect(metrics.map(\.lineWidth) == metrics.map(\.lineWidth).sorted())
        #expect(metrics.map(\.valueFontSize) == metrics.map(\.valueFontSize).sorted())
        #expect(metrics.map(\.contentWidth) == metrics.map(\.contentWidth).sorted())
        #expect(metrics.map(\.contentHeight) == metrics.map(\.contentHeight).sorted())

        let smallest = try #require(metrics.first)
        let largest = try #require(metrics.last)
        #expect(smallest.valueFontSize < largest.valueFontSize)
    }

    /// The design draws this ring as a 104pt box with an 11.2pt stroke. The widgets no longer
    /// draw it that large — it did not fit — but the *proportion* is what the design specifies,
    /// and holding it is what keeps the smaller ring looking like the drawing.
    @Test("hold the design's stroke proportion")
    func strokeMatchesTheDesign() {
        #expect(abs(RingMetrics(diameter: 104).lineWidth - 11.2) < 0.3)
    }

    /// Diameters too small to write two lines into, plus the nonsense a layout can briefly hand
    /// down during a transition. "No room" has to come out as zero rather than as the NaN a
    /// negative square root would give, because a NaN in a frame is a blank widget.
    @Test("survive a ring too small to write in", arguments: [-8.0, 0, 1, 12, 24])
    func degenerateDiameters(_ diameter: Double) {
        let metrics = RingMetrics(diameter: diameter)

        #expect(metrics.contentWidth.isNaN == false)
        #expect(metrics.contentWidth >= 0)
        #expect(metrics.contentHeight >= 0)
        #expect(metrics.lineWidth >= 0)
        #expect(metrics.innerDiameter >= 0)
    }
}

/// The other half of the ring: ``RingMetrics`` decides how big its type is, ``NetRingContent``
/// decides what that type says. All three widgets take their answer from here, which is what stops
/// them from captioning the same calories differently — the way they did when the 2×2 tile read
/// "2,100 OF 2,100" on a day nothing had been logged, and when the lock screen showed the net
/// against the goal while the other two showed what was left.
@Suite("Net ring content")
struct NetRingContentTests {
    @Test("leads with what's left, and says that's what it is")
    func remainingLeads() {
        let content = NetRingContent(netCalories: 1220, goalCalories: 2100, locale: enUS)

        #expect(content.value == "880")
        #expect(content.label == "CAL LEFT")
    }

    /// The regression the 2×2 widget shipped with. Its kicker spelled the goal out — "OF 2,100" —
    /// under a number that was what *remained*, so an untouched day showed the goal against the
    /// goal and looked like a day already spent, and every entry logged made it count down.
    @Test("reads as a whole day left, not a whole day eaten, before anything is logged")
    func untouchedDay() {
        let content = NetRingContent(netCalories: 0, goalCalories: 2100, locale: enUS)

        #expect(content.value == "2,100")
        #expect(content.label == "CAL LEFT")
        // Nothing in the caption may restate the goal: beside a remaining count it reads as a
        // consumed one.
        #expect(content.label.contains("2,100") == false)
    }

    /// The lock screen's regression, and the reason its number now comes from here too. That
    /// widget led with the day's *net* against the goal, so an exercise credit moved the number it
    /// showed 500 calories the wrong way — down — at the same moment the home-screen tiles counted
    /// 500 more available. Both readings are arithmetically true; only one of them answers the
    /// question a calorie widget is glanced at to answer.
    @Test("counts an exercise credit as calories gained, not spent")
    func exerciseCredit() {
        let goal = 2100
        let eaten = DayTotals(foodCalories: 1500, entryCount: 1)
        let afterAWalk = DayTotals(foodCalories: 1500, exerciseCalories: 500, entryCount: 2)

        let before = NetRingContent(netCalories: eaten.netCalories, goalCalories: goal, locale: enUS)
        let after = NetRingContent(
            netCalories: afterAWalk.netCalories, goalCalories: goal, locale: enUS
        )

        #expect(before.value == "600")
        #expect(after.value == "1,100")
        #expect(after.label == "CAL LEFT")
        #expect(after.accessibilityValue == "1,100 of 2,100")
        // The framing the lock screen used to show, pinned so the difference is explicit: the net
        // falls by the credit, which is the number that looked like the widget was ignoring it.
        #expect(afterAWalk.netCalories == 1000)
    }

    /// Passing the goal is a fact about the day, not an error state — the same reason
    /// ``DayTotals/remaining(against:)`` goes negative rather than clamping.
    @Test("goes negative once the goal is passed")
    func overGoal() {
        let content = NetRingContent(netCalories: 2220, goalCalories: 2100, locale: enUS)

        #expect(content.value.contains("120"))
        // Signed, rather than the bare "120" that would read as calories still available.
        #expect(content.value != "120")
        #expect(content.label == "CAL LEFT")
    }

    /// No goal is a failed or unfinished setup, not a zero goal. There is no "remaining" to show,
    /// so the ring shows the net and captions it as the net.
    @Test("falls back to the net when there is no goal to count toward")
    func withoutAGoal() {
        let content = NetRingContent(netCalories: 1220, goalCalories: nil, locale: enUS)

        #expect(content.value == "1,220")
        #expect(content.label == "NET")
        #expect(content.accessibilityLabel == "Net calories")
        #expect(content.accessibilityValue == "1,220")
    }

    /// VoiceOver used to announce the net against the goal — "1,220 / 2,100" — while the digits
    /// on screen said 880. Whatever the wording, it has to be about the number being shown.
    @Test("announces the number that is actually on screen")
    func spokenValueMatchesTheDigits() {
        let content = NetRingContent(netCalories: 1220, goalCalories: 2100, locale: enUS)

        #expect(content.accessibilityLabel == "Calories remaining")
        #expect(content.accessibilityValue == "880 of 2,100")
        #expect(content.accessibilityValue.hasPrefix(content.value))
    }
}

/// WCAG 2.1 contrast between a foreground token and an opaque background token.
///
/// A translucent foreground is composited onto the background first, which is what the
/// compositor does with the `opacity:` argument the views pass to `Color(token:)`.
private func contrastRatio(
    _ foreground: UInt32, on background: UInt32, opacity: Double = 1
) -> Double {
    func channels(_ token: UInt32) -> (Double, Double, Double) {
        (
            Double((token >> 16) & 0xFF) / 255,
            Double((token >> 8) & 0xFF) / 255,
            Double(token & 0xFF) / 255
        )
    }

    func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.0) + 0.7152 * linear(rgb.1) + 0.0722 * linear(rgb.2)
    }

    let back = channels(background)
    let front = channels(foreground)
    let composited = (
        front.0 * opacity + back.0 * (1 - opacity),
        front.1 * opacity + back.1 * (1 - opacity),
        front.2 * opacity + back.2 * (1 - opacity)
    )

    let lighter = max(luminance(composited), luminance(back))
    let darker = min(luminance(composited), luminance(back))
    return (lighter + 0.05) / (darker + 0.05)
}
