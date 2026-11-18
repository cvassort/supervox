import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Un trousseau par compte : chaque compte a sa clé, peut refuser (`denied`) ou ne pas répondre tant que le test ne le libère pas
/// (`held`). Note les comptes lus, dans l'ordre.
final class SetupAccountStore: SecretStore {
    private let keys: [String: String]
    private let denied: Set<String>
    private let held: Set<String>
    let asked = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    private let reads = Mutex<[String]>([])

    init(keys: [UUID: String] = [:], denied: Set<UUID> = [], held: Set<UUID> = []) {
        self.keys = Dictionary(uniqueKeysWithValues: keys.map { ($0.key.uuidString, $0.value) })
        self.denied = Set(denied.map(\.uuidString))
        self.held = Set(held.map(\.uuidString))
    }

    var readAccounts: [String] { reads.withLock { $0 } }

    func read(account: String) throws -> String? {
        reads.withLock { $0.append(account) }
        if held.contains(account) {
            asked.withLock { $0 = true }
            release.wait()
        }
        if denied.contains(account) { throw SecretError.denied }
        return keys[account]
    }
    func write(_ secret: String, account: String) throws {}
    func delete(account: String) throws {}
    func contains(account: String) throws -> Bool { keys[account] != nil }
}

/// Une voix double : rend un clip d'un seul échantillon (sa valeur dit qui a parlé), ou lève.
final class SetupMarkedVoice: SpeechSynthesizer {
    let mark: Float
    let fails: Bool
    init(mark: Float, fails: Bool = false) {
        self.mark = mark
        self.fails = fails
    }
    func synthesize(_ text: String) async throws -> Speech {
        if fails { throw SpeechError.timedOut }
        return Speech(clip: AudioClip(samples: [mark], sampleRate: 16_000))
    }
}

/// Ce que `makeVoice` a reçu, et les voix rendues : 1 pour celle du fournisseur, 2 pour celle du système.
final class SetupVoiceFactory: Sendable {
    struct Call: Equatable {
        var choice: VoiceChoice
        var providerName: String?
    }
    private let state = Mutex<[Call]>([])
    private let primaryFails: Bool
    let system = SetupMarkedVoice(mark: 2)
    let provider: SetupMarkedVoice

    init(primaryFails: Bool = false) {
        self.primaryFails = primaryFails
        provider = SetupMarkedVoice(mark: 1, fails: primaryFails)
    }

    var calls: [Call] { state.withLock { $0 } }

    var make: @Sendable (VoiceChoice, ResolvedProvider?) -> any SpeechSynthesizer {
        { [self] choice, resolved in
            state.withLock { $0.append(Call(choice: choice, providerName: resolved?.name)) }
            return resolved == nil ? system : provider
        }
    }
}

/// Ce que `makeModel` a reçu, et un modèle double distinct par fournisseur (reconnu à son adresse).
final class SetupModelFactory: Sendable {
    struct Made: Equatable {
        var kind: ProviderKind
        var baseURL: URL
        var apiKey: String
    }
    private let state = Mutex<[Made]>([])
    private let models = Mutex<[URL: ScriptedModel]>([:])

    var made: [Made] { state.withLock { $0 } }

    func model(at url: URL) -> ScriptedModel? { models.withLock { $0[url] } }

