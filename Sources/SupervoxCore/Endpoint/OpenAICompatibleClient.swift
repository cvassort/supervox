import Foundation

/// Client d'un endpoint HTTP compatible OpenAI. Aucun nom de fournisseur ni de modèle : tout vient de `EndpointConfig`
/// et des arguments des appels.
public final class OpenAICompatibleClient: Sendable {
    private let config: EndpointConfig
    let session: URLSession
    /// Délai d'inactivité de chaque requête, en secondes : la requête échoue (`EndpointError.transport`) si aucune
    /// donnée n'arrive pendant cette durée (mesuré : un serveur muet fait échouer la requête au bout du délai ; une
    /// réponse qui s'étire sur plus longtemps mais livre des octets plus souvent passe). Ce n'est pas une durée totale.
    public let requestTimeout: TimeInterval

    /// Sans délai explicite, une requête attendrait 60 s (défaut du système) à chaque appel sur un endpoint muet.
    public static let defaultRequestTimeout: TimeInterval = 30

    public init(config: EndpointConfig, session: URLSession = EndpointSession.shared, requestTimeout: TimeInterval = defaultRequestTimeout) {
        self.config = config
        self.session = session
        self.requestTimeout = requestTimeout
    }

    /// Transcrit un WAV en bloc (`POST <base>/v1/audio/transcriptions`, `multipart/form-data`).
    /// `language` et `prompt` sont omis quand ils valent `nil` ou sont vides. Le texte rendu est débarrassé des
    /// espaces et retours à la ligne de tête et de fin (le serveur de transcription ajoute un espace initial).
    /// Un texte vide est valide : c'est la transcription d'un passage sans parole.
    public func transcribe(wav: Data, model: String, language: String?, prompt: String?) async throws -> String {
        let url = try endpointURL(path: ["audio", "transcriptions"])
        var form = MultipartForm()
        form.addFile(name: "file", filename: "audio.wav", contentType: "audio/wav", data: wav)
        form.addField(name: "model", value: model)
        if let language, !language.isEmpty { form.addField(name: "language", value: language) }
        if let prompt, !prompt.isEmpty { form.addField(name: "prompt", value: prompt) }
        form.addField(name: "response_format", value: "json")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let (data, _) = try await send(request, body: form.finished())

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = object["text"] as? String
        else { throw EndpointError.malformedResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Réponse d'un modèle en flux (`POST <base>/v1/chat/completions`, `stream: true`, lecture ligne à ligne des événements SSE).
    /// Le flux rend les morceaux de texte non vides dans l'ordre : `.content` pour la réponse, `.reasoning` pour la
    /// réflexion du modèle (champ `reasoning_content` ou `reasoning`, selon le serveur).
    ///
    /// Le flux se termine normalement, et seulement, après `data: [DONE]` et au moins un morceau non vide. Toute autre
    /// fin est une erreur, jamais une fin silencieuse : coupure avant `[DONE]` (`.streamInterrupted`), objet `error` dans
    /// le flux ou dans un corps 200 qui n'est pas un flux (`.http`), flux vide (`.malformedResponse`), panne réseau
    /// (`.transport`), statut hors 2xx (`.http`). Les lignes illisibles ou sans rapport (commentaires, lignes `data:`
    /// qui ne sont pas du JSON) sont ignorées. L'arrêt de la lecture (boucle quittée, tâche annulée) annule la requête.
    /// La requête part dès l'appel de `chatStream`, pas à la première itération. Une tâche consommatrice annulée voit sa
    /// boucle se terminer sans erreur (comportement d'`AsyncThrowingStream`) : tester `Task.isCancelled` ensuite.
    public func chatStream(model: String, messages: [ChatMessage], maxTokens: Int) -> AsyncThrowingStream<ChatDelta, Error> {
        endpoint.events(
            request: { try self.streamingRequest(model: model, messages: messages, maxTokens: maxTokens) },
            reader: { status, redact in ChatChunkParser(status: status, redact: redact) })
    }

    /// Synthèse vocale (`POST <base>/v1/audio/speech`). Rend les octets audio. `extra` est fusionné au premier niveau
    /// du corps JSON (en chaînes : un paramètre numérique part donc comme une chaîne JSON) ; une clé d'`extra` ne
    /// remplace jamais `model`, `input`, `voice` ni `response_format` (ce dernier vient de `format`) : elle est ignorée.
    /// Un corps vide, un corps JSON ou texte (une erreur renvoyée avec un statut 2xx) et, pour `wav`, un corps sans en-tête
    /// WAV ne sont pas de l'audio : ils lèvent une erreur au lieu d'être rendus.
    public func speech(model: String, input: String, voice: String, format: String, extra: [String: String]) async throws -> Data {
        try await speechMeasured(model: model, input: input, voice: voice, format: format, extra: extra).audio
    }

    /// `speech`, et la connexion qui l'a portée telle que `URLSessionTaskMetrics` la décrit (dernière transaction de
    /// la tâche) : protocole négocié, connexion réutilisée ou ouverte pour l'appel. `connection` est `nil` si le
    /// système n'a pas livré de mesures avant la fin de l'appel.
    public func speechMeasured(model: String, input: String, voice: String, format: String,
                               extra: [String: String]) async throws -> (audio: Data, connection: ConnectionInfo?) {
        let url = try endpointURL(path: ["audio", "speech"])
        var fields = extra
        fields["model"] = model
        fields["input"] = input
        fields["voice"] = voice
        fields["response_format"] = format
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let delegate = EndpointTaskDelegate()
        let (data, response) = try await send(request, body: try encoder.encode(fields), delegate: delegate)
        try checkIsAudio(data, response: response, format: format)
        return (data, delegate.connection)
    }

    // MARK: - Requêtes

    private var endpoint: EndpointRequest { EndpointRequest(config: config, session: session) }

    private func endpointURL(path: [String]) throws -> URL { try endpoint.url(path: path) }

    /// Envoie la requête et rend le corps et la réponse d'un statut 2xx. Toute autre issue est une `EndpointError`,
    /// sauf l'annulation de la tâche, qui reste une `CancellationError`. Une redirection vers une autre origine
    /// n'est pas suivie (`EndpointTaskDelegate`).
    private func send(_ request: URLRequest, body: Data,
                      delegate: EndpointTaskDelegate = EndpointTaskDelegate()) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
        } catch {
            throw mapped(error)
        }
        if delegate.refusedRedirect { throw EndpointError.crossOriginRedirect }
        guard let http = response as? HTTPURLResponse else { throw EndpointError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw EndpointError.http(status: http.statusCode, body: errorBody(data))
        }
        return (data, http)
    }

