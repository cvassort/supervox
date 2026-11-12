import Foundation

/// Client d'un endpoint HTTP compatible OpenAI. Aucun nom de fournisseur ni de modèle : tout vient de `EndpointConfig`
/// et des arguments des appels.
public final class OpenAICompatibleClient: Sendable {
    private let config: EndpointConfig
    private let session: URLSession
    /// Délai d'inactivité de chaque requête, en secondes : la requête échoue (`EndpointError.transport`) si aucune
    /// donnée n'arrive pendant cette durée (mesuré : un serveur muet fait échouer la requête au bout du délai ; une
    /// réponse qui s'étire sur plus longtemps mais livre des octets plus souvent passe). Ce n'est pas une durée totale.
    public let requestTimeout: TimeInterval

    /// Sans délai explicite, une requête attendrait 60 s (défaut du système) à chaque appel sur un endpoint muet.
    public static let defaultRequestTimeout: TimeInterval = 30

    public init(config: EndpointConfig, session: URLSession = .shared, requestTimeout: TimeInterval = defaultRequestTimeout) {
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
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.streamChat(model: model, messages: messages, maxTokens: maxTokens, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapped(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Synthèse vocale (`POST <base>/v1/audio/speech`). Rend les octets audio. `extra` est fusionné au premier niveau
    /// du corps JSON (en chaînes : un paramètre numérique part donc comme une chaîne JSON) ; une clé d'`extra` ne
    /// remplace jamais `model`, `input`, `voice` ni `response_format` (ce dernier vient de `format`) : elle est ignorée.
    /// Un corps vide, un corps JSON ou texte (une erreur renvoyée avec un statut 2xx) et, pour `wav`, un corps sans en-tête
    /// WAV ne sont pas de l'audio : ils lèvent une erreur au lieu d'être rendus.
    public func speech(model: String, input: String, voice: String, format: String, extra: [String: String]) async throws -> Data {
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
        let (data, response) = try await send(request, body: try encoder.encode(fields))
        try checkIsAudio(data, response: response, format: format)
        return data
    }

    // MARK: - Requêtes

    /// `<base>/v1/<path>`. La base peut avoir un `/` final, se terminer par `/v1` ou porter un préfixe de chemin :
    /// dans tous les cas on obtient exactement un `/v1`, sans `//`. La requête et le fragment de la base sont ignorés.
    private func endpointURL(path: [String]) throws -> URL {
        guard var components = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else {
            throw EndpointError.transport("\(EndpointConfig.baseURLVariable) doit être une adresse http(s) complète")
        }
        var segments = components.path.split(separator: "/").map(String.init)
        if segments.last == "v1" { segments.removeLast() }
        components.path = "/" + (segments + ["v1"] + path).joined(separator: "/")
        components.query = nil
        components.fragment = nil
        guard let url = components.url else {
            throw EndpointError.transport("\(EndpointConfig.baseURLVariable) donne une adresse inutilisable")
        }
        return url
    }

    /// Envoie la requête et rend le corps et la réponse d'un statut 2xx. Toute autre issue est une `EndpointError`,
    /// sauf l'annulation de la tâche, qui reste une `CancellationError`.
    private func send(_ request: URLRequest, body: Data) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch {
            throw mapped(error)
        }
        guard let http = response as? HTTPURLResponse else { throw EndpointError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw EndpointError.http(status: http.statusCode, body: errorBody(data))
        }
        return (data, http)
    }

    /// Erreur de `URLSession` (ou levée en cours de lecture) rendue au format du client : l'annulation reste une
    /// `CancellationError`, une `EndpointError` passe telle quelle, tout le reste est une panne de transport.
    private func mapped(_ error: any Error) -> any Error {
        switch error {
        case is CancellationError: return CancellationError()
        case let error as URLError where error.code == .cancelled: return CancellationError()
        case let error as EndpointError: return error
        default: return EndpointError.transport(error.localizedDescription)
        }
    }

    /// Corps d'erreur affichable : la clé est masquée d'abord (une troncature ne doit pas en laisser un morceau),
    /// puis le texte est limité à 500 caractères.
    private func errorBody(_ data: Data) -> String {
        errorBody(String(decoding: data, as: UTF8.self))
    }

    private func errorBody(_ text: String) -> String {
        String(text.replacingOccurrences(of: config.apiKey, with: "***").prefix(500))
    }

    // MARK: - Flux de chat

    private func streamChat(model: String, messages: [ChatMessage], maxTokens: Int,
                            into continuation: AsyncThrowingStream<ChatDelta, Error>.Continuation) async throws {
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

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw EndpointError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count >= Self.errorBodyReadLimit { break }
            }
            throw EndpointError.http(status: http.statusCode, body: errorBody(body))
        }

        var lines = SSELineSplitter()
        var parser = ChatChunkParser(status: http.statusCode, redact: { self.errorBody($0) })
        for try await byte in bytes {
            for line in try lines.push(byte) {
                for delta in try parser.consume(line: line) { continuation.yield(delta) }
                if parser.isDone { return try parser.finishAfterDone() }
            }
        }
        if let last = lines.finish() {
            for delta in try parser.consume(line: last) { continuation.yield(delta) }
            if parser.isDone { return try parser.finishAfterDone() }
        }
        try Task.checkCancellation()
        throw parser.endWithoutDone()
    }

