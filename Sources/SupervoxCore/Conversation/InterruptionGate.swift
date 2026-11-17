import Foundation

/// La porte d'interruption : dit si la personne parle assez fort, assez longtemps, pour couper la parole de l'outil.
///
/// Le détecteur de voix seul ne suffit pas : pendant que l'outil parle, l'écho de sa propre voix qui reste après l'annulation
/// d'écho peut être annoncé comme de la voix. La porte demande en plus un niveau : seules comptent les trames d'au moins `level`
/// dB pleine échelle (`AudioLevel.decibels`), et il en faut `minDuration` secondes depuis le début du passage.
///
/// Struct pure, sans horloge : la durée est comptée **en échantillons** (une trame vaut 320 échantillons), jamais en temps machine.
/// L'audio est à 16 kHz (`transcriberSampleRate`, celui de la ligne de temps de l'entretien), et les indices d'échantillons sont
/// ceux de l'audio reçu depuis la création ou le dernier `reset()` : l'appelant remet la porte à zéro en même temps que sa ligne
/// de temps, pour que le début d'un passage (`SpeechTimeline.openSegmentStart`) désigne le même échantillon des deux côtés.
public struct InterruptionGate: Sendable {
    /// 20 ms à 16 kHz (valeur du brief de la tâche 6 ; choix non mesuré).
    static let frameLength = 320
    /// 30 s de trames au plus (valeur du brief ; choix non mesuré) : la mémoire de la porte est bornée, quelle que soit la durée de
    /// l'entretien. Une trame plus ancienne ne compte plus, même si le passage a commencé avant elle.
    static let maxFrames = 1_500

    let minDuration: Double
    let level: Double

    /// Pour chaque trame gardée : son niveau atteint-il `level` ?
    private var loud: [Bool] = []
    /// Le rang, depuis la remise à zéro, de la première trame gardée (`loud[0]`) : les rangs restent absolus après la coupe des 30 s.
    private var firstFrame = 0
    /// Le début d'une trame pas encore complète (moins de 320 échantillons).
    private var partial: [Float] = []

    /// - Parameters:
    ///   - minDuration: secondes de voix au niveau requises (réglage `interruptMinDuration`). Nulle ou négative, tout passage coupe ;
    ///     non numérique, aucun ne coupe.
    ///   - level: dB pleine échelle (réglage `interruptLevel`).
    public init(minDuration: Double, level: Double) {
        self.minDuration = minDuration
        self.level = level
    }

    /// Ajoute de l'audio à 16 kHz, à la suite de ce qui a été reçu, et garde le niveau de chaque trame complète.
    public mutating func append(_ samples: [Float]) {
        partial += samples
        var start = 0
        while partial.count - start >= Self.frameLength {
            let frame = Array(partial[start..<(start + Self.frameLength)])
            loud.append(AudioLevel.decibels(of: frame) >= level)
            start += Self.frameLength
        }
        partial.removeFirst(start)
        if loud.count > Self.maxFrames {
            let excess = loud.count - Self.maxFrames
            loud.removeFirst(excess)
            firstFrame += excess
        }
    }

    /// Vrai si les trames au niveau qui **commencent** à `passageStart` ou après durent ensemble `minDuration` au moins (une trame
    /// commencée avant le passage n'en fait pas partie, même si elle le chevauche). Les trames n'ont pas à être consécutives.
    public func shouldInterrupt(passageStart: Int) -> Bool {
        let firstOfPassage = (max(passageStart, 0) + Self.frameLength - 1) / Self.frameLength
        let from = max(firstOfPassage - firstFrame, 0)
        let count = from < loud.count ? loud[from...].filter { $0 }.count : 0
        // Comparé en échantillons : 15 trames × 320 = 4 800 = 0,30 × 16 000, sans somme de durées en virgule flottante.
        return Double(count * Self.frameLength) >= minDuration * transcriberSampleRate
    }

    public mutating func reset() {
        loud = []
        firstFrame = 0
        partial = []
    }
}
