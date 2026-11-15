import ArgumentParser
import Foundation
import Synchronization
import SupervoxCore
import SupervoxEngines

// MARK: - Le rejeu d'une prise

/// Ce qu'une prise rejouée a donné.
struct LiveOutcome: Equatable {
    /// Le texte final de la session ; `nil` sans résultat.
    var finalText: String?
    /// Le texte en direct tel que l'écran le montrait à la fin de la prise, juste avant `finish()`.
    var lastPreview: String
    /// Secondes entre l'appel de `finish()` et le texte final.
    var finishDelay: Double?
    /// La session a dit qu'aucune parole n'avait été entendue : ni un échec, ni un texte.
    var noSpeech: Bool
    /// Le message d'un échec de la session.
    var failure: String?
}

/// Un verrou qui s'ouvre une fois : `wait()` attend l'ouverture, `open()` la fait (plusieurs fois sans effet de plus).
private final class Latch: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// Le détecteur de voix cadencé : chacun des `pacedBlocks` premiers blocs attend sa propre durée avant d'être traité, si
/// bien que la session reçoit l'audio à la vitesse où un micro le donnerait (le micro scripté livre tout d'un coup, la
/// session le consomme bloc après bloc à travers ce détecteur). Les blocs suivants (le dernier bloc partiel, que
/// `finish()` passe au détecteur) ne sont pas cadencés : la vraie session ne les attend pas non plus. `onPaced` est appelé
/// quand le dernier bloc cadencé est passé : c'est le moment où l'utilisateur appuie sur le raccourci.
private final class PacedDetector: StreamingVoiceDetector, Sendable {
    private let inner: any StreamingVoiceDetector
    private let blockSeconds: Double
    private let pacedBlocks: Int
    private let pause: @Sendable (Double) async -> Void
    private let onPaced: @Sendable () -> Void
    private let count = Mutex(0)

    var blockSize: Int { inner.blockSize }

    init(
        inner: any StreamingVoiceDetector, blockSeconds: Double, pacedBlocks: Int,
        pause: @escaping @Sendable (Double) async -> Void, onPaced: @escaping @Sendable () -> Void
    ) {
        self.inner = inner
        self.blockSeconds = blockSeconds
        self.pacedBlocks = pacedBlocks
        self.pause = pause
        self.onPaced = onPaced
    }

    func prepare() async throws { try await inner.prepare() }

    func reset() async {
        count.withLock { $0 = 0 }
        await inner.reset()
    }

    func process(_ block: [Float]) async throws -> VoiceEvent? {
        let index = count.withLock { value -> Int in
            value += 1
            return value
        }
        if index <= pacedBlocks { await pause(blockSeconds) }
        let event = try await inner.process(block)
        if index == pacedBlocks { onPaced() }
        return event
    }
}

/// Rejoue une prise dans une vraie `DictationSession`, avec le micro scripté, à la vitesse de la parole.
///
/// - L'enregistrement (16 kHz) est livré par tranches de 100 ms, suivi de `settle` secondes de silence : l'utilisateur ne
///   presse pas le raccourci à l'instant où il se tait, et la session voit ce silence comme celui d'une vraie prise.
/// - La cadence vient du détecteur de voix (`PacedDetector`), pas d'une attente avant chaque tranche : la session lit les
///   tranches comme elle le fait avec un vrai micro et lance ses passes d'aperçu au fil de l'audio.
/// - `finish()` est demandé une fois le dernier bloc passé, pas avant : un `finish()` immédiat ferait traiter tout l'audio
///   après coup, sans aperçu, et le délai mesuré serait celui du détecteur sur toute la prise.
enum LiveReplay {
    /// Durée d'une tranche livrée par le micro scripté, en secondes.
    static let chunkSeconds = 0.1

