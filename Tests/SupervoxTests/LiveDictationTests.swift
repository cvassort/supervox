import Foundation
import Synchronization
import SupervoxApp
import SupervoxCore
import SupervoxEngines
import Testing

@testable import Supervox

/// Ce que la cible `Supervox` décide seule : de quels modèles une dictée a besoin et quand elle déclare un téléchargement,
/// le téléchargement par le catalogue, les moteurs gardés d'une dictée à l'autre et leur abandon quand un modèle est
/// supprimé. Aucun moteur n'est chargé, aucun disque lu, aucun réseau : le catalogue est un double.
@Suite(.timeLimit(.minutes(1))) struct LiveDictationTests {
    private static func model(_ id: String, _ state: LocalModel.State) -> LocalModel {
        LocalModel(id: id, title: id, detail: "", state: state)
    }

    private static func settings(
        engine: String = "whisperkit", model: String = "small", vocabulary: [String] = []
    ) -> TranscriptionSettings {
        TranscriptionSettings(engine: engine, whisperModel: model, language: "fr", vocabulary: vocabulary)
    }

    /// Un catalogue double : états réglés par le test, appels gardés.
    final class StubCatalog: ModelCatalog {
        struct State {
            var states: [String: LocalModel.State]
            var ensured: [String] = []
            var deleted: [String] = []
            var ensureError: (any Error)?
            var deleteError: (any Error)?
        }

        let state: Mutex<State>

        init(_ states: [String: LocalModel.State]) { state = Mutex(State(states: states)) }

        static let allReady: [String: LocalModel.State] = [
            LocalModelID.voiceDetector: .ready, LocalModelID.parakeet: .ready,
            LocalModelID.whisper("small"): .ready, LocalModelID.parakeetVocabulary: .ready,
        ]

        var ensured: [String] { state.withLock { $0.ensured } }
        var deleted: [String] { state.withLock { $0.deleted } }
        func set(_ id: String, _ value: LocalModel.State?) { state.withLock { $0.states[id] = value } }
        func failEnsure(_ error: (any Error)?) { state.withLock { $0.ensureError = error } }
        func failDelete(_ error: (any Error)?) { state.withLock { $0.deleteError = error } }

        func models() async -> [LocalModel] {
            // Le petit modèle de vocabulaire n'est pas une ligne de la liste.
            state.withLock { state in
                state.states.filter { $0.key != LocalModelID.parakeetVocabulary }
                    .map { LocalModel(id: $0.key, title: $0.key, detail: "", state: $0.value) }
            }
        }
        func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
        func ensureDownloaded(_ id: String) async throws {
            try state.withLock { state in
                state.ensured.append(id)
                if let error = state.ensureError { throw error }
            }
        }
        func state(of id: String) async -> LocalModel.State? { state.withLock { $0.states[id] } }
        func delete(_ id: String) async throws {
            try state.withLock { state in
                if let error = state.deleteError { throw error }
                state.deleted.append(id)
            }
        }
        func promptTokenCount(_ vocabulary: [String], whisperModel: String) async -> Int? { nil }
    }

    struct Refused: Error {}

    // MARK: - Modèles nécessaires

    @Test func aWhisperDictationNeedsTheVoiceDetectorParakeetAndTheChosenVariant() {
        #expect(
            LiveDictationEngines.neededModels(for: Self.settings())
                == [LocalModelID.voiceDetector, LocalModelID.parakeet, LocalModelID.whisper("small")])
    }

    @Test func aParakeetDictationDoesNotNeedAWhisperVariant() {
        #expect(
            LiveDictationEngines.neededModels(for: Self.settings(engine: "parakeet"))
                == [LocalModelID.voiceDetector, LocalModelID.parakeet])
    }

    /// Le petit modèle de vocabulaire ne sert qu'avec un vocabulaire, quel que soit le moteur final (l'aperçu est Parakeet).
    @Test(arguments: ["whisperkit", "parakeet"])
    func theVocabularyModelIsNeededOnlyWithAVocabulary(engine: String) {
        let with = LiveDictationEngines.neededModels(for: Self.settings(engine: engine, vocabulary: ["terme"]))
        let without = LiveDictationEngines.neededModels(for: Self.settings(engine: engine))
        #expect(with.last == LocalModelID.parakeetVocabulary)
        #expect(!without.contains(LocalModelID.parakeetVocabulary))
    }

    // MARK: - Quand un téléchargement est déclaré (I4)

    private static func missing(_ settings: TranscriptionSettings, _ states: [String: LocalModel.State]) -> [String] {
        LiveDictationEngines.missingModels(for: settings, state: { states[$0] })
    }

    @Test func nothingIsMissingWhenEveryNeededModelIsReady() {
        #expect(Self.missing(Self.settings(), StubCatalog.allReady).isEmpty)
    }

    /// La configuration par défaut (vocabulaire vide) : le petit modèle de vocabulaire absent ne déclenche aucune mention.
    @Test func withoutAVocabularyAMissingVocabularyModelIsNotADownload() {
        var states = StubCatalog.allReady
        states[LocalModelID.parakeetVocabulary] = .absent
        #expect(Self.missing(Self.settings(), states).isEmpty)
        #expect(Self.missing(Self.settings(engine: "parakeet"), states).isEmpty)
    }

    @Test(arguments: ["whisperkit", "parakeet"])
    func withAVocabularyAMissingVocabularyModelIsADownload(engine: String) {
        var states = StubCatalog.allReady
        states[LocalModelID.parakeetVocabulary] = .absent
        #expect(
            Self.missing(Self.settings(engine: engine, vocabulary: ["terme"]), states)
                == [LocalModelID.parakeetVocabulary])
        states[LocalModelID.parakeetVocabulary] = .ready
        #expect(Self.missing(Self.settings(engine: engine, vocabulary: ["terme"]), states).isEmpty)
    }

    @Test(arguments: [
        LocalModel.State.absent, .incomplete, .downloading(nil), .downloading(0.5), .failed("échec"),
    ])
    func aChosenVariantThatIsNotReadyIsMissing(_ state: LocalModel.State) {
        var states = StubCatalog.allReady
        states[LocalModelID.whisper("small")] = state
        #expect(Self.missing(Self.settings(), states) == [LocalModelID.whisper("small")])
    }

    @Test func parakeetOrTheVoiceDetectorNotReadyIsMissingWhateverTheEngine() {
        var states = StubCatalog.allReady
        states[LocalModelID.voiceDetector] = .absent
        states[LocalModelID.parakeet] = .incomplete
        #expect(
            Self.missing(Self.settings(engine: "parakeet"), states) == [LocalModelID.voiceDetector, LocalModelID.parakeet])
    }

    @Test func aWhisperVariantNotReadyDoesNotMatterToParakeet() {
        var states = StubCatalog.allReady
        states[LocalModelID.whisper("small")] = .absent
        #expect(Self.missing(Self.settings(engine: "parakeet"), states).isEmpty)
    }

    /// Un nom de variante saisi à la main n'est pas dans le catalogue : on ne dit pas « téléchargement » sans le savoir.
    @Test func aVariantTheCatalogueDoesNotKnowIsNotMissing() {
        var states = StubCatalog.allReady
        states[LocalModelID.whisper("small")] = nil
        #expect(Self.missing(Self.settings(), states).isEmpty)
    }

    // MARK: - Téléchargement par le catalogue (I5)

    @Test func theEnvironmentDownloadsThroughTheCatalogueExactlyWhatIsMissing() async throws {
        let catalog = StubCatalog(StubCatalog.allReady)
        catalog.set(LocalModelID.whisper("small"), .absent)
        catalog.set(LocalModelID.parakeetVocabulary, .absent)
        let engines = LiveDictationEngines(base: catalog)
        let environment = engines.environment
        let settings = Self.settings(vocabulary: ["terme"])

        #expect(await environment.needsModelDownload(settings))
        try await environment.downloadModels(settings)
        #expect(catalog.ensured == [LocalModelID.whisper("small"), LocalModelID.parakeetVocabulary])
    }

    @Test func theEnvironmentDownloadsNothingWhenNothingIsMissing() async throws {
        let catalog = StubCatalog(StubCatalog.allReady)
        let environment = LiveDictationEngines(base: catalog).environment
        #expect(await !environment.needsModelDownload(Self.settings()))
        try await environment.downloadModels(Self.settings())
        #expect(catalog.ensured.isEmpty)
    }

    /// Un modèle déjà en cours de téléchargement (par la fenêtre de réglages) est demandé au catalogue, qui attend le même.
    @Test func aModelBeingDownloadedElsewhereIsHandedToTheCatalogueToJoin() async throws {
        let catalog = StubCatalog(StubCatalog.allReady)
        catalog.set(LocalModelID.whisper("small"), .downloading(nil))
        let environment = LiveDictationEngines(base: catalog).environment
        try await environment.downloadModels(Self.settings())
        #expect(catalog.ensured == [LocalModelID.whisper("small")])
    }

    @Test func aFailedDownloadReachesTheCaller() async {
        let catalog = StubCatalog(StubCatalog.allReady)
        catalog.set(LocalModelID.voiceDetector, .absent)
        catalog.failEnsure(Refused())
        let environment = LiveDictationEngines(base: catalog).environment
        await #expect(throws: Refused.self) { try await environment.downloadModels(Self.settings()) }
    }

    // MARK: - Moteurs gardés (makeSession) et leur abandon

    @Test func parakeetServesAsPreviewAndAsFinalEngineWhenItIsTheSetting() {
        let cache = EngineCache(modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"))
        let engines = cache.engines(for: Self.settings(engine: "parakeet"))
        #expect((engines.final as AnyObject) === engines.preview)
    }

    @Test func whisperKitIsTheFinalEngineAndParakeetStaysThePreview() {
        let cache = EngineCache(modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"))
        let engines = cache.engines(for: Self.settings())
        #expect(engines.final is WhisperKitTranscriber)
        #expect((engines.final as AnyObject) !== engines.preview)
    }

    @Test func enginesAreKeptFromOneDictationToTheNextWhileTheSettingsStay() {
        let cache = EngineCache(modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"))
        let first = cache.engines(for: Self.settings())
        let second = cache.engines(for: Self.settings(vocabulary: ["terme"]))
        #expect(first.preview === second.preview)
        #expect(first.detector === second.detector)
        #expect((first.final as AnyObject) === (second.final as AnyObject))
    }

    @Test func aChangedWhisperModelGetsANewEngine() {
        let cache = EngineCache(modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"))
        let small = cache.engines(for: Self.settings(model: "small"))
        let base = cache.engines(for: Self.settings(model: "base"))
        #expect((small.final as AnyObject) !== (base.final as AnyObject))
        #expect(small.preview === base.preview)
    }

    @Test func deletingTheChosenWhisperModelDropsItsEngineAndOnlyIt() {
        let cache = EngineCache(modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"))
        let before = cache.engines(for: Self.settings(model: "small"))
        cache.evict(modelID: LocalModelID.whisper("base"))
        #expect((cache.engines(for: Self.settings(model: "small")).final as AnyObject) === (before.final as AnyObject))

        cache.evict(modelID: LocalModelID.whisper("small"))
        let after = cache.engines(for: Self.settings(model: "small"))
        #expect((after.final as AnyObject) !== (before.final as AnyObject))
        #expect(after.preview === before.preview)
        #expect(after.detector === before.detector)
    }

    @Test(arguments: [LocalModelID.parakeet, LocalModelID.parakeetVocabulary])
    func deletingParakeetOrItsVocabularyModelDropsTheParakeetEngine(id: String) {
        let cache = EngineCache(modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"))
        let before = cache.engines(for: Self.settings(engine: "parakeet"))
        cache.evict(modelID: id)
        let after = cache.engines(for: Self.settings(engine: "parakeet"))
        #expect(after.preview !== before.preview)
        #expect(after.detector === before.detector)
    }

    @Test func deletingTheVoiceDetectorDropsTheDetector() {
        let cache = EngineCache(modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"))
        let before = cache.engines(for: Self.settings())
        cache.evict(modelID: LocalModelID.voiceDetector)
        let after = cache.engines(for: Self.settings())
        #expect(after.detector !== before.detector)
        #expect(after.preview === before.preview)
    }

    @Test func aSessionIsBuiltFromTheKeptEnginesAndAScriptedFeed() async throws {
        let engines = LiveDictationEngines(
            base: StubCatalog(StubCatalog.allReady), makeFeed: { ScriptedMicrophoneFeed(chunks: []) })
        let session = try await engines.environment.makeSession(Self.settings())
        #expect(session is DictationSession)
    }

    /// Ce que la fenêtre de réglages supprime (son catalogue est celui de la dictée) abandonne le moteur gardé.
    @Test func theCatalogueSeenBySettingsDropsTheEngineOfADeletedModel() async throws {
        let stub = StubCatalog(StubCatalog.allReady)
        let engines = LiveDictationEngines(base: stub, makeFeed: { ScriptedMicrophoneFeed(chunks: []) })
        let before = engines.cache.engines(for: Self.settings())

        try await engines.catalog.delete(LocalModelID.whisper("small"))
        #expect(stub.deleted == [LocalModelID.whisper("small")])
        #expect((engines.cache.engines(for: Self.settings()).final as AnyObject) !== (before.final as AnyObject))
    }

    @Test func aRefusedDeletionDropsNothing() async {
        let cache = EngineCache(modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"))
        let stub = StubCatalog(StubCatalog.allReady)
        stub.failDelete(Refused())
        let catalog = EvictingModelCatalog(base: stub, cache: cache)
        let before = cache.engines(for: Self.settings())

        await #expect(throws: Refused.self) { try await catalog.delete(LocalModelID.whisper("small")) }
        #expect((cache.engines(for: Self.settings()).final as AnyObject) === (before.final as AnyObject))
    }

    @Test func aDeletionThroughTheCatalogueDropsTheEngine() async throws {
        let cache = EngineCache(modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"))
        let catalog = EvictingModelCatalog(base: StubCatalog(StubCatalog.allReady), cache: cache)
        let before = cache.engines(for: Self.settings())

        try await catalog.delete(LocalModelID.whisper("small"))
        #expect((cache.engines(for: Self.settings()).final as AnyObject) !== (before.final as AnyObject))
    }

    @Test func theCatalogueDecoratorForwardsEverythingElseUntouched() async throws {
        let stub = StubCatalog(StubCatalog.allReady)
        let catalog = EvictingModelCatalog(
            base: stub, cache: EngineCache(modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles")))
        #expect(await catalog.models().count == 3)
        #expect(await catalog.state(of: LocalModelID.parakeetVocabulary) == .ready)
        try await catalog.ensureDownloaded("x")
        #expect(stub.ensured == ["x"])
        #expect(await catalog.promptTokenCount(["a"], whisperModel: "small") == nil)
    }
}
