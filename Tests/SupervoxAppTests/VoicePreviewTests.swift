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

/// Un compte lisible de n'importe quel fil (lecteurs ou voix fabriqués).
final class SharedCount: Sendable {
    let value = Mutex(0)
}

/// La liste des voix « installées » (inventée), changeable par le test, lue sous verrou à chaque appel.
final class VoiceList: Sendable {
    let value: Mutex<[SystemVoiceInfo]>
    init(_ list: [SystemVoiceInfo]) { value = Mutex(list) }
    func set(_ list: [SystemVoiceInfo]) { value.withLock { $0 = list } }
    func read() -> [SystemVoiceInfo] { value.withLock { $0 } }
}

/// Le micro tenu ou non, tel que l'écoute le lit (`microphoneHeld`), changeable par le test.
@MainActor final class MicrophoneFlag {
    var held = false
}

/// Un compte sur le fil principal (appels de la résolution, entrées dans une attente).
@MainActor final class MainCounter {
    var value = 0
}

/// Un lecteur qui lève une erreur qui n'est pas une `ClipPlayerError`.
final class OtherErrorPlayer: ClipPlayer {
    func play(_ clip: AudioClip) async throws { throw VoicePreviewTests.Other() }
    func stop() {}
    @MainActor func stopNow() {}
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
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!, name: "Fournisseur d'exemple",
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

    /// La voix installée de la liste inventée du banc.
    static let listed = SystemVoiceInfo(identifier: "voix.exemple.a", language: "en-US", quality: 2, name: "Voix d'exemple A")

    /// L'écoute et ses doubles. `resolve` : la VRAIE résolution (`VoiceChoice.resolve(in:secrets:)`) sur un trousseau en mémoire,
    /// sauf quand un test la remplace ; chaque appel est compté (`resolves`). `voices` : la liste des voix installées, relue par
    /// l'écoute à chaque appel. `microphone` : le micro tenu ou non.
    @MainActor final class Rig {
        let factory: PreviewVoiceFactory
        let player: ScriptedClipPlayer
        let clock = PreviewClock()
        let keys: InMemorySecretStore
        let states = PreviewStates()
        let voices: VoiceList
        let microphone = MicrophoneFlag()
        let resolves = MainCounter()
        private let madePlayers = SharedCount()
        let preview: VoicePreview

        var playersMade: Int { madePlayers.value.withLock { $0 } }

