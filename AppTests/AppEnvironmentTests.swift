import AppIntents
import Foundation
import Testing
import TallyCore
@testable import Tally

/// Tests for the app target itself.
///
/// Deliberately thin. Everything decidable lives in TallyCore and is tested there, on any
/// platform; what's left here is the glue that can only exist inside an app — deep-link routing
/// into view state, and the view models' interaction with the stores.
@MainActor
@Suite("App environment")
struct AppEnvironmentTests {
    private func environment() -> AppEnvironment {
        AppEnvironment(previewStores: .inMemory())
    }

    @Test("a widget quick-log URL selects the Log tab and its compose mode")
    func widgetDeepLinkRouting() throws {
        let environment = environment()
        let url = try #require(URL(string: "tally://log?mode=voice"))

        environment.handle(url)

        #expect(environment.selectedTab == .log)
        #expect(environment.pendingLogMode == .voice)
    }

    @Test("a settings link opens settings over the Progress tab")
    func settingsDeepLink() throws {
        let environment = environment()
        let url = try #require(URL(string: "tally://settings"))

        environment.handle(url)

        #expect(environment.isShowingSettings)
        #expect(environment.selectedTab == .progress)
    }

    @Test("an unrecognised URL changes nothing")
    func ignoresForeignURLs() throws {
        let environment = environment()
        environment.selectedTab = .history
        let url = try #require(URL(string: "https://example.com/log"))

        environment.handle(url)

        #expect(environment.selectedTab == .history)
        #expect(environment.pendingLogMode == nil)
    }

    /// The widget's "Text" button is the one that looked like it did nothing: it sets the mode
    /// before the Log screen exists, so the screen reads it when it appears rather than being
    /// told about a change. Both of the screen's reads go through here.
    @Test("the requested compose mode survives until the Log screen takes it")
    func pendingModeIsWaitingWhenTheScreenAppears() throws {
        let environment = environment()
        let url = try #require(URL(string: "tally://log?mode=text"))

        environment.handle(url)

        #expect(environment.selectedTab == .log)
        #expect(environment.takePendingLogMode() == .text)
    }

    /// A mode left set is not inert: the Log screen treats one as "a deep link is steering this
    /// screen" and holds the keyboard back, so failing to clear it breaks every later visit.
    @Test("taking the compose mode clears it")
    func takingTheModeClearsIt() throws {
        let environment = environment()
        environment.handle(try #require(URL(string: "tally://log?mode=photo")))

        #expect(environment.takePendingLogMode() == .photo)

        #expect(environment.takePendingLogMode() == nil)
        #expect(environment.pendingLogMode == nil)
    }

    /// Tapping the same widget button twice has to work twice. It only can because the first tap
    /// left nothing behind — a mode that stayed set would make the second tap no change at all.
    @Test("the same widget button asked for twice is honoured twice")
    func repeatedTapsOfOneButton() throws {
        let environment = environment()
        let url = try #require(URL(string: "tally://log?mode=text"))

        environment.handle(url)
        #expect(environment.takePendingLogMode() == .text)

        environment.handle(url)
        #expect(environment.takePendingLogMode() == .text)
    }

    /// "Open quick log" routes through the same pending mode, and lands the same way: the app is
    /// launched by the intent, so the screen is always reading a mode set before it existed.
    @Test("an App Intent's destination is picked up the same way")
    func intentLinkBecomesAPendingMode() {
        let environment = environment()
        OpenQuickLogIntent.pendingLink = .log(mode: .text)
        defer { OpenQuickLogIntent.pendingLink = nil }

        environment.consumePendingIntentLink()

        #expect(environment.selectedTab == .log)
        #expect(environment.takePendingLogMode() == .text)
    }
}

/// The rule that matters here is the expiry: a dismissal is scoped to the build that was running
/// when it was made, so an update always shows the warning again.
@Suite("Banner dismissals")
struct BannerDismissalTests {
    /// A defaults suite of its own per test, so one test can't see another's writes — or the
    /// simulator's leftovers from a previous run.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "tally.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("a dismissed banner stays dismissed on the next launch")
    func survivesRelaunch() {
        withDefaults { defaults in
            BannerDismissals(defaults: defaults, version: "1.0 (1)").dismiss("widgetOnly")

            // A fresh instance is what the next launch builds.
            let relaunched = BannerDismissals(defaults: defaults, version: "1.0 (1)")

            #expect(relaunched.dismissed() == ["widgetOnly"])
        }
    }

