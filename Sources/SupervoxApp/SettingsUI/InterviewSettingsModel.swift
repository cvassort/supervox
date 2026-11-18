import Foundation
import Observation
import SupervoxCore

/// L'onglet Entretien : le nombre de questions, le gabarit du prompt final et les réglages avancés de l'interruption.
///
/// Les réglages vivent dans `AppSettings.interview` : le modèle n'en garde aucune copie à réécrire. `read` donne les réglages en
/// vigueur, `update` les modifie et les enregistre (en production, `AppController.updateSettings`). Chaque geste écrit **son champ
/// seulement**, sur les réglages en vigueur au moment de l'écriture : un autre champ changé ailleurs entre-temps (le panneau, un
/// autre onglet, le fichier) reste. Après chaque geste, réussi ou non, l'affichage est ce que `read` donne ; un enregistrement refusé
/// le dit dans `message`, par une phrase fixe (jamais par le texte de l'erreur, qui peut porter une adresse). Seule exception : le
/// gabarit que la personne tape, qui reste un brouillon à l'écran jusqu'à `commitTemplate()` et n'est jamais effacé par un refus.
///
/// Les bornes sont celles de `InterviewSettings` : ni ce fichier ni la vue n'en recopient une. Toute valeur écrite passe par
/// `InterviewSettings.normalized`, comme au décodage.
@MainActor @Observable
public final class InterviewSettingsModel {
    public typealias Update = @MainActor ((inout AppSettings) -> Void) throws -> Void

    // MARK: - Textes

    // Chaque phrase passe par `InterviewText.fr` : espaces insécables du français avant « : ; ? ! » et dans « « » ».

    /// L'en-tête du brief, en deux morceaux : la phrase d'introduction (en tête de l'onglet), et le reste (dans le bloc de notes, en
    /// bas : la fenêtre a une hauteur fixe, et ce qui sert à régler passe avant ce qui se lit une fois).
    public static let introduction = InterviewText.fr(
        "L'entretien vous pose des questions à voix haute, une à la fois, puis rédige un prompt à partir de vos réponses.")
    public static let introductionRest = InterviewText.fr(
        "Il passe toujours par la relecture. Les changements s'appliquent au prochain entretien.")
    /// L'en-tête entier, mot pour mot celui du brief.
    public static let header = introduction + " " + introductionRest
    public static let modelsNote = InterviewText.fr(
        "Le modèle rapide pose les questions, le modèle fort rédige le prompt : ils se choisissent en tête de l'onglet Modes.")
    public static let maxQuestionsTitle = "Nombre maximal de questions"
    public static let maxQuestionsNote = InterviewText.fr("Après la réponse à la dernière question, Supervox rédige le prompt.")
    public static let templateTitle = "Gabarit du prompt final"
    public static let restoreTemplateTitle = "Revenir au gabarit d'origine"
    public static let templateNote = InterviewText.fr(
        "Le gabarit dit au modèle fort comment rédiger le prompt. La conversation lui est passée à part, comme une donnée : rien de ce que vous dites ne peut changer ce gabarit."
    )
    public static let advancedTitle = "Réglages avancés"
    public static let turnSilenceTitle = "Silence de fin de tour"
    public static let interruptMinDurationTitle = "Durée de voix pour couper la parole"
    public static let interruptLevelTitle = "Niveau de voix pour couper la parole"
    public static let interruptNote = InterviewText.fr(
        "Si Supervox se coupe en entendant sa propre voix, montez le niveau (vers −20 dB). S'il ne s'arrête pas quand vous parlez, baissez-le."
    )
    public static let restoreAdvancedTitle = "Rétablir les valeurs d'origine"
    /// Ce que l'onglet dit quand l'enregistrement échoue pour une autre raison qu'une `SettingsError`. Le texte de l'erreur n'y est
    /// jamais repris : une erreur d'ailleurs peut porter une adresse.
    public static let saveFailure = InterviewText.fr(
        "Ce changement n'a pas pu être enregistré : l'entretien garde ses réglages précédents.")

    /// La ligne de vie privée de l'onglet (D11). Elle ne cite pas les fournisseurs des deux modèles (le panneau le fait, au lancement
    /// d'un entretien) ; elle cite celui de la voix quand la voix en a un.
    private static let privacyStart = InterviewText.fr(
        "Le texte de vos réponses est envoyé au fournisseur du modèle rapide et du modèle fort ; l'audio du micro ne quitte jamais cet ordinateur."
    )
    private static let systemVoiceSentence = InterviewText.fr(
        "La voix de Supervox est celle du système : rien n'est envoyé pour la produire.")

    // MARK: - Bornes et pas

    // Les bornes sont celles du type ; les pas sont ceux de l'interface (choix de présentation, non mesurés).

