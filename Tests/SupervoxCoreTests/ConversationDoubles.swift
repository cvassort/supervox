import Foundation
import os
import Testing
@testable import SupervoxCore

// Doubles de l'entretien. Aucun ne dort et aucun n'ouvre le micro, ne joue un son ni ne touche au réseau : le temps vient de
// `TestClock` et `TickSleeper`, chaque réponse d'un moteur vient du test, et chaque attente est une porte (`Gate`, `CountLatch`)
// qui rend la main à l'annulation de la tâche (la limite de temps d'une suite échoue le test au lieu de le laisser pendre).

// MARK: - Attentes

/// Un compteur que le test attend sans sommeil : `wait(atLeast:)` rend la main quand `increment()` a été appelé assez de fois.
final class CountLatch: @unchecked Sendable {
    private struct Waiter {
        var need: Int
        var continuation: CheckedContinuation<Void, Never>
    }
    private let state = OSAllocatedUnfairLock(initialState: (count: 0, waiters: [UUID: Waiter]()))

    var count: Int { state.withLock { $0.count } }

    func increment() {
        let ready = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.count += 1
            let due = s.waiters.filter { $0.value.need <= s.count }
            for key in due.keys { s.waiters[key] = nil }
            return due.values.map(\.continuation)
        }
        for continuation in ready { continuation.resume() }
    }

    func wait(atLeast need: Int) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { s -> Bool in
                    if s.count >= need || Task.isCancelled { return true }
                    s.waiters[id] = Waiter(need: need, continuation: continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume()
        }
    }
}

/// Le journal commun des appels, dans l'ordre où ils ont eu lieu : il prouve un ordre entre le son, le modèle et les événements
/// sans lire deux journaux après coup.
final class CallJournal: Sendable {
    private let lines = OSAllocatedUnfairLock(initialState: [String]())
    func add(_ line: String) { lines.withLock { $0.append(line) } }
    var all: [String] { lines.withLock { $0 } }
    func index(of line: String) -> Int? { all.firstIndex(of: line) }
    func count(of line: String) -> Int { all.filter { $0 == line }.count }
}

// MARK: - Son

/// `ScriptedAudioIO` observé : il journalise `start`, `stop` (à son retour) et `play`, compte les clips en file (au plus deux) et
/// peut refuser une lecture. Tout le reste est celui du double.
final class ObservedAudio: AudioIO, @unchecked Sendable {
    let inner: ScriptedAudioIO
    private let journal: CallJournal
    /// Nombre de clips acceptés par `play`.
    let plays = CountLatch()
    /// Ouverte quand `stop()` a rendu la main.
    let stopped = Gate()
    private let state = OSAllocatedUnfairLock(
        initialState: (playError: nil as (any Error)?, inQueue: 0, peak: 0, onStart: nil as (@Sendable () -> Void)?))

    init(completion: ScriptedAudioIO.Completion, startError: AudioCaptureError?, journal: CallJournal) {
        inner = ScriptedAudioIO(startError: startError, completion: completion)
        self.journal = journal
    }

    var peakQueuedClips: Int { state.withLock { $0.peak } }

    /// Fait refuser toute lecture (`play` lève).
    func failPlays(with error: any Error) { state.withLock { $0.playError = error } }

    /// Appelée au début de `start`, avant le double.
    func onStart(_ body: @escaping @Sendable () -> Void) { state.withLock { $0.onStart = body } }

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        state.withLock { $0.onStart }?()
        try inner.start(onChunk: onChunk)
        journal.add("audio.start")
    }

    func stop() {
        journal.add("audio.stop")
        inner.stop()
        journal.add("audio.stop.returned")
        stopped.open()
    }

    func play(_ clip: AudioClip, onEnd: @escaping @Sendable (PlaybackEnd) -> Void) throws {
        if let error = state.withLock({ $0.playError }) { throw error }
        state.withLock { s in
            s.inQueue += 1
            s.peak = max(s.peak, s.inQueue)
        }
        do {
            try inner.play(clip) { [self] end in
                state.withLock { $0.inQueue -= 1 }
                onEnd(end)
            }
        } catch {
            state.withLock { $0.inQueue -= 1 }
            throw error
        }
        journal.add("audio.play")
        plays.increment()
    }

    func stopPlayback() {
        journal.add("audio.stopPlayback")
        inner.stopPlayback()
    }

    var playbackPosition: Double? { inner.playbackPosition }
}