    private func mapped(_ error: any Error) -> any Error { endpoint.mapped(error) }

    private func errorBody(_ data: Data) -> String { endpoint.errorBody(data) }

    private func errorBody(_ text: String) -> String { endpoint.errorBody(text) }

    // MARK: - Flux de chat

    /// `POST <base>/v1/chat/completions` en flux : la requête de `chatStream` et de `complete`.
    private func streamingRequest(model: String, messages: [ChatMessage], maxTokens: Int) throws -> URLRequest {
        struct Body: Encodable {
            struct Message: Encodable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let max_tokens: Int
            let stream = true
        }
        var request = URLRequest(url: try endpointURL(path: ["chat", "completions"]))
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            Body(model: model, messages: messages.map { .init(role: $0.role, content: $0.content) }, max_tokens: maxTokens))
        return request
    }

    /// Un corps 2xx qui n'est pas de l'audio est refusé (voir `speech`).
    private func checkIsAudio(_ data: Data, response: HTTPURLResponse, format: String) throws {
        if data.isEmpty { throw EndpointError.malformedResponse }
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let declaredText = contentType.hasPrefix("application/json") || contentType.hasPrefix("text/")
        // Un corps qui se lit comme un document JSON n'est pas de l'audio : du PCM brut peut commencer par `{`,
        // mais pas former un document JSON complet.
        let json = try? JSONSerialization.jsonObject(with: data)
        if declaredText || json is [String: Any] || json is [Any] {
            if let object = json as? [String: Any], !(object["error"] is NSNull), object["error"] != nil {
                throw EndpointError.http(status: response.statusCode, body: errorBody(data))
            }
            throw EndpointError.malformedResponse
        }
        if format.lowercased() == "wav", !Self.hasWavHeader(data) { throw EndpointError.malformedResponse }
    }

    private static func hasWavHeader(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let head = Array(data.prefix(12))
        return (head[0..<4] == [0x52, 0x49, 0x46, 0x46] || head[0..<4] == [0x52, 0x46, 0x36, 0x34])  // "RIFF" ou "RF64"
            && head[8..<12] == [0x57, 0x41, 0x56, 0x45]  // "WAVE"
    }
}

