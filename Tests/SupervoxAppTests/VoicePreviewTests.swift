import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

// L'écoute d'une voix (réglage des voix, tâche 3). Aucun son, aucune vraie voix, aucune vraie liste des voix : le lecteur est
// `ScriptedClipPlayer`, les voix sont des doubles, la liste des voix installées est inventée, le trousseau est en mémoire.

/// Ce que l'environnement donne quand personne ne branche l'écoute : aucune voix listée, un lecteur qui refuse de jouer.
@MainActor @Suite(.timeLimit(.minutes(1))) struct VoiceEnvironmentDefaultsTests {
    static let clip = AudioClip(samples: [0.1, 0.2], sampleRate: 24_000)

    @Test func theUnavailableEnvironmentListsNoVoiceAndItsPlayerRefusesToPlay() async {
        let environment = InterviewEnvironment.unavailable
        #expect(environment.systemVoices().isEmpty)
        let player = environment.makePlayer()
        await #expect(throws: InterviewEnvironment.Unavailable.self) { try await player.play(Self.clip) }
    }

    @Test func anEnvironmentBuiltWithoutThemListsNoVoiceAndItsPlayerRefusesToPlay() async {
        let environment = InterviewEnvironment(
            prepare: { _ in throw InterviewEnvironment.Unavailable() },
            makeConversation: { _ in throw InterviewEnvironment.Unavailable() }, makeVoice: { _, _ in SilentTestVoice() })
        #expect(environment.systemVoices().isEmpty)
        let player = environment.makePlayer()
        await #expect(throws: InterviewEnvironment.Unavailable.self) { try await player.play(Self.clip) }
    }

    @Test func theEnvironmentGivesTheListAndThePlayerItWasBuiltWith() {
        let voice = SystemVoiceInfo(identifier: "voix.exemple.a", language: "fr-FR", quality: 2, name: "Voix d'exemple A")
        let player = ScriptedClipPlayer()
        let environment = InterviewEnvironment(
            prepare: { _ in throw InterviewEnvironment.Unavailable() },
            makeConversation: { _ in throw InterviewEnvironment.Unavailable() }, makeVoice: { _, _ in SilentTestVoice() },
            systemVoices: { [voice] }, makePlayer: { player })
        #expect(environment.systemVoices() == [voice])
        #expect((environment.makePlayer() as? ScriptedClipPlayer) === player)
    }
}

// MARK: - Doubles de l'écoute

/// Une voix double. `clip` : rend ce clip ; `error` : lève cette erreur ; `held` : attend la porte (sans écouter l'annulation, comme
/// un fournisseur lent) puis rend le clip, et note si sa tâche était annulée à ce moment ; `hang` : ne rend la main qu'à
/// l'annulation ; `forbidden` : ne doit jamais être appelée (la voix du système quand c'est un fournisseur qui parle).
final class PreviewVoice: SpeechSynthesizer {
    enum Behavior: @unchecked Sendable {
        case clip(AudioClip)
        case error(any Error)
        case held(TestGate, AudioClip)
        case hang
        case forbidden
    }
    private struct State {
        var texts: [String] = []
        var sawCancellation = false
    }
    private let behavior: Behavior
    private let state = Mutex(State())

    init(_ behavior: Behavior) { self.behavior = behavior }

    /// Les textes reçus, dans l'ordre.
    var texts: [String] { state.withLock { $0.texts } }
    /// La tâche de la synthèse était annulée quand la réponse tardive est arrivée (`held`).
    var sawCancellation: Bool { state.withLock { $0.sawCancellation } }

    func synthesize(_ text: String) async throws -> Speech {
        state.withLock { $0.texts.append(text) }
        switch behavior {
        case .clip(let clip):
            return Speech(clip: clip)
        case .error(let error):
            throw error
        case .held(let gate, let clip):
            await gate.wait()
            let cancelled = Task.isCancelled
            state.withLock { $0.sawCancellation = cancelled }
            return Speech(clip: clip)
        case .hang:
            let gate = TestGate()
            await withTaskCancellationHandler { await gate.wait() } onCancel: { gate.open() }
            throw CancellationError()
        case .forbidden:
            Issue.record("la voix du système a été sollicitée")
            throw SpeechError.empty
        }
    }
}

