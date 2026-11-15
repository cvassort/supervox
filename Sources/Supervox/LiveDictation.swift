import Foundation
import SupervoxApp
import SupervoxCore
import SupervoxEngines
import Synchronization

/// Un moteur dont on sait s'il est déjà chargé en mémoire.
protocol Loadable: Sendable {
    var isPrepared: Bool { get async }
}

extension ParakeetTranscriber: Loadable {}
extension WhisperKitTranscriber: Loadable {}
extension FluidStreamingVoiceDetector: Loadable {}

typealias LoadableTranscriber = Transcriber & Loadable
typealias LoadableDetector = StreamingVoiceDetector & Loadable

/// Comment l'application fabrique ses moteurs. Les tests en donnent d'autres : aucun vrai modèle n'est alors chargé.
/// Fabriquer ne charge, ne prépare et ne télécharge rien.
struct EngineFactory: Sendable {
    var parakeet: @Sendable () -> any LoadableTranscriber
    var detector: @Sendable () -> any LoadableDetector
    var whisper: @Sendable (_ model: String, _ modelsRoot: URL) -> any LoadableTranscriber
    /// Vrai si ce modèle se charge sans réseau (dossier prêt et tokenizer qui se charge depuis le disque) : condition du
    /// préchargement.
    var whisperLoadsOffline: @Sendable (_ model: String, _ modelsRoot: URL) async -> Bool
    /// Coupe ou rétablit le réseau de FluidAudio (global au processus) : coupé pendant le préchargement, rétabli à sa fin.
    var setOffline: @Sendable (_ offline: Bool) -> Void

    static let real = EngineFactory(
        parakeet: { ParakeetTranscriber() },
        detector: { FluidStreamingVoiceDetector() },
        whisper: { WhisperKitTranscriber(model: $0, downloadBase: $1) },
        whisperLoadsOffline: { await WhisperKitTranscriber.canLoadWithoutNetwork(model: $0, downloadBase: $1) },
        setOffline: { EngineNetwork.setOffline($0) })
}

/// Les moteurs réels de la dictée, gardés d'une dictée à l'autre : sans cela, le modèle se rechargerait à chaque appui.
///
/// Construire ne charge, ne prépare et ne télécharge rien (pas même un tokenizer) : les moteurs se préparent dans
/// `DictationSession.start()`, au premier appui, ou, si tous les modèles sont déjà sur le disque, en tâche de fond au
/// lancement (`LiveDictationEngines.preload`). Le catalogue des modèles et les moteurs partagent une seule racine de
/// modèles, sous Application Support, jamais dans Documents.
final class EngineCache: Sendable {
    /// Ce qu'une session reçoit.
    struct Engines {
        /// L'aperçu en direct : toujours Parakeet. Aussi le moteur final quand le réglage est Parakeet.
        let preview: any LoadableTranscriber
        let detector: any LoadableDetector
        let final: any LoadableTranscriber
    }

    private struct Held {
        var parakeet: any LoadableTranscriber
        var detector: any LoadableDetector
        /// La variante WhisperKit chargée, gardée tant que le modèle choisi ne change pas.
        var whisper: (model: String, engine: any LoadableTranscriber)?
    }

    private let modelsRoot: URL
    private let factory: EngineFactory
    private let held: Mutex<Held>

    init(modelsRoot: URL, factory: EngineFactory = .real) {
        self.modelsRoot = modelsRoot
        self.factory = factory
        held = Mutex(Held(parakeet: factory.parakeet(), detector: factory.detector()))
    }

    /// Un seul exemplaire de chaque moteur, un seul chargement : Parakeet sert d'aperçu et, au réglage Parakeet, de moteur
    /// final ; la variante WhisperKit est gardée tant que le modèle des réglages est le même.
    func engines(for settings: TranscriptionSettings) -> Engines {
        let root = modelsRoot
        let factory = factory
        return held.withLock { held in
            if settings.engine == "parakeet" {
                return Engines(preview: held.parakeet, detector: held.detector, final: held.parakeet)
            }
            if held.whisper?.model != settings.whisperModel {
                held.whisper = (settings.whisperModel, factory.whisper(settings.whisperModel, root))
            }
            return Engines(preview: held.parakeet, detector: held.detector, final: held.whisper!.engine)
        }
    }

