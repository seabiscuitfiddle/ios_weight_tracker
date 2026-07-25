import SwiftUI
import TallyCore

/// The AI quick-log. Design screen 1f.
///
/// Entries save the moment the parse returns and appear as editable cards, so the interaction is
/// "say it and it's logged", not "say it, review a modal, confirm". Corrections happen by editing
/// the card afterwards — which is cheap — rather than by making every single log pay for a
/// confirmation step it usually doesn't need.
struct LogScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: LogModel?
    @State private var draft = ""
    @FocusState private var isComposeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            recentlyAdded
            composeBar
        }
        .background(Color.tallyBackground)
        .task {
            if model == nil {
                model = LogModel(stores: environment.stores, parser: environment.parser)
            }
            model?.load()
        }
        .onChange(of: environment.pendingLogMode) { _, mode in
            // Arrived from a widget button or Siri. Voice and photo capture are wired in a later
            // phase; text focus works now, and an unimplemented mode falls back to it rather
            // than doing nothing visible.
            guard mode != nil else { return }
            isComposeFocused = true
            environment.pendingLogMode = nil
        }
    }

    @ViewBuilder private var header: some View {
        ScreenHeader(kicker: "quick log", title: "Log") {
            if let goal = model?.goal {
                VStack(alignment: .trailing, spacing: 0) {
                    Kicker("net left")
                    Text(TallyFormat.calories(model?.remaining ?? goal.calories))
                        .font(.tallyDisplay(20))
                        .foregroundStyle(Color.tallyText)
                }
            }
        }
    }

    @ViewBuilder private var recentlyAdded: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.space3) {
                if let model, !model.justAdded.isEmpty {
                    Kicker("just added")
                    ForEach(model.justAdded) { entry in
                        SavedEntryCard(entry: entry) { model.delete(entry) }
                    }
                } else if model?.isParsing != true {
                    EmptyStateView(
                        message: "Describe what you ate or did and Tally will work out the numbers."
                    )
                }

                if model?.isParsing == true {
                    HStack(spacing: Metrics.space2) {
                        ProgressView()
                        Text("Working it out…")
                            .font(.tallyBody)
                            .foregroundStyle(Color.tallySecondaryText)
                    }
                    .padding(.vertical, Metrics.space3)
                }

                if let message = model?.errorMessage {
                    ParseErrorBanner(
                        message: message,
                        canRetry: model?.canRetry == true,
                        retry: { Task { await model?.retry() } },
                        openSettings: { environment.isShowingSettings = true },
                        needsKey: model?.needsAPIKey == true
                    )
                }
            }
            .padding(.horizontal, Metrics.gutter)
            .padding(.top, Metrics.space4)
        }
    }

    @ViewBuilder private var composeBar: some View {
        VStack(spacing: 0) {
            TallyRule(weight: Metrics.rule)

            HStack(alignment: .bottom, spacing: 9) {
                TextField("Describe food or exercise…", text: $draft, axis: .vertical)
                    .font(.tallyBody)
                    .lineLimit(1...4)
                    .padding(.horizontal, Metrics.space3)
                    .padding(.vertical, 11)
                    .background(Color.tallySurface)
                    .tallyHairlineBorder()
                    .focused($isComposeFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .accessibilityIdentifier("log.composeField")

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.tallyInverted)
                        .frame(width: 46, height: 46)
                        .background(canSend ? Color.tallyAccent : Color.tallyDivider)
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Send")
                // Identifier as well as a label, because `.submitLabel(.send)` above gives the
                // keyboard's return key the label "Send" too — so a label-based query matches
                // two elements once the keyboard is up. Labels are for users; tests key off
                // this, which also means rewording the label can't break them.
                .accessibilityIdentifier("log.sendButton")
            }
            .padding(.horizontal, Metrics.space4)
            .padding(.vertical, Metrics.space2 + 2)
        }
        .background(Color.tallyBackground)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model?.isParsing != true
    }

    private func send() {
        guard canSend, let model else { return }
        let text = draft
        draft = ""
        Task { await model.log(text: text) }
    }
}

/// One optimistically-saved entry, with its macros in an editable grid.
struct SavedEntryCard: View {
    let entry: Entry
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Metrics.space2 + 2) {
                VStack(alignment: .leading, spacing: 2) {
                    // The user's own words, quoted back. Showing what was heard is what makes an
                    // estimate judgeable — a number alone can't be checked.
                    if let raw = entry.rawInput {
                        Text("“\(raw)”")
                            .font(.tallyScaled(14, weight: .regular))
                            .foregroundStyle(Color.tallyText)
                    }
                    Text(entry.label)
                        .font(.tallyEntryDetail)
                        .foregroundStyle(Color.tallySecondaryText)
                }

                Spacer(minLength: Metrics.space2)

                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                    Kicker("saved", color: .tallyAccent)
                }
                .foregroundStyle(Color.tallyAccent)
            }
            .padding(.horizontal, 14)
            .padding(.top, Metrics.space3)
            .padding(.bottom, Metrics.space2 + 2)

            TallyRule()

            HStack(spacing: 0) {
                cell("cal", TallyFormat.signedCalories(entry.calories, kind: entry.kind),
                     color: entry.kind == .exercise ? .tallyAccent : .tallyText)
                if entry.kind == .food {
                    cell("protein", "\(TallyFormat.grams(entry.proteinGrams))g")
                    cell("fiber", "\(TallyFormat.grams(entry.fiberGrams))g")
                } else {
                    cell("type", entry.exerciseKind?.displayName ?? "Other")
                }

                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.tallyText)
                        .frame(width: 46, height: 46)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete entry")
            }
        }
        .background(Color.tallySurface)
        .tallyHairlineBorder()
    }

    @ViewBuilder
    private func cell(_ label: String, _ value: String, color: Color = .tallyText) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Kicker(label)
            Text(value)
                .font(.tallyFixed(18, weight: .heavy))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Metrics.space3)
        .padding(.vertical, 9)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.tallyDivider).frame(width: Metrics.hairline)
        }
    }
}

/// Explains a parse failure and offers the one action that would help.
struct ParseErrorBanner: View {
    let message: String
    let canRetry: Bool
    let retry: () -> Void
    let openSettings: () -> Void
    let needsKey: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.space2) {
            Text(message)
                .font(.tallyBody)
                .foregroundStyle(Color.tallyText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Metrics.space4) {
                if needsKey {
                    Button("Open Settings", action: openSettings)
                        .font(.tallyScaled(13, weight: .semibold))
                        .foregroundStyle(Color.tallyAccent)
                } else if canRetry {
                    Button("Try again", action: retry)
                        .font(.tallyScaled(13, weight: .semibold))
                        .foregroundStyle(Color.tallyAccent)
                }
            }
        }
        .padding(Metrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyHairlineBorder()
    }
}