    /// Un corps d'erreur HTTP n'est lu que jusqu'à cette taille : on n'en garde de toute façon que 500 caractères.
    private static let errorBodyReadLimit = 64 * 1024

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

/// Découpe un flux d'octets en lignes selon les règles SSE : fin de ligne `\n`, `\r\n` ou `\r` seul, quelle que soit
/// la façon dont le réseau a coupé les morceaux (un `\r` et son `\n` peuvent arriver séparés).
/// Une ligne est décodée en UTF-8 une fois complète : un caractère coupé en deux par le réseau est recollé.
private struct SSELineSplitter {
    /// Au-delà, la ligne n'est plus un événement de chat : le corps n'est pas un flux utilisable.
    static let maxLineBytes = 1 << 20

    private var line: [UInt8] = []
    private var skipLineFeed = false

    mutating func push(_ byte: UInt8) throws -> [String] {
        switch byte {
        case 0x0D:
            skipLineFeed = true
            return [take()]
        case 0x0A:
            if skipLineFeed { skipLineFeed = false; return [] }
            return [take()]
        default:
            skipLineFeed = false
            line.append(byte)
            if line.count > Self.maxLineBytes { throw EndpointError.malformedResponse }
            return []
        }
    }

    /// La dernière ligne, quand le flux s'arrête sans fin de ligne.
    mutating func finish() -> String? {
        line.isEmpty ? nil : take()
    }

    private mutating func take() -> String {
        defer { line.removeAll(keepingCapacity: true) }
        return String(decoding: line, as: UTF8.self)
    }
}

/// Lit les lignes d'un flux de chat et en tire les morceaux de texte. Une ligne = un événement : les serveurs
/// compatibles n'étalent jamais un objet JSON sur plusieurs lignes `data:`.
private struct ChatChunkParser {
    private let status: Int
    private let redact: (String) -> String
    private(set) var isDone = false
    private var deliveredSomething = false
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
        guard let choice = (object["choices"] as? [Any])?.first as? [String: Any],
              let delta = choice["delta"] as? [String: Any]
        else { return [] }
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
    func finishAfterDone() throws {
        if !deliveredSomething { throw EndpointError.malformedResponse }
    }

    /// L'erreur d'un flux qui s'arrête sans `[DONE]`. Sans aucune ligne `data:`, le corps n'est pas un flux : si c'est
    /// un objet JSON `error`, c'est lui qu'on rend, sinon le corps est mal formé.
    func endWithoutDone() -> EndpointError {
        if sawDataLine || unrecognised.isEmpty { return .streamInterrupted }
        let text = unrecognised.joined(separator: "\n")
        if let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
           let error = object["error"], !(error is NSNull) {
            return .http(status: status, body: redact(text))
        }
        return .malformedResponse
    }
}
