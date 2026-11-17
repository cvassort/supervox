import Foundation
import os

/// L'entretien vocal : écoute, transcription, réflexion du modèle rapide, parole phrase par phrase, conclusion du modèle fort.
///
/// Fonctionnement :
/// - **Trois rappels hors de l'acteur, trois flux ordonnés.** Le micro (`onChunk`), la fin d'un clip (`onEnd`) et le texte du modèle
///   (`onText`) ne font qu'un `yield` dans un `AsyncStream` : jamais un appel à l'`AudioIO`, jamais une `Task` par rappel (l'ordre
///   entre tâches indépendantes n'est pas garanti).
/// - **Un flux de tranches par écoute.** `ChunkIntake` ne livre les tranches qu'à l'écoute en cours : tout ce que le micro capte
///   pendant la transcription, la réflexion et la parole est écarté **à l'arrivée**, et rien de ce qui reste dans un flux
///   d'écoute abandonné n'est lu par la suivante. L'outil ne se transcrit donc pas lui-même et l'échantillon d'un tour n'apparaît
///   jamais dans le suivant. (Conséquence : un passage de voix qui s'ouvre pendant la parole n'est pas gardé ; la tâche suivante,
///   l'interruption, devra y toucher.)
/// - **Deux tâches de premier niveau.** `talk` mène la conversation (préparation, micro, écoute, tours) ; `run` l'attend puis
///   referme : micro arrêté, conclusion, `.finished`. `conclude()` et `cancel()` n'écrivent qu'un drapeau et annulent `talk`
///   (`cancel()` annule aussi `run`, donc la requête de conclusion) ; chaque étape d'`talk` relit ces drapeaux au retour de ses
///   attentes (`interruption()`).
/// - **Une étape annulée se range avant de rendre.** L'écoute annule et attend l'aperçu ; la réplique annule et attend la requête et la
///   synthèse, coupe la lecture (`stopPlayback`) si des clips sont en file, attend leurs fins puis compte ce qui a été joué. Rien
///   ne survit donc à `talk`, et `run` n'a plus qu'à arrêter le chien de garde.
/// - **La transcription d'un tour n'est coupée ni par `conclude()` ni par une panne du micro** : elle part dans une tâche à part, bornée
///   par `Deadline` (`transcriptionTimeout`), que seul `cancel()` annule (et même un moteur sourd à l'annulation ne retient pas
///   `cancel()`). Ce que la personne vient de dire n'est pas perdu.
/// - **Une seule fin.** `.finished` est émis une fois, après le retour de `audio.stop()`, et le flux d'événements se termine
///   juste après.
///
/// Limites connues, laissées à la tâche suivante : un passage de voix encore ouvert quand on conclut n'est pas transcrit ; une
/// `ConversationChain` libérée sans `cancel()` n'est pas libérée (sa tâche la retient).
public actor ConversationChain: ConversationEngine {
    // MARK: Dépendances

    let audio: any AudioIO
    let detector: any StreamingVoiceDetector
    let transcriber: any Transcriber
    let fastModel: any LanguageModel
    let strongModel: any LanguageModel
    let voice: any SpeechSynthesizer
    let config: ConversationConfig
    let watchdog: MicrophoneWatchdog
    let now: @Sendable () -> Double
    /// L'attente entre deux transcriptions provisoires.
    let sleep: @Sendable (Double) async throws -> Void
    /// L'attente de la limite de temps d'une transcription (`ConversationConfig.transcriptionTimeout`), injectée pour que les tests
    /// la pilotent ; par défaut, la même que `sleep`.
    let transcriptionSleep: @Sendable (Double) async throws -> Void
    let makeResampler: @Sendable (Double, Double) -> StreamingResampler?
    /// Pour les tests : reçoit chaque événement au moment où il est émis, dans l'ordre exact, avant le flux.
    let eventTap: (@Sendable (ConversationEvent) -> Void)?

    public init(audio: any AudioIO, detector: any StreamingVoiceDetector, transcriber: any Transcriber,
                fastModel: any LanguageModel, strongModel: any LanguageModel, voice: any SpeechSynthesizer,
                config: ConversationConfig, watchdog: MicrophoneWatchdog = .system,
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
                transcriptionSleep: (@Sendable (Double) async throws -> Void)? = nil) {
        self.init(audio: audio, detector: detector, transcriber: transcriber, fastModel: fastModel, strongModel: strongModel,
                  voice: voice, config: config, watchdog: watchdog, now: now, sleep: sleep,
                  transcriptionSleep: transcriptionSleep ?? sleep,
                  makeResampler: { StreamingResampler(from: $0, to: $1) }, eventTap: nil)
    }

    init(audio: any AudioIO, detector: any StreamingVoiceDetector, transcriber: any Transcriber,
         fastModel: any LanguageModel, strongModel: any LanguageModel, voice: any SpeechSynthesizer,
         config: ConversationConfig, watchdog: MicrophoneWatchdog, now: @escaping @Sendable () -> Double,
         sleep: @escaping @Sendable (Double) async throws -> Void,
         transcriptionSleep: @escaping @Sendable (Double) async throws -> Void,
         makeResampler: (@Sendable (Double, Double) -> StreamingResampler?)?,
         eventTap: (@Sendable (ConversationEvent) -> Void)?) {
        self.audio = audio
        self.detector = detector
        self.transcriber = transcriber
        self.fastModel = fastModel
        self.strongModel = strongModel
        self.voice = voice
        self.config = config
        self.watchdog = watchdog
        self.now = now
        self.sleep = sleep
        self.transcriptionSleep = transcriptionSleep
        self.makeResampler = makeResampler ?? { StreamingResampler(from: $0, to: $1) }
        self.eventTap = eventTap
        timeline = SpeechTimeline(blockSize: detector.blockSize, sampleRate: transcriberSampleRate)
        let (stream, sink) = AsyncStream<ConversationEvent>.makeStream()
        pendingStream = stream
        self.sink = sink
    }

    // MARK: État

    /// Pourquoi `talk` a rendu la main.
    enum TalkOutcome: Sendable {
        case concluding
        case cancelled
        case failed(ConversationFailure)
    }

    enum Request { case conclude, cancel }

    enum Stage { case talking, closing }

    let sink: AsyncStream<ConversationEvent>.Continuation
    /// Le flux, tant que `start()` ne l'a pas rendu : l'acteur ne le garde pas (un lecteur qui l'abandonne doit pouvoir le terminer).
    var pendingStream: AsyncStream<ConversationEvent>?
    var started = false
    var stage = Stage.talking
    var request: Request?
    var pendingFailure: ConversationFailure?
    var runTask: Task<Void, Never>?
    var talkTask: Task<TalkOutcome, Never>?
    var watchdogTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    var transcribeTask: Task<String, any Error>?
    var audioOpen = false
    let intake = ChunkIntake()

    var conversation = Conversation()
    /// Le nombre de questions posées (une phrase de la réplique a été mise en file ou affichée).
    var questionsAsked = 0
    /// Faux dès qu'une voix ne parle plus : le reste de l'entretien est en texte seul.
    var voiceUsable = true
    var announcedFallback = false

    // Écoute
    var timeline: SpeechTimeline
    var resampler: StreamingResampler?
    var inputRate: Double?

    // Réplique
    var reply = ReplyState()
    var replyInputs: AsyncStream<ReplyInput>.Continuation?
    var replyTracker: ReplyPlayback?
    var synthesisTask: Task<Void, Never>?

    // MARK: Interface

    public func start() async -> AsyncStream<ConversationEvent> {
        guard !started, let stream = pendingStream else { return AsyncStream { $0.finish() } }
        started = true
        pendingStream = nil
        // Un lecteur qui abandonne le flux (tâche annulée, flux libéré) annule l'entretien : sans lui, le micro resterait ouvert.
        sink.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            Task { await self.cancel() }
        }
        // Les deux tâches existent avant que `start()` rende la main : un `cancel()` qui suit les trouve.
        let talk = Task { await self.talk() }
        talkTask = talk
        runTask = Task { await self.run(talk) }
        return stream
    }

    /// Pour les tests : une panne est notée (le chien de garde l'a vue) et attend la fin de la transcription en cours.
    var failureIsPending: Bool { pendingFailure != nil }
    /// Pour les tests : `cancel()` a été demandé.
    var cancelIsRequested: Bool { request == .cancel }
    /// Pour les tests : la conversation est finie, `run` referme (arrêt du chien de garde, micro, conclusion).
    var isClosing: Bool { stage == .closing }

    public func conclude() async {
        guard started, stage == .talking, request == nil else { return }
        request = .conclude
        talkTask?.cancel()
    }

    public func cancel() async {
        guard started else { return }
        if request != .cancel {
            request = .cancel
            talkTask?.cancel()
            transcribeTask?.cancel()
            runTask?.cancel()
        }
        await runTask?.value
    }

    // MARK: Fin

    func run(_ talk: Task<TalkOutcome, Never>) async {
        var outcome = await talk.value
        stage = .closing
        watchdogTask?.cancel()
        await watchdogTask?.value
        watchdogTask = nil
        // Relu APRÈS l'attente : un `cancel()` arrivé pendant l'arrêt du chien de garde l'emporte, sans annonce de conclusion.
        if request == .cancel { outcome = .cancelled }
        let end = await close(outcome)
        emit(.state(.finished))
        emit(.finished(end))
        sink.finish()
    }

    func close(_ outcome: TalkOutcome) async -> ConversationEnd {
        switch outcome {
        case .cancelled:
            closeAudio()
            return .cancelled
        case .failed(let failure):
            closeAudio()
            return .failed(failure, conversation)
        case .concluding:
            emit(.state(.concluding))
            // Le micro est arrêté, et a rendu la main, avant que le modèle fort soit sollicité.
            closeAudio()
            guard conversation.hasUserTurn else { return .nothingSaid }
            return await conclusion()
        }
    }

    func conclusion() async -> ConversationEnd {
        let prompt = InterviewPrompt.conclusion(conversation: conversation, template: config.template, vocabulary: config.vocabulary)
        do {
            let text = try await Rewriter.run(
                strongModel, model: config.strongModel, instruction: prompt.instruction, input: prompt.input,
                policy: config.conclusionPolicy, onText: { _ in })
            return .prompt(text, conversation)
        } catch is CancellationError {
            return .cancelled
        } catch let failure as RewriteFailure {
            return .conclusionFailed(failure, conversation)
        } catch {
            return .conclusionFailed(.from(error), conversation)
        }
    }

    /// Arrête le micro (une seule fois) : plus aucune tranche n'est livrée, et `stop()` a rendu la main au retour.
    func closeAudio() {
        intake.shutdown()
        guard audioOpen else { return }
        audioOpen = false
        audio.stop()
    }

    func emit(_ event: ConversationEvent) {
        eventTap?(event)
        sink.yield(event)
    }

    // MARK: La conversation

    /// Pourquoi la conversation doit s'arrêter, ou `nil` si rien ne le demande. L'annulation passe avant la panne, la panne avant
    /// la conclusion.
    func interruption() -> TalkOutcome? {
        if request == .cancel { return .cancelled }
        if let failure = pendingFailure { return .failed(failure) }
        if request == .conclude { return .concluding }
        return Task.isCancelled ? .cancelled : nil
    }

    /// Une panne : arrête la conversation en cours (la panne l'emporte sur une conclusion demandée, pas sur une annulation). La
    /// transcription d'un tour déjà capté n'est PAS annulée : elle va à son terme, ou à sa limite de temps, pour que ce tour soit dans la
    /// conversation que rend la fin. Seul `cancel()` l'annule.
    func fail(_ failure: ConversationFailure) {
        guard pendingFailure == nil, request != .cancel else { return }
        pendingFailure = failure
        talkTask?.cancel()
    }

    func talk() async -> TalkOutcome {
        emit(.state(.preparing))
        do {
            try await detector.prepare()
        } catch {
            return interruption() ?? .failed(.engine(ConversationFailure.Code.detectorFailed))
        }
        do {
            try await transcriber.prepare()
        } catch {
            return interruption() ?? .failed(.engine(Self.transcriptionCode(of: error)))
        }
        await renew()
        if let stop = interruption() { return stop }
        let intake = intake
        let clock = now
        do {
            try audio.start { chunk in intake.deliver(chunk, at: clock()) }
        } catch {
            return .failed(.microphone(Self.microphoneCode(of: error)))
        }
        audioOpen = true
        // Le délai de la première tranche court depuis l'ouverture du micro, non depuis le début de la préparation.
        intake.stamp(now())
        startWatchdog()
        return await converse()
    }

    func converse() async -> TalkOutcome {
        while true {
            if let stop = interruption() { return stop }
            switch await listen() {
            case .interrupted:
                return interruption() ?? .cancelled
            case .failed(let failure):
                return request == .cancel ? .cancelled : .failed(failure)
            case .turn(let clip):
                let text: String
                switch await transcribe(clip) {
                case .cancelled: return interruption() ?? .cancelled
                case .failed(let code):
                    // Une panne du micro déjà notée est la première cause ; sinon c'est celle du moteur de transcription.
                    return request == .cancel ? .cancelled : .failed(pendingFailure ?? .engine(code))
                case .text(let raw):
                    if request == .cancel { return .cancelled }   // annulé pendant la transcription : rien n'entre dans la conversation
                    text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                // Ce que la personne vient de dire entre dans la conversation même si l'on conclut, annule ou tombe en panne ensuite.
                if !text.isEmpty {
                    conversation.appendUser(text)
                    emit(.turnEnded(text))
                }
                if let stop = interruption() { return stop }
                guard !text.isEmpty else {
                    emit(.notice(.notUnderstood))
                    await renew()
                    continue
                }
                guard questionsAsked < config.maxQuestions else { return .concluding }
                let remaining = config.maxQuestions - questionsAsked
                await renew()   // une ligne de temps et un détecteur neufs au début de chaque réflexion
                if let stop = interruption() { return stop }
                emit(.state(.thinking))
                let result = await speak(remaining: remaining)
                if let stop = interruption() { return stop }
                if result.signal == .conclude { return .concluding }
                if let failure = result.failure { emit(.notice(.modelFailed(failure))) }
            }
        }
    }

    /// Ligne de temps, rééchantillonneur et détecteur neufs : la prochaine écoute ne voit rien de la précédente.
    func renew() async {
        timeline = SpeechTimeline(blockSize: detector.blockSize, sampleRate: transcriberSampleRate)
        resampler = nil
        inputRate = nil
        await detector.reset()
    }

    // MARK: Codes de panne

    /// Le code d'une panne à l'ouverture du micro : le genre de l'erreur de la capture, jamais son message (qui peut citer un
    /// périphérique ou une erreur du système).
    static func microphoneCode(of error: any Error) -> String {
        switch error as? AudioCaptureError {
        case .microphoneAccessDenied?: return ConversationFailure.Code.microphoneAccessDenied
        case .noInputDevice?: return ConversationFailure.Code.noInputDevice
        case .alreadyRunning?: return ConversationFailure.Code.alreadyRunning
        case .engineFailed?: return ConversationFailure.Code.engineFailed
        case .notRunning?: return ConversationFailure.Code.notRunning
        case nil: return ConversationFailure.Code.unexpected
        }
    }

    /// Le code d'une panne du moteur de transcription : le genre de l'erreur, jamais son texte (qui peut porter une adresse ou du
    /// texte dit).
    static func transcriptionCode(of error: any Error) -> String {
        switch error as? TranscriberError {
        case .unsupportedSampleRate?: return ConversationFailure.Code.transcriptionUnsupportedSampleRate
        case .notPrepared?: return ConversationFailure.Code.transcriptionNotPrepared
        case .unsupportedLocale?: return ConversationFailure.Code.transcriptionUnsupportedLocale
        case .vocabularyUnavailable?: return ConversationFailure.Code.transcriptionVocabularyUnavailable
        case .engine?, nil: return ConversationFailure.Code.transcriptionFailed
        }
    }
}
