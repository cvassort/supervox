import SupervoxApp
import SupervoxCore
import Testing

@testable import Supervox

/// Ce que la cible `Supervox` décide seule : de quels modèles une dictée a besoin, et quand elle déclare un téléchargement.
/// Aucun moteur n'est construit, aucun disque lu.
@Suite struct LiveDictationTests {
    private static func model(_ id: String, _ state: LocalModel.State) -> LocalModel {
        LocalModel(id: id, title: id, detail: "", state: state)
    }

    private static let whisperSmall = TranscriptionSettings(
        engine: "whisperkit", whisperModel: "small", language: "fr", vocabulary: [])
    private static let parakeet = TranscriptionSettings(
        engine: "parakeet", whisperModel: "small", language: "fr", vocabulary: [])

    private static func ready(_ ids: String...) -> [LocalModel] { ids.map { model($0, .ready) } }

    @Test func aWhisperDictationNeedsTheVoiceDetectorParakeetAndTheChosenVariant() {
        #expect(
            LiveDictationEngines.neededModels(for: Self.whisperSmall)
                == [LocalModelID.voiceDetector, LocalModelID.parakeet, LocalModelID.whisper("small")])
    }

    @Test func aParakeetDictationDoesNotNeedAWhisperVariant() {
        #expect(
            LiveDictationEngines.neededModels(for: Self.parakeet) == [LocalModelID.voiceDetector, LocalModelID.parakeet])
    }

    @Test func nothingToDownloadWhenEveryNeededModelIsReady() {
        let models = Self.ready(LocalModelID.voiceDetector, LocalModelID.parakeet, LocalModelID.whisper("small"))
        #expect(!LiveDictationEngines.needsDownload(Self.whisperSmall, models: models))
    }

    @Test(arguments: [
        LocalModel.State.absent, .incomplete, .downloading(nil), .downloading(0.5), .failed("échec"),
    ])
    func aChosenVariantThatIsNotReadyNeedsADownload(_ state: LocalModel.State) {
        let models = Self.ready(LocalModelID.voiceDetector, LocalModelID.parakeet)
            + [Self.model(LocalModelID.whisper("small"), state)]
        #expect(LiveDictationEngines.needsDownload(Self.whisperSmall, models: models))
    }

    @Test func aMissingVoiceDetectorOrParakeetNeedsADownloadWhateverTheEngine() {
        let noDetector =
            [Self.model(LocalModelID.voiceDetector, .absent)] + Self.ready(LocalModelID.parakeet, LocalModelID.whisper("small"))
        #expect(LiveDictationEngines.needsDownload(Self.whisperSmall, models: noDetector))
        let noParakeet = [Self.model(LocalModelID.parakeet, .absent)] + Self.ready(LocalModelID.voiceDetector)
        #expect(LiveDictationEngines.needsDownload(Self.parakeet, models: noParakeet))
    }

    @Test func aWhisperVariantNotReadyDoesNotMatterToParakeet() {
        let models =
            Self.ready(LocalModelID.voiceDetector, LocalModelID.parakeet)
            + [Self.model(LocalModelID.whisper("small"), .absent)]
        #expect(!LiveDictationEngines.needsDownload(Self.parakeet, models: models))
    }

    /// Un nom de variante saisi à la main n'est pas dans le catalogue : on ne dit pas « téléchargement » sans le savoir.
    @Test func aVariantTheCatalogueDoesNotKnowIsNotAnnouncedAsADownload() {
        let models = Self.ready(LocalModelID.voiceDetector, LocalModelID.parakeet)
        #expect(!LiveDictationEngines.needsDownload(Self.whisperSmall, models: models))
    }
}
