import Foundation
import Testing

@testable import SupervoxApp

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

/// L'arbre JSON que l'encodeur écrit pour `value`.
private func tree<T: Encodable>(_ value: T) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}

private let exampleProvider = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

/// Les réglages de l'entretien (`InterviewSettings`), le choix de voix (`VoiceChoice`, `VoiceGender`) et la durée de conservation
/// de l'historique (`HistorySettings`) : valeurs, bornes, lecture tolérante, champs inconnus gardés.
@Suite struct InterviewSettingsTests {
    // MARK: - Défauts et bornes

    @Test func theDefaultsAreTheDocumentedOnesAndLieInsideTheirRanges() {
        let defaults = InterviewSettings.defaults
        #expect(defaults.maxQuestions == 8)
        #expect(defaults.template == nil)
        #expect(defaults.turnSilence == 0.5)
        #expect(defaults.interruptMinDuration == 0.30)
        #expect(defaults.interruptLevel == -30)
        #expect(InterviewSettings.maxQuestionsRange.contains(defaults.maxQuestions))
        #expect(InterviewSettings.turnSilenceRange.contains(defaults.turnSilence))
        #expect(InterviewSettings.interruptMinDurationRange.contains(defaults.interruptMinDuration))
        #expect(InterviewSettings.interruptLevelRange.contains(defaults.interruptLevel))
        #expect(defaults.normalized == defaults)
        #expect(InterviewSettings() == defaults)
    }

    @Test func theRangesAreTheDocumentedOnes() {
        #expect(InterviewSettings.maxQuestionsRange == 1...20)
        #expect(InterviewSettings.turnSilenceRange == 0.3...2.0)
        #expect(InterviewSettings.interruptMinDurationRange == 0.1...1.0)
        #expect(InterviewSettings.interruptLevelRange == -50...(-10))
    }

    @Test func anEmptyObjectReadsAsTheDefaults() throws {
        #expect(try decode(InterviewSettings.self, "{}") == .defaults)
        #expect(try decode(HistorySettings.self, "{}") == .defaults)
        #expect(try decode(VoiceChoice.self, "{}") == .system)
    }

    // MARK: - Bornes (règle 4)

    @Test(arguments: [(-5, 1), (0, 1), (1, 1), (8, 8), (20, 20), (21, 20), (99, 20)])
    func theNumberOfQuestionsIsBroughtIntoItsRange(input: Int, expected: Int) {
        #expect(InterviewSettings(maxQuestions: input).normalized == InterviewSettings(maxQuestions: expected))
    }

    @Test(arguments: [(0.0, 0.3), (0.3, 0.3), (0.5, 0.5), (2.0, 2.0), (5.0, 2.0)])
    func theTurnSilenceIsBroughtIntoItsRange(input: Double, expected: Double) {
        #expect(InterviewSettings(turnSilence: input).normalized == InterviewSettings(turnSilence: expected))
    }

