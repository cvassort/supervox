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

    /// La phrase d'une panne de l'écoute ; pour `.provider(f)`, la phrase fixe de `f` (`RewriteFailure.message`).
    public static func failure(_ failure: VoicePreview.Failure) -> String {
        switch failure {
        case .notInstalled:
            InterviewText.fr("Cette voix n'est pas installée sur cet ordinateur : choisissez-en une autre.")
        case .unusable(let reason):
            Self.reason(reason)
        case .provider(let failure):
            providerFailure(failure)
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
    /// nouveau forcera une décision ici.
    public static func providerFailure(_ failure: RewriteFailure) -> String {
        switch failure {
        case .noModel:
            InterviewText.fr(
                "Aucun modèle n'est donné pour cette voix : vérifiez le modèle, l'identifiant et les paramètres de la voix dans "
                    + "l'onglet Voix.")
        case .providerMissing:
            Self.reason(.providerRemoved)
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

    /// Pourquoi une voix de fournisseur ne peut pas parler (règle 3).
    public static func reason(_ reason: SystemReason) -> String {
        switch reason {
        case .providerRemoved:
            InterviewText.fr("Le fournisseur de cette voix a été supprimé : choisissez-en un autre en modifiant la voix.")
        case .providerCannotSpeak:
            InterviewText.fr("Ce fournisseur ne sait pas parler : il n'a pas de synthèse de la voix.")
        case .incomplete:
            InterviewText.fr("Le modèle ou l'identifiant de cette voix manque : complétez-les en modifiant la voix.")
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
    public static let notSaved = InterviewText.fr("Cette voix n'est pas enregistrée dans la liste.")

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

    // MARK: - Écritures

    public static let deleteConfirmation = InterviewText.fr("Supprimer cette voix ?")
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
