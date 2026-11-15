import Foundation
import SupervoxApp
import SupervoxCore
import Testing

@testable import Supervox

/// I4 (a) : au lancement, les moteurs des réglages courants sont préparés en tâche de fond quand tous leurs modèles sont déjà sur
/// le disque ; jamais de téléchargement ; un échec est silencieux. Moteurs et catalogue sont des doubles : aucun modèle, aucun
/// disque, aucun réseau.
@Suite(.timeLimit(.minutes(1))) struct LiveDictationPreloadTests {
    typealias Stub = LiveDictationTests.StubCatalog

    private static func settings(
        engine: String = "whisperkit", model: String = "small", vocabulary: [String] = []
    ) -> TranscriptionSettings {
        TranscriptionSettings(engine: engine, whisperModel: model, language: "fr", vocabulary: vocabulary)
    }

    private struct Rig {
        let engines: LiveDictationEngines
        let doubles: DoubleEngines
        let catalog: Stub
    }

    private static func rig(states: [String: LocalModel.State] = Stub.allReady) -> Rig {
        let doubles = DoubleEngines()
        let catalog = Stub(states)
        let engines = LiveDictationEngines(
            modelsRoot: URL(fileURLWithPath: "/tmp/supervox-test-modeles"), base: catalog,
            makeFeed: { ScriptedMicrophoneFeed(chunks: []) }, factory: doubles.factory, watchdog: nil)
        return Rig(engines: engines, doubles: doubles, catalog: catalog)
    }

    // MARK: - Préchargement lancé

    @Test func everyModelReadyPreparesTheDetectorTheFinalEngineAndThePreview() async {
        let rig = Self.rig()
        await rig.engines.environment.preload(Self.settings())
        #expect(rig.doubles.detector.prepares == 1)
        #expect(rig.doubles.whisper("small").prepares == 1)
        #expect(rig.doubles.parakeet.prepares == 1)
        #expect(rig.catalog.ensured.isEmpty)
        #expect(await rig.catalog.state(of: LocalModelID.parakeet) == .ready)
    }

    @Test func aParakeetSettingPreparesTheDetectorAndParakeetOnlyOnce() async {
        let rig = Self.rig()
        await rig.engines.environment.preload(Self.settings(engine: "parakeet"))
        #expect(rig.doubles.detector.prepares == 1)
        // Parakeet est à la fois l'aperçu et le moteur final : deux appels de préparation, sur le même moteur.
        #expect(rig.doubles.parakeet.prepares == 2)
        #expect(rig.doubles.whisper("small").prepares == 0)
    }

    @Test func thePreparedEnginesAreTheOnesTheNextSessionUses() async {
        let rig = Self.rig()
        let settings = Self.settings()
        #expect(await rig.engines.enginesLoaded(for: settings) == false)
        await rig.engines.preload(for: settings)
        #expect(await rig.engines.enginesLoaded(for: settings) == true)
        let engines = rig.engines.cache.engines(for: settings)
        #expect((engines.final as AnyObject) === rig.doubles.whisper("small"))
        #expect((engines.detector as AnyObject) === rig.doubles.detector)
    }

    @Test func withAVocabularyThePreloadNeedsTheVocabularyModelToo() async {
        let rig = Self.rig()
        await rig.engines.preload(for: Self.settings(vocabulary: ["terme"]))
        #expect(rig.doubles.detector.prepares == 1)
    }

    // MARK: - Préchargement non lancé, et aucun téléchargement

    @Test(arguments: [
        LocalModel.State.absent, .incomplete, .downloading(nil), .downloading(0.5), .failed("échec"),
    ])
    func anyNeededModelNotReadyMeansNoPreloadAndNoDownload(_ state: LocalModel.State) async {
        for missing in [LocalModelID.voiceDetector, LocalModelID.parakeet, LocalModelID.whisper("small")] {
            var states = Stub.allReady
            states[missing] = state
            let rig = Self.rig(states: states)
            await rig.engines.preload(for: Self.settings())
            #expect(rig.doubles.detector.prepares == 0)
            #expect(rig.doubles.parakeet.prepares == 0)
            #expect(rig.doubles.whisper("small").prepares == 0)
            #expect(rig.catalog.ensured.isEmpty)
        }
    }

    @Test func aMissingVocabularyModelStopsThePreloadOnlyWhenThereIsAVocabulary() async {
        var states = Stub.allReady
        states[LocalModelID.parakeetVocabulary] = .absent
        let withVocabulary = Self.rig(states: states)
        await withVocabulary.engines.preload(for: Self.settings(vocabulary: ["terme"]))
        #expect(withVocabulary.doubles.detector.prepares == 0)
        #expect(withVocabulary.catalog.ensured.isEmpty)

        let without = Self.rig(states: states)
        await without.engines.preload(for: Self.settings())
        #expect(without.doubles.detector.prepares == 1)
    }

    /// Une variante inconnue du catalogue (nom saisi à la main) : on ne sait pas si elle est sur le disque, rien n'est préchargé.
    @Test func aVariantTheCatalogueDoesNotKnowIsNotPreloaded() async {
        var states = Stub.allReady
        states[LocalModelID.whisper("small")] = nil
        let rig = Self.rig(states: states)
        await rig.engines.preload(for: Self.settings())
        #expect(rig.doubles.detector.prepares == 0)
        #expect(rig.catalog.ensured.isEmpty)
    }

    /// Modèle « Prêt » mais tokenizer absent : WhisperKit irait le chercher sur le réseau. Pas de préchargement.
    @Test func aWhisperModelThatCannotLoadOfflineIsNotPreloaded() async {
        let rig = Self.rig()
        rig.doubles.setWhisperLoadsOffline(false)
        await rig.engines.preload(for: Self.settings())
        #expect(rig.doubles.detector.prepares == 0)
        #expect(rig.doubles.whisper("small").prepares == 0)
    }

    /// Le tokenizer ne concerne que WhisperKit.
    @Test func theTokenizerIsNotNeededForAParakeetSetting() async {
        let rig = Self.rig()
        rig.doubles.setWhisperLoadsOffline(false)
        await rig.engines.preload(for: Self.settings(engine: "parakeet"))
        #expect(rig.doubles.detector.prepares == 1)
    }

    // MARK: - Échec silencieux

    @Test func aFailedPreloadIsSilentAndTheNextDictationPreparesAgain() async {
        struct Boom: Error {}
        let rig = Self.rig()
        rig.doubles.whisper("small").failPrepare(with: Boom())
        rig.doubles.detector.failPrepare(with: Boom())
        // Ne lève pas, ne plante pas.
        await rig.engines.environment.preload(Self.settings())
        #expect(rig.doubles.whisper("small").prepares == 1)
        #expect(await rig.engines.enginesLoaded(for: Self.settings()) == false)

        // La panne passée, la préparation d'une dictée charge ce qui manque.
        rig.doubles.whisper("small").failPrepare(with: nil)
        rig.doubles.detector.failPrepare(with: nil)
        await rig.engines.preload(for: Self.settings())
        #expect(await rig.engines.enginesLoaded(for: Self.settings()) == true)
    }

    // MARK: - enginesLoaded

    @Test func enginesAreLoadedOnlyWhenTheDetectorThePreviewAndTheFinalEngineAre() async {
        let rig = Self.rig()
        let settings = Self.settings()
        #expect(await rig.engines.enginesLoaded(for: settings) == false)
        try? await rig.doubles.detector.prepare()
        #expect(await rig.engines.enginesLoaded(for: settings) == false)
        try? await rig.doubles.parakeet.prepare()
        #expect(await rig.engines.enginesLoaded(for: settings) == false)
        try? await rig.doubles.whisper("small").prepare()
        #expect(await rig.engines.enginesLoaded(for: settings) == true)
        // Un autre modèle n'est pas chargé pour autant.
        #expect(await rig.engines.enginesLoaded(for: Self.settings(model: "base")) == false)
    }
}