/// La fabrique de voix double : garde chaque fabrication (le choix reçu, le nom du fournisseur ou `nil`), rend la voix « système »
/// sans fournisseur et la voix « fournisseur » avec.
final class PreviewVoiceFactory: Sendable {
    let system: PreviewVoice
    let provider: PreviewVoice
    private let made = Mutex<[(choice: VoiceChoice, provider: String?)]>([])

    init(system: PreviewVoice, provider: PreviewVoice = PreviewVoice(.forbidden)) {
        self.system = system
        self.provider = provider
    }

    var calls: [(choice: VoiceChoice, provider: String?)] { made.withLock { $0 } }
    /// Les fabrications sans fournisseur : la voix du système.
    var systemCalls: Int { calls.filter { $0.provider == nil }.count }

    func make(_ choice: VoiceChoice, _ resolved: ResolvedProvider?) -> any SpeechSynthesizer {
        made.withLock { $0.append((choice, resolved?.name)) }
        return resolved == nil ? system : provider
    }
}

/// La borne de la synthèse : aucune attente ne rend d'elle-même ; `fire()` déclare le délai écoulé, l'annulation fait lever.
final class PreviewClock: Sendable {
    private let state = Mutex<(asked: [Double], gates: [TestGate])>(([], []))
    var asked: [Double] { state.withLock { $0.asked } }

    func sleep(_ seconds: Double) async throws {
        let gate = TestGate()
        state.withLock {
            $0.asked.append(seconds)
            $0.gates.append(gate)
        }
        await withTaskCancellationHandler { await gate.wait() } onCancel: { gate.open() }
        try Task.checkCancellation()
    }

    func fire() {
        for gate in state.withLock({ $0.gates }) { gate.open() }
    }
}

/// Le nombre de lecteurs fabriqués.
final class PlayerCount: Sendable {
    let value = Mutex(0)
}

/// Les états publiés par une écoute, dans l'ordre.
@MainActor final class PreviewStates {
    var states: [VoicePreview.State] = []
    func record(_ state: VoicePreview.State) { states.append(state) }
}

// MARK: - L'écoute

