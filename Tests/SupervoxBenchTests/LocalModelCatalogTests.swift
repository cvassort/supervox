import Foundation
import Synchronization
import SupervoxCore
import Testing
import WhisperKit

@testable import SupervoxEngines

/// `LocalModelCatalog` : l'état affiché vient du disque. Les tests unitaires fabriquent des arbres de dossiers dans un
/// dossier temporaire (jamais le dossier de FluidAudio de l'utilisateur, jamais Application Support ni Documents) ; le
/// téléchargement réel est dans `LocalModelCatalogIntegrationTests`, derrière `SUPERVOX_INTEGRATION=1`.
@Suite struct LocalModelCatalogTests {
    /// Une racine de modèles et une racine FluidAudio temporaires, supprimées par `cleanUp`.
    struct Sandbox {
        let directory: URL
        var root: URL { directory.appendingPathComponent("modeles", isDirectory: true) }
        var fluidAudio: URL { directory.appendingPathComponent("FluidAudio", isDirectory: true) }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("supervox-catalog-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }

        func catalog(variants: [LocalModelCatalog.WhisperVariant] = LocalModelCatalog.offeredWhisperVariants)
            -> LocalModelCatalog
        {
            LocalModelCatalog(root: root, fluidAudioRoot: fluidAudio, whisperVariants: variants)
        }

        /// Les trois modèles que le chargeur de WhisperKit lit (`WhisperKit.loadModels` : `MelSpectrogram`, `AudioEncoder`,
        /// `TextDecoder`), chacun en `.mlmodelc` ou en `.mlpackage`.
        static let whisperModels = ["AudioEncoder", "MelSpectrogram", "TextDecoder"]

        /// Les fichiers que le téléchargement dépose à côté des modèles et que le chargeur ne lit pas (arborescence publique
        /// du dépôt de WhisperKit : configuration, et dans chaque `.mlmodelc` les poids et les métadonnées).
        static let unreadFiles =
            ["config.json", "generation_config.json"]
            + whisperModels.flatMap { model in
                ["analytics/coremldata.bin", "metadata.json", "model.mil", "weights/weight.bin"].map {
                    "\(model).mlmodelc/\($0)"
                }
            }

        /// Un dossier de variante WhisperKit. `omitting` : modèles absents ; `empty` : modèles présents mais vides ;
        /// `packaged` : modèles livrés en `.mlpackage` ; `withUnreadFiles` : ajoute les fichiers que le chargeur ne lit pas.
        func makeWhisperFolder(
            _ name: String, omitting: Set<String> = [], empty: Set<String> = [], packaged: Set<String> = [],
            withUnreadFiles: Bool = true
        ) throws {
            let folder = LocalModelCatalog.whisperRepository(in: root).appendingPathComponent(name, isDirectory: true)
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            func write(_ data: Data, to relative: String) throws {
                let url = folder.appendingPathComponent(relative)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url)
            }
            for model in Self.whisperModels where !omitting.contains(model) {
                if packaged.contains(model) {
                    let path = "\(model).mlpackage/Data/com.apple.CoreML/model.mlmodel"
                    try write(empty.contains(model) ? Data() : Data("x".utf8), to: path)
                } else if empty.contains(model) {
                    try fileManager.createDirectory(
                        at: folder.appendingPathComponent("\(model).mlmodelc"), withIntermediateDirectories: true)
                } else {
                    try write(Data("x".utf8), to: "\(model).mlmodelc/coremldata.bin")
                }
            }
            if withUnreadFiles {
                for file in Self.unreadFiles {
                    // Les fichiers d'un modèle absent, vide ou livré en `.mlpackage` n'existent pas dans un `.mlmodelc`.
                    if let model = Self.whisperModels.first(where: { file.hasPrefix($0) }),
                        omitting.contains(model) || empty.contains(model) || packaged.contains(model)
                    {
                        continue
                    }
                    try write(Data("x".utf8), to: file)
                }
            }
        }