    /// Ce modèle Whisper se charge-t-il sans réseau ?
    func whisperLoadsOffline(_ model: String) async -> Bool { await factory.whisperLoadsOffline(model, modelsRoot) }

    func setOffline(_ offline: Bool) { factory.setOffline(offline) }

    /// Un modèle vient d'être supprimé du disque : le moteur qui le tient en mémoire est abandonné, la dictée suivante en
    /// recharge un neuf (et retélécharge le modèle). Le petit modèle de vocabulaire vit dans Parakeet.
    func evict(modelID id: String) {
        let factory = factory
        held.withLock { held in
            switch id {
            case LocalModelID.parakeet, LocalModelID.parakeetVocabulary:
                held.parakeet = factory.parakeet()
            case LocalModelID.voiceDetector:
                held.detector = factory.detector()
            default:
                if let variant = LocalModelID.whisperVariant(of: id), held.whisper?.model == variant {
                    held.whisper = nil
                }
            }
        }
    }
}

/// Le point de passage du préchargement du lancement. Pendant le préchargement le réseau de FluidAudio est coupé (voir
/// `LiveDictationEngines.preload`) : tout ce qui pourrait avoir besoin du réseau ou toucher un modèle (la préparation d'une
/// dictée, un téléchargement, une suppression) attend ici la fin du préchargement, succès ou échec, et reprend avec le réseau
/// rétabli. Sans préchargement en cours, rien n'attend.
final class PreloadGate: Sendable {
    private let state = Mutex<(active: Int, waiters: [CheckedContinuation<Void, Never>])>((0, []))

    /// Un préchargement commence (appel synchrone : aucune attente ne passe entre la décision et ce marquage).
    func begin() { state.withLock { $0.active += 1 } }

    /// Un préchargement finit : ceux qui attendaient reprennent.
    func finish() {
        let ready = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.active = max(0, state.active - 1)
            guard state.active == 0 else { return [] }
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in ready { waiter.resume() }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let passes = state.withLock { state -> Bool in
                if state.active == 0 { return true }
                state.waiters.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
    }
}

/// Le catalogue des modèles que voit la fenêtre de réglages : celui de la dictée, qui abandonne le moteur gardé en mémoire
/// quand son modèle est supprimé. Une suppression refusée (modèle en cours de téléchargement) n'abandonne rien.
struct EvictingModelCatalog: ModelCatalog {
    let base: any ModelCatalog
    let cache: EngineCache
    /// Un téléchargement ou une suppression attend la fin d'un préchargement en cours (voir `PreloadGate`).
    var gate = PreloadGate()

    func models() async -> [LocalModel] { await base.models() }

    func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        await gate.waitUntilFinished()
        try await base.download(id, progress: progress)
    }

    func ensureDownloaded(_ id: String) async throws {
        await gate.waitUntilFinished()
        try await base.ensureDownloaded(id)
    }

    func state(of id: String) async -> LocalModel.State? { await base.state(of: id) }

    func delete(_ id: String) async throws {
        await gate.waitUntilFinished()
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
    private let watchdog: MicrophoneWatchdog?
    private let gate = PreloadGate()

    /// - Parameters:
    ///   - base: le catalogue sous-jacent (les tests en donnent un double ; en production, `LocalModelCatalog`).
    ///   - makeFeed: le micro d'une session (les tests donnent un micro scripté).
    ///   - factory: les moteurs (les tests en donnent des doubles : aucun vrai modèle).
    ///   - watchdog: la surveillance du micro de chaque session ; `.system` en production. Un micro scripté livre tout à
    ///     l'ouverture puis se tait : les tests qui l'utilisent passent `nil`.
    init(
        modelsRoot: URL = LiveDictationEngines.defaultModelsRoot(), base: (any ModelCatalog)? = nil,
        makeFeed: @escaping @Sendable () -> any MicrophoneFeed = { LiveMicrophoneFeed() },
        factory: EngineFactory = .real, watchdog: MicrophoneWatchdog? = .system
    ) {
        let cache = EngineCache(modelsRoot: modelsRoot, factory: factory)
        let base = base ?? LocalModelCatalog(root: modelsRoot)
        self.cache = cache
        self.base = base
        self.makeFeed = makeFeed
        self.watchdog = watchdog
        catalog = EvictingModelCatalog(base: base, cache: cache, gate: gate)
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
            makeSession: { [self] settings in
                await gate.waitUntilFinished()
                return makeSession(settings)
            },
            needsModelDownload: { [self] settings in !(await missingModels(for: settings)).isEmpty },
            downloadModels: { [self] settings in try await downloadModels(for: settings) },
            promptTokenCount: { [self] terms, model in await base.promptTokenCount(terms, whisperModel: model) },
            promptTokenLimit: WhisperKitTranscriber.promptTokenLimit,
            enginesLoaded: { [self] settings in await enginesLoaded(for: settings) },
            preload: { [self] settings in await preload(for: settings) })
    }