    var make: @Sendable (ProviderKind, EndpointConfig) -> any LanguageModel {
        { [self] kind, config in
            state.withLock { $0.append(Made(kind: kind, baseURL: config.baseURL, apiKey: config.apiKey)) }
            return models.withLock { models in
                if let existing = models[config.baseURL] { return existing }
                let made = ScriptedModel(.never)
                models[config.baseURL] = made
                return made
            }
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct InterviewSetupTests {
    // Deux fournisseurs aux adresses différentes : le modèle rapide chez l'un, le fort chez l'autre. Une troisième adresse porte la voix.
    let fastProvider = Provider(
        id: UUID(), name: "Fournisseur d'exemple", baseURL: "https://exemple.invalid/rapide", kind: .openAICompatible,
        models: ["modele-exemple-rapide"])
    let strongProvider = Provider(
        id: UUID(), name: "Second d'exemple", baseURL: "https://exemple.invalid/fort", kind: .anthropic,
        models: ["modele-exemple-fort"])
    let voiceProvider = Provider(
        id: UUID(), name: "Voix d'exemple", baseURL: "https://exemple.invalid/voix", kind: .openAICompatible, models: [])

    var fastChoice: ModelChoice { ModelChoice(providerID: fastProvider.id, model: "modele-exemple-rapide") }
    var strongChoice: ModelChoice { ModelChoice(providerID: strongProvider.id, model: "modele-exemple-fort") }

    var providerVoice: VoiceChoice {
        VoiceChoice(
            providerID: voiceProvider.id, model: "voix-exemple-modele", identifier: "voix-exemple", language: "fr-FR",
            gender: .female, extra: ["reglage": "valeur"])
    }

    func settings(
        fast: ModelChoice?? = .none, strong: ModelChoice?? = .none, voice: VoiceChoice = .system,
        providers: [Provider]? = nil
    ) -> AppSettings {
        var settings = AppSettings.defaults
        settings.providers = providers ?? [fastProvider, strongProvider, voiceProvider]
        // `.none` : le choix d'exemple ; `.some(nil)` : aucun choix.
        if let fast { settings.fastModel = fast } else { settings.fastModel = fastChoice }
        if let strong { settings.strongModel = strong } else { settings.strongModel = strongChoice }
        settings.voice = voice
        return settings
    }

    func keys() -> [UUID: String] {
        [fastProvider.id: "cle-rapide", strongProvider.id: "cle-forte", voiceProvider.id: "cle-voix"]
    }

    func access(_ store: SetupAccountStore) -> SecretAccess {
        SecretAccess(store, queue: DispatchQueue(label: "test.setup.\(UUID())"))
    }

    func resolve(
        _ settings: AppSettings, engine: TranscriptionEngine? = nil, store: SetupAccountStore? = nil,
        models: SetupModelFactory = SetupModelFactory(), voices: SetupVoiceFactory = SetupVoiceFactory()
    ) async throws -> InterviewSetup {
        try await InterviewSetup.resolve(
            settings: settings, engine: engine, secrets: access(store ?? SetupAccountStore(keys: keys())),
            makeModel: models.make, makeVoice: voices.make)
    }

    // MARK: - La clé ne se laisse pas voir

    /// Un client qui tient sa configuration comme le vrai (`OpenAICompatibleClient` garde un `EndpointConfig`) : le reflet de
    /// l'`InterviewSetup` passe donc par lui.
    struct ConfigHoldingModel: LanguageModel {
        let config: EndpointConfig
        func complete(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    /// Les trois façons d'afficher une valeur : `String(describing:)`, `String(reflecting:)` et `dump`.
    static func displays(_ value: Any) -> [String] {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), dumped]
    }

    @Test("un fournisseur résolu ne montre jamais sa clé : ni description, ni reflet, ni dump")
    func aResolvedProviderNeverShowsItsKey() async throws {
        let store = SetupAccountStore(keys: [fastProvider.id: "cle-double-reconnaissable-123"])

        let resolved = try await ProviderResolver.resolve(fastProvider.id, settings: settings(), secrets: access(store))

        #expect(resolved.config.apiKey == "cle-double-reconnaissable-123", "la clé est bien là, pour le client")
        for text in Self.displays(resolved) {
            #expect(!text.contains("cle-double-reconnaissable-123"), "la clé apparaît : \(text.prefix(300))")
        }
    }

    @Test("une préparation d'entretien ne montre aucune clé : ni description, ni reflet, ni dump")
    func anInterviewSetupNeverShowsAKey() async throws {
        let keys = [
            fastProvider.id: "cle-double-rapide-456", strongProvider.id: "cle-double-forte-789",
            voiceProvider.id: "cle-double-voix-012",
        ]

        let setup = try await InterviewSetup.resolve(
            settings: settings(voice: providerVoice), engine: nil, secrets: access(SetupAccountStore(keys: keys)),
            makeModel: { _, config in ConfigHoldingModel(config: config) }, makeVoice: SetupVoiceFactory().make)

        let held = try #require(setup.fastModel as? ConfigHoldingModel)
        #expect(held.config.apiKey == "cle-double-rapide-456", "le client tient bien sa clé")
        for text in Self.displays(setup) {
            for key in keys.values { #expect(!text.contains(key), "une clé apparaît : \(text.prefix(300))") }
        }
    }

    // MARK: - Les modèles

    @Test("le modèle rapide et le modèle fort viennent chacun de leur fournisseur, avec leur nom de modèle et leur clé")
    func eachModelIsBuiltFromItsOwnProvider() async throws {
        let models = SetupModelFactory()
        let fastURL = try #require(URL(string: "https://exemple.invalid/rapide"))
        let strongURL = try #require(URL(string: "https://exemple.invalid/fort"))

        let setup = try await resolve(settings(), models: models)

        #expect(
            models.made == [
                .init(kind: .openAICompatible, baseURL: fastURL, apiKey: "cle-rapide"),
                .init(kind: .anthropic, baseURL: strongURL, apiKey: "cle-forte"),
            ])
        let fast = try #require(models.model(at: fastURL))
        let strong = try #require(models.model(at: strongURL))
        #expect((setup.fastModel as AnyObject) === fast)
        #expect((setup.strongModel as AnyObject) === strong)
        #expect(setup.config.fastModel == "modele-exemple-rapide")
        #expect(setup.config.strongModel == "modele-exemple-fort")
    }

    @Test("la vie privée nomme le fournisseur du modèle rapide, qui reçoit les réponses de la personne")
    func theProviderNameIsTheFastModelsProvider() async throws {
        let setup = try await resolve(settings())
        #expect(setup.providerName == "Fournisseur d'exemple")
    }

    @Test("sans modèle rapide : refus, avant toute lecture du trousseau et tout client")
    func withoutAFastModelTheSetupIsRefusedBeforeTheKeychainIsRead() async {
        let store = SetupAccountStore(keys: keys())
        let models = SetupModelFactory()

        await #expect(throws: InterviewSetupFailure.noFastModel) {
            try await resolve(settings(fast: .some(nil)), store: store, models: models)
        }
        #expect(store.readAccounts.isEmpty)
        #expect(models.made.isEmpty)
    }

    @Test("sans modèle fort : refus, avant toute lecture du trousseau et tout client")
    func withoutAStrongModelTheSetupIsRefusedBeforeTheKeychainIsRead() async {
        let store = SetupAccountStore(keys: keys())
        let models = SetupModelFactory()

        await #expect(throws: InterviewSetupFailure.noStrongModel) {
            try await resolve(settings(strong: .some(nil)), store: store, models: models)
        }
        #expect(store.readAccounts.isEmpty)
        #expect(models.made.isEmpty)
    }

    @Test func withNeitherModelTheFastOneIsReportedFirst() async {
        await #expect(throws: InterviewSetupFailure.noFastModel) {
            try await resolve(settings(fast: .some(nil), strong: .some(nil)))
        }
    }

