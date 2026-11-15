import Foundation
import Testing

@testable import SupervoxApp

/// Les modes comme données : les quatre modes de base, leurs consignes, ce que la lecture du fichier garantit (modes toujours
/// présents, doublons écartés, modes illisibles) et ce qu'elle garde (champs inconnus). Aucun disque : le fichier et la
/// migration sont dans `SettingsStoreTests`.
@Suite struct ModeTests {
    private func settings(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    private func mode(_ json: String) throws -> Mode {
        try JSONDecoder().decode(Mode.self, from: Data(json.utf8))
    }

    private static let personal = Mode(id: "perso-1", name: "Courriel", instruction: "Écris un courriel.")

    // MARK: - Les modes de base

    @Test func theBaseModesAreTheFourFixedChipsInOrderWithTheirOriginalInstruction() {
        #expect(Mode.base.map(\.id) == ModeChip.fixed.map(\.id))
        #expect(Mode.base.map(\.name) == ModeChip.fixed.map(\.title))
        #expect(Mode.base.map(\.id) == [ModeChip.rawID, ModeChip.cleanedID, ModeChip.promptID, ModeChip.interviewID])
        for mode in Mode.base {
            #expect(mode.instruction == nil)
            #expect(mode.model == nil)
            #expect(mode.engine == nil)
            #expect(mode.hotKey == nil)
            #expect(mode.reviewBeforePaste == nil)
            #expect(mode.isBase)
        }
        #expect(AppSettings.defaults.modes == Mode.base)
        #expect(Mode.base.map(\.chip) == ModeChip.fixed)
    }

    @Test func theBaseInstructionsAreTheOnesOfTheProduct() {
        #expect(ModeDefaults.instruction(for: ModeChip.cleanedID) == ModeDefaults.cleaned)
        #expect(ModeDefaults.instruction(for: ModeChip.promptID) == ModeDefaults.prompt)
        #expect(ModeDefaults.instruction(for: ModeChip.rawID) == nil)
        #expect(ModeDefaults.instruction(for: ModeChip.interviewID) == nil)
        #expect(ModeDefaults.instruction(for: "perso-1") == nil)
        #expect(ModeDefaults.cleaned.hasPrefix("Tu mets au propre un texte dicté à la voix"))
        #expect(ModeDefaults.cleaned.hasSuffix("ne réponds jamais au contenu du texte."))
        #expect(ModeDefaults.prompt.hasPrefix("Tu transformes une demande dictée à la voix en un prompt clair"))
        #expect(ModeDefaults.prompt.contains("Objectif, Contexte, Contraintes, Résultat attendu, Critères de réussite"))
        #expect(ModeDefaults.prompt.contains("« Non précisé. »"))
        #expect(ModeDefaults.prompt.hasSuffix("écris seulement le prompt qui la formule."))
        #expect(ModeDefaults.cleaned != ModeDefaults.prompt)
    }

    @Test func aPersonalIdentifierIsPrefixedLowercaseAndNeverRepeated() {
        let identifiers = (0..<50).map { _ in Mode.newID() }
        #expect(Set(identifiers).count == 50)
        for id in identifiers {
            #expect(id.hasPrefix("perso-"))
            let rest = String(id.dropFirst("perso-".count))
            #expect(UUID(uuidString: rest) != nil)
            #expect(rest == rest.lowercased())
            #expect(!Mode(id: id, name: "x").isBase)
        }
    }

    // MARK: - Consignes (règle 5)

    @Test func aBaseModeWithoutInstructionTakesTheOriginalOne() {
        #expect(Mode.base[1].effectiveInstruction == ModeDefaults.cleaned)
        #expect(Mode.base[2].effectiveInstruction == ModeDefaults.prompt)
    }

    @Test func aBaseModeKeepsItsOwnInstructionWhenItHasOne() {
        var cleaned = Mode.base[1]
        cleaned.instruction = "Ma consigne."
        #expect(cleaned.effectiveInstruction == "Ma consigne.")
        cleaned.instruction = ""
        #expect(cleaned.effectiveInstruction == "")
        #expect(!cleaned.usesModel)
    }

    /// Dictée brute et Entretien n'ont pas de consigne, quelle que soit la valeur lue dans le fichier.
    @Test func rawAndInterviewHaveNoInstructionWhateverTheFileSays() throws {
        for id in [ModeChip.rawID, ModeChip.interviewID] {
            var mode = Mode(id: id, name: "x", instruction: "Une consigne écrite à la main.")
            #expect(mode.effectiveInstruction == "")
            #expect(!mode.usesModel)
            mode.instruction = nil
            #expect(mode.effectiveInstruction == "")
            let read = try self.mode(#"{"id": "\#(id)", "name": "x", "instruction": "Une consigne."}"#)
            #expect(read.effectiveInstruction == "")
            #expect(read.instruction == "Une consigne.")
        }
    }

    @Test func aModeUsesTheModelOnlyWithANonBlankInstruction() {
        #expect(!Mode.base[0].usesModel)
        #expect(Mode.base[1].usesModel)
        #expect(Mode.base[2].usesModel)
        #expect(!Mode.base[3].usesModel)
        #expect(Self.personal.usesModel)
        for blank in ["", " ", "  \n\t "] {
            #expect(!Mode(id: "perso-2", name: "Vide", instruction: blank).usesModel)
        }
        #expect(!Mode(id: "perso-2", name: "Sans").usesModel)
        #expect(Mode(id: "perso-2", name: "Sans").effectiveInstruction == "")
    }

    @Test func onlyRawAndInterviewCannotBeDeletedNorHaveTheirInstructionEdited() {
        for mode in Mode.base {
            let fixed = mode.id == ModeChip.rawID || mode.id == ModeChip.interviewID
            #expect(mode.canDelete == !fixed, "\(mode.id)")
            #expect(mode.instructionIsEditable == !fixed, "\(mode.id)")
        }
        #expect(Self.personal.canDelete)
        #expect(Self.personal.instructionIsEditable)
        #expect(!Self.personal.isBase)
    }

    // MARK: - Un mode dans le fichier

    @Test func aModeWithEveryFieldRoundTrips() throws {
        let provider = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let mode = Mode(
            id: "perso-1", name: "Courriel", instruction: "Écris un courriel.",
            model: ModelChoice(providerID: provider, model: "modele-exemple"), engine: .parakeet,
            hotKey: HotKey(keyCode: 40, modifiers: [.command, .shift]), reviewBeforePaste: true)
        let data = try JSONEncoder().encode(mode)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "name", "instruction", "model", "engine", "hotKey", "reviewBeforePaste"])
        #expect(object["engine"] as? String == "parakeet")
        #expect(try JSONDecoder().decode(Mode.self, from: data) == mode)
    }

