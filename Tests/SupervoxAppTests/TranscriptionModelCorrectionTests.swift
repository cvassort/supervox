import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Tour de correction 1 : états de téléchargement honnêtes, vocabulaire refusé jamais effacé, recomptage du vocabulaire,
/// suppression des modèles que la dictée utilise toujours. Les doubles sont ceux de `TranscriptionModelTests`.
@MainActor @Suite struct TranscriptionModelCorrectionTests {
    static let voice = LocalModel(id: LocalModelID.voiceDetector, title: "Détecteur de voix", detail: "", state: .ready)
    static let limit = 111

    let catalog = FakeModelCatalog(models: [
        FakeModelCatalog.parakeet, FakeModelCatalog.turbo, FakeModelCatalog.small, TranscriptionModelCorrectionTests.voice,
    ])
    let saver = TranscriptionSaver()

    func makeModel(_ settings: TranscriptionSettings = .defaults) -> TranscriptionModel {
        let saver = saver
        return TranscriptionModel(
            settings: settings, catalog: catalog, promptTokenLimit: Self.limit, save: { try saver.save($0) })
    }

    func settings(engine: TranscriptionEngine = .whisperKit, model: String = "large-v3-v20240930_turbo", vocabulary: [String] = [])
        -> TranscriptionSettings
    {
        TranscriptionSettings(engine: engine, whisperModel: model, language: "fr", vocabulary: vocabulary)
    }

    static func state(_ model: TranscriptionModel, _ id: String) -> LocalModel.State? {
        model.models.first { $0.id == id }?.state
    }

    // MARK: - Téléchargement : états honnêtes

    @Test func aDownloadStartsWithoutAFractionAndKeepsNoneUntilTheLibraryGivesOne() async {
        let model = makeModel()
        await model.refresh()
        let gate = Gate()
        catalog.setDownload { _, _ in await gate.wait() }
        let id = LocalModelID.parakeet
        let download = Task { await model.download(id) }
        await settle { gate.isWaiting }
        #expect(Self.state(model, id) == .downloading(nil))
        gate.open()
        await download.value
    }

    @Test func aLowerProgressReportNeverMakesTheFractionGoBack() async {
        let model = makeModel()
        await model.refresh()
        let gate = Gate()
        catalog.setDownload { _, progress in
            progress(0.5)
            progress(0.3)
            await gate.wait()
        }
        let id = LocalModelID.parakeet
        let download = Task { await model.download(id) }
        await settle { Self.state(model, id) == .downloading(0.5) }
        // Le second rapport (0,3) arrive après le premier : on lui laisse tous les tours qu'il lui faut.
        await settleAbsence(of: { Self.state(model, id) == .downloading(0.3) })
        #expect(Self.state(model, id) == .downloading(0.5))
        gate.open()
        await download.value
    }

    /// Entre la fin du téléchargement et la relecture de la liste, la ligne ne retombe pas sur « Non téléchargé ».
    @Test func aFinishedDownloadNeverShowsAStaleStateWhileTheListIsReread() async {
        let model = makeModel()
        await model.refresh()
        let id = LocalModelID.parakeet
        let gate = Gate()
        catalog.holdNextListing(gate)
        let download = Task { await model.download(id) }
        await settle { gate.isWaiting }
        #expect(Self.state(model, id) == .downloading(nil))
        gate.open()
        await download.value
        #expect(Self.state(model, id) == .ready)
    }

    /// Un échec reste affiché tant qu'aucune nouvelle action ne l'a remplacé, même si le disque dit « prêt » juste après lui
    /// (le modèle est là mais le tokenizer, ou le chargement, a échoué).
    @Test func aFailureStaysVisibleEvenWhenTheDiskSaysReadyJustAfterIt() async {
        let model = makeModel()
        await model.refresh()
        let id = LocalModelID.parakeet
        let catalog = catalog
        catalog.setDownload { id, _ in
            catalog.setDiskState(.ready, of: id)
            throw SaveFailure()
        }
        await model.download(id)
        guard case .failed(let reason)? = Self.state(model, id) else {
            Issue.record("échec attendu, état reçu \(String(describing: Self.state(model, id)))")
            return
        }
        #expect(reason == TranscriptionModel.downloadFailure)
        // Relire le disque ne l'efface pas non plus.
        await model.refresh()
        #expect(Self.state(model, id) == .failed(reason))
        #expect(TranscriptionModel.actions(for: Self.state(model, id)!).map(\.label) == ["Réessayer", "Supprimer…"])
    }

