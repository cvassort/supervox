import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

// Doubles de l'entretien : aucun micro, aucun son, aucune voix du système, aucun réseau, aucun vrai trousseau.

/// Un journal commun à plusieurs doubles, lisible de n'importe quel fil : l'ordre de ce qui s'est passé entre eux.
final class Journal: Sendable {
    private let state = Mutex<[String]>([])
    func append(_ entry: String) { state.withLock { $0.append(entry) } }
    var entries: [String] { state.withLock { $0 } }
    /// La place de la première entrée qui vaut `entry`, `nil` si elle n'y est pas.
    func index(of entry: String) -> Int? { entries.firstIndex(of: entry) }
}

/// Le pilote d'une conversation double : ce que le test garde pour émettre les événements et lire les compteurs, sans tenir la
/// conversation elle-même (le test vérifie par une référence faible qu'elle est libérée à la fin).
final class ConversationDriver: Sendable {
    private struct State {
        var starts = 0
        var startReturned = false
        var concludes = 0
        var ignoredConcludes = 0
        var cancels = 0
        var ignoredCancels = 0
        var finished = false
        var startGate: TestGate?
        var cancelGate: TestGate?
        var finishOnCancel = true
        /// Retient la fin du flux (après `.finished`) tant que la porte n'est pas ouverte.
        var streamEndGate: TestGate?
    }

    let journal: Journal
    let events: AsyncStream<ConversationEvent>
    private let sink: AsyncStream<ConversationEvent>.Continuation
    private let state = Mutex(State())

    init(journal: Journal) {
        self.journal = journal
        (events, sink) = AsyncStream<ConversationEvent>.makeStream()
    }

    var starts: Int { state.withLock { $0.starts } }
    /// Les conclusions prises en compte (après le retour de `start()`).
    var concludes: Int { state.withLock { $0.concludes } }
    /// Les conclusions reçues avant le retour de `start()` : ignorées, comme le vrai moteur.
    var ignoredConcludes: Int { state.withLock { $0.ignoredConcludes } }
    /// Les annulations prises en compte (après le retour de `start()`).
    var cancels: Int { state.withLock { $0.cancels } }
    /// Les annulations reçues avant le retour de `start()` : ignorées, comme le vrai moteur (`cancel()` sans effet avant `start()`).
    var ignoredCancels: Int { state.withLock { $0.ignoredCancels } }
    var isFinished: Bool { state.withLock { $0.finished } }

    func configure(
        startGate: TestGate? = nil, cancelGate: TestGate? = nil, finishOnCancel: Bool = true, streamEndGate: TestGate? = nil
    ) {
        state.withLock {
            $0.startGate = startGate
            $0.cancelGate = cancelGate
            $0.finishOnCancel = finishOnCancel
            $0.streamEndGate = streamEndGate
        }
    }

    func emit(_ event: ConversationEvent) { sink.yield(event) }

    /// La fin, comme le vrai moteur : le micro est rendu (« audio arrêté » au journal), puis `.state(.finished)`, puis `.finished`,
    /// puis le flux se termine (« flux terminé » ; retenu par `streamEndGate` s'il y en a une). Une seule fois.
    func finish(_ end: ConversationEnd) {
        let (first, gate) = state.withLock { state -> (Bool, TestGate?) in
            defer { state.finished = true }
            return (!state.finished, state.streamEndGate)
        }
        guard first else { return }
        journal.append("audio arrêté")
        sink.yield(.state(.finished))
        sink.yield(.finished(end))
        guard let gate else { return endStream() }
        Task {
            await gate.wait()
            self.endStream()
        }
    }

    private func endStream() {
        journal.append("flux terminé")
        sink.finish()
    }

    fileprivate func started() async {
        let gate = state.withLock { state -> TestGate? in
            state.starts += 1
            return state.startGate
        }
        journal.append("conversation démarrée")
        await gate?.wait()
        state.withLock { $0.startReturned = true }
    }

    fileprivate func concluded() {
        let accepted = state.withLock { state -> Bool in
            guard state.startReturned else {
                state.ignoredConcludes += 1
                return false
            }
            state.concludes += 1
            return true
        }
        journal.append(accepted ? "conclusion demandée" : "conclusion ignorée")
    }

