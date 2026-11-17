import Foundation

/// La porte d'interruption : dit si la personne parle assez fort, assez longtemps, pour couper la parole de l'outil.
///
/// Le détecteur de voix seul ne suffit pas : pendant que l'outil parle, l'écho de sa propre voix qui reste après l'annulation
/// d'écho peut être annoncé comme de la voix. La porte demande en plus un niveau : seules comptent les trames d'au moins `level`
/// dB pleine échelle (`AudioLevel.decibels`), et il en faut `minDuration` secondes depuis le début du passage, à l'intérieur d'une
/// fenêtre glissante de `windowFactor × minDuration` : des trames fortes trop dispersées (clavier, porte) ne coupent pas.
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
    /// La fenêtre glissante dure `windowFactor × minDuration` : la moitié au moins de ses trames doivent être au niveau (choix du
    /// contrôleur au tour de correction 1 de la tâche 6 ; choix non mesuré).
    static let windowFactor = 2.0

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

    /// Vrai si les trames au niveau qui **commencent** à `passageStart` ou après durent `minDuration` au moins à l'intérieur d'une
    /// même fenêtre glissante (voir `passes(from:to:)`). Une trame commencée avant le passage n'en fait pas partie, même si elle le
    /// chevauche.
    public func shouldInterrupt(passageStart: Int) -> Bool {
        passes(from: passageStart, to: Int.max)
    }

    /// Vrai si une fenêtre de `windowFactor × minDuration`, posée n'importe où sur les trames qui commencent à `start` ou après et
    /// finissent à `end` au plus, contient `minDuration` de trames au niveau. Les trames n'ont pas à être consécutives, mais elles
    /// doivent être **proches** : des clics de clavier épars ne s'additionnent plus sur tout un passage (revue de la tâche 6, I-2).
    ///
    /// La fenêtre glisse sur toute la plage, pas seulement sur sa fin : la porte est consultée une fois par bloc du détecteur (en
    /// production 4 096 échantillons, près de 13 trames ; code lu), et un passage se ferme sur le silence qui a fait conclure le
    /// détecteur. Une fenêtre arrêtée à la dernière trame reçue manquerait une salve entre deux consultations, et ne verrait plus
    /// jamais la voix d'un passage fermé.
    func passes(from start: Int, to end: Int) -> Bool {
        // Non numérique ou infinie : aucun passage ne coupe ; nulle ou négative : tout passage coupe.
        guard minDuration.isFinite else { return false }
        let required = minDuration * transcriberSampleRate   // en échantillons
        guard required > 0 else { return true }
        let frame = Double(Self.frameLength)
        // Plus de trames requises qu'il n'en est gardé : jamais atteint (borne avant toute conversion en entier).
        guard required <= Double(Self.maxFrames) * frame else { return false }
        let window = max(Int((Self.windowFactor * required / frame).rounded(.down)), Int((required / frame).rounded(.up)))
        let first = max((max(start, 0) + Self.frameLength - 1) / Self.frameLength - firstFrame, 0)
        let last = min(max(end, 0) / Self.frameLength - firstFrame, loud.count)   // exclu : la trame `last` finit après `end`
        guard first < last else { return false }
        var count = 0
        for index in first..<last {
            if loud[index] { count += 1 }
            if index - window >= first, loud[index - window] { count -= 1 }
            // Comparé en échantillons : 15 trames × 320 = 4 800 = 0,30 × 16 000, sans somme de durées en virgule flottante.
            if Double(count * Self.frameLength) >= required { return true }
        }
        return false
    }

    public mutating func reset() {
        loud = []
        firstFrame = 0
        partial = []
    }
}