// MARK: - Voix

/// La voix doublée. Une phrase reçue, une réponse décidée par le test ; `.hold` retient l'appel jusqu'à `release(call:)` ou à
/// l'annulation de la tâche (qui lève alors `CancellationError`, comme le fait un vrai synthétiseur).
final class ScriptedSpeech: SpeechSynthesizer, @unchecked Sendable {
    enum Reply: Sendable {
        /// Un clip non vide, dont tous les échantillons valent `rang + 1` (pour reconnaître la phrase qu'il porte).
        case clip
        case fellBack
        case fail(any Error)
        case hold
    }

    private let reply: @Sendable (Int, String) -> Reply
    private let state = OSAllocatedUnfairLock(initialState: (texts: [String](), released: Set<Int>(), cancelled: 0, active: 0, peak: 0))
    private let calls = CountLatch()
    private let gates = OSAllocatedUnfairLock(initialState: [Int: Gate]())

    init(reply: @escaping @Sendable (Int, String) -> Reply = { _, _ in .clip }) {
        self.reply = reply
    }

    var texts: [String] { state.withLock { $0.texts } }
    /// Nombre d'appels qui ont vu leur tâche annulée pendant qu'ils étaient retenus.
    var cancelledCalls: Int { state.withLock { $0.cancelled } }
    /// Le plus grand nombre de synthèses en cours en même temps.
    var peakConcurrentSyntheses: Int { state.withLock { $0.peak } }

    func waitForCalls(_ count: Int) async { await calls.wait(atLeast: count) }

    private func gate(_ call: Int) -> Gate {
        gates.withLock { all in
            if let gate = all[call] { return gate }
            let gate = Gate()
            all[call] = gate
            return gate
        }
    }

    /// Rend la main à l'appel retenu de rang `call`.
    func release(call: Int) { gate(call).open() }

    func synthesize(_ text: String) async throws -> Speech {
        let index = state.withLock { s -> Int in
            s.texts.append(text)
            s.active += 1
            s.peak = max(s.peak, s.active)
            return s.texts.count - 1
        }
        defer { state.withLock { $0.active -= 1 } }
        calls.increment()
        let clip = AudioClip(samples: [Float](repeating: Float(index + 1), count: 160), sampleRate: 16000)
        switch reply(index, text) {
        case .clip: return Speech(clip: clip)
        case .fellBack: return Speech(clip: clip, fellBack: true)
        case .fail(let error): throw error
        case .hold:
            await gate(index).wait()
            if Task.isCancelled {
                state.withLock { $0.cancelled += 1 }
                throw CancellationError()
            }
            return Speech(clip: clip)
        }
    }
}

// MARK: - Modèles

/// Un modèle qui rend, à sa n-ième requête, la réponse de son n-ième `ScriptedModel`. Une requête de plus que prévu est une
/// erreur du test (et rend une panne, pour ne rien laisser pendre).
final class ModelSequence: LanguageModel, @unchecked Sendable {
    private let label: String
    private let journal: CallJournal
    private let models: [ScriptedModel]
    private let state = OSAllocatedUnfairLock(
        initialState: (calls: 0, onComplete: nil as (@Sendable () -> Void)?, onExcess: nil as (@Sendable () -> Void)?))

    init(_ label: String, _ models: [ScriptedModel], journal: CallJournal) {
        self.label = label
        self.models = models
        self.journal = journal
    }

    var calls: Int { state.withLock { $0.calls } }
    /// Les requêtes reçues, dans l'ordre.
    var requests: [CompletionRequest] { models.flatMap(\.requests) }
    /// La réponse de rang `index` ; un rang absent est une erreur du test, enregistrée, qui ne plante pas le processus.
    func model(at index: Int) -> ScriptedModel {
        guard models.indices.contains(index) else {
            Issue.record("aucune réponse de rang \(index) au modèle \(label)")
            return ScriptedModel()
        }
        return models[index]
    }