    @Test("a new build shows the banner again")
    func expiresOnUpdate() {
        withDefaults { defaults in
            BannerDismissals(defaults: defaults, version: "1.0 (1)").dismiss("widgetOnly")

            #expect(BannerDismissals(defaults: defaults, version: "1.0 (2)").dismissed().isEmpty)
            #expect(BannerDismissals(defaults: defaults, version: "1.1 (1)").dismissed().isEmpty)
        }
    }

    /// The two banners describe different problems, and the milder one is the one users will
    /// close. Closing it must not pre-dismiss "nothing is being saved".
    @Test("dismissing one banner leaves the other showing")
    func dismissalsAreIndependent() {
        withDefaults { defaults in
            let dismissals = BannerDismissals(defaults: defaults, version: "1.0 (1)")

            dismissals.dismiss("widgetOnly")

            #expect(dismissals.dismissed().contains("notSaving") == false)
        }
    }

    @Test("a memory-only store writes nothing to disk")
    func memoryOnly() {
        withDefaults { defaults in
            BannerDismissals(defaults: nil, version: "1.0 (1)").dismiss("widgetOnly")

            #expect(BannerDismissals(defaults: defaults, version: "1.0 (1)").dismissed().isEmpty)
        }
    }
}

@MainActor
@Suite("Today model")
struct TodayModelTests {
    private let day = Day.today()

    @Test("totals the day and reports what's left against the goal")
    func totalsAndRemaining() throws {
        let stores = StoreBundle.inMemory(
            entries: [
                Entry(kind: .food, label: "Lunch", calories: 640, proteinGrams: 48, day: Day.today()),
                Entry(kind: .exercise, label: "Run", calories: 320,
                      exerciseKind: .cardio, day: Day.today()),
            ],
            weights: [WeightSample(day: Day.today(), pounds: 168.4)],
            profile: UserProfile(
                birthDate: Calendar.current.date(byAdding: .year, value: -35, to: Date()),
                heightCentimeters: 178,
                biologicalSex: .male
            ),
            goal: GoalSettings(targetPounds: 155)
        )

        let model = TodayModel(stores: stores)
        model.load()

        #expect(model.totals.netCalories == 320)
        #expect(model.entries.count == 2)
        #expect(model.needsGoalSetup == false)
        #expect(model.remaining == (model.goal?.calories ?? 0) - 320)
    }

    /// With no profile and no weight there is nothing to compute a goal from, and the screen
    /// must ask rather than draw a ring around an invented number.
    @Test("asks for setup when no goal can be computed")
    func promptsForSetup() {
        let model = TodayModel(stores: .inMemory())
        model.load()

        #expect(model.needsGoalSetup)
        #expect(model.goal == nil)
        #expect(model.remaining == nil)
    }

    @Test("deleting an entry removes it from the day")
    func deletion() throws {
        let entry = Entry(kind: .food, label: "Toast", calories: 200, day: Day.today())
        let stores = StoreBundle.inMemory(entries: [entry])
        let model = TodayModel(stores: stores)
        model.load()
        #expect(model.entries.count == 1)

        model.delete(entry)
        model.load()

        #expect(model.entries.isEmpty)
        #expect(model.totals.netCalories == 0)
    }
}

/// Both numbers on this screen are typed as well as stepped, and the arithmetic that keeps a
/// typed field and a canonical pound value in step is where this can go wrong quietly — a logged
/// weight that isn't the one on the scale is worse than one that fails to save.
@MainActor
@Suite("Progress model")
struct ProgressModelTests {
    private static let today = Day.today()

    private static func stores(
        pounds: Double = 170,
        unit: MassUnit = .pounds,
        target: Double? = nil
    ) -> StoreBundle {
        .inMemory(
            weights: [WeightSample(day: today, pounds: pounds)],
            profile: UserProfile(massUnit: unit),
            goal: GoalSettings(targetPounds: target)
        )
    }