    @Test func aSuccessfulRetryReplacesTheFailure() async {
        let model = makeModel()
        await model.refresh()
        let id = LocalModelID.parakeet
        let catalog = catalog
        catalog.setDownload { id, _ in
            catalog.setDiskState(.ready, of: id)
            throw SaveFailure()
        }
        await model.download(id)
        catalog.setDownload { _, _ in }
        await model.download(id)
        #expect(Self.state(model, id) == .ready)
    }

    @Test func deletingReplacesTheFailure() async {
        let model = makeModel()
        await model.refresh()
        let id = LocalModelID.parakeet
        let catalog = catalog
        catalog.setDownload { id, _ in
            catalog.setDiskState(.ready, of: id)
            throw SaveFailure()
        }
        await model.download(id)
        await model.delete(id)
        #expect(Self.state(model, id) == .absent)
    }

    // MARK: - Recomptage : chaque fois que l'état du disque du modèle choisi change

    /// Même sur le chemin d'un échec : le modèle est là, le vocabulaire est recompté.
    @Test func aFailedDownloadWhoseDiskIsReadyStillRecountsTheVocabulary() async {
        let model = makeModel(settings(model: "small", vocabulary: ["Kubernetes"]))
        await model.refresh()
        let catalog = catalog
        catalog.setTokenCount(150)
        catalog.setDownload { id, _ in
            catalog.setDiskState(.ready, of: id)
            throw SaveFailure()
        }
        await model.download(FakeModelCatalog.small.id)
        guard case .failed? = Self.state(model, FakeModelCatalog.small.id) else {
            Issue.record("échec attendu")
            return
        }
        #expect(catalog.countRequests.count == 1)
        #expect(model.messageKind == .error)
        #expect(model.messageArea == .vocabulary)
        #expect(model.settings.vocabulary == ["Kubernetes"])
    }

    /// Le moteur a téléchargé le modèle de son côté : la relecture de la liste voit le changement et recompte.
    @Test func aRefreshSeeingTheChosenModelChangeOnDiskRecountsTheVocabulary() async {
        let model = makeModel(settings(model: "small", vocabulary: ["Kubernetes"]))
        await model.refresh()
        #expect(catalog.countRequests.isEmpty)  // première lecture : rien n'a changé

        catalog.setDiskState(.ready, of: FakeModelCatalog.small.id)
        catalog.setTokenCount(150)
        await model.refresh()
        #expect(catalog.countRequests.count == 1)
        #expect(model.messageKind == .error)

        await model.refresh()  // rien n'a changé : pas de nouveau comptage
        #expect(catalog.countRequests.count == 1)
    }

    /// Un téléchargement en cours (lancé ailleurs) n'est pas un état du disque : seul son aboutissement change l'état.
    @Test func aDownloadInProgressElsewhereIsNotAChangeOfTheDiskState() async {
        let model = makeModel(settings(model: "small", vocabulary: ["Kubernetes"]))
        await model.refresh()
        catalog.setTokenCount(150)

        catalog.setDiskState(.downloading(0.3), of: FakeModelCatalog.small.id)
        await model.refresh()
        #expect(catalog.countRequests.isEmpty)

        catalog.setDiskState(.ready, of: FakeModelCatalog.small.id)
        await model.refresh()
        #expect(catalog.countRequests.count == 1)
    }

    @Test func aChangeOnDiskOfAnotherModelDoesNotRecount() async {
        let model = makeModel(settings(model: "small", vocabulary: ["Kubernetes"]))
        await model.refresh()
        catalog.setDiskState(.ready, of: LocalModelID.parakeet)
        await model.refresh()
        #expect(catalog.countRequests.isEmpty)
    }

    @Test func anIncompleteModelCanBeDeletedWithoutAWarning() async {
        let model = makeModel(settings())
        catalog.setDiskState(.incomplete, of: FakeModelCatalog.turbo.id)
        await model.refresh()
        #expect(Self.state(model, FakeModelCatalog.turbo.id) == .incomplete)
        await model.delete(FakeModelCatalog.turbo.id)
        #expect(catalog.deletions == [FakeModelCatalog.turbo.id])
        #expect(model.message == nil)
    }

