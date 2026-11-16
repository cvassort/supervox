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
/// - **La transcription d'un tour n'est pas coupée par `conclude()`** : elle part dans une tâche à part, que seuls `cancel()` ou une
///   panne annulent. Ce que la personne vient de dire n'est pas perdu.
/// - **Une seule fin.** `.finished` est émis une fois, après le retour de `audio.stop()`, et le flux d'événements se termine
///   juste après.
///
/// Limites connues, laissées à la tâche suivante : un passage de voix encore ouvert quand on conclut n'est pas transcrit ; une
/// `ConversationChain` libérée sans `cancel()` n'est pas libérée (sa tâche la retient) ; la transcription n'a pas de délai.
public actor ConversationChain: ConversationEngine {
    // MARK: Dépendances

    private let audio: any AudioIO
    private let detector: any StreamingVoiceDetector
    private let transcriber: any Transcriber
    private let fastModel: any LanguageModel
    private let strongModel: any LanguageModel
    private let voice: any SpeechSynthesizer
    private let config: ConversationConfig
    private let watchdog: MicrophoneWatchdog
    private let now: @Sendable () -> Double
    /// L'attente entre deux transcriptions provisoires.
    private let sleep: @Sendable (Double) async throws -> Void
    private let makeResampler: @Sendable (Double, Double) -> StreamingResampler?
    /// Pour les tests : reçoit chaque événement au moment où il est émis, dans l'ordre exact, avant le flux.
    private let eventTap: (@Sendable (ConversationEvent) -> Void)?

    public init(audio: any AudioIO, detector: any StreamingVoiceDetector, transcriber: any Transcriber,
                fastModel: any LanguageModel, strongModel: any LanguageModel, voice: any SpeechSynthesizer,
                config: ConversationConfig, watchdog: MicrophoneWatchdog = .system,
                now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
                sleep: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.init(audio: audio, detector: detector, transcriber: transcriber, fastModel: fastModel, strongModel: strongModel,
                  voice: voice, config: config, watchdog: watchdog, now: now, sleep: sleep,
                  makeResampler: { StreamingResampler(from: $0, to: $1) }, eventTap: nil)
    }

    init(audio: any AudioIO, detector: any StreamingVoiceDetector, transcriber: any Transcriber,
         fastModel: any LanguageModel, strongModel: any LanguageModel, voice: any SpeechSynthesizer,
         config: ConversationConfig, watchdog: MicrophoneWatchdog, now: @escaping @Sendable () -> Double,
         sleep: @escaping @Sendable (Double) async throws -> Void,
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
        self.makeResampler = makeResampler ?? { StreamingResampler(from: $0, to: $1) }
        self.eventTap = eventTap
        timeline = SpeechTimeline(blockSize: detector.blockSize, sampleRate: transcriberSampleRate)
        let (stream, sink) = AsyncStream<ConversationEvent>.makeStream()
        pendingStream = stream
        self.sink = sink
    }

    // MARK: État

    /// Pourquoi `talk` a rendu la main.
    private enum TalkOutcome: Sendable {
        case concluding
        case cancelled
        case failed(ConversationFailure)
    }

    private enum Request { case conclude, cancel }

    private enum Stage { case talking, closing }

    private let sink: AsyncStream<ConversationEvent>.Continuation
    /// Le flux, tant que `start()` ne l'a pas rendu : l'acteur ne le garde pas (un lecteur qui l'abandonne doit pouvoir le terminer).
    private var pendingStream: AsyncStream<ConversationEvent>?
    private var started = false
    private var stage = Stage.talking
    private var request: Request?
    private var pendingFailure: ConversationFailure?
    private var runTask: Task<Void, Never>?
    private var talkTask: Task<TalkOutcome, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var transcribeTask: Task<String, any Error>?
    private var audioOpen = false
    private let intake = ChunkIntake()

    private var conversation = Conversation()
    /// Le nombre de questions posées (une phrase de la réplique a été mise en file ou affichée).
    private var questionsAsked = 0
    /// Faux dès qu'une voix ne parle plus : le reste de l'entretien est en texte seul.
    private var voiceUsable = true
    private var announcedFallback = false

    // Écoute
    private var timeline: SpeechTimeline
    private var resampler: StreamingResampler?
    private var inputRate: Double?

    // Réplique
    private var reply = ReplyState()
    private var replyInputs: AsyncStream<ReplyInput>.Continuation?
    private var replyTracker: ReplyPlayback?
    private var synthesisTask: Task<Void, Never>?

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

    private func run(_ talk: Task<TalkOutcome, Never>) async {
        var outcome = await talk.value
        stage = .closing
        if request == .cancel { outcome = .cancelled }
        watchdogTask?.cancel()
        await watchdogTask?.value
        watchdogTask = nil
        let end = await close(outcome)
        emit(.state(.finished))
        emit(.finished(end))
        sink.finish()
    }

    private func close(_ outcome: TalkOutcome) async -> ConversationEnd {
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

    private func conclusion() async -> ConversationEnd {
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
    private func closeAudio() {
        intake.shutdown()
        guard audioOpen else { return }
        audioOpen = false
        audio.stop()
    }

    private func emit(_ event: ConversationEvent) {
        eventTap?(event)
        sink.yield(event)
    }

    // MARK: La conversation

    /// Pourquoi la conversation doit s'arrêter, ou `nil` si rien ne le demande. L'annulation passe avant la panne, la panne avant
    /// la conclusion.
    private func interruption() -> TalkOutcome? {
        if request == .cancel { return .cancelled }
        if let failure = pendingFailure { return .failed(failure) }
        if request == .conclude { return .concluding }
        return Task.isCancelled ? .cancelled : nil
    }

    /// Une panne : annule la conversation en cours (la panne l'emporte sur une conclusion demandée, pas sur une annulation).
    private func fail(_ failure: ConversationFailure) {
        guard pendingFailure == nil, request != .cancel else { return }
        pendingFailure = failure
        talkTask?.cancel()
        transcribeTask?.cancel()
    }

    private func talk() async -> TalkOutcome {
        emit(.state(.preparing))
        do {
            try await detector.prepare()
            try await transcriber.prepare()
        } catch {
            return interruption() ?? .failed(.engine(Self.reason(of: error)))
        }
        await renew()
        if let stop = interruption() { return stop }
        let intake = intake
        let clock = now
        do {
            try audio.start { chunk in intake.deliver(chunk, at: clock()) }
        } catch {
            return .failed(.microphone(Self.reason(of: error)))
        }
        audioOpen = true
        // Le délai de la première tranche court depuis l'ouverture du micro, non depuis le début de la préparation.
        intake.stamp(now())
        startWatchdog()
        return await converse()
    }

    private func converse() async -> TalkOutcome {
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
                case .failed(let reason): return request == .cancel ? .cancelled : .failed(.engine(reason))
                case .text(let raw): text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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
    private func renew() async {
        timeline = SpeechTimeline(blockSize: detector.blockSize, sampleRate: transcriberSampleRate)
        resampler = nil
        inputRate = nil
        await detector.reset()
    }

    // MARK: Écoute

    private enum Listening {
        case turn(AudioClip)
        case interrupted
        case failed(ConversationFailure)
    }

    /// Écoute jusqu'à ce que le détecteur ferme un passage, ou que la conversation soit interrompue.
    private func listen() async -> Listening {
        let (chunks, chunkSink) = AsyncStream<AudioChunk>.makeStream()
        intake.open(chunkSink)
        startPreview()
        emit(.state(.listening))
        var result: Listening?
        for await chunk in chunks {
            if let step = await ingest(chunk) {
                result = step
                break
            }
        }
        intake.closeEpoch()
        // L'aperçu est annulé et attendu avant tout : le moteur de transcription n'a jamais deux appels en même temps.
        previewTask?.cancel()
        await previewTask?.value
        previewTask = nil
        return result ?? .interrupted
    }

    private func ingest(_ chunk: AudioChunk) async -> Listening? {
        let step = await process(chunk)
        emit(.level(AudioLevel.display(of: chunk.samples)))
        return step
    }

    private func process(_ chunk: AudioChunk) async -> Listening? {
        if resampler == nil || inputRate != chunk.sampleRate {
            guard let made = makeResampler(chunk.sampleRate, transcriberSampleRate) else {
                let rate = chunk.sampleRate.isFinite ? "\(Int(chunk.sampleRate.rounded()))" : "?"
                return .failed(.microphone("fréquence du micro inutilisable (\(rate) Hz)"))
            }
            resampler = made
            inputRate = chunk.sampleRate
        }
        guard let resampler else { return nil }
        let converted = resampler.push(chunk.samples)
        if resampler.hasFailed { return .failed(.microphone("la conversion de l'audio a échoué")) }
        for block in timeline.append(converted) {
            do {
                if let event = try await detector.process(block) { timeline.apply(event) }
            } catch {
                return Task.isCancelled ? .interrupted : .failed(.engine(Self.reason(of: error)))
            }
            // Le silence qui termine le tour est celui du détecteur : le premier passage fermé est le tour.
            if let segment = timeline.closedSegments.first { return .turn(paddedClip(of: segment)) }
        }
        return nil
    }

    /// Le passage fermé, élargi de `padding` secondes de chaque côté et borné à l'audio reçu.
    private func paddedClip(of segment: Range<Int>) -> AudioClip {
        let seconds = config.padding.isFinite ? min(max(config.padding, 0), 60) : 0   // 60 s : borne de sûreté, choix non mesuré
        let pad = Int((seconds * transcriberSampleRate).rounded())
        return timeline.clip(of: (segment.lowerBound - pad)..<(segment.upperBound + pad))
    }

    // MARK: Aperçu

    /// Une tâche qui, toutes les `previewInterval` secondes (attente injectée), transcrit le passage ouvert. Une passe à la fois :
    /// la suivante n'attend qu'après la fin de la précédente.
    private func startPreview() {
        let interval = config.previewInterval
        let sleep = sleep
        previewTask = Task {
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                guard !Task.isCancelled else { return }
                await self.previewPass()
            }
        }
    }

    private func previewPass() async {
        // `.infinity` : le passage ouvert en entier, pour que le texte provisoire soit celui du passage et non de sa fin.
        guard let start = timeline.openSegmentStart, let clip = timeline.openClip(maxSeconds: .infinity) else { return }
        let text = try? await transcriber.transcribe(clip, language: config.language, vocabulary: config.vocabulary)
        // Le résultat d'une passe qui revient après la fermeture du passage, ou après l'écoute, ne se montre pas.
        guard let text, !Task.isCancelled, timeline.openSegmentStart == start else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { emit(.partialTranscript(trimmed)) }
    }

    // MARK: Transcription

    private enum Transcription {
        case text(String)
        case failed(String)
        case cancelled
    }

    /// La transcription part dans une tâche à part : `conclude()` n'annule pas ce qui vient d'être dit. Seuls `cancel()` et une
    /// panne l'annulent.
    private func transcribe(_ clip: AudioClip) async -> Transcription {
        let engine = transcriber
        let language = config.language
        let vocabulary = config.vocabulary
        let task = Task { try await engine.transcribe(clip, language: language, vocabulary: vocabulary) }
        transcribeTask = task
        let result = await task.result
        transcribeTask = nil
        switch result {
        case .success(let text):
            return .text(text)
        case .failure(let error):
            return error is CancellationError || task.isCancelled ? .cancelled : .failed(Self.reason(of: error))
        }
    }

    // MARK: Chien de garde du micro

    private func startWatchdog() {
        let watchdog = watchdog
        watchdogTask = Task {
            while !Task.isCancelled {
                do { try await watchdog.sleep(watchdog.pollInterval) } catch { return }
                guard self.microphoneIsAlive() else { return }
            }
        }
    }

    /// Faux quand la tâche doit s'arrêter : l'entretien ne parle plus au micro, ou le micro s'est tu (l'entretien échoue alors).
    private func microphoneIsAlive() -> Bool {
        guard stage == .talking, audioOpen else { return false }
        // Avant toute tranche, la tolérance est celle de l'ouverture du micro ; ensuite, celle de l'écart entre deux tranches.
        let limit = intake.hasSeenAChunk ? watchdog.timeout : watchdog.firstChunkTimeout
        guard now() - intake.lastArrival >= limit else { return true }
        fail(.microphone("le micro s'est arrêté pendant l'entretien"))
        return false
    }

    // MARK: Réplique

    /// Ce que la réplique laisse à la conversation.
    private struct ReplyResult {
        var signal: ReplySignal
        var failure: RewriteFailure?
    }

    private enum ModelEnd: Sendable {
        case done
        case failed(RewriteFailure)
        case cancelled
    }

    /// Les entrées de la réplique, dans un seul flux : le texte du modèle, la fin du modèle, la fin d'une synthèse, la fin d'un
    /// clip. Une seule tâche les lit, dans l'ordre : aucune course entre elles.
    private enum ReplyInput: Sendable {
        case text(String)
        case modelEnded(ModelEnd)
        case synthesized(Int, Result<Speech, any Error>)
        case clipEnded(Int, PlaybackEnd)
    }

    private enum SentenceOutcome {
        /// Mise en file de lecture, pas encore finie.
        case queued
        case played
        /// Coupée avant la fin : pas entendue.
        case stopped
        /// Affichée seule (plus de voix) : comptée comme entendue, elle a été montrée.
        case shown
        /// Rien à dire (la voix n'a rien rendu) : sautée, la voix reste.
        case skipped
    }

    private struct ReplyState {
        var filter = ReplyFilter()
        var splitter = SentenceSplitter()
        /// Le texte visible cumulé, sans marqueur.
        var visible = ""
        var sentences: [String] = []
        var outcomes: [Int: SentenceOutcome] = [:]
        var queue = SpeechQueue()
        var modelEnd: ModelEnd?
        var started = false
        /// Le nombre de questions qui restaient quand la requête est partie.
        var remainingAtStart = 0

        var isComplete: Bool { modelEnd != nil && queue.isIdle }
    }

    /// L'état de la réplique en cours, pour les tests : l'appel passe derrière le tour d'acteur qui vient de le modifier.
    func replySnapshot() -> ReplySnapshot {
        ReplySnapshot(queuedClips: reply.queue.queuedClips, synthesizing: reply.queue.synthesizing, pending: reply.queue.pending)
    }

    /// Une requête au modèle rapide, puis sa réplique dite phrase par phrase. Rend la main quand le modèle a fini, que plus rien
    /// n'est à synthétiser et que tous les clips en file ont fini, ou dès que la tâche est annulée (la réplique est alors rangée :
    /// requête et synthèse annulées, lecture coupée, ce qui a été joué est compté).
    private func speak(remaining: Int) async -> ReplyResult {
        guard let completion = conversation.completion() else {
            return ReplyResult(signal: .continue, failure: .empty)   // jamais : le dernier tour est celui de la personne
        }
        let (inputs, inputSink) = AsyncStream<ReplyInput>.makeStream()
        let tracker = ReplyPlayback()
        reply = ReplyState(remainingAtStart: remaining)
        replyInputs = inputSink
        replyTracker = tracker

        let model = fastModel
        let name = config.fastModel
        let policy = config.turnPolicy
        let instruction = InterviewPrompt.instruction(remainingQuestions: remaining)
        let modelTask = Task {
            do {
                _ = try await Rewriter.run(model, model: name, instruction: instruction, input: completion.input,
                                           history: completion.history, policy: policy) { inputSink.yield(.text($0)) }
                inputSink.yield(.modelEnded(.done))
            } catch is CancellationError {
                inputSink.yield(.modelEnded(.cancelled))
            } catch let failure as RewriteFailure {
                inputSink.yield(.modelEnded(.failed(failure)))
            } catch {
                inputSink.yield(.modelEnded(.failed(.from(error))))
            }
        }

        for await input in inputs {
            handle(input)
            advance()
            if reply.isComplete { break }
        }

        // Rangement, quelle que soit la façon de finir : ce qui produit est arrêté et attendu avant ce qui consomme.
        modelTask.cancel()
        await modelTask.value
        synthesisTask?.cancel()
        await synthesisTask?.value
        synthesisTask = nil
        if tracker.outstanding > 0 {
            audio.stopPlayback()
            await tracker.waitUntilIdle()
        }
        for (index, end) in tracker.ends.sorted(by: { $0.key < $1.key }) where reply.outcomes[index] == .queued {
            finishClip(index, end)
        }

        let heard = reply.sentences.indices
            .filter { reply.outcomes[$0] == .played || reply.outcomes[$0] == .shown }
            .map { reply.sentences[$0] }
            .joined(separator: " ")
        conversation.appendInterviewer(heard)
        if reply.started { emit(.speakingEnded(heard: heard)) }

        var failure: RewriteFailure?
        if case .failed(let reason)? = reply.modelEnd { failure = reason }
        let signal = reply.filter.signal
        // Une réplique sans aucune phrase (le marqueur seul) n'est pas une question : c'est un modèle qui n'a rien dit.
        if case .done? = reply.modelEnd, reply.sentences.isEmpty, signal != .conclude { failure = .empty }
        replyInputs = nil
        replyTracker = nil
        reply = ReplyState()
        return ReplyResult(signal: signal, failure: failure)
    }

    private func handle(_ input: ReplyInput) {
        switch input {
        case .text(let visible):
            absorb(reply.filter.feed(visible))
        case .modelEnded(let end):
            if case .done = end {
                // La fin du texte : ce que le filtre retenait, puis la dernière phrase que le découpeur gardait.
                absorb(reply.filter.finish())
                if let last = reply.splitter.flush() { addSentence(last) }
            }
            reply.modelEnd = end
        case .synthesized(let index, let result):
            reply.queue.synthesisFinished()
            deliver(index, result)
        case .clipEnded(let index, let end):
            reply.queue.clipEnded()
            finishClip(index, end)
        }
    }

    private func absorb(_ delta: String) {
        guard !delta.isEmpty else { return }
        reply.visible += delta
        emit(.replyText(reply.visible))
        for sentence in reply.splitter.feed(delta) { addSentence(sentence) }
    }

    private func addSentence(_ text: String) {
        _ = reply.queue.register()
        reply.sentences.append(text)
    }

    /// Lance la synthèse de la phrase suivante si la file le permet ; sans voix, affiche les phrases en attente.
    private func advance() {
        if !voiceUsable {
            for index in reply.queue.takeAllPending() { show(index) }
        } else if let index = reply.queue.nextToSynthesize(), let inputs = replyInputs {
            let text = reply.sentences[index]
            let voice = voice
            synthesisTask = Task {
                do {
                    inputs.yield(.synthesized(index, .success(try await voice.synthesize(text))))
                } catch {
                    inputs.yield(.synthesized(index, .failure(error)))
                }
            }
        }
    }

    private func deliver(_ index: Int, _ result: Result<Speech, any Error>) {
        switch result {
        case .failure(let error):
            // Rien à dire n'est la panne d'aucune voix : la phrase est sautée. Une synthèse annulée aussi (la réplique se range).
            if error is CancellationError || (error as? SpeechError) == .empty {
                reply.outcomes[index] = .skipped
                return
            }
            voiceDown()
            show(index)
        case .success(let speech):
            if speech.fellBack, !announcedFallback {
                announcedFallback = true
                emit(.notice(.voiceFellBack))
            }
            guard let tracker = replyTracker, let inputs = replyInputs else { return }
            tracker.reserve()
            do {
                try audio.play(speech.clip) { end in
                    tracker.ended(index, end)
                    inputs.yield(.clipEnded(index, end))
                }
            } catch {
                tracker.release()
                voiceDown()
                show(index)
                return
            }
            reply.queue.clipQueued()
            reply.outcomes[index] = .queued
            beginSpeaking()
        }
    }

    /// Plus de voix : un avis, une seule fois par entretien, puis le texte seul jusqu'à la fin.
    private func voiceDown() {
        guard voiceUsable else { return }
        voiceUsable = false
        emit(.notice(.voiceUnavailable))
    }

    private func show(_ index: Int) {
        reply.outcomes[index] = .shown
        beginSpeaking()
    }

    private func finishClip(_ index: Int, _ end: PlaybackEnd) {
        switch end {
        case .played:
            reply.outcomes[index] = .played
            emit(.sentencePlayed(reply.sentences[index]))
        case .stopped:
            reply.outcomes[index] = .stopped
        }
    }

    /// La première phrase de la réplique est mise en file (ou affichée) : la question compte, avec les avis qui la concernent.
    private func beginSpeaking() {
        guard !reply.started else { return }
        reply.started = true
        let signal = reply.filter.signal
        if signal != .conclude {
            questionsAsked += 1
            if reply.remainingAtStart == 1 { emit(.notice(.lastQuestion)) }
            if signal == .propose { emit(.notice(.proposal)) }
        }
        emit(.state(.speaking))
        emit(.speakingStarted(question: questionsAsked))
    }

    // MARK: Raisons de panne

    /// Une raison technique de panne : un code, jamais le texte d'une erreur (qui peut porter une adresse ou du texte dit).
    private static func reason(of error: any Error) -> String {
        switch error {
        case let capture as AudioCaptureError:
            return capture.reason
        case let engine as TranscriberError:
            switch engine {
            case .unsupportedSampleRate: return "transcription : unsupportedSampleRate"
            case .notPrepared: return "transcription : notPrepared"
            case .unsupportedLocale: return "transcription : unsupportedLocale"
            case .vocabularyUnavailable: return "transcription : vocabularyUnavailable"
            case .engine: return "transcription : engine"
            }
        default:
            return "erreur inattendue"
        }
    }
}

// MARK: - Les tranches du micro

/// Là où le rappel du micro dépose ses tranches. Il ne fait qu'un verrou bref et un `yield` (contrat de `onChunk`). Une seule
/// écoute est ouverte à la fois : une tranche qui arrive hors écoute est écartée, et à l'ouverture d'une écoute celle d'avant
/// est close, avec ce qui n'y a pas été lu.
final class ChunkIntake: Sendable {
    private struct State {
        var sink: AsyncStream<AudioChunk>.Continuation?
        var lastArrival = 0.0
        var chunks = 0
        var closed = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Date de la dernière tranche arrivée du micro, écoute ou non (le chien de garde la lit), sans la compter.
    func stamp(_ time: Double) { state.withLock { $0.lastArrival = time } }

    var lastArrival: Double { state.withLock { $0.lastArrival } }
    var hasSeenAChunk: Bool { state.withLock { $0.chunks > 0 } }

    func deliver(_ chunk: AudioChunk, at time: Double) {
        let sink = state.withLock { state -> AsyncStream<AudioChunk>.Continuation? in
            state.lastArrival = time
            state.chunks += 1
            return state.sink
        }
        sink?.yield(chunk)
    }

    func open(_ sink: AsyncStream<AudioChunk>.Continuation) {
        let previous = state.withLock { state -> AsyncStream<AudioChunk>.Continuation? in
            guard !state.closed else { return sink }
            defer { state.sink = sink }
            return state.sink
        }
        previous?.finish()
    }

    func closeEpoch() {
        state.withLock { state -> AsyncStream<AudioChunk>.Continuation? in
            defer { state.sink = nil }
            return state.sink
        }?.finish()
    }

    /// Plus aucune écoute ne s'ouvrira.
    func shutdown() {
        state.withLock { state -> AsyncStream<AudioChunk>.Continuation? in
            state.closed = true
            defer { state.sink = nil }
            return state.sink
        }?.finish()
    }
}

// MARK: - La file de parole

/// L'état de la réplique vue de la file : au plus une synthèse en cours, au plus `maxQueuedClips` clips mis en file de lecture et
/// pas encore finis. Pure : l'acteur la fait avancer, les tests la vérifient seule.
struct SpeechQueue: Equatable {
    /// Deux clips : celui qui joue et le suivant déjà prêt, de quoi ne pas laisser de silence entre deux phrases sans synthétiser
    /// loin devant ce qui est dit (règle de la tâche 5 ; choix non mesuré).
    static let maxQueuedClips = 2

    /// Les rangs des phrases prêtes, pas encore en cours de synthèse.
    private(set) var pending: [Int] = []
    /// Le rang de la phrase en cours de synthèse.
    private(set) var synthesizing: Int?
    private(set) var queuedClips = 0
    private var registered = 0

    /// Une phrase est prête : son rang.
    mutating func register() -> Int {
        pending.append(registered)
        defer { registered += 1 }
        return registered
    }

    /// Le rang de la phrase à synthétiser maintenant, si rien n'est en cours et si la file n'est pas pleine ; elle est alors en cours.
    mutating func nextToSynthesize() -> Int? {
        guard synthesizing == nil, queuedClips < Self.maxQueuedClips, !pending.isEmpty else { return nil }
        let index = pending.removeFirst()
        synthesizing = index
        return index
    }

    mutating func synthesisFinished() { synthesizing = nil }
    mutating func clipQueued() { queuedClips += 1 }
    mutating func clipEnded() { queuedClips = max(queuedClips - 1, 0) }

    /// Sans voix : toutes les phrases en attente d'un coup.
    mutating func takeAllPending() -> [Int] {
        defer { pending = [] }
        return pending
    }

    var isIdle: Bool { pending.isEmpty && synthesizing == nil && queuedClips == 0 }
}

/// Ce que montre `ConversationChain.replySnapshot()`.
struct ReplySnapshot: Equatable {
    var queuedClips: Int
    var synthesizing: Int?
    var pending: [Int]
}

/// Les clips acceptés par l'`AudioIO` et leur fin, lus par le rangement d'une réplique : il attend que tous aient fini après
/// avoir coupé la lecture. Les fins arrivent par `onEnd`, hors de l'acteur.
final class ReplyPlayback: Sendable {
    private struct State {
        var outstanding = 0
        var ends: [Int: PlaybackEnd] = [:]
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Un clip va être donné à `play` (rendu par `release` si `play` refuse).
    func reserve() { state.withLock { $0.outstanding += 1 } }

    func release() { settle(nil) }

    func ended(_ index: Int, _ end: PlaybackEnd) { settle((index, end)) }

    var outstanding: Int { state.withLock { $0.outstanding } }
    var ends: [Int: PlaybackEnd] { state.withLock { $0.ends } }

    func waitUntilIdle() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = state.withLock { state -> Bool in
                if state.outstanding == 0 { return true }
                state.waiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    private func settle(_ finished: (index: Int, end: PlaybackEnd)?) {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            if let finished { state.ends[finished.index] = finished.end }
            state.outstanding = max(state.outstanding - 1, 0)
            guard state.outstanding == 0 else { return [] }
            defer { state.waiters = [] }
            return state.waiters
        }
        for continuation in ready { continuation.resume() }
    }
}
