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

        /// Un dossier de variante WhisperKit tel que le téléchargement le laisse : les trois modèles Core ML.
        func makeWhisperFolder(_ name: String, models: [String] = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]) throws {
            let folder = LocalModelCatalog.whisperRepository(in: root).appendingPathComponent(name, isDirectory: true)
            for model in models {
                let bundle = folder.appendingPathComponent("\(model).mlmodelc", isDirectory: true)
                try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
                try Data("x".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
            }
        }

        func markComplete(_ variant: String) throws {
            let marker = LocalModelCatalog.completionMarker(forWhisper: variant, in: root)
            try FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: marker)
        }
    }

    static func state(_ models: [LocalModel], _ id: String) -> LocalModel.State? { models.first { $0.id == id }?.state }

    static let turbo = LocalModelID.whisper("large-v3-v20240930_turbo")

    // MARK: - Liste

    @Test func anEmptyRootListsEveryOfferedModelAbsentInOrder() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let models = await sandbox.catalog().models()
        #expect(models.map(\.id) == [
            LocalModelID.parakeet, Self.turbo, LocalModelID.whisper("small"), LocalModelID.whisper("base"),
            LocalModelID.voiceDetector,
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

    @Test func aWhisperFolderWithItsThreeModelsAndMarkerReadsReady() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small")
        try sandbox.markComplete("small")
        let models = await sandbox.catalog().models()
        #expect(Self.state(models, LocalModelID.whisper("small")) == .ready)
        #expect(Self.state(models, Self.turbo) == .absent)
    }

    @Test func aWhisperFolderWithoutTheCompletionMarkerIsNotReady() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small")  // téléchargement interrompu : pas de marque
        #expect(Self.state(await sandbox.catalog().models(), LocalModelID.whisper("small")) == .absent)
    }

    @Test func aWhisperFolderMissingOneModelIsNotReadyEvenWithTheMarker() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small", models: ["MelSpectrogram", "AudioEncoder"])
        try sandbox.markComplete("small")
        #expect(Self.state(await sandbox.catalog().models(), LocalModelID.whisper("small")) == .absent)
    }

    /// WhisperKit cherche `*<variante>/*` : « small » ne doit pas reconnaître le dossier de « small.en ».
    @Test func aVariantIsMatchedByTheEndOfTheFolderName() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small.en")
        try sandbox.markComplete("small")
        #expect(Self.state(await sandbox.catalog().models(), LocalModelID.whisper("small")) == .absent)
    }

    @Test func theVoiceDetectorReadsReadyOnlyWithItsModelAndNoPartialFile() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let folder = LocalModelCatalog.voiceDetectorFolder(fluidAudioRoot: sandbox.fluidAudio)
        let bundle = folder.appendingPathComponent(LocalModelCatalog.voiceDetectorBundleName, isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: bundle.appendingPathComponent("coremldata.bin"))
        #expect(Self.state(await sandbox.catalog().models(), LocalModelID.voiceDetector) == .ready)

        try Data("x".utf8).write(to: bundle.appendingPathComponent("weight.bin.partial"))
        #expect(Self.state(await sandbox.catalog().models(), LocalModelID.voiceDetector) == .absent)
    }

    // MARK: - Suppression

    @Test func deletingAWhisperModelRemovesItsFolderAndMarkerAndNothingElse() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small")
        try sandbox.markComplete("small")
        try sandbox.makeWhisperFolder("openai_whisper-base")
        try sandbox.markComplete("base")
        let catalog = sandbox.catalog()

        try await catalog.delete(LocalModelID.whisper("small"))

        let models = await catalog.models()
        #expect(Self.state(models, LocalModelID.whisper("small")) == .absent)
        #expect(Self.state(models, LocalModelID.whisper("base")) == .ready)
        let repository = LocalModelCatalog.whisperRepository(in: sandbox.root)
        #expect(!FileManager.default.fileExists(atPath: repository.appendingPathComponent("openai_whisper-small").path))
        #expect(
            !FileManager.default.fileExists(
                atPath: LocalModelCatalog.completionMarker(forWhisper: "small", in: sandbox.root).path))
    }

    @Test func deletingAnAbsentModelIsHarmless() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let catalog = sandbox.catalog()
        try await catalog.delete(LocalModelID.whisper("small"))
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

    @Test func anUnknownModelIsRefusedWithoutTouchingTheDisk() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        let catalog = sandbox.catalog()
        await #expect(throws: LocalModelCatalogError.unknownModel("inconnu")) { try await catalog.delete("inconnu") }
        await #expect(throws: LocalModelCatalogError.unknownModel("whisper:medium")) {
            try await catalog.download("whisper:medium", progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: sandbox.root.path))
    }

    // MARK: - Amorce

    /// Sans tokenizer sur le disque : `nil`, sans réseau et sans rien écrire (jamais dans Documents).
    @Test func theTokenCountIsNilWithoutALocalTokenizerAndWritesNothing() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small")
        try sandbox.markComplete("small")
        let count = await sandbox.catalog().promptTokenCount(["Kubernetes"], whisperModel: "small")
        #expect(count == nil)
        let names = try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path).sorted()
        #expect(names == [".complete", "models"])
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

        let fractions = FractionLog()
        try await catalog.download(id, progress: { fractions.add($0) })
        let seen = fractions.values
        print("[intégration] fractions : premières \(seen.prefix(3)), dernière \(String(describing: seen.last)), \(seen.count) appels")
        #expect(!seen.isEmpty && seen.allSatisfy { (0...1).contains($0) })
        #expect(seen.last == 1)
        #expect(LocalModelCatalogTests.state(await catalog.models(), id) == .ready)

        // Tout est tombé sous la racine temporaire, le tokenizer compris (jamais dans Documents).
        let top = try FileManager.default.contentsOfDirectory(atPath: sandbox.root.path).sorted()
        print("[intégration] sous la racine : \(top)")
        #expect(Set(top).isSubset(of: [".complete", "models"]))
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

private final class FractionLog: Sendable {
    private let storage = Mutex<[Double]>([])
    func add(_ value: Double) { storage.withLock { $0.append(value) } }
    var values: [Double] { storage.withLock { $0 } }
}
