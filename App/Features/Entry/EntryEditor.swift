import Observation
import SwiftUI
import TallyCore

/// Correcting a logged entry by re-describing it.
///
/// The correction is text, not a form of number fields, because the mistake being fixed is almost
/// never arithmetic — it's "that was a large bowl, not a small one", or "I forgot the olive oil".
/// Handing back the words that produced the entry and letting them be rewritten keeps the estimate
/// and the description in step; typing 640 over 480 leaves a label that no longer describes the
/// number beside it.
///
/// Text only, deliberately. Voice already becomes text on the device before anything is parsed, so
/// a spoken entry arrives here as editable words with nothing lost. A photo is the one input with
/// no text behind it — those seed the box with the label the parser produced, which is a starting
/// point to edit rather than a blank field.
@Observable
@MainActor
final class EntryEditorModel {
    let original: Entry
    var text: String

    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private(set) var canRetry = false
    private(set) var needsAPIKey = false

    private let stores: StoreBundle
    private let parser: any NutritionParser

    init(entry: Entry, stores: StoreBundle, parser: any NutritionParser) {
        self.original = entry
        self.stores = stores
        self.parser = parser
        self.text = Self.startingText(for: entry)
    }

    /// The user's own words when there were any — this entry's share of them, not the whole
    /// send, so clarifying the toast doesn't mean reading past the eggs and the coffee to find
    /// it. A photo entry only carries whatever note was typed alongside it, so the parser's
    /// label stands in.
    private static func startingText(for entry: Entry) -> String {
        let raw = entry.rawInput?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? entry.label : raw
    }

    var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text != Self.startingText(for: original)
            && !isSaving
    }

    /// Re-parses the description and replaces the entry with what comes back.
    ///
    /// - Returns: true when the entry was replaced, so the caller can close the sheet. False
    ///   leaves the sheet open with ``errorMessage`` explaining why.
    func save() async -> Bool {
        let described = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !described.isEmpty else { return false }

        isSaving = true
        errorMessage = nil
        canRetry = false
        needsAPIKey = false
        defer { isSaving = false }

        // Weighted against the body weight of the day being edited, not today's — an exercise
        // estimate for six weeks ago should use the weight that applied then.
        let context = ParseContext(
            bodyWeightPounds: try? stores.weights.latestSample(onOrBefore: original.day)?.pounds
        )

        do {
            let result = try await parser.parse(.text(described), context: context)
            guard !result.items.isEmpty else {
                errorMessage = NutritionParserError.nothingRecognized(nil).userMessage
                return false
            }

            // The entry keeps its id, its day and its timestamp: this is a correction to an
            // existing record, and letting it jump to today or to the bottom of the list would
            // make fixing a typo look like logging a second meal.
            //
            // A rewrite that turns out to be two things splits the same way a fresh log does,
            // each replacement keeping the words it came from rather than all of them.
            var replacements = result.items.map {
                $0.entry(
                    on: original.day,
                    loggedAt: original.loggedAt,
                    source: .llmText,
                    rawInput: described
                )
            }
            replacements[0].id = original.id

            try stores.entries.save(replacements)
            return true
        } catch let error as NutritionParserError {
            errorMessage = error.userMessage
            canRetry = error.isRetryable
            needsAPIKey = error == .missingAPIKey || error == .invalidAPIKey
            return false
        } catch {
            errorMessage = String(describing: error)
            canRetry = true
            return false
        }
    }

    /// - Returns: true when the entry is gone, so the caller can close the sheet.
    func delete() -> Bool {
        do {
            try stores.entries.delete(id: original.id)
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }
}

