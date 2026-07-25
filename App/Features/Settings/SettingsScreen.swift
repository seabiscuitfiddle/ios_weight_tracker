import SwiftUI
import TallyCore

/// Profile, goal, units, and the API key.
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
    @State private var apiKey = ""
    @State private var model = ParserConfiguration.default.model
    @State private var heightText = ""
    @State private var targetWeightText = ""
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                aiSection
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

    @ViewBuilder private var aiSection: some View {
        Section {
            SecureField("sk-ant-…", text: $apiKey)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Picker("Model", selection: $model) {
                ForEach(ParserConfiguration.availableModels, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
        } header: {
            Text("AI logging")
        } footer: {
            // States plainly where the key goes and where it's sent. A credential the user
            // supplies deserves an explicit answer to "what happens to this?", in the place
            // they hand it over.
            Text("""
                Stored in your device's keychain and sent only to api.anthropic.com. \
                You're billed by Anthropic directly. Tally works without a key — you can \
                always add entries by hand.
                """)
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

            HStack {
                Text("Height")
                Spacer()
                TextField("cm", text: $heightText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text("cm").foregroundStyle(.secondary)
            }

            Picker("Units", selection: $profile.massUnit) {
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

        heightText = profile.heightCentimeters.map { String(format: "%.0f", $0) } ?? ""
        targetWeightText = goal.targetPounds
            .map { String(format: "%.1f", profile.massUnit.value(fromPounds: $0)) } ?? ""
        apiKey = (try? environment.keyStore.apiKey()) ?? ""
    }

    private func save() {
        // Parsed leniently: someone typing "178 cm" or using a comma decimal separator meant a
        // height, and refusing it would be pedantry.
        profile.heightCentimeters = Self.number(from: heightText)
        goal.targetPounds = Self.number(from: targetWeightText)
            .map { profile.massUnit.pounds(from: $0) }

        do {
            try environment.stores.settings.save(profile)
            try environment.stores.settings.save(goal)
            try environment.keyStore.save(apiKey)
            environment.updateParserConfiguration(model: model)
        } catch {
            saveError = String(describing: error)
        }
    }

    private static func number(from text: String) -> Double? {
        let cleaned = text
            .replacingOccurrences(of: ",", with: ".")
            .filter { $0.isNumber || $0 == "." }
        guard !cleaned.isEmpty, let value = Double(cleaned), value > 0 else { return nil }
        return value
    }
}
