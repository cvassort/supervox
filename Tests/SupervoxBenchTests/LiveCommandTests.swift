import ArgumentParser
import Foundation
import Synchronization
import SupervoxCore
import SupervoxEngines
import Testing

@testable import SupervoxBench

// `supervox-bench live` : le rejeu d'enregistrements dans une vraie `DictationSession`, avec le micro scripté. Les moteurs
// et le détecteur de voix sont des doubles : aucun modèle, aucun micro, aucun réseau ; seule la session est la vraie.

/// Détecteur double : annonce la voix dès le premier bloc d'une prise (ou jamais), et garde les blocs reçus.
private final class DoubleDetector: StreamingVoiceDetector, @unchecked Sendable {
    let blockSize = 4096
    private let speaks: Bool
    private let state = Mutex(0)

    init(speaks: Bool = true) { self.speaks = speaks }

    func prepare() async throws {}
    func reset() async { state.withLock { $0 = 0 } }
    func process(_ block: [Float]) async throws -> VoiceEvent? {
        let index = state.withLock { count -> Int in
            defer { count += 1 }
            return count
        }
        return speaks && index == 0 ? .speechStart(sample: 0) : nil
    }
}

/// Moteur double : garde la longueur de chaque clip reçu et répond par une fonction du clip ; peut faire avancer l'horloge
/// du test pendant qu'il « travaille ».
private final class DoubleTranscriber: Transcriber, @unchecked Sendable {
    let name: String
    private let reply: @Sendable (AudioClip) throws -> String
    private let work: @Sendable () -> Void
    private let lengths = Mutex<[Int]>([])

    init(name: String, work: @escaping @Sendable () -> Void = {}, reply: @escaping @Sendable (AudioClip) throws -> String) {
        self.name = name
        self.reply = reply
        self.work = work
    }

    var seenLengths: [Int] { lengths.withLock { $0 } }
    func prepare() async throws {}
    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        lengths.withLock { $0.append(clip.samples.count) }
        work()
        return try reply(clip)
    }
}

/// Horloge du test : ne bouge que quand le test (ou un moteur double) la fait avancer.
private final class TestClock: Sendable {
    private let value = Mutex(0.0)
    func now() -> Double { value.withLock { $0 } }
    func advance(_ seconds: Double) { value.withLock { $0 += seconds } }
}

private struct EngineBreakdown: Error {}

private func clip(seconds: Double) -> AudioClip {
    AudioClip(samples: Array(repeating: 0.1, count: Int(seconds * 16_000)), sampleRate: 16_000)
}

/// Une configuration de session sans attente entre deux passes d'aperçu.
private let eagerConfig = DictationConfig(language: "fr", previewInterval: 0)

/// Pause réelle de quelques millisecondes : assez pour que l'aperçu tourne entre deux blocs, sans durée réelle longue.
private let shortPause: @Sendable (Double) async -> Void = { _ in try? await Task.sleep(for: .milliseconds(3)) }

