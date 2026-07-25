import Foundation

/// Everything a completion call can fail with.
///
/// The distinctions here are chosen for what a *caller* has to decide, not for what the HTTP
/// spec says: retry now, retry later, fix a credential, shrink the request, or give up. A single
/// `serverError(status:)` case would be easier to write and useless to act on.
///
/// Deliberately provider-neutral. A rate limit is a rate limit whether it arrived as Anthropic's
/// `429 rate_limit_error` or OpenAI's `429 insufficient_quota`, and the code above this line
/// should not have to know which vendor is behind the call.
public enum LLMError: Error, Hashable, Sendable {
    /// No key configured. Not really an error — the expected state before setup.
    case missingAPIKey
    case invalidAPIKey
    /// The key is valid but the account is out of credit. Distinguished from `invalidAPIKey`
    /// because the fix is completely different, and telling someone to check a key that is fine
    /// sends them looking in the wrong place.
    case insufficientCredit(String?)
    case rateLimited(retryAfter: TimeInterval?)
    case overloaded
    case requestTooLarge
    case offline(String)
    /// The model declined to answer.
    case refused(String?)
    /// The reply hit the token ceiling, so it is cut off mid-sentence — or mid-JSON.
    case truncated
    /// A reply arrived but could not be read as the shape the wire format promises.
    case malformedResponse(String)
    /// The named model does not exist at this provider, or the key cannot reach it. Common when
    /// a model identifier is typed by hand or a provider retires one.
    case unknownModel(String)
    /// The request carried an image and the provider or model cannot accept one. Caught before
    /// sending where possible, since the failure is otherwise an opaque 400.
    case imagesUnsupported
    case serverError(status: Int, message: String?)

    /// Whether sending the identical request again could plausibly succeed.
    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded, .offline, .serverError, .truncated:
            true
        case .missingAPIKey, .invalidAPIKey, .insufficientCredit, .requestTooLarge, .refused,
             .malformedResponse, .unknownModel, .imagesUnsupported:
            false
        }
    }

    /// The provider's own words, when it supplied any. Worth surfacing for the cases a caller
    /// cannot phrase better itself — an unknown model or a billing problem is explained far more
    /// precisely by the service than by a generic sentence.
    public var providerMessage: String? {
        switch self {
        case .insufficientCredit(let message): message
        case .refused(let message): message
        case .unknownModel(let message): message
        case .serverError(_, let message): message
        case .malformedResponse(let message): message
        case .offline(let message): message
        case .missingAPIKey, .invalidAPIKey, .rateLimited, .overloaded, .requestTooLarge,
             .truncated, .imagesUnsupported:
            nil
        }
    }
}
