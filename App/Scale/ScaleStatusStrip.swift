import SwiftUI
import TallyCore

/// A weigh-in that just arrived from the scale.
struct ScaleConfirmation: Equatable, Identifiable {
    let id = UUID()
    let pounds: Double
    /// Set when the reading arrived but couldn't be saved.
    var failure: String?
}

/// The strip that appears above the tab bar while the scale is weighing, then says what was
/// logged.
///
/// Stepping on a scale is done with the phone out of reach, so the result has to be readable
/// from wherever the app was left — not only on Progress, where the weight lives.
struct ScaleStatusStrip: View {
    @Environment(AppEnvironment.self) private var environment

    /// How long a logged reading stays up.
    static let confirmationDuration: Duration = .seconds(5)

    var body: some View {
        Group {
            if let confirmation = environment.scaleConfirmation {
                strip(icon: confirmation.failure == nil ? "checkmark" : "exclamationmark.triangle",
                      title: title(for: confirmation),
                      detail: confirmation.failure)
                    .task(id: confirmation.id) {
                        try? await Task.sleep(for: Self.confirmationDuration)
                        guard !Task.isCancelled,
                              environment.scaleConfirmation?.id == confirmation.id
                        else { return }
                        environment.scaleConfirmation = nil
                    }
                    .onTapGesture { environment.scaleConfirmation = nil }
            } else if environment.scale.status == .weighing {
                strip(icon: "scalemass", title: "Weighing…", detail: nil)
            }
        }
        .animation(.easeOut(duration: 0.2), value: environment.scaleConfirmation)
        .animation(.easeOut(duration: 0.2), value: environment.scale.status)
    }

    private func title(for confirmation: ScaleConfirmation) -> String {
        let unit = (try? environment.stores.settings.profile().massUnit) ?? .pounds
        let weight = TallyFormat.weightWithUnit(pounds: confirmation.pounds, unit: unit)
        return confirmation.failure == nil
            ? "Logged \(weight) from your scale"
            : "Couldn't save \(weight) from your scale"
    }

    private func strip(icon: String, title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Metrics.space2) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .heavy))
            VStack(alignment: .leading, spacing: Metrics.space1) {
                Text(title)
                    .font(.tallyScaled(13, weight: .heavy))
                if let detail {
                    Text(detail)
                        .font(.tallyScaled(11, weight: .regular, relativeTo: .caption))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Color.tallyText)
        .padding(Metrics.space3)
        .background(Color.tallySurface)
        .overlay(alignment: .top) { TallyRule() }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scale.status")
    }
}