    @Test func aFastModelWhoseProviderIsGoneIsProviderMissingAndNothingIsRead() async {
        let store = SetupAccountStore(keys: keys())
        let gone = ModelChoice(providerID: UUID(), model: "modele-exemple-rapide")

        await #expect(throws: InterviewSetupFailure.provider(.providerMissing)) {
            try await resolve(settings(fast: .some(gone)), store: store)
        }
        #expect(store.readAccounts.isEmpty)
    }

    @Test func aStrongModelWithoutAKeyIsNoKeyNamingItsProvider() async {
        let store = SetupAccountStore(keys: [fastProvider.id: "cle-rapide"])

        await #expect(throws: InterviewSetupFailure.provider(.noKey(provider: "Second d'exemple"))) {
            try await resolve(settings(), store: store)
        }
    }

    @Test func aRefusedAddressIsUnreachableAndItsKeyIsNotRead() async {
        var bad = fastProvider
        bad.baseURL = "http://exemple.invalid/rapide"
        let store = SetupAccountStore(keys: keys())

        await #expect(throws: InterviewSetupFailure.provider(.unreachable)) {
            try await resolve(settings(providers: [bad, strongProvider, voiceProvider]), store: store)
        }
        #expect(store.readAccounts.isEmpty)
    }

    @Test func aKeychainThatRefusesIsKeychain() async {
        let store = SetupAccountStore(keys: keys(), denied: [strongProvider.id])

        await #expect(throws: InterviewSetupFailure.provider(.keychain)) {
            try await resolve(settings(), store: store)
        }
    }

    // MARK: - Le moteur, la configuration

    @Test("sans moteur donné, celui de l'entretien ; un moteur donné est gardé")
    func theEngineDefaultsToTheInterviewEngine() async throws {
        #expect(TranscriptionEngine.interviewDefault != .whisperKit, "le test n'a de sens que si les deux diffèrent")
        let byDefault = try await resolve(settings(), engine: nil)
        let chosen = try await resolve(settings(), engine: .whisperKit)

        #expect(byDefault.engine == .interviewDefault)
        #expect(chosen.engine == .whisperKit)
    }

    @Test("la configuration reprend les réglages de la transcription (langue, vocabulaire) et ceux de l'entretien")
    func theConfigCarriesTheTranscriptionAndInterviewSettings() async throws {
        var current = settings()
        current.transcription.language = "en"
        current.transcription.vocabulary = ["terme-exemple", "autre-terme"]
        current.interview = InterviewSettings(
            maxQuestions: 5, template: "Gabarit d'exemple.", turnSilence: 0.8, interruptMinDuration: 0.4, interruptLevel: -25)

        let setup = try await resolve(current)

        #expect(setup.config.language == "en")
        #expect(setup.config.vocabulary == ["terme-exemple", "autre-terme"])
        #expect(setup.config.maxQuestions == 5)
        #expect(setup.config.template == "Gabarit d'exemple.")
        #expect(setup.config.interruptMinDuration == 0.4)
        #expect(setup.config.interruptLevel == -25)
        #expect(setup.turnSilence == 0.8)
    }

    @Test("sans gabarit, ou avec un gabarit blanc, celui d'origine")
    func withoutATemplateTheDefaultOneIsUsed() async throws {
        for template in [nil, " \n\t "] as [String?] {
            var current = settings()
            current.interview.template = template

            let setup = try await resolve(current)

            #expect(setup.config.template == InterviewPrompt.defaultTemplate, "gabarit : \(String(describing: template))")
        }
    }

    @Test("les réglages hors bornes (posés en mémoire) sont ramenés dans leurs bornes avant d'être employés")
    func theInterviewSettingsAreNormalizedBeforeUse() async throws {
        var current = settings()
        current.interview = InterviewSettings(
            maxQuestions: 99, template: nil, turnSilence: 9, interruptMinDuration: 0, interruptLevel: 0)

        let setup = try await resolve(current)

        #expect(setup.config.maxQuestions == InterviewSettings.maxQuestionsRange.upperBound)
        #expect(setup.turnSilence == InterviewSettings.turnSilenceRange.upperBound)
        #expect(setup.config.interruptMinDuration == InterviewSettings.interruptMinDurationRange.lowerBound)
        #expect(setup.config.interruptLevel == InterviewSettings.interruptLevelRange.upperBound)
    }

    // MARK: - La voix

    @Test("une voix du système : le système seul, tel que choisi, sans fournisseur ni lecture de clé de voix")
    func aSystemVoiceIsTheSystemVoiceAlone() async throws {
        let voices = SetupVoiceFactory()
        let store = SetupAccountStore(keys: keys())
        let system = VoiceChoice(identifier: "voix-systeme-exemple", language: "fr-CA")

        let setup = try await resolve(settings(voice: system), store: store, voices: voices)

        #expect((setup.voice as AnyObject) === voices.system)
        #expect(voices.calls == [.init(choice: system, providerName: nil)])
        #expect(setup.voiceProviderName == nil)
        #expect(Set(store.readAccounts) == [fastProvider.id.uuidString, strongProvider.id.uuidString])
    }

    @Test("une voix de fournisseur résolue : la voix du fournisseur, et à son défaut celle du système (jamais l'inverse)")
    func aProviderVoiceFallsBackOnTheSystemVoice() async throws {
        let working = SetupVoiceFactory()
        let setup = try await resolve(settings(voice: providerVoice), voices: working)
        let first = try await setup.voice.synthesize("Bonjour.")
        #expect(first.clip.samples == [1], "la voix du fournisseur parle d'abord")
        #expect(!first.fellBack)
        #expect(setup.voiceProviderName == "Voix d'exemple")

        let failing = SetupVoiceFactory(primaryFails: true)
        let fallen = try await resolve(settings(voice: providerVoice), voices: failing)
        let second = try await fallen.voice.synthesize("Bonjour.")
        #expect(second.clip.samples == [2], "la voix du fournisseur échoue : le système parle")
        #expect(second.fellBack)
    }

    @Test("la voix du fournisseur reçoit le fournisseur résolu ; le repli reçoit un choix sans rien du fournisseur")
    func theFallbackVoiceGetsAChoiceWithNothingFromTheProvider() async throws {
        let voices = SetupVoiceFactory()

        _ = try await resolve(settings(voice: providerVoice), voices: voices)

        let systemChoice = VoiceChoice(providerID: nil, model: nil, identifier: nil, language: "fr-FR", gender: .female, extra: [:])
        #expect(
            voices.calls == [
                .init(choice: providerVoice, providerName: "Voix d'exemple"),
                .init(choice: systemChoice, providerName: nil),
            ])
    }

    @Test("une voix d'un fournisseur au format Anthropic (pas de synthèse) : le système, sans échec ni lecture de sa clé")
    func anAnthropicVoiceProviderGivesTheSystemVoiceWithoutReadingItsKey() async throws {
        var anthropicVoice = voiceProvider
        anthropicVoice.kind = .anthropic
        let voices = SetupVoiceFactory()
        let store = SetupAccountStore(keys: keys())

        let setup = try await resolve(
            settings(voice: providerVoice, providers: [fastProvider, strongProvider, anthropicVoice]), store: store,
            voices: voices)

        #expect((setup.voice as AnyObject) === voices.system)
        #expect(setup.voiceProviderName == nil)
        #expect(!store.readAccounts.contains(voiceProvider.id.uuidString), "aucune invite du trousseau pour une voix sans synthèse")
        #expect(voices.calls.allSatisfy { $0.providerName == nil })
    }

    @Test("une voix de fournisseur qui ne se résout pas donne le système, sans échec")
    func anUnresolvableProviderVoiceGivesTheSystemVoice() async throws {
        var badAddress = voiceProvider
        badAddress.baseURL = "pas une adresse"
        var noModel = providerVoice
        noModel.model = nil
        var blankIdentifier = providerVoice
        blankIdentifier.identifier = " "
        let cases: [(String, AppSettings, SetupAccountStore)] = [
            (
                "fournisseur disparu",
                settings(voice: providerVoice, providers: [fastProvider, strongProvider]), SetupAccountStore(keys: keys())
            ),
            (
                "adresse refusée",
                settings(voice: providerVoice, providers: [fastProvider, strongProvider, badAddress]), SetupAccountStore(keys: keys())
            ),
            (
                "clé absente", settings(voice: providerVoice),
                SetupAccountStore(keys: [fastProvider.id: "cle-rapide", strongProvider.id: "cle-forte"])
            ),
            ("trousseau qui refuse", settings(voice: providerVoice), SetupAccountStore(keys: keys(), denied: [voiceProvider.id])),
            ("modèle de voix absent", settings(voice: noModel), SetupAccountStore(keys: keys())),
            ("identifiant de voix blanc", settings(voice: blankIdentifier), SetupAccountStore(keys: keys())),
        ]
        for (name, current, store) in cases {
            let voices = SetupVoiceFactory()

            let setup = try await resolve(current, store: store, voices: voices)

            #expect((setup.voice as AnyObject) === voices.system, "\(name)")
            #expect(setup.voiceProviderName == nil, "\(name) : la ligne de vie privée ne doit pas nommer une voix qui ne parle pas")
        }
    }

    @Test("annulée pendant la lecture de la clé de la voix, la résolution lève l'annulation et ne se rabat pas sur le système")
    func cancellationWhileResolvingTheVoiceIsNotSwallowed() async throws {
        let store = SetupAccountStore(keys: keys(), held: [voiceProvider.id])
        let access = access(store)
        let current = settings(voice: providerVoice)
        let models = SetupModelFactory()
        let voices = SetupVoiceFactory()

        let task = Task { @MainActor in
            try await InterviewSetup.resolve(
                settings: current, engine: nil, secrets: access, makeModel: models.make, makeVoice: voices.make)
        }
        #expect(await until { store.asked.withLock { $0 } })
        task.cancel()
        store.release.signal()

        let result = try #require(await bounded(task), "la résolution annulée ne rend pas la main")
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(voices.calls.isEmpty, "aucune voix n'est fabriquée pour un entretien annulé")
    }

    // MARK: - L'environnement indisponible

    @Test("InterviewEnvironment.unavailable : préparer comme construire lèvent")
    func theUnavailableEnvironmentThrowsOnBothClosures() async throws {
        let setup = try await resolve(settings())
        let environment = InterviewEnvironment.unavailable

        await #expect(throws: InterviewEnvironment.Unavailable.self) { try await environment.prepare(setup) }
        await #expect(throws: InterviewEnvironment.Unavailable.self) { _ = try await environment.makeConversation(setup) }
        let voice = environment.makeVoice(.system, nil)
        await #expect(throws: InterviewEnvironment.Unavailable.self) { _ = try await voice.synthesize("Bonjour.") }
    }

    // MARK: - Ce que la préparation porte pour la suite (amendement I)

    @Test("amendement I : le fournisseur du modèle fort est nommé à part, et la vie privée nomme les deux quand ils diffèrent")
    func theStrongProviderIsNamedAndThePrivacyLineNamesBoth() async throws {
        let setup = try await resolve(settings())
        #expect(setup.providerName == "Fournisseur d'exemple")
        #expect(setup.strongProviderName == "Second d'exemple")
        #expect(
            setup.privacy
                == "Le texte de vos réponses part chez «\u{00A0}Fournisseur d'exemple\u{00A0}» et «\u{00A0}Second d'exemple\u{00A0}»\u{00A0}; l'audio du micro reste sur cet ordinateur.")

        let same = try await resolve(settings(strong: .some(ModelChoice(providerID: fastProvider.id, model: "modele-exemple-fort"))))
        #expect(same.strongProviderName == "Fournisseur d'exemple")
        #expect(
            same.privacy
                == "Le texte de vos réponses part chez «\u{00A0}Fournisseur d'exemple\u{00A0}»\u{00A0}; l'audio du micro reste sur cet ordinateur.")

        let voiced = try await resolve(settings(voice: providerVoice))
        #expect(
            voiced.privacy
                == "Le texte de vos réponses part chez «\u{00A0}Fournisseur d'exemple\u{00A0}» et «\u{00A0}Second d'exemple\u{00A0}»\u{00A0}; l'audio du micro reste sur cet ordinateur. Le texte que dit Supervox part chez «\u{00A0}Voix d'exemple\u{00A0}».")
    }

    @Test("amendement I : les réglages de transcription suivent la préparation, avec le moteur de l'entretien")
    func theTranscriptionSettingsTravelWithTheEngineOfTheInterview() async throws {
        var base = settings()
        base.transcription = TranscriptionSettings(
            engine: .whisperKit, whisperModel: "variante-exemple", language: "fr", vocabulary: ["Supervox"])
        let setup = try await resolve(base, engine: .parakeet)
        #expect(setup.transcription.engine == .parakeet)
        #expect(setup.transcription.whisperModel == "variante-exemple")
        #expect(setup.transcription.vocabulary == ["Supervox"])

        let whisper = try await resolve(base, engine: .whisperKit)
        #expect(whisper.transcription.engine == .whisperKit)
        #expect(whisper.engine == .whisperKit)
    }
}