@Suite(.timeLimit(.minutes(1))) struct LiveReplayTests {
    // MARK: - Le rejeu

    @Test func theReplayRunsARealSessionAndGivesTheFinalTextTheLastPreviewAndTheDelay() async {
        let clock = TestClock()
        let seconds = 3.0
        let total = Int(seconds * 16_000)
        // Le texte final n'est rendu qu'à la session (clip plus long que l'enregistrement : le silence de fin y est joint).
        let final = DoubleTranscriber(
            name: "final", work: { clock.advance(0.75) },
            reply: { $0.samples.count > total ? "texte de la session" : "texte en bloc" })
        let preview = DoubleTranscriber(name: "apercu", reply: { "aperçu \($0.samples.count)" })

        let outcome = await LiveReplay.run(
            clip: clip(seconds: seconds), detector: DoubleDetector(), preview: preview, final: final,
            config: eagerConfig, settle: 0.5,
            // L'horloge avance aussi pendant le rejeu (chaque bloc attend sa durée) : le délai ne doit compter ni ce temps ni
            // le silence de fin, seulement ce qui suit l'appel de `finish()`.
            pause: { seconds in
                clock.advance(seconds)
                await shortPause(seconds)
            }, now: { clock.now() })

        #expect(outcome.finalText == "texte de la session")
        #expect(outcome.failure == nil && !outcome.noSpeech)
        // Le délai : de l'appel de `finish()` au texte final, selon l'horloge donnée (le moteur final l'a fait avancer de 0,75 s).
        let delay = outcome.finishDelay ?? -1
        #expect(abs(delay - 0.75) < 1e-9, "délai : \(delay)")
        // 56 000 échantillons au total (3 s + 0,5 s) : le rejeu a fait avancer l'horloge de 13 × 0,256 s, bien plus que le
        // délai : un délai qui le compterait dépasserait 3 s.
        #expect(delay < 1)
        // Le dernier aperçu est le texte en direct tel que l'écran le montrait à la fin de la prise : celui d'une passe réelle.
        #expect(outcome.lastPreview.hasPrefix("aperçu "))
        #expect(preview.seenLengths.map { "aperçu \($0)" }.contains(outcome.lastPreview))
    }

    @Test func thePreviewRunsWhileTheAudioPlaysOnGrowingClipsAndFinishComesAfterTheLastBlock() async throws {
        let clock = TestClock()
        let seconds = 3.0
        let preview = DoubleTranscriber(name: "apercu", reply: { _ in "texte" })
        let final = DoubleTranscriber(name: "final", reply: { _ in "texte" })

        _ = await LiveReplay.run(
            clip: clip(seconds: seconds), detector: DoubleDetector(), preview: preview, final: final,
            config: eagerConfig, settle: 0.5, pause: shortPause, now: { clock.now() })

        let lengths = preview.seenLengths
        let total = Int((seconds + 0.5) * 16_000)
        #expect(lengths.count >= 2, "\(lengths)")
        #expect(lengths == lengths.sorted(), "les clips d'aperçu grandissent : \(lengths)")
        let first = try #require(lengths.first, "aucune passe d'aperçu")
        let last = try #require(lengths.last)
        #expect(last > first, "\(lengths)")
        // `finish()` n'est demandé qu'une fois les derniers blocs passés : l'aperçu a vu presque toute la prise.
        #expect(last >= total / 2, "\(lengths)")
    }

    @Test func eachBlockIsPacedByItsOwnDurationAndTheFlushAtTheEndIsNot() async {
        let clock = TestClock()
        let waits = Mutex<[Double]>([])
        let pause: @Sendable (Double) async -> Void = { seconds in waits.withLock { $0.append(seconds) } }
        let seconds = 3.0
        let samples = Int((seconds + 0.5) * 16_000)   // 56 000 : 13 blocs entiers de 4 096, et un reste
        let final = DoubleTranscriber(name: "final", reply: { _ in "texte" })

        _ = await LiveReplay.run(
            clip: clip(seconds: seconds), detector: DoubleDetector(), preview: nil, final: final,
            config: eagerConfig, settle: 0.5, pause: pause, now: { clock.now() })

        let blocks = samples / 4_096
        let seen = waits.withLock { $0 }
        #expect(seen.count == blocks, "\(seen.count) pauses pour \(blocks) blocs")
        #expect(seen.allSatisfy { $0 == 4_096.0 / 16_000.0 })
    }

    @Test func theTrailingSilenceIsPartOfTheTakeAndTheSessionGetsTheWholeOfIt() async {
        let clock = TestClock()
        let final = DoubleTranscriber(name: "final", reply: { _ in "texte" })
        _ = await LiveReplay.run(
            clip: clip(seconds: 2), detector: DoubleDetector(), preview: nil, final: final,
            config: eagerConfig, settle: 1, pause: { _ in }, now: { clock.now() })
        // 2 s de voix + 1 s de silence, spokenClip (voix ouverte jusqu'à la fin de la prise), sans marge hors prise.
        #expect(final.seenLengths == [48_000])
    }

    @Test func aSessionWithoutVoiceIsNoSpeechNotAFailure() async {
        let clock = TestClock()
        let final = DoubleTranscriber(name: "final", reply: { _ in "ne doit pas servir" })
        let outcome = await LiveReplay.run(
            clip: clip(seconds: 2), detector: DoubleDetector(speaks: false), preview: nil, final: final,
            config: eagerConfig, settle: 0.5, pause: { _ in }, now: { clock.now() })
        #expect(outcome.noSpeech)
        #expect(outcome.finalText == nil && outcome.failure == nil)
        #expect(final.seenLengths.isEmpty)
    }

    @Test func aFinalEngineThatFailsIsAFailureWithItsMessage() async {
        let clock = TestClock()
        let final = DoubleTranscriber(name: "final", reply: { _ in throw EngineBreakdown() })
        let outcome = await LiveReplay.run(
            clip: clip(seconds: 2), detector: DoubleDetector(), preview: nil, final: final,
            config: eagerConfig, settle: 0.5, pause: { _ in }, now: { clock.now() })
        #expect(outcome.finalText == nil && !outcome.noSpeech)
        #expect(outcome.failure?.contains("transcription") == true)
    }

    @Test func aRecordingShorterThanOneBlockStillEndsWithoutWaitingForABlockThatNeverComes() async {
        let clock = TestClock()
        let final = DoubleTranscriber(name: "final", reply: { _ in "court" })
        let outcome = await LiveReplay.run(
            clip: clip(seconds: 0.1), detector: DoubleDetector(), preview: nil, final: final,
            config: eagerConfig, settle: 0, pause: { _ in }, now: { clock.now() })
        #expect(outcome.finalText == "court")
    }

    // MARK: - Le passage sur tout le corpus

    private let corpus = [
        CorpusItem(id: "a", text: "un deux trois quatre", terms: ["trois"]),
        CorpusItem(id: "b", text: "cinq six sept huit", terms: []),
        CorpusItem(id: "c", text: "neuf dix", terms: []),
    ]

    @Test func eachSentenceGetsTheSessionResultAndTheBlockBaselineFromTheSameEngine() async {
        let clock = TestClock()
        let total = 32_000
        // Même moteur final pour la session et pour le bloc : le clip du bloc est l'enregistrement (32 000), celui de la
        // session est plus long (silence de fin).
        let final = DoubleTranscriber(
            name: "final",
            reply: { $0.samples.count > total ? "un deux trois quatre" : "un deux trois" })
        let preview = DoubleTranscriber(name: "apercu", reply: { _ in "un deux" })
        var said: [String] = []

        let results = await LiveBench.run(
            corpus: Array(corpus.prefix(1)), audio: { _ in clip(seconds: 2) }, detector: DoubleDetector(),
            preview: preview, final: final, settle: 0.5,
            sessionConfig: eagerConfig, pause: shortPause, now: { clock.now() }, progress: { said.append($0) })

        #expect(results.count == 1)
        #expect(results[0].id == "a")
        #expect(results[0].finalText == "un deux trois quatre")
        #expect(results[0].blockText == "un deux trois")
        #expect(results[0].lastPreview == "un deux")
        #expect(results[0].finishDelay != nil)
        #expect(!said.isEmpty)
    }

    @Test func anUnreadableRecordingIsAFailureOfThatSentenceOnly() async {
        let clock = TestClock()
        let final = DoubleTranscriber(name: "final", reply: { _ in "texte" })
        struct Unreadable: Error {}
        let results = await LiveBench.run(
            corpus: corpus, audio: { id in
                if id == "b" { throw Unreadable() }
                return clip(seconds: 1)
            }, detector: DoubleDetector(), preview: nil, final: final, settle: 0.25,
            sessionConfig: eagerConfig, pause: { _ in }, now: { clock.now() }, progress: { _ in })
        #expect(results.map(\.id) == ["a", "b", "c"])
        #expect(results[1].finalText == nil)
        #expect(results[1].failure?.contains("audio illisible") == true)
        #expect(results[0].finalText == "texte" && results[2].finalText == "texte")
    }

    @Test func anEngineThatCannotBePreparedFailsEverySentenceInsteadOfStoppingTheRun() async {
        struct NoModel: Error {}
        final class Unpreparable: Transcriber, @unchecked Sendable {
            let name = "final"
            func prepare() async throws { throw NoModel() }
            func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String { "x" }
        }
        let clock = TestClock()
        let results = await LiveBench.run(
            corpus: corpus, audio: { _ in clip(seconds: 1) }, detector: DoubleDetector(), preview: nil,
            final: Unpreparable(), settle: 0.25, sessionConfig: eagerConfig,
            pause: { _ in }, now: { clock.now() }, progress: { _ in })
        #expect(results.count == 3)
        #expect(results.allSatisfy { $0.finalText == nil && $0.failure?.contains("chargement du moteur final") == true })
    }
}

