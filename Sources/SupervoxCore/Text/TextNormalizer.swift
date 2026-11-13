/// Normalisation du texte avant comparaison : on neutralise la forme (casse,
/// ponctuation, apostrophes, traits d'union) mais jamais le fond (accents,
/// chiffres écrits en chiffres ou en lettres restent distincts).
public enum TextNormalizer {
    /// Découpe `text` en mots : minuscules, tout caractère qui n'est ni une
    /// lettre ni un chiffre (ponctuation, apostrophes droites ou typographiques,
    /// traits d'union, espaces) sert de séparateur. Accents et chiffres sont conservés.
    public static func words(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