/// Connexion qui a porté une requête, d'après `URLSessionTaskMetrics`.
public struct ConnectionInfo: Equatable, Sendable {
    /// Protocole négocié (ALPN) : `h2`, `http/1.1`, `h3`… ; `nil` si le système ne l'a pas dit.
    public let networkProtocol: String?
    /// `true` si la requête est partie sur une connexion déjà ouverte.
    public let reused: Bool

    public init(networkProtocol: String?, reused: Bool) {
        self.networkProtocol = networkProtocol
        self.reused = reused
    }
}

public struct ChatMessage: Sendable {
    public let role: String
    public let content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// Un morceau de la réponse d'un modèle : le texte de la réponse, ou celui de sa réflexion.
public enum ChatDelta: Equatable, Sendable {
    case content(String)
    case reasoning(String)
}

/// Corps `multipart/form-data` (RFC 7578) : chaque champ est séparé par `--frontière`, la fin par `--frontière--`.
private struct MultipartForm {
    private let boundary = "supervox-\(UUID().uuidString)"
    private var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        append(value)
        append("\r\n")
    }

    mutating func addFile(name: String, filename: String, contentType: String, data: Data) {
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n")
        body.append(data)
        append("\r\n")
    }

    func finished() -> Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }

    private mutating func append(_ string: String) { body.append(Data(string.utf8)) }
}

/// Lit les lignes d'un flux de chat et en tire les morceaux de texte. Une ligne = un événement : les serveurs
/// compatibles n'étalent jamais un objet JSON sur plusieurs lignes `data:`.
private struct ChatChunkParser: SSEReader {
    private let status: Int
    private let redact: (String) -> String
    private(set) var isDone = false
    /// La première raison d'arrêt non nulle du flux. Un serveur peut en redire une autre plus loin (l'enregistrement
    /// `chat-stream-reasoning.sse` dit `length`, puis `stop` sur un morceau vide) : la première est celle du texte.
    private(set) var finishReason: String?
    private(set) var deliveredSomething = false
    private var sawDataLine = false
    /// Lignes qui ne sont ni un champ SSE ni un commentaire : le début d'un corps JSON d'erreur, par exemple.
    private var unrecognised: [String] = []
    private var unrecognisedBytes = 0

    init(status: Int, redact: @escaping (String) -> String) {
        self.status = status
        self.redact = redact
    }

