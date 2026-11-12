import Foundation
import SupervoxCore
import Testing
@testable import SupervoxBench

// Les moteurs sont simulés ; l'agrégation (WordErrorRate, TermRecall), le déroulé de `runEngines` et la lecture
// des fichiers audio sont les vrais.

struct FakeTranscriber: Transcriber {
    let name: String; let answers: [String: String]; var failOn: Set<String> = []
    func prepare() async throws {}
    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        let id = String(Int(clip.sampleRate))                 // l'identifiant est porté par la fréquence dans ce double
        if failOn.contains(id) { throw EndpointError.http(status: 503, body: "panne") }
        return answers[id] ?? ""
    }
}

/// Double qui mémorise chaque vocabulaire reçu, dans l'ordre des appels.
actor VocabularySpy: Transcriber {
    nonisolated let name: String
    nonisolated let acceptsVocabulary: Bool
    private(set) var received: [[String]] = []

    init(name: String = "spy", acceptsVocabulary: Bool = true) {
        self.name = name
        self.acceptsVocabulary = acceptsVocabulary
    }

    func prepare() async throws {}
    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        received.append(vocabulary)
        return ""
    }
}

/// Moteur dont le chargement échoue (modèle introuvable, locale refusée…).
struct UnpreparableTranscriber: Transcriber {
    let name: String
    func prepare() async throws { throw TranscriberError.unsupportedLocale("xx-XX") }
    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        Issue.record("transcribe ne doit pas être appelé après un échec de prepare()")
        return ""
    }
}

private func clipFromID(_ id: String) -> AudioClip { AudioClip(samples: [0.1], sampleRate: Double(id)!) }

// MARK: - Tests du plan

