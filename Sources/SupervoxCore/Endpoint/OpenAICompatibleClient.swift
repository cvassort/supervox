import Foundation

/// Client d'un endpoint HTTP compatible OpenAI. Aucun nom de fournisseur ni de modèle : tout vient de `EndpointConfig`
/// et des arguments des appels.
public final class OpenAICompatibleClient: Sendable {
    private let config: EndpointConfig
    private let session: URLSession

    public init(config: EndpointConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
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
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        let data = try await send(request, body: form.finished())

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let text = object["text"] as? String
        else { throw EndpointError.malformedResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Envoie la requête et rend le corps d'une réponse 2xx. Toute autre issue est une `EndpointError`,
    /// sauf l'annulation de la tâche, qui reste une `CancellationError`.
    private func send(_ request: URLRequest, body: Data) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, from: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw EndpointError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw EndpointError.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw EndpointError.http(status: http.statusCode, body: errorBody(data))
        }
        return data
    }

    /// Corps d'erreur affichable : la clé est masquée d'abord (une troncature ne doit pas en laisser un morceau),
    /// puis le texte est limité à 500 caractères.
    private func errorBody(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: config.apiKey, with: "***")
        return String(text.prefix(500))
    }
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
