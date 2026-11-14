/// Ce qui reste d'une liste de termes une fois la limite de l'amorce de Whisper appliquée.
enum VocabularyFit {
    enum Outcome: Equatable {
        /// Toute la liste tient (ou elle est vide).
        case fits
        /// Seuls les premiers termes tiennent : `kept` est le plus long début de liste dans la limite (peut être vide).
        case trimmed(kept: [String], of: Int)
        /// La longueur n'a pas pu être comptée (le tokenizer n'est pas sur le disque).
        case unknown
    }

    /// Cherche le plus long début de `terms` dont `count` (nombre de jetons d'amorce) ne dépasse pas `limit`. Un début plus
    /// long ne compte jamais moins : la recherche est dichotomique, car chaque comptage recharge le tokenizer.
    static func fit(_ terms: [String], limit: Int, count: @Sendable ([String]) async -> Int?) async -> Outcome {
        guard !terms.isEmpty else { return .fits }
        guard let total = await count(terms) else { return .unknown }
        if total <= limit { return .fits }
        // Invariant : le début de `low` termes tient (0 terme tient toujours), celui de `high` termes ne tient pas.
        var low = 0
        var high = terms.count
        while high - low > 1 {
            let middle = (low + high) / 2
            guard let size = await count(Array(terms.prefix(middle))) else { break }
            if size <= limit { low = middle } else { high = middle }
        }
        return .trimmed(kept: Array(terms.prefix(low)), of: terms.count)
    }
}
