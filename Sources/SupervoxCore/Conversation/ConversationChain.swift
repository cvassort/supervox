import Foundation
import os

/// Ce qui arrive à l'entretien, dans un seul flux ordonné : les tranches du micro, la fin d'une transcription, les entrées de la
/// réplique (texte et fin du modèle, fin d'une synthèse, fin d'un clip). Une seule tâche le lit, dans l'ordre : aucune course entre
/// le micro, la transcription et la voix. La transcription et la réplique portent un **numéro de génération** : une entrée d'une
/// transcription ou d'une réplique abandonnée (interruption, conclusion, annulation) est jetée à la lecture.
enum ConversationInput: Sendable {
    case chunk(AudioChunk)
    case transcribed(generation: Int, Result<String, any Error>)
    case reply(generation: Int, ConversationChain.ReplyInput)
}

/// L'entretien vocal : écoute, transcription, réflexion du modèle rapide, parole phrase par phrase, conclusion du modèle fort.
///
/// Fonctionnement :
/// - **Des rappels hors de l'acteur, un flux ordonné.** Le micro (`onChunk`), la fin d'un clip (`onEnd`), le texte du modèle
///   (`onText`) et la fin d'une transcription ne font qu'un `yield` dans le flux d'entrées (`ConversationInput`) : jamais un appel à
///   l'`AudioIO`, jamais une `Task` par rappel. Une seule boucle, `converse`, le lit.
/// - **Deux tâches de premier niveau.** `talk` mène la conversation (préparation, micro, boucle) ; `run` l'attend puis referme :
///   micro arrêté, conclusion, `.finished`. `conclude()`, `cancel()` et une panne du micro n'écrivent qu'un drapeau et annulent
///   `talk` ; la boucle relit ces drapeaux **avant chaque entrée** (`interruption()`), donc rien de ce qui attend dans le flux n'est
///   lu après eux.
/// - **Une fin rangée, qui garde ce qui a été dit.** Sur une conclusion ou une panne, `windDown` coupe la réplique (les phrases
///   jouées restent), puis transcrit ce que la personne a dit et qui ne l'est pas encore (transcription en cours, passages fermés,
///   passage encore ouvert), chaque transcription bornée par `Deadline` ; sur une annulation, rien n'est transcrit. Tout ce qui a
///   été lancé est annulé et attendu avant que `talk` rende la main.
/// - **Une seule fin.** `.finished` est émis une fois, après le retour de `audio.stop()`, et le flux d'événements se termine
///   juste après.
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
        gate = InterruptionGate(minDuration: config.interruptMinDuration, level: config.interruptLevel)
        let (stream, sink) = AsyncStream<ConversationEvent>.makeStream()
        pendingStream = stream
        self.sink = sink
        let (inputs, inputSink) = AsyncStream<ConversationInput>.makeStream()
        pendingInputs = inputs
        self.inputSink = inputSink
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
    let inputSink: AsyncStream<ConversationInput>.Continuation
    /// Le flux d'entrées, tant que `talk` ne l'a pas pris.
    var pendingInputs: AsyncStream<ConversationInput>?
    var started = false
    var stage = Stage.talking
    var request: Request?
    var pendingFailure: ConversationFailure?
    var runTask: Task<Void, Never>?
    var talkTask: Task<TalkOutcome, Never>?
    var watchdogTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    var audioOpen = false
    let intake = ChunkIntake()
    /// `.state(.concluding)` a été émis : il ne l'est qu'une fois (par la fin rangée, ou par `close` quand la conclusion arrive
    /// avant toute conversation, pendant la préparation).
    var concludingAnnounced = false

    var conversation = Conversation()
    /// Le nombre de questions posées (la première phrase de la réplique a commencé à être jouée, ou a été affichée).
    var questionsAsked = 0
    /// Faux dès qu'une voix ne parle plus : le reste de l'entretien est en texte seul.
    var voiceUsable = true
    var announcedFallback = false

    // Écoute
    var timeline: SpeechTimeline
    /// Les échantillons reçus par la ligne de temps en cours (et par la porte, remise à zéro en même temps).
    var timelineSamples = 0
    /// Les passages fermés de la ligne de temps en cours déjà traités (pris pour un tour, ou jetés).
    var handledSegments = 0
    /// D'où vient le passage ouvert : il décide de ce qu'il devient à sa fermeture.
    var passageOrigin = PassageOrigin.listening
    var gate: InterruptionGate
    var resampler: StreamingResampler?
    var inputRate: Double?

    // Transcription
    /// Les passages fermés à transcrire, dans l'ordre ; un seul part à la fois.
    var clipsToTranscribe: [AudioClip] = []
    var transcription: (generation: Int, task: Task<Result<String, any Error>, Never>)?
    var transcriptionGeneration = 0
    /// Faux après une panne du moteur de transcription : rien d'autre ne lui est demandé.
    var transcriberUsable = true
    /// Le dernier tour de la personne attend une réplique.
    var awaitingReply = false

    // Réplique
    var reply = ReplyState()
    /// Une réplique est en cours (réflexion ou parole).
    var replyActive = false
    var replyGeneration = 0
    var replyTracker: ReplyPlayback?
    var modelTask: Task<Void, Never>?
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
            transcription?.task.cancel()
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
        inputSink.finish()
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
            announceConclusion()
            // Le micro est arrêté, et a rendu la main, avant que le modèle fort soit sollicité (déjà fait par la fin rangée, sauf
            // quand la conclusion arrive pendant la préparation).
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

    func announceConclusion() {
        guard !concludingAnnounced else { return }
        concludingAnnounced = true
        emit(.state(.concluding))
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

    /// Une panne vue hors de la boucle (le chien de garde) : arrête la conversation en cours (la panne l'emporte sur une conclusion
    /// demandée, pas sur une annulation). La transcription d'un tour déjà capté n'est PAS annulée : la fin la mène à son terme, ou à
    /// sa limite de temps, pour que ce tour soit dans la conversation que rend la fin. Seul `cancel()` l'annule.
    func fail(_ failure: ConversationFailure) {
        guard note(failure) else { return }
        talkTask?.cancel()
    }

    /// Note une panne ; la première cause reste. Faux si rien n'a été noté (une panne déjà notée, ou une annulation).
    @discardableResult
    func note(_ failure: ConversationFailure) -> Bool {
        guard pendingFailure == nil, request != .cancel else { return false }
        pendingFailure = failure
        return true
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
        guard let inputs = pendingInputs else { return .cancelled }
        pendingInputs = nil
        let intake = intake
        let clock = now
        intake.open(inputSink)
        do {
            try audio.start { chunk in intake.deliver(chunk, at: clock()) }
        } catch {
            return .failed(.microphone(Self.microphoneCode(of: error)))
        }
        audioOpen = true
        // Le délai de la première tranche court depuis l'ouverture du micro, non depuis le début de la préparation.
        intake.stamp(now())
        startWatchdog()
        return await converse(inputs)
    }

    /// La boucle de l'entretien : une entrée à la fois, puis ce qui doit en suivre (`proceed`). Les drapeaux de fin sont relus
    /// avant chaque entrée et après chacune.
    func converse(_ inputs: AsyncStream<ConversationInput>) async -> TalkOutcome {
        enterListening()
        for await input in inputs {
            if let stop = interruption() { return await windDown(stop) }
            switch input {
            case .chunk(let chunk):
                await hear(chunk)
            case .transcribed(let generation, let result):
                guard generation == transcription?.generation else { continue }
                transcription = nil
                take(result, closing: false)
            case .reply(let generation, let input):
                guard generation == replyGeneration, replyActive else { continue }
                handle(input)
                if reply.isComplete, let end = await finishReply() { return await windDown(end) }
            }
            if let stop = interruption() { return await windDown(stop) }
            if let end = await proceed() { return await windDown(end) }
        }
        return await windDown(interruption() ?? .cancelled)
    }

    /// Ce qui suit une entrée : la transcription suivante, ou la réplique quand plus rien de la personne n'est en attente.
    func proceed() async -> TalkOutcome? {
        if transcription == nil, !clipsToTranscribe.isEmpty {
            // L'aperçu est annulé et attendu avant : le moteur de transcription n'a jamais deux appels en même temps.
            await stopPreview()
            if let stop = interruption() { return stop }
            startTranscription(clipsToTranscribe.removeFirst())
            return nil
        }
        guard awaitingReply, transcription == nil, clipsToTranscribe.isEmpty, !replyActive, !interruptingPassageIsOpen else {
            return nil
        }
        guard questionsAsked < config.maxQuestions else { return .concluding }
        awaitingReply = false
        await stopPreview()
        if timeline.openSegmentStart == nil { await renew() }   // une ligne de temps neuve, sauf si la personne parle déjà
        if let stop = interruption() { return stop }
        startReply(remaining: config.maxQuestions - questionsAsked)
        return nil
    }

    /// La fin de la conversation. Sur une annulation, tout est arrêté et rien n'est ajouté. Sinon (conclusion, panne), la réplique est
    /// coupée en gardant ce qui a été entendu, puis ce que la personne a dit est transcrit et ajouté avant de rendre la main.
    ///
    /// Le passage encore ouvert est pris **avant** l'arrêt du micro, puis le micro est arrêté et, sur une conclusion, celle-ci est
    /// annoncée : les transcriptions finales tournent micro fermé (témoin éteint, plus aucune tranche accumulée, chien de garde arrêté
    /// avec lui ; revue de la tâche 6, I-1). La réplique est rangée avant : `stopPlayback()` n'est jamais appelé après `stop()`.
    /// Reste avant l'arrêt du micro une attente sans limite : la synthèse en cours, si la voix n'écoute pas l'annulation.
    func windDown(_ outcome: TalkOutcome) async -> TalkOutcome {
        if replyActive { await abortReply(interrupted: false) }
        await stopPreview()
        if case .cancelled = outcome {
            await abandonTranscription()
            return .cancelled
        }
        if let clip = openPassageClip() { clipsToTranscribe.append(clip) }
        if case .concluding = outcome, request != .cancel { announceConclusion() }
        closeAudio()
        while transcriberUsable, request != .cancel {
            if let running = transcription {
                let result = await running.task.value
                transcription = nil
                guard request != .cancel else { break }
                take(result, closing: true)
            } else if !clipsToTranscribe.isEmpty {
                startTranscription(clipsToTranscribe.removeFirst())
            } else {
                break
            }
        }
        await abandonTranscription()
        if request == .cancel { return .cancelled }
        if let failure = pendingFailure { return .failed(failure) }
        return outcome
    }

    /// L'écoute reprend : l'interface le montre, l'aperçu repart.
    func enterListening() {
        emit(.state(.listening))
        if previewTask == nil { startPreview() }
    }

    /// Ligne de temps, porte et détecteur neufs : la prochaine écoute ne voit rien de la précédente. Jamais pendant un passage ouvert
    /// (le détecteur perdrait la voix en cours, et le passage son début) : l'appelant le vérifie.
    func renew() async {
        timeline = SpeechTimeline(blockSize: detector.blockSize, sampleRate: transcriberSampleRate)
        gate.reset()
        timelineSamples = 0
        handledSegments = 0
        passageOrigin = .listening
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
