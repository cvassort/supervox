import Foundation
import Synchronization
import SupervoxApp
import SupervoxCore
import Testing

@testable import Supervox

/// Règle 11 et amendement I : le câblage réel de l'entretien. Moteurs, catalogue, son et voix sont des doubles : aucun modèle,
/// aucun disque, aucun réseau, aucun micro, aucune voix du système. La fabrique de détecteurs rend un exemplaire neuf par demande
/// (`EngineCacheDetectorTests.Ledger`) : celui de l'entretien et celui de la dictée se distinguent.
@Suite(.timeLimit(.minutes(1))) struct LiveInterviewTests {
    typealias Stub = LiveDictationTests.StubCatalog

    /// Ce que les fabriques ont reçu, et ce qu'elles ont rendu.
    final class Made: Sendable {
        private struct State {
            var audios: [ScriptedAudioIO] = []
            var systemVoices: [String] = []
            var providerVoices: [(provider: String, voice: ProviderVoice)] = []
            var parts: [LiveInterview.Parts] = []
        }
        private let state = Mutex(State())

        var audios: [ScriptedAudioIO] { state.withLock { $0.audios } }
        var systemVoices: [String] { state.withLock { $0.systemVoices } }
        var providerVoices: [(provider: String, voice: ProviderVoice)] { state.withLock { $0.providerVoices } }
        var parts: [LiveInterview.Parts] { state.withLock { $0.parts } }

        func audio() -> any AudioIO {
            let audio = ScriptedAudioIO()
            state.withLock { $0.audios.append(audio) }
            return audio
        }

        func systemVoice(_ language: String) -> any SpeechSynthesizer {
            state.withLock { $0.systemVoices.append(language) }
            return NamedVoice("système \(language)")
        }

        func providerVoice(_ provider: ResolvedProvider, _ voice: ProviderVoice) -> any SpeechSynthesizer {
            state.withLock { $0.providerVoices.append((provider.name, voice)) }
            return NamedVoice("fournisseur \(provider.name)")
        }

        func assemble(_ parts: LiveInterview.Parts) -> any ConversationEngine {
            state.withLock { $0.parts.append(parts) }
            return IdleConversation()
        }
    }

    /// Une voix double : elle ne dit rien, elle porte un nom.
    struct NamedVoice: SpeechSynthesizer {
        let name: String
        init(_ name: String) { self.name = name }
        func synthesize(_ text: String) async throws -> Speech { throw CancellationError() }
    }

    /// Un modèle double qui ne rend rien.
    struct SilentModel: LanguageModel {
        func complete(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// Une conversation qui ne fait rien : l'assemblage double la rend, personne ne la démarre.
    final class IdleConversation: ConversationEngine {
        func start() async -> AsyncStream<ConversationEvent> { AsyncStream { $0.finish() } }
        func conclude() async {}
        func cancel() async {}
    }

    struct Rig {
        let live: LiveInterview
        let engines: LiveDictationEngines
        let doubles: DoubleEngines
        let ledger: EngineCacheDetectorTests.Ledger
        let catalog: Stub
        let made: Made
    }

    static func rig(states: [String: LocalModel.State] = Stub.allReady) -> Rig {
        let doubles = DoubleEngines()
        let ledger = EngineCacheDetectorTests.Ledger()
        let factory = EngineFactory(
            parakeet: { doubles.parakeet }, detector: { ledger.make($0) }, whisper: { model, _ in doubles.whisper(model) },
            whisperLoadsOffline: { _, _ in true }, setOffline: { doubles.network.set($0) })
        let catalog = Stub(states)
        let engines = LiveDictationEngines(
            modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"), base: catalog,
            makeFeed: { ScriptedMicrophoneFeed(chunks: []) }, factory: factory, watchdog: nil)
        let made = Made()
        let live = LiveInterview(
            engines: engines, makeAudio: { made.audio() }, makeSystemVoice: { made.systemVoice($0) },
            makeProviderVoice: { made.providerVoice($0, $1) }, assemble: { made.assemble($0) })
        return Rig(live: live, engines: engines, doubles: doubles, ledger: ledger, catalog: catalog, made: made)
    }

    static func setup(engine: TranscriptionEngine = .parakeet, turnSilence: Double = 0.9) -> InterviewSetup {
        let config = ConversationConfig(
            fastModel: "modele-exemple-rapide", strongModel: "modele-exemple-fort", maxQuestions: 6, template: "Gabarit.",
            language: "fr", vocabulary: [], interruptMinDuration: 0.3, interruptLevel: 0.1)
        return InterviewSetup(
            engine: engine, fastModel: SilentModel(), strongModel: SilentModel(), voice: NamedVoice("voix de la préparation"),
            config: config, turnSilence: turnSilence,
            transcription: TranscriptionSettings(engine: .parakeet, whisperModel: "small", language: "fr", vocabulary: []),
            providerName: "Fournisseur d'exemple", strongProviderName: "Fournisseur d'exemple", voiceProviderName: nil)
    }

    static let dictationSettings = TranscriptionSettings(engine: .parakeet, whisperModel: "small", language: "fr", vocabulary: [])

    /// Comme les autres suites de cette cible : aucune horloge de test, des passages bornés (au plus environ 0,4 s en cas d'échec).
    private func settle() async {
        for round in 0..<300 {
            if round % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
        }
    }

    private func until(_ condition: () -> Bool) async -> Bool {
        for round in 0..<20000 {
            if condition() { return true }
            if round % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
        }
        return condition()
    }

    // MARK: - Préparation et construction (règle 11, amendement I)

    /// Le câblage réel donne à l'onglet Entretien la formule du détecteur (et non l'identité du repli) : 0,6 et 0,7 s demandées
    /// donnent 1,024 s en pratique, 0,5 s (le défaut) 0,768 s.
    @Test("l'environnement réel donne le silence en pratique du détecteur, pas l'identité")
    func theRealEnvironmentGivesTheDetectorsEffectiveSilence() {
        let environment = Self.rig().live.environment
        #expect(environment.effectiveTurnSilence(0.6) == 1.024)
        #expect(environment.effectiveTurnSilence(0.7) == 1.024)
        #expect(environment.effectiveTurnSilence(0.5) == 0.768)
    }

    @Test("I : prepare charge le détecteur de l'entretien (à son silence) et le moteur final ; la conversation reçoit ces mêmes exemplaires")
    func thePreparedEnginesAreTheOnesTheConversationGets() async throws {
        let rig = Self.rig()
        let setup = Self.setup(turnSilence: 0.9)
        try await rig.live.environment.prepare(setup)

        let interviewDetector = rig.engines.cache.detector(minSilence: 0.9)
        #expect(await interviewDetector.isPrepared, "le détecteur de l'entretien est préparé")
        let dictationDetector = try #require(rig.engines.cache.engines(for: Self.dictationSettings).detector as? DoubleDetector)
        #expect(dictationDetector.prepares == 0, "celui de la dictée n'est pas touché")
        #expect((dictationDetector as AnyObject) !== (interviewDetector as AnyObject))
        #expect(rig.doubles.parakeet.prepares == 1, "le moteur final de l'entretien est préparé")
        #expect(rig.catalog.ensured.isEmpty, "tout est prêt : rien à télécharger")
        #expect(rig.made.audios.isEmpty, "préparer n'ouvre aucun son")

        _ = try await rig.live.environment.makeConversation(setup)
        let parts = try #require(rig.made.parts.first)
        #expect((parts.detector as AnyObject) === (interviewDetector as AnyObject), "le même détecteur, préparé")
        #expect((parts.transcriber as AnyObject) === rig.doubles.parakeet)
        let audio = try #require(rig.made.audios.first)
        #expect((parts.audio as AnyObject) === audio, "le son de la fabrique, un par conversation")
        #expect((parts.setup.voice as? NamedVoice)?.name == "voix de la préparation")
        #expect(rig.ledger.requests == [EngineCache.dictationMinSilence, 0.9], "aucun détecteur refabriqué")
    }

    @Test("I : avec WhisperKit, le modèle manquant est téléchargé par le catalogue, puis la variante est chargée et donnée")
    func whisperKitIsDownloadedThenPrepared() async throws {
        var states = Stub.allReady
        states[LocalModelID.whisper("small")] = .absent
        let rig = Self.rig(states: states)
        let setup = Self.setup(engine: .whisperKit)
        #expect(setup.transcription.engine == .whisperKit)
        try await rig.live.environment.prepare(setup)
        #expect(rig.catalog.ensured == [LocalModelID.whisper("small")])
        #expect(rig.doubles.whisper("small").prepares == 1)
        #expect(rig.doubles.parakeet.prepares == 0)

        _ = try await rig.live.environment.makeConversation(setup)
        let parts = try #require(rig.made.parts.first)
        #expect((parts.transcriber as AnyObject) === rig.doubles.whisper("small"))
    }

    @Test("règle 11 : porte de préchargement fermée : ni préparation ni conversation ; ouverte, les deux passent")
    func nothingPassesWhileThePreloadGateIsClosed() async throws {
        let rig = Self.rig()
        let gate = Gate()
        defer { gate.open() }
        let dictationDetector = try #require(rig.engines.cache.engines(for: Self.dictationSettings).detector as? DoubleDetector)
        dictationDetector.holdPrepare(with: gate)
        let preload = Task { await rig.engines.preload(for: Self.dictationSettings) }
        #expect(await until { dictationDetector.prepares == 1 })

        let environment = rig.live.environment
        let setup = Self.setup()
        let made = Task { _ = try await environment.makeConversation(setup) }
        let prepared = Task { try await environment.prepare(setup) }
        await settle()
        #expect(rig.made.parts.isEmpty, "aucune conversation tant que la porte est fermée")
        #expect(rig.made.audios.isEmpty, "aucun son fabriqué")
        #expect(rig.ledger.requests == [EngineCache.dictationMinSilence], "aucun détecteur de l'entretien")

        gate.open()
        await preload.value
        try await made.value
        try await prepared.value
        #expect(rig.made.parts.count == 1)
        #expect(await rig.engines.cache.detector(minSilence: setup.turnSilence).isPrepared)
        #expect(!rig.doubles.network.isOffline, "le réseau est rétabli quand l'entretien passe")
    }

    @Test("une tâche annulée pendant l'attente de la porte ne construit rien")
    func aCancelledWaitBuildsNothing() async {
        let rig = Self.rig()
        let gate = Gate()
        defer { gate.open() }
        let dictationDetector = rig.engines.cache.engines(for: Self.dictationSettings).detector as? DoubleDetector
        dictationDetector?.holdPrepare(with: gate)
        let preload = Task { await rig.engines.preload(for: Self.dictationSettings) }
        #expect(await until { dictationDetector?.prepares == 1 })
        let environment = rig.live.environment
        let setup = Self.setup()
        let made = Task { _ = try await environment.makeConversation(setup) }
        await settle()
        made.cancel()
        gate.open()
        await preload.value
        if case .success = await made.result { Issue.record("l'annulation n'est pas rendue") }
        #expect(rig.made.parts.isEmpty && rig.made.audios.isEmpty)
    }

    // MARK: - La voix (amendement I)

    @Test("I : makeVoice(choix, nil) fabrique la voix du système dans la langue du choix ; jamais celle d'un fournisseur")
    func withoutAProviderTheVoiceIsTheSystems() throws {
        let rig = Self.rig()
        let choice = VoiceChoice(providerID: nil, model: nil, identifier: nil, language: "fr-CA")
        let voice = try #require(rig.live.environment.makeVoice(choice, nil) as? NamedVoice)
        #expect(voice.name == "système fr-CA")
        #expect(rig.made.systemVoices == ["fr-CA"])
        #expect(rig.made.providerVoices.isEmpty)
    }

    @Test("I : makeVoice(choix, fournisseur) fabrique la voix de ce fournisseur, avec le modèle, l'identifiant et les paramètres du choix")
    func withAProviderTheVoiceIsThatProviders() throws {
        let rig = Self.rig()
        let provider = ResolvedProvider(
            kind: .openAICompatible, config: EndpointConfig(baseURL: URL(string: "https://example.com/v1")!, apiKey: "cle-exemple"),
            name: "Fournisseur de voix d'exemple")
        let choice = VoiceChoice(
            providerID: UUID(), model: "modele-voix-exemple", identifier: "voix-exemple", language: "fr-FR", extra: ["vitesse": "1"])
        let voice = try #require(rig.live.environment.makeVoice(choice, provider) as? NamedVoice)
        #expect(voice.name == "fournisseur Fournisseur de voix d'exemple")
        let made = try #require(rig.made.providerVoices.first)
        #expect(made.voice == ProviderVoice(model: "modele-voix-exemple", identifier: "voix-exemple", extra: ["vitesse": "1"]))
        #expect(rig.made.systemVoices.isEmpty)

        // Un fournisseur sans synthèse (format Anthropic) : la voix du système plutôt qu'une voix muette.
        let silent = ResolvedProvider(kind: .anthropic, config: provider.config, name: "Autre")
        #expect((rig.live.environment.makeVoice(choice, silent) as? NamedVoice)?.name == "système fr-FR")
    }

    @Test("l'assemblage réel donne la façade du moteur, sans la démarrer")
    func theRealAssemblyIsTheSessionFacade() {
        let parts = LiveInterview.Parts(
            audio: ScriptedAudioIO(), detector: DoubleDetector(offlineProbe: { false }),
            transcriber: DoubleTranscriber(name: "double", text: "texte", offlineProbe: { false }), setup: Self.setup())
        #expect(LiveInterview.session(parts) is ConversationSession)
    }
}
