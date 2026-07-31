import Foundation

#if canImport(FoundationNetworking)
// On Linux, URLSession lives in a separate module from the rest of Foundation.
import FoundationNetworking
#endif

/// One HTTP round trip.
///
/// The seam that makes the whole library testable without a network or an API key: tests supply a
/// transport that replays recorded responses and captures the request that was built, so both
/// halves of the contract — what we send, and how we read what comes back — are verified on a
/// machine with no Xcode and no credentials.
///
/// It is also the reason this library abstracts *transport* rather than *generation*. Wrapping
/// the generation call, as most multi-provider SDKs do, hides exactly the thing that has to be
/// asserted on when a new provider is added: the bytes on the wire.
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
    /// The default 60s would leave someone staring at a spinner far longer than they'd tolerate;
    /// 30s is past the point where retrying beats waiting. Connectivity waiting is left off (the
    /// default) on purpose — offline should surface immediately so the caller can offer a manual
    /// path, not queue silently behind a spinner.
    public static func makeDefault(
        timeout: TimeInterval = 30,
        resourceTimeout: TimeInterval = 60
    ) -> URLSessionTransport {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = resourceTimeout
        #if canImport(Darwin)
        // Keeps the connection open when the app stops being on screen. A caller that has
        // arranged to keep running — an iOS background task assertion — otherwise waits out its
        // borrowed time on a socket the system tore down the moment the phone was locked, which
        // is the same lost reply the assertion was taken out to prevent.
        configuration.shouldUseExtendedBackgroundIdleMode = true
        #endif
        return URLSessionTransport(session: URLSession(configuration: configuration))
    }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LLMError.malformedResponse("Response was not HTTP.")
            }

            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String {
                    headers[key] = value
                }
            }
            return HTTPResponse(statusCode: http.statusCode, body: data, headers: headers)
        } catch let error as LLMError {
            throw error
        } catch let error as URLError {
            // Connectivity problems are worth distinguishing: the caller can suggest an offline
            // path rather than implying the service is broken. Note that a self-hosted or LAN
            // endpoint — Ollama on a desk machine — fails here far more often than a hosted API,
            // which is another reason not to report it as a server fault.
            throw LLMError.offline(error.localizedDescription)
        }
    }
}
