import Foundation

/// Ce que les clients d'un endpoint ont en commun : l'adresse `<base>/v1/…`, la conversion des erreurs et le masquage
/// de la clé. Interne : aucun client n'est tenu de passer par là, mais aucun ne doit réécrire ces règles.
struct EndpointRequest: Sendable {
    let config: EndpointConfig
    let session: URLSession

    /// Un corps d'erreur HTTP n'est lu que jusqu'à cette taille : on n'en garde de toute façon que 500 caractères.
    static let errorBodyReadLimit = 64 * 1024

    /// `<base>/v1/<path>`. La base peut avoir un `/` final, se terminer par `/v1` ou porter un préfixe de chemin :
    /// dans tous les cas on obtient exactement un `/v1`, sans `//`. La requête, le fragment et les identifiants de la base sont ignorés.
    func url(path: [String]) throws -> URL {
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
        // Des identifiants écrits dans l'adresse ne partent jamais : la clé voyage dans son en-tête, comme pour la liste des modèles.
        components.user = nil
        components.password = nil
        guard let url = components.url else {
            throw EndpointError.transport("\(EndpointConfig.baseURLVariable) donne une adresse inutilisable")
        }
        return url
    }

    /// Erreur de `URLSession` (ou levée en cours de lecture) rendue au format des clients : l'annulation reste une
    /// `CancellationError`, une `EndpointError` passe telle quelle, tout le reste est une panne de transport.
    /// `timeoutAs` : ce que devient un silence (`URLError.timedOut`) ; sans lui, c'est une panne de transport comme une
    /// autre. Le texte d'une panne de transport est masqué comme un corps d'erreur : la clé n'en sort jamais.
    func mapped(_ error: any Error, timeoutAs: (any Error)? = nil) -> any Error {
        switch error {
        case is CancellationError: return CancellationError()
        case let error as URLError where error.code == .cancelled: return CancellationError()
        case let error as EndpointError: return error
        case let error as CompletionError: return error
        case let error as URLError where error.code == .timedOut && timeoutAs != nil: return timeoutAs!
        default: return EndpointError.transport(errorBody(error.localizedDescription))
        }
    }

    /// Corps d'erreur affichable : la clé est masquée d'abord (une troncature ne doit pas en laisser un morceau),
    /// puis le texte est limité à 500 caractères.
    func errorBody(_ data: Data) -> String {
        errorBody(String(decoding: data, as: UTF8.self))
    }

    func errorBody(_ text: String) -> String {
        String(text.replacingOccurrences(of: config.apiKey, with: "***").prefix(500))
    }
}

/// Lit les lignes d'un flux SSE et en tire des événements. Une ligne = un événement : les serveurs ne répartissent
/// jamais un objet JSON sur plusieurs lignes `data:`.
protocol SSEReader: SendableMetatype {
    associatedtype Event: Sendable

    /// Le marqueur de fin du flux est passé : plus rien n'est lu.
    var isDone: Bool { get }
    mutating func consume(line: String) throws -> [Event]
    /// Appelé une fois, après le marqueur de fin : les derniers événements, ou l'erreur d'une fin sans contenu.
    mutating func finishAfterDone() throws -> [Event]
    /// L'erreur d'un flux qui s'arrête sans marqueur de fin.
    func endWithoutDone() -> any Error
}

extension EndpointRequest {
    /// Réponse en flux d'une requête POST : un `AsyncThrowingStream` des événements que `makeReader` tire des lignes SSE.
    ///
    /// Le flux se termine normalement seulement après le marqueur de fin du lecteur ; toute autre fin est une erreur :
    /// statut hors 2xx (`.http`), redirection vers une autre origine, panne réseau (`.transport`, ou `timeoutAs` pour
    /// un silence), coupure avant le marqueur (`endWithoutDone`). L'arrêt de la lecture (boucle quittée, tâche annulée)
    /// annule la requête. La requête part dès l'appel, pas à la première itération.
    func events<Reader: SSEReader>(
        request makeRequest: @escaping @Sendable () throws -> URLRequest,
        reader makeReader: @escaping @Sendable (_ status: Int, _ redact: @escaping (String) -> String) -> Reader,
        timeoutAs: (any Error)? = nil
    ) -> AsyncThrowingStream<Reader.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.read(try makeRequest(), makeReader: makeReader, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapped(error, timeoutAs: timeoutAs))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func read<Reader: SSEReader>(
        _ request: URLRequest,
        makeReader: @Sendable (Int, @escaping (String) -> String) -> Reader,
        into continuation: AsyncThrowingStream<Reader.Event, Error>.Continuation
    ) async throws {
        let delegate = EndpointTaskDelegate()
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        if delegate.refusedRedirect { throw EndpointError.crossOriginRedirect }
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
        var reader = makeReader(http.statusCode, { self.errorBody($0) })
        for try await byte in bytes {
            for line in try lines.push(byte) {
                for event in try reader.consume(line: line) { continuation.yield(event) }
                if reader.isDone { return try finish(&reader, into: continuation) }
            }
        }
        if let last = lines.finish() {
            for event in try reader.consume(line: last) { continuation.yield(event) }
            if reader.isDone { return try finish(&reader, into: continuation) }
        }
        try Task.checkCancellation()
        throw reader.endWithoutDone()
    }

    private func finish<Reader: SSEReader>(_ reader: inout Reader,
                                           into continuation: AsyncThrowingStream<Reader.Event, Error>.Continuation) throws {
        for event in try reader.finishAfterDone() { continuation.yield(event) }
    }
}

/// Découpe un flux d'octets en lignes selon les règles SSE : fin de ligne `\n`, `\r\n` ou `\r` seul, quelle que soit
/// la façon dont le réseau a coupé les morceaux (un `\r` et son `\n` peuvent arriver séparés).
/// Une ligne est décodée en UTF-8 une fois complète : un caractère coupé en deux par le réseau est recollé.
struct SSELineSplitter {
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
