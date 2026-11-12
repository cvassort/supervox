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

/// Mots français qui commencent par une pièce de la liste noire anglaise de FluidAudio (« so », « not »…) : avec
/// l'indication `.french`, Parakeet les déformait (« ce sort », « notament », « joirée »). 7 mots.
private let frenchTrapSentence = "Ce soir, nous verrons notamment la soirée."

/// `text` lu par la voix française `Thomas` de `say`, en WAV 16 kHz mono.
private func synthesizedSentence(_ text: String = sentence) throws -> AudioClip {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sv-say-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Thomas", "-o", url.path, "--file-format=WAVE", "--data-format=LEI16@16000", text]
    try say.run()
    say.waitUntilExit()
    try #require(say.terminationStatus == 0, "say a échoué")
    let clip = try WavFile.read(url)
    return clip.sampleRate == transcriberSampleRate ? clip : Resampler.resample(clip, to: transcriberSampleRate)
}

private func seconds(_ d: Duration) -> Double {
    Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
}

/// Charge le moteur (et le préchauffe si `warm`), transcrit deux fois la même phrase et vérifie le taux d'erreur des
/// deux transcriptions. Affiche les durées : chargement, 1er appel, 2e appel. Rend la transcription.
@discardableResult
private func measure(_ engine: any Transcriber, label: String, clip: AudioClip, warm: Bool = true,
                     vocabulary: [String] = [], reference: String = sentence) async throws -> String {
    let clock = ContinuousClock()
    var start = clock.now
    try await engine.prepare()
    if warm { try await engine.warmUp(vocabulary: vocabulary) }
    let prepare = seconds(start.duration(to: clock.now))

    var texts: [String] = []
    var times: [Double] = []
    for _ in 0..<2 {
        start = clock.now
        texts.append(try await engine.transcribe(clip, language: "fr", vocabulary: vocabulary))
        times.append(seconds(start.duration(to: clock.now)))
    }
    print(String(format: "[intégration] %@ : prepare+warmUp %.2f s, 1er appel %.3f s, 2e appel %.3f s, audio %.2f s",
                 label, prepare, times[0], times[1], clip.duration))
    for text in texts {
        let rate = WordErrorRate.compute(reference: reference, hypothesis: text).rate
        print("[intégration] \(label) : « \(text) » (taux \(String(format: "%.3f", rate)))")
        #expect(rate <= maximumRate, "\(label) : « \(text) »")
        #expect(!text.contains("<|"), "jeton spécial dans le texte : « \(text) »")
    }
    return texts[0]
}

/// Phrase avec des termes techniques rares, pour montrer l'effet du vocabulaire. « PostgreSQL » est dans la liste
/// mais pas dans la phrase : il ne doit jamais ressortir.
private let technicalSentence = "Le worker Celery redémarre après la mise à jour de Keycloak."
private let technicalVocabulary = ["Celery", "Keycloak", "PostgreSQL"]

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_INTEGRATION"] == "1"))
struct EngineIntegrationTests {
    /// À froid (sans `warmUp`), puis préchauffé : le premier appel du moteur froid montre ce que le préchauffage absorbe.
    @Test func whisperKit() async throws {
        let clip = try synthesizedSentence()
        try await measure(WhisperKitTranscriber(model: "large-v3-v20240930_turbo"), label: "whisperkit (froid)", clip: clip, warm: false)
        let engine = WhisperKitTranscriber(model: "large-v3-v20240930_turbo")
        try await measure(engine, label: "whisperkit", clip: clip)
        // Des termes absents de la phrase, en amorce : ils ne doivent pas ressortir dans le texte, sinon la ligne
        // « +vocab » gagnerait un rappel des termes immérité.
        let primed = try await measure(engine, label: "whisperkit+vocab", clip: clip, vocabulary: ["Kubernetes", "PostgreSQL"])
        #expect(!primed.localizedCaseInsensitiveContains("kubernetes") && !primed.localizedCaseInsensitiveContains("postgresql"))
    }

