import Foundation
import Testing

@testable import SupervoxApp

/// L'onglet Modes : les lignes, l'interrupteur « Relire avant de coller » et son enregistrement.
@MainActor @Suite struct ModesModelTests {
    /// Une erreur d'ailleurs, dont le texte porte une adresse : il ne doit jamais arriver à l'écran.
    struct ForeignError: LocalizedError {
        var errorDescription: String? { "échec de la requête vers https://api.example.com/v1/cle" }
    }

    /// Les enregistrements demandés, et ce que le prochain doit répondre.
    final class Saves {
        var calls: [[String: ModeOptions]] = []
        var failure: (any Error)?
    }

    func make(options: [String: ModeOptions] = [:], saves: Saves = Saves()) -> (ModesModel, Saves) {
        let model = ModesModel(
            modes: ModeChip.fixed, options: options,
            save: { options in
                saves.calls.append(options)
                if let failure = saves.failure { throw failure }
            })
        return (model, saves)
    }

    func row(_ model: ModesModel, _ id: String) throws -> ModesModel.Row {
        try #require(model.rows.first { $0.id == id })
    }

    // MARK: - Lignes

    @Test func thereIsOneRowPerModeInTheOrderOfTheChips() {
        let (model, _) = make()
        #expect(model.rows.map(\.id) == ModeChip.fixed.map(\.id))
        #expect(model.rows.map(\.title) == ["Dictée brute", "Dictée nettoyée", "Prompt", "Entretien"])
        #expect(model.message == nil)
    }

    @Test func theRowsStartOnTheDefaultsAndOnTheSavedChoices() throws {
        let (defaults, _) = make()
        #expect(defaults.rows.map(\.reviews) == [false, false, true, true])
        let (chosen, _) = make(options: [
            ModeChip.rawID: ModeOptions(reviewBeforePaste: true), ModeChip.promptID: ModeOptions(reviewBeforePaste: false),
        ])
        #expect(chosen.rows.map(\.reviews) == [true, false, false, true])
    }

    /// Entretien : toujours relu, sans interrupteur, même si le fichier dit faux.
    @Test func theInterviewRowIsLockedAndReviewedEvenIfTheFileSaysOtherwise() throws {
        let (model, _) = make(options: [ModeChip.interviewID: ModeOptions(reviewBeforePaste: false)])
        let interview = try row(model, ModeChip.interviewID)
        #expect(interview.reviews)
        #expect(interview.isLocked)
        #expect(model.rows.filter(\.isLocked).map(\.id) == [ModeChip.interviewID])
    }