    /// Détecteur, aperçu et moteur final de ces réglages sont-ils déjà chargés en mémoire ?
    func enginesLoaded(for settings: TranscriptionSettings) async -> Bool {
        let engines = cache.engines(for: settings)
        guard await engines.detector.isPrepared, await engines.preview.isPrepared else { return false }
        return await engines.final.isPrepared
    }

    /// Prépare, au lancement et en tâche de fond, les moteurs des réglages courants, dans l'ordre de la session (détecteur,
    /// moteur final, aperçu), **seulement** si tout ce dont une dictée a besoin est déjà « Prêt » sur le disque : détecteur,
    /// Parakeet, la variante WhisperKit (dossier, et tokenizer qui se charge depuis le disque) si c'est le moteur, le petit modèle
    /// de vocabulaire s'il y a un vocabulaire. Sinon, rien.
    ///
    /// Le préchargement ne touche jamais le réseau ni un modèle :
    /// - WhisperKit : `download: false` et le dossier du modèle donné (`WhisperKitTranscriber.configuration`), et le préchargement
    ///   n'a lieu que si le tokenizer se charge réellement depuis le disque (sinon WhisperKit irait le chercher en ligne) ;
    /// - FluidAudio (Parakeet, détecteur) : le réseau est coupé (`ModelHub.offlineMode`) pendant les préparations, ce qui interdit
    ///   le téléchargement d'un modèle « Prêt » pour le catalogue mais incomplet pour la bibliothèque, et le rattrapage qui
    ///   supprimerait puis retéléchargerait un modèle qui ne se charge pas. Il est rétabli à la fin, succès ou échec.
    /// Pendant ce temps, la préparation d'une dictée, un téléchargement et une suppression attendent la fin (`PreloadGate`).
    ///
    /// Un échec est silencieux et ne supprime rien : la dictée refera la préparation et dira l'erreur.
    func preload(for settings: TranscriptionSettings) async {
        gate.begin()
        defer { gate.finish() }
        guard await allNeededModelsReady(for: settings) else { return }
        if settings.engine == "whisperkit", await !cache.whisperLoadsOffline(settings.whisperModel) { return }
        let engines = cache.engines(for: settings)
        cache.setOffline(true)
        defer { cache.setOffline(false) }
        try? await engines.detector.prepare()
        try? await engines.final.prepare()
        try? await engines.preview.prepare()
    }

    /// Tous les modèles nécessaires sont exactement « Prêt » (un modèle absent du catalogue n'est pas prêt).
    private func allNeededModelsReady(for settings: TranscriptionSettings) async -> Bool {
        for id in Self.neededModels(for: settings) {
            guard await base.state(of: id) == .ready else { return false }
        }
        return true
    }

    /// Télécharge, par le catalogue, ce qui manque à cette dictée et rien de plus. Une tâche annulée (Échap) ne lance pas le
    /// modèle suivant de la liste. Le petit modèle de vocabulaire, qui vient après la reconnaissance de Parakeet, n'est pas
    /// indispensable : s'il ne se télécharge pas, la dictée a lieu sans vocabulaire (`vocabularyModelUnavailable`).
    func downloadModels(for settings: TranscriptionSettings) async throws -> ModelDownloadOutcome {
        await gate.waitUntilFinished()
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
            watchdog: watchdog)
    }
}