// MARK: - Les chiffres

@Suite struct LiveSummaryTests {
    private func item(
        _ id: String, final: String? = nil, block: String? = nil, preview: String = "", delay: Double? = nil,
        noSpeech: Bool = false, failure: String? = nil, blockFailure: String? = nil
    ) -> LiveItemResult {
        LiveItemResult(
            id: id, finalText: final, blockText: block, lastPreview: preview, finishDelay: delay, noSpeech: noSpeech,
            failure: failure, blockFailure: blockFailure)
    }

    private let corpus = [
        CorpusItem(id: "a", text: "un deux trois quatre", terms: ["trois"]),
        CorpusItem(id: "b", text: "cinq six sept huit", terms: []),
        CorpusItem(id: "c", text: "neuf dix", terms: []),
        CorpusItem(id: "d", text: "onze douze", terms: []),
        CorpusItem(id: "e", text: "treize", terms: []),
    ]

    @Test func theRatesAreAggregatedOverTheWordsOfThePairedSentencesOnly() {
        let results = [
            // 4 mots : session parfaite, bloc à 1 erreur, aperçu à 2 erreurs.
            item("a", final: "un deux trois quatre", block: "un deux trois", preview: "un deux", delay: 0.5),
            // 4 mots : session à 1 erreur, bloc parfait, aperçu vide (4 erreurs).
            item("b", final: "cinq six sept", block: "cinq six sept huit", preview: "", delay: 1.5),
            // sans voix : hors de tout taux.
            item("c", noSpeech: true),
            // échec de la session : hors de tout taux.
            item("d", failure: "la transcription a échoué"),
            // session sans voix de bloc : le bloc manque, la phrase est hors comparaison.
            item("e", final: "treize", blockFailure: "échec du bloc"),
        ]
        let summary = LiveSummary(corpus: corpus, results: results)

        #expect(summary.phrases == 5)
        #expect(summary.compared == 2)
        #expect(summary.noSpeech == 1)
        #expect(summary.failures == 2)
        // 8 mots de référence sur les deux phrases comparées.
        #expect(summary.finalWER == 1.0 / 8.0)
        #expect(summary.blockWER == 1.0 / 8.0)
        #expect(summary.previewWER == 6.0 / 8.0)
        #expect(summary.previewEmpty == 1)
        #expect(summary.delayMedian == 1.0)
        #expect(summary.termsTotal == 1)
        #expect(summary.finalTermsFound == 1)
        #expect(summary.blockTermsFound == 1)
    }

