/// Décompte des erreurs d'une transcription par rapport à une référence.
public struct ErrorCounts: Equatable, Sendable {
    public let substitutions: Int
    public let deletions: Int
    public let insertions: Int
    /// Nombre de mots de la référence (N).
    public let referenceCount: Int

    public init(substitutions: Int, deletions: Int, insertions: Int, referenceCount: Int) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceCount = referenceCount
    }

    /// (S + D + I) / N. Peut dépasser 1. Si N = 0 : 0 sans insertion, 1 sinon.
    public var rate: Double {
        let errors = substitutions + deletions + insertions
        if referenceCount == 0 { return insertions == 0 ? 0 : 1 }
        return Double(errors) / Double(referenceCount)
    }
}

/// Taux d'erreur de mots (WER) par distance d'édition au niveau des mots.
public enum WordErrorRate {
    public static func compute(reference: String, hypothesis: String) -> ErrorCounts {
        let ref = TextNormalizer.words(reference)
        let hyp = TextNormalizer.words(hypothesis)

        // cost[i][j] : distance d'édition entre les i premiers mots de ref et les j premiers de hyp.
        var cost = Array(repeating: Array(repeating: 0, count: hyp.count + 1), count: ref.count + 1)
        for i in 0...ref.count { cost[i][0] = i }
        for j in 0...hyp.count { cost[0][j] = j }
        for i in stride(from: 1, through: ref.count, by: 1) {
            for j in stride(from: 1, through: hyp.count, by: 1) {
                let diagonal = cost[i - 1][j - 1] + (ref[i - 1] == hyp[j - 1] ? 0 : 1)
                cost[i][j] = min(diagonal, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            }
        }

        // Remontée du chemin : à coût égal, on préfère la diagonale (accord ou substitution),
        // puis la suppression, puis l'insertion. S + D + I vaut toujours cost[N][M] ;
        // seule la répartition entre types peut varier entre chemins de même coût.
        var substitutions = 0, deletions = 0, insertions = 0
        var i = ref.count, j = hyp.count
        while i > 0 || j > 0 {
            if i > 0, j > 0 {
                let isMatch = ref[i - 1] == hyp[j - 1]
                if cost[i][j] == cost[i - 1][j - 1] + (isMatch ? 0 : 1) {
                    if !isMatch { substitutions += 1 }
                    i -= 1; j -= 1
                    continue
                }
            }
            if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                deletions += 1
                i -= 1
            } else {
                insertions += 1
                j -= 1
            }
        }
        return ErrorCounts(substitutions: substitutions, deletions: deletions,
                           insertions: insertions, referenceCount: ref.count)
    }
}

/// Rappel des termes techniques : un terme est trouvé si sa suite de mots
/// normalisés apparaît de façon contiguë dans la transcription normalisée.
public enum TermRecall {
    /// `total` vaut `terms.count`. Un terme sans aucun mot après normalisation
    /// (vide, ponctuation seule) n'est jamais trouvé : il ne peut pas être vérifié.
    public static func compute(terms: [String], hypothesis: String) -> (found: Int, total: Int) {
        let hyp = TextNormalizer.words(hypothesis)
        let found = terms.filter { term in
            let words = TextNormalizer.words(term)
            return !words.isEmpty && containsContiguously(hyp, words)
        }.count
        return (found, terms.count)
    }

    private static func containsContiguously(_ haystack: [String], _ needle: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { start in
            Array(haystack[start..<(start + needle.count)]) == needle
        }
    }
}