    @Test("seeds both fields from what is stored")
    func seedsFields() {
        let model = ProgressModel(stores: Self.stores(pounds: 168.4, target: 155))
        model.load()

        #expect(model.draftText == "168.4")
        #expect(model.targetText == "155.0")
    }

    /// The point of the whole change: a weight that is nowhere near the seeded one is typed, not
    /// tapped towards.
    @Test("logs the weight that was typed")
    func logsTypedWeight() throws {
        let stores = Self.stores(pounds: 170)
        let model = ProgressModel(stores: stores)
        model.load()

        model.draftText = "182.4"
        model.logDraft()

        #expect(try stores.weights.sample(on: Self.today)?.pounds == 182.4)
        #expect(model.draftPounds == 182.4)
    }

    @Test("steps from what has been typed rather than from the seeded weight")
    func stepsFromTypedValue() {
        let model = ProgressModel(stores: Self.stores(pounds: 170))
        model.load()

        model.draftText = "182"
        model.adjustDraft(by: 0.2)

        #expect(model.draftText == "182.2")
    }

    /// An emptied or half-typed weight field has no sensible reading, and taking it as zero would
    /// log a body weight of nothing.
    @Test("leaves the previous weight standing when the field says nothing", arguments: ["", "."])
    func unreadableWeightFieldReverts(_ text: String) {
        let model = ProgressModel(stores: Self.stores(pounds: 170))
        model.load()

        model.draftText = text
        model.commitDraft()

        #expect(model.draftPounds == 170)
        #expect(model.draftText == "170.0")
    }

    @Test("saves a typed goal weight to settings")
    func savesTypedTarget() throws {
        let stores = Self.stores(target: 165)
        let model = ProgressModel(stores: stores)
        model.load()

        model.focusChanged(from: nil, to: .target)
        model.targetText = "150"
        model.focusChanged(from: .target, to: nil)

        #expect(try stores.settings.goalSettings().targetPounds == 150)
        #expect(model.targetPounds == 150)
    }

    /// Emptying the field is how a target is given up, and that has to reach storage — otherwise
    /// the goal engine keeps chasing a number the user has deleted.
    @Test("clears the target when the field is emptied")
    func clearsTarget() throws {
        let stores = Self.stores(target: 155)
        let model = ProgressModel(stores: stores)
        model.load()

        model.targetText = ""
        model.commitTarget()

        #expect(try stores.settings.goalSettings().targetPounds == nil)
        #expect(model.targetPounds == nil)
    }

    /// A kilogram target displayed to one decimal doesn't convert back to exactly the pounds it
    /// came from, so a commit that only compared canonical values would rewrite — and drift —
    /// the stored target every time the field was tapped into and left alone.
    @Test("tapping through the goal field without editing changes nothing")
    func untouchedTargetIsNotRewritten() throws {
        let stores = Self.stores(unit: .kilograms, target: 155)
        let model = ProgressModel(stores: stores)
        model.load()

        model.focusChanged(from: nil, to: .target)
        model.focusChanged(from: .target, to: nil)

        #expect(try stores.settings.goalSettings().targetPounds == 155)
    }

    /// Fields are in the unit on screen; pounds stay canonical underneath.
    @Test("reads and writes the fields in the displayed unit")
    func convertsFromDisplayedUnit() throws {
        let stores = Self.stores(pounds: 170, unit: .kilograms, target: 155)
        let model = ProgressModel(stores: stores)
        model.load()

        // 170 lb ≈ 77.1 kg, 155 lb ≈ 70.3 kg.
        #expect(model.draftText.hasPrefix("77."))
        #expect(model.targetText.hasPrefix("70."))

        model.draftText = "75"
        model.commitDraft()

        // 75 kg ≈ 165.3 lb.
        #expect(abs(model.draftPounds - 165.35) < 0.05)
    }