    static func run(
        clip: AudioClip, detector: any StreamingVoiceDetector, preview: (any Transcriber)?, final: any Transcriber,
        config: DictationConfig, settle: Double, pause: @escaping @Sendable (Double) async -> Void,
        now: @escaping @Sendable () -> Double
    ) async -> LiveOutcome {
        guard clip.sampleRate == transcriberSampleRate else {
            return LiveOutcome(lastPreview: "", noSpeech: false, failure: "clip à \(Int(clip.sampleRate)) Hz, 16 000 Hz attendus")
        }
        let rate = transcriberSampleRate
        let samples = clip.samples + [Float](repeating: 0, count: max(0, Int((settle * rate).rounded())))
        let chunkSize = max(1, Int(chunkSeconds * rate))
        let chunks = stride(from: 0, to: samples.count, by: chunkSize).map {
            AudioChunk(samples: Array(samples[$0..<min($0 + chunkSize, samples.count)]), sampleRate: rate)
        }
        let blockSize = detector.blockSize
        let target = samples.count / blockSize
        let lastBlockPassed = Latch()
        let paced = PacedDetector(
            inner: detector, blockSeconds: Double(blockSize) / rate, pacedBlocks: target, pause: pause,
            onPaced: { lastBlockPassed.open() })
        let session = DictationSession(
            feed: ScriptedMicrophoneFeed(chunks: chunks), detector: paced, preview: preview, final: final, config: config,
            now: now)

        let ended = Mutex(false)
        let recorder = Task { () -> (lastPreview: String, terminal: DictationPhase?) in
            var lastPreview = ""
            var terminal: DictationPhase?
            for await snapshot in session.snapshots {
                if snapshot.phase == .recording { lastPreview = snapshot.liveText }
                if snapshot.phase.isTerminal {
                    terminal = snapshot.phase
                    ended.withLock { $0 = true }
                    lastBlockPassed.open()
                }
            }
            // Le flux fini sans phase terminale : rien ne doit rester pendu.
            ended.withLock { $0 = true }
            lastBlockPassed.open()
            return (lastPreview, terminal)
        }

        await session.start()
        if target == 0 { lastBlockPassed.open() }
        await lastBlockPassed.wait()
        var delay: Double?
        if !ended.withLock({ $0 }) {
            let began = now()
            await session.finish()
            delay = now() - began
        }
        let recording = await recorder.value

        switch recording.terminal {
        case .finished(let text)?:
            return LiveOutcome(finalText: text, lastPreview: recording.lastPreview, finishDelay: delay, noSpeech: false)
        case .failed(.noSpeech)?:
            return LiveOutcome(lastPreview: recording.lastPreview, noSpeech: true)
        case .failed(let failure)?:
            return LiveOutcome(lastPreview: recording.lastPreview, noSpeech: false, failure: failure.message)
        default:
            return LiveOutcome(
                lastPreview: recording.lastPreview, noSpeech: false, failure: "la session s'est arrêtée sans résultat")
        }
    }
}

// MARK: - Le passage sur le corpus

/// Une phrase du corpus, mesurée.
struct LiveItemResult: Codable, Equatable {
    let id: String
    /// Le texte final de la session.
    let finalText: String?
    /// La transcription en bloc de la même prise par le même moteur (la mesure de l'étape 1).
    let blockText: String?
    let lastPreview: String
    let finishDelay: Double?
    /// La session n'a entendu aucune parole.
    let noSpeech: Bool
    /// Échec de la phrase (audio illisible, moteur, session) ; `nil` si la session a rendu un texte ou « aucune parole ».
    let failure: String?
    /// Échec de la transcription en bloc seule.
    let blockFailure: String?

    init(
        id: String, finalText: String? = nil, blockText: String? = nil, lastPreview: String = "", finishDelay: Double? = nil,
        noSpeech: Bool = false, failure: String? = nil, blockFailure: String? = nil
    ) {
        self.id = id
        self.finalText = finalText
        self.blockText = blockText
        self.lastPreview = lastPreview
        self.finishDelay = finishDelay
        self.noSpeech = noSpeech
        self.failure = failure
        self.blockFailure = blockFailure
    }
}

