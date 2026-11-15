import Foundation

/// Whether the user has switched on the Bluetooth scale.
///
/// In `UserDefaults` rather than in the profile, because it describes this device rather than
/// the person: Bluetooth permission, and the scale in the bathroom, belong to one phone. Nothing
/// outside the running app reads it — an App Intent or the widget has no use for the radio.
///
/// Pass `defaults: nil` for a memory-only instance, as UI tests do, for the same reason
/// ``BannerDismissals`` gives: the simulator keeps `UserDefaults` between runs.
struct ScalePreferences {
    private static let enabledKey = "tally.scale.enabled"

    private let defaults: UserDefaults?
    private var memory = false

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        get { defaults?.bool(forKey: Self.enabledKey) ?? memory }
        set {
            memory = newValue
            defaults?.set(newValue, forKey: Self.enabledKey)
        }
    }
}