/// The sheet behind a tap on any logged entry: rewrite it, or delete it.
struct EntryEditorSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    let entry: Entry

    @State private var model: EntryEditorModel?
    @State private var isConfirmingDelete = false
    @FocusState private var isDescriptionFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            if let model {
                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.space4) {
                        current
                        rewriteField(model)

                        if let message = model.errorMessage {
                            ParseErrorBanner(
                                message: message,
                                canRetry: model.canRetry,
                                retry: { Task { await save(model) } },
                                openSettings: {
                                    dismiss()
                                    environment.isShowingSettings = true
                                },
                                needsKey: model.needsAPIKey
                            )
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.space4)
                }

                actions(model)
            } else {
                Spacer()
            }
        }
        .background(Color.tallyBackground)
        .task {
            if model == nil {
                model = EntryEditorModel(
                    entry: entry,
                    stores: environment.stores,
                    parser: environment.parser
                )
            }
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if model?.delete() == true { dismiss() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 1) {
                    Kicker(TallyFormat.dayKicker(entry.day), color: .tallyAccent)
                    Text("Edit entry")
                        .font(.tallyScreenTitle)
                        .foregroundStyle(Color.tallyText)
                }

                Spacer(minLength: Metrics.space2)

                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.tallyText)
                        .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                // Pulls the oversized hit area back so the glyph sits on the gutter.
                .padding(.trailing, -Metrics.space3)
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.space4)
            .padding(.bottom, Metrics.space3)

            TallyRule(weight: Metrics.rule)
        }
    }

    /// What the entry says right now, so a rewrite can be judged against it.
    @ViewBuilder private var current: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Kicker("logged as")
            HStack(alignment: .firstTextBaseline, spacing: Metrics.space3) {
                Text(entry.label)
                    .font(.tallyEntryTitle)
                    .foregroundStyle(Color.tallyText)
                Spacer(minLength: Metrics.space2)
                Text(TallyFormat.signedCalories(entry.calories, kind: entry.kind))
                    .font(.tallyFixed(18, weight: .heavy))
                    .foregroundStyle(entry.kind == .exercise ? Color.tallyAccent : Color.tallyText)
            }
            Text(TallyFormat.entryDetail(entry))
                .font(.tallyEntryDetail)
                .foregroundStyle(Color.tallySecondaryText)
        }
        .padding(Metrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.tallySurface)
        .tallyHairlineBorder()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func rewriteField(_ model: EntryEditorModel) -> some View {
        @Bindable var model = model

        VStack(alignment: .leading, spacing: Metrics.space2) {
            Kicker("describe it again")

            // Three lines minimum, so the box is the field and a tap anywhere in it lands on
            // the text rather than on decoration around it.
            TextField("Describe what you ate…", text: $model.text, axis: .vertical)
                .font(.tallyBody)
                .lineLimit(3...8)
                .focused($isDescriptionFocused)
                .padding(Metrics.space3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color.tallySurface)
                .tallyHairlineBorder()
                .accessibilityIdentifier("editor.descriptionField")

            Text("Tally will work the numbers out again from this.")
                .font(.tallyScaled(12, weight: .regular, relativeTo: .caption))
                .foregroundStyle(Color.tallySecondaryText)
        }
    }

    @ViewBuilder private func actions(_ model: EntryEditorModel) -> some View {
        VStack(spacing: 0) {
            TallyRule(weight: Metrics.rule)

            VStack(spacing: Metrics.space3) {
                if model.isSaving {
                    HStack(spacing: Metrics.space2) {
                        ProgressView()
                        Text("Working it out…")
                            .font(.tallyBody)
                            .foregroundStyle(Color.tallySecondaryText)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Metrics.space1)
                } else {
                    TallyPrimaryButton(
                        title: "Save changes",
                        action: { Task { await save(model) } },
                        isEnabled: model.canSave
                    )
                    .accessibilityIdentifier("editor.saveButton")
                }

                Button(role: .destructive) {
                    isConfirmingDelete = true
                } label: {
                    Text("Delete entry")
                        .font(.tallyScaled(13, weight: .semibold))
                        .foregroundStyle(Color.tallyAccent)
                        .frame(maxWidth: .infinity, minHeight: Metrics.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("editor.deleteButton")
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.space4)
            .padding(.bottom, Metrics.space2)
        }
        .background(Color.tallyBackground)
    }

    private func save(_ model: EntryEditorModel) async {
        if await model.save() { dismiss() }
    }
}