        init(
            factory: PreviewVoiceFactory, player: ScriptedClipPlayer = ScriptedClipPlayer(completion: .immediate),
            makePlayer: (@Sendable () -> any ClipPlayer)? = nil, withKey: Bool = true,
            resolve: VoicePreview.Resolve? = nil, installed: [SystemVoiceInfo] = [VoicePreviewTests.listed]
        ) {
            self.factory = factory
            self.player = player
            keys = withKey
                ? InMemorySecretStore(secrets: [VoicePreviewTests.provider.id.uuidString: "cle-exemple"]) : InMemorySecretStore()
            voices = VoiceList(installed)
            let access = SecretAccess(keys, queue: DispatchQueue(label: "test.voice.preview.\(UUID())"))
            let counter = madePlayers
            let clock = clock
            let voices = voices
            let microphone = microphone
            let resolves = resolves
            let resolveVoice: VoicePreview.Resolve =
                resolve ?? { choice, settings in try await choice.resolve(in: settings, secrets: access) }
            preview = VoicePreview(
                makeVoice: { factory.make($0, $1) },
                makePlayer: makePlayer ?? { [player] in
                    counter.value.withLock { $0 += 1 }
                    return player
                },
                resolve: { choice, settings in
                    resolves.value += 1
                    return try await resolveVoice(choice, settings)
                },
                systemVoices: { voices.read() },
                microphoneHeld: { microphone.held },
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
        case systemMissing, systemNoVoice, systemEmptyError, systemZeroSamples, systemTimedOutError, systemDeadline
        case systemOtherError
        case providerRemoved, providerCannotSpeak, providerIncomplete
        case resolveNoKey, resolveOther, providerHTTP, providerUnreadableBytes, providerEmptyError, providerZeroSamples
        case providerDeadline
        case playbackFailed, playbackOther, voiceUnavailable, playerUnavailable
        var testDescription: String { rawValue }
    }

    struct Other: Error {}

    /// Une ligne de la table : la voix choisie, les doubles, et la panne attendue.
    struct Scenario {
        let choice: VoiceChoice
        let factory: PreviewVoiceFactory
        var player: ScriptedClipPlayer? = nil
        var makePlayer: (@Sendable () -> any ClipPlayer)? = nil
        var withKey = true
        var fireDeadline = false
        var resolve: VoicePreview.Resolve? = nil
        let expected: VoicePreview.Failure
    }

    static func scenario(_ c: FailureCase) -> Scenario {
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
        case .systemMissing:
            // Une voix du système désignée, absente de la liste installée : rien n'est fabriqué.
            return Scenario(
                choice: VoiceChoice(identifier: "voix.exemple.absente", language: "fr-FR"), factory: system(.forbidden),
                expected: .notInstalled)
        case .systemNoVoice:
            return Scenario(
                choice: systemChoice, factory: system(.error(SpeechError.noVoice(language: "fr-FR"))), expected: .notInstalled)
        case .systemEmptyError: return Scenario(choice: systemChoice, factory: system(.error(SpeechError.empty)), expected: .silent)
        case .systemZeroSamples: return Scenario(choice: systemChoice, factory: system(.clip(silent)), expected: .silent)
        case .systemTimedOutError:
            return Scenario(choice: systemChoice, factory: system(.error(SpeechError.timedOut)), expected: .timedOut)
        case .systemDeadline:
            return Scenario(choice: systemChoice, factory: system(.hang), fireDeadline: true, expected: .timedOut)
        case .systemOtherError: return Scenario(choice: systemChoice, factory: system(.error(Other())), expected: .unavailable)
        case .providerRemoved: return Scenario(choice: removed, factory: provider(.forbidden), expected: .unusable(.providerRemoved))
        case .providerCannotSpeak:
            return Scenario(choice: cannotSpeak, factory: provider(.forbidden), expected: .unusable(.providerCannotSpeak))
        case .providerIncomplete:
            return Scenario(choice: incomplete, factory: provider(.forbidden), expected: .unusable(.incomplete))
        case .resolveNoKey:
            return Scenario(
                choice: providerChoice, factory: provider(.forbidden), withKey: false,
                expected: .provider(.noKey(provider: Self.provider.name)))
        case .resolveOther:
            // Une erreur de la résolution que le contrat ne prévoit pas.
            return Scenario(
                choice: providerChoice, factory: provider(.forbidden), resolve: { _, _ in throw Other() }, expected: .unavailable)
        case .providerHTTP:
            return Scenario(
                choice: providerChoice, factory: provider(.error(EndpointError.http(status: 401, body: "corps"))),
                expected: .provider(.unauthorized(401)))
        case .providerUnreadableBytes:
            return Scenario(choice: providerChoice, factory: provider(.error(WavFileError.notAWavFile)), expected: .provider(.malformed))
        case .providerEmptyError:
            return Scenario(choice: providerChoice, factory: provider(.error(SpeechError.empty)), expected: .silent)
        case .providerZeroSamples: return Scenario(choice: providerChoice, factory: provider(.clip(silent)), expected: .silent)
        case .providerDeadline:
            return Scenario(choice: providerChoice, factory: provider(.hang), fireDeadline: true, expected: .timedOut)
        case .playbackFailed:
            return Scenario(
                choice: systemChoice, factory: system(.clip(clip)), player: ScriptedClipPlayer(completion: .failing),
                expected: .playback)
        case .playbackOther:
            // Le lecteur lève une erreur qui n'est pas une `ClipPlayerError`.
            return Scenario(
                choice: systemChoice, factory: system(.clip(clip)), makePlayer: { OtherErrorPlayer() }, expected: .playback)
        case .voiceUnavailable:
            return Scenario(
                choice: systemChoice, factory: system(.error(InterviewEnvironment.Unavailable())), expected: .unavailable)
        case .playerUnavailable:
            return Scenario(
                choice: systemChoice, factory: system(.clip(clip)), makePlayer: InterviewEnvironment.noPlayer,
                expected: .unavailable)
        }
    }

