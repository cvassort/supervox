import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Catalogue double : états en mémoire, téléchargement piloté par le test, appels notés. Ne touche ni le disque ni le réseau.
final class FakeModelCatalog: ModelCatalog {
    typealias DownloadBehavior = @Sendable (String, @escaping @Sendable (Double) -> Void) async throws -> Void

    private struct State {
        var models: [LocalModel]
        var downloads: [String] = []
        var deletions: [String] = []
        var countRequests: [(vocabulary: [String], model: String)] = []
        var listCount = 0
        /// Retient le premier comptage de jetons tant qu'elle n'est pas ouverte.
        var firstCountGate: Gate?
        /// Retient le prochain `models()` tant qu'elle n'est pas ouverte.
        var nextListingGate: Gate?
        var tokenCount: Int?
        var download: DownloadBehavior = { _, _ in }
        var deleteFailure: (any Error)?
    }

    private let state: Mutex<State>

    init(models: [LocalModel]) { state = Mutex(State(models: models)) }

    static let parakeet = LocalModel(id: LocalModelID.parakeet, title: "Parakeet", detail: "", state: .absent)
    static let turbo = LocalModel(
        id: LocalModelID.whisper("large-v3-v20240930_turbo"), title: "Turbo", detail: "", state: .ready)
    static let small = LocalModel(id: LocalModelID.whisper("small"), title: "Small", detail: "", state: .absent)

    var downloads: [String] { state.withLock { $0.downloads } }
    var deletions: [String] { state.withLock { $0.deletions } }
    var listCount: Int { state.withLock { $0.listCount } }
    var countRequests: [(vocabulary: [String], model: String)] { state.withLock { $0.countRequests } }
    func holdNextListing(_ gate: Gate) { state.withLock { $0.nextListingGate = gate } }
    func holdFirstCount(_ gate: Gate) { state.withLock { $0.firstCountGate = gate } }
    func setTokenCount(_ count: Int?) { state.withLock { $0.tokenCount = count } }
    func setDownload(_ behavior: @escaping DownloadBehavior) { state.withLock { $0.download = behavior } }
    /// Change l'état que le disque (le double) rend pour ce modèle.
    func setDiskState(_ newState: LocalModel.State, of id: String) { setState(newState, of: id) }
    func setDeleteFailure(_ error: (any Error)?) { state.withLock { $0.deleteFailure = error } }

    func models() async -> [LocalModel] {
        let gate = state.withLock { state in
            state.listCount += 1
            defer { state.nextListingGate = nil }
            return state.nextListingGate
        }
        // L'état est lu après l'attente : une liste retenue montre le disque tel qu'il est quand elle repart.
        if let gate { await gate.wait() }
        return state.withLock { $0.models }
    }

    func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let behavior = state.withLock { state in
            state.downloads.append(id)
            return state.download
        }
        try await behavior(id, progress)
        setState(.ready, of: id)
    }

    func delete(_ id: String) async throws {
        try state.withLock { state in
            state.deletions.append(id)
            if let failure = state.deleteFailure { throw failure }
        }
        setState(.absent, of: id)
    }

    func promptTokenCount(_ vocabulary: [String], whisperModel: String) async -> Int? {
        let gate = state.withLock { state in
            state.countRequests.append((vocabulary, whisperModel))
            defer { state.firstCountGate = nil }
            return state.firstCountGate
        }
        if let gate { await gate.wait() }
        return state.withLock { $0.tokenCount }
    }

    private func setState(_ newState: LocalModel.State, of id: String) {
        state.withLock { state in
            if let index = state.models.firstIndex(where: { $0.id == id }) { state.models[index].state = newState }
        }
    }
}

/// Garde la fonction de progression reçue par le catalogue, pour la rappeler après la fin du téléchargement.
final class ProgressBox: Sendable {
    private let stored = Mutex<(@Sendable (Double) -> Void)?>(nil)
    func keep(_ progress: @escaping @Sendable (Double) -> Void) { stored.withLock { $0 = progress } }
    func call(_ fraction: Double) { stored.withLock { $0 }?(fraction) }
}