    // MARK: - Vocabulaire refusé : la saisie reste

    @Test func aRefusedVocabularyReportsItsOutcomeAndMessageSitsBesideTheField() async {
        let model = makeModel(settings(vocabulary: ["Ancien"]))
        catalog.setTokenCount(Self.limit + 1)
        let outcome = await model.setVocabulary(text: "un\ndeux")
        #expect(outcome == .refused)
        #expect(model.messageArea == .vocabulary)
        #expect(model.settings.vocabulary == ["Ancien"])
    }

    @Test func everyVocabularyOutcomeIsReported() async {
        let model = makeModel()
        catalog.setTokenCount(5)
        #expect(await model.setVocabulary(text: "Docker") == .saved)
        #expect(await model.setVocabulary(text: "Docker\n") == .unchanged)

        saver.failure = SaveFailure()
        #expect(await model.setVocabulary(text: "Docker\nSentry") == .notSaved)
        #expect(model.messageArea == .vocabulary)
        saver.failure = nil

        // Une saisie remplacée pendant le comptage.
        let gate = Gate()
        catalog.holdFirstCount(gate)
        let first = Task { await model.setVocabulary(text: "Ancien") }
        await settle { gate.isWaiting }
        #expect(await model.setVocabulary(text: "Nouveau") == .saved)
        gate.open()
        #expect(await first.value == .superseded)
    }

    @Test func theFieldKeepsWhatWasTypedUnlessTheVocabularyWasSavedAsIs() {
        func field(_ outcome: VocabularyOutcome, current: String = "a\nb", submitted: String = "a\nb", saved: String = "a")
            -> String
        {
            TranscriptionModel.fieldText(afterSubmitting: submitted, outcome: outcome, current: current, saved: saved)
        }
        // Refus, échec d'enregistrement, saisie dépassée : le texte tapé reste, jamais la liste enregistrée.
        #expect(field(.refused) == "a\nb")
        #expect(field(.notSaved) == "a\nb")
        #expect(field(.superseded) == "a\nb")
        // Enregistré (peut-être mis en forme) ou inchangé : le champ montre la liste enregistrée.
        #expect(field(.saved, current: "a\n\nb ", submitted: "a\n\nb ", saved: "a\nb") == "a\nb")
        #expect(field(.unchanged, saved: "a\nb") == "a\nb")
        // L'utilisateur a continué à taper pendant l'enregistrement : on ne l'écrase pas.
        #expect(field(.saved, current: "a\nb\nc", submitted: "a\nb", saved: "a\nb") == "a\nb\nc")
    }

    // MARK: - Messages du vocabulaire : en mots simples, avec le moteur concerné

    @Test func theRefusalNamesWhisperAndGivesBothNumbersWithoutJargon() async {
        let model = makeModel(settings(vocabulary: ["Ancien"]))
        catalog.setTokenCount(140)
        await model.setVocabulary(text: "un\ndeux")
        let message = model.message ?? ""
        #expect(message.contains("Whisper"))
        #expect(message.contains("140") && message.contains("\(Self.limit)"))
        #expect(!message.localizedCaseInsensitiveContains("jeton") && !message.localizedCaseInsensitiveContains("amorce"))
        #expect(message.contains("conservé"))
    }

    @Test func theRefusalUnderParakeetSaysWhichEngineHasTheLimit() async {
        let model = makeModel(settings(engine: .parakeet))
        catalog.setTokenCount(140)
        await model.setVocabulary(text: "un\ndeux")
        let message = model.message ?? ""
        #expect(message.contains("Parakeet") && message.contains("WhisperKit"))
        #expect(message.contains("140") && message.contains("\(Self.limit)"))
        #expect(!message.localizedCaseInsensitiveContains("jeton") && !message.localizedCaseInsensitiveContains("amorce"))
    }