enum LiveBench {
    /// Rejoue chaque phrase, l'une après l'autre (jamais en parallèle : les durées seraient faussées), et la transcrit aussi
    /// en bloc avec le même moteur final et le même vocabulaire.
    ///
    /// - Le détecteur, le moteur final et le moteur d'aperçu sont préparés et préchauffés une fois, hors mesure ; si l'un
    ///   des deux premiers échoue, chaque phrase porte l'échec (un moteur d'aperçu qui ne se prépare pas n'arrête pas la
    ///   dictée, la session s'en passe).
    /// - Un audio illisible est l'échec de sa phrase, pas de la commande.
    /// - `afterItem` reçoit les résultats après chaque phrase : la commande réécrit son rapport au fil de l'eau.
    static func run(
        corpus: [CorpusItem], audio: (String) throws -> AudioClip, detector: any StreamingVoiceDetector,
        preview: (any Transcriber)?, final: any Transcriber, settle: Double, sessionConfig: DictationConfig,
        pause: @escaping @Sendable (Double) async -> Void, now: @escaping @Sendable () -> Double,
        progress: (String) -> Void, afterItem: ([LiveItemResult]) -> Void = { _ in }
    ) async -> [LiveItemResult] {
        var setupFailure: String?
        progress("préparation du détecteur de voix et des moteurs…")
        do { try await detector.prepare() } catch { setupFailure = "détecteur de voix : \(describe(error))" }
        if setupFailure == nil {
            do { try await final.prepare() } catch { setupFailure = "chargement du moteur final : \(describe(error))" }
        }
        if setupFailure == nil {
            do { try await final.warmUp(vocabulary: sessionConfig.vocabulary) } catch {
                setupFailure = "préchauffage du moteur final : \(describe(error))"
            }
        }
        if setupFailure == nil, let preview {
            try? await preview.prepare()
            try? await preview.warmUp(vocabulary: sessionConfig.vocabulary)
        }

        var results: [LiveItemResult] = []
        for (index, item) in corpus.enumerated() {
            progress("\(index + 1)/\(corpus.count) : \(item.id)")
            if let setupFailure {
                results.append(LiveItemResult(id: item.id, failure: setupFailure))
                afterItem(results)
                continue
            }
            let clip: AudioClip
            do { clip = try audio(item.id) } catch {
                results.append(LiveItemResult(id: item.id, failure: "audio illisible : \(describe(error))"))
                afterItem(results)
                continue
            }
            var blockText: String?
            var blockFailure: String?
            do {
                blockText = try await final.transcribe(
                    clip, language: sessionConfig.language, vocabulary: sessionConfig.vocabulary)
            } catch {
                blockFailure = "transcription en bloc : \(describe(error))"
            }
            let outcome = await LiveReplay.run(
                clip: clip, detector: detector, preview: preview, final: final, config: sessionConfig, settle: settle,
                pause: pause, now: now)
            results.append(
                LiveItemResult(
                    id: item.id, finalText: outcome.finalText, blockText: blockText, lastPreview: outcome.lastPreview,
                    finishDelay: outcome.finishDelay, noSpeech: outcome.noSpeech, failure: outcome.failure,
                    blockFailure: blockFailure))
            afterItem(results)
        }
        return results
    }
}

// MARK: - Les chiffres

