import Foundation

/// Les options d'un mode, enregistrées dans `settings.json` sous `AppSettings.modeOptions`.
///
/// Chaque champ est optionnel : `nil` veut dire « la valeur par défaut du mode ». Le décodage est tolérant (voir la règle
/// d'évolution de `AppSettings`) : un champ absent vaut `nil`, un champ inconnu est ignoré, pour que l'étape suivante y
/// ajoute les siens sans changer `AppSettings.current`.
public struct ModeOptions: Codable, Equatable, Sendable {
    /// Montrer le texte dans le panneau pour relecture avant de le coller. `nil` : le défaut du mode
    /// (`AppSettings.reviewDefault`).
    public var reviewBeforePaste: Bool?

    public init(reviewBeforePaste: Bool? = nil) {
        self.reviewBeforePaste = reviewBeforePaste
    }

    private enum CodingKeys: String, CodingKey { case reviewBeforePaste }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reviewBeforePaste = try container.decodeIfPresent(Bool.self, forKey: .reviewBeforePaste)
    }
}
