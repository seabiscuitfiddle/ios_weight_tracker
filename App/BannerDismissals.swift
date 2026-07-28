import Foundation

/// Remembers which storage banners the user has closed, for the lifetime of one build.
///
/// The expiry is the whole point. Both banners describe a *configuration* problem — no database,
/// or no App Group — and the fix for either is a new build. A dismissal that outlived the build
/// would mean someone who closed "the widget won't show your data", then fixed their App Group
/// and shipped a version where the warning is gone, still has no way to learn it came back if it
/// ever regresses. Scoping to the build makes the banner re-earn its silence every install, and
/// costs the user one tap.
///
/// Deliberately keyed on the version *string* rather than a monotonic counter: downgrading to an
/// older build is also a change of situation, and should also show the warning again.
///
/// Pass `defaults: nil` for a memory-only instance. UI tests do, because the simulator keeps
/// `UserDefaults` between runs: a test that dismissed a banner would poison every later run on
/// that simulator, and the failure would look like a missing banner rather than like stale state.
final class BannerDismissals {
    /// Namespaced so a key can never collide with an unrelated preference.
    private static let keysDefault = "tally.banners.dismissed"
    private static let versionDefault = "tally.banners.dismissedForVersion"

    private let defaults: UserDefaults?
    private let version: String

    /// - Parameters:
    ///   - defaults: where to persist, or nil to keep dismissals in memory only.
    ///   - version: the build a dismissal belongs to. Defaults to the running bundle's.
    init(defaults: UserDefaults?, version: String = BannerDismissals.currentVersion()) {
        self.defaults = defaults
        self.version = version
    }

    /// `"1.4 (27)"` — the marketing version and the build number, which is what makes two
    /// TestFlight builds of the same version distinguishable.
    static func currentVersion(bundle: Bundle = .main) -> String {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case (let short?, let build?): return "\(short) (\(build))"
        case (let short?, nil): return short
        case (nil, let build?): return build
        // No Info.plist values at all — a unit-test bundle, most likely. A single stable string
        // is right here: it keeps dismissals consistent within a run rather than expiring them
        // at random.
        case (nil, nil): return "unknown"
        }
    }

    /// The banner keys closed under this build. Empty for any other build, which is how a new
    /// install shows the warnings again.
    func dismissed() -> Set<String> {
        guard let defaults,
              defaults.string(forKey: Self.versionDefault) == version,
              let stored = defaults.stringArray(forKey: Self.keysDefault)
        else { return [] }
        return Set(stored)
    }

    /// Records `key` as closed under this build.
    ///
    /// Writing the version alongside the keys — rather than checking and clearing on read — is
    /// what makes a stale set from an older build simply invisible: it is never read, so it never
    /// has to be migrated or cleaned up.
    func dismiss(_ key: String) {
        guard let defaults else { return }
        var keys = dismissed()
        keys.insert(key)
        defaults.set(Array(keys), forKey: Self.keysDefault)
        defaults.set(version, forKey: Self.versionDefault)
    }
}