@MainActor final class TranscriptionSaver {
    var saved: [TranscriptionSettings] = []
    var failure: (any Error)?

    func save(_ settings: TranscriptionSettings) throws {
        if let failure { throw failure }
        saved.append(settings)
    }
}

/// Laisse passer un nombre fixe de tours pour prouver qu'une chose n'arrive PAS (`condition` reste fausse). Une absence ne
/// se prouve pas par un signal : le pire qu'un faux départ puisse donner est un faux succès, jamais un faux échec.
@MainActor func settleAbsence(of condition: @MainActor () -> Bool) async {
    for _ in 0..<10_000 where !condition() { await Task.yield() }
}

/// Rend la main au fil principal jusqu'à ce que `condition` soit vraie, et rend aussitôt qu'elle l'est. Les méthodes du
/// catalogue double travaillent sur le pool global : un nombre fixe de `Task.yield()` pouvait finir avant elles sur une machine
/// chargée. L'attente cède donc aussi le fil quelques millisecondes à intervalles réguliers, et ne s'arrête que sur la
/// condition ou, par sécurité seulement (un test qui échoue), au bout de 30 s : aucune durée n'est jamais attendue quand la
/// condition vient.
@MainActor func settle(_ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    var round = 0
    while !condition(), ContinuousClock.now < deadline {
        round += 1
        if round % 20 == 0 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
    }
}

@MainActor @Suite struct TranscriptionModelTests {
    let catalog = FakeModelCatalog(models: [
        FakeModelCatalog.parakeet, FakeModelCatalog.turbo, FakeModelCatalog.small,
    ])
    let saver = TranscriptionSaver()

    /// Valeur de `WhisperKitTranscriber.promptTokenLimit`, fixée par `EngineIntegrationTests.whisperKitPromptBudget`.
    static let limit = 111

    /// Vrai pendant qu'une dictée est en cours (le contrôleur de dictée, ici un drapeau).
    let dictating = DictatingFlag()

    @MainActor final class DictatingFlag { var value = false }

    func makeModel(_ settings: TranscriptionSettings = .defaults) -> TranscriptionModel {
        let saver = saver
        let dictating = dictating
        return TranscriptionModel(
            settings: settings, catalog: catalog, promptTokenLimit: Self.limit,
            isDictating: { dictating.value }, save: { try saver.save($0) })
    }

    static func state(_ model: TranscriptionModel, _ id: String) -> LocalModel.State? {
        model.models.first { $0.id == id }?.state
    }

    // MARK: - Liste

    @Test func refreshListsTheCatalogModels() async {
        let model = makeModel()
        #expect(model.models.isEmpty)
        await model.refresh()
        #expect(model.models.map(\.id) == [LocalModelID.parakeet, FakeModelCatalog.turbo.id, FakeModelCatalog.small.id])
        #expect(Self.state(model, LocalModelID.parakeet) == .absent)
        #expect(Self.state(model, FakeModelCatalog.turbo.id) == .ready)
    }

    @Test func theListIsKnownOnlyAfterTheFirstRefresh() async {
        let model = makeModel()
        #expect(!model.hasListed)
        await model.refresh()
        #expect(model.hasListed)
    }

    // MARK: - Lignes de l'onglet

    @Test func eachStateOffersTheRightButtons() {
        func labels(_ state: LocalModel.State) -> [String] { TranscriptionModel.actions(for: state).map(\.label) }
        func kinds(_ state: LocalModel.State) -> [TranscriptionModel.RowAction.Kind] {
            TranscriptionModel.actions(for: state).map(\.kind)
        }
        #expect(labels(.absent) == ["Télécharger"])
        #expect(kinds(.absent) == [.download])
        // Incomplet : supprimer ce qui reste, ou le compléter.
        #expect(labels(.incomplete) == ["Supprimer…", "Télécharger"])
        #expect(kinds(.incomplete) == [.delete, .download])
        #expect(labels(.ready) == ["Supprimer…"])
        #expect(kinds(.ready) == [.delete])
        #expect(labels(.failed("x")) == ["Réessayer", "Supprimer…"])
        #expect(kinds(.failed("x")) == [.download, .delete])
        #expect(labels(.downloading(0.4)).isEmpty)
        #expect(labels(.downloading(nil)).isEmpty)
    }

