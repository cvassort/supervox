import Foundation
import Testing

@testable import SupervoxApp

/// Le réglage « relire avant de coller », par mode : défauts, choix enregistrés, Entretien toujours relu, identifiants
/// inconnus gardés. Aucun disque : le format du fichier est dans `SettingsStoreTests`.
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
        #expect(defaults.modeOptions.isEmpty)
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
        #expect(decoded.modeOptions.count == 3)
        #expect(decoded.modeOptions[ModeChip.promptID] == ModeOptions())
        #expect(decoded.reviewsBeforePaste(ModeChip.promptID))
        #expect(!decoded.reviewsBeforePaste(ModeChip.rawID))
        #expect(!decoded.reviewsBeforePaste(ModeChip.cleanedID))
    }

    @Test func aSavedChoiceOverridesTheDefaultInBothDirections() throws {
        let decoded = try settings(
            #"{"version": 1, "modeOptions": {"prompt": {"reviewBeforePaste": false}, "dictee-brute": {"reviewBeforePaste": true}}}"#)
        #expect(!decoded.reviewsBeforePaste(ModeChip.promptID))
        #expect(decoded.reviewsBeforePaste(ModeChip.rawID))
    }

    /// Entretien passe toujours par la relecture : un fichier qui dit le contraire n'y change rien à la lecture, et sa valeur
    /// reste telle quelle à l'aller-retour (elle n'est pas réécrite en vrai).
    @Test func theInterviewIsAlwaysReviewedWhateverTheFileSays() throws {
        let decoded = try settings(#"{"version": 1, "modeOptions": {"entretien": {"reviewBeforePaste": false}}}"#)
        #expect(decoded.modeOptions[ModeChip.interviewID]?.reviewBeforePaste == false)
        #expect(decoded.reviewsBeforePaste(ModeChip.interviewID))
        #expect(AppSettings.alwaysReviewed == [ModeChip.interviewID])

        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(decoded))
        #expect(again.modeOptions[ModeChip.interviewID]?.reviewBeforePaste == false)
        #expect(again.reviewsBeforePaste(ModeChip.interviewID))
    }

    /// Un mode que cette version ne connaît pas (mode personnalisé d'une étape suivante) garde son choix à l'aller-retour, et
    /// ce choix s'applique.
    @Test func anUnknownModeIdentifierIsKeptAndHonoured() throws {
        let decoded = try settings(
            #"{"version": 1, "modeOptions": {"mode-perso": {"reviewBeforePaste": true}, "autre": {}}}"#)
        let again = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(decoded))
        #expect(again.modeOptions == decoded.modeOptions)
        #expect(again.modeOptions["mode-perso"] == ModeOptions(reviewBeforePaste: true))
        #expect(again.modeOptions["autre"] == ModeOptions())
        #expect(again.reviewsBeforePaste("mode-perso"))
        #expect(!again.reviewsBeforePaste("autre"))
    }

    /// Le décodage d'un objet d'options ignore ce qu'il ne connaît pas (l'étape 5 y ajoute des champs) et se contente de `{}`.
    @Test func optionsDecodeLeniently() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ModeOptions.self, from: Data("{}".utf8)) == ModeOptions())
        #expect(
            try decoder.decode(ModeOptions.self, from: Data(#"{"reviewBeforePaste": true, "autre": [1, 2]}"#.utf8))
                == ModeOptions(reviewBeforePaste: true))
    }

    /// Un choix absent s'écrit sans le champ : le défaut du mode reste celui de la version qui relit le fichier.
    @Test func anAbsentChoiceIsNotWritten() throws {
        let data = try JSONEncoder().encode(ModeOptions())
        #expect(try JSONSerialization.jsonObject(with: data) as? [String: Int] == [:])
    }

    /// Les réglages par défaut ne portent aucun choix : un nouveau fichier ne fige pas les défauts d'aujourd'hui.
    @Test func newSettingsCarryNoSavedChoice() throws {
        var changed = AppSettings.defaults
        changed.modeOptions[ModeChip.rawID] = ModeOptions(reviewBeforePaste: true)
        #expect(changed != .defaults)
        #expect(changed.reviewsBeforePaste(ModeChip.rawID))
        #expect(AppSettings.current == 1)
    }
}