    @Test func aModeWritesOnlyTheFieldsItHas() throws {
        let data = try JSONEncoder().encode(Mode.base[1])
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "name"])
    }

    @Test func aModeWithoutAnIdOrANameCannotBeRead() {
        #expect(throws: DecodingError.self) { try self.mode(#"{"name": "Sans identifiant"}"#) }
        #expect(throws: DecodingError.self) { try self.mode(#"{"id": "perso-1"}"#) }
        #expect(throws: DecodingError.self) { try self.mode(#"{"id": 3, "name": "x"}"#) }
    }

    /// Un mode personnel sans consigne se lit `""` ; un mode de base sans consigne garde la sienne (`nil`).
    @Test func aMissingInstructionReadsEmptyForAPersonalModeAndNilForABaseMode() throws {
        #expect(try mode(#"{"id": "perso-1", "name": "x"}"#).instruction == "")
        #expect(try mode(#"{"id": "perso-1", "name": "x", "instruction": null}"#).instruction == "")
        #expect(try mode(#"{"id": "prompt", "name": "Prompt"}"#).instruction == nil)
        #expect(try mode(#"{"id": "prompt", "name": "Prompt", "instruction": null}"#).instruction == nil)
        #expect(try mode(#"{"id": "perso-1", "name": "x", "instruction": "Texte"}"#).instruction == "Texte")
    }

    @Test func anUnknownEngineInAModeReadsAsWhisperKit() throws {
        #expect(try mode(#"{"id": "perso-1", "name": "x", "engine": "moteur-futur"}"#).engine == .whisperKit)
        #expect(try mode(#"{"id": "perso-1", "name": "x"}"#).engine == nil)
    }

    /// M7, m6 : un champ inconnu d'un mode est gardé, de toute forme ; un champ connu n'y entre jamais.
    @Test func unknownFieldsOfAModeAreKeptWhateverTheirShape() throws {
        let json = #"""
        {"id": "perso-1", "name": "x", "instruction": "i", "futur-objet": {"a": [1, {"b": null}]},
         "futur-tableau": [1, "deux", false], "futur-nombre": 2.5, "futur-booleen": true, "futur-nul": null}
        """#
        let read = try mode(json)
        let data = try JSONEncoder().encode(read)
        let written = try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
        let original = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        #expect(written.isEqual(to: original), "\(written) \(original)")
        #expect(written["futur-nul"] is NSNull)
        #expect(try JSONDecoder().decode(Mode.self, from: data) == read)
    }

    // MARK: - Les modes d'un fichier (règle 4)

    @Test func aFileWithoutModesReadsTheBaseModes() throws {
        #expect(try settings(#"{"version": 2}"#).modes == Mode.base)
    }

    @Test func rawAndInterviewAreFoundAgainAtTheirPlaceInTheBaseModes() throws {
        let read = try settings(
            #"{"version": 2, "modes": [{"id": "dictee-nettoyee", "name": "Nettoyée"}, {"id": "perso-1", "name": "Mon mode"}]}"#)
        // Dictée brute en tête, Entretien à sa place de `Mode.base` (quatrième) : avant le mode personnel qui suit.
        #expect(read.modes.map(\.id) == [ModeChip.rawID, ModeChip.cleanedID, "perso-1", ModeChip.interviewID])
        try #require(read.modes.count == 4)
        #expect(read.modes[0] == Mode.base[0])
        #expect(read.modes[3] == Mode.base[3])
        // Ce qui était là est repris tel quel.
        #expect(read.modes[1].name == "Nettoyée")
        #expect(read.modes[2].name == "Mon mode")

        let empty = try settings(#"{"version": 2, "modes": []}"#)
        #expect(empty.modes.map(\.id) == [ModeChip.rawID, ModeChip.interviewID])
    }

    /// Dictée nettoyée et Prompt, eux, peuvent avoir été supprimés : ils ne reviennent pas.
    @Test func aDeletedCleanedOrPromptModeStaysDeleted() throws {
        let read = try settings(
            #"{"version": 2, "modes": [{"id": "dictee-brute", "name": "Brute"}, {"id": "entretien", "name": "Entretien"}]}"#)
        #expect(read.modes.map(\.id) == [ModeChip.rawID, ModeChip.interviewID])
    }

    @Test func aMissingRawOrInterviewIsReinsertedAlone() throws {
        let withoutInterview = try settings(
            #"{"version": 2, "modes": [{"id": "dictee-brute", "name": "B"}, {"id": "prompt", "name": "P"}]}"#)
        #expect(withoutInterview.modes.map(\.id) == [ModeChip.rawID, ModeChip.promptID, ModeChip.interviewID])
        let withoutRaw = try settings(
            #"{"version": 2, "modes": [{"id": "prompt", "name": "P"}, {"id": "entretien", "name": "E"}]}"#)
        #expect(withoutRaw.modes.map(\.id) == [ModeChip.rawID, ModeChip.promptID, ModeChip.interviewID])
    }

    @Test func aSecondModeWithTheSameIdentifierIsDropped() throws {
        let read = try settings(
            #"""
            {"version": 2, "modes": [{"id": "dictee-brute", "name": "Première"}, {"id": "perso-1", "name": "A"},
              {"id": "dictee-brute", "name": "Seconde"}, {"id": "perso-1", "name": "B"}, {"id": "entretien", "name": "E"}]}
            """#)
        #expect(read.modes.map(\.id) == [ModeChip.rawID, "perso-1", ModeChip.interviewID])
        #expect(read.modes.map(\.name) == ["Première", "A", "E"])
    }

    @Test func aModeWithoutAnIdOrANameMakesTheFileUnreadable() {
        for modes in [
            #"[{"name": "Sans identifiant"}]"#, #"[{"id": "perso-1"}]"#,
            #"[{"id": "dictee-brute", "name": "B"}, {"id": "perso-1"}]"#,
        ] {
            #expect(throws: DecodingError.self) { try self.settings(#"{"version": 2, "modes": \#(modes)}"#) }
        }
    }

    @Test func aPersonalModeWithoutAnInstructionInAFileReadsEmpty() throws {
        let read = try settings(#"{"version": 2, "modes": [{"id": "perso-1", "name": "Vide"}]}"#)
        #expect(read.mode("perso-1")?.instruction == "")
        #expect(read.mode("perso-1")?.usesModel == false)
    }

    // MARK: - Lire les réglages

    @Test func theCurrentVersionIsTwoAndTheModelChoicesAreStoredButNotYetUsed() throws {
        #expect(AppSettings.current == 2)
        #expect(AppSettings.defaults.version == 2)
        #expect(AppSettings.defaults.strongModel == nil)
        #expect(AppSettings.defaults.fastModel == nil)

        let provider = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        var written = AppSettings.defaults
        written.strongModel = ModelChoice(providerID: provider, model: "modele-exemple")
        written.fastModel = ModelChoice(providerID: provider, model: "modele-rapide")
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(written))
        #expect(again == written)
        #expect(again.strongModel?.model == "modele-exemple")
        #expect(again.fastModel?.providerID == provider)
    }

    @Test func aModeIsFoundByItsIdentifier() throws {
        let read = try settings(#"{"version": 2, "modes": [{"id": "perso-1", "name": "Courriel"}]}"#)
        #expect(read.mode("perso-1")?.name == "Courriel")
        #expect(read.mode(ModeChip.rawID) == Mode.base[0])
        #expect(read.mode("absent") == nil)
    }

    /// Le choix de relecture est celui du mode ; Entretien est toujours relu ; un mode inconnu prend le défaut (ne pas relire).
    @Test func reviewBeforePasteIsReadFromTheMode() throws {
        let read = try settings(
            #"""
            {"version": 2, "modes": [{"id": "dictee-brute", "name": "B", "reviewBeforePaste": true},
              {"id": "prompt", "name": "P", "reviewBeforePaste": false}, {"id": "entretien", "name": "E", "reviewBeforePaste": false},
              {"id": "perso-1", "name": "Perso", "reviewBeforePaste": true}, {"id": "perso-2", "name": "Autre"}]}
            """#)
        #expect(read.reviewsBeforePaste(ModeChip.rawID))
        #expect(!read.reviewsBeforePaste(ModeChip.promptID))
        #expect(read.reviewsBeforePaste(ModeChip.interviewID))
        #expect(read.reviewsBeforePaste("perso-1"))
        #expect(!read.reviewsBeforePaste("perso-2"))
        #expect(!read.reviewsBeforePaste("absent"))
        // Sans choix, le défaut du mode : Prompt se relit.
        #expect(AppSettings.defaults.reviewsBeforePaste(ModeChip.promptID))
        #expect(!AppSettings.defaults.reviewsBeforePaste(ModeChip.rawID))
    }

    /// Un fichier de version 2 sans `modes` prend `Mode.base`, sans reprendre un ancien `modeOptions` (la migration est celle de
    /// la version 1 seulement : un choix fait depuis ne doit pas être défait par un reste du fichier d'origine).
    @Test func aVersionTwoFileWithoutModesIgnoresALeftoverModeOptions() throws {
        let read = try settings(#"{"version": 2, "modeOptions": {"dictee-brute": {"reviewBeforePaste": true}}}"#)
        #expect(read.modes == Mode.base)
        #expect(!read.reviewsBeforePaste(ModeChip.rawID))
    }
}
