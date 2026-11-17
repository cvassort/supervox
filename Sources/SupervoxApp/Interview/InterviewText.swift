import Foundation
import SupervoxCore

/// Toutes les phrases de l'entretien dans le panneau. Un message montré vient d'ici, d'une table de phrases fixes : jamais le texte
/// d'une erreur (`localizedDescription`), jamais le corps d'une réponse HTTP, jamais un code de panne brut. Chacune tient dans
/// `DictationText.detailLimit` (`allSentences`, que `InterviewTextTests` mesure).
public enum InterviewText {
    // MARK: Typographie

    /// Les espaces insécables du français, comme `DictationText` : avant « : ; ? ! », après « « » et avant « » ». Une ligne ne finit
    /// donc pas sur un « « » ni ne commence par un « : ». Chaque phrase de ce fichier passe par là.
    private static func fr(_ text: String) -> String {
        var typeset = text
        for mark in [":", ";", "?", "!"] { typeset = typeset.replacingOccurrences(of: " " + mark, with: "\u{00A0}" + mark) }
        return typeset.replacingOccurrences(of: "« ", with: "«\u{00A0}").replacingOccurrences(of: " »", with: "\u{00A0}»")
    }

    // MARK: Titres et aides

    /// Le titre de la phase. `textOnly` : aucune voix ne parle (la réplique n'est qu'affichée), la phase de parole s'appelle alors
    /// « Supervox répond ».
    public static func title(_ phase: InterviewPhase, textOnly: Bool = false) -> String {
        switch phase {
        case .preparing: fr("Préparation de l'entretien…")
        case .listening: fr("À vous")
        case .thinking: fr("Réflexion…")
        case .speaking: textOnly ? fr("Supervox répond") : fr("Supervox parle")
        case .concluding: fr("Rédaction du prompt…")
        }
    }

    /// L'aide sous le titre ; vide en préparation et en conclusion (pas d'aide : `InterviewViewState.hint` rend alors `nil`). Sans
    /// voix (`textOnly`), la phase de parole dit de lire, jamais de couper la parole : personne ne parle.
    public static func hint(_ phase: InterviewPhase, textOnly: Bool = false) -> String {
        switch phase {
        case .preparing, .concluding: ""
        case .listening: fr("Parlez : Supervox attend la fin de votre phrase. Appuyez sur Conclure quand vous avez tout dit.")
        case .thinking: fr("Parlez pour ajouter quelque chose : Supervox reprendra avec.")
        case .speaking: textOnly ? fr("Lisez la réponse à l'écran, puis parlez.") : fr("Parlez pour couper la parole à Supervox.")
        }
    }

    /// Le pied : ce que fait Échap, à tout état sauf la conclusion.
    public static let cancelHint = fr("Échap annule l'entretien sans rien garder.")

    // MARK: Compteur, bouton, rôles

    /// « Question n sur m » ; la vue ne l'affiche qu'à partir de la première question (`InterviewViewState.counter`).
    public static func questionCounter(_ n: Int, of m: Int) -> String { fr("Question \(n) sur \(m)") }

    public static let concludeLabel = fr("Conclure")
    /// Ce que VoiceOver lit après le nom du bouton.
    public static let concludeHelp = fr("Rédige le prompt à partir de ce qui a été dit.")

    /// Les deux étiquettes au-dessus des textes : la réplique de Supervox, et la dernière réplique de la personne.
    public static let supervoxLabel = fr("Supervox")
    public static let youLabel = fr("Vous")

    /// L'aide VoiceOver des pastilles de modes pendant un entretien : elles ne répondent plus.
    public static let modeLockedHint = fr("Indisponible pendant un entretien.")

    /// Montrée quand le réglage du raccourci est « maintien » : en entretien, un appui conclut.
    public static let holdNote = fr("En entretien, le raccourci fonctionne toujours en bascule : un appui conclut.")

    // MARK: Avis