@Test func summaryAggregatesErrorsOverAllWords() {
    let corpus = [CorpusItem(id: "a", text: "le worker celery tourne", terms: ["worker celery"]),
                  CorpusItem(id: "b", text: "bonjour", terms: [])]
    let results = [ItemResult(id: "a", hypothesis: "le worker salary tourne", seconds: 1.0, failure: nil, hasSpeech: true),
                   ItemResult(id: "b", hypothesis: "bonjour", seconds: 3.0, failure: nil, hasSpeech: true)]
    let s = Reports.summarize(engine: "x", corpus: corpus, results: results)
    #expect(abs(s.wer! - 0.2) < 1e-9)   // 1 erreur sur 5 mots, et non la moyenne des taux par phrase (0,125)
    #expect(s.termsFound == 0 && s.termsTotal == 1 && s.termRecall == 0.0)   // « worker celery » n'est pas retrouvé
    #expect(Reports.markdownTable([s]).contains("0/1"))
    #expect(abs(s.medianSeconds! - 2.0) < 1e-9 && s.failures == 0 && s.excluded == 0)
}
@Test func itemWithoutSpeechIsExcluded() {
    let corpus = [CorpusItem(id: "a", text: "bonjour", terms: []), CorpusItem(id: "b", text: "salut", terms: [])]
    let results = [ItemResult(id: "a", hypothesis: "bonjour", seconds: 1, failure: nil, hasSpeech: true),
                   ItemResult(id: "b", hypothesis: nil, seconds: nil, failure: nil, hasSpeech: false)]
    let s = Reports.summarize(engine: "x", corpus: corpus, results: results)
    #expect(s.wer == 0 && s.excluded == 1)
}
@Test func perItemTermsAreNeverPassedAsVocabulary() async {
    // un double qui mémorise le vocabulaire reçu : il doit valoir la liste globale, jamais les termes de la phrase
    let spy = VocabularySpy()
    _ = await runEngines([spy], corpus: [CorpusItem(id: "16000", text: "le worker celery", terms: ["worker celery"])],
                         audio: { AudioClip(samples: [0.1], sampleRate: Double($0)!) }, hasSpeech: { _ in true },
                         vocabulary: ["Kubernetes"])
    #expect(await spy.received == [["Kubernetes"]])
}
@Test func failingEngineDoesNotStopRun() async {
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: []), CorpusItem(id: "8000", text: "salut", terms: [])]
    let bad = FakeTranscriber(name: "bad", answers: [:], failOn: ["16000", "8000"])
    let good = FakeTranscriber(name: "good", answers: ["16000": "bonjour", "8000": "salut"])
    let out = await runEngines([bad, good], corpus: corpus,
                               audio: { AudioClip(samples: [0.1], sampleRate: Double($0)!) }, hasSpeech: { _ in true })
    #expect(out["bad"]?.allSatisfy { $0.failure?.contains("503") == true } == true)
    #expect(out["good"]?.map(\.hypothesis) == ["bonjour", "salut"])
}
@Test func summaryOfAllFailuresHasNoRates() {
    let s = Reports.summarize(engine: "x", corpus: [CorpusItem(id: "a", text: "bonjour", terms: [])],
                              results: [ItemResult(id: "a", hypothesis: nil, seconds: nil, failure: "HTTP 503", hasSpeech: true)])
    #expect(s.wer == nil && s.medianSeconds == nil && s.failures == 1)
    #expect(Reports.markdownTable([s]).contains("échec"))
}
@Test func percentileOfEmptyIsNil() { #expect(Reports.percentile([], 0.9) == nil) }

// MARK: - Cas sur lesquels le plan est muet, et où un mauvais choix fausserait la comparaison

/// Un moteur qui rend une chaîne vide sur une phrase parlée s'est trompé sur tous les mots : la phrase entre dans le
/// taux comme N suppressions. L'écarter ferait passer un moteur muet pour parfait.
@Test func emptyTranscriptOfSpokenItemCountsAsAllDeletions() async {
    let corpus = [CorpusItem(id: "16000", text: "le worker celery tourne", terms: ["worker celery"]),
                  CorpusItem(id: "8000", text: "bonjour", terms: [])]
    let mute = FakeTranscriber(name: "muet", answers: ["8000": "bonjour"])   // rien pour 16000 : chaîne vide
    let out = await runEngines([mute], corpus: corpus, audio: clipFromID, hasSpeech: { _ in true })
    #expect(out["muet"]?.first?.hypothesis == "")
    #expect(out["muet"]?.first?.failure == nil)
    let s = Reports.summarize(engine: "muet", corpus: corpus, results: out["muet"]!)
    #expect(abs(s.wer! - 0.8) < 1e-9)   // 4 suppressions sur 5 mots
    #expect(s.termsFound == 0 && s.termsTotal == 1 && s.failures == 0)
}

/// Aucune transcription d'un passage sans voix : le moteur n'est pas appelé, et la phrase n'entre dans aucun taux.
@Test func itemWithoutSpeechIsNeverSentToTheEngine() async {
    let spy = VocabularySpy()
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: ["bonjour"])]
    let out = await runEngines([spy], corpus: corpus, audio: clipFromID, hasSpeech: { _ in false })
    #expect(await spy.received.isEmpty)
    #expect(out["spy"] == [ItemResult(id: "16000", hypothesis: nil, seconds: nil, failure: nil, hasSpeech: false)])
    let s = Reports.summarize(engine: "spy", corpus: corpus, results: out["spy"]!)
    #expect(s.wer == nil && s.termsTotal == 0 && s.excluded == 1 && s.failures == 0)
    #expect(!Reports.markdownTable([s]).contains("échec"))   // rien à mesurer n'est pas un échec du moteur
}

/// Un moteur qui ne se charge pas n'est ni retiré ni silencieux : chaque phrase parlée porte l'erreur, la ligne
/// affiche « échec » avec le message. Les phrases sans voix restent exclues, comme pour les autres moteurs.
@Test func prepareFailureMarksEverySpokenItemAsFailed() async {
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: []), CorpusItem(id: "8000", text: "salut", terms: [])]
    let out = await runEngines([UnpreparableTranscriber(name: "apple")], corpus: corpus, audio: clipFromID,
                               hasSpeech: { $0.sampleRate == 16000 })
    let rows = out["apple"]!
    #expect(rows[0].failure?.contains("xx-XX") == true && rows[0].hasSpeech)
    #expect(rows[1] == ItemResult(id: "8000", hypothesis: nil, seconds: nil, failure: nil, hasSpeech: false))
    let s = Reports.summarize(engine: "apple", corpus: corpus, results: rows)
    #expect(s.failures == 1 && s.excluded == 1 && s.wer == nil)
    let table = Reports.markdownTable([s])
    #expect(table.contains("échec") && table.contains("xx-XX"))
}