        /// Les fiches de téléchargement que la bibliothèque tient à côté du dossier.
        func makeDownloadNotes(for folderName: String) throws -> URL {
            let notes = LocalModelCatalog.whisperRepository(in: root)
                .appendingPathComponent(".cache/huggingface/download/\(folderName)/AudioEncoder.mlmodelc", isDirectory: true)
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: notes.appendingPathComponent("coremldata.bin.metadata"))
            return notes.deletingLastPathComponent()
        }
    }

    static func state(_ models: [LocalModel], _ id: String) -> LocalModel.State? { models.first { $0.id == id }?.state }

    static let turbo = LocalModelID.whisper("large-v3-v20240930_turbo")
    static let small = LocalModelID.whisper("small")

    // MARK: - Liste

    @Test func anEmptyRootListsEveryOfferedModelAbsentInOrder() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let models = await sandbox.catalog().models()
        #expect(models.map(\.id) == [
            LocalModelID.parakeet, Self.turbo, Self.small, LocalModelID.whisper("base"), LocalModelID.voiceDetector,
        ])
        #expect(models.allSatisfy { $0.state == .absent })
        #expect(models.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        // Lister ne crée rien.
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path))
        #expect(!FileManager.default.fileExists(atPath: sandbox.fluidAudio.path))
    }

    @Test func theDefaultVariantIsOfferedFirstAmongTheWhisperModels() {
        #expect(LocalModelCatalog.offeredWhisperVariants.map(\.name) == ["large-v3-v20240930_turbo", "small", "base"])
    }

    // MARK: - État d'une variante WhisperKit, lu du disque seul

    @Test func aWhisperFolderWithTheThreeModelsReadsReady() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small")
        let models = await sandbox.catalog().models()
        #expect(Self.state(models, Self.small) == .ready)
        #expect(Self.state(models, Self.turbo) == .absent)
        // Aucune marque ni fichier ajouté par le catalogue : l'état vient du disque seul.
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path) == ["models"])
    }

    /// « Prêt » veut dire ce que le chargeur lit, et rien d'autre : ni la configuration, ni les poids ni les métadonnées que
    /// le chargeur n'ouvre pas.
    @Test func theThreeModelsAloneAreEnoughTheFilesTheLoaderDoesNotReadAreNotRequired() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small", withUnreadFiles: false)
        #expect(Self.state(await sandbox.catalog().models(), Self.small) == .ready)
    }

    @Test(arguments: ["AudioEncoder", "MelSpectrogram", "TextDecoder"])
    func aWhisperFolderMissingOneOfTheThreeModelsReadsIncomplete(model: String) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small", omitting: [model])
        #expect(Self.state(await sandbox.catalog().models(), Self.small) == .incomplete)
    }

    @Test(arguments: ["AudioEncoder", "MelSpectrogram", "TextDecoder"])
    func anEmptyModelReadsIncomplete(model: String) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small", empty: [model])
        #expect(Self.state(await sandbox.catalog().models(), Self.small) == .incomplete)
    }

    @Test func aModelShippedAsAnMlpackageReadsReady() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small", packaged: ["AudioEncoder", "TextDecoder"])
        #expect(Self.state(await sandbox.catalog().models(), Self.small) == .ready)
        try sandbox.makeWhisperFolder("openai_whisper-base", packaged: ["AudioEncoder", "MelSpectrogram", "TextDecoder"], withUnreadFiles: false)
        #expect(Self.state(await sandbox.catalog().models(), LocalModelID.whisper("base")) == .ready)
    }

    @Test func anEmptyMlpackageModelReadsIncomplete() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small", empty: ["TextDecoder"], packaged: ["TextDecoder"])
        #expect(Self.state(await sandbox.catalog().models(), Self.small) == .incomplete)
    }

    /// Le chargeur préfère le `.mlmodelc` (`ModelUtilities.detectModelURL`) : un `.mlmodelc` vide n'est pas sauvé par un
    /// `.mlpackage` à côté.
    @Test func anEmptyCompiledModelIsNotRescuedByAPackageBesideIt() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small", empty: ["TextDecoder"])
        let package = LocalModelCatalog.whisperRepository(in: sandbox.root)
            .appendingPathComponent("openai_whisper-small/TextDecoder.mlpackage/Data/com.apple.CoreML", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: package.appendingPathComponent("model.mlmodel"))
        #expect(Self.state(await sandbox.catalog().models(), Self.small) == .incomplete)
    }

    @Test func aPresentButEmptyFolderReadsIncompleteNotAbsent() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let folder = LocalModelCatalog.whisperRepository(in: sandbox.root).appendingPathComponent("openai_whisper-small")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(Self.state(await sandbox.catalog().models(), Self.small) == .incomplete)
    }

    /// WhisperKit cherche `*<variante>/*` : « small » ne doit pas reconnaître le dossier de « small.en ».
    @Test func aVariantIsMatchedByTheEndOfTheFolderName() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small.en")
        #expect(Self.state(await sandbox.catalog().models(), Self.small) == .absent)
    }

    @Test func theVoiceDetectorReadsReadyThenIncompleteWithAPartialFileThenAbsent() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let folder = LocalModelCatalog.voiceDetectorFolder(fluidAudioRoot: sandbox.fluidAudio)
        #expect(Self.state(await sandbox.catalog().models(), LocalModelID.voiceDetector) == .absent)

        let bundle = folder.appendingPathComponent(LocalModelCatalog.voiceDetectorBundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
        #expect(Self.state(await sandbox.catalog().models(), LocalModelID.voiceDetector) == .ready)

        try Data("x".utf8).write(to: bundle.appendingPathComponent("weight.bin.partial"))
        #expect(Self.state(await sandbox.catalog().models(), LocalModelID.voiceDetector) == .incomplete)
    }

    @Test func aVoiceDetectorFolderWithoutItsModelReadsIncomplete() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let folder = LocalModelCatalog.voiceDetectorFolder(fluidAudioRoot: sandbox.fluidAudio)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(Self.state(await sandbox.catalog().models(), LocalModelID.voiceDetector) == .incomplete)
    }

    /// Un dossier de Parakeet sans les fichiers que `AsrModels.modelsExist` attend : incomplet, jamais prêt.
    @Test func aParakeetFolderWithoutTheExpectedFilesReadsIncomplete() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let folders = LocalModelCatalog.parakeetFolders(fluidAudioRoot: sandbox.fluidAudio)
        try FileManager.default.createDirectory(at: folders[0], withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folders[0].appendingPathComponent("fichier"))
        #expect(Self.state(await sandbox.catalog().models(), LocalModelID.parakeet) == .incomplete)
    }

    // MARK: - Suppression

    @Test func deletingAWhisperModelRemovesItsFolderAndItsDownloadNotesAndNothingElse() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small")
        let smallNotes = try sandbox.makeDownloadNotes(for: "openai_whisper-small")
        try sandbox.makeWhisperFolder("openai_whisper-base")
        let baseNotes = try sandbox.makeDownloadNotes(for: "openai_whisper-base")
        let catalog = sandbox.catalog()

        try await catalog.delete(Self.small)

        let models = await catalog.models()
        #expect(Self.state(models, Self.small) == .absent)
        #expect(Self.state(models, LocalModelID.whisper("base")) == .ready)
        let repository = LocalModelCatalog.whisperRepository(in: sandbox.root)
        #expect(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("openai_whisper-small").path))
        #expect(!FileManager.default.fileExists(atPath: smallNotes.path))
        #expect(FileManager.default.fileExists(atPath: baseNotes.path))
    }

    @Test func anIncompleteWhisperModelCanBeDeleted() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small", omitting: ["TextDecoder"])
        let catalog = sandbox.catalog()
        #expect(Self.state(await catalog.models(), Self.small) == .incomplete)
        try await catalog.delete(Self.small)
        #expect(Self.state(await catalog.models(), Self.small) == .absent)
    }

    @Test func deletingAnAbsentModelIsHarmless() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let catalog = sandbox.catalog()
        try await catalog.delete(Self.small)
        try await catalog.delete(LocalModelID.parakeet)
        try await catalog.delete(LocalModelID.voiceDetector)
    }

    @Test func deletingParakeetRemovesOnlyItsFoldersUnderTheGivenFluidAudioRoot() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let folders = LocalModelCatalog.parakeetFolders(fluidAudioRoot: sandbox.fluidAudio)
        #expect(folders.count == 2)
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("fichier"))
        }
        let neighbour = sandbox.fluidAudio.appendingPathComponent("Models/autre-modele", isDirectory: true)
        try FileManager.default.createDirectory(at: neighbour, withIntermediateDirectories: true)

        try await sandbox.catalog().delete(LocalModelID.parakeet)

        for folder in folders { #expect(!FileManager.default.fileExists(atPath: folder.path)) }
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
        // Les dossiers sont bien sous la racine donnée, pas sous celui de l'utilisateur.
        #expect(folders.allSatisfy { $0.path.hasPrefix(sandbox.fluidAudio.path) })
    }

    @Test(arguments: ["inconnu", "", "whisper:", "whisper:../small", "whisper:medium", "../parakeet"])
    func anUnlistedIdentifierIsRefusedWithoutTouchingTheDisk(id: String) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let catalog = sandbox.catalog()
        await #expect(throws: LocalModelCatalogError.unknownModel(id)) { try await catalog.delete(id) }
        await #expect(throws: LocalModelCatalogError.unknownModel(id)) {
            try await catalog.download(id, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path))
    }

    // MARK: - Amorce

    /// Sans tokenizer sur le disque : `nil`, sans réseau et sans rien écrire (jamais dans Documents).
    @Test func theTokenCountIsNilWithoutALocalTokenizerAndWritesNothing() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small")
        let count = await sandbox.catalog().promptTokenCount(["Kubernetes"], whisperModel: "small")
        #expect(count == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path) == ["models"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.root.appendingPathComponent("models").path) == ["argmaxinc"])
    }

    @Test func theTokenCountOfAnUnknownVariantNameIsNil() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        #expect(await sandbox.catalog().promptTokenCount(["x"], whisperModel: "modèle-inconnu") == nil)
    }

    // MARK: - WhisperKitTranscriber

    @Test func whisperKitIsConfiguredWithTheGivenDownloadBase() {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("supervox-base")
        let config = WhisperKitTranscriber.configuration(model: "small", downloadBase: base)
        #expect(config.downloadBase == base)
        #expect(config.model == "small")
        #expect(config.load == true)
        #expect(WhisperKitTranscriber.configuration(model: "small", downloadBase: nil).downloadBase == nil)
    }
}

