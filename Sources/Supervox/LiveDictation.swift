import Foundation
import SupervoxApp
import SupervoxCore
import SupervoxEngines
import Synchronization

/// Les moteurs réels de la dictée, gardés d'une dictée à l'autre : sans cela, le modèle se rechargerait à chaque appui.
///
/// Construire ne charge, ne prépare et ne télécharge rien (pas même un tokenizer) : les moteurs se préparent dans
/// `DictationSession.start()`, au premier appui. Le catalogue des modèles et les moteurs partagent une seule racine de
/// modèles, sous Application Support, jamais dans Documents.
final class LiveDictationEngines: Sendable {
    let catalog: LocalModelCatalog
    private let modelsRoot: URL
    private let held: Mutex<Held>

    private struct Held {
        /// L'aperçu en direct, et le moteur final quand le réglage est Parakeet : un seul exemplaire, un seul chargement.
        let parakeet = ParakeetTranscriber()
        let detector = FluidStreamingVoiceDetector()
        /// La variante WhisperKit chargée, gardée tant que le modèle choisi ne change pas.
        var whisper: (model: String, engine: WhisperKitTranscriber)?
    }

    init(modelsRoot: URL = LiveDictationEngines.defaultModelsRoot()) {
        self.modelsRoot = modelsRoot
        catalog = LocalModelCatalog(root: modelsRoot)
        held = Mutex(Held())
    }

    /// `Application Support/Supervox/Models`, créé au premier téléchargement et non au lancement.
    static func defaultModelsRoot() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL.applicationSupportDirectory
        return support.appendingPathComponent("Supervox/Models", isDirectory: true)
    }

    var environment: DictationEnvironment {
        let catalog = catalog
        return DictationEnvironment(
            makeSession: { [self] settings in makeSession(settings) },
            needsModelDownload: { settings in Self.needsDownload(settings, models: await catalog.models()) },
            promptTokenCount: { terms, model in await catalog.promptTokenCount(terms, whisperModel: model) },
            promptTokenLimit: WhisperKitTranscriber.promptTokenLimit)
    }

    /// Vrai si un modèle dont la dictée a besoin n'est pas prêt (absent, incomplet, en téléchargement ou en échec) : la
    /// préparation le téléchargera. Un modèle que le catalogue ne connaît pas (nom de variante saisi à la main) n'est pas
    /// déclaré à télécharger : on ne sait pas.
    static func needsDownload(_ settings: TranscriptionSettings, models: [LocalModel]) -> Bool {
        neededModels(for: settings).contains { id in
            guard let model = models.first(where: { $0.id == id }) else { return false }
            return model.state != .ready
        }
    }

    /// Ce dont une dictée a besoin : le détecteur de voix et Parakeet (l'aperçu) toujours, la variante Whisper choisie si
    /// c'est le moteur des réglages.
    static func neededModels(for settings: TranscriptionSettings) -> [String] {
        var needed = [LocalModelID.voiceDetector, LocalModelID.parakeet]
        if settings.engine == "whisperkit" { needed.append(LocalModelID.whisper(settings.whisperModel)) }
        return needed
    }

    private func makeSession(_ settings: TranscriptionSettings) -> any DictationSessioning {
        let root = modelsRoot
        let (parakeet, detector, final) = held.withLock { held -> (ParakeetTranscriber, FluidStreamingVoiceDetector, any Transcriber) in
            if settings.engine == "parakeet" { return (held.parakeet, held.detector, held.parakeet) }
            if held.whisper?.model != settings.whisperModel {
                held.whisper = (settings.whisperModel, WhisperKitTranscriber(model: settings.whisperModel, downloadBase: root))
            }
            return (held.parakeet, held.detector, held.whisper!.engine)
        }
        return DictationSession(
            feed: LiveMicrophoneFeed(), detector: detector, preview: parakeet, final: final,
            config: DictationConfig(language: settings.language, vocabulary: settings.vocabulary),
            now: { ProcessInfo.processInfo.systemUptime })
    }
}