    /// Appelée quand une requête arrive alors que toutes les réponses prévues sont servies : le montage y met fin à l'entretien, pour
    /// que le test qui a une requête de trop échoue tout de suite et non à la limite de temps de la suite.
    func onExcess(_ body: @escaping @Sendable () -> Void) { state.withLock { $0.onExcess = body } }

    /// Appelée à chaque requête, avant qu'elle soit servie : le test y prend un instantané de l'état du son.
    func onComplete(_ body: @escaping @Sendable () -> Void) { state.withLock { $0.onComplete = body } }

    func complete(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        let (index, observer, excess) = state.withLock { s -> (Int, (@Sendable () -> Void)?, (@Sendable () -> Void)?) in
            s.calls += 1
            return (s.calls - 1, s.onComplete, s.onExcess)
        }
        journal.add("\(label).complete")
        observer?()
        guard index < models.count else {
            Issue.record("requête de trop au modèle \(label) (rang \(index))")
            excess?()
            // Un flux qui ne finit qu'à l'annulation : l'entretien attend, et la fin que `excess` lui donne le range.
            return AsyncThrowingStream { _ in }
        }
        return models[index].complete(request)
    }
}

/// Une réponse de modèle : les morceaux de texte, la fin normale.
func modelReply(_ chunks: String...) -> ScriptedModel {
    ScriptedModel(chunks.map { .text($0) } + [.stop(.complete), .finish])
}

/// Une réponse coupée en morceaux de `size` scalaires.
func modelReply(_ text: String, cutEvery size: Int) -> ScriptedModel {
    let scalars = Array(text.unicodeScalars)
    var steps: [ScriptedModel.Step] = []
    var index = 0
    while index < scalars.count {
        var piece = String.UnicodeScalarView()
        piece.append(contentsOf: scalars[index..<min(index + size, scalars.count)])
        steps.append(.text(String(piece)))
        index += size
    }
    return ScriptedModel(steps + [.stop(.complete), .finish])
}

// MARK: - Événements

/// Lit le flux d'événements et laisse le test attendre sans sonder ni dormir.
final class EventLog: @unchecked Sendable {
    private struct Waiter {
        var need: Int
        var matches: @Sendable (ConversationEvent) -> Bool
        var continuation: CheckedContinuation<Void, Never>
    }
    private let state = OSAllocatedUnfairLock(initialState: (items: [ConversationEvent](), ended: false, waiters: [UUID: Waiter]()))

    /// Commence à lire `stream`. Le lecteur se termine avec le flux (celui de l'entretien finit juste après `.finished`).
    static func reading(_ stream: AsyncStream<ConversationEvent>) -> EventLog {
        let log = EventLog()
        Task {
            for await event in stream { log.append(event) }
            log.finishReading()
        }
        return log
    }

