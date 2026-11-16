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

    /// Sans effet panneau fermé, comme `PanelController.setKeyboard` : une demande faite avant `open()` ne se verrait pas.
    func setKeyboard(_ keyboard: PanelKeyboard) {
        guard isOpen else { return }
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

/// Un appel de mise en forme en cours : le test livre du texte (`deliver`) et rend l'issue (`finish`) quand il veut. Sans
/// durée réelle. `ignoresCancellation` : l'appel ne rend pas la main à l'annulation de la tâche (un modèle sourd) ; sinon il
/// rend `.cancelled`, comme le vrai.
final class RewriteCall: Sendable {
    private struct State {
        var continuation: CheckedContinuation<RewriteOutcome, Never>?
        var result: RewriteOutcome?
        var sawCancellation = false
    }

    let job: RewriteJob
    let onText: @MainActor (String) -> Void
    private let ignoresCancellation: Bool
    private let state = Mutex(State())

    init(job: RewriteJob, onText: @escaping @MainActor (String) -> Void, ignoresCancellation: Bool) {
        self.job = job
        self.onText = onText
        self.ignoresCancellation = ignoresCancellation
    }

    /// La tâche qui attendait l'issue a vu son annulation.
    var sawCancellation: Bool { state.withLock { $0.sawCancellation } }

    func wait() async -> RewriteOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RewriteOutcome, Never>) in
                let ready = state.withLock { state -> RewriteOutcome? in
                    if let result = state.result { return result }
                    state.continuation = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            let waiting = state.withLock { state -> CheckedContinuation<RewriteOutcome, Never>? in
                state.sawCancellation = true
                guard !ignoresCancellation, state.result == nil else { return nil }
                state.result = .cancelled
                defer { state.continuation = nil }
                return state.continuation
            }
            waiting?.resume(returning: .cancelled)
        }
    }

    func finish(_ outcome: RewriteOutcome) {
        let waiting = state.withLock { state -> CheckedContinuation<RewriteOutcome, Never>? in
            guard state.result == nil else { return nil }
            state.result = outcome
            defer { state.continuation = nil }
            return state.continuation
        }
        waiting?.resume(returning: outcome)
    }
}

/// La mise en forme double : garde chaque travail reçu, et ne rend rien tant que le test ne l'a pas décidé.
@MainActor final class FakeRewriter {
    private(set) var calls: [RewriteCall] = []
    /// Les modèles dont `providerName` a été demandé, dans l'ordre.
    private(set) var nameAsks: [ModelChoice?] = []
    var providerName: String? = "Fournisseur exemple"
    var ignoresCancellation = false

    var jobs: [RewriteJob] { calls.map(\.job) }

    var environment: RewriteEnvironment {
        RewriteEnvironment(
            rewrite: { [self] job, onText in
                let call = RewriteCall(job: job, onText: onText, ignoresCancellation: ignoresCancellation)
                calls.append(call)
                return await call.wait()
            },
            providerName: { [self] choice in
                nameAsks.append(choice)
                return providerName
            })
    }

    /// L'appel n° `index`, attendu.
    func call(_ index: Int = 0) async -> RewriteCall {
        let found = await until { calls.count > index }
        #expect(found)
        return found ? calls[index] : RewriteCall(job: RewriteJob(instruction: "", input: "", model: nil), onText: { _ in }, ignoresCancellation: false)
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
    /// Les modificateurs du raccourci de chaque mode, lus au début d'une dictée en maintien commencée par ce raccourci ; un mode
    /// absent n'en a aucun. `modeModifierReads` garde chaque lecture.
    var modeModifiers: [String: Modifiers] = [:]
    var modeModifierReads: [String] = []
    /// Les modes que le raccourci d'un mode a fait choisir, dans l'ordre ; le mode choisi (`modeID`) les suit.
    var selectedModes: [String] = []
    /// Les propriétaires dont le raccourci n'est plus enregistré (le mode a perdu le sien, ou n'existe plus).
    var unbound: Set<HotKeyOwner> = []
    /// Ce que répond la sonde des modificateurs ; `probes` garde chaque question posée (les modificateurs demandés).
    var modifiersHeld = true
    var probes: [Modifiers] = []
    /// Ce que répond la sonde d'Échap ; `escapeProbes` compte les questions posées.
    var escapeHeld = false
    var escapeProbes = 0
    /// Les modes dont le réglage « relire avant de coller » est actif, et chaque lecture que le contrôleur en a faite.
    var reviewing: Set<String> = []
    var reviewReads: [String] = []
    /// Le déroulé de chaque mode (`ModeRun.legacy` pour un mode absent), et chaque lecture que le contrôleur en a faite.
    var modeRuns: [String: ModeRun] = [:]
    var modeReads: [String] = []
    /// L'application au premier plan que répond le lecteur (`nil` : il ne sait pas dire), et chaque lecture.
    var front: Int32? = 100
    var frontReads = 0
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
    let rewriter = FakeRewriter()
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
        let rewriter = rewriter
        controller = DictationController(
            environment: engines.environment, inserter: rig.inserter,
            settings: { knobs.settings }, behavior: { knobs.behavior }, modeID: { knobs.modeID },
            microphoneAllowed: { knobs.microphoneAllowed }, panel: panel,
            hotKeyModifiers: { knobs.hotKeyModifiers },
            modeHotKeyModifiers: { mode in
                knobs.modeModifierReads.append(mode)
                return knobs.modeModifiers[mode] ?? []
            },
            selectMode: { mode in
                knobs.selectedModes.append(mode)
                knobs.modeID = mode
            },
            ownerIsBound: { !knobs.unbound.contains($0) },
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
            modes: { mode in
                knobs.modeReads.append(mode)
                return knobs.modeRuns[mode] ?? ModeRun.legacy(mode)
            },
            rewriter: rewriter.environment,
            frontApplication: {
                knobs.frontReads += 1
                return knobs.front
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

    /// Appui sur le raccourci de ce mode, puis la session est menée jusqu'à `recording`.
    @discardableResult
    func startModeRecording(_ modeID: String, index: Int = 0) async -> FakeSession {
        controller.modeHotKeyPressed(modeID)
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
        case .idle, .preparing, .recording, .finalizing, .formatting, .review, .pasting: false
        }
    }
}
