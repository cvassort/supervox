import Foundation
import SupervoxCore

/// Les phrases de l'onglet Voix et de l'écoute d'une voix : fixes, en français, en phrases complètes, passées par `InterviewText.fr`
/// (espaces insécables). Aucune ne reprend le texte d'une erreur.
public enum VoicesText {
    // MARK: - Phrase d'essai (règle 10)

    /// La phrase que dit une voix qu'on écoute, par langue primaire. Une autre langue prend l'anglais.
    public static let samplePhrases: [String: String] = [
        "fr": InterviewText.fr("Bonjour, je suis une voix que Supervox peut prendre pour vous parler."),
        "en": "Hello, I am a voice Supervox can use to speak to you.",
        "es": "Hola, soy una voz que Supervox puede usar para hablarte.",
        "de": "Hallo, ich bin eine Stimme, mit der Supervox zu Ihnen sprechen kann.",
        "it": "Ciao, sono una voce che Supervox può usare per parlarti.",
    ]

    /// La phrase d'essai de cette langue : sa langue primaire (avant `-` ou `_`, sans casse), sinon l'anglais.
    public static func samplePhrase(for language: String) -> String {
        let primary = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        return samplePhrases[primary] ?? samplePhrases["en"] ?? ""
    }

    // MARK: - Pannes de l'écoute

    /// La phrase d'une panne de l'écoute ; pour `.provider(f)`, la phrase fixe de `f` (`RewriteFailure.message`). Sans `canEdit` :
    /// la ligne écoutée se modifie (une voix enregistrée). `canEdit` faux : la phrase d'une voix qui ne peut pas parler ne renvoie
    /// pas à « Modifier » (`reason(_:canEdit:)`).
    public static func failure(_ failure: VoicePreview.Failure) -> String {
        Self.failure(failure, canEdit: true)
    }

    public static func failure(_ failure: VoicePreview.Failure, canEdit: Bool) -> String {
        switch failure {
        case .notInstalled:
            InterviewText.fr("Cette voix n'est pas installée sur cet ordinateur : choisissez-en une autre.")
        case .unusable(let reason):
            Self.reason(reason, canEdit: canEdit)
        case .provider(let failure):
            providerFailure(failure, canEdit: canEdit)
        case .silent:
            InterviewText.fr("La voix n'a rendu aucun son : il n'y a rien à faire entendre.")
        case .timedOut:
            // Sans nombre de secondes : la voix du système abandonne d'elle-même avant la borne de l'écoute.
            InterviewText.fr("La voix n'a pas répondu à temps : réessayez dans un moment.")
        case .playback:
            InterviewText.fr("Le son n'a pas pu être joué : vérifiez la sortie audio, puis réessayez.")
        case .unavailable:
            InterviewText.fr("L'écoute n'est pas disponible : relancez Supervox.")
        case .microphoneBusy:
            InterviewText.fr(
                "Une dictée ou un entretien se sert du micro : réessayez d'écouter cette voix quand la dictée ou l'entretien "
                    + "sera terminé.")
        }
    }