    fileprivate func cancelled() async {
        let accepted = state.withLock { state -> (gate: TestGate?, finishes: Bool)? in
            guard state.startReturned else {
                state.ignoredCancels += 1
                return nil
            }
            state.cancels += 1
            return (state.cancelGate, state.finishOnCancel)
        }
        guard let (gate, finishes) = accepted else {
            journal.append("annulation ignorée")
            return
        }
        journal.append("annulation demandée")
        await gate?.wait()
        if finishes { finish(.cancelled) }
    }
}

/// La conversation double que l'environnement fabrique : chaque appel passe au pilote. Elle ne garde que lui.
final class FakeConversation: ConversationEngine {
    let driver: ConversationDriver
    init(driver: ConversationDriver) { self.driver = driver }

    func start() async -> AsyncStream<ConversationEvent> {
        await driver.started()
        return driver.events
    }
    func conclude() async { driver.concluded() }
    func cancel() async { await driver.cancelled() }
}

/// L'historique double : garde chaque entretien enregistré ; peut lever, ou retenir l'enregistrement jusqu'à une porte.
final class FakeInterviewHistory: InterviewHistoryStoring {
    private struct State {
        var saved: [InterviewRecord] = []
        var attempts = 0
        var gate: TestGate?
        var fails = false
    }
    private let state = Mutex(State())

    var saved: [InterviewRecord] { state.withLock { $0.saved } }
    var attempts: Int { state.withLock { $0.attempts } }
    func configure(gate: TestGate? = nil, fails: Bool = false) {
        state.withLock {
            $0.gate = gate
            $0.fails = fails
        }
    }

    struct Refused: Error {}

    func save(_ entry: InterviewRecord) async throws {
        let (gate, fails) = state.withLock { state -> (TestGate?, Bool) in
            state.attempts += 1
            return (state.gate, state.fails)
        }
        await gate?.wait()
        if fails { throw Refused() }
        state.withLock { $0.saved.append(entry) }
    }
}

/// Une voix double qui ne dit rien (jamais appelée : la conversation est un double).
struct SilentTestVoice: SpeechSynthesizer {
    func synthesize(_ text: String) async throws -> Speech { throw SpeechError.empty }
}

/// L'environnement double : chaque préparation et chaque fabrication est comptée et notée au journal, peut être retenue par une
/// porte ou lever. Chaque conversation fabriquée est neuve ; le banc garde son pilote et une référence faible sur elle.
final class FakeInterviewEnvironment: Sendable {
    private final class WeakConversation: @unchecked Sendable {
        weak var value: FakeConversation?
    }
    private struct State {
        var prepared: [InterviewSetup] = []
        var made: [InterviewSetup] = []
        var drivers: [ConversationDriver] = []
        var conversations: [WeakConversation] = []
        var prepareGate: TestGate?
        var makeGate: TestGate?
        var prepareError: (any Error)?
        var makeError: (any Error)?
        /// La porte que chaque nouvelle conversation donne à son `start()`.
        var startGate: TestGate?
        /// La tâche qui fabriquait la conversation était annulée quand la fabrication a repris.
        var makeSawCancellation = false
        /// Ce que la préparation rend (vocabulaire ajusté, avis) ; `nil` : la configuration reçue, sans avis.
        var preparation: (@Sendable (InterviewSetup) -> InterviewPreparation)?
    }

    let journal: Journal
    private let state = Mutex(State())

    init(journal: Journal) { self.journal = journal }

    var prepareCount: Int { state.withLock { $0.prepared.count } }
    var makeCount: Int { state.withLock { $0.made.count } }
    var preparedSetups: [InterviewSetup] { state.withLock { $0.prepared } }
    var madeSetups: [InterviewSetup] { state.withLock { $0.made } }
    var drivers: [ConversationDriver] { state.withLock { $0.drivers } }
    var makeSawCancellation: Bool { state.withLock { $0.makeSawCancellation } }

    /// La conversation numéro `index` vit-elle encore ?
    func conversationIsAlive(_ index: Int) -> Bool {
        state.withLock { $0.conversations.indices.contains(index) && $0.conversations[index].value != nil }
    }

