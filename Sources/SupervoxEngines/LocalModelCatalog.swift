import FluidAudio
import Foundation
import SupervoxCore
import WhisperKit

public enum LocalModelCatalogError: Error, Equatable, LocalizedError {
    case unknownModel(String)
    case alreadyDownloading(String)
    /// Un téléchargement qui s'est terminé sans laisser les fichiers attendus.
    case incomplete(String)

    public var errorDescription: String? {
        switch self {
        case .unknownModel(let id): "Modèle inconnu : « \(id) »."
        case .alreadyDownloading: "Ce modèle est déjà en cours de téléchargement."
        case .incomplete(let title): "Le téléchargement de « \(title) » s'est terminé sans tous les fichiers attendus."
        }
    }
}

/// Les modèles locaux du disque : variantes WhisperKit sous `root`, Parakeet (reconnaissance et recalage du vocabulaire) et
/// détecteur de voix dans le dossier de FluidAudio.
///
/// Où vivent les fichiers :
/// - WhisperKit : `root/models/argmaxinc/whisperkit-coreml/<dossier de la variante>` (`downloadBase` = `root`, jamais le
///   dossier Documents que la bibliothèque prend sans paramètre) ; le tokenizer, lui, dans `root/models/openai/…`.
/// - Parakeet et détecteur de voix : `<fluidAudioRoot>/Models/<dépôt>`, c'est-à-dire, par défaut, le dossier que
///   `ParakeetTranscriber` et `FluidVoiceDetector` lisent (`Application Support/FluidAudio`). Les tests donnent un autre
///   `fluidAudioRoot`.
///
/// L'état d'un modèle se lit du disque seul, sans marque ni fichier ajouté : « prêt » si tous les fichiers attendus sont là,
/// « incomplet » si un dossier existe mais qu'il en manque, « absent » sinon. Pour une variante WhisperKit, les fichiers
/// attendus sont `requiredWhisperFiles`.
public actor LocalModelCatalog: ModelCatalog {
    /// Une variante WhisperKit proposée à l'utilisateur. `name` est celui du dépôt de modèles de WhisperKit.
    public struct WhisperVariant: Sendable, Equatable {
        public let name: String
        public let title: String
        public let detail: String

        public init(name: String, title: String, detail: String) {
            self.name = name
            self.title = title
            self.detail = detail
        }
    }

    /// Variantes proposées. La première est celle mesurée au banc d'essai (`docs/bench/2026-11-13-resultats.md`) et celle
    /// des réglages par défaut ; `small` et `base` sont des variantes de `Constants.fallbackModelSupportConfig` de WhisperKit
    /// (WhisperKit 1.1.1, `Models.swift`), plus petites : leur précision n'a pas été mesurée ici.
    public static let offeredWhisperVariants = [
        WhisperVariant(
            name: "large-v3-v20240930_turbo", title: "Whisper large-v3 turbo",
            detail:
                "Le modèle par défaut, celui des mesures de précision du projet. C'est le plus gros des trois : il demande le plus de temps de téléchargement, d'espace disque et de mémoire."
        ),
        WhisperVariant(
            name: "small", title: "Whisper small",
            detail:
                "Plus petit et plus rapide à charger que le modèle par défaut. Sa précision n'a pas été mesurée pour ce projet, et elle est en général moins bonne."
        ),
        WhisperVariant(
            name: "base", title: "Whisper base",
            detail:
                "Le plus léger des trois, pour un Mac peu puissant ou un essai rapide. Sa précision n'a pas été mesurée pour ce projet, et elle est en général plus faible."
        ),
    ]

    /// Dossier des modèles WhisperKit et des tokenizers.
    public nonisolated let root: URL
    private let fluidAudioRoot: URL
    private let whisperVariants: [WhisperVariant]
    /// Modèles en cours de téléchargement.
    private var inFlight: Set<String> = []
    /// Fraction de téléchargement, seulement quand la bibliothèque en donne une (le détecteur de voix).
    private var fractions: [String: Double] = [:]

    /// `root` : dossier des modèles de l'application (sous Application Support, jamais Documents). `fluidAudioRoot` :
    /// dossier de FluidAudio (`nil` : celui de la bibliothèque).
    public init(
        root: URL, fluidAudioRoot: URL? = nil, whisperVariants: [WhisperVariant] = LocalModelCatalog.offeredWhisperVariants
    ) {
        self.root = root
        self.fluidAudioRoot =
            fluidAudioRoot ?? MLModelConfigurationUtils.defaultModelsDirectory().deletingLastPathComponent()
        self.whisperVariants = whisperVariants
    }

    // MARK: - Emplacements

    /// `downloadBase/models/<dépôt>` : la disposition de `HubApi.localRepoLocation` (ArgmaxCore).
    static func whisperRepository(in root: URL) -> URL {
        root.appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    /// Les fichiers d'une variante WhisperKit que le moteur charge : les trois modèles Core ML compilés (chacun cinq fichiers)
    /// et les deux fichiers de configuration. Tiré de l'arborescence publique du dépôt de modèles de WhisperKit (variantes
    /// `large-v3-v20240930_turbo`, `small`, `base` et `tiny` lues : mêmes fichiers). `model.mlmodel` (absent de l'un des
    /// trois) et `TextDecoderContextPrefill` (présent pour la seule variante turbo) ne sont pas exigés.
    static let requiredWhisperFiles: [String] =
        ["config.json", "generation_config.json"]
        + ["AudioEncoder", "MelSpectrogram", "TextDecoder"].flatMap { bundle in
            ["analytics/coremldata.bin", "coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"].map {
                "\(bundle).mlmodelc/\($0)"
            }
        }

    /// Le tokenizer d'une variante : `downloadBase/models/openai/whisper-<variante>` (`tokenizerNameForVariant`).
    static func tokenizerFile(for variant: ModelVariant, in root: URL) -> URL {
        root.appendingPathComponent("models/openai/whisper-\(variant.description)/tokenizer.json")
    }

    static func parakeetFolders(fluidAudioRoot: URL) -> [URL] {
        let models = fluidAudioRoot.appendingPathComponent("Models", isDirectory: true)
        return [
            models.appendingPathComponent(AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent, isDirectory: true),
            models.appendingPathComponent(
                CtcModels.defaultCacheDirectory(for: .ctc110m).lastPathComponent, isDirectory: true),
        ]
    }

    static func voiceDetectorFolder(fluidAudioRoot: URL) -> URL {
        fluidAudioRoot.appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(Repo.vad.folderName, isDirectory: true)
    }

    static var voiceDetectorBundleName: String { ModelNames.VAD.sileroVadFile }

    /// Le dossier d'une variante : celui dont le nom finit par la variante (le filtre `*<variante>/*` de WhisperKit), de
    /// préférence celui qui porte `openai` (comme WhisperKit départage plusieurs dossiers).
    static func whisperFolder(for variant: String, in root: URL) -> URL? {
        let repository = whisperRepository(in: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: repository.path)) ?? []
        let matches = names.filter { $0.hasSuffix(variant) }.sorted()
        guard let name = matches.first(where: { $0.contains("openai") }) ?? (matches.count == 1 ? matches[0] : nil) else {
            return nil
        }
        return repository.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - État sur le disque

    private func whisperState(_ variant: String) -> LocalModel.State {
        guard let folder = Self.whisperFolder(for: variant, in: root) else { return .absent }
        let complete = Self.requiredWhisperFiles.allSatisfy { Self.isNonEmptyFile(folder.appendingPathComponent($0)) }
        return complete ? .ready : .incomplete
    }

    private static func isNonEmptyFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return size > 0
    }

    private func parakeetState() -> LocalModel.State {
        let folders = Self.parakeetFolders(fluidAudioRoot: fluidAudioRoot)
        if AsrModels.modelsExist(at: folders[0], version: .v3) && CtcModels.modelsExist(at: folders[1]) { return .ready }
        return folders.contains { FileManager.default.fileExists(atPath: $0.path) } ? .incomplete : .absent
    }

    private func voiceDetectorState() -> LocalModel.State {
        let folder = Self.voiceDetectorFolder(fluidAudioRoot: fluidAudioRoot)
        guard FileManager.default.fileExists(atPath: folder.path) else { return .absent }
        let ready =
            Self.isDirectory(folder.appendingPathComponent(Self.voiceDetectorBundleName))
            && !Self.containsPartialFile(in: folder)
        return ready ? .ready : .incomplete
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Un `*.partial` est ce qu'un téléchargement de FluidAudio interrompu laisse derrière lui.
    private static func containsPartialFile(in folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else {
            return false
        }
        for case let url as URL in enumerator where url.pathExtension == "partial" { return true }
        return false
    }

    // MARK: - ModelCatalog

    public func models() async -> [LocalModel] {
        func state(_ id: String, onDisk: @autoclosure () -> LocalModel.State) -> LocalModel.State {
            inFlight.contains(id) ? .downloading(fractions[id]) : onDisk()
        }
        var list = [
            LocalModel(
                id: LocalModelID.parakeet, title: "Parakeet",
                detail:
                    "Aperçu du texte en direct pendant que vous parlez, et moteur de dictée possible, très rapide. Comprend le petit modèle qui sert à reconnaître votre vocabulaire.",
                state: state(LocalModelID.parakeet, onDisk: parakeetState()))
        ]
        for variant in whisperVariants {
            let id = LocalModelID.whisper(variant.name)
            list.append(
                LocalModel(
                    id: id, title: variant.title, detail: variant.detail,
                    state: state(id, onDisk: whisperState(variant.name))))
        }
        list.append(
            LocalModel(
                id: LocalModelID.voiceDetector, title: "Détecteur de voix",
                detail: "Repère quand vous parlez, pour ne pas transcrire les silences.",
                state: state(LocalModelID.voiceDetector, onDisk: voiceDetectorState())))
        return list
    }

    /// Pendant le téléchargement, `models()` dit « en cours ». Une fraction n'est rapportée que si la bibliothèque en donne
    /// une pour ce modèle seul : c'est le cas du détecteur de voix (un seul fichier à charger). Pour WhisperKit
    /// (`Progress` compté en fichiers, pas en octets, d'après `HubApi.snapshot`) et pour Parakeet (deux téléchargements
    /// enchaînés, FluidAudio repartant de zéro à chaque fichier), aucune fraction n'est donnée : un partage entre le modèle
    /// et son tokenizer, ou entre deux modèles, serait une invention.
    public func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let title = try title(of: id)
        guard !inFlight.contains(id) else { throw LocalModelCatalogError.alreadyDownloading(id) }
        inFlight.insert(id)
        defer {
            inFlight.remove(id)
            fractions[id] = nil
        }
        if let variant = LocalModelID.whisperVariant(of: id) {
            try await downloadWhisper(variant, title: title)
        } else if id == LocalModelID.parakeet {
            try await downloadParakeet()
        } else {
            // Une fraction qui ne recule jamais : la bibliothèque la fait repartir de zéro à chaque phase.
            let monotonic = MonotonicProgress { fraction in
                progress(fraction)
                Task { await self.record(fraction, of: id) }
            }
            _ = try await VadManager(
                modelDirectory: fluidAudioRoot,
                progressHandler: { monotonic.report($0.fractionCompleted) })
            guard voiceDetectorState() == .ready else { throw LocalModelCatalogError.incomplete(title) }
            monotonic.report(1)
        }
    }

    private func record(_ fraction: Double, of id: String) {
        // Une fraction qui arrive après la fin du téléchargement ne le ressuscite pas.
        if inFlight.contains(id) { fractions[id] = fraction }
    }

    /// Le modèle, puis son tokenizer (pour compter l'amorce du vocabulaire hors ligne).
    private func downloadWhisper(_ variant: String, title: String) async throws {
        _ = try await WhisperKit.download(variant: variant, downloadBase: root)
        if let tokenizerVariant = WhisperKitTranscriber.tokenizerVariant(of: variant) {
            _ = try await ModelUtilities.loadTokenizer(for: tokenizerVariant, tokenizerFolder: root)
        }
        guard whisperState(variant) == .ready else { throw LocalModelCatalogError.incomplete(title) }
    }

    /// Reconnaissance (TDT v3) puis recalage du vocabulaire (CTC).
    private func downloadParakeet() async throws {
        let folders = Self.parakeetFolders(fluidAudioRoot: fluidAudioRoot)
        try await AsrModels.download(to: folders[0], version: .v3)
        try await CtcModels.download(to: folders[1], variant: .ctc110m)
        guard parakeetState() == .ready else { throw LocalModelCatalogError.incomplete("Parakeet") }
    }

    public func delete(_ id: String) async throws {
        _ = try title(of: id)
        guard !inFlight.contains(id) else { throw LocalModelCatalogError.alreadyDownloading(id) }
        if let variant = LocalModelID.whisperVariant(of: id) {
            if let folder = Self.whisperFolder(for: variant, in: root) {
                try removeIfPresent(folder)
                // Les fiches de téléchargement de la bibliothèque : sans elles, un nouveau téléchargement repart de zéro.
                let notes = Self.whisperRepository(in: root)
                    .appendingPathComponent(".cache/huggingface/download/\(folder.lastPathComponent)", isDirectory: true)
                try removeIfPresent(notes)
            }
        } else if id == LocalModelID.parakeet {
            for folder in Self.parakeetFolders(fluidAudioRoot: fluidAudioRoot) { try removeIfPresent(folder) }
        } else {
            try removeIfPresent(Self.voiceDetectorFolder(fluidAudioRoot: fluidAudioRoot))
        }
    }

    private func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Hors ligne seulement : sans tokenizer sur le disque, `nil` (compter obligerait à le télécharger).
    public func promptTokenCount(_ vocabulary: [String], whisperModel: String) async -> Int? {
        guard let variant = WhisperKitTranscriber.tokenizerVariant(of: whisperModel),
            FileManager.default.fileExists(atPath: Self.tokenizerFile(for: variant, in: root).path)
        else { return nil }
        return try? await WhisperKitTranscriber.promptTokenCount(vocabulary, model: whisperModel, tokenizerFolder: root)
    }

    private func title(of id: String) throws -> String {
        if id == LocalModelID.parakeet { return "Parakeet" }
        if id == LocalModelID.voiceDetector { return "Détecteur de voix" }
        if let variant = LocalModelID.whisperVariant(of: id), let known = whisperVariants.first(where: { $0.name == variant }) {
            return known.title
        }
        throw LocalModelCatalogError.unknownModel(id)
    }
}

/// Fractions de téléchargement qui ne reculent jamais, rapportées à `sink`.
private final class MonotonicProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var highest = 0.0
    private let sink: @Sendable (Double) -> Void

    init(sink: @escaping @Sendable (Double) -> Void) { self.sink = sink }

    func report(_ fraction: Double) {
        let value = min(max(fraction, 0), 1)
        let report: Bool = lock.withLock {
            guard value > highest else { return false }
            highest = value
            return true
        }
        if report { sink(value) }
    }
}
