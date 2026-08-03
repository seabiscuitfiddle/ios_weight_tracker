import Foundation

/// What the net-calorie ring says: the number in the middle, the kicker under it, and how
/// VoiceOver reads the two together.
///
/// ``RingMetrics`` decides how big that type is drawn; this decides what it says. Both live here
/// for the same reason — they are the parts of a rendered widget that can be asserted on a
/// machine with no Xcode — and this one exists because the two home-screen widgets had drifted
/// apart on it. Both drew the *remaining* calories, but the 2×2 captioned them "OF 2,100" where
/// the wide one said "CAL LEFT". Captioning a remaining number as a consumed one is what made
/// the small widget look like it had started the day already spent: an untouched day read
/// "2,100 OF 2,100", and every entry logged after it made that number go *down*. Its VoiceOver
/// value disagreed with its own digits on top of that, reading the net against the goal while
/// the screen showed what was left of it.
///
/// So the decision is made once, here, and every widget takes the answer — including the
/// lock-screen rectangle, which has no ring to draw but leads with the same number and had drifted
/// the same way, showing the net against the goal. Three views can still draw that number at
/// different sizes; they can no longer disagree about what it means.
public struct NetRingContent: Equatable, Sendable {
    /// The number in the hole: calories left when there is a goal to count toward, and the raw
    /// net when there isn't.
    public let value: String
    /// The kicker under it, which is what says *which* of those two ``value`` is.
    public let label: String
    /// What VoiceOver announces the element as.
    public let accessibilityLabel: String
    /// And the value it reads — of the number on screen, not of a different one.
    public let accessibilityValue: String

    public init(netCalories: Int, goalCalories: Int?, locale: Locale = .current) {
        guard let goal = goalCalories else {
            // Nothing to count toward, so there is no "remaining" to show. The ring falls back
            // to the net and captions it as such rather than implying a target that isn't set.
            let net = TallyFormat.calories(netCalories, locale: locale)
            value = net
            label = "NET"
            accessibilityLabel = "Net calories"
            accessibilityValue = net
            return
        }

        let left = TallyFormat.calories(goal - netCalories, locale: locale)
        value = left
        label = "CAL LEFT"
        // Worded as the Today screen words the same number, so the ring the user glances at and
        // the ring they open the app to are announced identically.
        accessibilityLabel = "Calories remaining"
        accessibilityValue = "\(left) of \(TallyFormat.calories(goal, locale: locale))"
    }
}