    /// Chaque ligne de la table des pannes : l'écoute finit sur sa panne, sans second classement, et la phrase montrée est celle de
    /// `VoicesText` (pour `.provider(f)`, `VoicesText.providerFailure(f)`). Une voix inutilisable, ou une voix du système absente de la liste, n'est
    /// jamais fabriquée ; aucune voix du système ne parle à la place d'un fournisseur ; rien n'est joué sauf par la ligne de lecture.
    @Test(arguments: FailureCase.allCases)
    func everyPreviewFailureHasItsSentence(_ c: FailureCase) async {
        let s = Self.scenario(c)
        let player = s.player ?? ScriptedClipPlayer(completion: .immediate)
        let rig = Rig(factory: s.factory, player: player, makePlayer: s.makePlayer, withKey: s.withKey, resolve: s.resolve)
        rig.start(s.choice)
        if s.fireDeadline {
            #expect(await until { rig.clock.asked.count == 1 })
            rig.clock.fire()
        }
        #expect(await rig.ended())
        #expect(rig.states.states.last == .failed(s.expected), "\(rig.states.states)")
        let sentence = VoicesText.failure(s.expected)
        #expect(!sentence.isEmpty)
        if case .provider(let failure) = s.expected { #expect(sentence == VoicesText.providerFailure(failure)) }
        if case .unusable(let reason) = s.expected {
            #expect(sentence == VoicesText.reason(reason))
            #expect(s.factory.calls.isEmpty, "une voix inutilisable n'est jamais fabriquée")
        }
        if c == .systemMissing { #expect(s.factory.calls.isEmpty, "une voix absente de la liste n'est jamais fabriquée") }
        if s.choice.providerID != nil { #expect(s.factory.systemCalls == 0, "jamais la voix du système à la place") }
        if c != .playbackFailed { #expect(player.clips.isEmpty, "rien n'est joué") }
    }

    /// La liste des voix est relue au moment de l'écoute : une voix listée à la construction, désinstallée depuis, n'est pas
    /// fabriquée.
    @Test func aDesignatedVoiceUninstalledSinceIsSaidWithoutSynthesis() async {
        let rig = Rig(factory: PreviewVoiceFactory(system: PreviewVoice(.forbidden)))
        rig.voices.set([])
        rig.start(VoiceChoice(identifier: "voix.exemple.a", language: "en-US"))
        #expect(await rig.ended())
        #expect(rig.states.states == [.preparing, .failed(.notInstalled)])
        #expect(rig.factory.calls.isEmpty)
    }

    enum CancellationSource: String, CaseIterable, CustomTestStringConvertible {
        case voice, resolution
        var testDescription: String { rawValue }
    }

    /// Une `CancellationError` levée d'elle-même (par la voix, ou par la résolution) n'est jamais une panne : l'écoute revient à
    /// `.idle`, sans phrase, et rien n'est joué.
    @Test(arguments: CancellationSource.allCases)
    func aCancellationIsNeverAFailure(_ source: CancellationSource) async {
        let rig: Rig = switch source {
        case .voice: Rig(factory: PreviewVoiceFactory(system: PreviewVoice(.error(CancellationError()))))
        case .resolution:
            Rig(factory: PreviewVoiceFactory(system: PreviewVoice(.forbidden)), resolve: { _, _ in throw CancellationError() })
        }
        rig.start(Self.systemChoice)
        #expect(await rig.ended())
        #expect(rig.states.states == [.preparing, .idle])
        #expect(rig.player.clips.isEmpty)
    }

    /// `stop()` pendant la résolution (une résolution sourde à l'annulation, retenue par une porte) : quand elle rend sa réponse,
    /// aucune voix n'est fabriquée et rien n'est publié après le `.idle` de `stop()`. C'est le contrôle du jeton d'après la
    /// résolution qui le tient.
    @Test func stopDuringTheResolutionMakesNoVoice() async {
        let gate = TestGate()
        defer { gate.open() }
        let entered = MainCounter()
        let rig = Rig(
            factory: PreviewVoiceFactory(system: PreviewVoice(.clip(Self.clip))),
            resolve: { choice, _ in
                entered.value += 1
                await gate.wait()
                return ResolvedVoice.system(language: choice.language, identifier: choice.identifier, because: nil)
            })
        rig.start(Self.systemChoice)
        #expect(await until { entered.value == 1 })
        rig.preview.stop()
        #expect(rig.states.states == [.preparing, .idle])
        gate.open()
        await settle()
        #expect(rig.factory.calls.isEmpty, "aucune voix fabriquée après stop()")
        #expect(rig.states.states == [.preparing, .idle], "aucun état après stop()")
        #expect(rig.player.clips.isEmpty)
    }

    // MARK: Le micro tenu

    /// Tant qu'un micro est tenu, l'écoute est refusée avant tout : un seul état, `.failed(.microphoneBusy)` ; rien n'est résolu
    /// (aucune lecture du trousseau), rien n'est fabriqué ni joué. Le refus ne retient pas le rappel : un `stop()` qui suit ne publie
    /// rien. Le micro rendu, l'écoute repart et joue.
    @Test func aHeldMicrophoneRefusesTheListeningBeforeAnything() async {
        let factory = PreviewVoiceFactory(system: PreviewVoice(.forbidden), provider: PreviewVoice(.clip(Self.clip)))
        let rig = Rig(factory: factory)
        rig.microphone.held = true
        rig.start(Self.providerChoice)
        #expect(rig.states.states == [.failed(.microphoneBusy)])
        await settle()
        #expect(rig.states.states == [.failed(.microphoneBusy)], "un seul état")
        #expect(rig.resolves.value == 0, "rien n'est résolu")
        #expect(rig.keys.readCount == 0, "le trousseau n'est pas lu")
        #expect(factory.calls.isEmpty)
        #expect(rig.player.clips.isEmpty)
        rig.preview.stop()
        #expect(rig.states.states == [.failed(.microphoneBusy)], "le refus ne retient pas le rappel")

        rig.microphone.held = false
        rig.start(Self.providerChoice)
        #expect(await until { rig.states.states.last == .idle })
        #expect(rig.states.states == [.failed(.microphoneBusy), .preparing, .playing, .idle])
        #expect(rig.player.clips == [Self.clip])
        #expect(rig.resolves.value == 1)
    }

    /// Les phrases des pannes : fixes, en français, distinctes d'un cas à l'autre.
    @Test func theFailureSentencesAreFixedAndDistinct() {
        let failures: [VoicePreview.Failure] = [
            .notInstalled, .unusable(.providerRemoved), .unusable(.providerCannotSpeak), .unusable(.incomplete),
            .provider(.noKey(provider: "Fournisseur d'exemple")), .silent, .timedOut, .playback, .unavailable,
            .microphoneBusy,
        ]
        let sentences = failures.map(VoicesText.failure)
        #expect(Set(sentences).count == failures.count)
        #expect(sentences.allSatisfy { $0.hasSuffix(".") && !$0.contains("Error") })
        let digits = VoicesText.failure(.timedOut).filter(\.isNumber)
        #expect(digits.isEmpty, "aucun nombre de secondes : la voix du système abandonne avant la borne de l'écoute")
        // Décision 13b (tâche 4) : la phrase du micro tenu nomme ce qui doit être fini, sans référent ambigu.
        let busy = VoicesText.failure(.microphoneBusy)
        #expect(busy.contains("la dictée ou l'entretien"), "\(busy)")
        #expect(!busy.contains("qu'il est fini"), "\(busy)")
    }

    /// Ce qu'une panne de fournisseur dit pour une voix : la phrase qui la classe, une ligne par cas de `RewriteFailure`.
    enum ProviderSentence {
        /// Une voix mal réglée : la phrase propre à la voix, qui envoie vérifier modèle, identifiant et paramètres dans l'onglet Voix.
        case misconfigured
        /// Un cas neutre : la phrase de `RewriteFailure` telle quelle.
        case neutral
        case removed, timedOut, silent
    }

    static let providerFailures: [(RewriteFailure, ProviderSentence)] = [
        (.noModel, .misconfigured), (.providerMissing, .removed), (.noKey(provider: "Fournisseur d'exemple"), .neutral),
        (.keychain, .neutral), (.unauthorized(401), .neutral), (.notFound, .misconfigured), (.rejected(400), .misconfigured),
        (.rateLimited, .neutral), (.server(503), .neutral), (.unreachable, .neutral), (.redirected, .neutral),
        (.interrupted, .neutral), (.stalled(30), .timedOut), (.providerError, .neutral), (.truncated, .neutral),
        (.refused, .neutral), (.empty, .silent), (.timedOut(30), .timedOut), (.malformed, .misconfigured),
    ]

    /// D1 : chaque cas de `RewriteFailure` (19, une ligne chacun) a sa phrase pour une voix ; aucune ne parle de « mode » ni de
    /// « réponse longue ». Une voix mal réglée (adresse ou modèle inconnu, requête refusée, réponse illisible, pas de modèle)
    /// envoie à l'onglet Voix ; les cas neutres gardent la phrase de `RewriteFailure`.
    @Test func everyProviderFailureHasAVoiceSentence() {
        #expect(Self.providerFailures.count == 19, "une ligne par cas")
        var misconfigured: [String] = []
        for (failure, kind) in Self.providerFailures {
            let sentence = VoicesText.providerFailure(failure)
            #expect(VoicesText.failure(.provider(failure)) == sentence)
            let lower = sentence.lowercased()
            #expect(lower.range(of: #"\bmodes?\b"#, options: .regularExpression) == nil, "« mode » : \(sentence)")
            #expect(!lower.contains("longue"), "« réponse longue » : \(sentence)")
            #expect(sentence.hasSuffix("."))
            switch kind {
            case .misconfigured:
                #expect(sentence != failure.message)
                for word in ["modèle", "identifiant", "paramètres", "onglet Voix"] {
                    #expect(sentence.contains(word), "\(failure) : \(word)")
                }
                misconfigured.append(sentence)
            case .neutral: #expect(sentence == failure.message)
            case .removed: #expect(sentence == VoicesText.reason(.providerRemoved))
            case .timedOut: #expect(sentence == VoicesText.failure(.timedOut))
            case .silent: #expect(sentence == VoicesText.failure(.silent))
            }
        }
        #expect(Set(misconfigured).count == misconfigured.count, "une phrase par cas mal réglé")
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
        // Une voix qu'on écoute n'est pas encore choisie : « peut prendre », jamais « prendra ».
        #expect(phrases["fr"]?.contains("peut prendre") == true)
        #expect(phrases["fr"]?.contains("prendra") == false)
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

/// L'application assemblée : une écoute lancée AVANT l'appui (après, elle est refusée : le micro est tenu dès l'appui) joue
/// pendant la préparation d'une dictée, d'une correction ou d'un entretien (la fabrication est retenue par une porte), et n'est
/// arrêtée que juste avant l'ouverture du micro : l'ordre au journal est « lecteur arrêté » puis « micro demandé ». Puis le refus,
/// par chemin, tant que le micro est tenu. Réglages dans un dossier temporaire ; sessions, conversation, voix et lecteur doubles.
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
    let voicesMade = SharedCount()
    let secrets = InMemorySecretStore()

    static let choice = VoiceChoice(language: "fr-FR")

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
        let voicesMade = voicesMade
        interview.makeVoice = { _, _ in
            voicesMade.value.withLock { $0 += 1 }
            return PreviewVoice(.clip(clip))
        }
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
        controller.voicePreview.start(Self.choice, settings: controller.settings, onState: { _ in })
        try #require(await until { player.inner.isPlaying }, "l'écoute doit jouer avant l'ouverture du micro")
    }

    /// L'écoute est refusée : un seul état, `.failed(.microphoneBusy)`. Aucune `.preparing` (publiée avant toute résolution) :
    /// rien n'est résolu ; aucune voix fabriquée, rien de joué.
    func expectRefused(_ controller: AppController) async {
        let states = PreviewStates()
        let made = voicesMade.value.withLock { $0 }
        let played = player.inner.clips.count
        controller.voicePreview.start(Self.choice, settings: controller.settings, onState: { states.record($0) })
        #expect(states.states == [.failed(.microphoneBusy)])
        await settle()
        #expect(states.states == [.failed(.microphoneBusy)], "ni préparation ni résolution")
        #expect(voicesMade.value.withLock { $0 } == made, "aucune voix fabriquée")
        #expect(player.inner.clips.count == played, "rien n'est joué")
        #expect(!player.inner.isPlaying)
    }

    /// « lecteur arrêté » est au journal, avant `microphone`, et le lecteur ne joue plus.
    func expectStoppedThenMicrophone(_ microphone: String) {
        let entries = journal.entries
        let stopped = entries.lastIndex(of: "lecteur arrêté")
        let opened = entries.lastIndex(of: microphone)
        #expect(stopped != nil, "le lecteur doit être arrêté : \(entries)")
        #expect(opened != nil, "le micro doit être demandé : \(entries)")
        if let stopped, let opened { #expect(stopped < opened, "\(entries)") }
        #expect(!player.inner.isPlaying)
    }

    /// Une dictée jusqu'à la relecture (le mode brut relit avant de coller).
    func dictateIntoReview(_ controller: AppController) async throws {
        hotKeys.press()
        try #require(await until { engines.sessions.count == 1 })
        let session = engines.sessions[0]
        try #require(await until { session.calls.contains("start") })
        session.emit(.preparing)
        session.emit(.recording)
        session.emit(.finished("Un texte à corriger."))
        try #require(await until { controller.panelModel.dictation.stage == .review })
    }

    static func reviewingSettings() throws -> AppSettings {
        var settings = AppSettings.defaults
        let raw = try #require(settings.modes.firstIndex { $0.id == ModeChip.rawID })
        settings.modes[raw].reviewBeforePaste = true
        return settings
    }

    // MARK: Arrêt juste avant le micro

    @Test func aDictationStopsThePreviewBeforeItsMicrophone() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TestGate()
        defer { gate.open() }
        engines.configure { $0.makeGate = gate }
        let controller = try makeController(settings: .defaults)
        try await listen(controller)
        hotKeys.press()
        #expect(await until { engines.events.contains("make") })
        #expect(player.inner.isPlaying)
        #expect(journal.index(of: "lecteur arrêté") == nil, "l'appui seul ne coupe pas : seul le micro coupe")
        gate.open()
        #expect(await until { journal.index(of: "micro demandé") != nil })
        expectStoppedThenMicrophone("micro demandé")
    }

    @Test func aCorrectionStopsThePreviewBeforeItsMicrophone() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(settings: try Self.reviewingSettings())
        try await dictateIntoReview(controller)

        let gate = TestGate()
        defer { gate.open() }
        engines.configure { $0.makeGate = gate }
        try await listen(controller)
        let before = journal.entries.filter { $0 == "micro demandé" }.count
        controller.dictation.startCorrection()
        #expect(await until { engines.events.filter { $0 == "make" }.count == 2 })
        #expect(player.inner.isPlaying)
        #expect(journal.index(of: "lecteur arrêté") == nil, "l'appui seul ne coupe pas : seul le micro coupe")
        gate.open()
        #expect(await until { journal.entries.filter { $0 == "micro demandé" }.count == before + 1 })
        expectStoppedThenMicrophone("micro demandé")
    }

    @Test func anInterviewStopsThePreviewBeforeItsMicrophone() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TestGate()
        defer { gate.open() }
        interviewFake.configure { $0.makeGate = gate }
        let controller = try makeController(settings: InterviewRig.readySettings())
        try await listen(controller)
        controller.panelModel.chipTapped(ModeChip.interviewID)
        #expect(await until { interviewFake.makeCount == 1 })
        #expect(player.inner.isPlaying)
        #expect(journal.index(of: "lecteur arrêté") == nil, "l'appui seul ne coupe pas : seul le micro coupe")
        gate.open()
        #expect(await until { journal.index(of: "conversation démarrée") != nil })
        expectStoppedThenMicrophone("conversation démarrée")
    }

    // MARK: Refus tant que le micro est tenu

    /// Dès l'appui d'une dictée (la session n'est pas encore fabriquée) : refusée.
    @Test func aDictationRefusesTheListeningFromThePress() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = TestGate()
        defer { gate.open() }
        engines.configure { $0.makeGate = gate }
        let controller = try makeController(settings: .defaults)
        hotKeys.press()
        #expect(await until { engines.events.contains("make") })
        await expectRefused(controller)
    }

    /// Pendant la session d'une correction : refusée.
    @Test func aCorrectionRefusesTheListeningDuringItsSession() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(settings: try Self.reviewingSettings())
        try await dictateIntoReview(controller)
        controller.dictation.startCorrection()
        #expect(await until { engines.sessions.count == 2 })
        let session = engines.sessions[1]
        #expect(await until { session.calls.contains("start") })
        session.emit(.recording)
        await expectRefused(controller)
    }

