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
final class EngineCache: Sendable {
    /// Ce qu'une session reçoit.
    struct Engines {
        /// L'aperçu en direct : toujours Parakeet. Aussi le moteur final quand le réglage est Parakeet.
        let preview: ParakeetTranscriber
        let detector: FluidStreamingVoiceDetector
        let final: any Transcriber
    }

    private struct Held {
        var parakeet = ParakeetTranscriber()
        var detector = FluidStreamingVoiceDetector()
        /// La variante WhisperKit chargée, gardée tant que le modèle choisi ne change pas.
        var whisper: (model: String, engine: WhisperKitTranscriber)?
    }

    private let modelsRoot: URL
    private let held = Mutex(Held())

    init(modelsRoot: URL) {
        self.modelsRoot = modelsRoot
    }

    /// Un seul exemplaire de chaque moteur, un seul chargement : Parakeet sert d'aperçu et, au réglage Parakeet, de moteur
    /// final ; la variante WhisperKit est gardée tant que le modèle des réglages est le même.
    func engines(for settings: TranscriptionSettings) -> Engines {
        let root = modelsRoot
        return held.withLock { held in
            if settings.engine == "parakeet" {
                return Engines(preview: held.parakeet, detector: held.detector, final: held.parakeet)
            }
            if held.whisper?.model != settings.whisperModel {
                held.whisper = (settings.whisperModel, WhisperKitTranscriber(model: settings.whisperModel, downloadBase: root))
            }
            return Engines(preview: held.parakeet, detector: held.detector, final: held.whisper!.engine)
        }
    }

    /// Un modèle vient d'être supprimé du disque : le moteur qui le tient en mémoire est abandonné, la dictée suivante en
    /// recharge un neuf (et retélécharge le modèle). Le petit modèle de vocabulaire vit dans Parakeet.
    func evict(modelID id: String) {
        held.withLock { held in
            switch id {
            case LocalModelID.parakeet, LocalModelID.parakeetVocabulary:
                held.parakeet = ParakeetTranscriber()
            case LocalModelID.voiceDetector:
                held.detector = FluidStreamingVoiceDetector()
            default:
                if let variant = LocalModelID.whisperVariant(of: id), held.whisper?.model == variant {
                    held.whisper = nil
                }
            }
        }
    }
}

/// Le catalogue des modèles que voit la fenêtre de réglages : celui de la dictée, qui abandonne le moteur gardé en mémoire
/// quand son modèle est supprimé. Une suppression refusée (modèle en cours de téléchargement) n'abandonne rien.
struct EvictingModelCatalog: ModelCatalog {
    let base: any ModelCatalog
    let cache: EngineCache

    func models() async -> [LocalModel] { await base.models() }

    func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        try await base.download(id, progress: progress)
    }

    func ensureDownloaded(_ id: String) async throws { try await base.ensureDownloaded(id) }

    func state(of id: String) async -> LocalModel.State? { await base.state(of: id) }

    func delete(_ id: String) async throws {
        try await base.delete(id)
        cache.evict(modelID: id)
    }

    func promptTokenCount(_ vocabulary: [String], whisperModel: String) async -> Int? {
        await base.promptTokenCount(vocabulary, whisperModel: whisperModel)
    }
}

/// L'environnement réel de la dictée.
final class LiveDictationEngines: Sendable {
    /// Le catalogue de la fenêtre de réglages et de la dictée : un seul, avec ses téléchargements.
    let catalog: any ModelCatalog
    private let base: any ModelCatalog
    /// Les moteurs gardés (internes : les tests y lisent l'identité des moteurs).
    let cache: EngineCache
    private let makeFeed: @Sendable () -> any MicrophoneFeed

    /// - Parameters:
    ///   - base: le catalogue sous-jacent (les tests en donnent un double ; en production, `LocalModelCatalog`).
    ///   - makeFeed: le micro d'une session (les tests donnent un micro scripté).
    init(
        modelsRoot: URL = LiveDictationEngines.defaultModelsRoot(), base: (any ModelCatalog)? = nil,
        makeFeed: @escaping @Sendable () -> any MicrophoneFeed = { LiveMicrophoneFeed() }
    ) {
        let cache = EngineCache(modelsRoot: modelsRoot)
        let base = base ?? LocalModelCatalog(root: modelsRoot)
        self.cache = cache
        self.base = base
        self.makeFeed = makeFeed
        catalog = EvictingModelCatalog(base: base, cache: cache)
    }