    @Test func withNothingToCompareThereAreNoRates() {
        let summary = LiveSummary(corpus: corpus, results: [item("c", noSpeech: true), item("d", failure: "x")])
        #expect(summary.compared == 0)
        #expect(summary.finalWER == nil && summary.blockWER == nil && summary.previewWER == nil)
        #expect(summary.delayMedian == nil && summary.delayP90 == nil)
    }

    @Test func aSentenceWithoutAnyResultIsAFailureNotASilentSkip() {
        let summary = LiveSummary(corpus: corpus, results: [item("a", final: "un", block: "un", delay: 1)])
        #expect(summary.phrases == 5)
        #expect(summary.compared == 1)
        #expect(summary.failures == 4)
    }

    @Test func theDelayPercentilesUseOnlyTheSentencesThatGaveAText() {
        let results = [
            item("a", final: "x", block: "x", delay: 1), item("b", final: "x", block: "x", delay: 3),
            item("c", delay: 99, noSpeech: true),
        ]
        let summary = LiveSummary(corpus: corpus, results: results)
        #expect(summary.delayMedian == 2)
        #expect(abs((summary.delayP90 ?? 0) - 2.8) < 1e-9)
    }

    // MARK: - Le rapport

    @Test func theReportNamesTheMethodTheRatesAndTheLimits() {
        let results = [
            item("a", final: "un deux trois quatre", block: "un deux trois", preview: "un deux", delay: 0.5),
            item("b", final: "cinq six sept huit", block: "cinq six sept huit", preview: "cinq six sept huit", delay: 1.5),
        ]
        let launch = LaunchInfo(date: Date(timeIntervalSince1970: 0), models: ["WhisperKit `x`"], capture: "Capture : rien.")
        let report = LiveReport.markdown(
            corpus: corpus, results: results, vocabulary: ["Terme"], settle: 1, engine: "whisperkit", launch: launch)

        #expect(report.hasPrefix("# Dictée en direct"))
        #expect(report.contains("Texte final de la session"))
        #expect(report.contains("Transcription en bloc"))
        #expect(report.contains("Dernier aperçu"))
        // 0 erreur sur 8 mots pour la session, 1 sur 8 (12,5 %) pour le bloc, 2 sur 8 (25,0 %) pour l'aperçu.
        #expect(report.contains("0,0 %"))
        #expect(report.contains("12,5 %"))
        #expect(report.contains("25,0 %"))
        #expect(report.contains("le début d'un passage de parole de plus de 15 s"))
        #expect(report.contains("Vocabulaire global (1 terme(s))"))
        #expect(report.contains("1,0 s de silence sont ajoutées"))
    }