/// Un fichier illisible est une panne de données, pas une réponse vide : la phrase est en échec pour chaque moteur,
/// et le moteur n'est pas appelé dessus.
@Test func unreadableAudioIsAFailureForEveryEngine() async {
    struct Missing: Error {}
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: []), CorpusItem(id: "8000", text: "salut", terms: [])]
    let spy = VocabularySpy()
    let out = await runEngines([spy, FakeTranscriber(name: "fake", answers: ["16000": "bonjour"])], corpus: corpus,
                               audio: { id in if id == "8000" { throw Missing() }; return clipFromID(id) },
                               hasSpeech: { _ in true })
    #expect(await spy.received.count == 1)
    for name in ["spy", "fake"] {
        #expect(out[name]?[1].failure?.contains("audio") == true)
        #expect(out[name]?[1].hypothesis == nil)
    }
}

/// Une phrase du corpus sans résultat est comptée en échec, jamais ignorée.
@Test func corpusItemWithoutResultCountsAsFailure() {
    let corpus = [CorpusItem(id: "a", text: "bonjour", terms: []), CorpusItem(id: "b", text: "salut", terms: [])]
    let s = Reports.summarize(engine: "x", corpus: corpus,
                              results: [ItemResult(id: "a", hypothesis: "bonjour", seconds: 1, failure: nil, hasSpeech: true)])
    #expect(s.failures == 1 && s.wer == 0)
}

/// Deux moteurs du même nom écraseraient leurs résultats dans le dictionnaire : `runEngines` s'arrête.
@Test func duplicateEngineNamesStopTheRun() async {
    await #expect(processExitsWith: .failure) {
        _ = await runEngines([FakeTranscriber(name: "x", answers: [:]), FakeTranscriber(name: "x", answers: [:])],
                             corpus: [CorpusItem(id: "16000", text: "bonjour", terms: [])],
                             audio: { AudioClip(samples: [0.1], sampleRate: Double($0)!) }, hasSpeech: { _ in true })
    }
}

/// Le rapport donne le nombre d'échecs sur chaque ligne : avec des échecs, le taux porte sur moins de phrases.
@Test func tableShowsFailuresAndWarnsWhenRatesCoverDifferentItems() {
    let corpus = [CorpusItem(id: "a", text: "bonjour", terms: []), CorpusItem(id: "b", text: "salut", terms: [])]
    let ok = Reports.summarize(engine: "ok", corpus: corpus, results: [
        ItemResult(id: "a", hypothesis: "bonjour", seconds: 1, failure: nil, hasSpeech: true),
        ItemResult(id: "b", hypothesis: "salut", seconds: 1, failure: nil, hasSpeech: true)])
    let partial = Reports.summarize(engine: "partiel", corpus: corpus, results: [
        ItemResult(id: "a", hypothesis: "bonjour", seconds: 1, failure: nil, hasSpeech: true),
        ItemResult(id: "b", hypothesis: nil, seconds: nil, failure: "délai | dépassé", hasSpeech: true)])
    let table = Reports.markdownTable([ok, partial])
    let lines = table.split(separator: "\n").map(String.init)
    let row = lines.first { $0.hasPrefix("| partiel ") }!
    #expect(row.contains("| 1 |"))                 // colonne des échecs
    #expect(row.contains("délai \\| dépassé"))     // un « | » dans l'erreur ne casse pas le tableau
    func columns(_ line: String) -> Int {   // « \| » est un caractère du texte, pas un séparateur
        line.replacingOccurrences(of: "\\|", with: "").split(separator: "|", omittingEmptySubsequences: false).count
    }
    #expect(columns(row) == columns(lines[0]))
    #expect(table.contains("moins de phrases"))
    #expect(lines.firstIndex { $0.hasPrefix("| ok ") }! < lines.firstIndex { $0.hasPrefix("| partiel ") }!)
}