/// Téléchargement réel d'une petite variante WhisperKit dans un dossier temporaire : `SUPERVOX_INTEGRATION=1`.
/// Ne touche ni les modèles de Parakeet ni le détecteur de voix (le dossier FluidAudio de l'utilisateur) : seul WhisperKit
/// est téléchargé, la plus petite variante, sous la racine temporaire.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_INTEGRATION"] == "1"))
struct LocalModelCatalogIntegrationTests {
    @Test func downloadingTheSmallestVariantIsReflectedOnDiskThenDeleted() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        let tiny = LocalModelCatalog.WhisperVariant(name: "tiny", title: "Whisper tiny", detail: "Le plus petit.")
        let id = LocalModelID.whisper("tiny")
        let catalog = sandbox.catalog(variants: [tiny])
        #expect(LocalModelCatalogTests.state(await catalog.models(), id) == .absent)

        // Pendant le téléchargement, le catalogue dit « en cours » sans fraction inventée.
        let observed = StateLog()
        let watcher = Task {
            while !Task.isCancelled {
                observed.add(LocalModelCatalogTests.state(await catalog.models(), id))
                await Task.yield()
            }
        }
        try await catalog.download(id, progress: { _ in })
        watcher.cancel()
        let states = observed.values
        print("[intégration] états vus pendant le téléchargement : \(Set(states.map { String(describing: $0) }).sorted())")
        #expect(states.contains { $0 == .downloading(nil) })
        #expect(LocalModelCatalogTests.state(await catalog.models(), id) == .ready)

