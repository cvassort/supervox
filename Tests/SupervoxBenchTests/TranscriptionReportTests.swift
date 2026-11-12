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

/// Journal partagé entre plusieurs doubles : ordre global des appels.
actor EventLog {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

/// Double qui mémorise chaque vocabulaire reçu par `transcribe`, dans l'ordre des appels ; si un journal est donné,
/// il y note aussi `prepare`, `warmUp` et `transcribe` avec le vocabulaire.
actor VocabularySpy: Transcriber {
    nonisolated let name: String
    nonisolated let acceptsVocabulary: Bool
    nonisolated let measurementConditions: String
    private let log: EventLog?
    private(set) var received: [[String]] = []

    init(name: String = "spy", acceptsVocabulary: Bool = true, log: EventLog? = nil, conditions: String = "conditions de test") {
        self.name = name
        self.acceptsVocabulary = acceptsVocabulary
        self.log = log
        self.measurementConditions = conditions
    }

    func prepare() async throws { await log?.add("\(name) prepare") }
    func warmUp(vocabulary: [String]) async throws { await log?.add("\(name) warmUp \(vocabulary)") }
    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        received.append(vocabulary)
        await log?.add("\(name) transcribe \(vocabulary)")
        return ""
    }
}

/// Moteur dont le passage à vide échoue.
struct UnwarmableTranscriber: Transcriber {
    let name: String
    func prepare() async throws {}
    func warmUp(vocabulary: [String]) async throws { throw TranscriberError.engine("préchauffage impossible") }
    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        Issue.record("transcribe ne doit pas être appelé après un préchauffage en échec")
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
    #expect(s.failures == 1 && abs(s.wer! - 0) < 1e-9)
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

/// Les deux passes d'un même moteur s'enchaînent, chacune précédée d'un passage à vide avec son propre vocabulaire,
/// avant de passer au moteur suivant : la passe « +vocab » ne démarre pas à froid après les autres moteurs.
@Test func passesOfAnEngineAreChainedAndEachIsWarmedUp() async {
    let log = EventLog()
    let a = VocabularySpy(name: "a", acceptsVocabulary: true, log: log)
    let b = VocabularySpy(name: "b", acceptsVocabulary: false, log: log)
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: [])]
    _ = await runBenchmark([a, b], corpus: corpus, audio: clipFromID, hasSpeech: { _ in true }, vocabulary: ["K"])
    #expect(await log.events == [
        "a prepare", "a warmUp []", "a transcribe []",
        "a prepare", "a warmUp [\"K\"]", "a transcribe [\"K\"]",
        "b prepare", "b warmUp []", "b transcribe []",
    ])
}

@Test func warmUpFailureMarksEverySpokenItemAsFailed() async {
    let out = await runEngines([UnwarmableTranscriber(name: "w")], corpus: [CorpusItem(id: "16000", text: "bonjour", terms: [])],
                               audio: clipFromID, hasSpeech: { _ in true })
    #expect(out["w"]?.first?.failure?.contains("préchauffage impossible") == true)
}

/// Chaque moteur décrit lui-même ce que contient sa mesure ; le rapport le reprend une fois par moteur.
@Test func reportDescribesEachEngineMeasurementOnce() async {
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: [])]
    let runs = await runBenchmark([VocabularySpy(name: "a", conditions: "chrono A : réseau compris"),
                                   VocabularySpy(name: "b", acceptsVocabulary: false, conditions: "chrono B : analyseur neuf")],
                                  corpus: corpus, audio: clipFromID, hasSpeech: { _ in true }, vocabulary: ["K"])
    let report = Reports.markdownReport(corpus: corpus, runs: runs, vocabulary: ["K"])
    #expect(report.components(separatedBy: "chrono A : réseau compris").count == 2)   // une fois, pas pour a+vocab aussi
    #expect(report.contains("chrono B : analyseur neuf"))
    #expect(!report.contains("non décrites"))
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

// MARK: - Budget d'amorce de WhisperKit

@Test func promptBudgetRefusesOverLimitWithoutTruncating() async throws {
    await #expect(throws: TranscribeError.vocabularyTooLong(tokens: 112, limit: 111)) {
        try await PromptBudget.check(["x"], limit: 111) { _ in 112 }
    }
    #expect(try await PromptBudget.check(["x"], limit: 111) { _ in 111 } == 111)   // la limite elle-même passe
    #expect(try await PromptBudget.check(["x"], limit: 111) { _ in nil } == nil)   // incalculable : pas de refus
    #expect(TranscribeError.vocabularyTooLong(tokens: 112, limit: 111).description.contains("112 jetons"))
}

