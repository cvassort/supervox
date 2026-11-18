import Foundation
import os
import Testing
@testable import SupervoxCore

/// Un point d'accès double : il enregistre chaque requête et rend l'octets configuré (ou lève).
private final class RecordingEndpoint: SpeechEndpoint, @unchecked Sendable {
    struct Request: Equatable { var model, input, voice, format: String; var extra: [String: String] }
    private let state = OSAllocatedUnfairLock(initialState: [Request]())
    var reply: @Sendable () async throws -> Data
    init(reply: @escaping @Sendable () async throws -> Data) { self.reply = reply }
    var requests: [Request] { state.withLock { $0 } }

    func speech(model: String, input: String, voice: String, format: String, extra: [String: String]) async throws -> Data {
        state.withLock { $0.append(Request(model: model, input: input, voice: voice, format: format, extra: extra)) }
        return try await reply()
    }
}

private let exampleVoice = ProviderVoice(model: "modele-exemple", identifier: "voix-exemple", extra: ["cle_exemple": "f", "vitesse": "1.1"])

private func wav(_ samples: [Float], rate: Double = 24000) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try WavFile.write(AudioClip(samples: samples, sampleRate: rate), to: url)
    return try Data(contentsOf: url)
}

@Suite struct ProviderSpeechTests {
    /// Règle 4 : la requête porte le modèle, la voix, le format `wav`, le texte et `extra` tel quel.
    @Test func theRequestCarriesTheModelTheVoiceTheWavFormatTheTextAndExtraAsIs() async throws {
        let data = try wav([0.1, 0.2])
        let endpoint = RecordingEndpoint { data }
        _ = try await ProviderSpeechSynthesizer(endpoint: endpoint, voice: exampleVoice).synthesize("Bonjour à tous")
        #expect(endpoint.requests == [.init(model: "modele-exemple", input: "Bonjour à tous", voice: "voix-exemple", format: "wav",
                                            extra: ["cle_exemple": "f", "vitesse": "1.1"])])
    }

    @Test func aWavReplyIsDecodedIntoTheClipAndIsNotAFallback() async throws {
        let samples = (0..<480).map { Float(sin(Double($0) * 0.2)) * 0.5 }
        let data = try wav(samples, rate: 24000)
        let speech = try await ProviderSpeechSynthesizer(endpoint: RecordingEndpoint { data }, voice: exampleVoice).synthesize("Bonjour")
        #expect(speech.clip.sampleRate == 24000 && speech.clip.samples.count == 480)
        #expect(zip(samples, speech.clip.samples).allSatisfy { abs($0 - $1) < 1.0 / 16384 })
        #expect(!speech.fellBack)
    }

    /// Un fournisseur en flux annonce une taille provisoire : les octets sont lus jusqu'au bout.
    @Test func aStreamedWavWithAProvisionalSizeIsReadToTheEnd() async throws {
        var streamed = try wav([0.25, -0.25, 0.5, 0.0, 0.1, 0.2])
        streamed.replaceSubrange(40..<44, with: [0xFF, 0xFF, 0xFF, 0xFF])
        let data = streamed
        let speech = try await ProviderSpeechSynthesizer(endpoint: RecordingEndpoint { data }, voice: exampleVoice).synthesize("Bonjour")
        #expect(speech.clip.samples.count == 6)
    }

    @Test func bytesThatAreNotAWavThrowTheWavFileError() async {
        let endpoint = RecordingEndpoint { Data("<html>pas du son</html>".utf8) }
        await #expect(throws: WavFileError.notAWavFile) {
            try await ProviderSpeechSynthesizer(endpoint: endpoint, voice: exampleVoice).synthesize("Bonjour")
        }
    }

    @Test func aWavWithoutSamplesThrowsEmpty() async throws {
        let data = try wav([])
        await #expect(throws: SpeechError.empty) {
            try await ProviderSpeechSynthesizer(endpoint: RecordingEndpoint { data }, voice: exampleVoice).synthesize("Bonjour")
        }
    }

    @Test func aBlankTextThrowsEmptyWithoutAnyRequest() async {
        let endpoint = RecordingEndpoint { Data() }
        await #expect(throws: SpeechError.empty) {
            try await ProviderSpeechSynthesizer(endpoint: endpoint, voice: exampleVoice).synthesize(" \n")
        }
        #expect(endpoint.requests.isEmpty)
    }

    @Test func anEndpointFailureIsThrownAsIs() async {
        let endpoint = RecordingEndpoint { throw EndpointError.http(status: 503, body: "") }
        await #expect(throws: EndpointError.http(status: 503, body: "")) {
            try await ProviderSpeechSynthesizer(endpoint: endpoint, voice: exampleVoice).synthesize("Bonjour")
        }
    }

    @Test(.timeLimit(.minutes(1))) func aCancelledTaskThrowsCancellation() async {
        let started = Gate()
        let endpoint = RecordingEndpoint {
            started.open()
            try await Task.sleep(for: .seconds(1_000_000))
            return Data()
        }
        let task = Task { try await ProviderSpeechSynthesizer(endpoint: endpoint, voice: exampleVoice).synthesize("Bonjour") }
        await started.wait()
        task.cancel()
        #expect((await outcome(task)).failureValue is CancellationError)
    }

    /// Un point d'accès sourd rend ses octets alors que la tâche est annulée : la parole n'est pas livrée (branche
    /// `Task.checkCancellation()` du fournisseur).
    @Test(.timeLimit(.minutes(1))) func anEndpointThatIgnoresTheCancellationDoesNotDeliverASpeech() async throws {
        let data = try wav([0.1, 0.2])
        let latch = DeafLatch(), started = Gate()
        let endpoint = RecordingEndpoint { started.open(); await latch.wait(); return data }
        let task = Task { try await ProviderSpeechSynthesizer(endpoint: endpoint, voice: exampleVoice).synthesize("Bonjour") }
        await started.wait()
        task.cancel()
        latch.open()
        #expect((await outcome(task)).failureValue is CancellationError)
    }

    /// Une panne quelconque levée parce qu'on annule (ici une erreur de point d'accès, pas une `CancellationError`) reste une
    /// annulation pour l'appelant (branche `Task.isCancelled` du `catch`).
    @Test(.timeLimit(.minutes(1))) func anyErrorRaisedWhileCancelledIsReportedAsCancellation() async {
        let latch = DeafLatch(), started = Gate()
        let endpoint = RecordingEndpoint { started.open(); await latch.wait(); throw EndpointError.http(status: 503, body: "") }
        let task = Task { try await ProviderSpeechSynthesizer(endpoint: endpoint, voice: exampleVoice).synthesize("Bonjour") }
        await started.wait()
        task.cancel()
        latch.open()
        #expect((await outcome(task)).failureValue is CancellationError)
    }

    /// Fréquence hors de 8 000 à 192 000 Hz (choix non mesuré) : une erreur nommée, donc le repli, et non un clip muet.
    @Test(arguments: [4000, 7999, 192_001, 384_000])
    func aSampleRateOutsideTheAcceptedRangeIsRefusedByName(rate: Int) async throws {
        let data = try wav([0.1, 0.2, 0.3], rate: Double(rate))
        do {
            _ = try await ProviderSpeechSynthesizer(endpoint: RecordingEndpoint { data }, voice: exampleVoice).synthesize("Bonjour")
            Issue.record("fréquence \(rate) acceptée")
        } catch let error as WavFileError {
            if case .unsupported = error {} else { Issue.record("autre erreur : \(error)") }
        }
    }

    @Test(arguments: [8000, 16000, 24000, 48000, 192_000])
    func aSampleRateInsideTheAcceptedRangeIsAccepted(rate: Int) async throws {
        let data = try wav([0.1, 0.2, 0.3], rate: Double(rate))
        let speech = try await ProviderSpeechSynthesizer(endpoint: RecordingEndpoint { data }, voice: exampleVoice).synthesize("Bonjour")
        #expect(speech.clip.sampleRate == Double(rate))
    }

    /// Un fournisseur qui répond une fréquence absurde fait basculer sur la voix de secours (au lieu d'un clip muet joué en silence).
    @Test func anAbsurdSampleRateMakesTheFallbackSpeak() async throws {
        let absurd = try wav([0.1, 0.2, 0.3], rate: 1)
        let fallback = SystemSpeechSynthesizer(language: "fr-FR", voices: { [SystemVoiceInfo(identifier: "v", language: "fr-FR", quality: 1)] },
                                               render: { _, _ in [AudioClip(samples: [0.5], sampleRate: 8000)] })
        let voice = FallbackSpeechSynthesizer(primary: ProviderSpeechSynthesizer(endpoint: RecordingEndpoint { absurd }, voice: exampleVoice),
                                              fallback: fallback)
        #expect(try await voice.synthesize("Bonjour").fellBack)
    }

    /// Un texte blanc n'est pas une panne de la voix du fournisseur : la phrase suivante lui revient (une seule requête, la sienne).
    @Test func aBlankSentenceDoesNotDiscardTheProviderVoiceForTheRestOfTheInterview() async throws {
        let data = try wav([0.1, 0.2])
        let endpoint = RecordingEndpoint { data }
        let rendered = OSAllocatedUnfairLock(initialState: 0)
        let system = SystemSpeechSynthesizer(language: "fr-FR", voices: { [SystemVoiceInfo(identifier: "v", language: "fr-FR", quality: 1)] },
                                             render: { _, _ in rendered.withLock { $0 += 1 }; return [AudioClip(samples: [0.5], sampleRate: 8000)] })
        let voice = FallbackSpeechSynthesizer(primary: ProviderSpeechSynthesizer(endpoint: endpoint, voice: exampleVoice), fallback: system)

        await #expect(throws: SpeechError.empty) { try await voice.synthesize("  ") }
        let next = try await voice.synthesize("Suite")

        #expect(!next.fellBack)
        #expect(endpoint.requests.map(\.input) == ["Suite"])
        #expect(rendered.withLock { $0 } == 0)
    }

    /// Le client réel est un point d'accès de synthèse (compilation) et sa réponse passe par le décodeur : un client rejoué.
    @Test func theOpenAICompatibleClientIsASpeechEndpoint() {
        let endpoint: any SpeechEndpoint = stubbedClient(status: 200, fixture: "speech-200.wav")
        #expect(endpoint is OpenAICompatibleClient)
    }
}

@Suite("ProviderSpeechClientTests", .serialized)
struct ProviderSpeechClientTests {
    @Test func theRealClientRepliesWithAClipTheProviderVoiceCanDecode() async throws {
        let client = stubbedClient(status: 200, fixture: "speech-200.wav")
        let speech = try await ProviderSpeechSynthesizer(endpoint: client, voice: exampleVoice).synthesize("Bonjour")
        #expect(speech.clip.sampleRate == 24000 && speech.clip.samples.count == 106_200)
        let json = try #require(try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody(of: client)) as? [String: String])
        #expect(json == ["model": "modele-exemple", "input": "Bonjour", "voice": "voix-exemple", "response_format": "wav",
                         "cle_exemple": "f", "vitesse": "1.1"])
    }
}
