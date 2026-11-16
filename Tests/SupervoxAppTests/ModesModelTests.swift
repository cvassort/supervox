import AppKit
import Foundation
import SwiftUI
import Testing

@testable import SupervoxApp

/// L'onglet Modes : créer, modifier, dupliquer, déplacer, supprimer ; consigne d'origine ; modèles ; raccourci de chaque mode.
/// `read` et `update` sont doublés par des réglages en mémoire, dont l'enregistrement peut lever sur ordre ; aucun réseau, aucun
/// disque, aucun raccourci du système.
@MainActor @Suite struct ModesModelTests {
    /// Une erreur d'ailleurs, dont le texte porte une adresse : il ne doit jamais arriver à l'écran.
    struct ForeignError: LocalizedError {
        var errorDescription: String? { "échec de la requête vers https://api.example.com/v1/cle" }
    }

    static let keyA = HotKeyTests.keyA
    static let keyB = HotKeyTests.keyB
    static let keyC = HotKey(keyCode: 0x08, modifiers: [.control, .option])
    static let labelA = keyA.label(layout: HotKeyTests.ansi)
    static let labelB = keyB.label(layout: HotKeyTests.ansi)
    static let labelC = keyC.label(layout: HotKeyTests.ansi)
    static let provider = Provider(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!, name: "Fournisseur d'exemple",
        baseURL: "https://example.com/v1", kind: .openAICompatible,
        models: ["modele-exemple-fort", "modele-exemple-rapide"])
    static let emptyProvider = Provider(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!, name: "Second exemple",
        baseURL: "https://example.com/second", kind: .anthropic, models: [])
    static let strong = ModelChoice(providerID: provider.id, model: "modele-exemple-fort")
    static let fast = ModelChoice(providerID: provider.id, model: "modele-exemple-rapide")

    /// Les réglages en mémoire, le double de `update`, et le double de ce que l'application fait des raccourcis.
    @MainActor final class Rig {
        var settings: AppSettings
        var updates = 0
        var failure: (any Error)?
        /// Ce qui s'écrit « ailleurs » pendant que l'enregistrement est refusé : le double l'applique avant de lever, pour que
        /// l'affichage ait un autre état que `read` à retrouver.
        var writtenElsewhereBeforeFailing: ((inout AppSettings) -> Void)?
        /// Les appels du modèle au système de raccourcis, dans l'ordre.
        var applied: [Applied] = []
        /// Ce que répondent les prochains `apply` ; épuisé, le système accepte.
        var applyScript: [Result<Void, HotKeyError>] = []
        var suspends = 0
        var resumes = 0
        var resumeResult = true
        var global: HotKey? = ModesModelTests.keyA
        let monitor = FakeKeyMonitor()
        let system = FakeSystemHotKeys()

        struct Applied: Equatable {
            var hotKey: HotKey?
            var modeID: String
        }

        init(_ settings: AppSettings = Rig.defaultSettings()) { self.settings = settings }

        static func defaultSettings() -> AppSettings {
            var settings = AppSettings.defaults
            settings.providers = [ModesModelTests.provider]
            return settings
        }

        func makeModel() -> ModesModel {
            ModesModel(
                read: { self.settings },
                update: { change in
                    self.updates += 1
                    if let failure = self.failure {
                        self.writtenElsewhereBeforeFailing?(&self.settings)
                        throw failure
                    }
                    change(&self.settings)
                },
                hotKeys: ModeHotKeyControl(
                    apply: { hotKey, id in
                        self.applied.append(Applied(hotKey: hotKey, modeID: id))
                        return self.applyScript.isEmpty ? .success(()) : self.applyScript.removeFirst()
                    },
                    suspend: { self.suspends += 1 },
                    resume: {
                        self.resumes += 1
                        return self.resumeResult
                    },
                    global: { self.global }),
                layout: HotKeyTests.ansi, systemHotKeys: system, keyMonitor: monitor)
        }

        func mode(_ id: String) -> Mode? { settings.mode(id) }
        var ids: [String] { settings.modes.map(\.id) }
    }

    /// Des réglages avec deux modes personnels entre Dictée brute et Entretien.
    static func personalSettings(lastModeID: String = ModeChip.rawID) -> AppSettings {
        var settings = Rig.defaultSettings()
        settings.modes = [
            Mode.base[0], Mode.base[1], Mode.base[2],
            Mode(id: "perso-un", name: "Compte rendu", instruction: "Résume.", model: strong, engine: .parakeet, hotKey: keyB, reviewBeforePaste: false),
            Mode(id: "perso-deux", name: "Courriel", instruction: "Rédige."),
            Mode.base[3],
        ]
        settings.lastModeID = lastModeID
        return settings
    }

    func row(_ model: ModesModel, _ id: String) throws -> ModesModel.Row {
        try #require(model.rows.first { $0.id == id })
    }

    // MARK: - Lignes et textes

    @Test func thereIsOneRowPerModeInTheOrderOfTheChips() {
        let rig = Rig()
        let model = rig.makeModel()
        #expect(model.rows.map(\.id) == ModeChip.fixed.map(\.id))
        #expect(model.rows.map(\.title) == ["Dictée brute", "Dictée nettoyée", "Prompt", "Entretien"])
        #expect(model.message == nil)
        #expect(rig.updates == 0)
    }

    @Test func theRowsStartOnTheDefaultsAndOnTheSavedChoices() {
        let defaults = Rig().makeModel()
        #expect(defaults.rows.map(\.reviews) == [false, false, true, true])
        var settings = Rig.defaultSettings()
        settings.modes[0].reviewBeforePaste = true
        settings.modes[2].reviewBeforePaste = false
        settings.modes[3].reviewBeforePaste = false
        #expect(Rig(settings).makeModel().rows.map(\.reviews) == [true, false, false, true])
    }

    /// Entretien : toujours relu, sans interrupteur, même si le fichier dit faux ; les autres lignes se règlent.
    @Test func onlyTheInterviewRowIsReviewLockedAndNeverDeletable() throws {
        var settings = Rig.defaultSettings()
        settings.modes[3].reviewBeforePaste = false
        let model = Rig(settings).makeModel()
        #expect(try row(model, ModeChip.interviewID).reviews)
        #expect(model.rows.filter(\.isReviewLocked).map(\.id) == [ModeChip.interviewID])
        #expect(model.rows.filter { !$0.canDelete }.map(\.id) == [ModeChip.rawID, ModeChip.interviewID])
    }