    func configure(_ change: @Sendable (inout PrepareKnobs) -> Void) {
        state.withLock { state in
            var knobs = PrepareKnobs(
                prepareGate: state.prepareGate, makeGate: state.makeGate, prepareError: state.prepareError,
                makeError: state.makeError, startGate: state.startGate, preparation: state.preparation)
            change(&knobs)
            state.preparation = knobs.preparation
            state.startGate = knobs.startGate
            state.prepareGate = knobs.prepareGate
            state.makeGate = knobs.makeGate
            state.prepareError = knobs.prepareError
            state.makeError = knobs.makeError
        }
    }

    struct PrepareKnobs {
        var prepareGate: TestGate?
        var makeGate: TestGate?
        var prepareError: (any Error)?
        var makeError: (any Error)?
        var startGate: TestGate?
        var preparation: (@Sendable (InterviewSetup) -> InterviewPreparation)?
    }

    var environment: InterviewEnvironment {
        InterviewEnvironment(
            prepare: { [self] setup in
                let (gate, error, preparation) = state.withLock {
                    state -> (TestGate?, (any Error)?, (@Sendable (InterviewSetup) -> InterviewPreparation)?) in
                    state.prepared.append(setup)
                    return (state.prepareGate, state.prepareError, state.preparation)
                }
                journal.append("préparation")
                await gate?.wait()
                if let error { throw error }
                return preparation?(setup) ?? InterviewPreparation(setup: setup)
            },
            makeConversation: { [self] setup in
                let (gate, error, startGate) = state.withLock { state -> (TestGate?, (any Error)?, TestGate?) in
                    state.made.append(setup)
                    return (state.makeGate, state.makeError, state.startGate)
                }
                journal.append("fabrication")
                await gate?.wait()
                let cancelled = Task.isCancelled
                state.withLock { $0.makeSawCancellation = cancelled }
                if let error { throw error }
                let driver = ConversationDriver(journal: journal)
                driver.configure(startGate: startGate)
                let conversation = FakeConversation(driver: driver)
                let weak = WeakConversation()
                weak.value = conversation
                state.withLock {
                    $0.drivers.append(driver)
                    $0.conversations.append(weak)
                }
                return conversation
            },
            makeVoice: { _, _ in SilentTestVoice() })
    }
}

/// Le contrôleur de l'entretien et ses doubles : vrai `PanelModel`, vraie résolution (`InterviewSetup.resolve`) sur un trousseau en
/// mémoire et des modèles doubles, environnement, conversation et historique doubles.
extension InterviewController {
    /// La FIN OBSERVÉE d'un entretien, au lieu d'une durée fixe : la lecture du flux de la conversation est finie (son micro est rendu,
    /// tout ce qu'elle devait faire de ses événements est fait) et toute écriture de l'historique lancée est finie. Après cela,
    /// « rien n'a été enregistré » est un fait, pas un instant où rien n'était encore arrivé. Borné (`bounded`) : rend `false` si
    /// l'attente ne finit pas, le test échoue au lieu de se suspendre.
    func drained() async -> Bool {
        let task = Task { @MainActor in
            await self.waitUntilStopped()
            await self.waitForSaves()
        }
        return await bounded(task) != nil
    }
}

/// Les minuteries de l'attente de l'enregistrement de l'historique : aucune ne rend d'elle-même, le test les déclenche (`fire`). Une
/// minuterie que le contrôleur annule (l'enregistrement a fini à temps) rend la main par une erreur d'annulation, sans délai écoulé.
final class SaveTimers: Sendable {
    private let gates = Mutex<[TestGate]>([])
    /// Combien de minuteries ont été lancées.
    var started: Int { gates.withLock { $0.count } }

    func wait() async throws {
        let gate = TestGate()
        gates.withLock { $0.append(gate) }
        try await withTaskCancellationHandler {
            await gate.wait()
            try Task.checkCancellation()
        } onCancel: {
            gate.open()
        }
    }

    /// Le délai est écoulé pour toutes les minuteries en cours.
    func fire() {
        for gate in gates.withLock({ $0 }) { gate.open() }
    }
}

