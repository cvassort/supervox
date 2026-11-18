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
            var systemIdentifiers: [String?] = []
            var providerVoices: [(provider: String, voice: ProviderVoice)] = []
            var parts: [LiveInterview.Parts] = []
            var conversations: [HeldConversation] = []
        }
        private let state = Mutex(State())

        var audios: [ScriptedAudioIO] { state.withLock { $0.audios } }
        var systemVoices: [String] { state.withLock { $0.systemVoices } }
        /// L'identifiant reçu par chaque fabrication de la voix du système, dans l'ordre de `systemVoices`.
        var systemIdentifiers: [String?] { state.withLock { $0.systemIdentifiers } }
        var providerVoices: [(provider: String, voice: ProviderVoice)] { state.withLock { $0.providerVoices } }
        var parts: [LiveInterview.Parts] { state.withLock { $0.parts } }
        var conversations: [HeldConversation] { state.withLock { $0.conversations } }

        func audio() -> any AudioIO {
            let audio = ScriptedAudioIO()
            state.withLock { $0.audios.append(audio) }
            return audio
        }

        func systemVoice(_ language: String, _ identifier: String?) -> any SpeechSynthesizer {
            state.withLock {
                $0.systemVoices.append(language)
                $0.systemIdentifiers.append(identifier)
            }
            return NamedVoice("système \(language)")
        }

        func providerVoice(_ provider: ResolvedProvider, _ voice: ProviderVoice) -> any SpeechSynthesizer {
            state.withLock { $0.providerVoices.append((provider.name, voice)) }
            return NamedVoice("fournisseur \(provider.name)")
        }

        func assemble(_ parts: LiveInterview.Parts) -> any ConversationEngine {
            let conversation = HeldConversation()
            state.withLock {
                $0.parts.append(parts)
                $0.conversations.append(conversation)
            }
            return conversation
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

    /// La conversation que l'assemblage double rend : elle compte ses démarrages et garde son flux ouvert jusqu'à `cancel()`, qui
    /// rend `.finished(.cancelled)` comme le moteur. Aucun son, aucun modèle.
    final class HeldConversation: ConversationEngine, Sendable {
        private struct State {
            var starts = 0
            var sink: AsyncStream<ConversationEvent>.Continuation?
        }
        private let state = Mutex(State())

        var starts: Int { state.withLock { $0.starts } }

        func start() async -> AsyncStream<ConversationEvent> {
            let (stream, sink) = AsyncStream.makeStream(of: ConversationEvent.self)
            state.withLock {
                $0.starts += 1
                $0.sink = sink
            }
            return stream
        }
        func conclude() async {}
        func cancel() async {
            let sink = state.withLock { $0.sink }
            sink?.yield(.finished(.cancelled))
            sink?.finish()
        }
    }

    /// Les issues d'un entretien.
    final class Outcomes: Sendable {
        private let state = Mutex<[InterviewOutcome]>([])
        var list: [InterviewOutcome] { state.withLock { $0 } }
        func append(_ outcome: InterviewOutcome) { state.withLock { $0.append(outcome) } }
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
            engines: engines, makeAudio: { made.audio() }, makeSystemVoice: { made.systemVoice($0, $1) },
            makeProviderVoice: { made.providerVoice($0, $1) }, assemble: { made.assemble($0) })
        return Rig(live: live, engines: engines, doubles: doubles, ledger: ledger, catalog: catalog, made: made)
    }

    static func setup(
        engine: TranscriptionEngine = .parakeet, turnSilence: Double = 0.9, vocabulary: [String] = []
    ) -> InterviewSetup {
        let config = ConversationConfig(
            fastModel: "modele-exemple-rapide", strongModel: "modele-exemple-fort", maxQuestions: 6, template: "Gabarit.",
            language: "fr", vocabulary: vocabulary, interruptMinDuration: 0.3, interruptLevel: 0.1)
        return InterviewSetup(
            engine: engine, fastModel: SilentModel(), strongModel: SilentModel(), voice: NamedVoice("voix de la préparation"),
            config: config, turnSilence: turnSilence,
            transcription: TranscriptionSettings(engine: .parakeet, whisperModel: "small", language: "fr", vocabulary: vocabulary),
            providerName: "Fournisseur d'exemple", strongProviderName: "Fournisseur d'exemple", voiceProviderName: nil)
    }

    static let dictationSettings = TranscriptionSettings(engine: .parakeet, whisperModel: "small", language: "fr", vocabulary: [])

    /// Comme les autres suites de cette cible : aucune horloge de test, des passages bornés (au plus environ 0,4 s en cas d'échec).
    private func settle() async {
        for round in 0..<300 {
            if round % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
        }
    }

    /// Sur l'isolation de l'appelant : un test du fil principal y lit l'état du contrôleur.
    nonisolated(nonsending) private func until(_ condition: () -> Bool) async -> Bool {
        for round in 0..<20000 {
            if condition() { return true }
            if round % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
        }
        return condition()
    }

    /// Le résultat d'une tâche, attendu au plus le temps de `until` : `nil` si elle n'a pas fini (M-7 : le test échoue à sa limite au
    /// lieu de rester suspendu sur `.value`).
    private func bounded<Success: Sendable, Failure: Error>(_ task: Task<Success, Failure>) async -> Result<Success, Failure>? {
        let box = ResultBox<Success, Failure>()
        Task { box.set(await task.result) }
        guard await until({ box.result != nil }) else { return nil }
        return box.result
    }

    final class ResultBox<Success: Sendable, Failure: Error>: Sendable {
        private let state = Mutex<Result<Success, Failure>?>(nil)
        var result: Result<Success, Failure>? { state.withLock { $0 } }
        func set(_ result: Result<Success, Failure>) { state.withLock { $0 = result } }
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
        _ = try await rig.live.environment.prepare(setup)

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
        _ = try await rig.live.environment.prepare(setup)
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
        let prepared = Task { _ = try await environment.prepare(setup) }
        await settle()
        #expect(rig.made.parts.isEmpty, "aucune conversation tant que la porte est fermée")
        #expect(rig.made.audios.isEmpty, "aucun son fabriqué")
        #expect(rig.ledger.requests == [EngineCache.dictationMinSilence], "aucun détecteur de l'entretien")

        gate.open()
        _ = try #require(await bounded(preload), "le préchargement ne finit pas")
        try #require(await bounded(made), "la fabrication ne finit pas").get()
        try #require(await bounded(prepared), "la préparation ne finit pas").get()
        #expect(rig.made.parts.count == 1)
        #expect(await rig.engines.cache.detector(minSilence: setup.turnSilence).isPrepared)
        #expect(!rig.doubles.network.isOffline, "le réseau est rétabli quand l'entretien passe")
    }

    @Test("une tâche annulée pendant l'attente de la porte ne construit rien")
    func aCancelledWaitBuildsNothing() async throws {
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
        _ = try #require(await bounded(preload), "le préchargement ne finit pas")
        let result = try #require(await bounded(made), "la fabrication annulée ne finit pas")
        if case .success = result { Issue.record("l'annulation n'est pas rendue") }
        #expect(rig.made.parts.isEmpty && rig.made.audios.isEmpty)
    }

    // MARK: - Le vocabulaire (I-1) : la règle de la dictée

    @MainActor
    @Test("I-1 : petit modèle de vocabulaire absent : l'entretien démarre, la conversation reçoit une configuration sans vocabulaire, l'avis le dit")
    func withoutTheVocabularyModelTheInterviewStartsWithoutVocabulary() async throws {
        var states = Stub.allReady
        states[LocalModelID.parakeetVocabulary] = .absent
        let rig = Self.rig(states: states)
        rig.catalog.failEnsure(LocalModelID.parakeetVocabulary, LiveDictationTests.Refused())
        let panel = PanelModel(lastModeID: ModeChip.interviewID)
        let setup = Self.setup(vocabulary: ["terme-un", "terme-deux"])
        let controller = InterviewController(
            environment: rig.live.environment, settings: { .defaults }, behavior: { .toggle }, resolve: { _, _ in setup },
            history: DiscardingInterviewHistory(), panel: panel)
        let outcomes = Outcomes()
        controller.start(engine: nil) { outcomes.append($0) }

        #expect(await until { rig.made.conversations.first?.starts == 1 }, "l'entretien démarre")
        let parts = try #require(rig.made.parts.first)
        #expect(parts.setup.config.vocabulary.isEmpty, "le moteur de conversation ne reçoit aucun terme")
        #expect(parts.setup.transcription.vocabulary.isEmpty)
        #expect(rig.catalog.ensured == [LocalModelID.parakeetVocabulary], "le petit modèle a été demandé au catalogue, rien d'autre")
        #expect(panel.interview?.notice == InterviewText.vocabularyModelUnavailable)
        #expect(outcomes.list.isEmpty)

        controller.cancel()
        #expect(await until { outcomes.list == [.cancelled] })
    }

    @Test("I-1 (témoin) : petit modèle prêt, Parakeet : la liste part entière, sans avis")
    func withTheVocabularyModelTheListIsKept() async throws {
        let rig = Self.rig()
        let prepared = try await rig.live.environment.prepare(Self.setup(vocabulary: ["terme-un", "terme-deux"]))
        #expect(prepared.notice == nil)
        #expect(prepared.setup.config.vocabulary == ["terme-un", "terme-deux"])
        #expect(prepared.setup.transcription.vocabulary == ["terme-un", "terme-deux"])
        #expect(rig.catalog.ensured.isEmpty)
        _ = try await rig.live.environment.makeConversation(prepared.setup)
        #expect(try #require(rig.made.parts.first).setup.config.vocabulary == ["terme-un", "terme-deux"])
    }

    @Test("I-1 : WhisperKit, liste trop longue pour l'amorce : les premiers termes qui tiennent, comme la dictée, et l'avis le dit")
    func withWhisperKitATooLongListIsTrimmed() async throws {
        let rig = Self.rig()
        // Chaque terme vaut la moitié de la limite : deux tiennent, trois non.
        let perTerm = rig.engines.environment.promptTokenLimit / 2
        rig.catalog.countTokens { $0.count * perTerm }
        let prepared = try await rig.live.environment.prepare(
            Self.setup(engine: .whisperKit, vocabulary: ["terme-un", "terme-deux", "terme-trois"]))
        #expect(prepared.setup.config.vocabulary == ["terme-un", "terme-deux"])
        #expect(prepared.setup.transcription.vocabulary == ["terme-un", "terme-deux"])
        #expect(prepared.notice == InterviewText.vocabularyTrimmed(kept: 2, of: 3))
        _ = try await rig.live.environment.makeConversation(prepared.setup)
        #expect(try #require(rig.made.parts.first).setup.config.vocabulary == ["terme-un", "terme-deux"])
    }

    @Test("I-1 : WhisperKit, longueur impossible à compter : aucun terme, comme la dictée, et l'avis le dit")
    func withWhisperKitAnUncountableListIsDropped() async throws {
        let rig = Self.rig()
        let prepared = try await rig.live.environment.prepare(
            Self.setup(engine: .whisperKit, vocabulary: ["terme-un", "terme-deux"]))
        #expect(prepared.setup.config.vocabulary.isEmpty)
        #expect(prepared.setup.transcription.vocabulary.isEmpty)
        #expect(prepared.notice == InterviewText.vocabularyUncountable)
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

    // MARK: - La voix désignée et la forme normalisée (tâche 2 de l'étape « voix »)

    static let voiceProviderID = UUID(uuidString: "00000000-0000-0000-0000-00000000E0B1")!

    static let resolvedVoiceProvider = ResolvedProvider(
        kind: .openAICompatible, config: EndpointConfig(baseURL: URL(string: "https://example.com/v1")!, apiKey: "cle-exemple"),
        name: "Fournisseur d'exemple")

    /// Des réglages écrits à la main : un fournisseur (modèles et voix), et la voix donnée, telle quelle.
    static func handWrittenSettings(voice: String) throws -> AppSettings {
        let json = #"""
            {"version":3,
             "providers":[{"id":"00000000-0000-0000-0000-00000000E0B1","name":"Fournisseur d'exemple","baseURL":"https://example.com/v1","kind":"openAICompatible","models":["modele-exemple"]}],
             "fastModel":{"providerID":"00000000-0000-0000-0000-00000000E0B1","model":"modele-exemple"},
             "strongModel":{"providerID":"00000000-0000-0000-0000-00000000E0B1","model":"modele-exemple"},
             "voice":
            """# + voice + "}"
        return try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    /// La résolution réelle de l'entretien, avec la fabrique de voix réelle (`LiveInterview.makeVoice`) branchée sur les doubles :
    /// clé en mémoire, aucun réseau, aucun modèle.
    @MainActor
    static func resolve(_ settings: AppSettings, with rig: Rig) async throws -> InterviewSetup {
        let store = InMemorySecretStore(secrets: [voiceProviderID.uuidString: "cle-exemple"])
        return try await InterviewSetup.resolve(
            settings: settings, engine: nil, secrets: SecretAccess(store, queue: DispatchQueue(label: "test.live.\(UUID())")),
            makeModel: { _, _ in SilentModel() }, makeVoice: rig.live.environment.makeVoice)
    }

    /// Règle 3 : ce qui part au fournisseur est la forme normalisée, même quand le fichier porte à la main des clés réservées, des
    /// clés vides et des espaces : aucune clé réservée n'arrive à la fabrique de la voix du fournisseur.
    @MainActor
    @Test func reservedKeysNeverReachTheProvider() async throws {
        let settings = try Self.handWrittenSettings(
            voice: #"{"providerID":"00000000-0000-0000-0000-00000000E0B1","model":" modele-voix-exemple ","identifier":"voix-exemple ","language":"fr-FR","extra":{"model":"x","input":"x","voice":"x","response_format":"mp3"," model":"x","":"x"," cle-exemple ":"valeur-exemple"}}"#)
        #expect(settings.voice.extra["model"] == "x", "le fichier porte bien les clés réservées")
        let rig = Self.rig()

        let setup = try await Self.resolve(settings, with: rig)

        #expect(setup.voiceProviderName == "Fournisseur d'exemple")
        let made = try #require(rig.made.providerVoices.first)
        #expect(rig.made.providerVoices.count == 1)
        #expect(made.voice == ProviderVoice(model: "modele-voix-exemple", identifier: "voix-exemple", extra: ["cle-exemple": "valeur-exemple"]))
        #expect(VoiceChoice.reservedExtraKeys.isDisjoint(with: made.voice.extra.keys))
    }

    struct SystemFactoryCase: Sendable, CustomTestStringConvertible {
        let name: String
        let choice: VoiceChoice
        let provider: ResolvedProvider?
        /// `nil` : la fabrique du système n'est pas appelée ; sinon, langue et identifiant reçus.
        let system: (language: String, identifier: String?)?
        var testDescription: String { name }
    }

    static let systemFactoryCases: [SystemFactoryCase] = [
        SystemFactoryCase(
            name: "voix du système désignée", choice: VoiceChoice(identifier: "voix.exemple.a", language: "fr-CA"), provider: nil,
            system: ("fr-CA", "voix.exemple.a")),
        SystemFactoryCase(
            name: "voix du système sans identifiant", choice: VoiceChoice(language: "fr-CA"), provider: nil, system: ("fr-CA", nil)),
        SystemFactoryCase(
            name: "voix de fournisseur sans fournisseur résolu : repli sans identifiant",
            choice: VoiceChoice(providerID: voiceProviderID, model: "modele-voix-exemple", identifier: "voix-exemple", language: "fr-CA"),
            provider: nil, system: ("fr-CA", nil)),
        SystemFactoryCase(
            name: "voix de fournisseur, fournisseur sans synthèse : repli sans identifiant",
            choice: VoiceChoice(providerID: voiceProviderID, model: "modele-voix-exemple", identifier: "voix-exemple", language: "fr-CA"),
            provider: ResolvedProvider(kind: .anthropic, config: resolvedVoiceProvider.config, name: "Fournisseur d'exemple"),
            system: ("fr-CA", nil)),
        SystemFactoryCase(
            name: "voix de fournisseur résolue : la fabrique du système n'est pas appelée",
            choice: VoiceChoice(providerID: voiceProviderID, model: "modele-voix-exemple", identifier: "voix-exemple", language: "fr-CA"),
            provider: resolvedVoiceProvider, system: nil),
    ]

    /// Règle 5 : `makeVoice(choix, nil)` passe l'identifiant du choix à la fabrique de la voix du système ; tout repli d'une voix de
    /// fournisseur lui passe `nil` (un identifiant de fournisseur ne désigne pas une voix du système).
    @Test(arguments: systemFactoryCases)
    func theSystemIdentifierReachesTheFactoryOnlyForASystemVoice(_ example: SystemFactoryCase) {
        let rig = Self.rig()
        _ = rig.live.environment.makeVoice(example.choice, example.provider)
        if let system = example.system {
            #expect(rig.made.systemVoices == [system.language])
            #expect(rig.made.systemIdentifiers == [system.identifier])
            #expect(rig.made.providerVoices.isEmpty)
        } else {
            #expect(rig.made.systemVoices.isEmpty)
            #expect(rig.made.providerVoices.count == 1)
        }
    }

    /// Règle 5, par la résolution réelle : une voix du système garde son identifiant (rogné) jusqu'à la fabrique ; une voix de
    /// fournisseur résolue fabrique son secours sans identifiant ; une voix de fournisseur qui retombe (fournisseur supprimé) aussi.
    @MainActor
    @Test func throughTheResolutionOnlyASystemVoiceKeepsItsIdentifier() async throws {
        let system = Self.rig()
        _ = try await Self.resolve(
            try Self.handWrittenSettings(voice: #"{"identifier":" voix.exemple.a ","language":"fr-CA"}"#), with: system)
        #expect(system.made.systemIdentifiers == ["voix.exemple.a"])
        #expect(system.made.systemVoices == ["fr-CA"])

        let provider = Self.rig()
        _ = try await Self.resolve(
            try Self.handWrittenSettings(
                voice: #"{"providerID":"00000000-0000-0000-0000-00000000E0B1","model":"modele-voix-exemple","identifier":"voix-exemple","language":"fr-CA"}"#),
            with: provider)
        #expect(provider.made.providerVoices.count == 1)
        #expect(provider.made.systemIdentifiers == [nil], "le secours de la voix du fournisseur")

        let removed = Self.rig()
        _ = try await Self.resolve(
            try Self.handWrittenSettings(
                voice: #"{"providerID":"00000000-0000-0000-0000-00000000E0B9","model":"modele-voix-exemple","identifier":"voix-exemple","language":"fr-CA"}"#),
            with: removed)
        #expect(removed.made.providerVoices.isEmpty)
        #expect(removed.made.systemIdentifiers == [nil])
        #expect(removed.made.systemVoices == ["fr-CA"])
    }

    @Test("l'assemblage réel donne la façade du moteur, sans la démarrer")
    func theRealAssemblyIsTheSessionFacade() {
        let parts = LiveInterview.Parts(
            audio: ScriptedAudioIO(), detector: DoubleDetector(offlineProbe: { false }),
            transcriber: DoubleTranscriber(name: "double", text: "texte", offlineProbe: { false }), setup: Self.setup())
        #expect(LiveInterview.session(parts) is ConversationSession)
    }
}