/// Les chiffres d'un passage. Les taux se calculent sur les phrases où la session a rendu un texte **et** où la
/// transcription en bloc en a rendu un : les trois taux portent ainsi sur les mêmes mots. Une phrase sans parole entendue,
/// ou en échec, est hors de tout taux (et comptée à part) ; une phrase du corpus sans résultat est un échec.
struct LiveSummary: Codable, Equatable {
    let phrases: Int
    let compared: Int
    let noSpeech: Int
    let failures: Int
    /// Taux d'erreur de mots agrégé du texte final de la session, de la transcription en bloc, du dernier aperçu.
    let finalWER: Double?
    let blockWER: Double?
    let previewWER: Double?
    /// Phrases comparées dont le dernier aperçu était vide (compté, chaque mot de la référence, comme omis).
    let previewEmpty: Int
    let termsTotal: Int
    let finalTermsFound: Int
    let blockTermsFound: Int
    let previewTermsFound: Int
    /// Délai entre `finish()` et le texte final, sur les phrases où la session a rendu un texte.
    let delayMedian: Double?
    let delayP90: Double?

    init(corpus: [CorpusItem], results: [LiveItemResult]) {
        var byID: [String: LiveItemResult] = [:]
        for result in results where byID[result.id] == nil { byID[result.id] = result }

        var final = Tally(), block = Tally(), live = Tally()
        var compared = 0, noSpeech = 0, failures = 0, previewEmpty = 0, termsTotal = 0
        var delays: [Double] = []
        for item in corpus {
            guard let result = byID[item.id] else { failures += 1; continue }
            if result.noSpeech { noSpeech += 1; continue }
            guard let finalText = result.finalText else { failures += 1; continue }
            if let delay = result.finishDelay { delays.append(delay) }
            guard let blockText = result.blockText else { failures += 1; continue }
            compared += 1
            final.add(item, finalText)
            block.add(item, blockText)
            live.add(item, result.lastPreview)
            termsTotal += item.terms.count
            if result.lastPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { previewEmpty += 1 }
        }
        phrases = corpus.count
        self.compared = compared
        self.noSpeech = noSpeech
        self.failures = failures
        finalWER = compared > 0 ? final.rate : nil
        blockWER = compared > 0 ? block.rate : nil
        previewWER = compared > 0 ? live.rate : nil
        self.previewEmpty = previewEmpty
        self.termsTotal = termsTotal
        finalTermsFound = final.found
        blockTermsFound = block.found
        previewTermsFound = live.found
        delayMedian = Reports.percentile(delays, 0.5)
        delayP90 = Reports.percentile(delays, 0.9)
    }

    /// Erreurs de mots et termes retrouvés, cumulés sur les phrases comparées.
    private struct Tally {
        var substitutions = 0, deletions = 0, insertions = 0, words = 0, found = 0

        mutating func add(_ item: CorpusItem, _ hypothesis: String) {
            let counts = WordErrorRate.compute(reference: item.text, hypothesis: hypothesis)
            substitutions += counts.substitutions
            deletions += counts.deletions
            insertions += counts.insertions
            words += counts.referenceCount
            found += TermRecall.compute(terms: item.terms, hypothesis: hypothesis).found
        }

        var rate: Double {
            ErrorCounts(substitutions: substitutions, deletions: deletions, insertions: insertions, referenceCount: words).rate
        }
    }
}

// MARK: - Le rapport

enum LiveReport {
    /// Ce que la dictée en direct ne sait pas faire, dit tel quel dans le rapport.
    static let previewLimit =
        "Limite connue : le texte en direct peut perdre le début d'un passage de parole de plus de 15 s (le moteur "
        + "d'aperçu ne reçoit que les 15 dernières secondes du passage ouvert). Le texte final, lui, est complet."