    private func append(_ event: ConversationEvent) {
        let ready = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.items.append(event)
            var due: [CheckedContinuation<Void, Never>] = []
            for (key, waiter) in s.waiters where s.items.filter(waiter.matches).count >= waiter.need {
                due.append(waiter.continuation)
                s.waiters[key] = nil
            }
            return due
        }
        for continuation in ready { continuation.resume() }
    }

    private func finishReading() {
        let waiters = state.withLock { s -> [Waiter] in
            s.ended = true
            defer { s.waiters = [:] }
            return Array(s.waiters.values)
        }
        for waiter in waiters { waiter.continuation.resume() }
    }

    var items: [ConversationEvent] { state.withLock { $0.items } }
    var ended: Bool { state.withLock { $0.ended } }

    func count(_ matches: (ConversationEvent) -> Bool) -> Int { items.filter(matches).count }

    /// Rend la main quand `count` événements au moins satisfont `matches` (ou quand le flux se termine, ou à l'annulation).
    func wait(_ count: Int = 1, where matches: @escaping @Sendable (ConversationEvent) -> Bool) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = state.withLock { s -> Bool in
                    if s.items.filter(matches).count >= count || s.ended || Task.isCancelled { return true }
                    s.waiters[id] = Waiter(need: count, matches: matches, continuation: continuation)
                    return false
                }
                if ready { continuation.resume() }
            }
        } onCancel: {
            state.withLock { $0.waiters.removeValue(forKey: id) }?.continuation.resume()
        }
    }

    /// Attend `count` fois l'événement `event`.
    func wait(_ event: ConversationEvent, count: Int = 1) async {
        await wait(count) { $0 == event }
    }

    /// Attend la fin du flux, et rend tout ce qui est arrivé.
    @discardableResult
    func waitForEnd() async -> [ConversationEvent] {
        await wait(Int.max) { _ in false }
        return items
    }

    /// Les événements sans les niveaux et les textes cumulés (qui dépendent du découpage).
    var trace: [ConversationEvent] {
        items.filter {
            switch $0 {
            case .level, .replyText, .partialTranscript: false
            default: true
            }
        }
    }

    /// La fin de l'entretien, si elle est arrivée.
    var end: ConversationEnd? {
        for case .finished(let end) in items { return end }
        return nil
    }
}

// MARK: - Le montage

/// Un tour parlé : `blocks` blocs de 1 000 échantillons sont poussés ; le détecteur annonce le début de la voix au bloc `start`
/// (échantillon `start × 1 000`) et sa fin au dernier bloc (échantillon `end × 1 000`). `base` est le rang du premier échantillon de
/// la rampe : l'échantillon `i` du tour vaut `(base + i) / 100 000`, ce qui permet de reconnaître chaque échantillon dans ce que
/// reçoivent les doubles.
struct TurnScript {
    var blocks: Int
    var start: Int
    var end: Int
    var base: Int

    init(blocks: Int = 6, start: Int = 1, end: Int = 4, base: Int) {
        self.blocks = blocks
        self.start = start
        self.end = end
        self.base = base
    }
}

/// La configuration des tests : noms d'exemple, aucune attente réelle (la limite de chaque requête ne rend jamais, sauf
/// annulation).
func makeConversationConfig(maxQuestions: Int = 8, template: String = "", vocabulary: [String] = ["Supervox"],
                            padding: Double = 0, previewInterval: Double = 1, transcriptionTimeout: Double = 12.5) -> ConversationConfig {
    // Des nombres DISTINCTS de `RewritePolicy.turn` (1 024 / 30) et de `.standard` (16 000 / 120) : une politique écrite en dur dans le
    // moteur ne passerait pas pour celle de la configuration. Le harnais remplace l'attente (`sleep`) par un `TickSleeper`.
    let never: @Sendable (Double) async throws -> Void = { _ in try await Task.sleep(for: .seconds(1_000_000)) }
    return ConversationConfig(
        fastModel: "modele-exemple-rapide", strongModel: "modele-exemple-fort", maxQuestions: maxQuestions,
        template: template, language: "fr", vocabulary: vocabulary, interruptMinDuration: 0.3, interruptLevel: -30,
        padding: padding, previewInterval: previewInterval, transcriptionTimeout: transcriptionTimeout,
        turnPolicy: RewritePolicy(maxTokens: 777, timeout: 17, sleep: never),
        conclusionPolicy: RewritePolicy(maxTokens: 4_321, timeout: 43, sleep: never))
}

