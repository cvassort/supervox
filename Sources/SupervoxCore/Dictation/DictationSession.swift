import Foundation

public actor DictationSession {
    /// Niveau affichable d'une tranche : RMS en décibels, ramené sur 0…1 (−60 dB → 0, 0 dB → 1). Une tranche vide ou
    /// non numérique donne 0.
    public static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        let decibels = 10 * log10(power)   // 10·log10 de la puissance = 20·log10 du RMS
        let level = (decibels + 60) / 60
        return level.isNaN ? 0 : Float(min(max(level, 0), 1))
    }
}