    public var maxQuestionsRange: ClosedRange<Int> { InterviewSettings.maxQuestionsRange }
    public var turnSilenceRange: ClosedRange<Double> { InterviewSettings.turnSilenceRange }
    public var interruptMinDurationRange: ClosedRange<Double> { InterviewSettings.interruptMinDurationRange }
    public var interruptLevelRange: ClosedRange<Double> { InterviewSettings.interruptLevelRange }
    public let turnSilenceStep = 0.1
    public let interruptMinDurationStep = 0.05
    public let interruptLevelStep = 1.0

    // MARK: - État

    /// Les réglages tels que `read` les a donnés la dernière fois : tout ce que l'onglet montre en est dérivé.
    private var settings: AppSettings
    /// Le gabarit tel que la personne le tape, pas encore enregistré : `nil` quand elle n'a rien tapé depuis le dernier
    /// enregistrement. Un champ vidé reste vide au lieu de se remplir sous les doigts. Il n'est écrit que par `commitTemplate()`, et
    /// n'est jamais jeté par un refus d'enregistrement, par un autre geste ni par `reload()` : le texte de la personne ne se perd pas.
    private var templateDraft: String?
    public private(set) var message: String?

    @ObservationIgnored private let read: @MainActor () -> AppSettings
    @ObservationIgnored private let update: Update
    @ObservationIgnored private let effectiveTurnSilence: @Sendable (Double) -> Double

    public init(
        read: @escaping @MainActor () -> AppSettings, update: @escaping Update,
        effectiveTurnSilence: @escaping @Sendable (Double) -> Double
    ) {
        self.read = read
        self.update = update
        self.effectiveTurnSilence = effectiveTurnSilence
        settings = read()
    }

    /// Relit les réglages : à chaque présentation de la fenêtre et à chaque affichage de l'onglet, une écriture faite ailleurs s'y
    /// voit. Le message reste (il dit ce qui vient de se passer) ; `clearMessage()` l'efface.
    ///
    /// Un gabarit tapé et pas encore enregistré n'est pas remplacé : en cas de conflit avec un gabarit écrit ailleurs entre-temps, le
    /// texte de la personne reste à l'écran et sera celui qu'`commitTemplate()` enregistre. Un brouillon devenu identique à
    /// l'enregistré est lâché (la suite suit les écritures d'ailleurs).
    public func reload() {
        settings = read()
        if let draft = templateDraft, Self.stored(draft) == settings.interview.template { templateDraft = nil }
    }

    public func clearMessage() {
        message = nil
    }

    // MARK: - Ce que l'onglet montre

    private var shown: InterviewSettings { settings.interview.normalized }

    /// Nombre maximal de questions.
    public var maxQuestions: Int {
        get { shown.maxQuestions }
        set {
            commit {
                var written = $0.interview
                written.maxQuestions = newValue
                $0.interview.maxQuestions = written.normalized.maxQuestions
            }
        }
    }

    /// Le gabarit montré : ce que la personne a tapé et pas encore enregistré, sinon celui des réglages, ou le gabarit d'origine
    /// quand il n'y en a pas. Écrire ne change que le brouillon : rien n'est enregistré avant `commitTemplate()`.
    public var template: String {
        get { templateDraft ?? settings.interview.template ?? InterviewPrompt.defaultTemplate }
        set { templateDraft = newValue }
    }