    /// Les phrases de l'onglet, mot pour mot.
    @Test func theTabSpeaksInTheExpectedWords() throws {
        let (model, _) = make()
        #expect(try row(model, ModeChip.interviewID).note == "Toujours relu : l'entretien passe toujours par la relecture.")
        let later = "Ce mode arrive à une étape suivante ; ce réglage vaudra dès qu'il sera là."
        #expect(try row(model, ModeChip.cleanedID).note == later)
        #expect(try row(model, ModeChip.promptID).note == later)
        #expect(try row(model, ModeChip.rawID).note == nil)
        #expect(
            ModesModel.header
                == "Quand la relecture est activée, le texte s'affiche dans le panneau à la fin de la dictée : vous pouvez le corriger au clavier, puis choisir « Coller » ou « Copier ». Rien n'est collé sans votre geste."
        )
        #expect(ModesModel.toggleTitle == "Relire avant de coller")
    }

    // MARK: - Entretien

    @Test func switchingTheInterviewOffChangesNothingAndSavesNothing() throws {
        let (model, saves) = make()
        model.setReview(false, for: ModeChip.interviewID)
        model.setReview(true, for: ModeChip.interviewID)
        #expect(saves.calls.isEmpty)
        #expect(try row(model, ModeChip.interviewID).reviews)
        #expect(model.message == nil)
    }

    // MARK: - Enregistrement

    /// Une bascule, un enregistrement, avec tout le dictionnaire : les modes inconnus et les champs voisins y restent.
    @Test func eachSwitchSavesOnceWithTheWholeDictionary() throws {
        let unknown = ModeOptions(reviewBeforePaste: true)
        let (model, saves) = make(options: ["mode-perso": unknown, ModeChip.promptID: ModeOptions(reviewBeforePaste: false)])

        model.setReview(true, for: ModeChip.rawID)
        #expect(saves.calls == [[
            "mode-perso": unknown, ModeChip.promptID: ModeOptions(reviewBeforePaste: false),
            ModeChip.rawID: ModeOptions(reviewBeforePaste: true),
        ]])
        #expect(try row(model, ModeChip.rawID).reviews)

        model.setReview(true, for: ModeChip.promptID)
        #expect(saves.calls.count == 2)
        #expect(saves.calls[1][ModeChip.promptID] == ModeOptions(reviewBeforePaste: true))
        #expect(saves.calls[1][ModeChip.rawID] == ModeOptions(reviewBeforePaste: true))
        #expect(saves.calls[1]["mode-perso"] == unknown)
        #expect(try row(model, ModeChip.promptID).reviews)
        #expect(model.message == nil)
    }

    @Test func aSwitchToTheValueAlreadyShownSavesNothing() {
        let (model, saves) = make()
        model.setReview(false, for: ModeChip.rawID)
        model.setReview(true, for: ModeChip.promptID)
        model.setReview(true, for: "mode-inconnu")
        #expect(saves.calls.isEmpty)
    }

    /// Si l'enregistrement échoue, la ligne revient à l'ancienne valeur, le message le dit, et l'échec ne laisse rien dans ce
    /// que le prochain enregistrement écrira.
    @Test func aFailedSaveRestoresTheRowAndSaysSo() throws {
        let (model, saves) = make()
        saves.failure = ForeignError()

        model.setReview(true, for: ModeChip.rawID)
        #expect(saves.calls.count == 1)
        #expect(try row(model, ModeChip.rawID).reviews == false)
        let message = try #require(model.message)
        #expect(message.contains("pas pu être enregistré"))

        // Un défaut vrai qu'on éteint, puis l'échec : la ligne reste vraie.
        model.setReview(false, for: ModeChip.promptID)
        #expect(try row(model, ModeChip.promptID).reviews)

        // Le succès suivant efface le message, et n'écrit pas le choix refusé plus tôt.
        saves.failure = nil
        model.setReview(false, for: ModeChip.promptID)
        #expect(model.message == nil)
        #expect(saves.calls.last == [ModeChip.promptID: ModeOptions(reviewBeforePaste: false)])
        #expect(try row(model, ModeChip.rawID).reviews == false)
        #expect(try row(model, ModeChip.promptID).reviews == false)
    }

    /// Le compteur sert à recréer l'interrupteur après un refus (il doit revenir à la valeur enregistrée) : il avance d'un cran
    /// par enregistrement refusé, et ne bouge ni sur un succès ni sur une bascule sans effet.
    @Test func theRevisionAdvancesOnEachRefusedSaveOnly() {
        let (model, saves) = make()
        #expect(model.revision == 0)

        model.setReview(true, for: ModeChip.rawID)  // succès
        #expect(model.revision == 0)
        model.setReview(true, for: ModeChip.rawID)  // déjà montré : rien
        model.setReview(false, for: ModeChip.interviewID)  // verrouillé : rien
        model.setReview(true, for: "mode-inconnu")  // inconnu : rien
        #expect(model.revision == 0)

        saves.failure = ForeignError()
        model.setReview(false, for: ModeChip.rawID)
        #expect(model.revision == 1)
        model.setReview(false, for: ModeChip.rawID)
        #expect(model.revision == 2)

        saves.failure = nil
        model.setReview(false, for: ModeChip.rawID)  // succès
        #expect(model.revision == 2)
    }

    @Test func theMessageNeverCarriesTheTextOfAForeignError() throws {
        let (model, saves) = make()
        saves.failure = ForeignError()
        model.setReview(true, for: ModeChip.rawID)
        let message = try #require(model.message)
        #expect(!message.contains("example.com"))
        #expect(!message.contains("https"))
        #expect(!message.contains("échec de la requête"))
    }

    @Test func aSettingsErrorSpeaksWithItsOwnSentence() throws {
        let (model, saves) = make()
        let error = SettingsError.unreadableFileKept(fileName: "settings.json")
        saves.failure = error
        model.setReview(true, for: ModeChip.rawID)
        #expect(model.message == error.errorDescription)
        #expect(model.message?.contains("settings.json") == true)
        #expect(try row(model, ModeChip.rawID).reviews == false)
    }
}