@MainActor @Suite(.timeLimit(.minutes(1))) struct VoicePreviewTests {
    static let clip = AudioClip(samples: [0.1, 0.2, 0.3], sampleRate: 24_000)
    static let provider = Provider(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!, name: "Fournisseur d'exemple",
        baseURL: "https://example.com/v1", kind: .openAICompatible, models: ["modele-voix-exemple"])
    static let silentProvider = Provider(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!, name: "Fournisseur sans voix",
        baseURL: "https://example.com/v2", kind: .anthropic, models: [])

    static let systemChoice = VoiceChoice(language: "fr-FR")
    static let providerChoice = VoiceChoice(
        providerID: provider.id, model: "modele-voix-exemple", identifier: "voix-exemple", language: "fr-FR",
        extra: ["cle-exemple": "valeur-exemple"])

    static func settings() -> AppSettings {
        var settings = AppSettings.defaults
        settings.providers = [provider, silentProvider]
        return settings
    }

    /// L'écoute et ses doubles. `resolve` : la VRAIE résolution (`VoiceChoice.resolve(in:secrets:)`) sur un trousseau en mémoire,
    /// sauf quand un test la remplace.
    @MainActor final class Rig {
        let factory: PreviewVoiceFactory
        let player: ScriptedClipPlayer
        let clock = PreviewClock()
        let keys: InMemorySecretStore
        let states = PreviewStates()
        private let madePlayers = PlayerCount()
        let preview: VoicePreview

        var playersMade: Int { madePlayers.value.withLock { $0 } }

        init(
            factory: PreviewVoiceFactory, player: ScriptedClipPlayer = ScriptedClipPlayer(completion: .immediate),
            makePlayer: (@Sendable () -> any ClipPlayer)? = nil, withKey: Bool = true,
            resolve: VoicePreview.Resolve? = nil
        ) {
            self.factory = factory
            self.player = player
            keys = withKey
                ? InMemorySecretStore(secrets: [VoicePreviewTests.provider.id.uuidString: "cle-exemple"]) : InMemorySecretStore()
            let access = SecretAccess(keys, queue: DispatchQueue(label: "test.voice.preview.\(UUID())"))
            let counter = madePlayers
            let clock = clock
            preview = VoicePreview(
                makeVoice: { factory.make($0, $1) },
                makePlayer: makePlayer ?? { [player] in
                    counter.value.withLock { $0 += 1 }
                    return player
                },
                resolve: resolve ?? { choice, settings in try await choice.resolve(in: settings, secrets: access) },
                sleep: { try await clock.sleep($0) })
        }

        func start(_ choice: VoiceChoice, settings: AppSettings = VoicePreviewTests.settings()) {
            preview.start(choice, settings: settings, onState: { [states] in states.record($0) })
        }

        /// L'écoute est finie (dernier état `.idle` ou `.failed`, après `.preparing`).
        func ended() async -> Bool {
            await until {
                guard states.states.count > 1, let last = states.states.last else { return false }
                switch last {
                case .idle, .failed: return true
                case .preparing, .playing: return false
                }
            }
        }
    }

    // MARK: Règle 7 : voix du système

    @Test func aSystemVoiceIsMadeWithoutProviderSaysTheSamplePhraseAndPlaysIt() async {
        let rig = Rig(factory: PreviewVoiceFactory(system: PreviewVoice(.clip(Self.clip))))
        rig.start(Self.systemChoice)
        #expect(await rig.ended())
        #expect(rig.states.states == [.preparing, .playing, .idle])
        #expect(rig.factory.calls.count == 1)
        #expect(rig.factory.calls.first?.provider == nil)
        #expect(rig.factory.calls.first?.choice == Self.systemChoice.normalized)
        #expect(rig.factory.system.texts == [VoicesText.samplePhrase(for: "fr-FR")])
        #expect(rig.player.clips == [Self.clip])
        #expect(rig.keys.readCount == 0, "une voix du système ne lit pas le trousseau")
    }

    @Test func aDesignatedSystemVoiceIsMadeWithItsIdentifier() async {
        let rig = Rig(factory: PreviewVoiceFactory(system: PreviewVoice(.clip(Self.clip))))
        let designated = VoiceChoice(identifier: " voix.exemple.a ", language: "en-US")
        rig.start(designated)
        #expect(await rig.ended())
        #expect(rig.factory.calls.first?.choice.identifier == "voix.exemple.a")
        #expect(rig.factory.system.texts == [VoicesText.samplePhrase(for: "en-US")])
    }

    // MARK: Règle 8 : voix de fournisseur

    @Test func aProviderVoiceIsResolvedThenMadeWithItsProviderAndPlays() async {
        let factory = PreviewVoiceFactory(system: PreviewVoice(.forbidden), provider: PreviewVoice(.clip(Self.clip)))
        let rig = Rig(factory: factory)
        rig.start(Self.providerChoice)
        #expect(await rig.ended())
        #expect(rig.states.states == [.preparing, .playing, .idle])
        #expect(factory.calls.map(\.provider) == [Self.provider.name])
        #expect(factory.calls.first?.choice == Self.providerChoice.normalized)
        #expect(factory.provider.texts == [VoicesText.samplePhrase(for: "fr-FR")])
        #expect(rig.keys.readCount == 1, "la clé est lue, une fois")
        #expect(rig.player.clips == [Self.clip])
        #expect(rig.clock.asked == [VoicePreview.limitSeconds], "la synthèse est bornée par limitSeconds")
    }

    /// Un fournisseur qui échoue : la panne du fournisseur est dite ; la voix du système n'est ni fabriquée ni appelée, rien n'est
    /// joué (aucun repli).
    @Test func aFailingProviderVoiceNeverSpeaksWithTheSystemVoice() async {
        let factory = PreviewVoiceFactory(
            system: PreviewVoice(.forbidden),
            provider: PreviewVoice(.error(EndpointError.http(status: 503, body: "corps"))))
        let rig = Rig(factory: factory)
        rig.start(Self.providerChoice)
        #expect(await rig.ended())
        #expect(rig.states.states.last == .failed(.provider(.server(503))))
        #expect(factory.systemCalls == 0, "la voix du système n'est jamais fabriquée")
        #expect(factory.system.texts.isEmpty, "la voix du système n'est jamais appelée")
        #expect(rig.player.clips.isEmpty)
    }

    /// Le lecteur est fabriqué une fois et gardé : un second `play` sur le même arrête le premier (contrat de `ClipPlayer`), et
    /// `stopNow()` vise la lecture en cours.
    @Test func thePlayerIsMadeOnceAndKept() async {
        let rig = Rig(factory: PreviewVoiceFactory(system: PreviewVoice(.clip(Self.clip))))
        rig.start(Self.systemChoice)
        #expect(await rig.ended())
        rig.states.states = []
        rig.start(Self.systemChoice)
        #expect(await rig.ended())
        #expect(rig.playersMade == 1)
        #expect(rig.player.clips.count == 2)
    }

    // MARK: Table des pannes (amendement 1)

    enum FailureCase: String, CaseIterable, CustomTestStringConvertible {
        case systemNoVoice, systemEmptyError, systemZeroSamples, systemTimedOutError, systemDeadline, systemOtherError
        case providerRemoved, providerCannotSpeak, providerIncomplete
        case resolveNoKey, providerHTTP, providerUnreadableBytes, providerEmptyError, providerZeroSamples, providerDeadline
        case playbackFailed, voiceUnavailable, playerUnavailable
        var testDescription: String { rawValue }
    }

    struct Other: Error {}

    /// Une ligne de la table : la voix choisie, les doubles, et la panne attendue.
    static func scenario(_ c: FailureCase) -> (
        choice: VoiceChoice, factory: PreviewVoiceFactory, player: ScriptedClipPlayer?, withKey: Bool,
        fireDeadline: Bool, expected: VoicePreview.Failure
    ) {
        let silent = AudioClip(samples: [], sampleRate: 24_000)
        func system(_ b: PreviewVoice.Behavior) -> PreviewVoiceFactory { PreviewVoiceFactory(system: PreviewVoice(b)) }
        func provider(_ b: PreviewVoice.Behavior) -> PreviewVoiceFactory {
            PreviewVoiceFactory(system: PreviewVoice(.forbidden), provider: PreviewVoice(b))
        }
        var removed = providerChoice
        removed.providerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000c9")
        var cannotSpeak = providerChoice
        cannotSpeak.providerID = silentProvider.id
        var incomplete = providerChoice
        incomplete.identifier = "  "
        switch c {
        case .systemNoVoice:
            return (systemChoice, system(.error(SpeechError.noVoice(language: "fr-FR"))), nil, true, false, .notInstalled)
        case .systemEmptyError: return (systemChoice, system(.error(SpeechError.empty)), nil, true, false, .silent)
        case .systemZeroSamples: return (systemChoice, system(.clip(silent)), nil, true, false, .silent)
        case .systemTimedOutError: return (systemChoice, system(.error(SpeechError.timedOut)), nil, true, false, .timedOut)
        case .systemDeadline: return (systemChoice, system(.hang), nil, true, true, .timedOut)
        case .systemOtherError: return (systemChoice, system(.error(Other())), nil, true, false, .unavailable)
        case .providerRemoved: return (removed, provider(.forbidden), nil, true, false, .unusable(.providerRemoved))
        case .providerCannotSpeak:
            return (cannotSpeak, provider(.forbidden), nil, true, false, .unusable(.providerCannotSpeak))
        case .providerIncomplete: return (incomplete, provider(.forbidden), nil, true, false, .unusable(.incomplete))
        case .resolveNoKey:
            return (providerChoice, provider(.forbidden), nil, false, false, .provider(.noKey(provider: Self.provider.name)))
        case .providerHTTP:
            return (
                providerChoice, provider(.error(EndpointError.http(status: 401, body: "corps"))), nil, true, false,
                .provider(.unauthorized(401))
            )
        case .providerUnreadableBytes:
            return (providerChoice, provider(.error(WavFileError.notAWavFile)), nil, true, false, .provider(.malformed))
        case .providerEmptyError: return (providerChoice, provider(.error(SpeechError.empty)), nil, true, false, .silent)
        case .providerZeroSamples: return (providerChoice, provider(.clip(silent)), nil, true, false, .silent)
        case .providerDeadline: return (providerChoice, provider(.hang), nil, true, true, .timedOut)
        case .playbackFailed:
            return (systemChoice, system(.clip(clip)), ScriptedClipPlayer(completion: .failing), true, false, .playback)
        case .voiceUnavailable:
            return (systemChoice, system(.error(InterviewEnvironment.Unavailable())), nil, true, false, .unavailable)
        case .playerUnavailable: return (systemChoice, system(.clip(clip)), nil, true, false, .unavailable)
        }
    }

    /// Chaque ligne de la table des pannes : l'écoute finit sur sa panne, sans second classement, et la phrase montrée est celle de
    /// `VoicesText` (pour `.provider(f)`, `f.message`). Une voix inutilisable n'est jamais fabriquée ; aucune voix du système ne parle
    /// à la place d'un fournisseur ; rien n'est joué sauf par la ligne de lecture.
    @Test(arguments: FailureCase.allCases)
    func everyPreviewFailureHasItsSentence(_ c: FailureCase) async {
        let s = Self.scenario(c)
        let player = s.player ?? ScriptedClipPlayer(completion: .immediate)
        let rig = Rig(
            factory: s.factory, player: player,
            makePlayer: c == .playerUnavailable ? InterviewEnvironment.noPlayer : nil, withKey: s.withKey)
        rig.start(s.choice)
        if s.fireDeadline {
            #expect(await until { rig.clock.asked.count == 1 })
            rig.clock.fire()
        }
        #expect(await rig.ended())
        #expect(rig.states.states.last == .failed(s.expected), "\(rig.states.states)")
        let sentence = VoicesText.failure(s.expected)
        #expect(!sentence.isEmpty)
        if case .provider(let failure) = s.expected { #expect(sentence == failure.message) }
        if case .unusable(let reason) = s.expected {
            #expect(sentence == VoicesText.reason(reason))
            #expect(s.factory.calls.isEmpty, "une voix inutilisable n'est jamais fabriquée")
        }
        if s.choice.providerID != nil { #expect(s.factory.systemCalls == 0, "jamais la voix du système à la place") }
        if c != .playbackFailed { #expect(player.clips.isEmpty, "rien n'est joué") }
    }

    /// Les phrases des pannes : fixes, en français, distinctes d'un cas à l'autre.
    @Test func theFailureSentencesAreFixedAndDistinct() {
        let failures: [VoicePreview.Failure] = [
            .notInstalled, .unusable(.providerRemoved), .unusable(.providerCannotSpeak), .unusable(.incomplete),
            .provider(.noKey(provider: "Fournisseur d'exemple")), .silent, .timedOut, .playback, .unavailable,
        ]
        let sentences = failures.map(VoicesText.failure)
        #expect(Set(sentences).count == failures.count)
        #expect(sentences.allSatisfy { $0.hasSuffix(".") && !$0.contains("Error") })
        #expect(VoicesText.failure(.timedOut).contains("15"), "la borne dite est celle de limitSeconds")
    }

    // MARK: Règle 9 : arrêt

    /// La synthèse rend sa réponse APRÈS `stop()` : rien n'est joué, l'état reste `.idle`, et la synthèse a vu l'annulation (c'est
    /// l'annulation, pas seulement le jeton, qui l'arrête).
    @Test func stopSilencesALateSynthesis() async {
        let gate = TestGate()
        defer { gate.open() }
        let voice = PreviewVoice(.held(gate, Self.clip))
        let rig = Rig(factory: PreviewVoiceFactory(system: voice))
        rig.start(Self.systemChoice)
        #expect(await until { voice.texts.count == 1 })
        rig.preview.stop()
        #expect(rig.states.states == [.preparing, .idle])
        gate.open()
        #expect(await until { voice.sawCancellation })
        await settle()
        #expect(rig.player.clips.isEmpty, "rien n'est joué après stop()")
        #expect(rig.states.states == [.preparing, .idle], "aucun état après stop()")
    }

    /// Pendant la lecture : `stop()` annule la tâche (le lecteur compte l'arrêt de SA lecture) puis appelle `stopNow()` ; l'état
    /// revient à `.idle`, et plus rien n'arrive ensuite.
    @Test func stopDuringPlaybackCancelsThenStopsNow() async {
        let player = ScriptedClipPlayer(completion: .manual)
        let rig = Rig(factory: PreviewVoiceFactory(system: PreviewVoice(.clip(Self.clip))), player: player)
        rig.start(Self.systemChoice)
        #expect(await until { player.isPlaying })
        #expect(rig.states.states == [.preparing, .playing])
        rig.preview.stop()
        #expect(player.stopNowCount == 1, "stopNow() : l'arrêt est fait avant le retour")
        #expect(!player.isPlaying)
        #expect(await until { player.stopCount == 1 }, "l'annulation de la tâche arrête sa lecture")
        await settle()
        #expect(rig.states.states == [.preparing, .playing, .idle])
    }

    /// Un second `start` pendant la préparation du premier : le premier ne joue jamais et ne publie plus rien après son `.idle`.
    @Test func aSecondStartStopsTheFirst() async {
        let gate = TestGate()
        defer { gate.open() }
        let first = PreviewStates()
        let second = PreviewStates()
        let slow = PreviewVoice(.held(gate, AudioClip(samples: [0.9], sampleRate: 24_000)))
        let factory = PreviewVoiceFactory(system: slow, provider: PreviewVoice(.clip(Self.clip)))
        let rig = Rig(factory: factory)
        rig.preview.start(Self.systemChoice, settings: Self.settings(), onState: { first.record($0) })
        #expect(await until { slow.texts.count == 1 })
        rig.preview.start(Self.providerChoice, settings: Self.settings(), onState: { second.record($0) })
        #expect(await until { second.states.last == .idle })
        gate.open()
        await settle()
        #expect(rig.player.clips == [Self.clip], "seul le second joue")
        #expect(first.states == [.preparing, .idle])
        #expect(second.states == [.preparing, .playing, .idle])
    }

    /// `stop()` sans écoute en cours : rien n'est publié, rien ne casse.
    @Test func stopWithoutListeningDoesNothing() {
        let rig = Rig(factory: PreviewVoiceFactory(system: PreviewVoice(.clip(Self.clip))))
        rig.preview.stop()
        #expect(rig.states.states.isEmpty)
        #expect(rig.playersMade == 0, "aucun lecteur fabriqué pour rien")
    }
}

// MARK: - La phrase d'essai (règle 10)

@Suite(.timeLimit(.minutes(1))) struct VoiceSamplePhraseTests {
    @Test(arguments: [
        ("fr-FR", "fr"), ("fr_CA", "fr"), ("FR", "fr"), ("en-US", "en"), ("en", "en"), ("es-ES", "es"), ("de-DE", "de"),
        ("it-IT", "it"), ("pt-BR", "en"), ("ja-JP", "en"), ("", "en"), (" de-DE ", "de"),
    ])
    func eachPrimaryLanguageHasItsFixedPhraseOtherwiseEnglish(language: String, primary: String) {
        #expect(VoicesText.samplePhrase(for: language) == VoicesText.samplePhrases[primary])
    }

    @Test func theFivePhrasesAreDistinctAndNonEmpty() {
        let phrases = VoicesText.samplePhrases
        #expect(Set(phrases.keys) == ["fr", "en", "es", "de", "it"])
        #expect(Set(phrases.values).count == 5)
        #expect(phrases.values.allSatisfy { !$0.isEmpty })
    }
}

// MARK: - Le micro n'entend jamais la voix d'essai (règle 9, amendement 3)

/// Un relais vers `ScriptedClipPlayer` qui note « lecteur arrêté » au journal commun à chaque `stopNow()` (pas un second double de
/// lecteur : tout le reste passe au double existant).
final class JournaledPlayer: ClipPlayer {
    let inner = ScriptedClipPlayer(completion: .manual)
    let journal: Journal
    init(journal: Journal) { self.journal = journal }
    func play(_ clip: AudioClip) async throws { try await inner.play(clip) }
    func stop() { inner.stop() }
    @MainActor func stopNow() {
        journal.append("lecteur arrêté")
        inner.stopNow()
    }
}

/// Un relais vers la session double qui note « micro demandé » au journal commun quand `start()` (l'ouverture du micro) est appelé.
final class JournaledSession: DictationSessioning {
    let inner: any DictationSessioning
    let journal: Journal
    init(_ inner: any DictationSessioning, journal: Journal) {
        self.inner = inner
        self.journal = journal
    }
    func start() async {
        journal.append("micro demandé")
        await inner.start()
    }
    func finish() async { await inner.finish() }
    func cancel() async { await inner.cancel() }
    var snapshots: AsyncStream<DictationSnapshot> { inner.snapshots }
}

/// L'application assemblée : une écoute qui joue pendant la PRÉPARATION d'une dictée, d'une correction ou d'un entretien (la
/// fabrication est retenue par une porte) est arrêtée juste avant l'ouverture du micro, pas à l'appui : l'ordre au journal est
/// « lecteur arrêté » puis « micro demandé ». Réglages dans un dossier temporaire ; sessions, conversation, voix et lecteur doubles.
@MainActor @Suite(.timeLimit(.minutes(1))) struct PreviewBeforeMicrophoneTests {
    let directory: URL
    let store: SettingsStore
    let hotKeys = HotKeyTests.FakeRegistrar()
    let escape = HotKeyTests.FakeRegistrar()
    let modeRegistrars = ModeRegistrars()
    let surface = FakePanelSurface()
    let clicks = FakeClickMonitor()
    let presenter = Presenter()
    let engines = FakeEngines()
    let journal = Journal()
    let interviewFake: FakeInterviewEnvironment
    let player: JournaledPlayer
    let secrets = InMemorySecretStore()

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-preview-micro-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SettingsStore(file: directory.appendingPathComponent("settings.json"))
        interviewFake = FakeInterviewEnvironment(journal: journal)
        player = JournaledPlayer(journal: journal)
        try secrets.write("cle-exemple", account: InterviewRig.provider.id.uuidString)
    }

    func makeController(settings: AppSettings) throws -> AppController {
        try store.save(settings)
        var dictation = engines.environment
        let makeSession = dictation.makeSession
        let journal = journal
        dictation.makeSession = { JournaledSession(try await makeSession($0), journal: journal) }
        var interview = interviewFake.environment
        let clip = VoicePreviewTests.clip
        interview.makeVoice = { _, _ in PreviewVoice(.clip(clip)) }
        interview.makePlayer = { [player] in player }
        let fake = interviewFake.environment
        let access = SecretAccess(secrets, queue: DispatchQueue(label: "test.preview.micro.\(UUID())"))
        let controller = AppController(
            settingsStore: store, secrets: secrets, hotKeyRegistrar: hotKeys,
            escapeRegistrar: escape, makeModeHotKeyRegistrar: { [modeRegistrars] in modeRegistrars.make() },
            permissionsProbe: FakePermissionsProbe(microphone: .granted, accessibility: .granted),
            systemHotKeys: FakeSystemHotKeys(), keyboardLayout: HotKeyTests.ansi,
            makePanelSurface: { [surface] _ in surface }, clickMonitor: clicks,
            makeSettingsWindow: presenter.make, terminate: presenter.terminate,
            dictation: dictation, rewriter: .unavailable, inserter: InsertionRig().inserter,
            holdWatch: HoldWatch(anyHeld: { _ in true }, wait: { _ in }), reviewHandoverWait: { _ in },
            interview: interview,
            resolveInterview: { settings, engine in
                try await InterviewSetup.resolve(
                    settings: settings, engine: engine, secrets: access, makeModel: { _, _ in ScriptedModel(.never) },
                    makeVoice: fake.makeVoice)
            },
            interviewHistory: FakeInterviewHistory(), announcer: RecordingAnnouncer())
        controller.launch()
        return controller
    }

    /// L'écoute de la voix du système, jusqu'à la lecture.
    func listen(_ controller: AppController) async throws {
        controller.voicePreview.start(VoiceChoice(language: "fr-FR"), settings: controller.settings, onState: { _ in })
        try #require(await until { player.inner.isPlaying }, "l'écoute doit jouer avant l'ouverture du micro")
    }

    func expectStoppedThenMicrophone(_ microphone: String) {
        let stopped = journal.index(of: "lecteur arrêté")
        let opened = journal.index(of: microphone)
        #expect(stopped != nil, "le lecteur doit être arrêté : \(journal.entries)")
        #expect(opened != nil, "le micro doit être demandé : \(journal.entries)")
        if let stopped, let opened { #expect(stopped < opened, "\(journal.entries)") }
        #expect(!player.inner.isPlaying)
    }

    @Test func aDictationStopsThePreviewBeforeItsMicrophone() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TestGate()
        defer { gate.open() }
        engines.configure { $0.makeGate = gate }
        let controller = try makeController(settings: .defaults)
        hotKeys.press()
        #expect(await until { engines.events.contains("make") })
        try await listen(controller)
        #expect(journal.index(of: "lecteur arrêté") == nil, "l'appui seul ne coupe pas : seul le micro coupe")
        gate.open()
        #expect(await until { journal.index(of: "micro demandé") != nil })
        expectStoppedThenMicrophone("micro demandé")
    }

    @Test func aCorrectionStopsThePreviewBeforeItsMicrophone() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        var settings = AppSettings.defaults
        let raw = try #require(settings.modes.firstIndex { $0.id == ModeChip.rawID })
        settings.modes[raw].reviewBeforePaste = true
        let controller = try makeController(settings: settings)
        hotKeys.press()
        #expect(await until { engines.sessions.count == 1 })
        let session = engines.sessions[0]
        #expect(await until { session.calls.contains("start") })
        session.emit(.preparing)
        session.emit(.recording)
        session.emit(.finished("Un texte à corriger."))
        try #require(await until { controller.panelModel.dictation.stage == .review })

        let gate = TestGate()
        defer { gate.open() }
        engines.configure { $0.makeGate = gate }
        let before = journal.entries.filter { $0 == "micro demandé" }.count
        controller.dictation.startCorrection()
        #expect(await until { engines.events.filter { $0 == "make" }.count == 2 })
        try await listen(controller)
        gate.open()
        #expect(await until { journal.entries.filter { $0 == "micro demandé" }.count == before + 1 })
        let entries = journal.entries
        let stopped = try #require(entries.lastIndex(of: "lecteur arrêté"), "\(entries)")
        let opened = try #require(entries.lastIndex(of: "micro demandé"))
        #expect(stopped < opened, "\(entries)")
        #expect(!player.inner.isPlaying)
    }

    @Test func anInterviewStopsThePreviewBeforeItsMicrophone() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TestGate()
        defer { gate.open() }
        interviewFake.configure { $0.makeGate = gate }
        let controller = try makeController(settings: InterviewRig.readySettings())
        controller.panelModel.chipTapped(ModeChip.interviewID)
        #expect(await until { interviewFake.makeCount == 1 })
        try await listen(controller)
        #expect(journal.index(of: "lecteur arrêté") == nil, "l'appui seul ne coupe pas : seul le micro coupe")
        gate.open()
        #expect(await until { journal.index(of: "conversation démarrée") != nil })
        expectStoppedThenMicrophone("conversation démarrée")
    }
}