    @Test func eachStateHasAReadableLabel() {
        #expect(TranscriptionModel.stateLabel(.absent) == "Non téléchargé")
        #expect(TranscriptionModel.stateLabel(.incomplete) == "Incomplet : des fichiers manquent")
        #expect(TranscriptionModel.stateLabel(.ready) == "Prêt")
        #expect(TranscriptionModel.stateLabel(.downloading(0.4)) == "Téléchargement : 40 %")
        #expect(TranscriptionModel.stateLabel(.downloading(0)) == "Téléchargement : 0 %")
        #expect(TranscriptionModel.stateLabel(.downloading(1)) == "Téléchargement : 100 %")
        // Sans fraction donnée par la bibliothèque : aucun pourcentage.
        #expect(TranscriptionModel.stateLabel(.downloading(nil)) == "Téléchargement en cours…")
        #expect(TranscriptionModel.stateLabel(.failed("Le téléchargement a échoué : réseau.")) == "Le téléchargement a échoué : réseau.")
    }

    @Test func theWhisperVariantsAreTheWhisperRowsOfTheList() async {
        let model = makeModel()
        await model.refresh()
        #expect(model.whisperModels.map(\.id) == [FakeModelCatalog.turbo.id, FakeModelCatalog.small.id])
        #expect(TranscriptionModel.whisperVariant(of: FakeModelCatalog.small) == "small")
        #expect(TranscriptionModel.whisperVariant(of: FakeModelCatalog.parakeet) == nil)
    }

    /// Le bouton « Enregistrer le vocabulaire » s'éteint quand la saisie, mise en forme comme à l'enregistrement, est déjà enregistrée.
    @Test func theSaveButtonIsOffOnlyWhenTheDraftEqualsTheSavedList() {
        #expect(PendingVocabulary.isUnchanged(draft: "Docker\n\n  Sentry \nDocker", saved: ["Docker", "Sentry"]))
        #expect(PendingVocabulary.isUnchanged(draft: "", saved: []))
        #expect(!PendingVocabulary.isUnchanged(draft: "Docker", saved: ["Docker", "Sentry"]))
        #expect(!PendingVocabulary.isUnchanged(draft: "Docker\nSentry", saved: []))
    }

    // MARK: - Enregistrement des changements