    /// Un texte vide ou égal, mot pour mot, au gabarit d'origine s'enregistre `nil` ; un autre tel quel.
    private static func stored(_ text: String) -> String? {
        text == InterviewPrompt.defaultTemplate || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Enregistre le brouillon du gabarit, une seule fois. Appelée quand le champ perd la main, quand l'onglet disparaît, à la
    /// fermeture de la fenêtre et à Quitter. Sans brouillon, ou avec un brouillon qui dit déjà ce que les réglages en vigueur disent,
    /// n'écrit rien. Refusé : le brouillon reste, la phrase d'échec est posée, et un nouvel appel réessaie.
    public func commitTemplate() {
        guard let draft = templateDraft else { return }
        let value = Self.stored(draft)
        if value == read().interview.template {
            settings = read()
            templateDraft = nil
            return
        }
        if commit({
            var written = $0.interview
            written.template = value
            $0.interview.template = written.normalized.template
        }) {
            templateDraft = nil
        }
    }

    /// Le gabarit montré est le gabarit d'origine (le bouton « Revenir au gabarit d'origine » est alors grisé).
    public var isDefaultTemplate: Bool { template == InterviewPrompt.defaultTemplate }

    /// Enregistre `nil` : le gabarit d'origine revient, et le brouillon avec lui. Refusé : le texte de la personne reste à l'écran.
    public func restoreTemplate() {
        let previous = templateDraft
        templateDraft = nil
        if !commit({ $0.interview.template = nil }) { templateDraft = previous }
    }

    /// Silence de fin de tour, en secondes.
    public var turnSilence: Double {
        get { shown.turnSilence }
        set {
            let value = Self.hundredths(newValue)
            commit {
                var written = $0.interview
                written.turnSilence = value
                $0.interview.turnSilence = written.normalized.turnSilence
            }
        }
    }

    /// Durée de voix qui coupe la parole de Supervox, en secondes.
    public var interruptMinDuration: Double {
        get { shown.interruptMinDuration }
        set {
            let value = Self.hundredths(newValue)
            commit {
                var written = $0.interview
                written.interruptMinDuration = value
                $0.interview.interruptMinDuration = written.normalized.interruptMinDuration
            }
        }
    }

    /// Niveau de voix qui coupe la parole de Supervox, en dB.
    public var interruptLevel: Double {
        get { shown.interruptLevel }
        set {
            let value = Self.hundredths(newValue)
            commit {
                var written = $0.interview
                written.interruptLevel = value
                $0.interview.interruptLevel = written.normalized.interruptLevel
            }
        }
    }

    /// Les valeurs montrées à côté des contrôles.
    public var turnSilenceLabel: String { Self.decimal(turnSilence) + " s" }
    public var interruptMinDurationLabel: String { Self.decimal(interruptMinDuration) + " s" }
    /// Entier, avec le signe moins typographique (U+2212) : le niveau est négatif.
    public var interruptLevelLabel: String {
        let level = Int(interruptLevel.rounded())
        return (level < 0 ? "\u{2212}\(-level)" : "\(level)") + " dB"
    }

    /// Remet les trois réglages avancés à leur valeur d'origine, en un seul enregistrement ; ni le nombre de questions ni le
    /// gabarit ne bougent.
    public func restoreAdvanced() {
        let defaults = InterviewSettings.defaults
        commit {
            $0.interview.turnSilence = defaults.turnSilence
            $0.interview.interruptMinDuration = defaults.interruptMinDuration
            $0.interview.interruptLevel = defaults.interruptLevel
        }
    }

    /// « n s demandées, m s en pratique : … » : le silence demandé et celui que le détecteur de voix applique réellement. Il compte par
    /// blocs de 0,256 s (4 096 échantillons à 16 kHz, code lu : `VadManager.chunkSize` et `sampleRate`) : de 0,30 à 0,51 s demandées,
    /// la valeur en pratique est la même. `SupervoxApp` ne voit pas le détecteur, d'où ce chiffre écrit ici et la fonction injectée.
    /// Deux décimales, virgule.
    public var effectiveSilenceText: String {
        let requested = turnSilence
        let practical = effectiveTurnSilence(requested)
        return InterviewText.fr(
            "\(Self.decimal(requested)) s demandées, \(Self.decimal(practical)) s en pratique : le détecteur de voix compte par tranches de 0,256 s."
        )
    }

    /// La ligne de vie privée : où part le texte, et que l'audio reste ici. Le fournisseur de la voix n'est nommé que si
    /// `VoiceChoice.route(in:)` dit qu'il parle ; sinon (voix du système, fournisseur supprimé, sans synthèse, voix incomplète)
    /// l'entretien prend la voix du système, et la ligne le dit. Une clé absente ne se voit pas d'ici (le trousseau n'est pas lu) :
    /// la ligne nomme alors un fournisseur qui ne recevra rien, sur-avertissement admis (voir `route(in:)`).
    public var privacyText: String {
        let voiceSentence: String
        switch settings.voice.route(in: settings) {
        case .provider(let provider, _):
            voiceSentence = InterviewText.fr(
                "La voix de Supervox vient de « \(Provider.shortName(provider.name)) » : le texte qu'elle dit lui est envoyé.")
        case .system:
            voiceSentence = Self.systemVoiceSentence
        }
        return Self.privacyStart + " " + voiceSentence
    }

    /// La note de maintien (tâche 8) : montrée quand le raccourci est réglé en « maintien ».
    public var holdNote: String? { settings.hotKeyBehavior == .hold ? InterviewText.holdNote : nil }

    // MARK: - Écriture

    /// Appelle `update` une fois. Réussi : le message s'efface. Refusé : le message le dit, et l'affichage est relu.
    @discardableResult
    private func commit(_ change: (inout AppSettings) -> Void) -> Bool {
        do {
            try update(change)
            message = nil
            settings = read()
            return true
        } catch {
            message = (error as? SettingsError)?.errorDescription ?? Self.saveFailure
            settings = read()
            return false
        }
    }

    /// Arrondit au centième (choix : les pas de l'interface, 0,1 / 0,05 / 1, sont des multiples du centième) : un contrôle à pas additionne mal (0,7 + 0,1 = 0,7999999999999999), et la valeur écrite dans le fichier
    /// doit être celle que la personne voit.
    private static func hundredths(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// Deux décimales, virgule, quelle que soit la langue du système.
    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value).replacingOccurrences(of: ".", with: ",")
    }
}