    /// `Application Support/Supervox/Models`, créé au premier téléchargement et non au lancement.
    static func defaultModelsRoot() -> URL {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? URL.applicationSupportDirectory
        return support.appendingPathComponent("Supervox/Models", isDirectory: true)
    }

    var environment: DictationEnvironment {
        DictationEnvironment(
            makeSession: { [self] settings in makeSession(settings) },
            needsModelDownload: { [self] settings in !(await missingModels(for: settings)).isEmpty },
            downloadModels: { [self] settings in try await downloadModels(for: settings) },
            promptTokenCount: { [self] terms, model in await base.promptTokenCount(terms, whisperModel: model) },
            promptTokenLimit: WhisperKitTranscriber.promptTokenLimit)
    }

    /// Télécharge, par le catalogue, ce qui manque à cette dictée et rien de plus. Une tâche annulée (Échap) ne lance pas le
    /// modèle suivant de la liste. Le petit modèle de vocabulaire, qui vient après la reconnaissance de Parakeet, n'est pas
    /// indispensable : s'il ne se télécharge pas, la dictée a lieu sans vocabulaire (`vocabularyModelUnavailable`).
    func downloadModels(for settings: TranscriptionSettings) async throws -> ModelDownloadOutcome {
        var outcome = ModelDownloadOutcome.complete
        for id in await missingModels(for: settings) {
            try Task.checkCancellation()
            guard id == LocalModelID.parakeetVocabulary else {
                try await base.ensureDownloaded(id)
                continue
            }
            do {
                try await base.ensureDownloaded(id)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcome.vocabularyModelUnavailable = true
            }
        }
        return outcome
    }

    /// Ce dont une dictée a besoin : le détecteur de voix et Parakeet (l'aperçu) toujours, la variante Whisper choisie si
    /// c'est le moteur des réglages, et le petit modèle de vocabulaire seulement avec un vocabulaire (Parakeet, qui fait
    /// l'aperçu même sous WhisperKit, l'utilise alors).
    static func neededModels(for settings: TranscriptionSettings) -> [String] {
        var needed = [LocalModelID.voiceDetector, LocalModelID.parakeet]
        if settings.engine == "whisperkit" { needed.append(LocalModelID.whisper(settings.whisperModel)) }
        if !settings.vocabulary.isEmpty { needed.append(LocalModelID.parakeetVocabulary) }
        return needed
    }

    /// Les modèles nécessaires qui ne sont pas prêts (absents, incomplets, en téléchargement), dans l'ordre. Un modèle que le
    /// catalogue ne connaît pas (nom de variante saisi à la main) n'est pas déclaré à télécharger : on ne sait pas.
    static func missingModels(for settings: TranscriptionSettings, state: (String) -> LocalModel.State?) -> [String] {
        neededModels(for: settings).filter { id in
            guard let state = state(id) else { return false }
            return state != .ready
        }
    }

    private func missingModels(for settings: TranscriptionSettings) async -> [String] {
        var states: [String: LocalModel.State] = [:]
        for model in await base.models() { states[model.id] = model.state }
        if let vocabulary = await base.state(of: LocalModelID.parakeetVocabulary) {
            states[LocalModelID.parakeetVocabulary] = vocabulary
        }
        return Self.missingModels(for: settings, state: { states[$0] })
    }

    private func makeSession(_ settings: TranscriptionSettings) -> any DictationSessioning {
        let engines = cache.engines(for: settings)
        return DictationSession(
            feed: makeFeed(), detector: engines.detector, preview: engines.preview, final: engines.final,
            config: DictationConfig(language: settings.language, vocabulary: settings.vocabulary),
            now: { ProcessInfo.processInfo.systemUptime },
            // Un micro qui s'arrête en pleine prise (casque débranché) fait échouer la dictée au lieu de la laisser « en
            // enregistrement ». Seul le vrai micro est surveillé : `live` et les tests n'en ont pas.
            watchdog: .system)
    }
}
