import Observation

/// L'onglet Modes : une ligne par mode, avec l'interrupteur « Relire avant de coller ».
///
/// Chaque bascule enregistre tout le dictionnaire d'options (les modes que cette version ne connaît pas y restent). Si
/// l'enregistrement échoue, la ligne garde son ancienne valeur et `message` le dit. Entretien est toujours relu : sa
/// ligne n'a pas d'interrupteur, et aucune bascule ne l'atteint.
@MainActor @Observable
public final class ModesModel {
    /// Une ligne de l'onglet.
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        /// Vrai si le texte de ce mode passe par la relecture.
        public var reviews: Bool
        /// Vrai si la ligne n'a pas d'interrupteur : le choix n'est pas à l'utilisateur.
        public let isLocked: Bool
        /// Ce que la ligne dit en plus de son titre, ou `nil`.
        public let note: String?
    }

    public typealias Save = @MainActor ([String: ModeOptions]) throws -> Void

    /// La phrase d'en-tête de l'onglet.
    public static let header =
        "Quand la relecture est activée, le texte s'affiche dans le panneau à la fin de la dictée : vous pouvez le corriger au clavier, puis choisir « Coller » ou « Copier ». Rien n'est collé sans votre geste."
    public static let toggleTitle = "Relire avant de coller"
    public static let alwaysReviewedNote = "Toujours relu : l'entretien passe toujours par la relecture."
    public static let laterModeNote = "Ce mode arrive à une étape suivante ; ce réglage vaudra dès qu'il sera là."
    /// Ce que l'onglet dit quand l'enregistrement échoue pour une autre raison qu'une `SettingsError`. Le texte de l'erreur
    /// n'y est jamais repris : une erreur d'ailleurs peut porter une adresse.
    public static let saveFailure = "Ce réglage n'a pas pu être enregistré : il garde sa valeur précédente."

    public private(set) var rows: [Row]
    public private(set) var message: String?

    @ObservationIgnored private var options: [String: ModeOptions]
    @ObservationIgnored private let save: Save

    /// `modes` : les pastilles du panneau, dans l'ordre. `options` : `AppSettings.modeOptions`.
    public init(modes: [ModeChip], options: [String: ModeOptions], save: @escaping Save) {
        self.options = options
        self.save = save
        rows = modes.map { Self.row($0, options: options) }
    }

    private static func row(_ mode: ModeChip, options: [String: ModeOptions]) -> Row {
        let note: String?
        switch mode.id {
        case ModeChip.interviewID: note = alwaysReviewedNote
        case ModeChip.cleanedID, ModeChip.promptID: note = laterModeNote
        default: note = nil
        }
        return Row(
            id: mode.id, title: mode.title, reviews: AppSettings.reviews(mode.id, options: options),
            isLocked: AppSettings.alwaysReviewed.contains(mode.id), note: note)
    }

    /// Change le choix d'un mode. Sans effet pour un mode toujours relu, un mode inconnu, ou une valeur déjà montrée.
    public func setReview(_ on: Bool, for modeID: String) {
        guard let index = rows.firstIndex(where: { $0.id == modeID }), !rows[index].isLocked,
            rows[index].reviews != on
        else { return }
        var updated = options
        updated[modeID, default: ModeOptions()].reviewBeforePaste = on
        do {
            try save(updated)
        } catch {
            message = Self.message(for: error)
            return
        }
        options = updated
        rows[index].reviews = on
        message = nil
    }

    private static func message(for error: any Error) -> String {
        (error as? SettingsError)?.errorDescription ?? saveFailure
    }
}
