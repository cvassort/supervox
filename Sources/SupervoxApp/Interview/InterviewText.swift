import Foundation
import SupervoxCore

/// Toutes les phrases de l'entretien dans le panneau. Un message montré vient d'ici, d'une table de phrases fixes : jamais le texte
/// d'une erreur (`localizedDescription`), jamais le corps d'une réponse HTTP, jamais un code de panne brut. Chacune tient dans
/// `DictationText.detailLimit` (`allSentences`, que `InterviewTextTests` mesure).
public enum InterviewText {
    // MARK: Titres et aides

    public static func title(_ phase: InterviewPhase) -> String {
        switch phase {
        case .preparing: "Préparation de l'entretien…"
        case .listening: "À vous"
        case .thinking: "Réflexion…"
        case .speaking: "Supervox parle"
        case .concluding: "Rédaction du prompt…"
        }
    }

    /// L'aide sous le titre ; vide en préparation et en conclusion (pas d'aide : `InterviewViewState.hint` rend alors `nil`).
    public static func hint(_ phase: InterviewPhase) -> String {
        switch phase {
        case .preparing, .concluding: ""
        case .listening: "Parlez : Supervox attend la fin de votre phrase. Appuyez sur Conclure quand vous avez tout dit."
        case .thinking: "Parlez pour ajouter quelque chose : Supervox reprendra avec."
        case .speaking: "Parlez pour couper la parole à Supervox."
        }
    }

    /// Le pied : ce que fait Échap, à tout état sauf la conclusion.
    public static let cancelHint = "Échap annule l'entretien sans rien garder."

    // MARK: Compteur, bouton, rôles

    /// « Question n sur m » ; la vue ne l'affiche qu'à partir de la première question (`InterviewViewState.counter`).
    public static func questionCounter(_ n: Int, of m: Int) -> String { "Question \(n) sur \(m)" }

    public static let concludeLabel = "Conclure"
    /// Ce que VoiceOver lit après le nom du bouton.
    public static let concludeHelp = "Rédige le prompt à partir de ce qui a été dit."

    /// Les deux étiquettes au-dessus des textes : la réplique de Supervox, et la dernière réplique de la personne.
    public static let supervoxLabel = "Supervox"
    public static let youLabel = "Vous"

    /// Montrée quand le réglage du raccourci est « maintien » : en entretien, un appui conclut.
    public static let holdNote = "En entretien, le raccourci fonctionne toujours en bascule : un appui conclut."

    /// Les caractères montrés de la réplique de Supervox : cinq lignes de `callout` au plus (une ligne en tient 80 à 90, relevé sur
    /// les images de la dictée), avec la marge d'une coupe à une limite de mot. Choix de mise en page, non mesuré sur l'entretien.
    public static let questionLimit = 330

    // MARK: Avis

    /// L'avis d'un fait que le moteur signale sans s'arrêter. `switch` exhaustif, sans `default` : un cas ajouté à
    /// `ConversationNotice` ne compile pas tant qu'il n'a pas sa phrase.
    public static func notice(_ notice: ConversationNotice) -> String {
        switch notice {
        case .notUnderstood: "Rien n'a été compris : répétez, un peu plus près du micro."
        case .modelFailed(let failure): turnFailure(failure)
        case .voiceFellBack: "La voix choisie ne répond pas : l'entretien continue avec la voix du système."
        case .voiceUnavailable: "La voix ne fonctionne pas : lisez la question à l'écran, puis répondez à voix haute."
        case .proposal: "Supervox propose de conclure : dites-le s'il vous convient, ou continuez à préciser."
        case .lastQuestion: "Dernière question : après votre réponse, Supervox rédige le prompt."
        }
    }

    /// Ce que dit le panneau quand le modèle rapide n'a pas pu formuler la question : le tour de la personne est gardé, l'écoute
    /// reprend. Aucun cas ne montre un code HTTP ni le nom du fournisseur. Chaque cas est nommé, sans `default`.
    public static func turnFailure(_ failure: RewriteFailure) -> String {
        switch failure {
        case .unauthorized, .noKey, .keychain:
            "Le fournisseur refuse la clé : vérifiez-la dans Réglages, onglet Fournisseurs, puis relancez l'entretien."
        case .notFound:
            "Le modèle rapide n'existe pas chez ce fournisseur : choisissez-en un autre en tête de Réglages, onglet Modes."
        case .rateLimited:
            "Le fournisseur limite les requêtes : attendez un peu, puis répétez votre réponse."
        case .noModel, .providerMissing, .rejected, .server, .unreachable, .redirected, .interrupted, .stalled, .providerError,
            .truncated, .refused, .empty, .timedOut, .malformed:
            "Supervox n'a pas pu formuler sa question : répétez votre réponse, ou appuyez sur Conclure."
        }
    }

    // MARK: Vie privée

    /// Le pied de la vue (D11) : où part le texte, et que l'audio reste sur l'ordinateur. Avec une voix de fournisseur, où part aussi
    /// le texte que dit Supervox. Les noms sont rognés comme partout (`Provider.shortName`) : la ligne tient quel que soit le nom.
    public static func privacy(provider: String, voiceProvider: String?) -> String {
        let line =
            "Le texte de vos réponses part chez « \(Provider.shortName(provider)) » ; l'audio du micro reste sur cet ordinateur."
        guard let voiceProvider else { return line }
        return line + " Le texte que dit Supervox part chez « \(Provider.shortName(voiceProvider)) »."
    }

    // MARK: Pannes de l'entretien

