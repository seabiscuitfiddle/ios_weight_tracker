import Foundation

#if canImport(FoundationNetworking)
// On Linux, URLSession lives in a separate module from the rest of Foundation.
import FoundationNetworking
#endif

/// One HTTP round trip.
///
/// The seam that makes the whole LLM layer testable without a network or an API key: tests
/// supply a transport that replays recorded responses and captures the request that was built,
/// so both halves of the contract — what we send, and how we read what comes back — are
/// verified on a machine with no Xcode and no credentials.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct HTTPResponse: Hashable, Sendable {
    public var statusCode: Int
    public var body: Data
    public var headers: [String: String]

    public init(statusCode: Int, body: Data, headers: [String: String] = [:]) {
        self.statusCode = statusCode
        self.body = body
        self.headers = headers
    }

    /// Case-insensitive header lookup, since HTTP header names are not case-sensitive and
    /// servers vary in what they send.
    public func header(_ name: String) -> String? {
        if let exact = headers[name] { return exact }
        let lowered = name.lowercased()
        return headers.first { $0.key.lowercased() == lowered }?.value
    }
}

/// The real transport, over `URLSession`.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// A session with timeouts suited to a foreground request the user is waiting on.
    ///
    /// The default 60s would leave someone staring at a spinner far longer than they'd tolerate
    /// while logging a meal; 30s is past the point where retrying beats waiting. Connectivity
    /// waiting is left off (the default) on purpose — offline should surface immediately so the
    /// app can offer manual entry, not queue silently behind a spinner.
    public static func makeDefault() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw NutritionParserError.malformedResponse("Response was not HTTP.")
            }

            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
            return HTTPResponse(statusCode: http.statusCode, body: data, headers: headers)
        } catch let error as NutritionParserError {
            throw error
        } catch let error as URLError {
            // Connectivity problems are worth distinguishing: the app can suggest logging by
            // hand rather than implying the service is broken.
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                throw NutritionParserError.offline(error.localizedDescription)
            default:
                throw NutritionParserError.offline(error.localizedDescription)
            }
        }
    }
}
