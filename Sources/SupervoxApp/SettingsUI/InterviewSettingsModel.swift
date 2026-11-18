import Foundation
import Observation
import SupervoxCore

/// L'onglet Entretien : le nombre de questions, le gabarit du prompt final et les réglages avancés de l'interruption.
///
/// Les réglages vivent dans `AppSettings.interview` : le modèle n'en garde aucune copie à réécrire. `read` donne les réglages en
/// vigueur, `update` les modifie et les enregistre (en production, `AppController.updateSettings`). Chaque geste écrit **son champ
/// seulement**, sur les réglages en vigueur au moment de l'écriture : un autre champ changé ailleurs entre-temps (le panneau, un
/// autre onglet, le fichier) reste. Après chaque geste, réussi ou non, l'affichage est ce que `read` donne ; un enregistrement refusé
/// le dit dans `message`, par une phrase fixe (jamais par le texte de l'erreur, qui peut porter une adresse).
///
/// Les bornes sont celles de `InterviewSettings` : ni ce fichier ni la vue n'en recopient une. Toute valeur écrite passe par
/// `InterviewSettings.normalized`, comme au décodage.
@MainActor @Observable
public final class InterviewSettingsModel {
    public typealias Update = @MainActor ((inout AppSettings) -> Void) throws -> Void

    // MARK: - Textes

    // Chaque phrase passe par `InterviewText.fr` : espaces insécables du français avant « : ; ? ! » et dans « « » ».

    public static let header = InterviewText.fr(
        "L'entretien vous pose des questions à voix haute, une à la fois, puis rédige un prompt à partir de vos réponses. Il passe toujours par la relecture. Les changements s'appliquent au prochain entretien."
    )
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
    /// Le gabarit tel que la personne le tape, tant qu'il diffère de ce que les réglages en disent : un champ vidé reste vide
    /// (l'enregistré est alors `nil`, le gabarit d'origine) au lieu de se remplir sous les doigts. Effacé par `reload`, par un
    /// retour au gabarit d'origine et par un enregistrement refusé.
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
    public func reload() {
        settings = read()
        templateDraft = nil
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

    /// Le gabarit montré : celui des réglages, ou le gabarit d'origine quand il n'y en a pas ; ce que la personne tape tant qu'elle
    /// tape. Écrire enregistre `nil` quand le texte est vide ou égal, mot pour mot, au gabarit d'origine.
    public var template: String {
        get { templateDraft ?? settings.interview.template ?? InterviewPrompt.defaultTemplate }
        set {
            templateDraft = newValue
            let isOriginal = newValue == InterviewPrompt.defaultTemplate
            if !commit({
                var written = $0.interview
                written.template = isOriginal ? nil : newValue
                $0.interview.template = written.normalized.template
            }) {
                templateDraft = nil
            }
        }
    }

    /// Le gabarit montré est le gabarit d'origine (le bouton « Revenir au gabarit d'origine » est alors grisé).
    public var isDefaultTemplate: Bool { template == InterviewPrompt.defaultTemplate }

    /// Enregistre `nil` : le gabarit d'origine revient.
    public func restoreTemplate() {
        templateDraft = nil
        commit { $0.interview.template = nil }
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

    /// « n s demandées, m s en pratique : … » : le silence demandé et celui que le détecteur de voix applique réellement (il compte
    /// par blocs de 0,256 s : de 0,30 à 0,51 s demandées, la valeur en pratique est la même). Deux décimales, virgule.
    public var effectiveSilenceText: String {
        let requested = turnSilence
        let practical = effectiveTurnSilence(requested)
        return InterviewText.fr(
            "\(Self.decimal(requested)) s demandées, \(Self.decimal(practical)) s en pratique : le détecteur de voix compte par tranches de 0,256 s."
        )
    }

    /// La ligne de vie privée : où part le texte, et que l'audio reste ici. La voix d'un fournisseur est nommée quand le fournisseur
    /// existe encore ; sinon l'entretien prend la voix du système, et la ligne le dit.
    public var privacyText: String {
        let voiceSentence: String
        if settings.voice.usesProvider,
            let provider = settings.providers.first(where: { $0.id == settings.voice.providerID })
        {
            voiceSentence = InterviewText.fr(
                "La voix de Supervox vient de « \(Provider.shortName(provider.name)) » : le texte qu'elle dit lui est envoyé.")
        } else {
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
            templateDraft = nil
            return false
        }
    }

    /// Arrondit au centième : un contrôle à pas additionne mal (0,7 + 0,1 = 0,7999999999999999), et la valeur écrite dans le fichier
    /// doit être celle que la personne voit.
    private static func hundredths(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    /// Deux décimales, virgule, quelle que soit la langue du système.
    private static func decimal(_ value: Double) -> String {
        String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value).replacingOccurrences(of: ".", with: ",")
    }
}
