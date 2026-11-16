import Foundation

/// Les options d'un mode dans le fichier de la version 1, sous `modeOptions`. Depuis la version 2, ce choix vit dans chaque
/// `Mode` : ce type ne sert plus qu'à la migration (`AppSettings.init(from:)`, une fois).
///
/// Chaque champ est optionnel : `nil` veut dire « la valeur par défaut du mode ». Le décodage est tolérant : un champ absent
/// vaut `nil`, un champ inconnu est ignoré.
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
