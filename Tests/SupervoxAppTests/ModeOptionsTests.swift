import Foundation
import Testing

@testable import SupervoxApp

/// Le réglage « relire avant de coller », par mode : défauts, choix enregistrés, Entretien toujours relu. Depuis la version 2
/// du fichier, le choix vit dans chaque mode ; `modeOptions` (version 1) ne sert plus qu'à la migration, une fois, et reste
/// dans le fichier tel quel. Aucun disque : le format du fichier est dans `SettingsStoreTests`.
@Suite struct ModeOptionsTests {
    private func settings(_ json: String) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
    }

    @Test func theFixedModeIdentifiersAreTheOnesTheModeChipsCarry() {
        #expect(ModeChip.fixed.map(\.id) == [ModeChip.rawID, ModeChip.cleanedID, ModeChip.promptID, ModeChip.interviewID])
        #expect(ModeChip.fallbackID == ModeChip.rawID)
        #expect(AppSettings.defaults.lastModeID == ModeChip.rawID)
    }

    /// Sans choix enregistré : seuls Prompt et Entretien se relisent.
    @Test func withoutAChoiceOnlyPromptAndInterviewAreReviewed() {
        let defaults = AppSettings.defaults
        #expect(defaults.modes.allSatisfy { $0.reviewBeforePaste == nil })
        #expect(!defaults.reviewsBeforePaste(ModeChip.rawID))
        #expect(!defaults.reviewsBeforePaste(ModeChip.cleanedID))
        #expect(defaults.reviewsBeforePaste(ModeChip.promptID))
        #expect(defaults.reviewsBeforePaste(ModeChip.interviewID))
        #expect(!AppSettings.reviewDefault(ModeChip.rawID))
        #expect(!AppSettings.reviewDefault(ModeChip.cleanedID))
        #expect(AppSettings.reviewDefault(ModeChip.promptID))
        #expect(AppSettings.reviewDefault(ModeChip.interviewID))
        #expect(!AppSettings.reviewDefault("mode-inconnu"))
    }

    /// Un objet d'options sans `reviewBeforePaste` prend le défaut du mode, quel qu'il soit : le test porte sur un mode dont
    /// le défaut est vrai et sur un mode dont il est faux.
    @Test func anOptionsObjectWithoutTheFieldTakesTheModeDefault() throws {
        let decoded = try settings(
            #"{"version": 1, "modeOptions": {"prompt": {}, "dictee-brute": {}, "dictee-nettoyee": {"futur": 3}}}"#)
        #expect(decoded.modes == Mode.base)
        #expect(decoded.reviewsBeforePaste(ModeChip.promptID))
        #expect(!decoded.reviewsBeforePaste(ModeChip.rawID))
        #expect(!decoded.reviewsBeforePaste(ModeChip.cleanedID))
    }

    @Test func aSavedChoiceOverridesTheDefaultInBothDirections() throws {
        let decoded = try settings(
            #"{"version": 1, "modeOptions": {"prompt": {"reviewBeforePaste": false}, "dictee-brute": {"reviewBeforePaste": true}}}"#)
        #expect(decoded.mode(ModeChip.promptID)?.reviewBeforePaste == false)
        #expect(decoded.mode(ModeChip.rawID)?.reviewBeforePaste == true)
        #expect(!decoded.reviewsBeforePaste(ModeChip.promptID))
        #expect(decoded.reviewsBeforePaste(ModeChip.rawID))
    }

    /// Entretien passe toujours par la relecture : un fichier qui dit le contraire n'y change rien à la lecture, et sa valeur
    /// reste telle quelle à l'aller-retour (elle n'est pas réécrite en vrai).
    @Test func theInterviewIsAlwaysReviewedWhateverTheFileSays() throws {
        let decoded = try settings(#"{"version": 1, "modeOptions": {"entretien": {"reviewBeforePaste": false}}}"#)
        #expect(decoded.mode(ModeChip.interviewID)?.reviewBeforePaste == false)
        #expect(decoded.reviewsBeforePaste(ModeChip.interviewID))
        #expect(AppSettings.alwaysReviewed == [ModeChip.interviewID])

        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(decoded))
        #expect(again.mode(ModeChip.interviewID)?.reviewBeforePaste == false)
        #expect(again.reviewsBeforePaste(ModeChip.interviewID))

        let inModes = try settings(
            #"{"version": 2, "modes": [{"id": "entretien", "name": "Entretien", "reviewBeforePaste": false}]}"#)
        #expect(inModes.reviewsBeforePaste(ModeChip.interviewID))
    }

    /// Un identifiant que `modes` ne connaît pas n'est pas un mode : son entrée de `modeOptions` n'en crée pas, ne s'applique
    /// à rien, mais reste dans le fichier, telle quelle, à l'aller-retour.
    @Test func anUnknownModeIdentifierInTheOldOptionsIsKeptButCreatesNoMode() throws {
        let decoded = try settings(
            #"{"version": 1, "modeOptions": {"mode-perso": {"reviewBeforePaste": true}, "autre": {}}}"#)
        #expect(decoded.modes == Mode.base)
        #expect(!decoded.reviewsBeforePaste("mode-perso"))

        let data = try JSONEncoder().encode(decoded)
        let written = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let options = try #require(written["modeOptions"] as? NSDictionary)
        #expect(options.isEqual(to: ["mode-perso": ["reviewBeforePaste": true], "autre": [String: Bool]()]))
    }

    /// Le décodage d'un objet d'options ignore ce qu'il ne connaît pas et se contente de `{}`.
    @Test func optionsDecodeLeniently() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ModeOptions.self, from: Data("{}".utf8)) == ModeOptions())
        #expect(
            try decoder.decode(ModeOptions.self, from: Data(#"{"reviewBeforePaste": true, "autre": [1, 2]}"#.utf8))
                == ModeOptions(reviewBeforePaste: true))
    }

    /// Un `modeOptions` d'une autre forme ne fait pas perdre le fichier : il ne sert qu'à la migration, il est gardé tel quel.
    @Test func aLegacyOptionsFieldOfAnotherShapeIsKeptAndSkipsTheMigration() throws {
        let decoded = try settings(#"{"version": 1, "modeOptions": "pas un objet"}"#)
        #expect(decoded.modes == Mode.base)
        let written = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(written["modeOptions"] as? String == "pas un objet")
    }

    /// Un choix absent s'écrit sans le champ : le défaut du mode reste celui de la version qui relit le fichier.
    @Test func anAbsentChoiceIsNotWritten() throws {
        let data = try JSONEncoder().encode(ModeOptions())
        #expect(try JSONSerialization.jsonObject(with: data) as? [String: Int] == [:])
    }
}