    mutating func consume(line: String) throws -> [ChatDelta] {
        if line.isEmpty || line.hasPrefix(":") { return [] }
        guard line.hasPrefix("data:") else {
            if !["event:", "id:", "retry:"].contains(where: line.hasPrefix), unrecognisedBytes < 64 * 1024 {
                unrecognised.append(line)
                unrecognisedBytes += line.utf8.count
            }
            return []
        }
        sawDataLine = true
        var payload = line.dropFirst("data:".count)
        if payload.first == " " { payload = payload.dropFirst() }
        if payload.trimmingCharacters(in: .whitespaces) == "[DONE]" {
            isDone = true
            return []
        }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return [] }
        if let error = object["error"], !(error is NSNull) {
            throw EndpointError.http(status: status, body: redact(String(payload)))
        }
        guard let choice = (object["choices"] as? [Any])?.first as? [String: Any] else { return [] }
        if finishReason == nil, let reason = choice["finish_reason"] as? String, !reason.isEmpty { finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any] else { return [] }
        // Un serveur peut envoyer les deux noms de champ avec le même texte : on ne garde que le premier non vide.
        let reasoning = [delta["reasoning_content"], delta["reasoning"]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty }
        var out: [ChatDelta] = []
        if let reasoning { out.append(.reasoning(reasoning)) }
        if let content = delta["content"] as? String, !content.isEmpty { out.append(.content(content)) }
        if !out.isEmpty { deliveredSomething = true }
        return out
    }

    /// `[DONE]` sans un seul morceau de texte (ni réponse ni réflexion) n'est pas une réponse : on ne la fait pas
    /// passer pour un succès.
    func finishAfterDone() throws -> [ChatDelta] {
        if !deliveredSomething { throw EndpointError.malformedResponse }
        return []
    }

    /// L'erreur d'un flux qui s'arrête sans `[DONE]`. Sans aucune ligne `data:`, le corps n'est pas un flux : si c'est
    /// un objet JSON `error`, c'est lui qu'on rend, sinon le corps est mal formé.
    func endWithoutDone() -> any Error {
        if sawDataLine || unrecognised.isEmpty { return EndpointError.streamInterrupted }
        let text = unrecognised.joined(separator: "\n")
        if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
           let error = object["error"], !(error is NSNull) {
            return EndpointError.http(status: status, body: redact(text))
        }
        return EndpointError.malformedResponse
    }
}

/// Le même flux de chat lu comme une complétion : les morceaux deviennent `.text` et `.reasoning`, la raison d'arrêt
/// devient un `.stop` unique livré à `[DONE]`, après le contrôle « au moins un morceau », donc jamais avant une erreur.
private struct OpenAICompletionReader: SSEReader {
    private var parser: ChatChunkParser

    init(status: Int, redact: @escaping (String) -> String) {
        parser = ChatChunkParser(status: status, redact: redact)
    }

    var isDone: Bool { parser.isDone }

    mutating func consume(line: String) throws -> [CompletionEvent] {
        try parser.consume(line: line).map {
            switch $0 {
            case .content(let text): .text(text)
            case .reasoning(let text): .reasoning(text)
            }
        }
    }

    /// Sans aucun morceau, `[DONE]` n'est pas une réponse (`.malformedResponse`), sauf si le serveur dit que la réponse
    /// est coupée ou refusée : la raison est alors livrée, `.stop` seul, fin normale (même règle que pour Anthropic).
    mutating func finishAfterDone() throws -> [CompletionEvent] {
        let stop = parser.finishReason.map(Self.stop(for:))
        if !parser.deliveredSomething, let stop, stop == .truncated || stop == .refused { return [.stop(stop)] }
        _ = try parser.finishAfterDone()
        return stop.map { [.stop($0)] } ?? []
    }

    func endWithoutDone() -> any Error { parser.endWithoutDone() }

    /// `finish_reason` des serveurs compatibles OpenAI.
    private static func stop(for reason: String) -> CompletionStop {
        switch reason {
        case "stop": .complete
        case "length": .truncated
        case "content_filter": .refused
        default: .other
        }
    }
}

extension OpenAICompatibleClient: LanguageModel {
    /// `POST <base>/v1/chat/completions` (`stream: true`), messages `[system: instruction, user: input]`. Même lecteur
    /// que `chatStream`, qui ne livre pas la raison d'arrêt ; ici elle arrive en `.stop`. Un silence est
    /// `CompletionError.stalled`, alors que `chatStream` le rend en `.transport`.
    public func complete(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        endpoint.events(
            request: {
                try self.streamingRequest(
                    model: request.model,
                    messages: [ChatMessage(role: "system", content: request.instruction),
                               ChatMessage(role: "user", content: request.input)],
                    maxTokens: request.maxTokens)
            },
            reader: { status, redact in OpenAICompletionReader(status: status, redact: redact) },
            timeoutAs: CompletionError.stalled)
    }
}
