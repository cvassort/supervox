import Foundation

/// Niveau d'une tranche de son : la formule vit ici, pour la dictée (affichage) comme pour l'entretien (seuil de coupure de parole).
public enum AudioLevel {
    /// Plancher des décibels : rendu pour une tranche vide, nulle ou non numérique, et plancher d'un signal plus bas. Une valeur
    /// de repli, non une mesure (choix non mesuré).
    static let floorDecibels = -120.0

    /// 10·log10 de la puissance moyenne (= 20·log10 de la valeur efficace), en dB pleine échelle. `-120` pour un tableau vide, nul
    /// ou contenant un NaN ; jamais en dessous de `-120`. Un échantillon infini donne `+∞`.
    public static func decibels(of samples: [Float]) -> Double {
        guard !samples.isEmpty else { return floorDecibels }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        guard !power.isNaN, power > 0 else { return floorDecibels }
        return max(10 * log10(power), floorDecibels)
    }

    /// Niveau affichable, entre 0 et 1 : −60 dB → 0, 0 dB → 1. Une tranche vide ou non numérique donne 0.
    public static func display(of samples: [Float]) -> Float {
        let level = (decibels(of: samples) + 60) / 60
        return level.isNaN ? 0 : Float(min(max(level, 0), 1))
    }
}
