import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

/// L'onglet Entretien : nombre de questions, gabarit du prompt final, réglages avancés de l'interruption. `read` et `update` sont
/// doublés par des réglages en mémoire, dont l'enregistrement peut lever sur ordre ; aucun disque, aucun réseau, aucun matériel.
/// Les bornes et les défauts sont lus dans `InterviewSettings`, jamais recopiés ici en dur.
@MainActor @Suite(.timeLimit(.minutes(1))) struct InterviewSettingsModelTests {
    /// Une erreur d'ailleurs, dont le texte porte une adresse : il ne doit jamais arriver à l'écran.
    struct ForeignError: LocalizedError {
        var errorDescription: String? { "échec de la requête vers https://api.example.com/v1/cle" }
    }

    static let provider = Provider(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!, name: "Fournisseur d'exemple",
        baseURL: "https://example.com/v1", kind: .openAICompatible, models: ["modele-exemple-rapide"])
    static let voiceProvider = Provider(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!, name: "Fournisseur de voix d'exemple",
        baseURL: "https://example.com/voix", kind: .openAICompatible, models: [])

    /// Les réglages en mémoire et le double de `update`, qui applique le changement aux réglages **en vigueur** (comme
    /// `AppController.updateSettings`) ou lève sur ordre.
    @MainActor final class Rig {
        var settings: AppSettings
        var updates = 0
        var reads = 0
        var failure: (any Error)?
        /// Ce qui s'écrit « ailleurs » juste avant que l'enregistrement refusé ne lève.
        var writtenElsewhereBeforeFailing: ((inout AppSettings) -> Void)?
        /// Les arguments reçus par la fonction du silence en pratique.
        var silenceRequests: [Double] = []

        init(_ settings: AppSettings = .defaults) { self.settings = settings }

        func makeModel(effective: (@Sendable (Double) -> Double)? = nil) -> InterviewSettingsModel {
            InterviewSettingsModel(
                read: {
                    self.reads += 1
                    return self.settings
                },
                update: { change in
                    self.updates += 1
                    if let failure = self.failure {
                        self.writtenElsewhereBeforeFailing?(&self.settings)
                        throw failure
                    }
                    change(&self.settings)
                },
                effectiveTurnSilence: effective ?? { $0 })
        }
    }

    // MARK: - Ce que l'onglet montre au départ

    /// Les réglages par défaut : les valeurs et les bornes sont celles du type.
    @Test func theTabShowsTheTypesDefaultsAndBounds() {
        let model = Rig().makeModel()
        let defaults = InterviewSettings.defaults
        #expect(model.maxQuestions == defaults.maxQuestions)
        #expect(model.turnSilence == defaults.turnSilence)
        #expect(model.interruptMinDuration == defaults.interruptMinDuration)
        #expect(model.interruptLevel == defaults.interruptLevel)
        #expect(model.template == InterviewPrompt.defaultTemplate)
        #expect(model.isDefaultTemplate)
        #expect(model.maxQuestionsRange == InterviewSettings.maxQuestionsRange)
        #expect(model.turnSilenceRange == InterviewSettings.turnSilenceRange)
        #expect(model.interruptMinDurationRange == InterviewSettings.interruptMinDurationRange)
        #expect(model.interruptLevelRange == InterviewSettings.interruptLevelRange)
    }

    /// Les pas de l'interface (brief : 1 question, 0,1 s, 0,05 s, 1 dB) tiennent dans les bornes du type : un pas plus grand que la
    /// plage n'aurait aucun sens.
    @Test func theStepsFitInsideTheBounds() {
        let model = Rig().makeModel()
        #expect(model.turnSilenceStep == 0.1)
        #expect(model.interruptMinDurationStep == 0.05)
        #expect(model.interruptLevelStep == 1)
        #expect(model.turnSilenceStep <= model.turnSilenceRange.upperBound - model.turnSilenceRange.lowerBound)
        #expect(
            model.interruptMinDurationStep
                <= model.interruptMinDurationRange.upperBound - model.interruptMinDurationRange.lowerBound)
        #expect(model.interruptLevelStep <= model.interruptLevelRange.upperBound - model.interruptLevelRange.lowerBound)
    }

    /// Une valeur hors bornes lue dans les réglages (un champ `.other`, un fichier édité) est montrée normalisée.
    @Test func anOutOfBoundsStoredValueIsShownNormalized() {
        var settings = AppSettings.defaults
        settings.interview.maxQuestions = 500
        settings.interview.turnSilence = 40
        settings.interview.interruptMinDuration = -3
        settings.interview.interruptLevel = 12
        let model = Rig(settings).makeModel()
        #expect(model.maxQuestions == InterviewSettings.maxQuestionsRange.upperBound)
        #expect(model.turnSilence == InterviewSettings.turnSilenceRange.upperBound)
        #expect(model.interruptMinDuration == InterviewSettings.interruptMinDurationRange.lowerBound)
        #expect(model.interruptLevel == InterviewSettings.interruptLevelRange.upperBound)
    }

    // MARK: - Règle 1 : enregistrement

    /// Chaque champ s'enregistre par `update`, une seule fois, dans les réglages en vigueur.
    @Test func eachFieldIsSavedThroughUpdate() {
        let rig = Rig()
        let model = rig.makeModel()
        model.maxQuestions = 5
        #expect(rig.settings.interview.maxQuestions == 5)
        model.turnSilence = 0.9
        #expect(rig.settings.interview.turnSilence == 0.9)
        model.interruptMinDuration = 0.45
        #expect(rig.settings.interview.interruptMinDuration == 0.45)
        model.interruptLevel = -25
        #expect(rig.settings.interview.interruptLevel == -25)
        model.template = "Un gabarit à moi."
        #expect(rig.settings.interview.template == "Un gabarit à moi.")
        #expect(rig.updates == 5, "un seul `update` par geste")
        #expect(model.maxQuestions == 5 && model.turnSilence == 0.9 && model.interruptLevel == -25)
    }

    /// Une écriture passe par `normalized` : chaque valeur est ramenée dans sa borne, et un nombre qui n'en est pas un prend le
    /// défaut du champ.
    @Test func writtenValuesAreClampedToTheTypesBounds() {
        let rig = Rig()
        let model = rig.makeModel()
        model.maxQuestions = 99
        #expect(rig.settings.interview.maxQuestions == InterviewSettings.maxQuestionsRange.upperBound)
        model.maxQuestions = -4
        #expect(rig.settings.interview.maxQuestions == InterviewSettings.maxQuestionsRange.lowerBound)
        model.turnSilence = 9
        #expect(rig.settings.interview.turnSilence == InterviewSettings.turnSilenceRange.upperBound)
        model.turnSilence = 0.01
        #expect(rig.settings.interview.turnSilence == InterviewSettings.turnSilenceRange.lowerBound)
        model.interruptMinDuration = 7
        #expect(rig.settings.interview.interruptMinDuration == InterviewSettings.interruptMinDurationRange.upperBound)
        model.interruptMinDuration = 0
        #expect(rig.settings.interview.interruptMinDuration == InterviewSettings.interruptMinDurationRange.lowerBound)
        model.interruptLevel = 5
        #expect(rig.settings.interview.interruptLevel == InterviewSettings.interruptLevelRange.upperBound)
        model.interruptLevel = -300
        #expect(rig.settings.interview.interruptLevel == InterviewSettings.interruptLevelRange.lowerBound)
        model.turnSilence = .nan
        #expect(rig.settings.interview.turnSilence == InterviewSettings.defaults.turnSilence)
    }

    /// Le pas d'un contrôle s'additionne mal (0,7 + 0,1 = 0,7999999999999999) : la valeur écrite est arrondie au centième, et c'est
    /// elle qui reste dans le fichier.
    @Test func aSteppedValueIsWrittenWithoutFloatingPointDrift() {
        let rig = Rig()
        let model = rig.makeModel()
        model.turnSilence = 0.7 + 0.1
        #expect(rig.settings.interview.turnSilence == 0.8)
        model.interruptMinDuration = 0.1 + 0.05 + 0.05
        #expect(rig.settings.interview.interruptMinDuration == 0.2)
    }

    /// Un autre champ changé ailleurs entre-temps (dans l'entretien comme dans les réglages) n'est pas écrasé : le geste ne touche
    /// que son champ, sur les réglages en vigueur, jamais sur une copie périmée. Le modèle n'a pas relu depuis.
    @Test func aGestureDoesNotOverwriteWhatAnotherPathWroteMeanwhile() {
        let rig = Rig()
        let model = rig.makeModel()
        rig.settings.interview.turnSilence = 1.2
        rig.settings.interview.template = "Écrit ailleurs."
        rig.settings.providers = [Self.provider]
        rig.settings.hotKeyBehavior = .hold

        model.maxQuestions = 5
        #expect(rig.settings.interview.maxQuestions == 5)
        #expect(rig.settings.interview.turnSilence == 1.2, "le silence écrit ailleurs reste")
        #expect(rig.settings.interview.template == "Écrit ailleurs.", "le gabarit écrit ailleurs reste")
        #expect(rig.settings.providers == [Self.provider], "les fournisseurs écrits ailleurs restent")
        #expect(rig.settings.hotKeyBehavior == .hold)

        model.template = "Mon gabarit."
        #expect(rig.settings.interview.maxQuestions == 5 && rig.settings.interview.turnSilence == 1.2)
    }

    /// Un champ que cette version ne connaît pas dans `interview` est gardé par le geste (le geste ne remplace pas la structure).
    @Test func anUnknownInterviewFieldSurvivesAGesture() throws {
        let json = #"{"maxQuestions": 8, "avenir": {"cle": 1}}"#
        let decoded = try JSONDecoder().decode(InterviewSettings.self, from: Data(json.utf8))
        let rig = Rig()
        rig.settings.interview = decoded
        let model = rig.makeModel()
        model.maxQuestions = 3
        let written = try JSONEncoder().encode(rig.settings.interview)
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        #expect(object["maxQuestions"] as? Int == 3)
        #expect(object["avenir"] != nil, "le champ inconnu est réécrit tel quel")
    }

    /// `update` qui lève : la phrase fixe (jamais le texte de l'erreur, qui porte une adresse), l'écran relu sur ce que `read` donne
    /// — y compris ce qui s'est écrit ailleurs entre-temps — et aucun brouillon de gabarit gardé.
    @Test func aRefusedSaveSaysTheFixedSentenceAndRereadsTheScreen() {
        let rig = Rig()
        let model = rig.makeModel()
        rig.failure = ForeignError()
        rig.writtenElsewhereBeforeFailing = { $0.interview.interruptLevel = -20 }

        model.maxQuestions = 5
        #expect(model.message == InterviewSettingsModel.saveFailure)
        #expect(model.message?.contains("example.com") == false)
        #expect(model.maxQuestions == InterviewSettings.defaults.maxQuestions, "le chiffre refusé n'est pas montré")
        #expect(model.interruptLevel == -20, "l'écran est relu : ce qui s'est écrit ailleurs s'y voit")

        model.template = "Refusé."
        #expect(model.template == InterviewPrompt.defaultTemplate, "le brouillon d'un gabarit refusé n'est pas gardé")
        #expect(model.isDefaultTemplate)
    }

    /// Un refus que le fichier de réglages explique (illisible, d'une version plus récente) garde sa phrase fixe, qui nomme le
    /// fichier : comme l'onglet Modes. Le geste suivant qui réussit efface le message.
    @Test func aSettingsFileRefusalKeepsItsOwnFixedSentenceAndASuccessClearsIt() {
        let rig = Rig()
        let model = rig.makeModel()
        let refusal = SettingsError.unreadableFileKept(fileName: "settings.json")
        rig.failure = refusal
        model.turnSilence = 1
        #expect(model.message == refusal.errorDescription)
        rig.failure = nil
        model.turnSilence = 1
        #expect(model.message == nil)
        #expect(rig.settings.interview.turnSilence == 1)
    }

    /// `reload` relit : une écriture faite ailleurs s'y voit ; avant, l'écran garde ce qu'il avait.
    @Test func reloadShowsWhatWasWrittenElsewhere() {
        let rig = Rig()
        let model = rig.makeModel()
        rig.settings.interview.maxQuestions = 12
        #expect(model.maxQuestions == InterviewSettings.defaults.maxQuestions, "pas encore relu")
        model.reload()
        #expect(model.maxQuestions == 12)
    }

    // MARK: - Règle 2 : gabarit

    /// Un gabarit égal mot pour mot au gabarit d'origine, ou vide, est enregistré `nil` ; un autre est enregistré tel quel.
    @Test func theOriginalOrBlankTemplateIsSavedAsNil() {
        let rig = Rig()
        let model = rig.makeModel()
        model.template = "Mon gabarit."
        #expect(rig.settings.interview.template == "Mon gabarit.")
        model.template = InterviewPrompt.defaultTemplate
        #expect(rig.settings.interview.template == nil, "le gabarit d'origine ne s'enregistre pas en clair")
        model.template = "Mon gabarit."
        model.template = ""
        #expect(rig.settings.interview.template == nil)
        model.template = "Mon gabarit."
        model.template = "  \n\t "
        #expect(rig.settings.interview.template == nil)
        // Le gabarit d'origine à une espace près n'est plus le gabarit d'origine : mot pour mot.
        model.template = InterviewPrompt.defaultTemplate + " Et une phrase de plus."
        #expect(rig.settings.interview.template == InterviewPrompt.defaultTemplate + " Et une phrase de plus.")
    }

    /// « Revenir au gabarit d'origine » enregistre `nil`, montre le gabarit d'origine, et grise le bouton (`isDefaultTemplate`).
    @Test func restoringTheTemplateSavesNilAndDisablesTheButton() {
        let rig = Rig()
        let model = rig.makeModel()
        model.template = "Mon gabarit."
        #expect(!model.isDefaultTemplate, "personnalisé : le bouton est actif")
        model.restoreTemplate()
        #expect(rig.settings.interview.template == nil)
        #expect(model.template == InterviewPrompt.defaultTemplate)
        #expect(model.isDefaultTemplate, "le bouton est grisé")
    }

    /// Le champ vidé reste vide pendant la frappe (le texte d'origine ne revient pas sous les doigts), alors que le réglage enregistré
    /// est `nil` ; le bouton « Revenir… » est alors actif, et `reload` ramène le gabarit d'origine.
    @Test func aClearedFieldStaysEmptyWhileTypingEvenThoughNilIsSaved() {
        let rig = Rig()
        let model = rig.makeModel()
        model.template = "Mon gabarit."
        model.template = ""
        #expect(rig.settings.interview.template == nil)
        #expect(model.template == "")
        #expect(!model.isDefaultTemplate, "le champ est vide : on peut revenir au gabarit d'origine")
        model.template = "Un"
        #expect(model.template == "Un")
        model.reload()
        #expect(model.template == "Un", "relu : le gabarit enregistré")
        model.template = ""
        model.reload()
        #expect(model.template == InterviewPrompt.defaultTemplate, "vide enregistré nil : relu, l'origine")
    }

    // MARK: - Réglages avancés

    /// « Rétablir les valeurs d'origine » remet les trois réglages avancés à ceux du type, sans toucher au nombre de questions ni au
    /// gabarit.
    @Test func restoringTheAdvancedSettingsKeepsTheRest() {
        let rig = Rig()
        let model = rig.makeModel()
        model.maxQuestions = 5
        model.template = "Mon gabarit."
        model.turnSilence = 1.5
        model.interruptMinDuration = 0.8
        model.interruptLevel = -15
        let updates = rig.updates
        model.restoreAdvanced()
        let defaults = InterviewSettings.defaults
        #expect(rig.settings.interview.turnSilence == defaults.turnSilence)
        #expect(rig.settings.interview.interruptMinDuration == defaults.interruptMinDuration)
        #expect(rig.settings.interview.interruptLevel == defaults.interruptLevel)
        #expect(rig.settings.interview.maxQuestions == 5)
        #expect(rig.settings.interview.template == "Mon gabarit.")
        #expect(rig.updates == updates + 1, "un seul enregistrement pour les trois")
    }

    /// Les valeurs montrées à côté des contrôles : deux décimales et la virgule pour les secondes, un entier pour les dB (signe moins
    /// typographique).
    @Test func theValuesNextToTheControlsAreFormattedInFrench() {
        let model = Rig().makeModel()
        #expect(model.turnSilenceLabel == "0,50 s")
        #expect(model.interruptMinDurationLabel == "0,30 s")
        #expect(model.interruptLevelLabel == "\u{2212}30 dB")
        model.turnSilence = 1.5
        model.interruptMinDuration = 0.05 + 0.1
        model.interruptLevel = -25
        #expect(model.turnSilenceLabel == "1,50 s")
        #expect(model.interruptMinDurationLabel == "0,15 s")
        #expect(model.interruptLevelLabel == "\u{2212}25 dB")
    }

    // MARK: - Règle 3 : silence effectif

    /// Avec l'identité : la valeur demandée dite deux fois, avec deux décimales et la virgule.
    @Test func theEffectiveSilenceTextWithTheIdentity() {
        let rig = Rig()
        let model = rig.makeModel()
        model.turnSilence = 0.7
        #expect(
            model.effectiveSilenceText
                == "0,70 s demandées, 0,70 s en pratique\u{00A0}: le détecteur de voix compte par tranches de 0,256 s.")
    }

    /// Avec une fonction qui répond autre chose, c'est sa réponse qui est dite (arrondie au centième), et on la questionne avec la
    /// valeur réglée normalisée.
    @Test func theEffectiveSilenceTextSaysWhatTheFunctionAnswersForTheShownValue() {
        var settings = AppSettings.defaults
        settings.interview.turnSilence = 90  // hors borne : ramené à la borne haute
        let rig = Rig(settings)
        let requests = Mutex<[Double]>([])
        let model = rig.makeModel(effective: { value in
            requests.withLock { $0.append(value) }
            return 2.304
        })
        #expect(
            model.effectiveSilenceText
                == "2,00 s demandées, 2,30 s en pratique\u{00A0}: le détecteur de voix compte par tranches de 0,256 s.")
        #expect(requests.withLock { $0 }.last == InterviewSettings.turnSilenceRange.upperBound)
        model.turnSilence = 0.6
        #expect(model.effectiveSilenceText.hasPrefix("0,60 s demandées, 2,30 s en pratique"))
        #expect(requests.withLock { $0 }.last == 0.6)
    }

    // MARK: - Règle 4 : vie privée

    static let systemPrivacy =
        "Le texte de vos réponses est envoyé au fournisseur du modèle rapide et du modèle fort\u{00A0}; l'audio du micro ne quitte jamais cet ordinateur. La voix de Supervox est celle du système\u{00A0}: rien n'est envoyé pour la produire."

    /// Avec la voix du système : rien n'est envoyé pour la produire.
    @Test func thePrivacyLineSaysTheSystemVoiceSendsNothing() {
        #expect(Rig().makeModel().privacyText == Self.systemPrivacy)
    }

    /// Avec la voix d'un fournisseur : la dernière phrase change et nomme ce fournisseur (rogné comme partout).
    @Test func thePrivacyLineNamesTheVoiceProvider() {
        var settings = AppSettings.defaults
        settings.providers = [Self.provider, Self.voiceProvider]
        settings.voice = VoiceChoice(providerID: Self.voiceProvider.id, model: "voix-modele", identifier: "voix-exemple")
        #expect(settings.voice.usesProvider)
        let model = Rig(settings).makeModel()
        let expected =
            "Le texte de vos réponses est envoyé au fournisseur du modèle rapide et du modèle fort\u{00A0}; l'audio du micro ne quitte jamais cet ordinateur. La voix de Supervox vient de «\u{00A0}Fournisseur de voix d'exemple\u{00A0}»\u{00A0}: le texte qu'elle dit lui est envoyé."
        #expect(model.privacyText == expected)
        #expect(!model.privacyText.contains("est celle du système"))

        settings.providers[1].name = String(repeating: "V", count: Provider.shortNameLimit + 10)
        let long = Rig(settings).makeModel()
        #expect(long.privacyText.contains("«\u{00A0}" + String(repeating: "V", count: Provider.shortNameLimit) + "…\u{00A0}»"))
    }

    /// Une voix dont le fournisseur n'existe plus se dit avec la voix du système (c'est ce que l'entretien fera), jamais avec un nom
    /// inventé.
    @Test func aVoiceWhoseProviderIsGoneIsSaidAsTheSystemVoice() {
        var settings = AppSettings.defaults
        settings.providers = [Self.provider]
        settings.voice = VoiceChoice(providerID: Self.voiceProvider.id, model: "voix-modele", identifier: "voix-exemple")
        #expect(Rig(settings).makeModel().privacyText == Self.systemPrivacy)
    }

    // MARK: - Note de maintien

    /// La note de maintien (tâche 8) n'apparaît que si le raccourci est en maintien.
    @Test func theHoldNoteShowsOnlyForTheHoldBehavior() {
        var settings = AppSettings.defaults
        settings.hotKeyBehavior = .toggle
        #expect(Rig(settings).makeModel().holdNote == nil)
        settings.hotKeyBehavior = .hold
        #expect(Rig(settings).makeModel().holdNote == InterviewText.holdNote)
    }

    // MARK: - Les phrases

    /// Les phrases de l'onglet, mot pour mot, avec les espaces insécables de la maison.
    @Test func theTabSpeaksInTheExpectedWords() {
        #expect(
            InterviewSettingsModel.header
                == "L'entretien vous pose des questions à voix haute, une à la fois, puis rédige un prompt à partir de vos réponses. Il passe toujours par la relecture. Les changements s'appliquent au prochain entretien."
        )
        #expect(
            InterviewSettingsModel.modelsNote
                == "Le modèle rapide pose les questions, le modèle fort rédige le prompt\u{00A0}: ils se choisissent en tête de l'onglet Modes."
        )
        #expect(InterviewSettingsModel.maxQuestionsTitle == "Nombre maximal de questions")
        #expect(
            InterviewSettingsModel.maxQuestionsNote == "Après la réponse à la dernière question, Supervox rédige le prompt.")
        #expect(InterviewSettingsModel.templateTitle == "Gabarit du prompt final")
        #expect(InterviewSettingsModel.restoreTemplateTitle == "Revenir au gabarit d'origine")
        #expect(
            InterviewSettingsModel.templateNote
                == "Le gabarit dit au modèle fort comment rédiger le prompt. La conversation lui est passée à part, comme une donnée\u{00A0}: rien de ce que vous dites ne peut changer ce gabarit."
        )
        #expect(InterviewSettingsModel.advancedTitle == "Réglages avancés")
        #expect(InterviewSettingsModel.turnSilenceTitle == "Silence de fin de tour")
        #expect(InterviewSettingsModel.interruptMinDurationTitle == "Durée de voix pour couper la parole")
        #expect(InterviewSettingsModel.interruptLevelTitle == "Niveau de voix pour couper la parole")
        #expect(
            InterviewSettingsModel.interruptNote
                == "Si Supervox se coupe en entendant sa propre voix, montez le niveau (vers −20 dB). S'il ne s'arrête pas quand vous parlez, baissez-le."
        )
        #expect(InterviewSettingsModel.restoreAdvancedTitle == "Rétablir les valeurs d'origine")
        #expect(
            InterviewSettingsModel.saveFailure
                == "Ce changement n'a pas pu être enregistré\u{00A0}: l'entretien garde ses réglages précédents.")
    }

    /// La typographie française de la maison : aucune espace ordinaire avant « : ; ? ! », ni après « « », ni avant « » », dans
    /// aucune phrase de l'onglet (celles de l'exemple compris).
    @Test func everySentenceFollowsTheHouseTypography() {
        var settings = AppSettings.defaults
        settings.providers = [Self.voiceProvider]
        settings.voice = VoiceChoice(providerID: Self.voiceProvider.id, model: "voix-modele", identifier: "voix-exemple")
        settings.hotKeyBehavior = .hold
        let model = Rig(settings).makeModel()
        let sentences: [String] =
            [
                InterviewSettingsModel.header, InterviewSettingsModel.modelsNote, InterviewSettingsModel.maxQuestionsNote,
                InterviewSettingsModel.templateNote, InterviewSettingsModel.interruptNote, InterviewSettingsModel.saveFailure,
                model.privacyText, model.effectiveSilenceText, model.holdNote ?? "", Self.systemPrivacy,
            ]
        for sentence in sentences {
            #expect(!sentence.isEmpty)
            for mark in [" :", " ;", " ?", " !", "« ", " »"] {
                #expect(!sentence.contains(mark), "« \(mark) » ordinaire dans : \(sentence)")
            }
        }
    }
}