    /// Pendant un entretien, de son lancement : refusée.
    @Test func anInterviewRefusesTheListeningWhileItRuns() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(settings: InterviewRig.readySettings())
        controller.panelModel.chipTapped(ModeChip.interviewID)
        #expect(await until { interviewFake.drivers.first?.starts == 1 })
        await expectRefused(controller)
    }

    /// Un entretien annulé dont la conversation n'a pas encore rendu son micro : l'entretien n'est plus actif ni la dictée occupée,
    /// mais l'écoute est refusée. Le micro rendu, elle repart et joue.
    @Test func aCancelledInterviewStillReleasingItsMicrophoneRefusesThenTheListeningResumes() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = try makeController(settings: InterviewRig.readySettings())
        controller.panelModel.chipTapped(ModeChip.interviewID)
        #expect(await until { interviewFake.drivers.first?.starts == 1 })
        let driver = try #require(interviewFake.drivers.first)
        let release = TestGate()
        defer { release.open() }
        driver.configure(cancelGate: release)
        controller.dictation.escapePressed()
        #expect(await until { journal.index(of: "annulation demandée") != nil })
        #expect(await until { !controller.interview.isActive })
        #expect(!controller.dictation.isBusy, "la dictée seule ne le voit plus")
        #expect(controller.interview.isReleasingMicrophone)
        await expectRefused(controller)

        release.open()
        #expect(await until { !controller.interview.isReleasingMicrophone })
        try await listen(controller)
        #expect(voicesMade.value.withLock { $0 } == 1)
    }
}