    static func markdown(
        corpus: [CorpusItem], results: [LiveItemResult], vocabulary: [String], settle: Double, engine: String,
        launch: LaunchInfo, progress: ReportProgress? = nil
    ) -> String {
        let summary = LiveSummary(corpus: corpus, results: results)
        let config = DictationConfig(language: "fr")
        var text = "# Dictée en direct\n\n"
        if let progress { text += Reports.partialBanner(progress, unit: "phrase(s)") }
        text += "\(corpus.count) phrase(s), moteur final : \(engine), aperçu : parakeet. "
        text += vocabulary.isEmpty
            ? "Sans vocabulaire global.\n\n"
            : "Vocabulaire global (\(vocabulary.count) terme(s)) : \(vocabulary.joined(separator: ", ")).\n\n"

        text += "| Mesure | Valeur |\n|---|---|\n"
        text += "| Phrases comparées | \(summary.compared) sur \(summary.phrases) |\n"
        text += "| Texte final de la session (taux d'erreur) | \(percent(summary.finalWER)) |\n"
        text += "| Transcription en bloc (étape 1, même moteur) | \(percent(summary.blockWER)) |\n"
        text += "| Dernier aperçu | \(percent(summary.previewWER)) |\n"
        text += "| Termes trouvés, texte final / bloc / aperçu | "
            + (summary.termsTotal > 0
                ? "\(summary.finalTermsFound) / \(summary.blockTermsFound) / \(summary.previewTermsFound) sur \(summary.termsTotal)"
                : "—") + " |\n"
        text += "| Délai de `finish()` au texte final, médiane (s) | \(seconds(summary.delayMedian)) |\n"
        text += "| Délai de `finish()` au texte final, 90e centile (s) | \(seconds(summary.delayP90)) |\n"
        text += "| Aperçu vide à la fin | \(summary.previewEmpty) sur \(summary.compared) |\n"
        text += "| Sans parole entendue | \(summary.noSpeech) |\n"
        text += "| Échecs | \(summary.failures) |\n"
        if summary.failures > 0 {
            text += "\nAttention : \(summary.failures) phrase(s) sans comparaison possible (échec ou texte manquant) : "
                + "les taux ne portent que sur les \(summary.compared) autres.\n"
        }

        text += "\n## Méthode\n\n"
        text += "- Chaque enregistrement est rejoué dans une vraie session de dictée, avec le micro scripté, par tranches de "
            + "\(Int(LiveReplay.chunkSeconds * 1000)) ms, à la vitesse de la parole : la cadence vient du détecteur de voix, "
            + "qui attend la durée de chaque bloc avant de le traiter.\n"
        text += "- Après l'enregistrement, \(Reports.decimal(settle, digits: 1)) s de silence sont ajoutées (le temps que "
            + "l'utilisateur presse le raccourci), puis `finish()` est demandé quand le dernier bloc est passé.\n"
        text += "- Réglages de la session : passe d'aperçu au plus toutes les \(Reports.decimal(config.previewInterval, digits: 1)) s "
            + "sur les \(Int(config.previewWindow)) dernières secondes du passage ouvert, marge de "
            + "\(Reports.decimal(config.padding, digits: 1)) s autour de la parole, durée maximale \(Int(config.maxDuration)) s.\n"
        text += "- Transcription en bloc : le même moteur final (même exemplaire, même vocabulaire) sur l'enregistrement entier, "
            + "sans détecteur de voix ni marge : la mesure de l'étape 1.\n"
        text += "- Les taux comparent des mots normalisés (voir `README.md`, « Comparaison des textes ») et portent sur les mêmes "
            + "phrases pour les trois lignes. Le délai part de l'appel de `finish()` et s'arrête au texte final ; il comprend "
            + "le dernier bloc du détecteur et la transcription par le moteur final.\n"
        text += "\n## Limites\n\n- \(previewLimit)\n"
        text += "- Le rejeu est à 16 kHz : le rééchantillonnage d'un vrai micro (44,1 ou 48 kHz) n'est pas exercé.\n"
        text += "- Le détecteur de voix passe chaque bloc après sa durée d'attente : le rejeu est un peu plus lent que le temps réel "
            + "(la durée du traitement s'y ajoute).\n"
        text += launchSection(launch)

        text += "\n## Phrases\n\n"
        var byID: [String: LiveItemResult] = [:]
        for result in results where byID[result.id] == nil { byID[result.id] = result }
        var lines: [String] = []
        for item in corpus {
            guard let result = byID[item.id] else { lines.append("- `\(item.id)` — aucun résultat"); continue }
            if result.noSpeech { lines.append("- `\(item.id)` — aucune parole entendue"); continue }
            if let failure = result.failure { lines.append("- `\(item.id)` — échec : \(Reports.oneLine(failure))"); continue }
            guard let finalText = result.finalText else { lines.append("- `\(item.id)` — aucun texte final"); continue }
            let finalErrors = errors(item, finalText)
            let blockErrors = result.blockText.map { errors(item, $0) }
            let previewErrors = errors(item, result.lastPreview)
            guard finalErrors > 0 || (blockErrors ?? 0) > 0 || previewErrors > 0 || result.blockText == nil else { continue }
            var line = "- `\(item.id)` — texte final \(finalErrors) erreur(s), bloc "
                + (blockErrors.map(String.init) ?? "échec") + ", aperçu \(previewErrors), sur "
                + "\(WordErrorRate.compute(reference: item.text, hypothesis: finalText).referenceCount) mot(s)"
            if let delay = result.finishDelay { line += ", délai \(Reports.decimal(delay, digits: 2)) s" }
            line += "\n  - référence : \(Reports.oneLine(item.text))\n  - texte final : \(Reports.oneLine(finalText))"
            if let block = result.blockText { line += "\n  - bloc : \(Reports.oneLine(block))" }
            if let failure = result.blockFailure { line += "\n  - bloc : \(Reports.oneLine(failure))" }
            line += "\n  - aperçu : \(Reports.oneLine(result.lastPreview))"
            lines.append(line)
        }
        text += lines.isEmpty ? "Aucune phrase fautive.\n" : lines.joined(separator: "\n") + "\n"
        return text
    }