    /// Everything on this screen reloads whenever anything is written — including from the
    /// widget, an App Intent, or a Health import. None of that may land in a field mid-edit.
    @Test("a reload doesn't overwrite the field being typed into")
    func reloadLeavesAnEditAlone() throws {
        let stores = Self.stores(pounds: 170, target: 155)
        let model = ProgressModel(stores: stores)
        model.load()

        model.focusChanged(from: nil, to: .draft)
        model.draftText = "18"

        try stores.weights.save(WeightSample(day: Self.today, pounds: 171))
        model.load()

        #expect(model.draftText == "18")
        // The field not being touched still refreshes.
        #expect(model.targetText == "155.0")
    }
}

@MainActor
@Suite("Log model")
struct LogModelTests {
    @Test("saves what the parser returns and shows it as just added")
    func savesParsedItems() async throws {
        let stores = StoreBundle.inMemory()
        let model = LogModel(stores: stores, parser: StubNutritionParser())

        await model.log(text: "two eggs and toast")

        #expect(model.justAdded.count == 1)
        #expect(model.errorMessage == nil)
        // And it really reached storage, not just the view state.
        #expect(try stores.entries.entries(on: Day.today()).count == 1)
    }

    /// The parser named no fragment here, so the whole description stands for the send — which
    /// is exactly right when it produced one entry.
    @Test("keeps the user's own words on the saved entry")
    func retainsTranscript() async throws {
        let stores = StoreBundle.inMemory()
        let model = LogModel(stores: stores, parser: StubNutritionParser())

        await model.log(text: "two eggs and toast")

        #expect(model.justAdded.first?.rawInput == "two eggs and toast")
        #expect(model.justAdded.first?.source == .llmText)
    }

    /// Logging is almost always several things at once. Each card is corrected on its own, so
    /// each carries only the words it came from — captioning all three with the whole sentence
    /// makes clarifying the toast a matter of re-reading the eggs and the coffee.
    @Test("gives each entry only the part of the description it came from")
    func splitsDescriptionAcrossEntries() async throws {
        let stores = StoreBundle.inMemory()
        let parser = StubNutritionParser(result: ParseResult(items: [
            ParsedItem(kind: .food, label: "Scrambled eggs", sourceText: "two eggs",
                       calories: 180, proteinGrams: 12),
            ParsedItem(kind: .food, label: "Sourdough toast", sourceText: "toast",
                       calories: 160, proteinGrams: 5),
            ParsedItem(kind: .food, label: "Black coffee", sourceText: "a black coffee",
                       calories: 5),
        ]))
        let model = LogModel(stores: stores, parser: parser)

        await model.log(text: "two eggs, toast and a black coffee")

        #expect(model.justAdded.count == 3)
        #expect(
            model.justAdded.compactMap(\.rawInput) == ["two eggs", "toast", "a black coffee"]
        )
        #expect(try stores.entries.entries(on: Day.today()).count == 3)
    }

    /// A photo's items have no words of their own, so whatever note was typed alongside it
    /// stands for all of them rather than leaving the cards blank.
    @Test("falls back to the note when a photo's items name no words")
    func photoItemsFallBackToTheNote() async throws {
        let stores = StoreBundle.inMemory()
        let parser = StubNutritionParser(result: ParseResult(items: [
            ParsedItem(kind: .food, label: "Chicken bowl", calories: 640),
        ]))
        let model = LogModel(stores: stores, parser: parser)

        await model.log(image: Data([0x01]), mediaType: .jpeg, note: "half of it was left over")

        #expect(model.justAdded.first?.rawInput == "half of it was left over")
        #expect(model.justAdded.first?.source == .llmPhoto)
    }

    /// A failure has to be actionable: the message the user sees, and whether the UI should
    /// offer "try again" or send them to Settings.
    @Test("surfaces a parser failure with the right follow-up action")
    func surfacesErrors() async throws {
        let stores = StoreBundle.inMemory()
        let parser = StubNutritionParser(error: NutritionParserError.missingAPIKey)
        let model = LogModel(stores: stores, parser: parser)

        await model.log(text: "toast")

        #expect(model.errorMessage == NutritionParserError.missingAPIKey.userMessage)
        #expect(model.needsAPIKey)
        #expect(model.canRetry == false)
        #expect(model.justAdded.isEmpty)
        #expect(try stores.entries.entries(on: Day.today()).isEmpty)
    }