    /// L'avis d'un fait que le moteur signale sans s'arrêter. `switch` exhaustif, sans `default` : un cas ajouté à
    /// `ConversationNotice` ne compile pas tant qu'il n'a pas sa phrase.
    public static func notice(_ notice: ConversationNotice) -> String {
        switch notice {
        case .notUnderstood: fr("Rien n'a été compris : répétez, un peu plus près du micro.")
        case .modelFailed(let failure): turnFailure(failure)
        case .voiceFellBack: fr("La voix choisie ne répond pas : l'entretien continue avec la voix du système.")
        case .voiceUnavailable: fr("La voix ne fonctionne pas : lisez la question à l'écran, puis répondez à voix haute.")
        case .proposal: fr("Supervox propose de conclure : dites-le s'il vous convient, ou continuez à préciser.")
        case .lastQuestion: fr("Dernière question : après votre réponse, Supervox rédige le prompt.")
        case .lastWordsLost: fr("Votre dernière phrase n'a pas pu être transcrite : le prompt est rédigé sans elle.")
        }
    }

    /// Ce que dit le panneau quand le modèle rapide n'a pas pu formuler la question : le tour de la personne est gardé, l'écoute
    /// reprend. Aucun cas ne montre un code HTTP ni le nom du fournisseur. Chaque cas est nommé, sans `default`.
    public static func turnFailure(_ failure: RewriteFailure) -> String {
        switch failure {
        case .unauthorized, .noKey, .keychain:
            fr("Le fournisseur refuse la clé : vérifiez-la dans Réglages, onglet Fournisseurs, puis relancez l'entretien.")
        case .notFound:
            fr("Le modèle rapide n'existe pas chez ce fournisseur : choisissez-en un autre en tête de Réglages, onglet Modes.")
        case .rateLimited:
            fr("Le fournisseur limite les requêtes : attendez un peu, puis répétez votre réponse.")
        case .noModel, .providerMissing, .rejected, .server, .unreachable, .redirected, .interrupted, .stalled, .providerError,
            .truncated, .refused, .empty, .timedOut, .malformed:
            fr("Supervox n'a pas pu formuler sa question : répétez votre réponse, ou appuyez sur Conclure.")
        }
    }

    // MARK: Vie privée

    /// Le pied de la vue (D11) : où part le texte, et que l'audio reste sur l'ordinateur. Avec une voix de fournisseur, où part aussi
    /// le texte que dit Supervox. Les noms sont rognés comme partout (`Provider.shortName`) : la ligne tient quel que soit le nom.
    public static func privacy(provider: String, voiceProvider: String?) -> String {
        let line = fr(
            "Le texte de vos réponses part chez « \(Provider.shortName(provider)) » ; l'audio du micro reste sur cet ordinateur.")
        guard let voiceProvider else { return line }
        return line + " " + fr("Le texte que dit Supervox part chez « \(Provider.shortName(voiceProvider)) ».")
    }

    // MARK: Pannes de l'entretien