/// Les conditions sont lues après les passes du moteur : il peut y décrire ce qui s'est réellement appliqué.
actor SelfDescribingSpy: Transcriber {
    nonisolated let name = "auto"
    nonisolated var acceptsVocabulary: Bool { true }
    private var lastWarmUp: [String] = []
    var measurementConditions: String { "dernier préchauffage avec \(lastWarmUp)" }
    func prepare() async throws {}
    func warmUp(vocabulary: [String]) async throws { lastWarmUp = vocabulary }
    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String { "" }
}

@Test func conditionsAreReadAfterTheEnginePasses() async {
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: [])]
    let runs = await runBenchmark([SelfDescribingSpy()], corpus: corpus, audio: clipFromID, hasSpeech: { _ in true },
                                  vocabulary: ["Keycloak"])
    #expect(runs.map(\.conditions) == ["dernier préchauffage avec [\"Keycloak\"]", "dernier préchauffage avec [\"Keycloak\"]"])
}

// MARK: - Détection de voix

/// La présence de voix est décidée une fois par enregistrement pour tout le passage, pas une fois par passe : toutes
/// les passes (ici « a », « a+vocab », « b ») reçoivent la même décision.
@Test func speechIsDetectedOncePerRecordingForAllPasses() async {
    let calls = EventLog()
    let a = VocabularySpy(name: "a", acceptsVocabulary: true)
    let b = VocabularySpy(name: "b", acceptsVocabulary: false)
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: []), CorpusItem(id: "8000", text: "salut", terms: [])]
    let runs = await runBenchmark([a, b], corpus: corpus, audio: clipFromID,
                                  hasSpeech: { await calls.add("\(Int($0.sampleRate))"); return $0.sampleRate == 16000 },
                                  vocabulary: ["K"])
    #expect(await calls.events == ["16000", "8000"])
    #expect(runs.map(\.label) == ["a", "a+vocab", "b"])
    #expect(runs.allSatisfy { $0.results.map(\.hasSpeech) == [true, false] })
    #expect(await a.received == [[], ["K"]])
    #expect(await b.received == [[]])
}

/// Une erreur du détecteur sur un enregistrement n'est ni « voix » ni « sans voix » par défaut : la phrase est en
/// échec pour chaque moteur, avec le message, et n'est envoyée à aucun moteur.
@Test func detectorErrorFailsTheItemForEveryEngine() async {
    let spy = VocabularySpy(name: "spy", acceptsVocabulary: false)
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: []), CorpusItem(id: "8000", text: "salut", terms: [])]
    let out = await runEngines([spy, FakeTranscriber(name: "fake", answers: ["8000": "salut"])], corpus: corpus,
                               audio: clipFromID, hasSpeech: { clip in
                                   if clip.sampleRate == 16000 { throw TranscriberError.engine("modèle de voix absent") }
                                   return true
                               })
    for name in ["spy", "fake"] {
        let first = out[name]![0]
        #expect(first.hasSpeech && first.hypothesis == nil && first.failure?.contains("modèle de voix absent") == true)
        #expect(out[name]![1].failure == nil && out[name]![1].hasSpeech)
    }
    #expect(await spy.received.count == 1)   // seule la phrase « 8000 » a été transcrite
    let s = Reports.summarize(engine: "fake", corpus: corpus, results: out["fake"]!)
    #expect(s.failures == 1 && s.excluded == 0)
}

// MARK: - Règles de comparaison dites au lecteur

/// Le rapport dit en clair ce que la comparaison plie, ce qu'elle compte comme erreur, et ce que cela veut dire pour
/// le rappel des termes : sans cela, « 3 » contre « trois » ou « Fast API » contre « FastAPI » passeraient pour des
/// fautes du moteur. Les exemples cités sont vérifiés contre la vraie normalisation, pas seulement recopiés.
@Test func reportStatesTheComparisonRules() {
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: [])]
    let report = Reports.markdownReport(corpus: corpus, runs: [], vocabulary: [])
    let rules = report.components(separatedBy: "## Règles de comparaison").last ?? ""
    #expect(report.contains("## Règles de comparaison"))
    for folded in ["casse", "apostrophes", "traits d'union", "ponctuation"] { #expect(rules.contains(folded), "\(folded)") }
    #expect(rules.contains("« 3 » contre « trois »") && rules.contains("« FastAPI » contre « Fast API »"))
    #expect(rules.contains("rappel des termes"))
    // Les exemples du texte sont exacts : pliés à l'identique, ou comptés comme erreurs.
    #expect(WordErrorRate.compute(reference: "L'API pull-request", hypothesis: "l api Pull Request").rate == 0)
    #expect(WordErrorRate.compute(reference: "3 workers", hypothesis: "trois workers").rate > 0)
    #expect(TermRecall.compute(terms: ["FastAPI"], hypothesis: "le Fast API").found == 0)
}
