import Foundation
import SupervoxCore
import SupervoxEngines
import Testing

// Vrais moteurs, vrais modèles (téléchargés au premier passage : de quelques centaines de Mo à quelques Go).
// Activé seulement avec SUPERVOX_INTEGRATION=1. Les moteurs passent un par un : en parallèle, ils se disputeraient
// le Neural Engine et la mémoire, et les durées affichées ne voudraient rien dire.

private let sentence = "Bonjour, ceci est un test de transcription."
/// 7 mots après normalisation : 0,34 laisse passer au plus 2 mots faux (2/7 ≈ 0,29 ; 3/7 ≈ 0,43).
private let maximumRate = 0.34

/// La phrase lue par la voix française `Thomas` de `say`, en WAV 16 kHz mono.
private func synthesizedSentence() throws -> AudioClip {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sv-say-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Thomas", "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", sentence]
    try say.run()
    say.waitUntilExit()
    try #require(say.terminationStatus == 0, "say a échoué")
    let clip = try WavFile.read(url)
    return clip.sampleRate == transcriberSampleRate ? clip : Resampler.resample(clip, to: transcriberSampleRate)
}

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// Charge le moteur, transcrit deux fois la même phrase et vérifie le taux d'erreur des deux transcriptions.
/// Affiche les durées : chargement, 1er appel, 2e appel. Rend la transcription.
@discardableResult
private func measure(_ engine: any Transcriber, label: String, clip: AudioClip, vocabulary: [String] = []) async throws -> String {
    let clock = ContinuousClock()
    var start = clock.now
    try await engine.prepare()
    let prepare = seconds(start.duration(to: clock.now))

    var texts: [String] = []
    var times: [Double] = []
    for _ in 0..<2 {
        start = clock.now
        texts.append(try await engine.transcribe(clip, language: "fr", vocabulary: vocabulary))
        times.append(seconds(start.duration(to: clock.now)))
    }
    print(String(format: "[intégration] %@ : prepare %.2f s, 1er appel %.3f s, 2e appel %.3f s, audio %.2f s",
                 label, prepare, times[0], times[1], clip.duration))
    for text in texts {
        let rate = WordErrorRate.compute(reference: sentence, hypothesis: text).rate
        print("[intégration] \(label) : « \(text) » (taux \(String(format: "%.3f", rate)))")
        #expect(rate <= maximumRate, "\(label) : « \(text) »")
        #expect(!text.contains("<|"), "jeton spécial dans le texte : « \(text) »")
    }
    return texts[0]
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_INTEGRATION"] == "1"))
struct EngineIntegrationTests {
    /// Sans passage à vide, puis avec : le premier appel du moteur froid montre ce que `prepare()` doit absorber.
    @Test func whisperKit() async throws {
        let clip = try synthesizedSentence()
        try await measure(WhisperKitTranscriber(model: "large-v3-v20240930_turbo", warmUp: false), label: "whisperkit (froid)", clip: clip)
        let engine = WhisperKitTranscriber(model: "large-v3-v20240930_turbo")
        try await measure(engine, label: "whisperkit", clip: clip)
        // Des termes absents de la phrase, en amorce : ils ne doivent pas ressortir dans le texte, sinon la ligne
        // « +vocab » gagnerait un rappel des termes immérité.
        let primed = try await measure(engine, label: "whisperkit+vocab", clip: clip, vocabulary: ["Kubernetes", "PostgreSQL"])
        #expect(!primed.localizedCaseInsensitiveContains("kubernetes") && !primed.localizedCaseInsensitiveContains("postgresql"))
    }

    @Test func parakeet() async throws {
        let clip = try synthesizedSentence()
        try await measure(ParakeetTranscriber(warmUp: false), label: "parakeet (froid)", clip: clip)
        try await measure(ParakeetTranscriber(), label: "parakeet", clip: clip)
    }

    @Test func appleSpeech() async throws {
        let clip = try synthesizedSentence()
        try await measure(AppleSpeechTranscriber(locale: "fr-FR", warmUp: false), label: "apple (froid)", clip: clip)
        try await measure(AppleSpeechTranscriber(locale: "fr-FR"), label: "apple", clip: clip)
    }

    /// Une locale que le framework ne propose pas fait échouer `prepare()` : pas de repli silencieux sur une autre.
    @Test func appleSpeechRejectsUnsupportedLocale() async {
        await #expect(throws: TranscriberError.unsupportedLocale("zz-ZZ")) {
            try await AppleSpeechTranscriber(locale: "zz-ZZ").prepare()
        }
    }
}
