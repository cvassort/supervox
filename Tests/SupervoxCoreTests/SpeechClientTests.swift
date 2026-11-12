import Foundation
import Testing
@testable import SupervoxCore

/// Erreur levée par `body`, ou nil si elle n'en lève pas.
private func thrownError(_ body: () async throws -> some Any) async -> (any Error)? {
    do { _ = try await body(); return nil } catch { return error }
}

private func speak(_ client: OpenAICompatibleClient, format: String = "wav", extra: [String: String] = [:]) async throws -> Data {
    try await client.speech(model: "m", input: "Bonjour", voice: "v", format: format, extra: extra)
}

private func sentJSON(_ client: OpenAICompatibleClient) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody(of: client)) as? [String: Any])
}

@Suite("SpeechClientTests", .serialized)
struct SpeechClientTests {
    @Test func speechSendsExtraParametersAtTopLevel() async throws {
        let client = stubbedClient(status: 200, fixture: "speech-200.wav")
        let data = try await client.speech(model: "m", input: "Bonjour", voice: "v", format: "wav", extra: ["lang_code": "f"])
        #expect(data == fixtureData("speech-200.wav"))
        #expect(data.count > 44)
        let json = try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody(of: client)) as? [String: Any]
        #expect(json?["lang_code"] as? String == "f" && json?["input"] as? String == "Bonjour" && json?["voice"] as? String == "v")
    }

    @Test func speechRejectsEmptyAudio() async {
        await #expect(throws: EndpointError.malformedResponse) {
            try await stubbedClient(status: 200, body: "").speech(model: "m", input: "x", voice: "v", format: "wav", extra: [:])
        }
    }

    @Test func requestIsAJSONPostToTheSpeechPathWithExactlyTheExpectedFields() async throws {
        let client = stubbedClient(status: 200, fixture: "speech-200.wav", baseURL: "https://exemple.test/v1", apiKey: "cle-de-test-0123")
        _ = try await speak(client, extra: ["lang_code": "f"])
        let request = try #require(StubURLProtocol.lastRequest(of: client))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://exemple.test/v1/audio/speech")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cle-de-test-0123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let json = try sentJSON(client)
        #expect(json as? [String: String] == ["model": "m", "input": "Bonjour", "voice": "v", "response_format": "wav", "lang_code": "f"])

        let bare = stubbedClient(status: 200, fixture: "speech-200.wav")
        _ = try await speak(bare)
        #expect(Set(try sentJSON(bare).keys) == ["model", "input", "voice", "response_format"])
    }

    /// `extra` ne remplace ni `model`, ni `input`, ni `voice`. `response_format` non plus : le format demandé est celui
    /// de l'argument `format`, celui que l'appelant s'attend à recevoir.
    @Test func extraParametersCannotOverwriteTheExplicitArguments() async throws {
        let client = stubbedClient(status: 200, fixture: "speech-200.wav")
        let extra = ["model": "intrus", "input": "intrus", "voice": "intrus", "response_format": "mp3", "lang_code": "f"]
        _ = try await client.speech(model: "m", input: "Bonjour", voice: "v", format: "wav", extra: extra)
        let json = try sentJSON(client)
        #expect(json as? [String: String] == ["model": "m", "input": "Bonjour", "voice": "v", "response_format": "wav", "lang_code": "f"])
    }

    @Test func textIsSentAsValidJSONWhateverItContains() async throws {
        let client = stubbedClient(status: 200, fixture: "speech-200.wav")
        let text = "L'été à « Paris » : \"ok\", \\ / retour\nligne 😀"
        _ = try await client.speech(model: "m", input: text, voice: "v", format: "wav", extra: [:])
        #expect(try sentJSON(client)["input"] as? String == text)
    }

    // MARK: Un corps 2xx qui n'est pas de l'audio

    @Test func jsonErrorWithStatus200IsAnErrorNotAudio() async {
        let body = "{\"error\":{\"message\":\"voix inconnue\"}}"
        let e1 = await thrownError { try await speak(stubbedClient(status: 200, body: body)) }
        #expect(e1 as? EndpointError == .http(status: 200, body: body))
        // Même chose en PCM brut (aucun contrôle d'en-tête WAV) et avec un en-tête qui l'annonce.
        let e2 = await thrownError { try await speak(stubbedClient(status: 200, body: body), format: "pcm") }
        #expect(e2 as? EndpointError == .http(status: 200, body: body))
        let e3 = await thrownError { try await speak(stubbedClient(status: 200, data: Data(body.utf8), headers: ["Content-Type": "application/json"]), format: "mp3") }
        #expect(e3 as? EndpointError == .http(status: 200, body: body))
    }

    @Test func keyIsHiddenInAJSONErrorReturnedWithStatus200() async {
        let body = "{\"error\":\"clé cle-de-test-0123 invalide\"}"
        let error = await thrownError { try await speak(stubbedClient(status: 200, body: body, apiKey: "cle-de-test-0123")) }
        #expect(error as? EndpointError == .http(status: 200, body: "{\"error\":\"clé *** invalide\"}"))
    }

    @Test(arguments: [
        "{\"result\":\"ok\"}", "[]", "[1,2]", "{\"error\":null}",
        "<html>Bienvenue</html>", "Service indisponible", " \n",
    ])
    func jsonOrTextBodyWithoutAnErrorIsMalformedNotAudio(body: String) async {
        for format in ["wav", "pcm", "mp3"] {
            let isJSON = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) != nil
            let client = stubbedClient(status: 200, data: Data(body.utf8), headers: ["Content-Type": isJSON ? "application/json" : "text/html"])
            let error = await thrownError { try await speak(client, format: format) }
            #expect(error as? EndpointError == .malformedResponse, "format \(format), corps \(body)")
        }
    }

    @Test func textWithoutWavHeaderIsRejectedForWavEvenWithoutContentType() async {
        let error = await thrownError { try await speak(stubbedClient(status: 200, body: "Service indisponible")) }
        #expect(error as? EndpointError == .malformedResponse)
        // Un en-tête RIFF sans WAVE n'est pas un WAV non plus.
        let riff = Data("RIFF\0\0\0\0AVI LIST".utf8)
        let error2 = await thrownError { try await speak(stubbedClient(status: 200, data: riff, headers: [:])) }
        #expect(error2 as? EndpointError == .malformedResponse)
    }

    /// Du PCM brut n'a pas d'en-tête et peut commencer par `{` (0x7B) : c'est de l'audio tant qu'il ne forme pas un
    /// document JSON. De même, un MP3 n'est pas contrôlé comme un WAV.
    @Test func rawAudioStartingLikeJSONIsStillAudio() async throws {
        let pcm = Data([0x7B, 0x00, 0x22, 0x01, 0x7D, 0xFF, 0x00, 0x80])
        #expect(try await speak(stubbedClient(status: 200, data: pcm, headers: ["Content-Type": "audio/pcm"]), format: "pcm") == pcm)
        let mp3 = Data("ID3".utf8) + Data([4, 0, 0, 0, 0, 0, 0x21, 0xFF, 0xFB, 0x90, 0x00])
        #expect(try await speak(stubbedClient(status: 200, data: mp3, headers: ["Content-Type": "audio/mpeg"]), format: "mp3") == mp3)
    }

    // MARK: Erreurs

    @Test func httpErrorTransportFailureAndCancellationAreMapped() async {
        let e1 = await thrownError { try await speak(stubbedClient(status: 500, body: "{\"error\":\"panne\"}")) }
        #expect(e1 as? EndpointError == .http(status: 500, body: "{\"error\":\"panne\"}"))
        let e2 = await thrownError { try await speak(stubbedClient(failure: .notConnectedToInternet)) }
        guard case .transport? = e2 as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: e2))")
            return
        }
        let e3 = await thrownError { try await speak(stubbedClient(failure: .cancelled)) }
        #expect(e3 is CancellationError)
        let client = stubbedClient(status: 200, fixture: "speech-200.wav", baseURL: "exemple.test")
        let e4 = await thrownError { try await speak(client) }
        guard case .transport? = e4 as? EndpointError else {
            Issue.record("attendu .transport, reçu \(String(describing: e4))")
            return
        }
        #expect(StubURLProtocol.requestCount(of: client) == 0)
    }

    @Test func httpErrorBodyHidesTheKeyAndIsTruncated() async {
        let body = String(repeating: "x", count: 497) + "cle-de-test-0123" + String(repeating: "y", count: 100)
        let error = await thrownError { try await speak(stubbedClient(status: 401, body: body, apiKey: "cle-de-test-0123")) }
        #expect(error as? EndpointError == .http(status: 401, body: String(repeating: "x", count: 497) + "***"))
    }
}
