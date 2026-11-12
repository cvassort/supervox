import Foundation
import Testing
@testable import SupervoxCore

// MARK: - Lecture d'un corps multipart

private struct MultipartPart {
    let name: String
    let filename: String?
    let contentType: String?
    let data: Data
}

private func split(_ data: Data, on separator: Data) -> [Data] {
    var parts: [Data] = []
    var rest = data[...]
    while let r = rest.range(of: separator) {
        parts.append(Data(rest[rest.startIndex..<r.lowerBound]))
        rest = rest[r.upperBound...]
    }
    parts.append(Data(rest))
    return parts
}

/// Lit un corps `multipart/form-data` selon la frontière annoncée par l'en-tête `Content-Type`.
/// Renvoie nil si la structure n'est pas celle de la RFC 7578 (ouverture, séparateurs CRLF, clôture `--frontière--`).
private func parseMultipart(_ body: Data, contentType: String?) -> (boundary: String, parts: [MultipartPart])? {
    guard let contentType, contentType.hasPrefix("multipart/form-data"),
          let range = contentType.range(of: "boundary=")
    else { return nil }
    let boundary = String(contentType[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    let opening = Data("--\(boundary)\r\n".utf8)
    let closing = Data("\r\n--\(boundary)--\r\n".utf8)
    guard body.starts(with: opening), body.count >= opening.count + closing.count,
          body.suffix(closing.count) == closing
    else { return nil }
    let inner = body.dropFirst(opening.count).dropLast(closing.count)
    var parts: [MultipartPart] = []
    for chunk in split(Data(inner), on: Data("\r\n--\(boundary)\r\n".utf8)) {
        guard let headerEnd = chunk.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headers = String(decoding: chunk[chunk.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        var name: String?, filename: String?, partType: String?
        for line in headers.components(separatedBy: "\r\n") {
            if line.hasPrefix("Content-Disposition:") {
                name = quotedValue("name", in: line)
                filename = quotedValue("filename", in: line)
            } else if line.hasPrefix("Content-Type:") {
                partType = line.dropFirst("Content-Type:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let name else { return nil }
        parts.append(MultipartPart(name: name, filename: filename, contentType: partType, data: Data(chunk[headerEnd.upperBound...])))
    }
    return (boundary, parts)
}

private func quotedValue(_ key: String, in line: String) -> String? {
    // `; name="x"` : on exige le point-virgule et l'espace devant, pour ne pas confondre `name` et `filename`.
    guard let r = line.range(of: "; \(key)=\"") else { return nil }
    let tail = line[r.upperBound...]
    guard let end = tail.firstIndex(of: "\"") else { return nil }
    return String(tail[..<end])
}

/// Erreur levée par `body`, ou nil si elle n'en lève pas.
private func thrownError(_ body: () async throws -> some Any) async -> (any Error)? {
    do { _ = try await body(); return nil } catch { return error }
}

private let recordedTranscript = "Bonjour, ceci est une phrase de test pour la reconnaissance vocale."
private let transcriptionPath = "/v1/audio/transcriptions"

// MARK: - Tests

@Suite("TranscriptionClientTests", .serialized)
struct TranscriptionClientTests {
    @Test func transcribeReturnsTextFromRecordedResponse() async throws {
        let client = stubbedClient(status: 200, fixture: "transcription-200.json")
        let wav = Data([0x01, 0x00, 0xFF, 0x0D, 0x0A, 0x80])  // octets non UTF-8 et un CRLF : le multipart ne doit pas les altérer
        let text = try await client.transcribe(wav: wav, model: "m", language: "fr", prompt: "FastAPI")
        #expect(text == recordedTranscript)

        let request = try #require(StubURLProtocol.lastRequest(of: client))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://exemple.test\(transcriptionPath)")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k")

        let parsed = try #require(parseMultipart(StubURLProtocol.lastBody(of: client), contentType: request.value(forHTTPHeaderField: "Content-Type")))
        func value(_ name: String) -> String? {
            parsed.parts.first { $0.name == name }.map { String(decoding: $0.data, as: UTF8.self) }
        }
        #expect(parsed.parts.map(\.name) == ["file", "model", "language", "prompt", "response_format"])
        #expect(value("model") == "m")
        #expect(value("language") == "fr")
        #expect(value("prompt") == "FastAPI")
        #expect(value("response_format") == "json")
        let file = try #require(parsed.parts.first { $0.name == "file" })
        #expect(file.data == wav)
        #expect(file.filename == "audio.wav")
        #expect(file.contentType == "audio/wav")
    }

    @Test func nilOrEmptyLanguageAndPromptAreOmitted() async throws {
        for (language, prompt) in [(nil, nil), ("", ""), (nil, ""), ("", nil)] as [(String?, String?)] {
            let client = stubbedClient(status: 200, fixture: "transcription-200.json")
            _ = try await client.transcribe(wav: Data([1]), model: "m", language: language, prompt: prompt)
            let request = try #require(StubURLProtocol.lastRequest(of: client))
            let parsed = try #require(parseMultipart(StubURLProtocol.lastBody(of: client), contentType: request.value(forHTTPHeaderField: "Content-Type")))
            #expect(parsed.parts.map(\.name) == ["file", "model", "response_format"], "language=\(String(describing: language)) prompt=\(String(describing: prompt))")
        }
    }

    @Test func transcribeMapsHTTPErrors() async throws {
        let unauthorized = fixtureString("transcription-401.json")
        #expect(unauthorized.contains("AuthenticationError"))  // la fixture n'est pas vide et vient bien d'un refus d'authentification
        // Clé réaliste : avec la clé « k » du helper, le masquage de la clé réécrirait chaque « k » du corps (« To***en »).
        let e401 = await thrownError { try await stubbedClient(status: 401, fixture: "transcription-401.json", apiKey: "cle-de-test-0123").transcribe(wav: Data(), model: "m", language: nil, prompt: nil) }
        #expect(e401 as? EndpointError == .http(status: 401, body: unauthorized))

        await #expect(throws: EndpointError.http(status: 503, body: "{\"error\":\"Internal Server Error\"}")) {
            try await stubbedClient(status: 503, body: "{\"error\":\"Internal Server Error\"}").transcribe(wav: Data(), model: "m", language: nil, prompt: nil)
        }
        await #expect(throws: EndpointError.malformedResponse) {
            try await stubbedClient(status: 200, body: "<html>").transcribe(wav: Data(), model: "m", language: nil, prompt: nil)
        }
    }

    /// Le serveur de transcription renvoie un espace en tête de transcription (présent dans la fixture enregistrée) : le client le retire,
    /// ainsi que les retours à la ligne éventuels.
    @Test func transcriptIsTrimmed() async throws {
        #expect(fixtureString("transcription-200.json").contains("\"text\":\" Bonjour"))
        let text = try await stubbedClient(status: 200, body: "{\"text\":\"\\n  Salut à tous \\n\"}").transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil)
        #expect(text == "Salut à tous")
    }

    /// Un passage sans parole donne un texte vide valide : ce n'est pas une réponse malformée.
    @Test func emptyTextIsAValidTranscript() async throws {
        let text = try await stubbedClient(status: 200, body: "{\"text\":\"\"}").transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil)
        #expect(text == "")
    }

    @Test(arguments: [
        "{}", "{\"text\":null}", "{\"text\":42}", "{\"text\":[\"a\"]}", "{\"texte\":\"a\"}",
        "[]", "[{\"text\":\"a\"}]", "\"a\"", "", "{\"text\":",
    ])
    func missingOrNonStringTextIsMalformed(body: String) async {
        let error = await thrownError { try await stubbedClient(status: 200, body: body).transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil) }
        #expect(error as? EndpointError == .malformedResponse, "corps : \(body)")
    }

    /// Une URL de base peut être donnée avec ou sans `/` final, avec ou sans `/v1` : la requête part toujours
    /// vers `<base>/v1/audio/transcriptions`, sans `//` ni `/v1/v1`.
    @Test(arguments: [
        ("https://exemple.test", "https://exemple.test/v1/audio/transcriptions"),
        ("https://exemple.test/", "https://exemple.test/v1/audio/transcriptions"),
        ("https://exemple.test//", "https://exemple.test/v1/audio/transcriptions"),
        ("https://exemple.test/v1", "https://exemple.test/v1/audio/transcriptions"),
        ("https://exemple.test/v1/", "https://exemple.test/v1/audio/transcriptions"),
        ("https://exemple.test:8443/v1", "https://exemple.test:8443/v1/audio/transcriptions"),
        ("https://exemple.test/passerelle", "https://exemple.test/passerelle/v1/audio/transcriptions"),
        ("https://exemple.test/passerelle/v1/", "https://exemple.test/passerelle/v1/audio/transcriptions"),
        ("https://exemple.test/v10", "https://exemple.test/v10/v1/audio/transcriptions"),
    ])
    func baseURLShapesReachTheSamePath(base: String, expected: String) async throws {
        let client = stubbedClient(status: 200, body: "{\"text\":\"ok\"}", baseURL: base)
        _ = try await client.transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil)
        #expect(StubURLProtocol.lastRequest(of: client)?.url?.absoluteString == expected)
    }

    /// Une adresse sans schéma (`exemple.test`) est refusée avant toute requête.
    @Test func baseURLWithoutSchemeFailsBeforeAnyRequest() async {
        let client = stubbedClient(status: 200, body: "{\"text\":\"ok\"}", baseURL: "exemple.test")
        let error = await thrownError { try await client.transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil) }
        guard case .transport(let message)? = error as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: error))")
            return
        }
        #expect(!message.isEmpty)
        #expect(StubURLProtocol.lastRequest(of: client) == nil)
    }

    @Test func networkFailureIsMappedToTransport() async {
        let client = stubbedClient(failure: .notConnectedToInternet)
        let error = await thrownError { try await client.transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil) }
        guard case .transport(let message)? = error as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: error))")
            return
        }
        #expect(!message.isEmpty)
        #expect(StubURLProtocol.lastRequest(of: client) != nil)  // la requête est bien partie : c'est le réseau qui a échoué
    }

    /// Une requête annulée (Ctrl-C, délai d'une tâche parente) n'est pas une panne réseau : on propage l'annulation.
    @Test func cancelledRequestPropagatesCancellation() async {
        let client = stubbedClient(failure: .cancelled)
        let error = await thrownError { try await client.transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil) }
        #expect(error is CancellationError)
    }

    @Test(arguments: [(500, 500), (501, 500), (2000, 500), (499, 499)])
    func errorBodyIsTruncatedTo500Characters(length: Int, kept: Int) async {
        let body = String(repeating: "x", count: length)
        let error = await thrownError { try await stubbedClient(status: 500, body: body).transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil) }
        #expect(error as? EndpointError == .http(status: 500, body: String(repeating: "x", count: kept)))
    }

    /// On compte des caractères, pas des octets : couper au milieu d'un « é » donnerait un texte invalide.
    @Test func errorBodyTruncationCountsCharactersNotBytes() async {
        let body = String(repeating: "é", count: 600)
        let error = await thrownError { try await stubbedClient(status: 502, body: body).transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil) }
        #expect(error as? EndpointError == .http(status: 502, body: String(repeating: "é", count: 500)))
    }

    /// Un serveur peut renvoyer la clé dans son message d'erreur : elle est masquée avant de sortir du client,
    /// y compris quand la troncature tomberait au milieu d'elle.
    @Test func errorBodyNeverContainsTheKey() async {
        let echoed = "{\"error\":\"Incorrect API key provided: secret-123\"}"
        let e1 = await thrownError { try await stubbedClient(status: 401, body: echoed, apiKey: "secret-123").transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil) }
        #expect(e1 as? EndpointError == .http(status: 401, body: "{\"error\":\"Incorrect API key provided: ***\"}"))

        let straddling = String(repeating: "x", count: 497) + "secret-123" + String(repeating: "y", count: 100)
        let e2 = await thrownError { try await stubbedClient(status: 401, body: straddling, apiKey: "secret-123").transcribe(wav: Data([1]), model: "m", language: nil, prompt: nil) }
        #expect(e2 as? EndpointError == .http(status: 401, body: String(repeating: "x", count: 497) + "***"))
    }
}