    @Test("offers a retry for a transient failure")
    func retryableErrors() async throws {
        let parser = StubNutritionParser(error: NutritionParserError.overloaded)
        let model = LogModel(stores: .inMemory(), parser: parser)

        await model.log(text: "toast")

        #expect(model.canRetry)
        #expect(model.needsAPIKey == false)
    }

    /// Voice and keyboard both send text, so the source has to be carried explicitly. Getting it
    /// wrong would mislabel every dictated entry's provenance in the log.
    @Test("records voice-originated text as a voice entry")
    func recordsSpokenSource() async throws {
        let stores = StoreBundle.inMemory()
        let model = LogModel(stores: stores, parser: StubNutritionParser())

        await model.log(text: "two eggs and toast", spoken: true)

        #expect(model.justAdded.first?.source == .llmVoice)
    }

    @Test("records typed text as a text entry")
    func recordsTypedSource() async throws {
        let stores = StoreBundle.inMemory()
        let model = LogModel(stores: stores, parser: StubNutritionParser())

        await model.log(text: "two eggs and toast")

        #expect(model.justAdded.first?.source == .llmText)
    }

    /// A retry must not change how the entry is labelled — the input didn't change, only the
    /// attempt count.
    @Test("a retry keeps the original provenance")
    func retryKeepsProvenance() async throws {
        let stores = StoreBundle.inMemory()
        let parser = StubNutritionParser(error: NutritionParserError.overloaded)
        let model = LogModel(stores: stores, parser: parser)

        await model.log(text: "two eggs", spoken: true)
        #expect(model.justAdded.isEmpty)

        // Same model, now with a parser that succeeds.
        let working = LogModel(stores: stores, parser: StubNutritionParser())
        await working.log(text: "two eggs", spoken: true)
        await working.retry()

        #expect(working.justAdded.allSatisfy { $0.source == .llmVoice })
    }
}

@MainActor
@Suite("Entry editor")
struct EntryEditorModelTests {
    /// A day in the past, because the thing most likely to go wrong in an edit is the corrected
    /// entry silently moving to today.
    private static let pastDay = Day.today().adding(days: -9)

    private static func logged(
        rawInput: String? = "two eggs and toast",
        label: String = "Scrambled eggs & toast"
    ) -> Entry {
        Entry(
            kind: .food, label: label, calories: 340, proteinGrams: 18, fiberGrams: 3,
            loggedAt: Date(timeIntervalSince1970: 1_700_000_000), day: pastDay,
            source: .llmText, rawInput: rawInput
        )
    }

    @Test("seeds the field with the words that produced this entry")
    func seedsFromRawInput() {
        let model = EntryEditorModel(
            entry: Self.logged(), stores: .inMemory(), parser: StubNutritionParser()
        )

        #expect(model.text == "two eggs and toast")
        // Nothing has been changed yet, so there is nothing to save.
        #expect(model.canSave == false)
    }

    /// A photo entry is the one input with no words behind it, so the label has to stand in —
    /// an empty box would make the commonest correction ("that was a large portion") impossible.
    @Test("falls back to the label when the entry has no words")
    func seedsFromLabelForPhotoEntries() {
        let entry = Entry(
            kind: .food, label: "Chicken bowl, avocado", calories: 640,
            day: Self.pastDay, source: .llmPhoto, rawInput: nil
        )
        let model = EntryEditorModel(
            entry: entry, stores: .inMemory(), parser: StubNutritionParser()
        )

        #expect(model.text == "Chicken bowl, avocado")
    }

    @Test("replaces the entry in place, keeping its id, day and time")
    func savesInPlace() async throws {
        let entry = Self.logged()
        let stores = StoreBundle.inMemory(entries: [entry])
        let model = EntryEditorModel(entry: entry, stores: stores, parser: StubNutritionParser())

        model.text = "three eggs and two slices of toast"
        #expect(model.canSave)
        #expect(await model.save())

        let onDay = try stores.entries.entries(on: Self.pastDay)
        #expect(onDay.count == 1)
        let updated = try #require(onDay.first)
        #expect(updated.id == entry.id)
        #expect(updated.day == entry.day)
        #expect(updated.loggedAt == entry.loggedAt)
        #expect(updated.rawInput == "three eggs and two slices of toast")
        // Re-parsed by hand from text, whatever the entry started life as.
        #expect(updated.source == .llmText)
        // And it didn't land on today as a second meal.
        #expect(try stores.entries.entries(on: Day.today()).isEmpty)
    }

