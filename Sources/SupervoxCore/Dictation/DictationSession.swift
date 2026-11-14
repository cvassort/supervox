import Foundation

/// Une prise de dictée : relie le micro, le détecteur de voix en flux, l'aperçu en direct et la transcription finale.
///
/// Fonctionnement :
/// - Le rappel du micro ne fait que passer la tranche à un `AsyncStream` (sans attente, ordre conservé) : ni détection
///   ni transcription sur le fil audio, et `feed.stop()` n'est jamais appelé depuis lui. Le flux est créé **avant**
///   `feed.start()` : un micro qui livre pendant `start` (le micro scripté des tests) ne perd aucune tranche.
/// - **Une seule** tâche (la pompe) lit ce flux : rééchantillonnage à 16 kHz, ajout à la `SpeechTimeline`, puis
///   les blocs vont au détecteur l'un après l'autre, dans l'ordre de la prise (l'ordre entre tâches indépendantes
///   n'est pas garanti par la `SerialGate` du détecteur).
/// - À `finish()`, la capture est arrêtée, la pompe vide ce qui reste, la queue du rééchantillonneur et le dernier
///   bloc partiel passent au détecteur (`speechEnd` n'arrive qu'après environ une seconde de silence : un passage peut
///   rester ouvert), puis `spokenClip(padding:)` part au moteur final.
/// - Un acteur accepte d'autres appels à chaque `await` : la phase est relue après chaque attente (une annulation, ou
///   un échec, peut être passé entre-temps) et une phase terminale ne change plus.
///
/// Pas de durée minimale de passage : le détecteur n'en a pas et aucune mesure ne permet d'en fixer une ; un bruit bref
/// pris pour de la voix part donc au moteur final, dont un texte vide donne `failed(.noSpeech)`.
public actor DictationSession: DictationSessioning {
    public nonisolated let snapshots: AsyncStream<DictationSnapshot>
    private let snapshotSink: AsyncStream<DictationSnapshot>.Continuation

    private let feed: any MicrophoneFeed
    private let detector: any StreamingVoiceDetector
    private let preview: (any Transcriber)?
    private let final: any Transcriber
    private let config: DictationConfig
    private let now: @Sendable () -> Double
    /// Pour les tests : fabrique du rééchantillonneur (fréquence du micro, fréquence cible).
    private let makeResampler: @Sendable (Double, Double) -> StreamingResampler?

    private var snapshot = DictationSnapshot()
    private var timeline: SpeechTimeline
    private var resampler: StreamingResampler?
    private var inputRate: Double?
    private var startedAt = 0.0

    // Aperçu : un seul travailleur à la fois, hors de la pompe.
    private enum PreviewPass {
        /// Le passage clos qui commence à cet échantillon.
        case closed(start: Int)
        /// Le passage ouvert qui commence à cet échantillon.
        case open(start: Int)
    }
    private var previewUsable: Bool
    private var previewBusy = false
    private var previewTask: Task<Void, Never>?
    /// La transcription finale : retenue pour que `cancel()` puisse l'annuler (un moteur qui respecte l'annulation de
    /// tâche s'arrête, au lieu de calculer pour rien).
    private var finalTask: Task<String, Error>?
    /// Textes des passages clos, dans l'ordre : le rang est celui du passage dans `timeline.closedSegments`.
    private var frozenTexts: [String] = []
    private var openText = ""
    /// Début du passage dont `openText` est le texte. Un passage qui se ferme garde son texte affiché jusqu'à ce que
    /// sa passe de passage clos le fige : le texte ne clignote pas.
    private var openTextStart: Int?
    private var lastOpenPassAt: Double?
    private var maxDurationReached = false
    /// Pour les tests : appelée à la fin de chaque passe d'aperçu, résultat pris en compte ou non.
    private var previewPassDidFinish: (@Sendable () -> Void)?

    private var chunkSink: AsyncStream<AudioChunk>.Continuation?
    private var pump: Task<Void, Never>?
    /// Vrai de l'ouverture du micro jusqu'à la fin de la vidange : la pompe n'accepte plus de tranche ensuite.
    private var ingesting = false
    private var captureRunning = false

    public init(feed: any MicrophoneFeed, detector: any StreamingVoiceDetector, preview: (any Transcriber)?,
                final: any Transcriber, config: DictationConfig, now: @escaping @Sendable () -> Double) {
        self.init(feed: feed, detector: detector, preview: preview, final: final, config: config, now: now,
                  makeResampler: { StreamingResampler(from: $0, to: $1) })
    }

    init(feed: any MicrophoneFeed, detector: any StreamingVoiceDetector, preview: (any Transcriber)?,
         final: any Transcriber, config: DictationConfig, now: @escaping @Sendable () -> Double,
         makeResampler: @escaping @Sendable (Double, Double) -> StreamingResampler?) {
        self.feed = feed
        self.detector = detector
        self.preview = preview
        self.final = final
        self.config = config
        self.now = now
        self.makeResampler = makeResampler
        previewUsable = preview != nil
        timeline = SpeechTimeline(blockSize: detector.blockSize, sampleRate: transcriberSampleRate)
        (snapshots, snapshotSink) = AsyncStream<DictationSnapshot>.makeStream()
        snapshotSink.yield(snapshot)
    }

    /// Pour les tests : la phase courante, y compris après la fin du flux d'instantanés (qui, lui, ne montre plus rien
    /// après une phase terminale).
    var phase: DictationPhase { snapshot.phase }

    /// Pour les tests : nombre de passes d'aperçu lancées depuis le début de la session.
    private(set) var previewPassesLaunched = 0

    /// Pour les tests : rend la main quand la pompe a fini (flux vidé ou annulée).
    func waitUntilPumpEnds() async {
        await pump?.value
    }

    /// Niveau affichable d'une tranche : RMS en décibels, ramené sur 0…1 (−60 dB → 0, 0 dB → 1). Une tranche vide ou
    /// non numérique donne 0.
    public static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        let decibels = 10 * log10(power)   // 10·log10 de la puissance = 20·log10 du RMS
        let level = (decibels + 60) / 60
        return level.isNaN ? 0 : Float(min(max(level, 0), 1))
    }

    // MARK: - Cycle de la prise

    public func start() async {
        guard snapshot.phase == .idle else { return }
        setPhase(.preparing)
        do {
            try await detector.prepare()
            guard snapshot.phase == .preparing else { return }
            await detector.reset()
            guard snapshot.phase == .preparing else { return }
            try await final.prepare()
        } catch {
            guard snapshot.phase == .preparing else { return }
            fail(.engine(Self.describe(error)))
            return
        }
        guard snapshot.phase == .preparing else { return }
        // Un aperçu qui ne se prépare pas n'empêche pas la dictée : la prise se passe de texte provisoire.
        if let preview {
            do { try await preview.prepare() } catch { previewUsable = false }
            guard snapshot.phase == .preparing else { return }
        }

        let (chunks, sink) = AsyncStream<AudioChunk>.makeStream()
        do {
            // Le rappel ne fait que transmettre : voir la description de la classe.
            try feed.start { sink.yield($0) }
        } catch {
            sink.finish()
            fail(.microphone(Self.describe(error)))
            return
        }
        chunkSink = sink
        captureRunning = true
        ingesting = true
        startedAt = now()
        setPhase(.recording)
        pump = Task { [weak self] in
            for await chunk in chunks {
                guard let self else { return }
                await self.handle(chunk)
            }
        }
    }

    public func finish() async {
        guard snapshot.phase == .recording else { return }
        setPhase(.finalizing)
        stopCapture()
        // Le moteur d'aperçu peut être le moteur final : une passe d'aperçu ne le retient pas pendant `finalizing`.
        cancelPreview()
        // La pompe vide ce qui était déjà livré, puis s'arrête avec le flux.
        await pump?.value

        if let resampler {
            guard await ingest(resampler.finish()), !failIfResamplerFailed(resampler) else { return }
        }
        // `flush` reçoit la ligne de temps en `inout` : sur une propriété d'acteur, à travers un `await`, c'est refusé
        // (et dangereux) ; la pompe est vidée, personne d'autre ne l'écrit ici.
        var flushed = timeline
        do {
            _ = try await detector.flush(&flushed)
        } catch {
            guard snapshot.phase == .finalizing else { return }
            fail(.engine(Self.describe(error)))
            return
        }
        guard snapshot.phase == .finalizing else { return }
        timeline = flushed
        ingesting = false

        guard let clip = timeline.spokenClip(padding: config.padding) else {
            fail(.noSpeech)
            return
        }
        let engine = final
        let language = config.language
        let vocabulary = config.vocabulary
        let transcription = Task { try await engine.transcribe(clip, language: language, vocabulary: vocabulary) }
        finalTask = transcription
        let text: String
        do {
            // Une tâche appelante annulée annule aussi le moteur.
            text = try await withTaskCancellationHandler { try await transcription.value } onCancel: { transcription.cancel() }
        } catch is CancellationError {
            // Annulation (de la session ou de l'appelant) : ce n'est pas une panne du moteur.
            setPhase(.cancelled)
            return
        } catch {
            guard snapshot.phase == .finalizing else { return }
            fail(.engine(Self.describe(error)))
            return
        }
        // Annulée pendant l'attente : `setPhase` refuse tout changement depuis une phase terminale, le résultat qui
        // arrive ne change donc plus rien.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            fail(.noSpeech)
            return
        }
        setPhase(.finished(trimmed))
    }

    public func cancel() async {
        guard !snapshot.phase.isTerminal else { return }
        setPhase(.cancelled)
    }

    // MARK: - Pompe

    private func handle(_ chunk: AudioChunk) async {
        if let rate = inputRate {
            guard chunk.sampleRate == rate else {
                fail(.microphone("la fréquence du micro a changé en cours de prise"))
                return
            }
        } else {
            guard let made = makeResampler(chunk.sampleRate, transcriberSampleRate) else {
                fail(.microphone("fréquence du micro inutilisable (\(chunk.sampleRate) Hz)"))
                return
            }
            resampler = made
            inputRate = chunk.sampleRate
        }
        guard let resampler else { return }
        snapshot.level = Self.level(of: chunk.samples)
        let converted = resampler.push(chunk.samples)
        guard !failIfResamplerFailed(resampler), await ingest(converted) else { return }
        snapshot.elapsed = now() - startedAt
        schedulePreview(includingOpenSegment: true)
        emit()
        if snapshot.elapsed >= config.maxDuration, !maxDurationReached {
            maxDurationReached = true
            // Une tâche à part : `finish()` attend la pompe, qui est justement en train d'appeler ceci.
            Task { [weak self] in await self?.finish() }
        }
    }

    // MARK: - Aperçu

    /// Lance au plus une passe d'aperçu, jamais pendant une autre. D'abord les passages clos (une fois chacun, dans
    /// l'ordre, sans attendre), puis le passage ouvert, au plus une fois par `previewInterval` (de début de passe à début
    /// de passe) et sur ses `previewWindow` dernières secondes. Les passages ne sont pas élargis de `padding` : c'est un
    /// aperçu, le moteur final a le dernier mot.
    private func schedulePreview(includingOpenSegment: Bool) {
        guard snapshot.phase == .recording, previewUsable, let preview, !previewBusy else { return }
        let pass: PreviewPass
        let clip: AudioClip
        if frozenTexts.count < timeline.closedSegments.count {
            let segment = timeline.closedSegments[frozenTexts.count]
            pass = .closed(start: segment.lowerBound)
            clip = timeline.clip(of: segment)
        } else if includingOpenSegment, let start = timeline.openSegmentStart,
                  lastOpenPassAt.map({ now() - $0 >= config.previewInterval }) ?? true,
                  let openClip = timeline.openClip(maxSeconds: config.previewWindow) {
            lastOpenPassAt = now()
            pass = .open(start: start)
            clip = openClip
        } else {
            return
        }
        previewBusy = true
        previewPassesLaunched += 1
        let language = config.language
        let vocabulary = config.vocabulary
        previewTask = Task { [weak self] in
            let result: Result<String, Error>
            do {
                result = .success(try await preview.transcribe(clip, language: language, vocabulary: vocabulary))
            } catch {
                result = .failure(error)
            }
            await self?.previewFinished(pass, result)
        }
    }

    /// Annule la passe d'aperçu en cours, s'il y en a une ; son résultat, quand il arrive, est ignoré.
    private func cancelPreview() {
        previewTask?.cancel()
        previewTask = nil
        previewBusy = false
    }

    /// Pour les tests : de quoi attendre qu'une passe d'aperçu ait été traitée par la session.
    func onPreviewPassFinished(_ hook: @escaping @Sendable () -> Void) {
        previewPassDidFinish = hook
    }

    private func previewFinished(_ pass: PreviewPass, _ result: Result<String, Error>) {
        defer { previewPassDidFinish?() }
        previewBusy = false
        // Après `recording`, le texte provisoire ne compte plus.
        guard snapshot.phase == .recording else { return }
        switch pass {
        case .closed(let start):
            // Une erreur n'est pas retentée (le moteur final couvrira ce passage) : le passage garde le texte qu'il
            // avait comme passage ouvert, s'il en avait un.
            var text = openTextStart == start ? openText : ""
            if case .success(let transcript) = result { text = transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
            frozenTexts.append(text)
            if openTextStart == start {
                openText = ""
                openTextStart = nil
            }
        case .open(let start):
            // Un passage clos entre-temps : sa propre passe donnera son texte. Une erreur laisse le texte tel quel.
            guard case .success(let transcript) = result, timeline.openSegmentStart == start else { break }
            openText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            openTextStart = start
        }
        snapshot.liveText = (frozenTexts + [openText]).filter { !$0.isEmpty }.joined(separator: " ")
        schedulePreview(includingOpenSegment: false)
        emit()
    }

    /// Ajoute `samples` (16 kHz) à la ligne de temps et passe les blocs complets au détecteur, un par un, dans l'ordre.
    /// `false` si la prise est interrompue (erreur du détecteur, annulation) ; la session est alors déjà terminale.
    private func ingest(_ samples: [Float]) async -> Bool {
        for block in timeline.append(samples) {
            guard ingesting else { return false }
            do {
                if let event = try await detector.process(block) { timeline.apply(event) }
            } catch {
                guard !snapshot.phase.isTerminal else { return false }
                fail(.engine(Self.describe(error)))
                return false
            }
        }
        return ingesting
    }

    /// Une panne du convertisseur rend un flux tronqué : la prise est abandonnée plutôt que transcrite à moitié.
    private func failIfResamplerFailed(_ resampler: StreamingResampler) -> Bool {
        guard resampler.hasFailed else { return false }
        if !snapshot.phase.isTerminal { fail(.microphone("la conversion de l'audio a échoué")) }
        return true
    }

    // MARK: - État

    private func stopCapture() {
        guard captureRunning else { return }
        captureRunning = false
        // Depuis l'acteur, jamais depuis le rappel du micro (précondition fatale) ; le rappel ne prend aucun verrou
        // d'ici, donc l'attente de `stop()` ne peut pas se bloquer.
        feed.stop()
        chunkSink?.finish()
        chunkSink = nil
    }

    private func setPhase(_ phase: DictationPhase) {
        guard !snapshot.phase.isTerminal else { return }
        snapshot.phase = phase
        if phase.isTerminal {
            ingesting = false
            stopCapture()
            pump?.cancel()
            cancelPreview()
            finalTask?.cancel()
        }
        emit()
        if phase.isTerminal { snapshotSink.finish() }
    }

    private func fail(_ failure: DictationFailure) {
        setPhase(.failed(failure))
    }

    private func emit() {
        snapshotSink.yield(snapshot)
    }

    /// Le texte d'une erreur, en une raison qui se lit dans une phrase (sans point final). Jamais le texte brut d'une
    /// erreur inconnue : une erreur système (`URLError`…) y met l'adresse du service. Les erreurs connues (`AudioCaptureError`,
    /// `TranscriberError`) et celles qui portent un message d'elles-mêmes (`LocalizedError`) gardent leur message ; le
    /// reste devient une phrase générique.
    private static func describe(_ error: Error) -> String {
        if let capture = error as? AudioCaptureError {
            switch capture {
            case .microphoneAccessDenied(let message): return message
            case .noInputDevice: return "aucun micro utilisable n'a été trouvé"
            case .alreadyRunning: return "le micro est déjà utilisé"
            case .engineFailed(let message): return "le moteur audio a échoué (\(message))"
            }
        }
        if let transcriber = error as? TranscriberError { return transcriber.description }
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        return "erreur inattendue"
    }
}