    @Test func anAbsentModelWarnsUnderWhisperKitAndSaysNothingUnderParakeet() async {
        let whisper = makeModel()
        catalog.setTokenCount(nil)
        await whisper.setVocabulary(text: "Docker")
        #expect(whisper.messageKind == .warning)
        #expect(whisper.messageArea == .vocabulary)
        #expect(whisper.message?.contains("Whisper") == true)
        #expect(!(whisper.message ?? "").localizedCaseInsensitiveContains("jeton"))
        #expect(whisper.settings.vocabulary == ["Docker"])

        let parakeet = makeModel(settings(engine: .parakeet))
        await parakeet.setVocabulary(text: "Docker")
        #expect(parakeet.message == nil)
        #expect(parakeet.settings.vocabulary == ["Docker"])
    }

    // MARK: - Recomptage

    /// Vocabulaire accepté sans pouvoir compter (modèle absent) : le téléchargement du modèle le recompte.
    @Test func aVocabularyTooLongForTheModelIsFlaggedOnceItIsDownloadedButNotErased() async {
        let model = makeModel(settings(model: "small", vocabulary: ["Kubernetes", "PostgreSQL"]))
        await model.refresh()
        catalog.setTokenCount(150)
        await model.download(FakeModelCatalog.small.id)
        #expect(model.messageKind == .error)
        #expect(model.messageArea == .vocabulary)
        #expect(model.message?.contains("150") == true && model.message?.contains("\(Self.limit)") == true)
        #expect(model.settings.vocabulary == ["Kubernetes", "PostgreSQL"])
        #expect(saver.saved.isEmpty)
    }

    @Test func downloadingAnotherModelDoesNotRecountTheVocabulary() async {
        let model = makeModel(settings(model: "small", vocabulary: ["Docker"]))
        await model.refresh()
        await model.download(LocalModelID.parakeet)
        #expect(catalog.countRequests.isEmpty)
    }

    @Test func changingTheWhisperModelRecountsTheVocabulary() async {
        let model = makeModel(settings(vocabulary: ["Docker"]))
        catalog.setTokenCount(150)
        model.setWhisperModel("small")
        await model.waitForRecheck()
        #expect(catalog.countRequests.last?.model == "small")
        #expect(model.messageKind == .error)
        #expect(model.settings.vocabulary == ["Docker"])
        #expect(model.settings.whisperModel == "small")
    }

    @Test func switchingToWhisperKitRecountsButSwitchingToParakeetDoesNot() async {
        let model = makeModel(settings(engine: .parakeet, vocabulary: ["Docker"]))
        model.setEngine(.whisperKit)
        await model.waitForRecheck()
        #expect(catalog.countRequests.count == 1)

        model.setEngine(.parakeet)
        await model.waitForRecheck()
        #expect(catalog.countRequests.count == 1)
    }

    @Test func aShortEnoughVocabularyLeavesNoMessageAfterAModelChange() async {
        let model = makeModel(settings(vocabulary: ["Docker"]))
        catalog.setTokenCount(150)
        model.setWhisperModel("small")
        await model.waitForRecheck()
        #expect(model.message != nil)

        catalog.setTokenCount(20)
        model.setWhisperModel("base")
        await model.waitForRecheck()
        #expect(model.message == nil)
    }

    /// Le recomptage d'une ancienne liste, fini après qu'une autre a été enregistrée, ne dit rien de la nouvelle.
    @Test func aRecountOfAnOldListFinishingLateSaysNothingAboutTheNewOne() async {
        let model = makeModel(settings(vocabulary: ["Ancien"]))
        catalog.setTokenCount(5)
        let gate = Gate()
        catalog.holdFirstCount(gate)
        model.setWhisperModel("small")
        await settle { gate.isWaiting }
        guard gate.isWaiting else {
            Issue.record("le recomptage n'a pas démarré")
            gate.open()  // ne laisse personne pendu sur la barrière
            return
        }

        #expect(await model.setVocabulary(text: "Nouveau") == .saved)
        catalog.setTokenCount(150)
        gate.open()
        await model.waitForRecheck()
        #expect(model.settings.vocabulary == ["Nouveau"])
        #expect(model.message == nil)
    }

    @Test func anEmptyVocabularyIsNeverRecounted() async {
        let model = makeModel(settings())
        model.setWhisperModel("small")
        await model.waitForRecheck()
        #expect(catalog.countRequests.isEmpty)
    }

