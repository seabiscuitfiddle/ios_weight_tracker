import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asks a provider which models the user's key can actually reach.
///
/// Exists because a hardcoded model list is wrong within months — identifiers are added, renamed
/// and retired constantly, and an app that ships one either nags the user to update or quietly
/// fails with "model not found". Every OpenAI-compatible provider exposes `/v1/models`, and
/// Anthropic exposes an equivalent, so the honest answer is available at runtime for the cost of
/// one request.
public struct ModelCatalog: Sendable {
    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    /// Model identifiers available at `provider`, sorted.
    ///
    /// Throws ``LLMError/malformedResponse(_:)`` when the provider has no listing endpoint, so a
    /// caller can fall back to ``LLMProvider/suggestedModels`` rather than showing an empty list.
    public func models(for provider: LLMProvider, apiKey: String?) async throws -> [String] {
        guard let endpoint = provider.modelsEndpoint else {
            throw LLMError.malformedResponse(
                "\(provider.displayName) does not publish a model list."
            )
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"

        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch provider.authStyle {
        case .anthropicHeader:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue(AnthropicWire.apiVersion, forHTTPHeaderField: "anthropic-version")
        case .bearer:
            if !key.isEmpty {
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
        }

        let response = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw provider.wireFormat == .anthropicMessages
                ? AnthropicWire.error(from: response)
                : OpenAIWire.error(from: response)
        }

        guard let listing = try? JSONDecoder().decode(Listing.self, from: response.body) else {
            throw LLMError.malformedResponse("The model list was not in the expected format.")
        }

        return listing.data.map(\.id).filter { !$0.isEmpty }.sorted()
    }

    /// Both formats put the identifiers in `data[].id`; only the surrounding metadata differs,
    /// and none of it is needed here.
    private struct Listing: Decodable {
        var data: [Model]
        struct Model: Decodable { var id: String }
    }
}