    /// Une phrase par code de `ConversationFailure.Code` : ce qui s'est passé, et quoi faire. Le moteur ne rend que des codes, jamais
    /// le texte d'une erreur ; un test relit la liste des codes dans le moteur et exige une phrase propre à chacun.
    private static let failureSentences: [String: String] = [
        ConversationFailure.Code.microphoneAccessDenied:
            "L'accès au micro est refusé : autorisez Supervox dans Réglages Système, Confidentialité et sécurité, Micro, puis relancez l'entretien.",
        ConversationFailure.Code.noInputDevice:
            "Aucun micro n'est disponible : branchez-en un ou choisissez une entrée dans Réglages Système, Son, puis relancez l'entretien.",
        ConversationFailure.Code.alreadyRunning:
            "Le micro est déjà utilisé : terminez l'autre dictée ou l'autre écoute de Supervox, puis relancez l'entretien.",
        ConversationFailure.Code.engineFailed:
            "Le moteur audio n'a pas pu démarrer : vérifiez que le micro fonctionne dans une autre application, puis relancez l'entretien.",
        ConversationFailure.Code.notRunning:
            "Le moteur audio n'était pas démarré quand Supervox a voulu parler : relancez l'entretien.",
        ConversationFailure.Code.silent:
            "Le micro ne donne plus aucun son : vérifiez qu'il est branché et choisi comme entrée dans Réglages Système, Son, puis relancez l'entretien.",
        ConversationFailure.Code.unusableSampleRate:
            "Le micro utilise une fréquence que Supervox ne sait pas lire : choisissez une autre entrée dans Réglages Système, Son, puis relancez l'entretien.",
        ConversationFailure.Code.conversionFailed:
            "Le son du micro n'a pas pu être converti : choisissez une autre entrée dans Réglages Système, Son, puis relancez l'entretien.",
        ConversationFailure.Code.detectorFailed:
            "Le détecteur de voix a échoué : relancez l'entretien ; si cela se répète, vérifiez dans Réglages, onglet Transcription, que son modèle est téléchargé.",
        ConversationFailure.Code.transcriptionUnsupportedSampleRate:
            "Le moteur de transcription a reçu un son à une fréquence qu'il ne lit pas : relancez l'entretien ; si cela se répète, choisissez une autre entrée dans Réglages Système, Son.",
        ConversationFailure.Code.transcriptionNotPrepared:
            "Le moteur de transcription n'était pas prêt : relancez l'entretien ; si cela se répète, vérifiez dans Réglages, onglet Transcription, que son modèle est téléchargé.",
        ConversationFailure.Code.transcriptionUnsupportedLocale:
            "Le moteur de transcription ne gère pas cette langue : changez de moteur ou de langue dans Réglages, onglet Transcription, puis relancez l'entretien.",
        ConversationFailure.Code.transcriptionVocabularyUnavailable:
            "Le moteur de transcription n'a pas pu prendre en compte votre vocabulaire : relancez l'entretien ; si cela se répète, videz le vocabulaire dans Réglages, onglet Transcription.",
        ConversationFailure.Code.transcriptionFailed:
            "La transcription a échoué : relancez l'entretien ; si cela se répète, changez de moteur dans Réglages, onglet Transcription.",
        ConversationFailure.Code.transcriptionTimedOut:
            "Le moteur de transcription n'a rien rendu à temps : relancez l'entretien ; si cela se répète, changez de moteur dans Réglages, onglet Transcription.",
        ConversationFailure.Code.unexpected:
            "Une panne inattendue a arrêté l'entretien : relancez-le.",
    ]

    /// Pour un code que cette version ne connaît pas : jamais le code brut.
    private static let generalFailure =
        "L'entretien s'est arrêté sur une panne que cette version ne sait pas décrire : relancez-le, ou mettez Supervox à jour."

    /// Les codes qui ont leur phrase (pour les tests, qui les comparent à ceux du moteur).
    static var knownFailureCodes: [String] { failureSentences.keys.sorted() }

    /// La phrase d'une panne qui a arrêté l'entretien. Les codes du micro et des moteurs sont distincts : la phrase ne dépend que du
    /// code.
    public static func failure(_ failure: ConversationFailure) -> String {
        switch failure {
        case .microphone(let code), .engine(let code): failureSentences[code] ?? generalFailure
        }
    }

    // MARK: Pour le test de longueur

    /// Toutes les phrases que ce fichier peut dire, avec des noms de fournisseur de 40 caractères (la limite de `Provider.shortName`)
    /// et le plus grand compteur. Chacune doit tenir dans `DictationText.detailLimit` ; `InterviewTextTests` le mesure.
    static var allSentences: [String] {
        let phases: [InterviewPhase] = [.preparing, .listening, .thinking, .speaking, .concluding]
        let forty = String(repeating: "x", count: Provider.shortNameLimit)
        let failures: [RewriteFailure] = [
            .noModel, .providerMissing, .noKey(provider: forty), .keychain, .unauthorized(401), .notFound, .rejected(422),
            .rateLimited, .server(503), .unreachable, .redirected, .interrupted, .stalled(30), .providerError, .truncated,
            .refused, .empty, .timedOut(30), .malformed,
        ]
        let notices: [ConversationNotice] = [.notUnderstood, .voiceFellBack, .voiceUnavailable, .proposal, .lastQuestion]
        var sentences = phases.map(title) + phases.map(hint).filter { !$0.isEmpty }
        sentences += [cancelHint, concludeLabel, concludeHelp, supervoxLabel, youLabel, holdNote, questionCounter(99, of: 99)]
        sentences += [privacy(provider: forty, voiceProvider: nil), privacy(provider: forty, voiceProvider: forty)]
        sentences += notices.map(notice) + failures.map(turnFailure) + failures.map { notice(.modelFailed($0)) }
        sentences += knownFailureCodes.flatMap { code in [failure(.microphone(code)), failure(.engine(code))] }
        sentences.append(failure(.engine("code-inconnu")))
        return sentences
    }
}