/// L'entretien et tous ses doubles.
final class ConversationHarness: @unchecked Sendable {
    let journal = CallJournal()
    let audio: ObservedAudio
    let detector: ScriptedDetector
    let transcriber: ScriptedTranscriber
    let fast: ModelSequence
    let strong: ModelSequence
    let speech: ScriptedSpeech
    let clock = TestClock()
    /// L'attente de l'aperçu (`sleep` de l'entretien) et celle du chien de garde du micro : deux `TickSleeper`, aucune durée réelle.
    let previewSleeper = TickSleeper()
    let watchdogSleeper = TickSleeper()
    /// L'attente de la limite de temps d'une transcription (tour ou aperçu), distincte de celle de l'aperçu : elle ne compte que les
    /// limites demandées au moteur de transcription.
    let transcriptionSleeper = TickSleeper()
    /// Les attentes des politiques de requête (délai du tour, délai de la conclusion) : elles enregistrent la durée que le moteur leur
    /// demande, ce qui prouve d'où vient chaque politique.
    let turnSleeper = TickSleeper()
    let conclusionSleeper = TickSleeper()
    let chain: ConversationChain
    let turns: [TurnScript]
    private let state = OSAllocatedUnfairLock(initialState: (log: nil as EventLog?, said: 0, strongSeen: [(log: [String], running: Bool)]()))

    /// - Parameters:
    ///   - transcripts: la réponse du moteur de transcription à son n-ième appel (aperçus compris).
    ///   - detectorFailure: le bloc de rang global donné fait échouer le détecteur.
    ///   - watchdogSleep: l'attente du chien de garde à la place du `TickSleeper` (pour une attente sourde à l'annulation).
    ///   - transcriberHonorsCancellation: faux, le moteur de transcription est sourd à l'annulation (un appel retenu ne rend la main qu'à `release`).
    init(turns: [TurnScript] = [], transcripts: @escaping @Sendable (Int) -> ScriptedTranscriber.Reply = { _ in .text("réponse") },
         fast: [ScriptedModel] = [], strong: [ScriptedModel] = [modelReply("Prompt final")], speech: ScriptedSpeech = ScriptedSpeech(),
         completion: ScriptedAudioIO.Completion = .immediate, startError: AudioCaptureError? = nil,
         config baseConfig: ConversationConfig = makeConversationConfig(), detectorPrepareError: (any Error)? = nil,
         detectorFailure: (block: Int, error: any Error)? = nil, transcriberHonorsCancellation: Bool = true,
         watchdogSleep: (@Sendable (Double) async throws -> Void)? = nil,
         makeResampler: (@Sendable (Double, Double) -> StreamingResampler?)? = nil) {
        self.turns = turns
        var config = baseConfig
        let turnWait = turnSleeper, conclusionWait = conclusionSleeper
        config.turnPolicy.sleep = { try await turnWait.sleep($0) }
        config.conclusionPolicy.sleep = { try await conclusionWait.sleep($0) }
        audio = ObservedAudio(completion: completion, startError: startError, journal: journal)
        var events: [Int: VoiceEvent] = [:]
        var offset = 0
        for turn in turns {
            events[offset + turn.start] = .speechStart(sample: turn.start * 1000)
            events[offset + turn.blocks - 1] = .speechEnd(sample: turn.end * 1000)
            offset += turn.blocks
        }
        detector = ScriptedDetector(blockSize: 1000, events: events)
        detector.prepareError = detectorPrepareError
        detector.processFailure = detectorFailure
        transcriber = ScriptedTranscriber(honorsCancellation: transcriberHonorsCancellation, reply: transcripts)
        self.fast = ModelSequence("fast", fast, journal: journal)
        self.strong = ModelSequence("strong", strong, journal: journal)
        self.speech = speech
        let journal = journal
        let tap: @Sendable (ConversationEvent) -> Void = { event in
            switch event {
            case .state(let state): journal.add("event.state.\(state)")
            case .finished: journal.add("event.finished")
            default: break
            }
        }
        let watchdog = watchdogSleep.map { MicrophoneWatchdog(timeout: 1, firstChunkTimeout: 3, pollInterval: 0.25, sleep: $0) }
            ?? watchdogSleeper.watchdog
        let sleeper = previewSleeper
        let transcriptionWait = transcriptionSleeper
        let audioIO = audio
        chain = ConversationChain(
            audio: audioIO, detector: detector, transcriber: transcriber, fastModel: self.fast, strongModel: self.strong,
            voice: speech, config: config, watchdog: watchdog, now: self.clock.reader,
            sleep: { try await sleeper.sleep($0) }, transcriptionSleep: { try await transcriptionWait.sleep($0) },
            makeResampler: makeResampler, eventTap: tap)
        let seen = self.state
        let log = audioIO
        self.strong.onComplete {
            seen.withLock { $0.strongSeen.append((log: log.inner.log, running: log.inner.isRunning)) }
        }
        // Une requête de trop à l'un des modèles met fin à l'entretien : le test échoue tout de suite (le problème est déjà enregistré).
        let ending = chain
        self.fast.onExcess { Task { await ending.cancel() } }
        self.strong.onExcess { Task { await ending.cancel() } }
    }