    /// La phrase d'une panne de fournisseur pendant l'écoute d'une voix. Le classement reste unique (`RewriteFailure.from`) ; seule
    /// la phrase change là où celle de `RewriteFailure`, écrite pour les modes, égarerait : pour une voix, une adresse ou un modèle
    /// inconnu, une requête refusée ou une réponse illisible veulent dire « voix mal réglée ». `switch` sans `default` : un cas
    /// nouveau forcera une décision ici. Quatre cas gardent la phrase écrite pour les modes sans être atteints par l'écoute
    /// (code lu) : `.interrupted` et `.providerError` ne naissent que d'un flux de complétion (`EndpointError.streamInterrupted`,
    /// `CompletionError.provider`), `.truncated` et `.refused` que de la raison d'arrêt d'un flux, dans la réécriture
    /// (`Rewrite.swift`) ; la synthèse est une seule requête, sans
    /// flux (`OpenAICompatibleClient.speechMeasured`).
    public static func providerFailure(_ failure: RewriteFailure, canEdit: Bool = true) -> String {
        switch failure {
        case .noModel:
            InterviewText.fr(
                "Aucun modèle n'est donné pour cette voix : vérifiez le modèle, l'identifiant et les paramètres de la voix dans "
                    + "l'onglet Voix.")
        case .providerMissing:
            Self.reason(.providerRemoved, canEdit: canEdit)
        case .notFound:
            InterviewText.fr(
                "Le fournisseur ne connaît pas ce modèle ou cette adresse (HTTP 404) : vérifiez le modèle, l'identifiant et les "
                    + "paramètres de la voix dans l'onglet Voix, puis l'adresse du fournisseur.")
        case .rejected(let status):
            InterviewText.fr(
                "Le fournisseur a refusé la demande de cette voix (HTTP \(status)) : vérifiez le modèle, l'identifiant et les "
                    + "paramètres de la voix dans l'onglet Voix.")
        case .malformed:
            InterviewText.fr(
                "Le fournisseur n'a pas rendu un son lisible : vérifiez le modèle, l'identifiant et les paramètres de la voix dans "
                    + "l'onglet Voix.")
        case .stalled, .timedOut:
            Self.failure(.timedOut)
        case .empty:
            Self.failure(.silent)
        case .noKey, .keychain, .unauthorized, .rateLimited, .server, .unreachable, .redirected, .interrupted, .providerError,
            .truncated, .refused:
            failure.message
        }
    }

    /// Pourquoi une voix de fournisseur ne peut pas parler (règle 3). `canEdit` faux : la ligne ne se modifie pas (la ligne
    /// « Voix en vigueur », B4 de la revue finale) ; la phrase finit alors par « choisissez une autre voix », jamais par « en
    /// modifiant la voix ».
    public static func reason(_ reason: SystemReason, canEdit: Bool = true) -> String {
        switch reason {
        case .providerRemoved:
            canEdit
                ? InterviewText.fr("Le fournisseur de cette voix a été supprimé : choisissez-en un autre en modifiant la voix.")
                : InterviewText.fr("Le fournisseur de cette voix a été supprimé : choisissez une autre voix.")
        case .providerCannotSpeak:
            InterviewText.fr("Ce fournisseur ne sait pas parler : il n'a pas de synthèse de la voix.")
        case .incomplete:
            canEdit
                ? InterviewText.fr("Le modèle ou l'identifiant de cette voix manque : complétez-les en modifiant la voix.")
                : InterviewText.fr("Le modèle ou l'identifiant de cette voix manque : choisissez une autre voix.")
        }
    }

    // MARK: - L'onglet

    public static let systemSection = "Voix du système"
    public static let providerSection = "Voix de fournisseurs"
    public static let automatic = "Automatique"
    public static let automaticDetail = "Meilleure voix de la langue"
    public static let activeVoice = "Voix en vigueur"
    public static let genderUnspecified = "Genre non précisé"
    public static let allLanguages = "Toutes les langues"
    /// Le nom d'un fournisseur qui n'est plus dans les réglages, à la place de son nom.
    public static let providerRemovedName = "Fournisseur supprimé"
    public static let noLongerInstalled = InterviewText.fr("Cette voix n'est plus installée sur cet ordinateur.")
    /// La note de la ligne « Voix en vigueur » d'une voix automatique du système dont la langue exacte n'a pas de ligne
    /// « Automatique » mais dont la langue a une voix installée (autre région, ou langue écrite sans région) : elle nomme la voix
    /// que le synthétiseur prend (`SystemSpeechSynthesizer.pickVoice`), par son nom, ou son identifiant si le nom est vide. Le nom
    /// est repris tel quel (les espaces insécables ne touchent que la phrase autour).
    public static func speaksWithBestVoice(named name: String) -> String {
        InterviewText.fr("Supervox parle avec « ") + name + InterviewText.fr(" », la meilleure voix installée pour cette langue.")
    }
    public static let notSaved = InterviewText.fr("Cette voix n'est pas enregistrée dans la liste.")

