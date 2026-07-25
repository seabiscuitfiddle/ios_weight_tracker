import LLMWire
import SwiftUI
import TallyCore

/// Profile, goal, units, and the AI provider.
///
/// The design doesn't draw this screen, but it needs to exist: the goal engine needs a height and
/// age, and AI logging needs a key. Uses a plain `Form` rather than the design's custom
/// components — a settings screen is a system-idiom surface, and reimplementing pickers in a
/// bespoke visual language would cost usability for no benefit.
struct SettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var profile = UserProfile.default
    @State private var goal = GoalSettings.default
    @State private var ai = AISettings.default
    /// The key for whichever provider is selected. Which one that is has to be tracked
    /// separately, so switching provider mid-edit writes the typed key to the right item.
    @State private var apiKey = ""
    @State private var keyProviderID = AISettings.default.providerID
    @State private var customName = "Custom"
    @State private var customBaseURL = ""
    @State private var customJSONStyle = StructuredOutputStyle.prompt
    /// Filled by asking the provider what the key can reach. Empty until then, because a shipped
    /// list of model identifiers is wrong within months.
    @State private var fetchedModels: [String] = []
    @State private var isRefreshingModels = false
    @State private var modelRefreshMessage: String?
    @State private var heightText = ""
    @State private var targetWeightText = ""
    @State private var saveError: String?
    @State private var isImportingHealth = false
    @State private var healthImportMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                aiSection
                healthSection
                profileSection
                goalSection
                aboutSection
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        save()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: load)
            .onChange(of: profile.heightUnit) { previous, _ in
                // The centimetre row edits a text buffer that is only committed on save. Commit
                // it before it disappears, and refill it when it comes back, so toggling units
                // never drops what was typed.
                if previous == .centimeters {
                    profile.heightCentimeters = Self.number(from: heightText)
                } else {
                    heightText = Self.heightText(from: profile.heightCentimeters)
                }
            }
            .alert("Couldn't save", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    // MARK: Sections

    /// Provider, model, and the key for whichever provider is chosen.
    ///
    /// One section rather than a sub-screen, because the three settings are meaningless apart:
    /// a model identifier only means something at a provider, and a key only works at the one it
    /// was minted for.
    @ViewBuilder private var aiSection: some View {
        onDeviceSection

        if !usesOnDevice {
            Section {
                Picker("Provider", selection: providerSelection) {
                    ForEach(LLMProvider.builtIn) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                    Text("Custom (OpenAI-compatible)").tag(Self.customProviderID)
                }

                if isCustomProvider {
                    customProviderRows
                }

                modelRow

                SecureField(ai.provider.keyPlaceholder, text: $apiKey)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                if let consoleURL = ai.provider.consoleURL {
                    Link("Get a key from \(ai.provider.displayName)", destination: consoleURL)
                        .font(.footnote)
                }
            } header: {
                Text("AI logging")
            } footer: {
                // States plainly where the key goes and where it's sent. A credential the user
                // supplies deserves an explicit answer to "what happens to this?", in the place
                // they hand it over — and now that the destination is their choice, it has to be
                // read from that choice rather than written into the sentence.
                Text("""
                    Stored in your device's keychain and sent only to \(ai.provider.host). \
                    You're billed by \(ai.provider.displayName) directly. Each provider keeps \
                    its own key, so switching back doesn't mean entering it again. Tally works \
                    without a key — you can always add entries by hand.
                    """)
            }
        }
    }

    /// Offered only when it would actually work. A toggle that can be switched on and then fails
    /// every request is worse than one that isn't there.
    @ViewBuilder private var onDeviceSection: some View {
        if OnDeviceModel.isAvailable {
            Section {
                Toggle("Use the on-device model", isOn: $ai.prefersOnDevice)
            } header: {
                Text("On device")
            } footer: {
                Text("""
                    Free, private, and works offline — nothing leaves your phone and there's no \
                    key to enter. It's a much smaller model than the hosted ones, so portion \
                    estimates are rougher, and it can't read photos of meals.
                    """)
            }
        }
    }

    /// A text field rather than a picker, with suggestions alongside.
    ///
    /// Providers add and retire model identifiers constantly, so any fixed list is wrong within
    /// months and a picker would make the right answer unreachable. The suggestions are a
    /// convenience; asking the provider what the key can actually reach is the reliable route.
    @ViewBuilder private var modelRow: some View {
        HStack {
            Text("Model")
            Spacer()
            TextField(ai.provider.defaultModel, text: $ai.model)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }

        Menu {
            ForEach(modelSuggestions, id: \.self) { name in
                Button(name) { ai.model = name }
            }
        } label: {
            HStack {
                Text(fetchedModels.isEmpty ? "Suggested models" : "Models on your account")
                Spacer()
                if isRefreshingModels { ProgressView() }
            }
        }
        .disabled(modelSuggestions.isEmpty)

        Button("Fetch models from \(ai.provider.displayName)") {
            Task { await refreshModels() }
        }
        .disabled(isRefreshingModels || ai.provider.modelsEndpoint == nil)

        if let modelRefreshMessage {
            Text(modelRefreshMessage)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// Enough to reach a self-hosted endpoint, a gateway, or Ollama on the local network.
    @ViewBuilder private var customProviderRows: some View {
        HStack {
            Text("Name")
            Spacer()
            TextField("Custom", text: $customName)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }

        HStack {
            Text("Base URL")
            Spacer()
            TextField("http://localhost:11434/v1", text: $customBaseURL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }

        // The pessimistic default works everywhere; guessing strict support fails with an opaque
        // 400 on endpoints that never implemented it.
        Picker("JSON support", selection: $customJSONStyle) {
            Text("None").tag(StructuredOutputStyle.prompt)
            Text("JSON mode").tag(StructuredOutputStyle.jsonObject)
            Text("Strict schema").tag(StructuredOutputStyle.jsonSchema)
        }
    }

    @ViewBuilder private var healthSection: some View {
        // Hidden entirely where Health doesn't exist, such as on iPad, rather than offered and
        // then failing.
        if HealthKitImporter.isAvailable {
            Section {
                Button {
                    Task {
                        isImportingHealth = true
                        healthImportMessage = await environment.importFromHealth()
                        isImportingHealth = false
                    }
                } label: {
                    HStack {
                        Text("Import from Health")
                        Spacer()
                        if isImportingHealth { ProgressView() }
                    }
                }
                .disabled(isImportingHealth)

                if let healthImportMessage {
                    Text(healthImportMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Apple Health")
            } footer: {
                Text("""
                    Brings across your weight and workouts from the last 90 days. Tally reads \
                    from Health and never writes to it, and a weight you entered by hand is \
                    never replaced. Only the active calories of a workout are counted — total \
                    would double-count energy already in your daily estimate.
                    """)
            }
        }
    }

    @ViewBuilder private var profileSection: some View {
        Section {
            Picker("Sex", selection: $profile.biologicalSex) {
                ForEach(UserProfile.BiologicalSex.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }

            DatePicker(
                "Date of birth",
                selection: Binding(
                    get: { profile.birthDate ?? Self.defaultBirthDate },
                    set: { profile.birthDate = $0 }
                ),
                displayedComponents: .date
            )

            heightRow

            Picker("Height units", selection: $profile.heightUnit) {
                ForEach(HeightUnit.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }

            Picker("Weight units", selection: $profile.massUnit) {
                ForEach(MassUnit.allCases, id: \.self) {
                    Text($0.shortName).tag($0)
                }
            }

            Picker("Daily activity", selection: $profile.activityLevel) {
                ForEach(UserProfile.ActivityLevel.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
        } header: {
            Text("You")
        } footer: {
            // The double-counting trap, explained where the choice is made rather than left
            // for the user to discover from a goal that seems too generous.
            Text("""
                \(profile.activityLevel.detail). Choose this for everyday movement only — \
                workouts you log are subtracted from your daily net separately, so counting \
                them here too would credit them twice.
                """)
        }
    }

    /// Feet and inches get two menus rather than a text field: nobody thinks of themselves as
    /// 5.83 feet tall, and a short list can't be mistyped. Centimetres stay a plain field —
    /// one number, and a 200-entry menu would be worse than typing it.
    @ViewBuilder private var heightRow: some View {
        switch profile.heightUnit {
        case .feetInches:
            HStack {
                Text("Height")
                Spacer()
                Picker("Feet", selection: feetSelection) {
                    Text("—").tag(Int?.none)
                    ForEach(Height.feetRange, id: \.self) { feet in
                        Text("\(feet) ft").tag(Int?.some(feet))
                    }
                }
                .accessibilityLabel("Height, feet")

                // Withheld until there is a height at all: beside an unset "—", a "0 in" would
                // read as a stated zero rather than as nothing entered yet.
                if profile.heightCentimeters != nil {
                    Picker("Inches", selection: inchesSelection) {
                        ForEach(0..<Height.inchesPerFoot, id: \.self) { inches in
                            Text("\(inches) in").tag(inches)
                        }
                    }
                    .accessibilityLabel("Height, inches")
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

        case .centimeters:
            HStack {
                Text("Height")
                Spacer()
                TextField("cm", text: $heightText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("cm").foregroundStyle(.secondary)
            }
        }
    }

    /// Whole feet, or nil when no height is set. Picking "—" clears the height, which the goal
    /// engine reads as "estimate expenditure from observed data instead" rather than as an error.
    ///
    /// Both bindings write straight back to canonical centimetres, so switching units mid-edit
    /// can't leave two disagreeing copies of the same fact. A foot/inch round trip moves the
    /// stored value by up to half an inch, which is worth about a kilocalorie of BMR.
    private var feetSelection: Binding<Int?> {
        Binding(
            get: { profile.heightCentimeters.map { Height.feetAndInches(fromCentimeters: $0).feet } },
            set: { feet in
                guard let feet else {
                    profile.heightCentimeters = nil
                    return
                }
                profile.heightCentimeters = Height.centimeters(feet: feet, inches: currentInches ?? 0)
            }
        )
    }

    private var inchesSelection: Binding<Int> {
        Binding(
            get: { currentInches ?? 0 },
            set: { inches in
                let feet = profile.heightCentimeters
                    .map { Height.feetAndInches(fromCentimeters: $0).feet }
                profile.heightCentimeters = Height.centimeters(feet: feet ?? 5, inches: inches)
            }
        )
    }

    private var currentInches: Int? {
        profile.heightCentimeters.map { Height.feetAndInches(fromCentimeters: $0).inches }
    }

    @ViewBuilder private var goalSection: some View {
        Section {
            HStack {
                Text("Goal weight")
                Spacer()
                TextField(profile.massUnit.shortName, text: $targetWeightText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text(profile.massUnit.shortName).foregroundStyle(.secondary)
            }

            Picker("Rate", selection: $goal.rate) {
                ForEach(GoalSettings.WeeklyRate.allCases, id: \.self) {
                    Text("\($0.displayName) \(profile.massUnit.shortName)/week").tag($0)
                }
            }

            Stepper(
                "Protein target: \(Int(goal.proteinTargetGrams))g",
                value: $goal.proteinTargetGrams, in: 20...400, step: 5
            )
            Stepper(
                "Fiber target: \(Int(goal.fiberTargetGrams))g",
                value: $goal.fiberTargetGrams, in: 10...100, step: 1
            )
        } header: {
            Text("Goal")
        } footer: {
            Text("""
                Your daily calorie target is worked out from these and adjusts as Tally learns \
                what you actually burn. It will never go below a safe minimum, even if that \
                means a slower rate than you picked.
                """)
        }
    }

    @ViewBuilder private var aboutSection: some View {
        Section {
            LabeledContent("Storage", value: "On this device only")
        } footer: {
            Text("Tally has no account and no server. Nothing is uploaded or synced.")
        }
    }

    // MARK: AI provider

    /// The id used for a user-supplied endpoint. Fixed rather than generated so the key stored
    /// against it survives an edit to the URL.
    private static let customProviderID = "custom"

    private var isCustomProvider: Bool { ai.providerID == Self.customProviderID }

    /// True when the on-device model is both preferred and actually usable — the only case where
    /// the provider rows are pointless. A preference set on another device stays visible.
    private var usesOnDevice: Bool { ai.prefersOnDevice && OnDeviceModel.isAvailable }

    private var modelSuggestions: [String] {
        fetchedModels.isEmpty ? ai.provider.suggestedModels : fetchedModels
    }

    /// Switching provider rewrites the model and moves the key field, because carrying either
    /// across is worse than useless: `claude-opus-5` at OpenAI is a 404, and one company's key is
    /// never valid at another.
    private var providerSelection: Binding<String> {
        Binding(
            get: { ai.providerID },
            set: { id in
                guard id != ai.providerID else { return }
                persistKey()

                if id == Self.customProviderID {
                    ai.select(customProvider())
                } else if let provider = LLMProvider.builtIn(id: id) {
                    ai.select(provider)
                }

                fetchedModels = []
                modelRefreshMessage = nil
                loadKey(for: ai.providerID)
            }
        )
    }

    /// Assembles the user's endpoint into a provider. Tolerates a half-typed URL by falling back
    /// to a placeholder, so the picker can be switched to Custom before the address is known.
    private func customProvider() -> LLMProvider {
        let url = URL(string: customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? URL(string: "http://localhost:11434/v1")!

        return .custom(
            id: Self.customProviderID,
            displayName: customName.isEmpty ? "Custom" : customName,
            baseURL: url,
            structuredOutput: customJSONStyle,
            defaultModel: ai.model
        )
    }

    /// Replaces the suggestions with what this key can actually reach.
    private func refreshModels() async {
        isRefreshingModels = true
        modelRefreshMessage = nil
        defer { isRefreshingModels = false }

        do {
            let models = try await ModelCatalog(transport: URLSessionTransport.makeDefault())
                .models(for: ai.provider, apiKey: apiKey)
            fetchedModels = models
            modelRefreshMessage = models.isEmpty
                ? "That key reached \(ai.provider.displayName) but returned no models."
                : "\(models.count) models available."
        } catch let error as LLMError {
            // The provider's own words beat anything invented here — "invalid api key" and
            // "insufficient credit" send the user to completely different places.
            modelRefreshMessage = error.providerMessage
                ?? "Couldn't reach \(ai.provider.displayName). Check the key and try again."
        } catch {
            modelRefreshMessage = error.localizedDescription
        }
    }

    private func loadKey(for providerID: String) {
        keyProviderID = providerID
        apiKey = (try? environment.keyStore(for: providerID).apiKey()) ?? ""
    }

    /// Writes the typed key to the item for the provider it was typed against, not the one now
    /// selected — the distinction that stops a switch mid-edit from filing a key under the wrong
    /// company.
    private func persistKey() {
        try? environment.keyStore(for: keyProviderID).save(apiKey)
    }

    // MARK: Loading and saving

    private static let defaultBirthDate = Calendar.current.date(
        byAdding: .year, value: -35, to: Date()
    ) ?? Date()

    private func load() {
        do {
            profile = try environment.stores.settings.profile()
            goal = try environment.stores.settings.goalSettings()
        } catch {
            saveError = String(describing: error)
        }

        ai = environment.aiSettings
        if let custom = ai.customProvider {
            customName = custom.displayName
            // Shown as the base rather than the completed endpoint, which is the form the user
            // typed and the form their provider's documentation uses.
            customBaseURL = custom.endpoint.deletingLastPathComponent()
                .deletingLastPathComponent().absoluteString
            customJSONStyle = custom.structuredOutput
        }

        heightText = Self.heightText(from: profile.heightCentimeters)
        targetWeightText = goal.targetPounds
            .map { String(format: "%.1f", profile.massUnit.value(fromPounds: $0)) } ?? ""
        loadKey(for: ai.providerID)
    }

    private func save() {
        // Parsed leniently: someone typing "178 cm" or using a comma decimal separator meant a
        // height, and refusing it would be pedantry. The foot/inch pickers write through to the
        // profile as they are used, so there is nothing to commit for them here.
        if profile.heightUnit == .centimeters {
            profile.heightCentimeters = Self.number(from: heightText)
        }
        goal.targetPounds = Self.number(from: targetWeightText)
            .map { profile.massUnit.pounds(from: $0) }

        // Rebuilt from the fields on the way out, so an edited URL or JSON setting takes effect
        // rather than being stranded on the value captured when Custom was first chosen.
        if isCustomProvider {
            ai.customProvider = customProvider()
        }

        do {
            try environment.stores.settings.save(profile)
            try environment.stores.settings.save(goal)
            persistKey()
            try environment.updateAISettings(ai)
        } catch {
            saveError = String(describing: error)
        }
    }

    private static func heightText(from centimeters: Double?) -> String {
        centimeters.map { String(format: "%.0f", $0) } ?? ""
    }

    private static func number(from text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." }
        guard !cleaned.isEmpty, let value = Double(cleaned), value > 0 else { return nil }
        return value
    }
}
