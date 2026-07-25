import Foundation

/// A destination inside the app, addressable by URL.
///
/// The widget's quick-log buttons are the reason this exists: a widget cannot run app code, so
/// "open the app straight into voice logging" has to travel as a URL. Keeping the parsing here
/// rather than in the app target means it is testable without Xcode — and URL parsing is
/// exactly the sort of code that quietly mishandles an edge case.
public enum DeepLink: Hashable, Sendable {
    case today
    case log(mode: LogMode)
    case history(day: Day?)
    case progress
    case settings

    /// Which compose mode the Log screen should open in.
    public enum LogMode: String, Hashable, Sendable, CaseIterable {
        case text, photo, voice
    }

    /// Declared in `project.yml` under the app target's `CFBundleURLTypes`. Changing one
    /// without the other silently breaks every widget button, so they are documented together
    /// in the README.
    public static let scheme = "tally"

    /// Parses an incoming URL, or returns nil if it isn't one of ours.
    ///
    /// Unknown hosts return nil rather than defaulting to `.today`: a URL we don't understand
    /// is a bug or a hostile link, and silently landing the user somewhere plausible would hide
    /// both.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }

        // In `tally://log?mode=voice` the "log" part is the host; in `tally:log` it's the path.
        // Accepting both means a hand-typed or hand-written URL behaves the same way.
        let host = url.host?.lowercased()
        let firstPathComponent = url.pathComponents
            .first { $0 != "/" }?
            .lowercased()
        guard let action = host ?? firstPathComponent else { return nil }

        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .reduce(into: [String: String]()) { result, item in
                result[item.name.lowercased()] = item.value
            } ?? [:]

        switch action {
        case "today":
            self = .today
        case "log":
            // An unrecognised or absent mode falls back to text, which is the one mode that
            // always works and needs no permission.
            self = .log(mode: query["mode"].flatMap(LogMode.init(rawValue:)) ?? .text)
        case "history":
            self = .history(day: query["day"].flatMap(Day.init))
        case "progress":
            self = .progress
        case "settings":
            self = .settings
        default:
            return nil
        }
    }

    /// The URL that reopens this destination. Round-trips through ``init(url:)``.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme

        switch self {
        case .today:
            components.host = "today"
        case .log(let mode):
            components.host = "log"
            components.queryItems = [URLQueryItem(name: "mode", value: mode.rawValue)]
        case .history(let day):
            components.host = "history"
            if let day {
                components.queryItems = [URLQueryItem(name: "day", value: day.description)]
            }
        case .progress:
            components.host = "progress"
        case .settings:
            components.host = "settings"
        }

        // Every case above produces a valid URL; the force-unwrap would only fire if one of
        // them were changed to something malformed, which the round-trip tests would catch.
        return components.url!
    }

    /// Which tab this destination lives on.
    public var tab: Tab {
        switch self {
        case .today: .today
        case .log: .log
        case .history: .history
        // Settings has no tab of its own — it opens over Progress, which is where the
        // design puts the profile button.
        case .progress, .settings: .progress
        }
    }

    /// The four tabs along the bottom of every screen.
    public enum Tab: String, Hashable, Sendable, CaseIterable {
        case today, log, history, progress

        public var title: String {
            switch self {
            case .today: "Today"
            case .log: "Log"
            case .history: "History"
            case .progress: "Progress"
            }
        }
    }
}