    /// Les phrases de l'onglet, mot pour mot.
    @Test func theTabSpeaksInTheExpectedWords() throws {
        #expect(
            ModesModel.header
                == "Un mode dit ce que devient le texte dicté. Sans consigne, il est collé tel quel. Avec une consigne, le texte (jamais l'audio) est envoyé au fournisseur choisi pour être mis en forme ; l'audio ne quitte jamais cet ordinateur."
        )
        #expect(ModesModel.strongTitle == "Modèle fort")
        #expect(
            ModesModel.strongNote
                == "Réécrit le texte quand vous le corrigez à la voix, et sert aux modes qui n'ont pas de modèle propre.")
        #expect(ModesModel.fastTitle == "Modèle rapide")
        #expect(ModesModel.fastNote == "Servira à l'entretien vocal, à une étape suivante.")
        #expect(
            ModesModel.privacyNote(providerName: "Fournisseur d'exemple")
                == "Ce mode envoie le texte dicté à « Fournisseur d'exemple ». L'audio reste sur cet ordinateur.")
        #expect(ModesModel.toggleTitle == "Relire avant de coller")
        var settings = Rig.defaultSettings()
        settings.strongModel = Self.strong
        let model = Rig(settings).makeModel()
        #expect(
            try row(model, ModeChip.interviewID).note
                == "Toujours relu : l'entretien passe toujours par la relecture. Ce mode arrive à une étape suivante.")
        #expect(try row(model, ModeChip.cleanedID).note == nil, "la note « étape suivante » a disparu de Dictée nettoyée")
        #expect(try row(model, ModeChip.promptID).note == nil, "et de Prompt")
        #expect(try row(model, ModeChip.rawID).note == nil)
    }

    /// Règle 6 : modèle (ou « Modèle fort »), moteur (ou « Moteur de l'onglet Transcription »), raccourci s'il y en a.
    @Test func theSummaryNamesTheModelTheEngineAndTheHotKey() throws {
        let model = Rig(Self.personalSettings()).makeModel()
        let engine = "Moteur de l'onglet Transcription"
        #expect(try row(model, ModeChip.cleanedID).summary == "Modèle fort · \(engine)")
        #expect(try row(model, ModeChip.promptID).summary == "Modèle fort · \(engine)")
        #expect(
            try row(model, "perso-un").summary == "modele-exemple-fort (Fournisseur d'exemple) · Parakeet · ⌃⌥B")
        // Sans consigne, le texte est collé tel quel : aucun modèle n'est en jeu.
        #expect(try row(model, ModeChip.rawID).summary == "Texte collé tel quel · \(engine)")
        #expect(try row(model, ModeChip.interviewID).summary == engine)
    }

    /// Le nom d'un fournisseur trop long est rogné dans les lignes comme dans la note de vie privée.
    @Test func aLongProviderNameIsCutInTheSummaryAndInThePrivacyNote() throws {
        let long = String(repeating: "x", count: 60)
        var settings = Self.personalSettings()
        settings.providers[0].name = long
        let model = Rig(settings).makeModel()
        let cut = String(repeating: "x", count: 40) + "…"
        #expect(try row(model, "perso-un").summary == "modele-exemple-fort (\(cut)) · Parakeet · ⌃⌥B")
        #expect(ModesModel.privacyNote(providerName: long).contains("« \(cut) »"))
        #expect(!ModesModel.privacyNote(providerName: long).contains(long))
        let draft = model.draft(for: "perso-un")
        #expect(model.privacyNote(for: draft) == ModesModel.privacyNote(providerName: long))
    }

    // MARK: - Règle 1 : une seule écriture, sur l'état en vigueur

    @Test func eachGestureWritesOnceAndTouchesOnlyWhatItTouches() throws {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        let before = rig.settings

        model.setReview(true, for: ModeChip.rawID)
        #expect(rig.updates == 1)
        var expected = before
        expected.modes[0].reviewBeforePaste = true
        #expect(rig.settings == expected)

        model.setStrongModel(Self.strong)
        #expect(rig.updates == 2)
        expected.strongModel = Self.strong
        #expect(rig.settings == expected)

        model.setFastModel(Self.fast)
        #expect(rig.updates == 3)
        expected.fastModel = Self.fast
        #expect(rig.settings == expected)

        model.move("perso-deux", by: -1)
        #expect(rig.updates == 4)
        #expect(rig.ids == [ModeChip.rawID, ModeChip.cleanedID, ModeChip.promptID, "perso-deux", "perso-un", ModeChip.interviewID])

        model.clearHotKey(for: "perso-un")
        #expect(rig.updates == 5)
        #expect(rig.mode("perso-un")?.hotKey == nil)
        #expect(rig.mode("perso-un")?.name == "Compte rendu")
    }

    /// M5 : un réglage écrit ailleurs entre deux gestes (un raccourci, `lastModeID`, un autre mode, un fournisseur) est gardé.
    @Test func aWriteMadeElsewhereBetweenTwoGesturesIsKept() throws {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()

        // Après l'ouverture : le panneau change de mode, un autre onglet ajoute un fournisseur, un raccourci change, un mode apparaît.
        rig.settings.lastModeID = ModeChip.promptID
        rig.settings.providers.append(Self.emptyProvider)
        rig.settings.modes[3].hotKey = Self.keyC
        rig.settings.modes.append(Mode(id: "perso-trois", name: "Ailleurs", instruction: "Écrit ailleurs."))

        model.setReview(true, for: ModeChip.rawID)
        #expect(rig.settings.lastModeID == ModeChip.promptID)
        #expect(rig.settings.providers.count == 2)
        #expect(rig.mode("perso-un")?.hotKey == Self.keyC)
        #expect(rig.mode("perso-trois")?.name == "Ailleurs")
        #expect(rig.mode(ModeChip.rawID)?.reviewBeforePaste == true)

        // Même chose pour un geste qui ne touche qu'un autre champ du même mode.
        rig.settings.modes[3].name = "Renommé ailleurs"
        model.move("perso-deux", by: -1)
        #expect(rig.mode("perso-un")?.name == "Renommé ailleurs")
        #expect(rig.mode("perso-trois")?.name == "Ailleurs")
        #expect(rig.mode("perso-un")?.hotKey == Self.keyC)
    }

    /// Un mode supprimé ailleurs : le geste ne le recrée pas.
    @Test func aGestureOnAModeRemovedElsewhereChangesNothing() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        rig.settings.modes.removeAll { $0.id == "perso-un" }
        let before = rig.settings

        model.setReview(true, for: "perso-un")
        model.move("perso-un", by: 1)
        model.delete("perso-un")
        model.resetInstruction("perso-un")
        model.save(ModeDraft.example(id: "perso-un", name: "Fantôme"))
        #expect(rig.settings == before)
        #expect(!rig.ids.contains("perso-un"))
    }

    @Test func aFailedSaveBringsTheDisplayBackToWhatReadGivesAndSaysSo() throws {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        rig.failure = ForeignError()
        rig.settings.modes[4].name = "Courriel renommé ailleurs"  // ce que `read` donne maintenant

        model.save(ModeDraft.example(id: "perso-un", name: "Autre nom"))

        #expect(rig.updates == 1)
        #expect(try row(model, "perso-un").title == "Compte rendu", "le nom proposé n'est pas resté à l'écran")
        #expect(try row(model, "perso-deux").title == "Courriel renommé ailleurs", "l'affichage suit ce que read donne")
        let message = try #require(model.message)
        #expect(message == ModesModel.saveFailure)
        #expect(model.revision == 1)
        #expect(!message.contains("example.com"))
        #expect(!message.contains("https"))
        #expect(!message.contains("échec de la requête"))
    }

    @Test func aSettingsErrorSpeaksWithItsOwnSentence() throws {
        let rig = Rig()
        let model = rig.makeModel()
        let error = SettingsError.unreadableFileKept(fileName: "settings.json")
        rig.failure = error
        model.setReview(true, for: ModeChip.rawID)
        #expect(model.message == error.errorDescription)
        #expect(try row(model, ModeChip.rawID).reviews == false)
        #expect(model.revision == 1)
        // Le succès suivant efface le message.
        rig.failure = nil
        model.setReview(true, for: ModeChip.rawID)
        #expect(model.message == nil)
        #expect(model.revision == 1)
        #expect(try row(model, ModeChip.rawID).reviews)
    }

    /// Geste par geste : l'enregistrement est refusé alors qu'une écriture venue d'ailleurs a changé les réglages ; l'affichage
    /// (lignes, modèles, brouillon de chaque mode) revient à ce que `read` donne, le message est la phrase de `SettingsError`, la
    /// révision avance d'un cran, et `update` a été appelé une seule fois.
    @Test(arguments: [
        "setReview", "add", "duplicate", "delete", "move", "save", "resetInstruction", "setStrongModel", "setFastModel",
        "clearHotKey", "addBase", "record",
    ])
    func everyRefusedGestureBringsTheDisplayBackToWhatReadGives(gesture: String) throws {
        let rig = Rig(Self.personalSettings())
        rig.settings.modes.removeAll { $0.id == ModeChip.cleanedID }  // `addBase` a quelque chose à faire
        rig.settings.modes[rig.ids.firstIndex(of: ModeChip.promptID)!].instruction = "Ma version."  // et `resetInstruction`
        let model = rig.makeModel()
        let error = SettingsError.unreadableFileKept(fileName: "settings.json")
        rig.failure = error
        rig.writtenElsewhereBeforeFailing = { settings in
            settings.modes[settings.modes.firstIndex { $0.id == ModeChip.promptID }!].name = "Prompt renommé ailleurs"
            settings.strongModel = Self.strong
            settings.modes[settings.modes.firstIndex { $0.id == "perso-deux" }!].instruction = "Écrite ailleurs."
        }
        // Avant le geste : l'affichage montre l'état d'avant l'écriture venue d'ailleurs.
        #expect(try row(model, ModeChip.promptID).title == "Prompt")
        #expect(model.strongModel == nil)

        switch gesture {
        case "setReview": model.setReview(true, for: ModeChip.rawID)
        case "add": model.add()
        case "duplicate": model.duplicate("perso-un")
        case "delete": model.delete("perso-un")
        case "move": model.move("perso-un", by: 1)
        case "save": model.save(ModeDraft.example(id: "perso-un", name: "Autre nom"))
        case "resetInstruction": model.resetInstruction(ModeChip.promptID)
        case "setStrongModel": model.setStrongModel(Self.fast)
        case "setFastModel": model.setFastModel(Self.fast)
        case "clearHotKey": model.clearHotKey(for: "perso-un")
        case "addBase": model.addBase(ModeChip.cleanedID)
        case "record": model.record(Self.keyC, for: "perso-deux")
        default: Issue.record("geste inconnu : \(gesture)")
        }

        #expect(rig.updates == 1, "un seul appel à `update`")
        #expect(model.message == error.errorDescription)
        #expect(model.revision == 1)
        // L'affichage est exactement ce qu'un modèle neuf construit sur `read` montrerait.
        rig.failure = nil
        rig.writtenElsewhereBeforeFailing = nil
        let fresh = rig.makeModel()
        #expect(model.rows == fresh.rows)
        #expect(model.strongModel == fresh.strongModel && model.fastModel == fresh.fastModel)
        #expect(model.missingBaseModes == fresh.missingBaseModes)
        for id in rig.ids { #expect(model.draft(for: id) == fresh.draft(for: id), "brouillon de \(id)") }
        #expect(try row(model, ModeChip.promptID).title == "Prompt renommé ailleurs", "ce que `read` donne")
        #expect(model.strongModel == Self.strong)
    }

    @Test func theRevisionAdvancesOnEachRefusedSaveOnly() {
        let rig = Rig()
        let model = rig.makeModel()
        model.setReview(true, for: ModeChip.rawID)
        model.setReview(true, for: ModeChip.rawID)  // déjà montré : rien
        model.setReview(false, for: ModeChip.interviewID)  // verrouillé : rien
        model.setReview(true, for: "mode-inconnu")  // inconnu : rien
        #expect(model.revision == 0)
        rig.failure = ForeignError()
        model.setReview(false, for: ModeChip.rawID)
        #expect(model.revision == 1)
        model.setReview(false, for: ModeChip.rawID)
        #expect(model.revision == 2)
    }

    @Test func aSwitchThatChangesNothingSavesNothing() {
        let rig = Rig()
        let model = rig.makeModel()
        model.setReview(false, for: ModeChip.rawID)
        model.setReview(true, for: ModeChip.promptID)
        model.setReview(false, for: ModeChip.interviewID)
        model.setStrongModel(nil)
        model.setFastModel(nil)
        #expect(rig.updates == 0)
    }

    @Test func reloadReadsTheSettingsAgain() throws {
        let rig = Rig()
        let model = rig.makeModel()
        rig.failure = ForeignError()
        model.setReview(true, for: ModeChip.rawID)
        #expect(model.message != nil)
        rig.failure = nil
        rig.settings.modes.append(Mode(id: "perso-ailleurs", name: "Ailleurs", instruction: "x"))
        rig.settings.strongModel = Self.strong
        #expect(model.rows.count == 4)

        model.reload()
        #expect(model.rows.map(\.id).last == "perso-ailleurs")
        #expect(model.strongModel == Self.strong)
        #expect(model.message != nil, "relire ne cache pas ce qui vient de se passer")
        model.clearMessage()
        #expect(model.message == nil)
    }

    // MARK: - Règle 2 : créer

    @Test func addAppendsANewModeWithoutInstructionAndWithReviewOn() throws {
        let rig = Rig()
        let model = rig.makeModel()
        let first = model.add()
        let second = model.add()
        #expect(rig.updates == 2)
        #expect(first != second)
        #expect(first.hasPrefix("perso-"))
        #expect(rig.ids.suffix(2) == [first, second], "en fin de liste, après Entretien")
        #expect(rig.ids.dropLast(2).last == ModeChip.interviewID)
        #expect(rig.mode(first)?.name == "Nouveau mode")
        #expect(rig.mode(second)?.name == "Nouveau mode 2")
        let created = try #require(rig.mode(first))
        #expect(created.instruction == "")
        #expect(created.reviewBeforePaste == true)
        #expect(created.model == nil && created.engine == nil && created.hotKey == nil)
        #expect(try row(model, first).reviews)
        #expect(model.rows.last?.id == second)
        // Un nom pris sans tenir compte de la casse est sauté.
        rig.settings.modes[rig.settings.modes.count - 1].name = "NOUVEAU MODE 2"
        rig.settings.modes[rig.settings.modes.count - 2].name = "nouveau mode"
        #expect(rig.mode(model.add())?.name == "Nouveau mode 3")
    }

    @Test func duplicatePlacesTheCopyRightAfterTheOriginalWithAllItsSettingsExceptTheHotKey() throws {
        let rig = Rig(Self.personalSettings())
        rig.settings.modes[3].reviewBeforePaste = true
        let model = rig.makeModel()

        let copyID = model.duplicate("perso-un")

        #expect(rig.updates == 1)
        #expect(rig.ids == [ModeChip.rawID, ModeChip.cleanedID, ModeChip.promptID, "perso-un", copyID, "perso-deux", ModeChip.interviewID])
        let copy = try #require(rig.mode(copyID))
        #expect(copyID != "perso-un" && copyID.hasPrefix("perso-"))
        #expect(copy.name == "Compte rendu (copie)")
        #expect(copy.instruction == "Résume.")
        #expect(copy.model == Self.strong)
        #expect(copy.engine == .parakeet)
        #expect(copy.reviewBeforePaste == true)
        #expect(copy.hotKey == nil, "le raccourci n'est pas recopié")
        #expect(rig.mode("perso-un")?.hotKey == Self.keyB, "l'original garde le sien")
        #expect(model.rows.map(\.id) == rig.ids)

        let second = model.duplicate("perso-un")
        #expect(rig.mode(second)?.name == "Compte rendu (copie 2)")
        #expect(rig.ids[4] == second, "toujours juste après l'original")
    }

    /// Un mode de base dupliqué devient personnel, avec la consigne qui s'appliquait (d'origine ou modifiée) ; le choix de
    /// relecture qui s'appliquait aussi (Prompt se relit par défaut, une copie n'a pas ce défaut).
    @Test func duplicatingABaseModeCopiesTheEffectiveInstructionAndTheEffectiveReview() throws {
        let rig = Rig()
        let model = rig.makeModel()
        let fromOrigin = model.duplicate(ModeChip.promptID)
        let copy = try #require(rig.mode(fromOrigin))
        #expect(copy.name == "Prompt (copie)")
        #expect(copy.instruction == ModeDefaults.prompt, "la consigne d'origine est recopiée en clair")
        #expect(copy.reviewBeforePaste == true, "Prompt se relit par défaut : la copie le garde")
        #expect(!copy.isBase && copy.canDelete)
        #expect(try row(model, fromOrigin).reviews)

        rig.settings.modes[1].instruction = "Ma version."
        let fromEdited = model.duplicate(ModeChip.cleanedID)
        #expect(rig.mode(fromEdited)?.instruction == "Ma version.")
        #expect(rig.mode(fromEdited)?.reviewBeforePaste == false)

        let fromRaw = model.duplicate(ModeChip.rawID)
        #expect(rig.mode(fromRaw)?.instruction == "")
        #expect(rig.mode(fromRaw)?.instructionIsEditable == true)
    }

    @Test func addBaseBringsBackCleanedOrPromptAtTheEndWithTheOriginalInstruction() throws {
        let rig = Rig(Self.personalSettings())
        rig.settings.modes[1].instruction = "Ma version."
        let model = rig.makeModel()
        #expect(model.missingBaseModes.isEmpty)

        model.delete(ModeChip.cleanedID)
        model.delete(ModeChip.promptID)
        #expect(model.missingBaseModes.map(\.id) == [ModeChip.cleanedID, ModeChip.promptID])
        #expect(model.missingBaseModes.map(\.title) == ["Dictée nettoyée", "Prompt"])

        let updatesBefore = rig.updates
        model.addBase(ModeChip.promptID)
        #expect(rig.updates == updatesBefore + 1)
        #expect(rig.ids.last == ModeChip.promptID, "à la fin")
        #expect(rig.mode(ModeChip.promptID)?.instruction == nil, "la consigne d'origine")
        #expect(rig.mode(ModeChip.promptID)?.hotKey == nil)
        #expect(model.missingBaseModes.map(\.id) == [ModeChip.cleanedID])

        model.addBase(ModeChip.cleanedID)
        #expect(rig.ids.suffix(2) == [ModeChip.promptID, ModeChip.cleanedID])
        #expect(rig.mode(ModeChip.cleanedID)?.instruction == nil, "la version modifiée a disparu avec le mode")
        #expect(model.missingBaseModes.isEmpty)
        #expect(try row(model, ModeChip.promptID).reviews, "Prompt se relit par défaut")
    }

    @Test func addBaseDoesNothingForAModeThatIsThereOrIsNotABaseToBringBack() {
        let rig = Rig()
        let model = rig.makeModel()
        model.addBase(ModeChip.promptID)
        model.addBase(ModeChip.rawID)
        model.addBase(ModeChip.interviewID)
        model.addBase("perso-inconnu")
        #expect(rig.updates == 0)
        #expect(rig.ids == ModeChip.fixed.map(\.id))
    }

    // MARK: - Règle 3 : supprimer

    @Test func theRawAndInterviewModesCannotBeDeleted() throws {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        #expect(try row(model, ModeChip.rawID).canDelete == false)
        #expect(try row(model, ModeChip.interviewID).canDelete == false)
        model.delete(ModeChip.rawID)
        model.delete(ModeChip.interviewID)
        #expect(rig.updates == 0)
        #expect(rig.ids.contains(ModeChip.rawID) && rig.ids.contains(ModeChip.interviewID))
        #expect(try row(model, "perso-un").canDelete)
        #expect(try row(model, ModeChip.promptID).canDelete)
    }

    @Test func aDeletedModeLosesItsHotKeyWithIt() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        model.delete("perso-un")
        #expect(rig.updates == 1)
        #expect(!rig.ids.contains("perso-un"))
        #expect(rig.settings.modes.compactMap(\.hotKey).isEmpty)
        #expect(model.rows.map(\.id) == rig.ids)
    }

    /// Tâche 4, règle 1 : le mode choisi dans le panneau est supprimé, `lastModeID` revient à Dictée brute dans la MÊME écriture.
    @Test func deletingTheChosenModeResetsTheLastModeInTheSameWrite() {
        let rig = Rig(Self.personalSettings(lastModeID: "perso-un"))
        let model = rig.makeModel()
        model.delete("perso-un")
        #expect(rig.updates == 1, "une seule écriture, pas de seconde passe")
        #expect(rig.settings.lastModeID == ModeChip.rawID)
        #expect(!rig.ids.contains("perso-un"))
    }

    @Test func deletingAnotherModeKeepsTheLastMode() {
        let rig = Rig(Self.personalSettings(lastModeID: ModeChip.promptID))
        let model = rig.makeModel()
        model.delete("perso-un")
        #expect(rig.settings.lastModeID == ModeChip.promptID)
        #expect(rig.updates == 1)
    }

    // MARK: - Règle 4 : modifier

    @Test func aBlankNameIsRefusedWithASentenceAndWritesNothing() throws {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        for blank in ["", "   ", "\n\t "] {
            model.save(ModeDraft.example(id: "perso-un", name: blank))
            #expect(model.message == ModesModel.blankNameMessage)
        }
        #expect(ModesModel.blankNameMessage == "Donnez un nom au mode.")
        #expect(rig.updates == 0)
        #expect(rig.mode("perso-un")?.name == "Compte rendu")
        #expect(model.revision == 0, "un refus de saisie n'est pas un enregistrement refusé")
    }

    @Test func aNameAlreadyTakenIsRefusedWhateverTheCase() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        for taken in ["Courriel", "courriel", "COURRIEL", "  Courriel  ", "prompt", "DICTÉE BRUTE"] {
            model.save(ModeDraft.example(id: "perso-un", name: taken))
            #expect(model.message == ModesModel.nameTakenMessage, "« \(taken) »")
        }
        #expect(ModesModel.nameTakenMessage == "Un autre mode porte déjà ce nom : choisissez-en un autre.")
        #expect(rig.updates == 0)
        #expect(rig.mode("perso-un")?.name == "Compte rendu")
    }

    @Test func aModeMayKeepOrReCaseItsOwnNameAndTheNameIsTrimmed() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        model.save(ModeDraft.example(id: "perso-un", name: "Compte rendu"))
        #expect(model.message == nil)
        model.save(ModeDraft.example(id: "perso-un", name: "  COMPTE RENDU  "))
        #expect(model.message == nil)
        #expect(rig.mode("perso-un")?.name == "COMPTE RENDU")
        #expect(rig.updates == 2)
    }

    @Test func theInstructionOfTheRawAndInterviewModesCannotBeEdited() throws {
        let rig = Rig()
        let model = rig.makeModel()
        for id in [ModeChip.rawID, ModeChip.interviewID] {
            var draft = model.draft(for: id)
            #expect(!draft.isInstructionEditable)
            #expect(draft.instruction == "")
            draft.instruction = "Une consigne qui ne doit pas passer."
            model.save(draft)
            #expect(rig.mode(id)?.instruction == nil)
        }
        #expect(model.draft(for: ModeChip.cleanedID).isInstructionEditable)
    }

    @Test func aBaseInstructionEqualToTheOriginalIsSavedAsNilAndAnEditedOneAsText() {
        let rig = Rig()
        let model = rig.makeModel()
        var draft = model.draft(for: ModeChip.promptID)
        #expect(draft.instruction == ModeDefaults.prompt)
        #expect(!draft.isInstructionModified)

        draft.instruction = "Ma version."
        model.save(draft)
        #expect(rig.mode(ModeChip.promptID)?.instruction == "Ma version.")
        let edited = model.draft(for: ModeChip.promptID)
        #expect(edited.isInstructionModified)
        #expect(edited.instruction == "Ma version.")

        var back = edited
        back.instruction = ModeDefaults.prompt
        model.save(back)
        #expect(rig.mode(ModeChip.promptID)?.instruction == nil, "égale à l'origine : l'origine, pas une copie")
        #expect(!model.draft(for: ModeChip.promptID).isInstructionModified)
    }

    @Test func resetInstructionPutsTheOriginalBackAndSavesOnceOnlyIfThereIsSomethingToReset() {
        let rig = Rig()
        rig.settings.modes[2].instruction = "Ma version."
        let model = rig.makeModel()
        #expect(model.draft(for: ModeChip.promptID).isInstructionModified)

        model.resetInstruction(ModeChip.promptID)
        #expect(rig.updates == 1)
        #expect(rig.mode(ModeChip.promptID)?.instruction == nil)
        #expect(!model.draft(for: ModeChip.promptID).isInstructionModified)

        model.resetInstruction(ModeChip.promptID)  // déjà d'origine
        model.resetInstruction(ModeChip.rawID)  // pas d'origine
        #expect(rig.updates == 1)
    }

    /// « Revenir à la consigne d'origine » ne change que le brouillon de la feuille : rien n'est écrit avant « Enregistrer », et
    /// abandonner la feuille laisse la consigne personnelle des réglages.
    @Test func resettingTheInstructionInTheSheetOnlyChangesTheDraftUntilItIsSaved() {
        let rig = Rig()
        rig.settings.modes[2].instruction = "Ma consigne personnelle, longue."
        let model = rig.makeModel()
        var draft = model.draft(for: ModeChip.promptID)
        #expect(draft.isInstructionModified)

        draft.resetInstructionToOrigin()
        #expect(draft.instruction == ModeDefaults.prompt)
        #expect(!draft.isInstructionModified)
        // « Annuler » : le brouillon est jeté.
        #expect(rig.updates == 0)
        #expect(rig.mode(ModeChip.promptID)?.instruction == "Ma consigne personnelle, longue.")
        #expect(model.draft(for: ModeChip.promptID).instruction == "Ma consigne personnelle, longue.")

        // « Enregistrer » : l'origine est écrite comme `nil`.
        model.save(draft)
        #expect(rig.updates == 1)
        #expect(rig.mode(ModeChip.promptID)?.instruction == nil)
    }

    @Test func resettingTheInstructionOfAModeWithoutAnOriginChangesNothing() {
        let model = Rig(Self.personalSettings()).makeModel()
        var draft = model.draft(for: "perso-un")
        draft.instruction = "Modifiée dans la feuille."
        draft.resetInstructionToOrigin()
        #expect(draft.instruction == "Modifiée dans la feuille.")
    }

    /// Un mode personnel n'a pas d'origine : sa consigne n'est jamais « modifiée ».
    @Test func aPersonalInstructionIsNeverReportedAsModified() throws {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        let draft = model.draft(for: "perso-un")
        #expect(!draft.isInstructionModified)
        #expect(draft.instruction == "Résume.")
        model.resetInstruction("perso-un")
        #expect(rig.updates == 0, "un mode personnel n'a pas d'origine à remettre")
        #expect(rig.mode("perso-un")?.instruction == "Résume.")
    }

    @Test func saveWritesTheNameTheInstructionTheModelTheEngineAndTheReview() throws {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        var draft = model.draft(for: "perso-un")
        #expect(draft.name == "Compte rendu" && draft.model == Self.strong && draft.engine == .parakeet)
        #expect(draft.reviews == false)
        #expect(draft.hotKeyLabel == "⌃⌥B")

        draft.name = "Synthèse"
        draft.instruction = "Fais une synthèse."
        draft.model = Self.fast
        draft.engine = .whisperKit
        draft.reviews = true
        model.save(draft)

        #expect(rig.updates == 1)
        let saved = try #require(rig.mode("perso-un"))
        #expect(saved.name == "Synthèse" && saved.instruction == "Fais une synthèse.")
        #expect(saved.model == Self.fast && saved.engine == .whisperKit && saved.reviewBeforePaste == true)
        #expect(saved.hotKey == Self.keyB)
        #expect(model.message == nil)
        #expect(try row(model, "perso-un").title == "Synthèse")

        draft.model = nil
        draft.engine = nil
        model.save(draft)
        #expect(rig.mode("perso-un")?.model == nil && rig.mode("perso-un")?.engine == nil)
    }

    /// Un choix de relecture que l'édition ne change pas reste « le défaut du mode », sans devenir un choix enregistré.
    @Test func savingWithoutTouchingTheReviewKeepsTheModesDefault() {
        let rig = Rig()
        let model = rig.makeModel()
        model.save(model.draft(for: ModeChip.promptID))
        model.save(model.draft(for: ModeChip.interviewID))
        #expect(rig.mode(ModeChip.promptID)?.reviewBeforePaste == nil)
        #expect(rig.mode(ModeChip.interviewID)?.reviewBeforePaste == nil)
        var interview = model.draft(for: ModeChip.interviewID)
        interview.reviews = false
        model.save(interview)
        #expect(rig.mode(ModeChip.interviewID)?.reviewBeforePaste == nil, "Entretien est toujours relu")
    }

    /// Le raccourci n'est pas un champ de l'édition : un raccourci changé pendant que la feuille est ouverte reste.
    @Test func saveKeepsTheHotKeyChangedWhileTheSheetWasOpen() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        var draft = model.draft(for: "perso-un")
        rig.settings.modes[3].hotKey = Self.keyC
        draft.name = "Synthèse"
        model.save(draft)
        #expect(rig.mode("perso-un")?.hotKey == Self.keyC)
    }

    @Test func aVeryLongInstructionIsKeptWhole() throws {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        let long = String(repeating: "Une phrase de la consigne. ", count: 400)
        var draft = model.draft(for: "perso-un")
        draft.instruction = long
        model.save(draft)
        #expect(rig.mode("perso-un")?.instruction == long)
        #expect(model.draft(for: "perso-un").instruction == long)
    }

    // MARK: - Règle 5 : modèles

    @Test func modelOptionsListEachProviderWithItsLastKnownModels() {
        var settings = Rig.defaultSettings()
        settings.providers.append(Self.emptyProvider)
        let model = Rig(settings).makeModel()
        #expect(
            model.modelOptions == [
                ModesModel.ModelOption(
                    providerID: Self.provider.id, providerName: "Fournisseur d'exemple",
                    models: ["modele-exemple-fort", "modele-exemple-rapide"]),
                ModesModel.ModelOption(providerID: Self.emptyProvider.id, providerName: "Second exemple", models: []),
            ])
        #expect(Rig().makeModel().modelOptions.count == 1)
    }

    @Test func theStrongAndFastChoicesAreSavedAndCanBeClearedAndTheDefaultIsNil() throws {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        #expect(model.strongModel == nil && model.fastModel == nil)
        model.setStrongModel(Self.strong)
        model.setFastModel(Self.fast)
        #expect(rig.settings.strongModel == Self.strong && rig.settings.fastModel == Self.fast)
        #expect(model.strongModel == Self.strong && model.fastModel == Self.fast)
        model.setStrongModel(nil)
        #expect(rig.settings.strongModel == nil)
        // « Modèle fort (par défaut) » vaut nil : le mode n'a pas de modèle propre.
        var draft = model.draft(for: "perso-un")
        draft.model = nil
        model.save(draft)
        #expect(rig.mode("perso-un")?.model == nil)
        #expect(ModesModel.defaultModelTitle == "Modèle fort (par défaut)")
    }

    @Test func aChosenModelMissingFromTheLastListStaysShownAndMarked() throws {
        let rig = Rig()
        let model = rig.makeModel()
        let gone = ModelChoice(providerID: Self.provider.id, model: "modele-retire")
        let content = model.pickerContent(selected: gone)
        let group = try #require(content.groups.first)
        #expect(group.items.map(\.label) == [
            "modele-exemple-fort", "modele-exemple-rapide", "modele-retire (absent de la dernière liste)",
        ])
        #expect(group.items.last?.choice == gone)
        #expect(content.removedProviderChoice == nil)
        // Un modèle présent n'est pas marqué.
        let present = model.pickerContent(selected: Self.strong)
        #expect(present.groups.first?.items.map(\.label) == ["modele-exemple-fort", "modele-exemple-rapide"])
        #expect(ModesModel.absentFromListMarker == "absent de la dernière liste")
    }

    @Test func aDeletedProviderIsSaidOnTheRowAndTheChoiceIsNotErased() throws {
        var settings = Self.personalSettings()
        settings.providers = []
        let rig = Rig(settings)
        let model = rig.makeModel()
        let line = try row(model, "perso-un")
        #expect(line.note == "Fournisseur supprimé : choisissez un autre modèle.")
        #expect(ModesModel.removedProviderNote == "Fournisseur supprimé : choisissez un autre modèle.")
        #expect(line.summary.contains("modele-exemple-fort") && line.summary.contains("fournisseur supprimé"))
        #expect(rig.mode("perso-un")?.model == Self.strong, "le choix n'est pas effacé seul")
        #expect(rig.updates == 0)
        let draft = model.draft(for: "perso-un")
        #expect(draft.model == Self.strong)
        let content = model.pickerContent(selected: draft.model)
        #expect(content.removedProviderChoice?.choice == Self.strong)
        #expect(content.removedProviderChoice?.label == "modele-exemple-fort (fournisseur supprimé)")
        #expect(model.modelNote(for: draft) == ModesModel.removedProviderNote)
        #expect(model.privacyNote(for: draft) == nil, "aucun fournisseur à nommer")
        // Un mode qui n'a pas de modèle propre ne porte pas cette note.
        #expect(try row(model, ModeChip.cleanedID).note != ModesModel.removedProviderNote)
    }

    @Test func aProviderWithoutAListedModelPointsToTheProvidersTab() throws {
        var settings = Rig.defaultSettings()
        settings.providers = [Self.emptyProvider]
        let model = Rig(settings).makeModel()
        let content = model.pickerContent(selected: nil)
        let group = try #require(content.groups.first)
        #expect(group.items.isEmpty)
        #expect(
            group.emptyNote
                == "« Second exemple » n'a aucun modèle listé : ouvrez l'onglet Fournisseurs, puis choisissez « Lister les modèles ».")
        #expect(Rig().makeModel().pickerContent(selected: nil).groups.first?.emptyNote == nil)
        let none = Rig(AppSettings.defaults).makeModel().pickerContent(selected: nil)
        #expect(none.groups.isEmpty)
        #expect(none.emptyNote == "Aucun fournisseur n'est enregistré : ajoutez-en un dans l'onglet Fournisseurs.")
    }

    @Test func theModelNoteSaysWhenNoStrongModelIsChosenAndNamesTheProviderOtherwise() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        var draft = model.draft(for: "perso-deux")  // sans modèle propre
        #expect(model.privacyNote(for: draft) == nil, "aucun modèle fort : aucun fournisseur nommé")
        #expect(model.modelNote(for: draft) == ModesModel.noStrongModelNote)
        // Les phrases sont épinglées en toutes lettres : la section « Modèles » est en tête de l'onglet, sous l'introduction.
        #expect(
            ModesModel.noStrongModelNote
                == "Aucun modèle fort n'est choisi : le texte de ce mode ne pourra pas être mis en forme. Choisissez-en un en tête de l'onglet Modes, dans « Modèles », ou choisissez un modèle propre à ce mode.")
        #expect(ModesModel.removedProviderNote == "Fournisseur supprimé : choisissez un autre modèle.")
        #expect(ModesModel.noProviderNote == "Aucun fournisseur n'est enregistré : ajoutez-en un dans l'onglet Fournisseurs.")
        model.setStrongModel(Self.strong)
        draft = model.draft(for: "perso-deux")
        #expect(model.privacyNote(for: draft) == ModesModel.privacyNote(providerName: "Fournisseur d'exemple"))
        #expect(model.modelNote(for: draft) == nil)
        // Sans consigne : rien n'est envoyé, rien à dire.
        draft.instruction = "  \n"
        #expect(model.privacyNote(for: draft) == nil)
        #expect(model.modelNote(for: draft) == nil)
        // Un mode dont le fournisseur est celui d'un autre : c'est le sien qui est nommé.
        var settings = Self.personalSettings()
        settings.providers.append(Provider(id: UUID(), name: "Autre exemple", baseURL: "https://example.com/b", kind: .anthropic, models: ["m"]))
        settings.strongModel = Self.strong
        settings.modes[3].model = ModelChoice(providerID: settings.providers[1].id, model: "m")
        let other = Rig(settings).makeModel()
        #expect(other.privacyNote(for: other.draft(for: "perso-un")) == ModesModel.privacyNote(providerName: "Autre exemple"))
        #expect(other.privacyNote(for: other.draft(for: "perso-deux")) == ModesModel.privacyNote(providerName: "Fournisseur d'exemple"))
    }

    /// Tant qu'aucun modèle fort n'est choisi, chaque ligne qui en dépend (consigne, pas de modèle propre) le dit ; la note disparaît
    /// dès qu'il est choisi ; un mode sans consigne, ou qui a son modèle, ne la porte jamais.
    @Test func aRowThatDependsOnTheStrongModelSaysSoUntilOneIsChosen() throws {
        let literal = "Aucun modèle fort n'est choisi : choisissez-en un ci-dessus, dans « Modèles »."
        #expect(ModesModel.noStrongModelRowNote == literal)
        var settings = Self.personalSettings()
        settings.modes.append(Mode(id: "perso-vide", name: "Sans consigne", instruction: ""))
        let rig = Rig(settings)
        let model = rig.makeModel()
        #expect(try row(model, ModeChip.cleanedID).note == literal)
        #expect(try row(model, ModeChip.promptID).note == literal)
        #expect(try row(model, "perso-deux").note == literal)
        #expect(try row(model, "perso-un").note == nil, "il a son modèle propre")
        #expect(try row(model, ModeChip.rawID).note == nil, "il ne passe pas par un modèle")
        #expect(try row(model, "perso-vide").note == nil, "sans consigne : rien n'est envoyé")
        #expect(try row(model, ModeChip.interviewID).note?.contains("Aucun modèle fort") == false)

        model.setStrongModel(Self.strong)
        #expect(model.rows.compactMap(\.note).filter { $0 == literal }.isEmpty)
        #expect(try row(model, ModeChip.cleanedID).note == nil)

        // Un modèle fort dont le fournisseur est supprimé : la ligne dit autre chose, et le dit vrai.
        rig.settings.providers = []
        model.reload()
        #expect(try row(model, ModeChip.cleanedID).note == ModesModel.removedProviderNote)
        #expect(try row(model, "perso-un").note == ModesModel.removedProviderNote, "son propre modèle est aussi sans fournisseur")
    }

    /// Sans aucun fournisseur, la feuille ne renvoie pas à des choix qui n'existent pas encore : l'explication du sélecteur suffit.
    @Test func withoutAnyProviderTheSheetDoesNotPointToChoicesThatDoNotExist() {
        let model = Rig(AppSettings.defaults).makeModel()
        let draft = model.draft(for: ModeChip.promptID)
        #expect(model.modelNote(for: draft) == nil)
        #expect(model.pickerContent(selected: nil).emptyNote == ModesModel.noProviderNote)
    }

    // MARK: - Longueur du nom

    @Test func aNameOfMoreThanSixtyCharactersIsRefusedWithoutAnyWrite() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        #expect(ModesModel.nameLimit == 60)
        #expect(ModesModel.nameTooLongMessage == "Le nom d'un mode ne peut pas dépasser 60 caractères.")
        var draft = model.draft(for: "perso-un")
        draft.name = String(repeating: "x", count: 61)
        #expect(!model.save(draft))
        #expect(model.message == ModesModel.nameTooLongMessage)
        #expect(rig.updates == 0)
        // Le blanc autour ne compte pas ; soixante caractères exactement sont acceptés.
        draft.name = "  " + String(repeating: "x", count: 60) + "  "
        #expect(model.save(draft))
        #expect(rig.mode("perso-un")?.name.count == 60)
    }

    /// Un nom déjà plus long (fichier écrit à la main) ne bloque pas l'enregistrement d'un mode dont on ne change pas le nom.
    @Test func aModeThatAlreadyHasALongNameCanBeSavedWithoutRenamingIt() {
        let rig = Rig(Self.personalSettings())
        let long = String(repeating: "y", count: 90)
        rig.settings.modes[3].name = long
        let model = rig.makeModel()
        var draft = model.draft(for: "perso-un")
        draft.instruction = "Nouvelle consigne."
        #expect(model.save(draft))
        #expect(rig.mode("perso-un")?.name == long)
    }

    /// Les copies restent dans la limite, et une copie de copie ne s'empile pas : « X (copie) » donne « X (copie 2) ».
    @Test func copiesStayWithinTheLimitAndDoNotStack() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        rig.settings.modes[3].name = String(repeating: "z", count: 60)
        let long = model.duplicate("perso-un")
        #expect(rig.mode(long)?.name.count == 60)
        #expect(rig.mode(long)?.name.hasSuffix(" (copie)") == true)
        let again = model.duplicate("perso-un")
        #expect(rig.mode(again)?.name.count == 60)
        #expect(rig.mode(again)?.name.hasSuffix(" (copie 2)") == true)

        let first = model.duplicate("perso-deux")
        #expect(rig.mode(first)?.name == "Courriel (copie)")
        let ofCopy = model.duplicate(first)
        #expect(rig.mode(ofCopy)?.name == "Courriel (copie 2)", "pas « Courriel (copie) (copie) »")
    }

    // MARK: - Détails relevés à la revue

    /// Un refus suivi d'un raccourci général qui ne revient pas : les deux phrases sont dites, la raison du refus n'est pas perdue.
    @Test func aRefusalAndAFailedResumeAreBothSaid() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        rig.resumeResult = false
        model.startRecording(for: "perso-deux")
        model.record(Self.keyA, for: "perso-deux")  // tenu par le raccourci général
        let message = model.message ?? ""
        #expect(message.contains(HotKeyConflicts.heldByGlobal(label: Self.labelA)))
        #expect(message.contains(ModesModel.resumeFailure(label: Self.labelA)))
    }

    /// Une capture commence sans le message d'une précédente.
    @Test func aNewCaptureStartsWithoutTheMessageOfThePreviousOne() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        model.record(Self.keyA, for: "perso-deux")
        #expect(model.message != nil)
        model.startRecording(for: "perso-deux")
        #expect(model.message == nil)
        model.cancelRecording()
    }

    /// Fermer la feuille pendant une capture rend les raccourcis, retire le moniteur et efface le refus resté à l'écran.
    @Test func closingTheSheetDuringACaptureGivesTheHotKeysBack() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        model.save(ModeDraft.example(id: "perso-un", name: ""))  // un refus reste à l'écran
        #expect(model.message != nil)
        model.startRecording(for: "perso-deux")
        #expect(rig.suspends == 1 && rig.monitor.isActive)

        model.editorClosed()
        #expect(model.recordingModeID == nil)
        #expect(!rig.monitor.isActive)
        #expect(rig.resumes == 1, "les raccourcis sont rétablis")
        #expect(rig.applied.isEmpty && rig.updates == 0)
        #expect(model.message == nil)
        model.editorClosed()  // sans capture : rien de plus
        #expect(rig.resumes == 1)
    }

    /// La confirmation de suppression dit que le panneau revient à Dictée brute quand le mode y était choisi.
    @Test func theDeletionMessageSaysWhenThePanelWillGoBackToTheRawMode() throws {
        let rig = Rig(Self.personalSettings(lastModeID: "perso-un"))
        let model = rig.makeModel()
        #expect(model.isChosenInPanel("perso-un"))
        #expect(!model.isChosenInPanel("perso-deux"))
        let chosen = ModesPane.deletionMessage(for: try row(model, "perso-un"), chosenInPanel: true)
        let other = ModesPane.deletionMessage(for: try row(model, "perso-deux"), chosenInPanel: false)
        #expect(chosen.hasSuffix(" Ce mode est choisi dans le panneau : le panneau reviendra à Dictée brute."))
        #expect(!other.contains("panneau"))
        #expect(
            ModesPane.deletionMessage(for: try row(model, ModeChip.promptID), chosenInPanel: false).contains("« Ajouter un mode »"))
    }

    /// Ce que la feuille dit à la place du champ de consigne de Dictée brute et d'Entretien : deux phrases propres à chacun.
    @Test func theSheetSaysWhyTheLockedModesHaveNoInstruction() {
        #expect(
            ModesModel.lockedInstructionNote(for: ModeChip.rawID)
                == "Ce mode n'a pas de consigne : le texte y est collé tel quel.")
        #expect(
            ModesModel.lockedInstructionNote(for: ModeChip.interviewID)
                == "Ce mode n'a pas de consigne à modifier. Ce mode arrive à une étape suivante.")
    }

    /// La feuille a une hauteur fixe qui tient sous une fenêtre de réglages sur un écran de 800 points, et un champ de consigne
    /// borné qui défile au-delà : la feuille ne grandit pas avec une consigne de plusieurs milliers de caractères.
    @Test func theSheetHasABoundedHeightAndABoundedInstructionField() {
        #expect(ModeEditor.sheetHeight <= 700)
        #expect(ModeEditor.instructionMaxHeight <= 120)
        #expect(ModeEditor.instructionMinHeight <= ModeEditor.instructionMaxHeight)
    }

    /// Sous un bandeau d'erreur, la dernière phrase d'aide de la feuille (« Le raccourci lance ce mode… ») était coupée par la
    /// barre des boutons : la feuille grandit de la place du bandeau, et le budget de 700 points tient encore.
    @Test func theSheetGrowsByTheBannerRoomWhileAnErrorShowsAndStaysUnderTheBudget() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        func sheetHeight() -> CGFloat {
            let host = NSHostingView(rootView: ModeEditor(model: model, id: "perso-deux"))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }
        #expect(model.message == nil)
        #expect(sheetHeight() == ModeEditor.sheetHeight)

        model.record(Self.keyA, for: "perso-deux")  // tenu par le raccourci général : un refus, donc un bandeau
        #expect(model.message != nil)
        #expect(sheetHeight() == ModeEditor.sheetHeight + ModeEditor.bannerRoom)
        #expect(ModeEditor.sheetHeight + ModeEditor.bannerRoom <= 700)
    }

    // MARK: - Trous relevés à la revue

    /// Un mode sans consigne n'envoie rien : un modèle périmé qu'il porte n'ajoute aucune note sur sa ligne.
    @Test func aModeWithoutInstructionNeverCarriesTheRemovedProviderNote() throws {
        var settings = Rig.defaultSettings()
        settings.providers = []
        settings.modes.append(Mode(id: "perso-vide", name: "Vide", instruction: "", model: Self.strong))
        let model = Rig(settings).makeModel()
        #expect(try row(model, "perso-vide").note == nil)
        #expect(try row(model, "perso-vide").summary == "Texte collé tel quel · Moteur de l'onglet Transcription")
    }

    /// Remettre un mode de base dont le nom est pris par un autre mode : le nom reste libre.
    @Test func addBaseKeepsTheNameFreeWhenAnotherModeTookIt() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        model.delete(ModeChip.promptID)
        var draft = model.draft(for: "perso-deux")
        draft.name = "Prompt"
        #expect(model.save(draft))

        model.addBase(ModeChip.promptID)
        let names = rig.settings.modes.map(\.name)
        #expect(names.filter { $0.lowercased() == "prompt" }.count == 1, "deux modes ne portent pas le même nom : \(names)")
        #expect(rig.mode(ModeChip.promptID)?.name == "Prompt 2")
    }

    /// Les accents comptent, la casse non : « Résumé » et « Resume » sont deux noms, « RÉSUMÉ » est le premier.
    @Test func accentsMakeTwoNamesDifferentAndCaseDoesNot() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        var draft = model.draft(for: "perso-un")
        draft.name = "Résumé"
        #expect(model.save(draft))
        var other = model.draft(for: "perso-deux")
        other.name = "Resume"
        #expect(model.save(other), "sans accent : un autre nom")
        other.name = "RÉSUMÉ"
        #expect(!model.save(other))
        #expect(model.message == ModesModel.nameTakenMessage)
    }

    @Test func savingAModeThatIsGoneSaysSoAndWritesNothing() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        rig.settings.modes.removeAll { $0.id == "perso-un" }
        #expect(!model.save(ModeDraft.example(id: "perso-un", name: "Fantôme")))
        #expect(model.message == ModesModel.unknownModeMessage)
        #expect(rig.updates == 0)
    }

    /// Entretien reste relu et sans message après une tentative de bascule ; Prompt, relu par défaut, reste relu quand
    /// l'enregistrement de son extinction est refusé.
    @Test func theInterviewStaysReviewedAndAFailedSwitchOffKeepsAReviewedDefault() throws {
        let rig = Rig()
        let model = rig.makeModel()
        model.setReview(false, for: ModeChip.interviewID)
        #expect(try row(model, ModeChip.interviewID).reviews)
        #expect(model.message == nil)

        rig.failure = SettingsError.unreadableFileKept(fileName: "settings.json")
        model.setReview(false, for: ModeChip.promptID)
        #expect(try row(model, ModeChip.promptID).reviews, "le défaut vrai n'est pas éteint par un enregistrement refusé")
        #expect(model.message != nil)
        rig.failure = nil
        model.setReview(false, for: ModeChip.promptID)
        #expect(try row(model, ModeChip.promptID).reviews == false)
        #expect(model.message == nil)
    }

    // MARK: - Règle 8 : ordre

    @Test func moveShiftsByOneStepAndStopsAtTheBounds() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        model.move("perso-un", by: 1)
        #expect(rig.ids == [ModeChip.rawID, ModeChip.cleanedID, ModeChip.promptID, "perso-deux", "perso-un", ModeChip.interviewID])
        #expect(model.rows.map(\.id) == rig.ids, "l'ordre des lignes est celui des pastilles")
        model.move("perso-un", by: -1)
        model.move("perso-un", by: -1)
        #expect(rig.ids.prefix(4) == [ModeChip.rawID, ModeChip.cleanedID, "perso-un", ModeChip.promptID])
        #expect(rig.updates == 3)

        // Bornes : aucun effet, aucune écriture.
        model.move(ModeChip.rawID, by: -1)
        model.move(ModeChip.interviewID, by: 1)
        model.move("perso-un", by: 0)
        model.move("perso-inconnu", by: 1)
        #expect(rig.updates == 3)
        #expect(rig.ids.first == ModeChip.rawID && rig.ids.last == ModeChip.interviewID)
    }

    // MARK: - Règle 7 : raccourci du mode

    @Test func recordingSuspendsTheHotKeysAndEscapeAloneCancels() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        model.startRecording(for: "perso-deux")
        #expect(model.recordingModeID == "perso-deux")
        #expect(rig.suspends == 1)
        #expect(rig.monitor.isActive)

        rig.monitor.send(keyCode: 0x35, flags: [])
        #expect(model.recordingModeID == nil)
        #expect(!rig.monitor.isActive)
        #expect(rig.resumes == 1)
        #expect(rig.applied.isEmpty)
        #expect(rig.updates == 0)
        #expect(model.message == nil, "annulée, pas refusée")
        #expect(rig.mode("perso-deux")?.hotKey == nil)
    }

    @Test func aCapturedCombinationIsAppliedThenSavedOnceAndTheCaptureEnds() throws {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        model.startRecording(for: "perso-deux")
        rig.monitor.send(keyCode: UInt16(Self.keyC.keyCode), flags: [.control, .option])

        #expect(rig.applied == [Rig.Applied(hotKey: Self.keyC, modeID: "perso-deux")])
        #expect(rig.updates == 1)
        #expect(rig.mode("perso-deux")?.hotKey == Self.keyC)
        #expect(model.message == nil)
        #expect(model.recordingModeID == nil)
        #expect(!rig.monitor.isActive)
        #expect(rig.resumes == 1)
        #expect(Self.labelC == "⌃⌥C")
        #expect(model.draft(for: "perso-deux").hotKeyLabel == Self.labelC)
        #expect(try row(model, "perso-deux").summary.hasSuffix(Self.labelC))
    }

    /// Avant le système : la combinaison du raccourci général, celle d'un autre mode, un raccourci de macOS, une combinaison
    /// invalide sont refusés avec la phrase de la table commune ; l'ancien raccourci reste, le système n'est pas sollicité.
    @Test func aRefusedCombinationKeepsTheOldHotKeyAndUsesTheSharedSentences() throws {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        let names = ["perso-un": "Compte rendu"]
        let cases: [(HotKey, String?)] = [
            (Self.keyA, HotKeyConflicts.heldByGlobal(label: Self.labelA)),
            (Self.keyB, HotKeyConflicts.heldByMode(label: Self.labelB, name: names["perso-un"])),
            (HotKey(keyCode: 0x00, modifiers: []), HotKeyConflicts.refusal(.needsModifier, label: "A")),
            (HotKey(keyCode: 0x0C, modifiers: [.command]), HotKeyConflicts.refusal(.reserved("⌘Q"), label: "⌘Q")),
        ]
        for (candidate, sentence) in cases {
            model.startRecording(for: "perso-deux")
            model.record(candidate, for: "perso-deux")
            #expect(model.message == sentence)
            #expect(model.message?.isEmpty == false)
            #expect(rig.mode("perso-deux")?.hotKey == nil)
        }
        rig.system.hotKeys = [Self.keyC]
        model.startRecording(for: "perso-deux")
        model.record(Self.keyC, for: "perso-deux")
        #expect(model.message == HotKeyConflicts.systemShortcutRefusal(label: Self.labelC))

        #expect(rig.applied.isEmpty, "le système n'est jamais sollicité")
        #expect(rig.updates == 0)
        #expect(rig.resumes == 5, "chaque capture rend les raccourcis, quelle que soit sa fin")
        #expect(rig.suspends == 5)
    }

    @Test func aCombinationThatTheModeAlreadyHoldsIsNotAConflict() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        model.record(Self.keyB, for: "perso-un")
        #expect(model.message == nil)
        #expect(rig.applied == [Rig.Applied(hotKey: Self.keyB, modeID: "perso-un")])
    }

    @Test func aCombinationTheSystemRefusesKeepsTheOldHotKeyAndSaysSo() {
        let rig = Rig(Self.personalSettings())
        rig.applyScript = [.failure(.refused)]
        let model = rig.makeModel()
        model.startRecording(for: "perso-un")
        model.record(Self.keyC, for: "perso-un")

        #expect(model.message == HotKeyConflicts.refusedBySystem(label: Self.labelC))
        #expect(rig.mode("perso-un")?.hotKey == Self.keyB, "l'ancien est gardé")
        #expect(rig.updates == 0)
        #expect(rig.applied == [Rig.Applied(hotKey: Self.keyC, modeID: "perso-un")])
        #expect(rig.resumes == 1)
    }

    @Test func aCombinationTheSystemCallsInvalidIsSaidWithTheSharedSentence() {
        let rig = Rig(Self.personalSettings())
        rig.applyScript = [.failure(.invalid(.needsModifier))]
        let model = rig.makeModel()
        model.record(Self.keyC, for: "perso-un")
        #expect(model.message == HotKeyConflicts.refusal(.needsModifier, label: Self.labelC))
        #expect(rig.updates == 0)
    }

    /// Enregistrement refusé : l'ancien raccourci est réappliqué.
    @Test func aRefusedSaveReappliesThePreviousHotKey() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        rig.failure = SettingsError.unreadableFileKept(fileName: "settings.json")
        model.startRecording(for: "perso-un")
        model.record(Self.keyC, for: "perso-un")

        #expect(rig.applied == [Rig.Applied(hotKey: Self.keyC, modeID: "perso-un"), Rig.Applied(hotKey: Self.keyB, modeID: "perso-un")])
        #expect(rig.mode("perso-un")?.hotKey == Self.keyB)
        #expect(model.message == SettingsError.unreadableFileKept(fileName: "settings.json").errorDescription)
        #expect(rig.resumes == 1)
    }

    @Test func aRefusedSaveThatCannotReapplyLeavesNoHotKeyActiveAndSaysSo() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        rig.failure = ForeignError()
        rig.applyScript = [.success(()), .failure(.refused)]
        model.record(Self.keyC, for: "perso-un")

        #expect(rig.applied.map(\.hotKey) == [Self.keyC, Self.keyB, nil])
        #expect(model.message?.hasPrefix(ModesModel.saveFailure) == true)
        #expect(model.message?.contains("Aucun raccourci n'est actif pour ce mode.") == true)
        #expect(model.message?.contains("example.com") == false)
        #expect(rig.mode("perso-un")?.hotKey == Self.keyB)
    }

    @Test func aModeWithoutAPreviousHotKeyIsClearedAgainWhenTheSaveFails() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        rig.failure = ForeignError()
        model.record(Self.keyC, for: "perso-deux")
        #expect(rig.applied == [Rig.Applied(hotKey: Self.keyC, modeID: "perso-deux"), Rig.Applied(hotKey: nil, modeID: "perso-deux")])
        #expect(rig.mode("perso-deux")?.hotKey == nil)
    }

    @Test func clearHotKeyRemovesItFromTheSystemAndTheSettingsInOneWrite() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        model.clearHotKey(for: "perso-un")
        #expect(rig.applied == [Rig.Applied(hotKey: nil, modeID: "perso-un")])
        #expect(rig.updates == 1)
        #expect(rig.mode("perso-un")?.hotKey == nil)
        model.clearHotKey(for: "perso-un")  // déjà sans raccourci
        model.clearHotKey(for: "perso-deux")
        #expect(rig.updates == 1)
        #expect(rig.applied.count == 1)
    }

    @Test func clearHotKeyThatCannotBeSavedPutsTheKeyBack() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        rig.failure = ForeignError()
        model.clearHotKey(for: "perso-un")
        #expect(rig.applied == [Rig.Applied(hotKey: nil, modeID: "perso-un"), Rig.Applied(hotKey: Self.keyB, modeID: "perso-un")])
        #expect(rig.mode("perso-un")?.hotKey == Self.keyB)
        #expect(model.message == ModesModel.saveFailure)
    }

    /// Un mode que les réglages ne portent plus : phrase fixe, rien n'est suspendu ni enregistré.
    @Test func aHotKeyForAModeThatIsGoneSaysSoAndRegistersNothing() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        rig.settings.modes.removeAll { $0.id == "perso-un" }

        model.startRecording(for: "perso-un")
        #expect(model.message == ModesModel.unknownModeMessage)
        #expect(rig.suspends == 0 && !rig.monitor.isActive && model.recordingModeID == nil)

        model.record(Self.keyC, for: "perso-un")
        model.clearHotKey(for: "perso-un")
        #expect(model.message == ModesModel.unknownModeMessage)
        #expect(rig.applied.isEmpty && rig.updates == 0)
        #expect(ModesModel.unknownModeMessage == "Ce mode n'existe plus : la liste vient d'être relue.")
    }

    /// Le système refuse de rétablir le raccourci général après la capture : la phrase le dit.
    @Test func aFailedResumeAfterTheCaptureIsSaid() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        rig.resumeResult = false
        model.startRecording(for: "perso-deux")
        model.cancelRecording()
        #expect(model.message == ModesModel.resumeFailure(label: Self.labelA))
        #expect(model.message?.contains("⌃⌥A") == true)
    }

    @Test func theKeyMonitorIsOnlyPlacedDuringTheCaptureWhateverTheEnd() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        #expect(!rig.monitor.isActive)
        model.startRecording(for: "perso-deux")
        #expect(rig.monitor.isActive)
        model.cancelRecording()
        #expect(!rig.monitor.isActive)
        model.cancelRecording()  // sans capture : rien
        #expect(rig.resumes == 1)

        model.startRecording(for: "perso-deux")
        model.startRecording(for: "perso-deux")  // déjà en capture pour ce mode
        #expect(rig.suspends == 2)
        // Une capture pour un autre mode remplace la première, sans suspendre deux fois ni rendre les raccourcis entre-temps.
        model.startRecording(for: "perso-un")
        #expect(model.recordingModeID == "perso-un")
        #expect(rig.suspends == 2)
        #expect(rig.resumes == 1)
        rig.monitor.send(keyCode: 0x00, flags: [])  // sans modificateur : refusé, capture finie
        #expect(!rig.monitor.isActive && model.recordingModeID == nil)
        #expect(rig.resumes == 2)
        #expect(model.message != nil)
    }

    @Test func deletingTheModeBeingCapturedEndsTheCapture() {
        let rig = Rig(Self.personalSettings())
        let model = rig.makeModel()
        model.startRecording(for: "perso-un")
        model.delete("perso-un")
        #expect(model.recordingModeID == nil && !rig.monitor.isActive)
        #expect(rig.resumes == 1)
    }
}

extension ModeDraft {
    /// Un brouillon qui ne change que ce que l'on dit : le nom ; le reste d'un mode personnel quelconque.
    static func example(id: String, name: String) -> ModeDraft {
        ModeDraft(
            id: id, name: name, instruction: "Résume.", isInstructionEditable: true, isInstructionModified: false,
            model: nil, engine: nil, reviews: false, hotKeyLabel: nil)
    }
}