@Test func percentileInterpolatesBetweenRanks() {
    #expect(abs(Reports.percentile([1.5, 1.9], 0.5)! - 1.7) < 1e-9)
    let slow = Array(repeating: 1.5, count: 8) + [2.7, 2.7]
    #expect(abs(Reports.percentile(slow.shuffled(), 0.9)! - 2.7) < 1e-9)
    #expect(abs(Reports.percentile([3, 1, 2], 0.0)! - 1) < 1e-9 && abs(Reports.percentile([3, 1, 2], 1.0)! - 3) < 1e-9)
    #expect(abs(Reports.percentile([4], 0.9)! - 4) < 1e-9)
}

// MARK: - Deux passes : sans puis avec le vocabulaire global

@Test func vocabularyCapableEnginesGetASecondLabelledRun() async {
    let spy = VocabularySpy(name: "spy", acceptsVocabulary: true)
    let corpus = [CorpusItem(id: "16000", text: "le worker celery", terms: ["worker celery"])]
    let rows = await runBenchmark([FakeTranscriber(name: "plain", answers: [:]), spy], corpus: corpus,
                                  audio: clipFromID, hasSpeech: { _ in true }, vocabulary: ["Kubernetes"])
    #expect(rows.map(\.label) == ["plain", "spy", "spy+vocab"])
    #expect(await spy.received == [[], ["Kubernetes"]])   // jamais « worker celery »
    #expect(rows[0].note != nil && rows[1].note == nil && rows[2].note == nil)
}

@Test func withoutVocabularyEachEngineRunsOnce() async {
    let spy = VocabularySpy(name: "spy", acceptsVocabulary: true)
    let rows = await runBenchmark([spy], corpus: [CorpusItem(id: "16000", text: "bonjour", terms: [])],
                                  audio: clipFromID, hasSpeech: { _ in true }, vocabulary: [])
    #expect(rows.map(\.label) == ["spy"] && rows[0].note == nil)
    #expect(await spy.received == [[]])
}

// MARK: - Entrées de la commande

@Test func engineListRejectsDuplicatesAndUnknownNames() throws {
    #expect(try EngineList.parse(" whisperkit , apple ") == ["whisperkit", "apple"])
    #expect(throws: TranscribeError.duplicateEngine("whisperkit")) { try EngineList.parse("whisperkit,parakeet,whisperkit") }
    #expect(throws: TranscribeError.unknownEngine("vosk")) { try EngineList.parse("parakeet,vosk") }
    #expect(throws: TranscribeError.noEngine) { try EngineList.parse(" , ") }
}

@Test func vocabularyFileKeepsOneTermPerLine() {
    #expect(VocabularyFile.parse("# termes\nKubernetes\n\n  pull request  \r\nKubernetes\n") == ["Kubernetes", "pull request"])
}

/// Les moteurs attendent du 16 kHz : un WAV à une autre fréquence est rééchantillonné à la lecture, pour tous les
/// moteurs à la fois ; un identifiant sans fichier arrête la commande avant tout chargement de modèle.
@Test func corpusAudioIsCheckedAndBroughtTo16kHz() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sv-tr-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func tone(_ rate: Double) -> AudioClip {
        AudioClip(samples: (0..<Int(rate)).map { 0.5 * Float(sin(2 * .pi * 440 * Double($0) / rate)) }, sampleRate: rate)
    }
    try WavFile.write(tone(16000), to: dir.appendingPathComponent("a.wav"))
    try WavFile.write(tone(8000), to: dir.appendingPathComponent("b.wav"))
    let items = ["a", "b", "c", "d"].map { CorpusItem(id: $0, text: "x", terms: []) }

    #expect(throws: TranscribeError.missingAudio(["c", "d"])) { try CorpusAudio.load(items, from: dir) }

    let clips = try CorpusAudio.load(Array(items.prefix(2)), from: dir)
    #expect(clips["a"]?.sampleRate == 16000 && clips["a"]?.samples.count == 16000)
    #expect(clips["b"]?.sampleRate == 16000)
    #expect(abs((clips["b"]?.duration ?? 0) - 1.0) < 0.01)
}

@Test func emptyWavIsRejected() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sv-tr-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try WavFile.write(AudioClip(samples: [], sampleRate: 16000), to: dir.appendingPathComponent("a.wav"))
    #expect(throws: TranscribeError.emptyAudio("a")) {
        try CorpusAudio.load([CorpusItem(id: "a", text: "x", terms: [])], from: dir)
    }
}