    /// La langue d'un code (`fr-FR`), en clair et en français (« français (France) »), calculée avec une locale française FIXE,
    /// pas celle de la machine. Un code que la locale ne connaît pas, vide ou blanc : rendu tel quel (mesuré sur macOS 26 :
    /// `zz-ZZ`, `code-invente` et la chaîne vide n'ont pas de nom ; `fr-ZZ` donne « français (région inconnue) »).
    public static func languageName(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let name = Self.frenchLocale.localizedString(forIdentifier: trimmed) else { return code }
        return name
    }

    private static let frenchLocale = Locale(identifier: "fr_FR")

    /// Le genre d'une voix, dans le détail d'une ligne.
    public static func genderTitle(_ gender: VoiceGender?) -> String {
        switch gender {
        case .female?: "Féminin"
        case .male?: "Masculin"
        case .neutral?: "Neutre"
        case .other?, nil: genderUnspecified
        }
    }

    /// Le libellé d'un filtre de genre.
    public static func genderFilterTitle(_ filter: VoicesModel.GenderFilter) -> String {
        switch filter {
        case .all: "Tous"
        case .female: "Féminin"
        case .male: "Masculin"
        case .neutral: "Neutre"
        case .unspecified: "Non précisé"
        }
    }

    /// La qualité d'une voix du système (1 défaut, 2 améliorée, 3 premium : valeurs d'`AVSpeechSynthesisVoiceQuality`, code lu).
    public static func quality(_ quality: Int) -> String {
        switch quality {
        case 1: "Qualité standard"
        case 2: "Qualité améliorée"
        case 3: "Qualité premium"
        default: "Qualité non précisée"
        }
    }

    // MARK: - Libellés de la vue (tâche 4)

    public static let languageFilterLabel = "Langue"
    public static let genderFilterLabel = "Genre"
    public static let useTitle = "Utiliser cette voix"
    public static let listenTitle = "Écouter"
    public static let stopTitle = "Arrêter"
    public static let addTitle = "Ajouter une voix…"
    public static let editTitle = "Modifier…"
    public static let deleteTitle = "Supprimer…"
    /// Le bouton de la confirmation de suppression.
    public static let confirmDeleteTitle = "Supprimer"
    /// Le bouton de l'onglet Entretien qui mène à l'onglet Voix.
    public static let chooseVoiceTitle = "Choisir la voix…"
    /// La ligne de l'onglet Entretien qui mène à l'onglet Voix : son libellé et sa légende.
    public static let voiceRowTitle = "Voix"
    public static let voiceRowCaption = "La voix de Supervox se choisit dans l'onglet Voix."
    /// Ce que VoiceOver dit de la marque de la ligne en cours d'écoute.
    public static let listeningMark = "En écoute"
    /// Ce que VoiceOver dit des icônes (R8, tour 2) : le triangle d'une note et l'icône de la bande d'un avis, d'une panne, de la
    /// vie privée.
    public static let warningLabel = "Avertissement"
    public static let errorLabel = "Erreur"
    public static let informationLabel = "Information"
    /// Ce que VoiceOver dit des champs d'un paramètre : leur numéro les distingue (R8, tour 2).
    public static func parameterKeyLabel(_ number: Int) -> String { "Clé du paramètre \(number)" }
    public static func parameterValueLabel(_ number: Int) -> String { "Valeur du paramètre \(number)" }

    // MARK: - L'éditeur d'une voix de fournisseur (tâche 4)

    public static let editorAddTitle = "Ajouter une voix"
    public static let editorEditTitle = "Modifier la voix"
    public static let nameField = "Nom"
    public static let providerField = "Fournisseur"
    public static let noSpeakingProvider = "Aucun fournisseur qui sait parler"
    /// Le fournisseur d'une voix modifiée qui ne peut plus servir (supprimé, ou sans synthèse de la voix).
    public static let unusableProvider = "Fournisseur qui ne peut pas parler"
    public static let modelField = "Modèle"
    /// Le menu des modèles connus du fournisseur, à côté du champ du modèle.
    public static let modelMenu = "Modèles du fournisseur"
    public static let identifierField = "Identifiant"
    public static let languageField = "Langue"
    public static let genderField = "Genre"
    public static let parametersTitle = "Paramètres"
    public static let keyField = "Clé"
    public static let valueField = "Valeur"
    public static let addParameterTitle = "Ajouter un paramètre"
    public static let removeParameterTitle = "Retirer ce paramètre"
    public static let cancelTitle = "Annuler"
    public static let saveTitle = "Enregistrer"