        // Tout est tombé sous la racine temporaire, le tokenizer compris (jamais dans Documents), et l'état vient du
        // disque seul : les fichiers attendus (copie indépendante de la liste du dépôt) y sont tous.
        let top = try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path).sorted()
        print("[intégration] sous la racine : \(top)")
        #expect(top == ["models"])
        let repository = LocalModelCatalog.whisperRepository(in: sandbox.root).appendingPathComponent("openai_whisper-tiny")
        for model in LocalModelCatalogTests.Sandbox.whisperModels {
            #expect(FileManager.default.fileExists(atPath: repository.appendingPathComponent("\(model).mlmodelc").path), "\(model)")
        }
        let tokenizer = sandbox.root.appendingPathComponent("models/openai/whisper-tiny/tokenizer.json")
        #expect(FileManager.default.fileExists(atPath: tokenizer.path))

        // Le compte d'amorce se fait avec ce tokenizer local.
        let count = try #require(await catalog.promptTokenCount(["Kubernetes", "PostgreSQL"], whisperModel: "tiny"))
        #expect(count > 0)

        // Un second catalogue sur la même racine relit le disque.
        let reopened = sandbox.catalog(variants: [tiny])
        #expect(LocalModelCatalogTests.state(await reopened.models(), id) == .ready)

        try await reopened.delete(id)
        #expect(LocalModelCatalogTests.state(await reopened.models(), id) == .absent)
    }
}

private final class StateLog: Sendable {
    private let storage = Mutex<[LocalModel.State?]>([])
    func add(_ value: LocalModel.State?) { storage.withLock { $0.append(value) } }
    var values: [LocalModel.State?] { storage.withLock { $0 } }
}