    @Test func aRecountWithoutTheModelWarnsOnlyUnderWhisperKit() async {
        let whisper = makeModel(settings(vocabulary: ["Docker"]))
        catalog.setTokenCount(nil)
        whisper.setWhisperModel("small")
        await whisper.waitForRecheck()
        #expect(whisper.messageKind == .warning)

        let parakeet = makeModel(settings(engine: .parakeet, vocabulary: ["Docker"]))
        parakeet.setWhisperModel("small")
        await parakeet.waitForRecheck()
        #expect(parakeet.message == nil)
    }

    // MARK: - Suppression : ce que la dictée utilise

    @Test func deletingParakeetWarnsEvenWhenWhisperKitIsChosenBecauseItServesThePreview() async {
        let model = makeModel(settings())
        catalog.setDiskState(.ready, of: LocalModelID.parakeet)
        await model.refresh()
        await model.delete(LocalModelID.parakeet)
        #expect(model.message?.contains("prochaine dictée") == true)
        #expect(model.message?.contains("aperçu") == true)
    }

    @Test func deletingTheVoiceDetectorWarns() async {
        let model = makeModel(settings())
        await model.refresh()
        await model.delete(LocalModelID.voiceDetector)
        #expect(model.message?.contains("prochaine dictée") == true)
        #expect(model.message?.contains("voix") == true)
    }

    @Test func aWhisperModelOtherThanTheChosenOneDoesNotWarn() async {
        let model = makeModel(settings())
        catalog.setDiskState(.ready, of: FakeModelCatalog.small.id)
        await model.refresh()
        await model.delete(FakeModelCatalog.small.id)
        #expect(model.message == nil)
    }

    @Test func theDictationUsesParakeetAndTheDetectorWhateverTheEngine() {
        let model = makeModel(settings())
        #expect(model.isUsedByDictation(LocalModelID.parakeet))
        #expect(model.isUsedByDictation(LocalModelID.voiceDetector))
        #expect(model.isUsedByDictation(FakeModelCatalog.turbo.id))
        #expect(!model.isUsedByDictation(FakeModelCatalog.small.id))
    }

    @Test func theConfirmationSaysWhenTheFolderIsSharedWithOtherApplications() {
        let model = makeModel(settings())
        for shared in [FakeModelCatalog.parakeet, Self.voice] {
            let text = model.deletionConfirmation(for: shared)
            #expect(text.contains("FluidAudio"))
            #expect(text.contains("autres applications"))
            #expect(text.contains("prochaine dictée"))
        }
        let chosen = model.deletionConfirmation(for: FakeModelCatalog.turbo)
        #expect(!chosen.contains("FluidAudio"))
        #expect(chosen.contains("prochaine dictée"))
        let other = model.deletionConfirmation(for: FakeModelCatalog.small)
        #expect(!other.contains("FluidAudio") && !other.contains("prochaine dictée"))
    }

    // MARK: - « Moteur choisi » : le modèle du texte final seulement

    @Test func aWhisperModelIsNeverTheChosenOneWhenParakeetIsTheEngine() {
        let model = makeModel(settings(engine: .parakeet))
        #expect(!model.isUsedByChosenEngine(FakeModelCatalog.turbo.id))
        #expect(!model.isUsedByDictation(FakeModelCatalog.turbo.id))
        #expect(model.isUsedByChosenEngine(LocalModelID.parakeet))
        // Parakeet et le détecteur de voix servent toujours.
        #expect(model.isUsedByDictation(LocalModelID.parakeet))
        #expect(model.isUsedByDictation(LocalModelID.voiceDetector))
    }

    @Test func theTagFollowsTheEngineBothWays() {
        let whisper = makeModel(settings())
        #expect(whisper.isUsedByChosenEngine(FakeModelCatalog.turbo.id))
        #expect(!whisper.isUsedByChosenEngine(LocalModelID.parakeet))
        #expect(!whisper.isUsedByChosenEngine(FakeModelCatalog.small.id))
    }

    @Test func deletingTheWhisperModelOfTheSettingsDoesNotWarnWhenParakeetIsTheEngine() async {
        let model = makeModel(settings(engine: .parakeet))
        await model.refresh()
        await model.delete(FakeModelCatalog.turbo.id)
        #expect(model.message == nil)
        let confirmation = model.deletionConfirmation(for: FakeModelCatalog.turbo)
        #expect(!confirmation.contains("prochaine dictée") && !confirmation.contains("moteur choisi"))
        #expect(confirmation.contains("plus tard"))
    }
}