    @Test func aPartialReportSaysSoAtTheTop() {
        let launch = LaunchInfo(date: Date(timeIntervalSince1970: 0), models: [], capture: "")
        let report = LiveReport.markdown(
            corpus: corpus, results: [], vocabulary: [], settle: 1, engine: "parakeet", launch: launch,
            progress: ReportProgress(done: 2, planned: 5))
        #expect(report.contains("Rapport partiel"))
    }

    @Test func theJSONCarriesEverySentenceAndTheSummary() throws {
        let results = [item("a", final: "un", block: "un", preview: "u", delay: 1)]
        let json = try LiveReport.json(corpus: corpus, results: results, vocabulary: [], settle: 1, engine: "parakeet", progress: nil)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(object["complete"] as? Bool == true)
        #expect((object["items"] as? [[String: Any]])?.count == 1)
        #expect((object["summary"] as? [String: Any])?["compared"] as? Int == 1)
        #expect(object["settleSeconds"] as? Double == 1)
    }
}

// MARK: - La commande

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sv-live-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite(.timeLimit(.minutes(1))) struct LiveCommandTests {
    @Test func theOptionsAreParsedWithTheirDefaults() throws {
        let command = try LiveCommand.parse(["--audio", "a", "--corpus", "c.tsv", "--out", "o"])
        #expect(command.engine == "whisperkit")
        #expect(command.settle == 1.0)
        #expect(!command.overwrite)
        #expect(command.vocabulary == nil)
        let other = try LiveCommand.parse([
            "--audio", "a", "--corpus", "c.tsv", "--out", "o", "--engine", "parakeet", "--overwrite", "--settle", "0.5",
        ])
        #expect(other.engine == "parakeet" && other.overwrite && other.settle == 0.5)
    }

    @Test func anExistingReportIsRefusedBeforeAnythingIsReadAndNamed() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        try "ancien".write(to: folder.appendingPathComponent("live.json"), atomically: true, encoding: .utf8)
        let command = try LiveCommand.parse(["--corpus", "/absent.tsv", "--audio", "/absent", "--out", folder.path])
        await #expect(throws: OutputError.reportExists(folder.appendingPathComponent("live.json").path)) {
            try await command.run()
        }
    }

    @Test func anOutputFolderTrackedByGitIsRefusedBeforeAnythingIsRead() async throws {
        let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "init", "-q", root.path]
        try git.run()
        git.waitUntilExit()
        try #require(git.terminationStatus == 0)
        let command = try LiveCommand.parse([
            "--corpus", "/absent.tsv", "--audio", "/absent", "--out", root.appendingPathComponent("resultats").path,
        ])
        await #expect(throws: OutputError.self) { try await command.run() }
    }

    @Test func anUnknownEngineIsRefusedBeforeAnythingIsRead() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let command = try LiveCommand.parse([
            "--corpus", "/absent.tsv", "--audio", "/absent", "--out", folder.path, "--engine", "apple",
        ])
        await #expect(throws: TranscribeError.unknownEngine("apple")) { try await command.run() }
    }

    @Test(arguments: ["-1", "1e15", "nan", "inf", "3601"])
    func anUnreasonableSettleIsRefused(value: String) async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let command = try LiveCommand.parse([
            "--corpus", "/absent.tsv", "--audio", "/absent", "--out", folder.path, "--settle=\(value)",
        ])
        await #expect(throws: ValidationError.self) { try await command.run() }
    }

    // MARK: - `run` avec des moteurs doubles

    /// Un corpus de trois phrases et leurs enregistrements, dans un dossier temporaire.
    private func fixture() throws -> (root: URL, corpus: URL, audio: URL, out: URL) {
        let root = try temporaryFolder()
        let audio = root.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let corpus = root.appendingPathComponent("corpus.tsv")
        try "a\tun deux trois quatre\ttrois\nb\tcinq six sept huit\nc\tneuf dix\n"
            .write(to: corpus, atomically: true, encoding: .utf8)
        for id in ["a", "b", "c"] { try WavFile.write(clip(seconds: 1), to: audio.appendingPathComponent(id + ".wav")) }
        return (root, corpus, audio, root.appendingPathComponent("sortie"))
    }

    /// Ce que la commande a demandé à la fabrique, et les moteurs doubles qu'elle a reçus.
    private final class Factory: @unchecked Sendable {
        private let asked = Mutex<[(engine: String, model: String)]>([])
        let final: DoubleTranscriber
        let preview: DoubleTranscriber
        init(final: DoubleTranscriber, preview: DoubleTranscriber) {
            self.final = final
            self.preview = preview
        }
        var calls: [(engine: String, model: String)] { asked.withLock { $0 } }
        func make(_ engine: String, _ model: String) -> LiveEngines {
            asked.withLock { $0.append((engine, model)) }
            // La règle de choix est celle de la commande (`LiveEngines.assemble`), pas une copie.
            return LiveEngines.assemble(
                engine: engine, whisperModel: model, parakeet: preview, whisper: final, detector: DoubleDetector())
        }
    }

    private func command(_ f: (root: URL, corpus: URL, audio: URL, out: URL), _ extra: [String] = []) throws -> LiveCommand {
        try LiveCommand.parse(["--corpus", f.corpus.path, "--audio", f.audio.path, "--out", f.out.path, "--settle", "0.25"] + extra)
    }

    @Test func runWritesTheTwoReportsWithTheResultsOfEverySentence() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = TestClock()
        let factory = Factory(
            final: DoubleTranscriber(name: "final", reply: { $0.samples.count > 16_000 ? "un deux trois quatre" : "un deux" }),
            preview: DoubleTranscriber(name: "apercu", reply: { _ in "un" }))

        try await command(f).run(makeEngines: factory.make, pause: { _ in }, now: { clock.now() })

        let markdown = try String(contentsOf: f.out.appendingPathComponent("live.md"), encoding: .utf8)
        #expect(markdown.hasPrefix("# Dictée en direct"))
        #expect(!markdown.contains("Rapport partiel"))
        let data = try Data(contentsOf: f.out.appendingPathComponent("live.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["complete"] as? Bool == true)
        let items = try #require(object["items"] as? [[String: Any]])
        #expect(items.map { $0["id"] as? String } == ["a", "b", "c"])
        #expect(items.allSatisfy { $0["finalText"] as? String == "un deux trois quatre" })
        #expect((object["summary"] as? [String: Any])?["compared"] as? Int == 3)
    }

    @Test func theEngineOptionChoosesWhichEnginesAreBuilt() async throws {
        let clock = TestClock()
        for (extra, expected, models) in [
            (["--engine", "parakeet"], ("parakeet", "large-v3-v20240930_turbo"), "Parakeet (aperçu)"),
            (["--whisperkit-model", "autre-variante"], ("whisperkit", "autre-variante"), "WhisperKit `autre-variante`"),
            ([String](), ("whisperkit", "large-v3-v20240930_turbo"), "WhisperKit `large-v3-v20240930_turbo`"),
        ] {
            let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
            let factory = Factory(
                final: DoubleTranscriber(name: "final", reply: { _ in "texte" }),
                preview: DoubleTranscriber(name: "apercu", reply: { _ in "texte" }))
            try await command(f, extra).run(makeEngines: factory.make, pause: { _ in }, now: { clock.now() })
            #expect(factory.calls.count == 1)
            #expect(factory.calls.first?.engine == expected.0 && factory.calls.first?.model == expected.1, "\(extra)")
            let markdown = try String(contentsOf: f.out.appendingPathComponent("live.md"), encoding: .utf8)
            #expect(markdown.contains(models), "\(extra)")
            // Avec Parakeet, le moteur final est l'exemplaire d'aperçu : c'est lui qui a travaillé, pas l'autre.
            if expected.0 == "parakeet" { #expect(factory.final.seenLengths.isEmpty) } else { #expect(!factory.final.seenLengths.isEmpty) }
        }
    }

    @Test func thePartialReportIsRewrittenAfterEverySentenceThenCompleted() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let clock = TestClock()
        let json = f.out.appendingPathComponent("live.json")
        /// Ce que le fichier du disque dit chaque fois que le moteur final travaille : (phrases écrites, complet) ou rien.
        let seen = Mutex<[String]>([])
        let factory = Factory(
            final: DoubleTranscriber(
                name: "final",
                work: {
                    guard let data = try? Data(contentsOf: json),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { seen.withLock { $0.append("aucun fichier") }; return }
                    let count = (object["items"] as? [Any])?.count ?? -1
                    seen.withLock { $0.append("\(count) phrase(s), complet : \(object["complete"] as? Bool ?? false)") }
                },
                reply: { _ in "texte" }),
            preview: DoubleTranscriber(name: "apercu", reply: { _ in "texte" }))

        try await command(f).run(makeEngines: factory.make, pause: { _ in }, now: { clock.now() })

        // Le moteur final travaille deux fois par phrase (bloc, puis session) : avant la 1re phrase le fichier n'existe pas ;
        // pendant la 2e, il en porte une, incomplet ; pendant la 3e, deux, incomplet.
        let log = seen.withLock { $0 }
        #expect(log.first == "aucun fichier", "\(log)")
        #expect(log.contains("1 phrase(s), complet : false"), "\(log)")
        #expect(log.contains("2 phrase(s), complet : false"), "\(log)")
        let final = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [String: Any])
        #expect((final["items"] as? [Any])?.count == 3 && final["complete"] as? Bool == true)
    }

    @Test func overwriteReplacesTheReportsAndWithoutItTheyAreKept() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.createDirectory(at: f.out, withIntermediateDirectories: true)
        try "ancien".write(to: f.out.appendingPathComponent("live.md"), atomically: true, encoding: .utf8)
        let clock = TestClock()
        let factory = Factory(
            final: DoubleTranscriber(name: "final", reply: { _ in "texte" }),
            preview: DoubleTranscriber(name: "apercu", reply: { _ in "texte" }))

        await #expect(throws: OutputError.self) {
            try await command(f).run(makeEngines: factory.make, pause: { _ in }, now: { clock.now() })
        }
        #expect(try String(contentsOf: f.out.appendingPathComponent("live.md"), encoding: .utf8) == "ancien")
        #expect(factory.calls.isEmpty)

        try await command(f, ["--overwrite"]).run(makeEngines: factory.make, pause: { _ in }, now: { clock.now() })
        #expect(try String(contentsOf: f.out.appendingPathComponent("live.md"), encoding: .utf8).hasPrefix("# Dictée en direct"))
    }

    @Test func aMissingRecordingStopsTheCommandBeforeAnyEngineIsBuilt() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.removeItem(at: f.audio.appendingPathComponent("b.wav"))
        let clock = TestClock()
        let factory = Factory(
            final: DoubleTranscriber(name: "final", reply: { _ in "texte" }),
            preview: DoubleTranscriber(name: "apercu", reply: { _ in "texte" }))
        await #expect(throws: TranscribeError.missingAudio(["b"])) {
            try await command(f).run(makeEngines: factory.make, pause: { _ in }, now: { clock.now() })
        }
        #expect(factory.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.out.appendingPathComponent("live.md").path))
    }

    @Test func theReportFilesAreWrittenAndTheCommandIsRegistered() throws {
        let names = BenchCommand.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("live"))
        #expect(LiveCommand.reportFiles == ["live.md", "live.json"])
    }
}

