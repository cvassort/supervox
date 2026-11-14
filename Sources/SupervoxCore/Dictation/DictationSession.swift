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
        timeline = SpeechTimeline(blockSize: detector.blockSize, sampleRate: transcriberSampleRate)
        (snapshots, snapshotSink) = AsyncStream<DictationSnapshot>.makeStream()
        snapshotSink.yield(snapshot)
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
        // La pompe vide ce qui était déjà livré, puis s'arrête avec le flux.
        await pump?.value
        guard snapshot.phase == .finalizing else { return }

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
        let text: String
        do {
            text = try await final.transcribe(clip, language: config.language, vocabulary: config.vocabulary)
        } catch {
            guard snapshot.phase == .finalizing else { return }
            fail(.engine(Self.describe(error)))
            return
        }
        // Annulée pendant l'attente : le résultat qui arrive ne change plus rien.
        guard snapshot.phase == .finalizing else { return }
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
        guard ingesting else { return }
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

    /// Le texte d'une erreur, en une raison qui se lit dans une phrase (sans point final).
    private static func describe(_ error: Error) -> String {
        if let capture = error as? AudioCaptureError {
            switch capture {
            case .microphoneAccessDenied(let message): return message
            case .noInputDevice: return "aucun micro utilisable n'a été trouvé"
            case .alreadyRunning: return "le micro est déjà utilisé"
            case .engineFailed(let message): return "le moteur audio a échoué (\(message))"
            }
        }
        if let localized = error as? LocalizedError, let description = localized.errorDescription { return description }
        return String(describing: error)   // `TranscriberError` et les erreurs de test se décrivent par `description`
    }
}
