import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxEngines

/// Un seul téléchargement par modèle, partagé entre la fenêtre de réglages et les dictées ; visible dans la liste ;
/// la suppression est refusée pendant ce temps. Le téléchargement est remplacé par un double qui attend une porte : aucun
/// réseau, aucun vrai modèle, tout dans un dossier temporaire.
@Suite(.timeLimit(.minutes(1))) struct LocalModelCatalogDownloadTests {
    typealias Gate = EnginePrepareTests.Gate

    struct Failure: Error, LocalizedError, Equatable {
        var errorDescription: String? { "panne de réseau" }
    }

    /// Ce que le double de téléchargement a reçu, et ce qu'il attend.
    final class Downloads: Sendable {
        private let log = Mutex<[String]>([])
        let entered = Gate()
        let release = Gate()
        private let failuresLeft = Mutex(0)

        var started: [String] { log.withLock { $0 } }
        func failNext(_ count: Int = 1) { failuresLeft.withLock { $0 = count } }

        var downloader: LocalModelCatalog.Downloader {
            { [self] id, _ in
                log.withLock { $0.append(id) }
                entered.open()
                await release.wait()
                let fail = failuresLeft.withLock { left -> Bool in
                    guard left > 0 else { return false }
                    left -= 1
                    return true
                }
                if fail { throw Failure() }
            }
        }
    }

    private func catalog(_ sandbox: LocalModelCatalogTests.Sandbox, _ downloads: Downloads) -> LocalModelCatalog {
        LocalModelCatalog(
            root: sandbox.root, fluidAudioRoot: sandbox.fluidAudio,
            whisperVariants: LocalModelCatalog.offeredWhisperVariants, downloader: downloads.downloader)
    }

    private func settle() async {
        for _ in 0..<200 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }

    static let small = LocalModelID.whisper("small")

    // MARK: - Un seul téléchargement

    @Test func ensuringAModelThatIsBeingDownloadedWaitsForTheSameDownload() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        let downloads = Downloads()
        defer { downloads.release.open() }
        let catalog = catalog(sandbox, downloads)

        // Le bouton de la fenêtre de réglages.
        let fromSettings = Task { try await catalog.download(Self.small, progress: { _ in }) }
        await downloads.entered.wait()
        // Une dictée qui manque du même modèle.
        let fromDictation = Task { try await catalog.ensureDownloaded(Self.small) }
        await settle()
        #expect(downloads.started == [Self.small])

        // La fenêtre de réglages le voit « en cours ».
        let during = await catalog.models()
        #expect(LocalModelCatalogTests.state(during, Self.small) == .downloading(nil))
        #expect(await catalog.state(of: Self.small) == .downloading(nil))

        downloads.release.open()
        try await fromSettings.value
        try await fromDictation.value
        #expect(downloads.started == [Self.small])
        #expect(LocalModelCatalogTests.state(await catalog.models(), Self.small) != .downloading(nil))
    }

    @Test func aDownloadStartedByADictationIsVisibleInTheListAndBlocksTheSettingsButton() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        let downloads = Downloads()
        defer { downloads.release.open() }
        let catalog = catalog(sandbox, downloads)

        let fromDictation = Task { try await catalog.ensureDownloaded(Self.small) }
        await downloads.entered.wait()
        #expect(LocalModelCatalogTests.state(await catalog.models(), Self.small) == .downloading(nil))

        // Le bouton « Télécharger » de la fenêtre n'en lance pas un second dans le même dossier. L'appel est lancé à part et
        // la porte ouverte ensuite : un second téléchargement fautif attendrait la porte sans jamais pendre le test.
        let button = Task { try await catalog.download(Self.small, progress: { _ in }) }
        await settle()
        #expect(downloads.started == [Self.small])
        downloads.release.open()
        await #expect(throws: ModelCatalogRefusal.busyDownloading) { try await button.value }
        try await fromDictation.value
    }

    @Test func aFailedDownloadReachesEveryoneWhoWaitedAndCanBeRetried() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        let downloads = Downloads()
        defer { downloads.release.open() }
        downloads.failNext()
        let catalog = catalog(sandbox, downloads)

        let first = Task { try await catalog.ensureDownloaded(Self.small) }
        await downloads.entered.wait()
        let second = Task { try await catalog.ensureDownloaded(Self.small) }
        await settle()
        downloads.release.open()
        for task in [first, second] { await #expect(throws: Failure.self) { try await task.value } }
        #expect(downloads.started == [Self.small])

        // La place est libérée : l'essai suivant relance.
        try await catalog.ensureDownloaded(Self.small)
        #expect(downloads.started == [Self.small, Self.small])
    }

    @Test func ensuringAnUnknownModelFailsWithoutDownloading() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        let downloads = Downloads()
        defer { downloads.release.open() }
        let catalog = catalog(sandbox, downloads)
        await #expect(throws: LocalModelCatalogError.unknownModel("whisper:medium")) {
            try await catalog.ensureDownloaded("whisper:medium")
        }
        #expect(downloads.started.isEmpty)
    }

    // MARK: - Suppression refusée pendant un téléchargement

    @Test func deletingAModelThatIsBeingDownloadedIsRefusedWithAClearMessageAndTouchesNothing() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small")
        let downloads = Downloads()
        defer { downloads.release.open() }
        let catalog = catalog(sandbox, downloads)

        // Le bouton « Télécharger » (Réessayer) d'un modèle incomplet : `ensureDownloaded` ne retélécharge pas un modèle prêt.
        let download = Task { try await catalog.download(Self.small, progress: { _ in }) }
        await downloads.entered.wait()

        do {
            try await catalog.delete(Self.small)
            Issue.record("la suppression aurait dû être refusée")
        } catch {
            #expect(error as? ModelCatalogRefusal == .busyDownloading)
        }
        let folder = LocalModelCatalog.whisperRepository(in: sandbox.root).appendingPathComponent("openai_whisper-small")
        #expect(FileManager.default.fileExists(atPath: folder.path))

        downloads.release.open()
        try await download.value
        // Le téléchargement fini, la suppression passe.
        try await catalog.delete(Self.small)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func deletingParakeetIsRefusedWhileItsVocabularyModelIsBeingDownloaded() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        let downloads = Downloads()
        defer { downloads.release.open() }
        let catalog = catalog(sandbox, downloads)

        let download = Task { try await catalog.ensureDownloaded(LocalModelID.parakeetVocabulary) }
        await downloads.entered.wait()
        #expect(await catalog.state(of: LocalModelID.parakeetVocabulary) == .downloading(nil))
        await #expect(throws: ModelCatalogRefusal.busyDownloading) {
            try await catalog.delete(LocalModelID.parakeet)
        }
        downloads.release.open()
        try await download.value
        #expect(await catalog.state(of: LocalModelID.parakeetVocabulary) == .absent)
    }

    // MARK: - Parakeet et le petit modèle de vocabulaire

    /// Le bouton de la ligne Parakeet télécharge la reconnaissance puis le petit modèle de vocabulaire.
    @Test func theParakeetButtonDownloadsTheTranscriptionModelThenTheVocabularyModel() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        let downloads = Downloads()
        downloads.release.open()
        let catalog = catalog(sandbox, downloads)
        try await catalog.download(LocalModelID.parakeet, progress: { _ in })
        #expect(downloads.started == [LocalModelID.parakeet, LocalModelID.parakeetVocabulary])
    }

    /// N1 : une dictée ne télécharge que ce dont elle a besoin. Demander Parakeet à une dictée (aperçu, moteur final) ne
    /// télécharge que sa reconnaissance : le petit modèle de vocabulaire est demandé à part, et seulement avec un vocabulaire.
    @Test func ensuringParakeetDownloadsOnlyTheTranscriptionModel() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        let downloads = Downloads()
        downloads.release.open()
        let catalog = catalog(sandbox, downloads)
        try await catalog.ensureDownloaded(LocalModelID.parakeet)
        #expect(downloads.started == [LocalModelID.parakeet])
        try await catalog.ensureDownloaded(LocalModelID.parakeetVocabulary)
        #expect(downloads.started == [LocalModelID.parakeet, LocalModelID.parakeetVocabulary])
    }

    @Test func ensuringAModelThatIsAlreadyOnDiskDownloadsNothing() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        try sandbox.makeWhisperFolder("openai_whisper-small")
        let downloads = Downloads()
        downloads.release.open()
        let catalog = catalog(sandbox, downloads)
        #expect(await catalog.state(of: Self.small) == .ready)
        try await catalog.ensureDownloaded(Self.small)
        #expect(downloads.started.isEmpty)
    }

    @Test func everyOtherModelIsOneStep() {
        #expect(LocalModelCatalog.steps(for: LocalModelID.voiceDetector) == [LocalModelID.voiceDetector])
        #expect(LocalModelCatalog.steps(for: Self.small) == [Self.small])
        #expect(LocalModelCatalog.steps(for: LocalModelID.parakeetVocabulary) == [LocalModelID.parakeetVocabulary])
    }

    @Test(arguments: [
        (true, true, LocalModel.State.ready), (true, false, .ready), (false, true, .incomplete),
        (false, false, .absent),
    ])
    func parakeetIsReadyWhenItsTranscriptionModelIsThere(asrReady: Bool, folder: Bool, expected: LocalModel.State) {
        #expect(LocalModelCatalog.parakeetState(asrReady: asrReady, asrFolderExists: folder) == expected)
    }

    @Test func theNoteAppearsOnlyForAReadyParakeetWithoutItsVocabularyModel() {
        let note = LocalModelCatalog.parakeetNote(asr: .ready, vocabularyReady: false)
        #expect(note?.contains("vocabulaire") == true)
        #expect(note?.contains("première dictée") == true)
        #expect(LocalModelCatalog.parakeetNote(asr: .ready, vocabularyReady: true) == nil)
        for asr in [LocalModel.State.absent, .incomplete, .downloading(nil), .failed("x")] {
            #expect(LocalModelCatalog.parakeetNote(asr: asr, vocabularyReady: false) == nil)
        }
    }

    @Test func theVocabularyModelIsNotAListedRowButHasAState() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        let catalog = sandbox.catalog()
        #expect(await catalog.models().contains { $0.id == LocalModelID.parakeetVocabulary } == false)
        #expect(await catalog.state(of: LocalModelID.parakeetVocabulary) == .absent)
        #expect(await catalog.state(of: "inconnu") == nil)

        let folder = LocalModelCatalog.parakeetFolders(fluidAudioRoot: sandbox.fluidAudio)[1]
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("fichier"))
        #expect(await catalog.state(of: LocalModelID.parakeetVocabulary) == .incomplete)
    }

    @Test func deletingTheVocabularyModelRemovesItsFolderAndLeavesTheTranscriptionModel() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        let folders = LocalModelCatalog.parakeetFolders(fluidAudioRoot: sandbox.fluidAudio)
        for folder in folders {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: folder.appendingPathComponent("fichier"))
        }
        try await sandbox.catalog().delete(LocalModelID.parakeetVocabulary)
        #expect(FileManager.default.fileExists(atPath: folders[0].path))
        #expect(!FileManager.default.fileExists(atPath: folders[1].path))
    }

    @Test func theParakeetRowOfAnEmptyDiskIsAbsentWithoutANote() async throws {
        let sandbox = try LocalModelCatalogTests.Sandbox()
        defer { sandbox.cleanUp() }
        let parakeet = try #require(await sandbox.catalog().models().first { $0.id == LocalModelID.parakeet })
        #expect(parakeet.state == .absent)
        #expect(parakeet.note == nil)
    }
}
