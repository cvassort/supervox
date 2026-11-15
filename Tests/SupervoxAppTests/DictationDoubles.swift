import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Barrière : `wait()` attend jusqu'à `open()`, sans durée réelle. Ne regarde pas l'annulation de la tâche qui attend
/// (un moteur qui ignore l'annulation se comporte ainsi) ; seul `open()` la libère, et les tests l'ouvrent dans un `defer`
/// pour qu'un échec ne laisse jamais rien pendu.
final class TestGate: Sendable {
    private let state = Mutex<(isOpen: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
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

/// Session de dictée double. Elle ne fait rien d'elle-même : le test émet les instantanés, et choisit si `finish()` rend la
/// main. Elle garde ce que le contrôleur lui a demandé, et dans quelle phase (le vrai contrat perd un `finish()` reçu en
/// `idle`).
final class FakeSession: DictationSessioning {
    let snapshots: AsyncStream<DictationSnapshot>
    private let sink: AsyncStream<DictationSnapshot>.Continuation
    private let finishGate: TestGate?
    private let state = Mutex<(calls: [String], phase: DictationPhase, finishPhases: [DictationPhase])>(([], .idle, []))

    init(finishGate: TestGate? = nil) {
        self.finishGate = finishGate
        (snapshots, sink) = AsyncStream<DictationSnapshot>.makeStream()
        sink.yield(DictationSnapshot())
    }

    func start() async { record("start") }

    func finish() async {
        state.withLock {
            $0.calls.append("finish")
            $0.finishPhases.append($0.phase)
        }
        await finishGate?.wait()
    }

    func cancel() async { record("cancel") }

    private func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    var calls: [String] { state.withLock { $0.calls } }
    /// La phase de la session à chaque `finish()` reçu.
    var finishPhases: [DictationPhase] { state.withLock { $0.finishPhases } }
    func count(of call: String) -> Int { calls.filter { $0 == call }.count }

    /// Le flux de la session se termine (le contrôleur n'a plus rien à lire).
    func end() { sink.finish() }

    func emit(_ snapshot: DictationSnapshot) {
        state.withLock { $0.phase = snapshot.phase }
        sink.yield(snapshot)
    }

    func emit(_ phase: DictationPhase, liveText: String = "", level: Float = 0, elapsed: Double = 0) {
        emit(DictationSnapshot(phase: phase, liveText: liveText, level: level, elapsed: elapsed))
    }
}

/// L'environnement double : garde les réglages reçus à chaque fabrication, donne des sessions doubles, et compte ce qu'on lui
/// demande.
final class FakeEngines: Sendable {
    struct State {
        var sessions: [FakeSession] = []
        var queue: [FakeSession] = []
        var settingsSeen: [TranscriptionSettings] = []
        var makeGate: TestGate?
        var makeError: (any Error)?
        var modelMissing = false
        var countCalls = 0
        /// La tâche qui fabriquait la session était annulée quand la fabrication a repris.
        var cancelledDuringMake = false
        /// L'ordre des appels à l'environnement : « download », « count », « make ».
        var events: [String] = []
        var downloadGate: TestGate?
        var downloadError: (any Error)?
        var downloadOutcome = ModelDownloadOutcome.complete
        var downloadedFor: [TranscriptionSettings] = []
        var tokenCount: @Sendable ([String], String) -> Int? = { terms, _ in terms.count }
        var limit = 1000
        /// Les moteurs sont déjà chargés en mémoire (une préparation instantanée) : le défaut, qui laisse les avis inchangés.
        var enginesLoaded = true
        /// Retient `enginesLoaded` (puis la fabrication) tant que la porte n'est pas ouverte.
        var loadedGate: TestGate?
        var preloadedFor: [TranscriptionSettings] = []
        var preloadGate: TestGate?
    }

    let state = Mutex(State())

    var sessions: [FakeSession] { state.withLock { $0.sessions } }
    var settingsSeen: [TranscriptionSettings] { state.withLock { $0.settingsSeen } }
    var countCalls: Int { state.withLock { $0.countCalls } }
    var cancelledDuringMake: Bool { state.withLock { $0.cancelledDuringMake } }
    var events: [String] { state.withLock { $0.events } }
    var downloadedFor: [TranscriptionSettings] { state.withLock { $0.downloadedFor } }
    var preloadedFor: [TranscriptionSettings] { state.withLock { $0.preloadedFor } }

    func configure(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    var environment: DictationEnvironment {
        DictationEnvironment(
            makeSession: { [self] settings in
                let gate = state.withLock { state -> TestGate? in
                    state.events.append("make")
                    state.settingsSeen.append(settings)
                    return state.makeGate
                }
                await gate?.wait()
                let wasCancelled = Task.isCancelled
                state.withLock { $0.cancelledDuringMake = wasCancelled }
                let (error, session) = state.withLock { state -> ((any Error)?, FakeSession) in
                    let session = state.queue.isEmpty ? FakeSession() : state.queue.removeFirst()
                    if state.makeError == nil { state.sessions.append(session) }
                    return (state.makeError, session)
                }
                if let error { throw error }
                return session
            },
            needsModelDownload: { [self] _ in state.withLock { $0.modelMissing } },
            downloadModels: { [self] settings in
                let (gate, error, outcome) = state.withLock { state -> (TestGate?, (any Error)?, ModelDownloadOutcome) in
                    state.events.append("download")
                    state.downloadedFor.append(settings)
                    return (state.downloadGate, state.downloadError, state.downloadOutcome)
                }
                await gate?.wait()
                if let error { throw error }
                return outcome
            },
            promptTokenCount: { [self] terms, model in
                let count = state.withLock { state -> @Sendable ([String], String) -> Int? in
                    state.countCalls += 1
                    state.events.append("count")
                    return state.tokenCount
                }
                return count(terms, model)
            },
            promptTokenLimit: state.withLock { $0.limit },
            enginesLoaded: { [self] _ in
                let (loaded, gate) = state.withLock { state -> (Bool, TestGate?) in
                    return (state.enginesLoaded, state.loadedGate)
                }
                await gate?.wait()
                return loaded
            },
            preload: { [self] settings in
                let gate = state.withLock { state -> TestGate? in
                    state.preloadedFor.append(settings)
                    return state.preloadGate
                }
                await gate?.wait()
            })
    }
}

/// Panneau double. `close()` imite le vrai : un panneau qui se ferme prévient le contrôleur de dictée.
@MainActor final class FakeDictationPanel: PanelOpening {
    private(set) var isOpen = false
    private(set) var openCount = 0
    private(set) var closeCount = 0
    /// Les valeurs de clavier demandées, dans l'ordre.
    private(set) var keyboards: [PanelKeyboard] = []
    var onClosed: (@MainActor () -> Void)?
    /// Le journal de l'insertion, partagé pour comparer l'ordre des appels (« keyboard(none) » avant l'attente et l'insertion).
    var log: CallLog?
    /// Appelé à chaque `setKeyboard`, avant l'enregistrement : le test y lit ce que le contrôleur montre à cet instant.
    var onSetKeyboard: (@MainActor (PanelKeyboard) -> Void)?

    func open() {
        guard !isOpen else { return }
        isOpen = true
        openCount += 1
    }

    func setKeyboard(_ keyboard: PanelKeyboard) {
        onSetKeyboard?(keyboard)
        keyboards.append(keyboard)
        log?.entries.append("keyboard(\(keyboard))")
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        closeCount += 1
        onClosed?()
    }
}

/// Un lieu où le test change ce que les fermetures du contrôleur lisent.
@MainActor final class DictationKnobs {
    var settings = TranscriptionSettings.defaults
    var behavior = HotKeyBehavior.toggle
    var modeID = "dictee-brute"
    var microphoneAllowed = true
    /// Les modificateurs du raccourci que le contrôleur lit au début d'une dictée en maintien.
    var hotKeyModifiers: Modifiers = [.control, .option]
    /// Ce que répond la sonde des modificateurs ; `probes` garde chaque question posée (les modificateurs demandés).
    var modifiersHeld = true
    var probes: [Modifiers] = []
    /// Ce que répond la sonde d'Échap ; `escapeProbes` compte les questions posées.
    var escapeHeld = false
    var escapeProbes = 0
    /// Les modes dont le réglage « relire avant de coller » est actif, et chaque lecture que le contrôleur en a faite.
    var reviewing: Set<String> = []
    var reviewReads: [String] = []
}

/// L'attente du contrôleur entre le retrait de la frappe et l'insertion : elle journalise sa durée, n'attend rien, sauf si le
/// test la retient (`holds`) : elle dure alors jusqu'à `sleeper.release()` ou jusqu'à l'annulation de la tâche qui l'attend.
@MainActor final class HandoverWait {
    private let log: CallLog
    let sleeper: SleepingWait
    private(set) var durations: [Double] = []
    var holds = false
    /// Une attente qui ignore l'annulation de la tâche qui l'attend (comme celle de restauration de l'insertion) : elle dure
    /// jusqu'à `gate.open()`, puis rend la main même à une tâche annulée. Prime sur `holds`.
    var gate: TestGate?

    init(log: CallLog) {
        self.log = log
        sleeper = SleepingWait(log: log)
    }

    func wait(_ seconds: Double) async {
        durations.append(seconds)
        if let gate {
            log.entries.append("wait(\(seconds))")
            await gate.wait()
        } else if holds {
            await sleeper.wait(seconds)
        } else {
            log.entries.append("wait(\(seconds))")
        }
    }
}

/// Le contrôleur et tous ses doubles : vrai `TextInserter` sur presse-papiers, touches et attente doubles.
@MainActor final class DictationHarness {
    let panel = FakeDictationPanel()
    let rig: InsertionRig
    let engines = FakeEngines()
    let knobs = DictationKnobs()
    /// L'attente du sondage des modificateurs : elle dure jusqu'à `holdSleeper.release()` (un « tic »), ou à l'annulation.
    let holdSleeper = SleepingWait(log: CallLog())
    /// L'attente de la relecture avant l'insertion (voir `HandoverWait`).
    let handover: HandoverWait
    let controller: DictationController
    /// Le contenu du presse-papiers double à chaque ⌘V posté : les textes réellement collés, dans l'ordre.
    private(set) var pasted: [String] = []
    private(set) var views: [DictationViewState] = []

    /// `limit` : la limite de jetons d'amorce de Whisper que l'environnement double annonce. `heldModifiers` : ce que le poseur
    /// de touches double répond aux sondages des modificateurs.
    init(
        trusted: Bool = true, wait: (@MainActor (Double) async -> Void)? = nil, log: CallLog = CallLog(),
        limit: Int = 1000, heldModifiers: [Bool] = [false]
    ) {
        rig = InsertionRig(log: log, trusted: trusted, held: heldModifiers, wait: wait)
        engines.configure { $0.limit = limit }
        let knobs = knobs
        let handover = HandoverWait(log: log)
        self.handover = handover
        panel.log = log
        controller = DictationController(
            environment: engines.environment, inserter: rig.inserter,
            settings: { knobs.settings }, behavior: { knobs.behavior }, modeID: { knobs.modeID },
            microphoneAllowed: { knobs.microphoneAllowed }, panel: panel,
            hotKeyModifiers: { knobs.hotKeyModifiers },
            hold: HoldWatch(
                anyHeld: { modifiers in
                    knobs.probes.append(modifiers)
                    return knobs.modifiersHeld
                },
                escapeHeld: {
                    knobs.escapeProbes += 1
                    return knobs.escapeHeld
                },
                wait: { [holdSleeper] in await holdSleeper.wait($0) }),
            reviewBeforePaste: { mode in
                knobs.reviewReads.append(mode)
                return knobs.reviewing.contains(mode)
            },
            wait: { await handover.wait($0) })
        panel.onClosed = { [controller] in controller.panelClosedByUser() }
        rig.keys.onPostPaste = { [weak self] in self?.pasted.append(self?.rig.board.text ?? "") }
        controller.onViewChange = { [weak self] in self?.views.append($0) }
    }

    /// Les textes que le presse-papiers double a reçus (écritures du texte dicté), dans l'ordre.
    var writtenTexts: Int { rig.log.entries.filter { $0.hasPrefix("writeText") }.count }

    /// La n-ième session fabriquée, attendue.
    func session(_ index: Int = 0) async -> FakeSession {
        let found = await until { engines.sessions.count > index }
        #expect(found)
        return found ? engines.sessions[index] : FakeSession()
    }

    /// Appui sur le raccourci, puis la session est menée jusqu'à `recording`.
    @discardableResult
    func startRecording(index: Int = 0) async -> FakeSession {
        controller.hotKeyPressed()
        return await driveToRecording(index: index)
    }

    @discardableResult
    func driveToRecording(index: Int = 0) async -> FakeSession {
        let session = await session(index)
        #expect(await until { session.calls.contains("start") })
        session.emit(.preparing)
        session.emit(.recording)
        #expect(await until { controller.view.stage == .recording })
        return session
    }
}

/// Rend la main aux tâches en attente jusqu'à ce que `condition` soit vraie. Aucune horloge de test : au plus 20 000 passages,
/// avec une attente d'une milliseconde tous les 50 (soit au plus environ 0,4 s, consommées seulement en cas d'échec) pour
/// laisser avancer les fils d'arrière-plan, même sous charge.
@MainActor
func until(_ condition: @MainActor () -> Bool) async -> Bool {
    for round in 0..<20000 {
        if condition() { return true }
        if round % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
    }
    return condition()
}

/// Laisse le temps à tout ce qui est déjà en route d'arriver (pour prouver qu'une chose n'a PAS lieu).
@MainActor
func settle() async {
    for round in 0..<300 {
        if round % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
    }
}

extension DictationStage {
    /// L'écran dit comment la dictée a fini : texte copié, interruption ou échec.
    var isTerminal: Bool {
        switch self {
        case .copied, .cancelled, .failed: true
        case .idle, .preparing, .recording, .finalizing, .review, .pasting: false
        }
    }
}
