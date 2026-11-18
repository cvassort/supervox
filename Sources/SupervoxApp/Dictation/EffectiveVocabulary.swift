import SupervoxCore

/// Le vocabulaire personnel qu'une transcription reçoit vraiment, et l'avis qui le dit. Une seule règle pour la dictée
/// (`DictationController`) et pour l'entretien (la préparation de l'environnement réel) :
/// - le petit modèle de vocabulaire n'a pas pu être téléchargé : aucun terme (Parakeet irait sinon le chercher lui-même, hors du
///   catalogue, et lèverait s'il échoue) ;
/// - WhisperKit avec une liste : le plus long début de liste qui tient dans l'amorce (`VocabularyFit`) ; aucun terme si sa longueur
///   ne se compte pas (le moteur refuserait une liste trop longue à chaque transcription, après que la personne a parlé) ;
/// - sinon, la liste part telle quelle.
public struct EffectiveVocabulary: Equatable, Sendable {
    /// Ce que la phrase de l'avis nomme.
    public enum Activity: Sendable {
        case dictation
        case interview

        /// « à cette dictée » ou « à cet entretien ».
        fileprivate var this: String {
            switch self {
            case .dictation: "cette dictée"
            case .interview: "cet entretien"
            }
        }

        fileprivate var next: String {
            switch self {
            case .dictation: "à la prochaine dictée"
            case .interview: "au prochain entretien"
            }
        }

        /// Les phrases de la dictée gardent leurs espaces ordinaires (celles d'avant l'extraction) ; celles de l'entretien passent par
        /// la typographie de `InterviewText`, comme toutes ses phrases.
        fileprivate func typeset(_ text: String) -> String {
            switch self {
            case .dictation: text
            case .interview: InterviewText.fr(text)
            }
        }
    }

    /// Les termes envoyés au moteur.
    public var terms: [String]
    /// L'avis à montrer ; `nil` quand la liste part entière.
    public var notice: String?

    public init(terms: [String], notice: String?) {
        self.terms = terms
        self.notice = notice
    }

    /// La règle. `nil` : rien à décider, la liste des réglages part telle quelle et rien n'est à dire (ni compté).
    ///
    /// - Parameters:
    ///   - vocabularyModelUnavailable: le petit modèle de vocabulaire ne s'est pas téléchargé (`ModelDownloadOutcome`).
    ///   - limit: la place de l'amorce de WhisperKit, en jetons.
    ///   - count: le nombre de jetons d'amorce de ces termes pour cette variante de Whisper ; `nil` si le tokenizer manque.
    public static func resolve(
        for settings: TranscriptionSettings, vocabularyModelUnavailable: Bool, activity: Activity, limit: Int,
        count: @escaping @Sendable ([String], String) async -> Int?
    ) async -> EffectiveVocabulary? {
        if vocabularyModelUnavailable {
            return EffectiveVocabulary(terms: [], notice: modelUnavailableNotice(activity))
        }
        guard settings.engine == .whisperKit, !settings.vocabulary.isEmpty else { return nil }
        let model = settings.whisperModel
        switch await VocabularyFit.fit(settings.vocabulary, limit: limit, count: { await count($0, model) }) {
        case .fits:
            return EffectiveVocabulary(terms: settings.vocabulary, notice: nil)
        case .trimmed(let kept, let total):
            return EffectiveVocabulary(terms: kept, notice: trimmedNotice(kept: kept.count, of: total, activity))
        case .unknown:
            return EffectiveVocabulary(terms: [], notice: uncountableNotice(activity))
        }
    }

    // MARK: Les phrases

    public static func uncountableNotice(_ activity: Activity) -> String {
        activity.typeset(
            "Le vocabulaire n'a pas servi à \(activity.this) : sa longueur n'a pas pu être vérifiée avec ce modèle.")
    }

    public static func modelUnavailableNotice(_ activity: Activity) -> String {
        activity.typeset(
            "Le vocabulaire n'a pas servi à \(activity.this) : le petit modèle qui le reconnaît n'a pas pu être téléchargé. Il sera retenté \(activity.next).")
    }

    public static func trimmedNotice(kept: Int, of total: Int, _ activity: Activity) -> String {
        let used =
            switch kept {
            case 0: "aucun terme n'a pu servir"
            case 1: "seul le premier terme sur \(total) sert"
            default: "seuls les \(kept) premiers termes sur \(total) servent"
            }
        return activity.typeset(
            "Vocabulaire trop long pour ce modèle : \(used) à \(activity.this). Raccourcissez la liste dans Réglages, onglet Transcription.")
    }
}
