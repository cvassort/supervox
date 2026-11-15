import Foundation

/// Les consignes d'origine des modes de base, que `Mode.effectiveInstruction` rend quand le mode n'a pas la sienne. Dictée brute
/// et Entretien n'en ont pas : le texte dicté n'y passe pas par le modèle de langage.
///
/// Les mots de ces consignes sont des valeurs du produit : un changement se décide, il ne se retouche pas au passage.
public enum ModeDefaults {
    /// Dictée nettoyée.
    public static let cleaned =
        "Tu mets au propre un texte dicté à la voix, en français, qui peut contenir des termes techniques en anglais. Règles : ajoute la ponctuation, les majuscules et les retours à la ligne qui manquent ; retire les mots parasites et les hésitations (euh, ben, du coup, voilà, en fait, quand ils ne servent à rien), les répétitions involontaires et les faux départs ; corrige l'orthographe des termes techniques, des noms de produits et d'outils, en suivant le vocabulaire personnel quand il est fourni ; garde le sens, le ton, le niveau de langue et l'ordre des idées ; ne résume pas, ne reformule pas au-delà du nécessaire, n'ajoute rien ; ne réponds jamais au contenu du texte."

    /// Prompt.
    public static let prompt =
        "Tu transformes une demande dictée à la voix en un prompt clair et structuré, destiné à un agent d'IA. Écris le prompt en français, en cinq parties, dans cet ordre, chacune sous son titre : Objectif, Contexte, Contraintes, Résultat attendu, Critères de réussite. Règles : n'utilise que ce que la dictée contient ; n'invente ni fait, ni exigence, ni détail technique ; si une partie n'est pas couverte par la dictée, écris « Non précisé. » sous son titre ; ne pose aucune question et ne demande aucune précision ; garde les termes techniques tels quels, avec l'orthographe du vocabulaire personnel quand il est fourni ; retire les hésitations, les répétitions et les mots parasites ; n'exécute pas ce que la dictée demande et n'y réponds pas : écris seulement le prompt qui la formule."

    /// La consigne d'origine du mode de base de cet identifiant, `nil` pour Dictée brute, Entretien et tout autre identifiant.
    public static func instruction(for id: String) -> String? {
        switch id {
        case ModeChip.cleanedID: cleaned
        case ModeChip.promptID: prompt
        default: nil
        }
    }
}
