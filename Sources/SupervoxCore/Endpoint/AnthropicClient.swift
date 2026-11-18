import Foundation

/// Client de l'API Messages d'Anthropic, en flux. Aucun nom de modèle : il vient de la demande ; l'adresse et la clé
/// viennent de `EndpointConfig`.
public final class AnthropicClient: LanguageModel, Sendable {
    private let config: EndpointConfig
    let session: URLSession
    /// Délai d'inactivité de chaque requête, en secondes (voir `OpenAICompatibleClient.requestTimeout`).
    public let requestTimeout: TimeInterval

    public init(config: EndpointConfig, session: URLSession = EndpointSession.shared,
                requestTimeout: TimeInterval = OpenAICompatibleClient.defaultRequestTimeout) {
        self.config = config
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// `POST <base>/v1/messages` (`stream: true`), en-têtes `x-api-key`, `anthropic-version`, `content-type` et `accept`.
    /// La consigne part en `system` ; `messages` est l'historique dans l'ordre, puis le texte en dernier message de
    /// l'utilisateur (sans historique : ce texte seul). Ni `temperature`, ni `top_p`, ni `top_k` :
    /// cette version d'API les refuse (référence locale de l'API, codes d'erreur 400).
    ///
    /// Le flux se termine normalement, et seulement, après l'événement `message_stop` et au moins un morceau de texte ou
    /// de réflexion (ou, sans morceau, une raison d'arrêt `truncated` ou `refused`, livrée en `.stop` seul). Toute autre fin est une erreur : coupure avant `message_stop` (`.streamInterrupted`), événement
    /// `error` (`CompletionError.provider`, après le texte déjà livré), flux sans contenu (`.malformedResponse`),
    /// silence (`CompletionError.stalled`), panne réseau (`.transport`), statut hors 2xx (`.http`).
    public func complete(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        endpoint.events(
            request: { try self.messagesRequest(request) },
            reader: { _, redact in AnthropicStreamReader(redact: redact) },
            timeoutAs: CompletionError.stalled)
    }

    private var endpoint: EndpointRequest { EndpointRequest(config: config, session: session) }

    private func messagesRequest(_ completion: CompletionRequest) throws -> URLRequest {
        struct Body: Encodable {
            struct Message: Encodable { let role: String; let content: String }
            let model: String
            let max_tokens: Int
            let system: String
            let messages: [Message]
            let stream = true
        }
        var request = URLRequest(url: try endpoint.url(path: ["messages"]))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(ModelLister.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONEncoder().encode(
            Body(model: completion.model, max_tokens: completion.maxTokens, system: completion.instruction,
                 messages: completion.history.map { .init(role: $0.role.rawValue, content: $0.text) }
                     + [.init(role: "user", content: completion.input)]))
        return request
    }
}

/// Lit les événements d'un flux de l'API Messages. Une ligne `data:` porte un objet JSON dont `type` donne
/// l'événement : seuls `content_block_delta` (`text_delta`, `thinking_delta`), `message_delta` (`stop_reason`),
/// `message_stop` et `error` comptent ; le reste (`ping`, `message_start`, `content_block_start`, `content_block_stop`,
/// `signature_delta`, lignes `event:`, commentaires) est ignoré.
struct AnthropicStreamReader: SSEReader {
    private let redact: (String) -> String
    private(set) var isDone = false
    private var deliveredSomething = false
    private var stopReason: String?
    private var sawDataLine = false
    /// Une ligne qui n'est ni un champ SSE ni un commentaire : le corps n'est pas un flux (un objet JSON, du HTML).
    private var sawForeignLine = false

    init(redact: @escaping (String) -> String) { self.redact = redact }

    mutating func consume(line: String) throws -> [CompletionEvent] {
        if line.isEmpty || line.hasPrefix(":") { return [] }
        guard line.hasPrefix("data:") else {
            if !["event:", "id:", "retry:"].contains(where: line.hasPrefix) { sawForeignLine = true }
            return []
        }
        sawDataLine = true
        var payload = line.dropFirst("data:".count)
        if payload.first == " " { payload = payload.dropFirst() }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any],
              let type = object["type"] as? String
        else { return [] }
        switch type {
        case "content_block_delta":
            guard let delta = object["delta"] as? [String: Any] else { return [] }
            switch delta["type"] as? String {
            case "text_delta":
                guard let text = delta["text"] as? String, !text.isEmpty else { return [] }
                deliveredSomething = true
                return [.text(text)]
            case "thinking_delta":
                guard let text = delta["thinking"] as? String, !text.isEmpty else { return [] }
                deliveredSomething = true
                return [.reasoning(text)]
            default:
                return []
            }
        case "message_delta":
            // La première raison d'arrêt non nulle : le message n'en annonce qu'une.
            if stopReason == nil, let reason = (object["delta"] as? [String: Any])?["stop_reason"] as? String, !reason.isEmpty {
                stopReason = reason
            }
            return []
        case "message_stop":
            isDone = true
            return []
        case "error":
            let kind = (object["error"] as? [String: Any])?["type"] as? String
            throw CompletionError.provider(type: kind.map(redact) ?? "inconnu")
        default:
            return []
        }
    }

    /// `message_stop` sans un seul morceau de texte (ni réponse ni réflexion) n'est pas une réponse (`.malformedResponse`),
    /// sauf si le modèle dit pourquoi : une réponse coupée (`max_tokens`, réflexion non affichée qui a tout consommé) ou
    /// refusée (avant toute sortie) garde sa raison, `.stop` seul, fin normale. Le consommateur peut ainsi dire « coupée »
    /// ou « refusée » au lieu de « mal formée ».
    mutating func finishAfterDone() throws -> [CompletionEvent] {
        let stop = stopReason.map(Self.stop(for:))
        if !deliveredSomething && stop != .truncated && stop != .refused { throw EndpointError.malformedResponse }
        return stop.map { [.stop($0)] } ?? []
    }

    /// Sans aucune ligne `data:`, le corps n'est pas un flux : un objet JSON ou une page ne sont pas une coupure.
    func endWithoutDone() -> any Error {
        sawDataLine || !sawForeignLine ? EndpointError.streamInterrupted : EndpointError.malformedResponse
    }

    /// `stop_reason` de l'API Messages.
    private static func stop(for reason: String) -> CompletionStop {
        switch reason {
        case "end_turn", "stop_sequence": .complete
        case "max_tokens", "model_context_window_exceeded": .truncated
        case "refusal": .refused
        default: .other
        }
    }
}