    static func json(
        corpus: [CorpusItem], results: [LiveItemResult], vocabulary: [String], settle: Double, engine: String,
        progress: ReportProgress?
    ) throws -> Data {
        struct Document: Encodable {
            let complete: Bool
            let engine: String
            let settleSeconds: Double
            let vocabulary: [String]
            let summary: LiveSummary
            let items: [LiveItemResult]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            Document(
                complete: progress == nil, engine: engine, settleSeconds: settle, vocabulary: vocabulary,
                summary: LiveSummary(corpus: corpus, results: results), items: results))
    }

    private static func errors(_ item: CorpusItem, _ hypothesis: String) -> Int {
        let counts = WordErrorRate.compute(reference: item.text, hypothesis: hypothesis)
        return counts.substitutions + counts.deletions + counts.insertions
    }

    private static func percent(_ value: Double?) -> String {
        value.map { Reports.decimal($0 * 100, digits: 1) + " %" } ?? "—"
    }

    private static func seconds(_ value: Double?) -> String {
        value.map { Reports.decimal($0, digits: 2) } ?? "—"
    }

    private static func launchSection(_ launch: LaunchInfo) -> String { Reports.launchSection(launch) }
}

// MARK: - La commande

struct LiveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "live",
        abstract: "Rejoue les enregistrements du corpus dans une vraie session de dictée et mesure le texte final, le dernier aperçu et le délai."
    )

    @Option(name: .long, help: "Fichier du corpus (TSV : id, texte, termes).")
    var corpus: String

    @Option(name: .long, help: "Dossier des enregistrements : <dossier>/<id>.wav.")
    var audio: String

    @Option(name: .long, help: "Dossier de sortie : live.md et live.json.")
    var out: String

    @Flag(name: .long, help: "Remplace live.md et live.json s'ils existent (sinon la commande refuse).")
    var overwrite = false

    @Option(name: .long, help: "Moteur du texte final : whisperkit ou parakeet. L'aperçu est toujours Parakeet.")
    var engine = "whisperkit"

    @Option(name: .long, help: "Variante du modèle WhisperKit.")
    var whisperkitModel = "large-v3-v20240930_turbo"

    @Option(name: .long, help: "Vocabulaire global, un terme par ligne (même format et mêmes contrôles que `transcribe`).")
    var vocabulary: String?

    @Option(
        name: .long,
        help: "Secondes de silence ajoutées après chaque enregistrement avant `finish()` (le temps de presser le raccourci).")
    var settle = 1.0

    static let reportFiles = ["live.md", "live.json"]
    static let language = "fr"

    func run() async throws {
        // Tout ce qui peut être refusé l'est avant de lire quoi que ce soit et de charger le moindre modèle.
        guard ["whisperkit", "parakeet"].contains(engine) else { throw TranscribeError.unknownEngine(engine) }
        guard settle >= 0, settle.isFinite else { throw ValidationError("--settle doit être positif ou nul") }
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try OutputGuard.checkIgnoredByGit(
            directory, content: "ces rapports contiennent ce que tu as dit (transcriptions) et ton vocabulaire")
        try OutputGuard.checkNotExisting(Self.reportFiles.map { directory.appendingPathComponent($0) }, overwrite: overwrite)

        let launchedAt = Date()
        let items = try Corpus.load(from: URL(fileURLWithPath: corpus))
        let terms = try await GlobalVocabulary.load(
            vocabulary, whisperKitModel: engine == "whisperkit" ? whisperkitModel : nil, say: { print($0) })
        let clips = try CorpusAudio.load(items, from: URL(fileURLWithPath: audio, isDirectory: true))

        let parakeet = ParakeetTranscriber()
        let final: any Transcriber = engine == "parakeet" ? parakeet : WhisperKitTranscriber(model: whisperkitModel)
        var models = ["Parakeet (aperçu)"]
        if engine == "whisperkit" { models.append("WhisperKit `\(whisperkitModel)`") }
        let launch = LaunchInfo(
            date: launchedAt, models: models,
            capture: CaptureLog.summary(of: URL(fileURLWithPath: audio, isDirectory: true), ids: items.map(\.id)))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let results = await LiveBench.run(
            corpus: items, audio: { id in
                guard let clip = clips[id] else { throw TranscribeError.missingAudio([id]) }
                return clip
            }, detector: FluidStreamingVoiceDetector(), preview: parakeet, final: final, settle: settle,
            sessionConfig: DictationConfig(language: Self.language, vocabulary: terms),
            pause: { try? await Task.sleep(for: .seconds($0)) },
            now: { ProcessInfo.processInfo.systemUptime }, progress: { print($0) },
            afterItem: { done in
                // Rapport réécrit après chaque phrase : un arrêt en cours de route garde ce qui est fait.
                do {
                    try write(
                        directory, items: items, results: done, vocabulary: terms, launch: launch,
                        progress: done.count < items.count ? ReportProgress(done: done.count, planned: items.count) : nil)
                } catch {
                    print("Attention : rapport partiel non écrit : \(describe(error))")
                }
            })
        try write(directory, items: items, results: results, vocabulary: terms, launch: launch, progress: nil)

        let summary = LiveSummary(corpus: items, results: results)
        print("")
        print("Phrases comparées : \(summary.compared) sur \(summary.phrases)")
        print("Rapport : \(directory.appendingPathComponent("live.md").path)")
    }

    private func write(
        _ directory: URL, items: [CorpusItem], results: [LiveItemResult], vocabulary: [String], launch: LaunchInfo,
        progress: ReportProgress?
    ) throws {
        let markdown = LiveReport.markdown(
            corpus: items, results: results, vocabulary: vocabulary, settle: settle, engine: engine, launch: launch,
            progress: progress)
        try markdown.write(to: directory.appendingPathComponent("live.md"), atomically: true, encoding: .utf8)
        try LiveReport.json(
            corpus: items, results: results, vocabulary: vocabulary, settle: settle, engine: engine, progress: progress
        ).write(to: directory.appendingPathComponent("live.json"), options: .atomic)
    }
}
