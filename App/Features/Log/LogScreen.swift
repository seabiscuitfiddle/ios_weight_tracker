import PhotosUI
import SwiftUI
import TallyCore
import UIKit

/// The AI quick-log. Design screen 1f.
///
/// The screen is the text field. It opens focused and the writing area takes whatever room is
/// going, because there is exactly one thing to do here and making someone tap a thin bar at the
/// bottom of an otherwise empty screen to start doing it is a tax on every single log.
///
/// Photo and voice are modifiers on that one field rather than separate modes: a photo attaches to
/// whatever has been typed, and speech fills the field in as it's heard, so both end up in the same
/// place — a draft that can be read and fixed before it's sent.
///
/// Entries save the moment the parse returns and appear as cards below, so the interaction is
/// "say it and it's logged", not "say it, review a modal, confirm". Corrections happen by editing
/// the card afterwards — which is cheap — rather than by making every single log pay for a
/// confirmation step it usually doesn't need.
struct LogScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: LogModel?
    @State private var transcriber = SpeechTranscriber()
    @State private var draft = ""
    /// Whether the current draft originated from speech. Set when a transcript populates the
    /// field and cleared on send, so entries record how they were actually captured.
    @State private var draftCameFromVoice = false
    /// The photo attached to the draft, if any. Nil is the overwhelmingly common case, which is
    /// why the thumbnail row only exists when it isn't.
    @State private var photo: CapturedPhoto?
    @State private var isChoosingPhotoSource = false
    @State private var isShowingCamera = false
    @State private var isShowingLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var photoError: String?
    /// The just-added card being corrected, if any.
    @State private var editing: Entry?
    @FocusState private var isComposeFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            composer
            results
        }
        .background(Color.tallyBackground)
        .task {
            if model == nil {
                model = LogModel(stores: environment.stores, parser: environment.parser)
            }
            model?.load()

            // A widget button or a Siri phrase asks for a mode *before* this screen exists —
            // switching to the Log tab is what brings it on screen — so `onChange` below never
            // sees that value and the arriving case has to be handled here as well. Missing it
            // is what made the widget's "Text" button land on an unfocused field, and left the
            // mode set, which then kept the keyboard shut on every later visit too.
            if let mode = environment.takePendingLogMode() {
                await openCompose(mode)
            } else {
                await focusCompose()
            }
        }
        .onChange(of: environment.pendingLogMode) { _, mode in
            // Arrived from a widget button or from Siri with the screen already up.
            guard mode != nil else { return }
            Task {
                if let mode = environment.takePendingLogMode() { await openCompose(mode) }
            }
        }
        // Mirror the live transcript into the field so the user can see what was heard and fix
        // it before sending — on-device recognition is less accurate, and an editable draft is
        // what makes that acceptable.
        .onChange(of: transcriber.transcript) { _, text in
            if transcriber.isRecording, !text.isEmpty {
                draft = text
                draftCameFromVoice = true
            }
        }
        .onChange(of: libraryItem) { _, item in
            guard let item else { return }
            Task { await attachFromLibrary(item) }
        }
        .onDisappear { transcriber.stop() }
        .confirmationDialog("Add a photo", isPresented: $isChoosingPhotoSource,
                            titleVisibility: .visible) {
            if CameraPicker.isAvailable {
                Button("Take Photo") { isShowingCamera = true }
            }
            Button("Choose from Library") { isShowingLibrary = true }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $isShowingCamera) {
            CameraPicker { image in
                isShowingCamera = false
                if let image { attach(image) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $isShowingLibrary, selection: $libraryItem, matching: .images)
        .sheet(item: $editing, onDismiss: { model?.refreshJustAdded() }) { entry in
            EntryEditorSheet(entry: entry)
        }
    }

    // MARK: Compose

    /// The writing area, taking every point the results list isn't using.
    @ViewBuilder private var composer: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                // Sits *behind* the field so the whole writing area is a target, without
                // intercepting the taps that belong to the text itself — placing the caret and
                // selecting a word have to keep working. A large blank region that ignores a
                // tap is the odd hit box this replaces.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { isComposeFocused = true }

                TextField("Describe what you ate…", text: $draft, axis: .vertical)
                    .font(.tallyBody)
                    .focused($isComposeFocused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.top, Metrics.space4)
                    .accessibilityIdentifier("log.composeField")
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.space8 * 3, maxHeight: .infinity)

            if let photo {
                attachedPhoto(photo)
            }

            if let photoError {
                Text(photoError)
                    .font(.tallyScaled(12, weight: .regular, relativeTo: .caption))
                    .foregroundStyle(Color.tallyAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
            }

            if let message = transcriber.errorMessage {
                Text(message)
                    .font(.tallyScaled(12, weight: .regular, relativeTo: .caption))
                    .foregroundStyle(Color.tallyAccent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.gutter)
            }

            actionRow
        }
    }

    /// Photo · Voice on the left, send on the right. One row, all of it 44pt tall.
    @ViewBuilder private var actionRow: some View {
        HStack(spacing: Metrics.space2) {
            modifierButton(
                title: photo == nil ? "Photo" : "Replace",
                systemImage: "camera",
                isActive: photo != nil,
                identifier: "log.photoButton"
            ) {
                isComposeFocused = false
                isChoosingPhotoSource = true
            }

            if transcriber.isAvailable {
                modifierButton(
                    title: transcriber.isRecording ? "Listening…" : "Voice",
                    systemImage: transcriber.isRecording ? "waveform" : "mic",
                    isActive: transcriber.isRecording,
                    identifier: "log.voiceButton"
                ) {
                    Task {
                        if transcriber.isRecording {
                            transcriber.stop()
                        } else {
                            await startVoice()
                        }
                    }
                }
            }

            Spacer(minLength: Metrics.space2)

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.tallyInverted)
                    .frame(width: Metrics.tapTarget + Metrics.space3,
                           height: Metrics.tapTarget)
                    .background(canSend ? Color.tallyAccent : Color.tallyDivider)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
            // Identifier as well as a label, because `.submitLabel(.send)` above gives the
            // keyboard's return key the label "Send" too — so a label-based query matches two
            // elements once the keyboard is up. Labels are for users; tests key off this, which
            // also means rewording the label can't break them.
            .accessibilityIdentifier("log.sendButton")
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.vertical, Metrics.space3)
    }

    /// A tile that changes what the draft is, rather than sending it.
    @ViewBuilder
    private func modifierButton(
        title: String,
        systemImage: String,
        isActive: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.tallyScaled(12, weight: .semibold, relativeTo: .caption))
                .foregroundStyle(isActive ? Color.tallyInverted : Color.tallyText)
                .padding(.horizontal, Metrics.space3)
                .frame(height: Metrics.tapTarget)
                .background(isActive ? Color.tallyAccent : Color.tallySurface)
                .tallyHairlineBorder()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder private func attachedPhoto(_ photo: CapturedPhoto) -> some View {
        HStack(spacing: Metrics.space3) {
            Image(uiImage: photo.image)
                .resizable()
                .scaledToFill()
                .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                .clipped()
                .tallyHairlineBorder()

            Text("Photo attached. Add a note if the picture doesn't tell the whole story.")
                .font(.tallyScaled(12, weight: .regular, relativeTo: .caption))
                .foregroundStyle(Color.tallySecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: Metrics.space2)

            Button { self.photo = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.tallyText)
                    .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove photo")
        }
        .padding(.horizontal, Metrics.gutter)
        .padding(.top, Metrics.space2)
    }

    // MARK: Results

    /// Everything the last send produced. Absent entirely until there is something to say, so an
    /// untouched screen is all writing area.
    @ViewBuilder private var results: some View {
        if let model, hasResults(model) {
            VStack(spacing: 0) {
                TallyRule(weight: Metrics.rule)

                ScrollView {
                    VStack(alignment: .leading, spacing: Metrics.space3) {
                        if !model.justAdded.isEmpty {
                            Kicker("just added")
                            ForEach(model.justAdded) { entry in
                                SavedEntryCard(
                                    entry: entry,
                                    edit: { editing = entry },
                                    delete: { model.delete(entry) }
                                )
                            }
                        }

                        if model.isParsing {
                            HStack(spacing: Metrics.space2) {
                                ProgressView()
                                Text("Working it out…")
                                    .font(.tallyBody)
                                    .foregroundStyle(Color.tallySecondaryText)
                            }
                            .padding(.vertical, Metrics.space2)
                        }

                        if let message = model.errorMessage {
                            ParseErrorBanner(
                                message: message,
                                canRetry: model.canRetry,
                                retry: { Task { await model.retry() } },
                                openSettings: { environment.isShowingSettings = true },
                                needsKey: model.needsAPIKey
                            )
                        }
                    }
                    .padding(.horizontal, Metrics.gutter)
                    .padding(.vertical, Metrics.space4)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func hasResults(_ model: LogModel) -> Bool {
        !model.justAdded.isEmpty || model.isParsing || model.errorMessage != nil
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

    // MARK: Actions

    /// Opens whichever way of composing was asked for.
    ///
    /// Text goes through `focusCompose` rather than setting focus directly, because a mode that
    /// arrived from a widget is applied as the screen is being installed — exactly the case the
    /// wait in there exists for.
    private func openCompose(_ mode: DeepLink.LogMode) async {
        switch mode {
        case .text:
            await focusCompose()
        case .photo:
            isComposeFocused = false
            isChoosingPhotoSource = true
        case .voice:
            await startVoice()
        }
    }

    /// Opens the keyboard on arrival.
    ///
    /// The brief wait isn't superstition: setting `@FocusState` in the same turn the field is
    /// installed is dropped often enough to show up as "the keyboard doesn't come up the first
    /// time", which is precisely the tap this redesign is meant to remove.
    private func focusCompose() async {
        try? await Task.sleep(for: .milliseconds(50))
        // Don't fight a deep link that asked for voice or the camera instead — one that lands
        // during the wait above is still to be applied, and applying it wins over the keyboard.
        guard environment.pendingLogMode == nil, !transcriber.isRecording,
              !isChoosingPhotoSource, !isShowingCamera, !isShowingLibrary
        else { return }
        isComposeFocused = true
    }

    /// Starts listening, and falls back to the keyboard if it can't.
    ///
    /// No `isAvailable` guard, deliberately. The widget's Voice button is a deep link into here,
    /// and a silent return left the user looking at an empty screen that had visibly opened for
    /// them and then done nothing — indistinguishable from a crash, and reported as one.
    /// `transcriber.start()` says why instead, and the keyboard is the fallback that still lets
    /// the log they came to make happen.
    private func startVoice() async {
        draft = ""
        draftCameFromVoice = false
        await transcriber.start()
        if !transcriber.isRecording { await focusCompose() }
    }

    private func attach(_ image: UIImage) {
        guard let captured = CapturedPhoto(image) else {
            photoError = "That image couldn't be read. Try another one."
            return
        }
        photoError = nil
        photo = captured
        isComposeFocused = true
    }

    private func attachFromLibrary(_ item: PhotosPickerItem) async {
        defer { libraryItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else {
            photoError = "That image couldn't be read. Try another one."
            return
        }
        attach(image)
    }

    private var canSend: Bool {
        guard model?.isParsing != true else { return false }
        return photo != nil || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend, let model else { return }
        let text = draft
        let spoken = draftCameFromVoice
        let attached = photo

        draft = ""
        draftCameFromVoice = false
        photo = nil
        photoError = nil
        transcriber.stop()

        Task {
            if let attached {
                // Whatever was typed rides along as the note — "half of this", "no dressing" —
                // so a photo and a correction are one send rather than two entries.
                let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
                await model.log(image: attached.jpeg, mediaType: .jpeg,
                                note: note.isEmpty ? nil : note)
            } else {
                await model.log(text: text, spoken: spoken)
            }
        }
    }
}

/// One optimistically-saved entry: the words that made it, the numbers that came back, and the
/// two things worth doing about it.
struct SavedEntryCard: View {
    let entry: Entry
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Metrics.space2 + 2) {
                VStack(alignment: .leading, spacing: 2) {
                    // The user's own words for this one item, quoted back. Showing what was heard
                    // is what makes an estimate judgeable — a number alone can't be checked.
                    if let quoted = quotedInput {
                        Text("“\(quoted)”")
                            .font(.tallyScaled(14, weight: .regular))
                            .foregroundStyle(Color.tallyText)
                        Text(entry.label)
                            .font(.tallyEntryDetail)
                            .foregroundStyle(Color.tallySecondaryText)
                    } else {
                        Text(entry.label)
                            .font(.tallyScaled(14, weight: .regular))
                            .foregroundStyle(Color.tallyText)
                    }
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

                Button(action: edit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.tallyText)
                        .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit entry")

                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.tallyText)
                        .frame(width: Metrics.tapTarget, height: Metrics.tapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete entry")
            }
        }
        .background(Color.tallySurface)
        .tallyHairlineBorder()
    }

    /// The words behind this entry, when they say something its label doesn't.
    ///
    /// Each card now carries only the fragment it came from, so "a black coffee" sits above
    /// "Black coffee" often enough to matter — two lines saying one thing read as a rendering
    /// mistake. Nothing is lost by dropping the quote in that case; the label is the same words.
    private var quotedInput: String? {
        guard let raw = entry.rawInput?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.caseInsensitiveCompare(entry.label) != .orderedSame
        else { return nil }
        return raw
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