    /// Une phrase par code de `ConversationFailure.Code` : ce qui s'est passé, et quoi faire. Le moteur ne rend que des codes, jamais
    /// le texte d'une erreur ; un test relit la liste des codes dans le moteur et exige une phrase propre à chacun.
    private static let failureSentences: [String: String] = [
        ConversationFailure.Code.microphoneAccessDenied:
            "L'accès au micro est refusé : autorisez Supervox à utiliser le micro dans les Réglages Système (Confidentialité et sécurité), puis relancez l'entretien.",
        ConversationFailure.Code.noInputDevice:
            "Aucun micro n'est disponible : branchez-en un, puis relancez l'entretien.",
        ConversationFailure.Code.alreadyRunning:
            "Le micro est déjà utilisé : terminez l'autre dictée ou l'autre écoute de Supervox, puis relancez l'entretien.",
        ConversationFailure.Code.engineFailed:
            "Le moteur audio n'a pas pu démarrer : vérifiez que le micro fonctionne dans une autre application, puis relancez l'entretien.",
        ConversationFailure.Code.notRunning:
            "Le moteur audio n'était pas démarré quand Supervox a voulu parler : relancez l'entretien.",
        ConversationFailure.Code.silent:
            "Le micro ne donne plus aucun son : vérifiez qu'il est branché, puis relancez l'entretien.",
        ConversationFailure.Code.unusableSampleRate:
            "Le micro utilise une fréquence que Supervox ne sait pas lire : relancez l'entretien ; si cela se répète, essayez une autre entrée audio.",
        ConversationFailure.Code.conversionFailed:
            "Le son du micro n'a pas pu être converti : relancez l'entretien ; si cela se répète, essayez une autre entrée audio.",
        ConversationFailure.Code.detectorFailed:
            "Le détecteur de voix a échoué : relancez l'entretien ; si cela se répète, vérifiez dans Réglages, onglet Transcription, que son modèle est téléchargé.",
        ConversationFailure.Code.transcriptionUnsupportedSampleRate:
            "Le moteur de transcription a reçu un son à une fréquence qu'il ne lit pas : relancez l'entretien ; si cela se répète, essayez une autre entrée audio.",
        ConversationFailure.Code.transcriptionNotPrepared:
            "Le moteur de transcription n'était pas prêt : relancez l'entretien ; si cela se répète, vérifiez dans Réglages, onglet Transcription, que son modèle est téléchargé.",
        ConversationFailure.Code.transcriptionUnsupportedLocale:
            "Le moteur de transcription ne gère pas cette langue : changez de moteur ou de langue dans Réglages, onglet Transcription, puis relancez l'entretien.",
        // Une panne de WhisperKit quand le vocabulaire dépasse la place du prompt d'amorce : elle se répète à l'identique, donc la
        // consigne vient avant « relancez ».
        ConversationFailure.Code.transcriptionVocabularyUnavailable:
            "Réduisez ou videz le vocabulaire personnel dans Réglages, onglet Transcription, puis relancez l'entretien.",
        ConversationFailure.Code.transcriptionFailed:
            "La transcription a échoué : relancez l'entretien ; si cela se répète, changez de moteur dans Réglages, onglet Transcription.",
        ConversationFailure.Code.transcriptionTimedOut:
            "Le moteur de transcription n'a rien rendu à temps : relancez l'entretien ; si cela se répète, changez de moteur dans Réglages, onglet Transcription.",
        ConversationFailure.Code.unexpected:
            "Une panne inattendue a arrêté l'entretien : relancez-le.",
    ].mapValues(fr)

    /// Pour un code que cette version ne connaît pas : jamais le code brut.
    private static let generalFailure = fr(
        "L'entretien s'est arrêté sur une panne que cette version ne sait pas décrire : relancez-le, ou mettez Supervox à jour.")

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
        let notices: [ConversationNotice] = [
            .notUnderstood, .voiceFellBack, .voiceUnavailable, .proposal, .lastQuestion, .lastWordsLost,
        ]
        var sentences: [String] = []
        for textOnly in [false, true] {
            sentences += phases.map { title($0, textOnly: textOnly) } + phases.map { hint($0, textOnly: textOnly) }.filter { !$0.isEmpty }
        }
        sentences += [cancelHint, concludeLabel, concludeHelp, supervoxLabel, youLabel, holdNote, modeLockedHint]
        sentences += [questionCounter(99, of: 99)]
        sentences += [privacy(provider: forty, voiceProvider: nil), privacy(provider: forty, voiceProvider: forty)]
        sentences += notices.map(notice) + failures.map(turnFailure) + failures.map { notice(.modelFailed($0)) }
        sentences += knownFailureCodes.flatMap { code in [failure(.microphone(code)), failure(.engine(code))] }
        sentences.append(failure(.engine("code-inconnu")))
        return sentences
    }
}