    /// Le compte de jetons d'amorce se fait avec le seul tokenizer, et un vocabulaire trop long est refusé.
    @Test func whisperKitPromptBudget() async throws {
        let model = "large-v3-v20240930_turbo"
        let short = try #require(try await WhisperKitTranscriber.promptTokenCount(technicalVocabulary, model: model))
        let long = (1...60).map { "Terme\($0)Technique" }
        let longCount = try #require(try await WhisperKitTranscriber.promptTokenCount(long, model: model))
        print("[intégration] amorce WhisperKit : \(technicalVocabulary.count) termes → \(short) jetons ; 60 termes → \(longCount) jetons ; limite \(WhisperKitTranscriber.promptTokenLimit)")
        #expect(WhisperKitTranscriber.promptTokenLimit == 111)
        #expect(short <= WhisperKitTranscriber.promptTokenLimit && longCount > WhisperKitTranscriber.promptTokenLimit)
        #expect(try await WhisperKitTranscriber.promptTokenCount(["x"], model: "modèle-inconnu") == nil)
    }

    @Test func parakeet() async throws {
        let clip = try synthesizedSentence()
        try await measure(ParakeetTranscriber(), label: "parakeet (froid)", clip: clip, warm: false)
        try await measure(ParakeetTranscriber(), label: "parakeet", clip: clip)
        let trap = try synthesizedSentence(frenchTrapSentence)
        try await measure(ParakeetTranscriber(), label: "parakeet (mots piégés)", clip: trap, reference: frenchTrapSentence)
    }

    /// Ce que donne le recalage par vocabulaire de Parakeet sur des termes rares. Aucun gain n'est exigé : le test
    /// montre les deux transcriptions et vérifie seulement qu'un terme non prononcé n'est pas inséré.
    @Test func parakeetVocabulary() async throws {
        let clip = try synthesizedSentence(technicalSentence)
        let engine = ParakeetTranscriber()
        try await engine.prepare()
        try await engine.warmUp(vocabulary: [])
        let plain = try await engine.transcribe(clip, language: "fr", vocabulary: [])
        try await engine.warmUp(vocabulary: technicalVocabulary)
        let primed = try await engine.transcribe(clip, language: "fr", vocabulary: technicalVocabulary)
        for (label, text) in [("parakeet", plain), ("parakeet+vocab", primed)] {
            let rate = WordErrorRate.compute(reference: technicalSentence, hypothesis: text).rate
            let terms = TermRecall.compute(terms: ["Celery", "Keycloak"], hypothesis: text)
            print("[intégration] \(label) : « \(text) » (taux \(String(format: "%.3f", rate)), termes \(terms.found)/\(terms.total))")
        }
        #expect(!primed.localizedCaseInsensitiveContains("postgresql"))

        // Le vocabulaire est global : la plupart des phrases ne contiennent aucun de ses termes. Une telle phrase doit
        // sortir identique avec et sans vocabulaire. Avec les réglages par défaut de FluidAudio, « Le serveur web
        // redémarre tous les matins. » devenait « PostgreSQL Kubernetes. ».
        let unrelatedText = "Le serveur web redémarre tous les matins."
        let unrelated = try synthesizedSentence(unrelatedText)
        let unrelatedPlain = try await engine.transcribe(unrelated, language: "fr", vocabulary: [])
        let unrelatedPrimed = try await engine.transcribe(unrelated, language: "fr", vocabulary: technicalVocabulary + ["Kubernetes"])
        print("[intégration] parakeet / parakeet+vocab, phrase sans terme : « \(unrelatedPlain) » / « \(unrelatedPrimed) »")
        #expect(unrelatedPrimed == unrelatedPlain)
    }

    @Test func appleSpeech() async throws {
        let clip = try synthesizedSentence()
        try await measure(AppleSpeechTranscriber(locale: "fr-FR"), label: "apple (froid)", clip: clip, warm: false)
        try await measure(AppleSpeechTranscriber(locale: "fr-FR"), label: "apple", clip: clip)
    }

    /// Une locale que le framework ne propose pas fait échouer `prepare()` : pas de repli silencieux sur une autre.
    @Test func appleSpeechRejectsUnsupportedLocale() async {
        await #expect(throws: TranscriberError.unsupportedLocale("zz-ZZ")) {
            try await AppleSpeechTranscriber(locale: "zz-ZZ").prepare()
        }
    }
}