    @Test func everyChangeIsSavedWithTheWholeSettings() async {
        let model = makeModel()
        model.setEngine(.parakeet)
        model.setWhisperModel("small")
        model.setLanguage("en")
        await model.setVocabulary(text: "Docker")
        #expect(saver.saved.count == 4)
        #expect(saver.saved.last == TranscriptionSettings(
            engine: .parakeet, whisperModel: "small", language: "en", vocabulary: ["Docker"]))
        #expect(model.settings == saver.saved.last)
    }

    @Test func aFailedSaveBringsBackThePreviousValueAndSaysWhy() async {
        let model = makeModel()
        saver.failure = SaveFailure()

        model.setEngine(.parakeet)
        #expect(model.settings.engine == .whisperKit)
        #expect(model.message?.contains("disque plein") == true)

        model.setWhisperModel("small")
        #expect(model.settings.whisperModel == TranscriptionSettings.defaults.whisperModel)

        model.setLanguage("en")
        #expect(model.settings.language == "fr")

        await model.setVocabulary(text: "Docker")
        #expect(model.settings.vocabulary == [])
        #expect(model.vocabularyText == "")
        #expect(model.message?.contains("disque plein") == true)
        #expect(saver.saved.isEmpty)
    }

    @Test func aSuccessfulChangeClearsThePreviousMessage() {
        let model = makeModel()
        saver.failure = SaveFailure()
        model.setEngine(.parakeet)
        #expect(model.message != nil)
        saver.failure = nil
        model.setEngine(.parakeet)
        #expect(model.message == nil)
        #expect(model.settings.engine == .parakeet)
    }

    @Test func aBlankLanguageIsIgnored() {
        let model = makeModel()
        model.setLanguage("  ")
        #expect(model.settings == .defaults)
        #expect(saver.saved.isEmpty)
    }

    // MARK: - Vocabulaire

    @Test func vocabularyIsOneTermPerLineWithoutBlankLinesOrDuplicates() async {
        let model = makeModel()
        catalog.setTokenCount(5)
        await model.setVocabulary(text: "Kubernetes\n\n  Docker  \nKubernetes\r\n   \nSentry\n")
        #expect(model.settings.vocabulary == ["Kubernetes", "Docker", "Sentry"])
        #expect(model.vocabularyText == "Kubernetes\nDocker\nSentry")
        #expect(catalog.countRequests.last?.vocabulary == ["Kubernetes", "Docker", "Sentry"])
        #expect(catalog.countRequests.last?.model == TranscriptionSettings.defaults.whisperModel)
    }

    @Test func vocabularyBeyondThePromptLimitIsRefusedAndTheOldOneKept() async {
        let model = makeModel(
            TranscriptionSettings(engine: .whisperKit, whisperModel: "small", language: "fr", vocabulary: ["Ancien"]))
        catalog.setTokenCount(Self.limit + 1)
        await model.setVocabulary(text: "un\ndeux")
        #expect(model.settings.vocabulary == ["Ancien"])
        #expect(model.vocabularyText == "Ancien")
        #expect(saver.saved.isEmpty)
        // Les deux nombres : ce que la liste demande, et ce que le moteur accepte.
        #expect(model.message?.contains("\(Self.limit + 1)") == true)
        #expect(model.message?.contains("\(Self.limit)") == true)
        #expect(model.messageKind == .error)
    }

    @Test func vocabularyExactlyAtTheLimitIsAccepted() async {
        let model = makeModel()
        catalog.setTokenCount(Self.limit)
        await model.setVocabulary(text: "un\ndeux")
        #expect(model.settings.vocabulary == ["un", "deux"])
        #expect(model.message == nil)
    }

    @Test func vocabularyWithAnAbsentModelIsAcceptedWithAWarning() async {
        let model = makeModel()
        catalog.setTokenCount(nil)
        await model.setVocabulary(text: "Kubernetes")
        #expect(model.settings.vocabulary == ["Kubernetes"])
        #expect(saver.saved.last?.vocabulary == ["Kubernetes"])
        #expect(model.messageKind == .warning)
        #expect(model.message?.contains("limite") == true)
        #expect(model.message?.contains("modèle") == true)
    }

    @Test func clearingTheVocabularyNeedsNoCountAndIsSaved() async {
        let model = makeModel(
            TranscriptionSettings(engine: .whisperKit, whisperModel: "small", language: "fr", vocabulary: ["Docker"]))
        await model.setVocabulary(text: " \n ")
        #expect(model.settings.vocabulary == [])
        #expect(saver.saved.count == 1)
        #expect(catalog.countRequests.isEmpty)
    }

    /// Deux saisies de suite : la seconde, comptée plus vite, l'emporte ; la première, qui finit après, ne l'écrase pas.
    @Test func aVocabularyReplacedWhileItsTokensAreCountedIsDropped() async {
        let model = makeModel()
        let gate = Gate()
        catalog.holdFirstCount(gate)
        catalog.setTokenCount(5)

        let first = Task { await model.setVocabulary(text: "Ancien") }
        await settle { gate.isWaiting }
        await model.setVocabulary(text: "Nouveau")
        #expect(model.settings.vocabulary == ["Nouveau"])

        gate.open()
        _ = await first.value
        #expect(model.settings.vocabulary == ["Nouveau"])
        #expect(saver.saved.map(\.vocabulary) == [["Nouveau"]])
    }

    @Test func anUnchangedVocabularyIsNotSavedAgain() async {
        let model = makeModel(
            TranscriptionSettings(engine: .whisperKit, whisperModel: "small", language: "fr", vocabulary: ["Docker"]))
        await model.setVocabulary(text: "Docker\n")
        #expect(saver.saved.isEmpty)
        #expect(catalog.countRequests.isEmpty)
    }

    // MARK: - Téléchargement

    @Test func aDownloadGoesThroughItsFractionsThenReady() async {
        let model = makeModel()
        await model.refresh()
        let gate = Gate()
        catalog.setDownload { _, progress in
            progress(0.25)
            await gate.wait()
        }
        let id = LocalModelID.parakeet
        let download = Task { await model.download(id) }

        await settle { Self.state(model, id) == .downloading(0.25) }
        #expect(Self.state(model, id) == .downloading(0.25))
        gate.open()
        await download.value
        #expect(Self.state(model, id) == .ready)
    }

    @Test func aFailedDownloadShowsItsReasonAndCanBeRetried() async {
        let model = makeModel()
        await model.refresh()
        let id = LocalModelID.parakeet
        catalog.setDownload { _, _ in throw SaveFailure() }
        await model.download(id)
        guard case .failed(let reason)? = Self.state(model, id) else {
            Issue.record("état attendu : failed, reçu \(String(describing: Self.state(model, id)))")
            return
        }
        #expect(reason.contains("disque plein"))

        catalog.setDownload { _, _ in }
        await model.download(id)
        #expect(Self.state(model, id) == .ready)
        #expect(catalog.downloads == [id, id])
    }

    @Test func twoDownloadsOfTheSameModelDoNotRunInParallel() async {
        let model = makeModel()
        await model.refresh()
        let gate = Gate()
        catalog.setDownload { _, _ in await gate.wait() }
        let id = LocalModelID.parakeet
        let first = Task { await model.download(id) }
        await settle { gate.isWaiting }

        let second = Task { await model.download(id) }
        // Un second téléchargement lancé aurait atteint le catalogue : on lui laisse tous les tours qu'il lui faut.
        await settleAbsence(of: { catalog.downloads.count > 1 })
        #expect(catalog.downloads == [id])

        gate.open()
        await first.value
        await second.value
        #expect(catalog.downloads == [id])
        #expect(Self.state(model, id) == .ready)
    }

    @Test func twoDifferentModelsMayDownloadTogether() async {
        let model = makeModel()
        await model.refresh()
        let gate = Gate()
        catalog.setDownload { _, _ in await gate.wait() }
        let first = Task { await model.download(LocalModelID.parakeet) }
        let second = Task { await model.download(FakeModelCatalog.small.id) }
        await settle { gate.calls == 2 }
        #expect(Set(catalog.downloads) == [LocalModelID.parakeet, FakeModelCatalog.small.id])
        gate.open()
        await first.value
        await second.value
    }

    @Test func aRefreshDuringADownloadKeepsItsProgress() async {
        let model = makeModel()
        await model.refresh()
        let gate = Gate()
        catalog.setDownload { _, progress in
            progress(0.5)
            await gate.wait()
        }
        let id = LocalModelID.parakeet
        let download = Task { await model.download(id) }
        await settle { Self.state(model, id) == .downloading(0.5) }

        await model.refresh()
        #expect(Self.state(model, id) == .downloading(0.5))
        gate.open()
        await download.value
    }

    @Test func aLateProgressReportDoesNotBringAFinishedDownloadBack() async {
        let model = makeModel()
        await model.refresh()
        let id = LocalModelID.parakeet
        let report = ProgressBox()
        catalog.setDownload { _, progress in report.keep(progress) }
        await model.download(id)
        #expect(Self.state(model, id) == .ready)

        report.call(0.5)
        await settleAbsence(of: { Self.state(model, id) == .downloading(0.5) })
        #expect(Self.state(model, id) == .ready)
    }

    // MARK: - Suppression

    @Test func deletingTheModelOfTheChosenEngineIsAllowedButWarns() async {
        let model = makeModel()  // whisperkit + large-v3-v20240930_turbo, prêt
        await model.refresh()
        await model.delete(FakeModelCatalog.turbo.id)
        #expect(catalog.deletions == [FakeModelCatalog.turbo.id])
        #expect(Self.state(model, FakeModelCatalog.turbo.id) == .absent)
        #expect(model.message?.contains("prochaine dictée") == true)
        #expect(model.message?.contains("télécharg") == true)
    }

    /// I5 : une dictée en cours tient peut-être ce modèle : la suppression est refusée, avec un message clair.
    @Test func deletingAModelIsRefusedWhileADictationRuns() async {
        let model = makeModel()
        await model.refresh()
        dictating.value = true

        await model.delete(FakeModelCatalog.turbo.id)
        #expect(catalog.deletions.isEmpty)
        #expect(Self.state(model, FakeModelCatalog.turbo.id) == .ready)
        let message = model.message ?? ""
        #expect(message.contains("dictée est en cours"))
        #expect(message.contains("supprimer"))
        #expect(model.messageKind == .error)

        // La dictée finie, la suppression passe, et le refus ne reste pas affiché.
        dictating.value = false
        await model.delete(FakeModelCatalog.turbo.id)
        #expect(catalog.deletions == [FakeModelCatalog.turbo.id])
        #expect(Self.state(model, FakeModelCatalog.turbo.id) == .absent)
        #expect(!(model.message ?? "").contains("dictée est en cours"))
    }

    @Test func aRefusalFromTheCatalogIsShownAsIs() async {
        struct Busy: LocalizedError { var errorDescription: String? { "« Whisper small » est en cours de téléchargement." } }
        let model = makeModel()
        await model.refresh()
        catalog.setDeleteFailure(Busy())

        await model.delete(FakeModelCatalog.small.id)
        #expect(model.message?.contains("est en cours de téléchargement") == true)
        #expect(model.messageKind == .error)
    }

    @Test func aModelNoteIsPassedThroughToTheList() async {
        let note = "Le petit modèle qui reconnaît votre vocabulaire sera téléchargé à la première dictée qui en a besoin."
        let withNote = FakeModelCatalog(models: [
            LocalModel(id: LocalModelID.parakeet, title: "Parakeet", detail: "", state: .ready, note: note)
        ])
        let model = TranscriptionModel(
            settings: .defaults, catalog: withNote, promptTokenLimit: Self.limit, save: { _ in })
        await model.refresh()
        #expect(model.models.first?.note == note)
    }

    @Test func deletingAnAbsentModelOfTheChosenEngineDoesNotWarn() async {
        let model = makeModel(
            TranscriptionSettings(engine: .whisperKit, whisperModel: "small", language: "fr", vocabulary: []))
        await model.refresh()  // « small » est absent : rien à retélécharger
        await model.delete(FakeModelCatalog.small.id)
        #expect(model.message == nil)
    }

    @Test func deletingAnotherModelDoesNotWarn() async {
        let model = makeModel()
        await model.refresh()
        await model.delete(FakeModelCatalog.small.id)
        #expect(model.message == nil)
    }

    @Test func aFailedDeletionSaysWhyAndKeepsTheState() async {
        let model = makeModel()
        await model.refresh()
        catalog.setDeleteFailure(SaveFailure())
        await model.delete(FakeModelCatalog.turbo.id)
        #expect(model.message?.contains("disque plein") == true)
        #expect(model.messageKind == .error)
        #expect(Self.state(model, FakeModelCatalog.turbo.id) == .ready)
    }

    @Test func aModelBeingDownloadedIsNotDeleted() async {
        let model = makeModel()
        await model.refresh()
        let gate = Gate()
        catalog.setDownload { _, progress in
            progress(0.1)
            await gate.wait()
        }
        let id = LocalModelID.parakeet
        let download = Task { await model.download(id) }
        await settle { Self.state(model, id) == .downloading(0.1) }

        await model.delete(id)
        #expect(catalog.deletions.isEmpty)
        gate.open()
        await download.value
    }
}