    var log: EventLog? { state.withLock { $0.log } }

    /// Ce que le son était à chaque requête au modèle fort : son journal et s'il tournait encore.
    var audioAtStrongRequests: [(log: [String], running: Bool)] { state.withLock { $0.strongSeen } }

    /// Annule l'entretien et attend qu'il soit arrêté, mais rend la main si la tâche du test est annulée (limite de temps de la
    /// suite) : un entretien qui ne s'arrête pas fait échouer le test, il ne le laisse pas en vie.
    func cancel() async {
        let chain = chain
        await untilDoneOrCancelled { await chain.cancel() }
    }

    @discardableResult
    func start() async -> EventLog {
        let log = EventLog.reading(await chain.start())
        state.withLock { $0.log = log }
        return log
    }

    /// Dit le tour `index` : attend que l'entretien écoute, puis pousse les blocs du tour.
    func say(_ index: Int) async {
        guard let log else { return }
        guard turns.indices.contains(index) else {
            Issue.record("le tour \(index) n'est pas scripté")
            return
        }
        let turn = turns[index]
        let said = state.withLock { s -> Int in
            defer { s.said += 1 }
            return s.said
        }
        await log.wait(said + 1) { $0 == .state(.listening) }
        for block in 0..<turn.blocks {
            let first = turn.base + block * 1000
            audio.inner.push(rampChunk(first..<(first + 1000)))
        }
    }

    /// Le clip que le moteur de transcription doit recevoir pour le tour `index` quand le remplissage est nul.
    func expectedClip(turn index: Int) -> AudioClip {
        guard turns.indices.contains(index) else {
            Issue.record("le tour \(index) n'est pas scripté")
            return AudioClip(samples: [], sampleRate: 16000)
        }
        let turn = turns[index]
        return AudioClip(samples: rampSamples((turn.base + turn.start * 1000)..<(turn.base + turn.end * 1000)), sampleRate: 16000)
    }
}

/// Une conversation dont les tours sont `texts` (la personne puis l'intervieweur, en alternance).
func conversation(_ texts: String...) -> Conversation {
    var conversation = Conversation()
    for (index, text) in texts.enumerated() {
        if index.isMultiple(of: 2) { conversation.appendUser(text) } else { conversation.appendInterviewer(text) }
    }
    return conversation
}

/// Rend la main quand `body` a fini, ou quand la tâche appelante est annulée (alors `body` continue sans que personne l'attende).
func untilDoneOrCancelled(_ body: @escaping @Sendable () async -> Void) async {
    let once = Once()
    await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            once.install(continuation)
            Task {
                await body()
                once.fire()
            }
        }
    } onCancel: {
        once.fire()
    }
}

/// Reprend une attente au plus une fois, que le déclenchement vienne avant ou après la pose de l'attente.
final class Once: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (fired: false, continuation: nil as CheckedContinuation<Void, Never>?))

    func install(_ continuation: CheckedContinuation<Void, Never>) {
        let fireNow = state.withLock { s -> Bool in
            if s.fired { return true }
            s.continuation = continuation
            return false
        }
        if fireNow { continuation.resume() }
    }

    func fire() {
        let continuation = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.fired = true
            defer { s.continuation = nil }
            return s.continuation
        }
        continuation?.resume()
    }
}

/// Rend la main quand `condition` est vraie, en cédant la main entre deux lectures (aucune durée : un compte de passages). Rend la
/// main aussi quand la tâche est annulée (limite de temps de la suite) : `false` alors.
func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    while !Task.isCancelled {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