@MainActor final class InterviewRig {
    static let provider = Provider(
        id: UUID(), name: "Fournisseur d'exemple", baseURL: "https://example.com/v1", kind: .openAICompatible,
        models: ["modele-exemple-rapide", "modele-exemple-fort"])

    /// Des réglages qui permettent l'entretien : un fournisseur avec sa clé, un modèle rapide et un modèle fort.
    static func readySettings() -> AppSettings {
        var settings = AppSettings.defaults
        settings.providers = [provider]
        settings.fastModel = ModelChoice(providerID: provider.id, model: "modele-exemple-rapide")
        settings.strongModel = ModelChoice(providerID: provider.id, model: "modele-exemple-fort")
        settings.interview.maxQuestions = 6
        return settings
    }

    let panel: PanelModel
    let journal = Journal()
    let environment: FakeInterviewEnvironment
    let history = FakeInterviewHistory()
    let timers = SaveTimers()
    let secrets = InMemorySecretStore()
    var settings = InterviewRig.readySettings()
    var behavior = HotKeyBehavior.toggle
    /// Retient la résolution (avant la lecture du trousseau) tant que la porte n'est pas ouverte.
    var resolveGate: TestGate?
    private(set) var resolveCount = 0
    /// Les dates données à l'historique.
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let controller: InterviewController
    private(set) var outcomes: [InterviewOutcome] = []

    init(panel: PanelModel = PanelModel(lastModeID: ModeChip.interviewID)) {
        self.panel = panel
        let journal = journal
        environment = FakeInterviewEnvironment(journal: journal)
        try? secrets.write("cle-exemple", account: Self.provider.id.uuidString)
        let fakeEnvironment = environment
        let secrets = secrets
        let date = date
        let timers = timers
        // Construit en deux temps : la résolution relit `self` (porte, compte), qui n'existe pas encore.
        let relay = RigRelay()
        controller = InterviewController(
            environment: fakeEnvironment.environment, settings: { relay.rig?.settings ?? .defaults },
            behavior: { relay.rig?.behavior ?? .toggle },
            resolve: { settings, engine in
                await relay.rig?.resolveStarted()
                return try await InterviewSetup.resolve(
                    settings: settings, engine: engine,
                    secrets: SecretAccess(secrets, queue: DispatchQueue(label: "test.interview.\(UUID())")),
                    makeModel: { _, _ in ScriptedModel(.never) }, makeVoice: fakeEnvironment.environment.makeVoice)
            },
            history: history, panel: panel, now: { date }, saveWait: { _ in try await timers.wait() }, beforeMicrophone: {})
        relay.rig = self
        panel.onConclude = { [controller] in controller.conclude() }
    }

    private func resolveStarted() async {
        resolveCount += 1
        journal.append("résolution")
        await resolveGate?.wait()
    }

    /// Lance un entretien ; l'issue est gardée dans `outcomes`.
    func start(engine: TranscriptionEngine? = nil) {
        controller.start(engine: engine) { [weak self] in self?.outcomes.append($0) }
    }

    /// Le pilote de la conversation numéro `index`, attendu jusqu'à ce que le contrôleur l'ait démarrée.
    func driver(_ index: Int = 0) async throws -> ConversationDriver {
        let found = await until { self.environment.drivers.count > index && self.environment.drivers[index].starts > 0 }
        try #require(found, "aucune conversation démarrée")
        return environment.drivers[index]
    }

    /// Lancé, la conversation démarrée et à l'écoute.
    func listening() async throws -> ConversationDriver {
        start()
        let driver = try await driver()
        driver.emit(.state(.listening))
        try #require(await until { self.panel.interview?.phase == .listening })
        return driver
    }

    /// Un tour de la personne : la conversation en relecture en aura un.
    static func conversation(_ turns: [(ConversationTurn.Speaker, String)]) -> Conversation {
        var conversation = Conversation()
        for (speaker, text) in turns {
            switch speaker {
            case .user: conversation.appendUser(text)
            case .interviewer: conversation.appendInterviewer(text)
            }
        }
        return conversation
    }
}

@MainActor private final class RigRelay {
    weak var rig: InterviewRig?
}