    /// Le genre d'une voix dans l'éditeur : contrairement au détail d'une ligne, « Autre » s'y distingue de « Non précisé ».
    public static func editorGenderTitle(_ gender: VoiceGender?) -> String {
        switch gender {
        case nil: genderFilterTitle(.unspecified)
        case .female?: genderFilterTitle(.female)
        case .male?: genderFilterTitle(.male)
        case .neutral?: genderFilterTitle(.neutral)
        case .other(let name)?: "Autre (\(name))"
        }
    }

    // MARK: - Écritures

    /// La question posée avant de supprimer une voix enregistrée : elle la nomme. La voix en vigueur : une seconde phrase dit ce
    /// que Supervox prendra à sa place (la voix de `deletedActive`). Le nom est repris tel quel (les espaces insécables ne
    /// touchent que la phrase autour).
    public static func deleteConfirmation(name: String, isActive: Bool) -> String {
        let question = InterviewText.fr("Supprimer la voix « ") + name + InterviewText.fr(" » ?")
        guard isActive else { return question }
        return question + " "
            + InterviewText.fr("C'est la voix en vigueur : Supervox reprendra la voix automatique du système, en français.")
    }
    public static let deletedActive = InterviewText.fr(
        "La voix supprimée était la voix en vigueur : Supervox reprend la voix automatique du système, en français.")

    // MARK: - Refus du brouillon (règle 5)

    public static let refusalEmptyName = InterviewText.fr("Donnez un nom à cette voix.")
    public static let refusalNoProvider = InterviewText.fr(
        "Choisissez un fournisseur qui sait parler : ajoutez-en un dans l'onglet Fournisseurs s'il n'y en a pas.")
    public static let refusalEmptyModel = InterviewText.fr("Indiquez le modèle de synthèse de la voix.")
    public static let refusalEmptyIdentifier = InterviewText.fr("Indiquez l'identifiant de la voix chez le fournisseur.")
    public static let refusalEmptyKey = InterviewText.fr("Chaque paramètre a besoin d'une clé : remplissez-la ou retirez la ligne.")
    /// Nomme les clés réservées, depuis `VoiceChoice.reservedExtraKeys`, dans l'ordre alphabétique.
    public static let refusalReservedKey = InterviewText.fr(
        "Ces clés sont posées par Supervox et ne peuvent pas servir de paramètre : "
            + VoiceChoice.reservedExtraKeys.sorted().map { "« \($0) »" }.joined(separator: ", ") + ".")
    public static let refusalDuplicateKey = InterviewText.fr("Deux paramètres ont la même clé : gardez-en un seul.")
    public static let refusalTooManyParameters = InterviewText.fr(
        "Une voix a au plus \(VoiceChoice.maxExtraEntries) paramètres : retirez-en.")

    // MARK: - Vie privée (règle 10)

    /// Une voix du système : l'écoute n'envoie rien.
    public static let privacyNothingSent = InterviewText.fr(
        "Écouter cette voix n'envoie rien : elle est produite sur cet ordinateur.")

    /// Une voix de fournisseur qui ne peut pas parler (fournisseur supprimé, sans synthèse, voix incomplète) : rien n'est envoyé,
    /// et elle n'est produite nulle part.
    public static let privacyCannotSpeak = InterviewText.fr("Cette voix ne peut pas parler : l'écouter n'envoie rien.")

    /// Une voix de fournisseur : la phrase d'essai part chez lui, et sa clé est lue.
    public static func privacyProvider(_ name: String) -> String {
        InterviewText.fr("Écouter cette voix envoie la phrase d'essai à « \(name) » et lit sa clé dans le trousseau.")
    }
}