// MARK: - Le choix réel des moteurs (N4)

/// `LiveEngines.real` : ce que `--engine` décide vraiment. Construire les moteurs ne charge rien (aucun modèle, aucun réseau).
@Suite(.timeLimit(.minutes(1))) struct LiveEnginesTests {
    @Test func withParakeetThePreviewAndTheFinalEngineAreTheSameInstance() {
        let engines = LiveEngines.real(engine: "parakeet", whisperModel: "small")
        #expect(engines.final is ParakeetTranscriber)
        #expect(engines.preview is ParakeetTranscriber)
        #expect((engines.final as AnyObject) === (engines.preview.map { $0 as AnyObject }))
        #expect(engines.models == ["Parakeet (aperçu)"])
    }

    @Test func withWhisperKitTheFinalEngineIsWhisperKitAndThePreviewStaysParakeet() {
        let engines = LiveEngines.real(engine: "whisperkit", whisperModel: "small")
        #expect(engines.final is WhisperKitTranscriber)
        #expect(engines.preview is ParakeetTranscriber)
        #expect((engines.final as AnyObject) !== (engines.preview.map { $0 as AnyObject }))
        #expect(engines.models == ["Parakeet (aperçu)", "WhisperKit `small`"])
    }

    @Test func theDetectorIsTheStreamingOne() {
        #expect(LiveEngines.real(engine: "whisperkit", whisperModel: "small").detector is FluidStreamingVoiceDetector)
    }

    /// WhisperKit ne se construit qu'avec le modèle demandé, et seulement si le moteur final est WhisperKit.
    @Test func theWhisperEngineIsOnlyBuiltWhenItIsTheChosenEngine() {
        let built = Mutex(0)
        let parakeet = ParakeetTranscriber()
        func make() -> any Transcriber {
            built.withLock { $0 += 1 }
            return WhisperKitTranscriber(model: "small")
        }
        _ = LiveEngines.assemble(
            engine: "parakeet", whisperModel: "small", parakeet: parakeet, whisper: make(),
            detector: FluidStreamingVoiceDetector())
        #expect(built.withLock { $0 } == 0)
        _ = LiveEngines.assemble(
            engine: "whisperkit", whisperModel: "small", parakeet: parakeet, whisper: make(),
            detector: FluidStreamingVoiceDetector())
        #expect(built.withLock { $0 } == 1)
    }
}