    @Test(arguments: [(0.0, 0.1), (0.1, 0.1), (0.3, 0.3), (1.0, 1.0), (3.0, 1.0)])
    func theMinimumInterruptionDurationIsBroughtIntoItsRange(input: Double, expected: Double) {
        #expect(
            InterviewSettings(interruptMinDuration: input).normalized
                == InterviewSettings(interruptMinDuration: expected))
    }

    @Test(arguments: [(-80.0, -50.0), (-50.0, -50.0), (-30.0, -30.0), (-10.0, -10.0), (0.0, -10.0)])
    func theInterruptionLevelIsBroughtIntoItsRange(input: Double, expected: Double) {
        #expect(InterviewSettings(interruptLevel: input).normalized == InterviewSettings(interruptLevel: expected))
    }

    /// Un nombre qui n'en est pas un (NaN) ne se compare à aucune borne : il prend le défaut du champ. L'infini, lui, va à la
    /// borne de son côté.
    @Test func aValueThatIsNotANumberTakesTheDefaultOfItsFieldAndInfinityGoesToTheBound() {
        let defaults = InterviewSettings.defaults
        let broken = InterviewSettings(
            turnSilence: .nan, interruptMinDuration: .nan, interruptLevel: .nan
        ).normalized
        #expect(broken.turnSilence == defaults.turnSilence)
        #expect(broken.interruptMinDuration == defaults.interruptMinDuration)
        #expect(broken.interruptLevel == defaults.interruptLevel)
        let infinite = InterviewSettings(turnSilence: .infinity, interruptLevel: -.infinity).normalized
        #expect(infinite.turnSilence == InterviewSettings.turnSilenceRange.upperBound)
        #expect(infinite.interruptLevel == InterviewSettings.interruptLevelRange.lowerBound)
    }

    @Test func normalizingTwiceChangesNothing() {
        let wild = InterviewSettings(
            maxQuestions: 99, template: " \n", turnSilence: 0, interruptMinDuration: 9, interruptLevel: -80)
        #expect(wild.normalized.normalized == wild.normalized)
        #expect(wild.normalized != wild)
    }

    /// Un fichier dont chaque valeur sort de sa borne : c'est `normalized` qui les ramène (les consommateurs l'appellent).
    @Test func aFileWithOutOfRangeValuesIsBroughtBackByNormalized() throws {
        let low = try decode(
            InterviewSettings.self,
            #"{"maxQuestions": 0, "turnSilence": 0, "interruptMinDuration": 0, "interruptLevel": -80}"#
        ).normalized
        #expect(low.maxQuestions == 1)
        #expect(low.turnSilence == 0.3)
        #expect(low.interruptMinDuration == 0.1)
        #expect(low.interruptLevel == -50)
        let high = try decode(
            InterviewSettings.self,
            #"{"maxQuestions": 99, "turnSilence": 9, "interruptMinDuration": 9, "interruptLevel": 5}"#
        ).normalized
        #expect(high.maxQuestions == 20)
        #expect(high.turnSilence == 2.0)
        #expect(high.interruptMinDuration == 1.0)
        #expect(high.interruptLevel == -10)
    }

    @Test(arguments: ["\n  ", "", "   ", "\t\n \n"])
    func aBlankTemplateBecomesNil(blank: String) {
        #expect(InterviewSettings(template: blank).normalized.template == nil)
    }

    /// Un gabarit qui dit quelque chose reste tel quel, marges comprises : `normalized` ne le réécrit pas.
    @Test func aTemplateThatSaysSomethingIsKeptVerbatim() {
        let template = "  Pose des questions.\n\nUne à la fois.  \n"
        #expect(InterviewSettings(template: template).normalized.template == template)
    }

    // MARK: - Lecture tolérante

    @Test func aNonNumericValueTakesTheDefaultOfItsFieldAndTheOtherFieldsAreRead() throws {
        let read = try decode(
            InterviewSettings.self,
            #"""
            {"maxQuestions": "beaucoup", "turnSilence": 1.25, "interruptMinDuration": true,
             "interruptLevel": -20, "template": "Un gabarit d'exemple."}
            """#)
        #expect(read.maxQuestions == InterviewSettings.defaults.maxQuestions)
        #expect(read.turnSilence == 1.25)
        #expect(read.interruptMinDuration == InterviewSettings.defaults.interruptMinDuration)
        #expect(read.interruptLevel == -20)
        #expect(read.template == "Un gabarit d'exemple.")
    }

    @Test func eachFieldFallsBackAloneWhenItsValueIsOfAnotherForm() throws {
        let defaults = InterviewSettings.defaults
        let good = #"{"maxQuestions": 3, "turnSilence": 1.5, "interruptMinDuration": 0.4, "interruptLevel": -20, "template": "T"}"#
        let base = try decode(InterviewSettings.self, good)
        #expect(base.maxQuestions == 3 && base.turnSilence == 1.5 && base.interruptMinDuration == 0.4)
        #expect(base.interruptLevel == -20 && base.template == "T")
        // Chaque champ cassé à son tour : lui seul retombe, les quatre autres gardent leur valeur lue.
        let broken = try decode(
            InterviewSettings.self,
            #"{"maxQuestions": [1], "turnSilence": "x", "interruptMinDuration": {}, "interruptLevel": null, "template": 12}"#)
        #expect(broken == defaults)
        for (key, check) in [
            ("maxQuestions", { (s: InterviewSettings) in s.maxQuestions == defaults.maxQuestions && s.turnSilence == 1.5 }),
            ("turnSilence", { (s: InterviewSettings) in s.turnSilence == defaults.turnSilence && s.maxQuestions == 3 }),
            (
                "interruptMinDuration",
                { (s: InterviewSettings) in s.interruptMinDuration == defaults.interruptMinDuration && s.interruptLevel == -20 }
            ),
            (
                "interruptLevel",
                { (s: InterviewSettings) in s.interruptLevel == defaults.interruptLevel && s.interruptMinDuration == 0.4 }
            ),
            ("template", { (s: InterviewSettings) in s.template == nil && s.maxQuestions == 3 }),
        ] {
            var object = try #require(
                try JSONSerialization.jsonObject(with: Data(good.utf8)) as? [String: Any])
            object[key] = ["un tableau, qui n'est ni un nombre ni un texte"]
            let read = try JSONDecoder().decode(InterviewSettings.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(check(read), "\(key) cassé : \(read)")
        }
    }

    @Test func aTemplateIsWrittenOnlyWhenThereIsOne() throws {
        #expect(try tree(InterviewSettings.defaults)["template"] == nil)
        #expect(try tree(InterviewSettings(template: "Un gabarit."))["template"] as? String == "Un gabarit.")
    }

    // MARK: - Champs inconnus gardés

    /// Les trois types gardent ce qu'ils ne connaissent pas, de toute forme, et le réécrivent avec la valeur courante des champs
    /// connus (un champ connu modifié se réécrit modifié, jamais doublé par un reste).
    @Test func unknownFieldsOfTheInterviewSettingsAreKeptAndTheKnownOnesStayCurrent() throws {
        var read = try decode(
            InterviewSettings.self,
            #"{"maxQuestions": 4, "futur-objet": {"a": [1, {"b": null}]}, "futur-tableau": [1, "deux"], "futur-nombre": 2.5, "futur-nul": null}"#)
        read.maxQuestions = 6
        let written = try tree(read)
        #expect(written["maxQuestions"] as? Int == 6)
        #expect((written["futur-objet"] as? NSDictionary)?.isEqual(to: ["a": [1, ["b": NSNull()]]]) == true)
        #expect((written["futur-tableau"] as? NSArray)?.isEqual(to: [1, "deux"]) == true)
        #expect(written["futur-nombre"] as? Double == 2.5)
        #expect(written["futur-nul"] is NSNull)
    }

    @Test func unknownFieldsOfTheVoiceChoiceAreKept() throws {
        var read = try decode(
            VoiceChoice.self,
            #"{"model": "modele-exemple-voix", "futur-objet": {"a": 1}, "futur-texte": "t", "futur-faux": false}"#)
        read.model = "autre-modele"
        let written = try tree(read)
        #expect(written["model"] as? String == "autre-modele")
        #expect((written["futur-objet"] as? NSDictionary)?.isEqual(to: ["a": 1]) == true)
        #expect(written["futur-texte"] as? String == "t")
        #expect(written["futur-faux"] as? Bool == false)
    }

    @Test func unknownFieldsOfTheHistorySettingsAreKept() throws {
        var read = try decode(HistorySettings.self, #"{"retentionDays": 7, "futur": [1, 2], "futur-objet": {"x": "y"}}"#)
        read.retentionDays = 90
        let written = try tree(read)
        #expect(written["retentionDays"] as? Int == 90)
        #expect((written["futur"] as? NSArray)?.isEqual(to: [1, 2]) == true)
        #expect((written["futur-objet"] as? NSDictionary)?.isEqual(to: ["x": "y"]) == true)
    }

    /// `normalized` repart de la valeur : il ne reconstruit pas un `InterviewSettings` neuf, qui perdrait ces champs. La valeur
    /// hors borne est posée après la lecture (la lecture, elle, borne déjà : voir `outOfRangeValuesAreBoundedAtReading`).
    @Test func normalizingKeepsTheUnknownFields() throws {
        var read = try decode(InterviewSettings.self, #"{"maxQuestions": 5, "futur": {"a": 1}}"#)
        read.maxQuestions = 99
        let written = try tree(read.normalized)
        #expect(written["maxQuestions"] as? Int == 20)
        #expect((written["futur"] as? NSDictionary)?.isEqual(to: ["a": 1]) == true)
    }

    // MARK: - Bornes à la lecture

    /// Une valeur hors borne est ramenée dans sa borne dès le décodage, sans que personne appelle `normalized` : aucun
    /// consommateur ne peut oublier la borne (`maxQuestions` à 0 conclurait l'entretien sans question).
    @Test func outOfRangeValuesAreBoundedAtReading() throws {
        let low = try decode(
            InterviewSettings.self,
            #"{"maxQuestions": 0, "turnSilence": 0, "interruptMinDuration": 0, "interruptLevel": -80}"#)
        #expect(low.maxQuestions == 1)
        #expect(low.turnSilence == 0.3)
        #expect(low.interruptMinDuration == 0.1)
        #expect(low.interruptLevel == -50)
        let high = try decode(
            InterviewSettings.self,
            #"{"maxQuestions": 99, "turnSilence": 9, "interruptMinDuration": 9, "interruptLevel": 5}"#)
        #expect(high.maxQuestions == 20)
        #expect(high.turnSilence == 2.0)
        #expect(high.interruptMinDuration == 1.0)
        #expect(high.interruptLevel == -10)
        #expect(try decode(InterviewSettings.self, #"{"template": "\n  "}"#).template == nil)
    }

    @Test func boundingAtReadingKeepsTheUnknownFieldsAndTheValuesInRange() throws {
        let read = try decode(
            InterviewSettings.self, #"{"maxQuestions": 99, "turnSilence": 1.25, "template": " T ", "futur": {"a": 1}}"#)
        let written = try tree(read)
        #expect(written["maxQuestions"] as? Int == 20)
        #expect(written["turnSilence"] as? Double == 1.25)
        #expect(written["template"] as? String == " T ")
        #expect((written["futur"] as? NSDictionary)?.isEqual(to: ["a": 1]) == true)
    }

    @Test(arguments: [
        (-5, 30), (-1, 30), (Int.min, 30), (0, 0), (7, 7), (30, 30), (365, 365), (3650, 3650), (3651, 3650), (Int.max, 3650),
    ])
    func theRetentionIsBoundedAtReading(file: Int, expected: Int) throws {
        #expect(try decode(HistorySettings.self, #"{"retentionDays": \#(file)}"#).retentionDays == expected)
        // `normalized` pose la même règle sur une valeur choisie par l'interface.
        #expect(HistorySettings(retentionDays: file).normalized.retentionDays == expected)
    }

    @Test func theMaximumRetentionIsTenYearsAndNormalizingKeepsTheUnknownFields() throws {
        #expect(HistorySettings.maxRetentionDays == 3650)
        var read = try decode(HistorySettings.self, #"{"retentionDays": 7, "futur": [1]}"#)
        read.retentionDays = -1
        let written = try tree(read.normalized)
        #expect(written["retentionDays"] as? Int == 30)
        #expect((written["futur"] as? NSArray)?.isEqual(to: [1]) == true)
    }

    // MARK: - L'égalité ignore les champs inconnus

    @Test func theEqualityOfInterviewSettingsIgnoresUnknownFieldsButNotKnownOnes() throws {
        let one = try decode(InterviewSettings.self, #"{"maxQuestions": 5, "a": 1}"#)
        let other = try decode(InterviewSettings.self, #"{"maxQuestions": 5, "b": [2]}"#)
        #expect(one == other)
        let base = InterviewSettings(
            maxQuestions: 5, template: "T", turnSilence: 0.8, interruptMinDuration: 0.2, interruptLevel: -25)
        var changed = [base, base, base, base, base]
        changed[0].maxQuestions = 6
        changed[1].template = nil
        changed[2].turnSilence = 0.9
        changed[3].interruptMinDuration = 0.25
        changed[4].interruptLevel = -26
        for (index, variant) in changed.enumerated() { #expect(variant != base, "champ \(index)") }
    }

    @Test func theEqualityOfHistorySettingsIgnoresUnknownFieldsButNotTheRetention() throws {
        #expect(try decode(HistorySettings.self, #"{"a": 1}"#) == decode(HistorySettings.self, #"{"b": 2}"#))
        #expect(HistorySettings(retentionDays: 7) != HistorySettings(retentionDays: 30))
    }

    // MARK: - Historique

    @Test func theHistoryKeepsThirtyDaysByDefaultAndOffersTheDocumentedChoices() {
        #expect(HistorySettings.defaults.retentionDays == 30)
        #expect(HistorySettings.choices == [0, 7, 30, 90, 365])
        #expect(HistorySettings.choices.contains(HistorySettings.defaults.retentionDays))
    }

    /// Zéro est un choix (ne rien garder) : il ne se confond pas avec un champ absent.
    @Test func zeroDaysIsAChoiceAndAFieldOfAnotherFormTakesTheDefault() throws {
        #expect(try decode(HistorySettings.self, #"{"retentionDays": 0}"#).retentionDays == 0)
        #expect(try decode(HistorySettings.self, #"{"retentionDays": 365}"#).retentionDays == 365)
        #expect(try decode(HistorySettings.self, #"{"retentionDays": "longtemps"}"#).retentionDays == 30)
        #expect(try decode(HistorySettings.self, #"{"retentionDays": null}"#).retentionDays == 30)
        #expect(try tree(HistorySettings(retentionDays: 0))["retentionDays"] as? Int == 0)
    }

    // MARK: - Voix

    @Test func theSystemVoiceHasNoProviderAndNoIdentifier() {
        let system = VoiceChoice.system
        #expect(system == VoiceChoice())
        #expect(system.providerID == nil)
        #expect(system.model == nil)
        #expect(system.identifier == nil)
        #expect(system.language == "fr-FR")
        #expect(system.gender == nil)
        #expect(system.extra == [:])
        #expect(!system.usesProvider)
    }

    @Test func aVoiceUsesAProviderExactlyWhenItNamesOne() {
        #expect(VoiceChoice(providerID: exampleProvider).usesProvider)
        // Un modèle ou un identifiant sans fournisseur : c'est toujours une voix du système.
        #expect(!VoiceChoice(model: "modele-exemple-voix", identifier: "voix-exemple").usesProvider)
    }

    @Test func aVoiceChoiceIsWrittenAndReadBackWithEveryField() throws {
        let voice = VoiceChoice(
            providerID: exampleProvider, model: "modele-exemple-voix", identifier: "voix-exemple", language: "en-US",
            gender: .female, extra: ["parametre-exemple": "valeur-exemple"])
        let written = try tree(voice)
        #expect(written["providerID"] as? String == exampleProvider.uuidString)
        #expect(written["model"] as? String == "modele-exemple-voix")
        #expect(written["identifier"] as? String == "voix-exemple")
        #expect(written["language"] as? String == "en-US")
        #expect(written["gender"] as? String == "female")
        #expect((written["extra"] as? NSDictionary)?.isEqual(to: ["parametre-exemple": "valeur-exemple"]) == true)
        #expect(try JSONDecoder().decode(VoiceChoice.self, from: JSONEncoder().encode(voice)) == voice)
    }

    @Test func anAbsentVoiceFieldIsNotWrittenAsNull() throws {
        let written = try tree(VoiceChoice.system)
        #expect(Set(written.keys) == ["language", "extra"])
    }

    @Test func aVoiceFileWithoutALanguageReadsFrench() throws {
        #expect(try decode(VoiceChoice.self, #"{"identifier": "voix-exemple"}"#).language == "fr-FR")
        #expect(try decode(VoiceChoice.self, #"{"language": "en-GB"}"#).language == "en-GB")
    }

    /// Un champ d'une autre forme retombe seul sur son défaut ; un fournisseur illisible rend la voix du système (jamais un
    /// fournisseur au hasard).
    @Test func aVoiceFieldOfAnotherFormFallsBackAlone() throws {
        let read = try decode(
            VoiceChoice.self,
            #"""
            {"providerID": "pas-un-identifiant", "model": 3, "identifier": "voix-exemple", "language": ["fr"], "gender": 7,
             "extra": {"garde": "oui", "refuse": 1}}
            """#)
        #expect(read.providerID == nil)
        #expect(!read.usesProvider)
        #expect(read.model == nil)
        #expect(read.identifier == "voix-exemple")
        #expect(read.language == "fr-FR")
        #expect(read.gender == nil)
        #expect(read.extra == ["garde": "oui"])
    }

    // MARK: - Énumérations tolérantes (règle 5)

    @Test func anUnknownGenderIsKeptAsItIsAndWrittenBackIdentically() throws {
        let read = try decode(VoiceChoice.self, #"{"gender": "autre-valeur"}"#)
        #expect(read.gender == .other("autre-valeur"))
        #expect(try tree(read)["gender"] as? String == "autre-valeur")
        // Réécrit puis relu : même valeur, même texte.
        let again = try JSONDecoder().decode(VoiceChoice.self, from: JSONEncoder().encode(read))
        #expect(again.gender == .other("autre-valeur"))
        #expect(try tree(again)["gender"] as? String == "autre-valeur")
    }

    @Test(arguments: [("female", VoiceGender.female), ("male", .male), ("neutral", .neutral)])
    func aKnownGenderIsReadAndWrittenUnderItsName(name: String, gender: VoiceGender) throws {
        let read = try decode(VoiceChoice.self, #"{"gender": "\#(name)"}"#)
        #expect(read.gender == gender)
        #expect(try tree(read)["gender"] as? String == name)
    }

    @Test func twoUnknownGendersAreEqualOnlyWhenTheirTextIs() {
        #expect(VoiceGender.other("a") == .other("a"))
        #expect(VoiceGender.other("a") != .other("b"))
        #expect(VoiceGender.other("a") != .female)
    }

    @Test func theEqualityOfVoiceChoicesIgnoresUnknownFieldsButNotKnownOnes() throws {
        let one = try decode(VoiceChoice.self, #"{"identifier": "voix-exemple", "a": 1}"#)
        let other = try decode(VoiceChoice.self, #"{"identifier": "voix-exemple", "b": [2]}"#)
        #expect(one == other)
        let base = VoiceChoice(
            providerID: exampleProvider, model: "m", identifier: "i", language: "fr-FR", gender: .male, extra: ["k": "v"])
        var changed = [VoiceChoice](repeating: base, count: 6)
        changed[0].providerID = nil
        changed[1].model = "autre"
        changed[2].identifier = nil
        changed[3].language = "en-US"
        changed[4].gender = .female
        changed[5].extra = [:]
        for (index, variant) in changed.enumerated() { #expect(variant != base, "champ \(index)") }
    }

    // MARK: - Moteur de l'entretien

    /// Le moteur de l'entretien est Parakeet (design 6.4), et ce n'est pas celui de la dictée par défaut : les deux sont
    /// deux décisions distinctes.
    @Test func theInterviewEngineIsParakeetAndNotTheDictationDefault() {
        #expect(TranscriptionEngine.interviewDefault == .parakeet)
        #expect(TranscriptionEngine.interviewDefault != TranscriptionSettings.defaults.engine)
    }
}