    /// "Eggs" corrected to "eggs and a run" is two things. The first keeps the row's identity;
    /// the rest join it on the same day rather than being dropped on the floor.
    @Test("a description covering two things saves both onto the original day")
    func savesExtraItemsAlongside() async throws {
        let entry = Self.logged()
        let stores = StoreBundle.inMemory(entries: [entry])
        let parser = StubNutritionParser(result: ParseResult(items: [
            ParsedItem(kind: .food, label: "Scrambled eggs", calories: 220),
            ParsedItem(kind: .exercise, label: "Morning run", calories: 300,
                       exerciseKind: .cardio, durationMinutes: 30),
        ]))
        let model = EntryEditorModel(entry: entry, stores: stores, parser: parser)

        model.text = "two eggs and a half hour run"
        #expect(await model.save())

        let onDay = try stores.entries.entries(on: Self.pastDay)
        #expect(onDay.count == 2)
        #expect(onDay.contains { $0.id == entry.id })
        #expect(onDay.allSatisfy { $0.day == Self.pastDay })
    }

    /// The whole point of splitting a send across entries: correcting the toast opens on the
    /// toast, re-parses the toast, and leaves the eggs and the coffee untouched. Seeded with all
    /// three, the same edit would re-log the two that were already right.
    @Test("correcting one entry of a multi-item log leaves its siblings alone")
    func correctsOneOfSeveral() async throws {
        let eggs = Self.logged(rawInput: "two eggs", label: "Scrambled eggs")
        let toast = Self.logged(rawInput: "toast", label: "Sourdough toast")
        let coffee = Self.logged(rawInput: "a black coffee", label: "Black coffee")
        let stores = StoreBundle.inMemory(entries: [eggs, toast, coffee])
        let parser = StubNutritionParser(result: ParseResult(items: [
            ParsedItem(kind: .food, label: "Sourdough toast with butter",
                       sourceText: "two slices of toast with butter", calories: 260),
        ]))
        let model = EntryEditorModel(entry: toast, stores: stores, parser: parser)

        // The box opens on this entry's words alone, not on the whole breakfast.
        #expect(model.text == "toast")

        model.text = "two slices of toast with butter"
        #expect(await model.save())

        let onDay = try stores.entries.entries(on: Self.pastDay)
        #expect(onDay.count == 3)
        #expect(onDay.first { $0.id == eggs.id }?.label == "Scrambled eggs")
        #expect(onDay.first { $0.id == coffee.id }?.label == "Black coffee")

        let corrected = try #require(onDay.first { $0.id == toast.id })
        #expect(corrected.label == "Sourdough toast with butter")
        #expect(corrected.rawInput == "two slices of toast with butter")
    }

    @Test("a parser failure leaves the entry exactly as it was")
    func failedSaveChangesNothing() async throws {
        let entry = Self.logged()
        let stores = StoreBundle.inMemory(entries: [entry])
        let parser = StubNutritionParser(error: NutritionParserError.overloaded)
        let model = EntryEditorModel(entry: entry, stores: stores, parser: parser)

        model.text = "something else entirely"
        #expect(await model.save() == false)

        #expect(model.errorMessage == NutritionParserError.overloaded.userMessage)
        #expect(model.canRetry)
        #expect(try stores.entries.entries(on: Self.pastDay) == [entry])
    }

    @Test("deleting removes the entry from its day")
    func deletes() throws {
        let entry = Self.logged()
        let stores = StoreBundle.inMemory(entries: [entry])
        let model = EntryEditorModel(entry: entry, stores: stores, parser: StubNutritionParser())

        #expect(model.delete())
        #expect(try stores.entries.entries(on: Self.pastDay).isEmpty)
    }
}
