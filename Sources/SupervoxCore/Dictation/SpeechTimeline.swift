import Foundation

/// La « ligne de temps » d'une prise : tout l'audio reçu, et les passages où l'on a parlé selon le détecteur de voix.
///
/// Une struct pure : ni modèle, ni fil, ni horloge. C'est elle qui porte la règle « aucune transcription sans voix
/// détectée » : `spokenClip` et `openClip` rendent `nil` tant que le détecteur n'a rien entendu.
///
/// Les indices sont en échantillons, depuis le début de la prise. Les passages clos sont dans l'ordre et sans
/// chevauchement ; au plus un passage est ouvert (début reçu, fin pas encore reçue), et il vient après tous les clos.
public struct SpeechTimeline: Sendable {
    public let blockSize: Int
    public let sampleRate: Double

    private var audio: [Float] = []
    /// Début, dans `audio`, du prochain bloc à rendre.
    private var nextBlockStart = 0
    public private(set) var closedSegments: [Range<Int>] = []
    public private(set) var openSegmentStart: Int?

    public init(blockSize: Int, sampleRate: Double = 16000) {
        precondition(blockSize > 0, "la taille de bloc doit être positive")
        precondition(sampleRate > 0, "la fréquence doit être positive")
        self.blockSize = blockSize
        self.sampleRate = sampleRate
    }

    /// Ajoute `samples` à l'audio de la prise et rend, dans l'ordre, les blocs complets devenus disponibles. Un bloc
    /// n'est rendu qu'une fois ; la fin incomplète attend le prochain appel.
    public mutating func append(_ samples: [Float]) -> [[Float]] {
        audio += samples
        var blocks: [[Float]] = []
        while nextBlockStart + blockSize <= audio.count {
            blocks.append(Array(audio[nextBlockStart..<(nextBlockStart + blockSize)]))
            nextBlockStart += blockSize
        }
        return blocks
    }

    /// Prend en compte un événement du détecteur. Un événement incohérent est ignoré et l'état précédent est gardé :
    /// deux débuts de suite, une fin sans début, une fin qui ne tombe pas après le début, un début qui chevauche le
    /// dernier passage clos. Un indice hors de l'audio reçu est ramené dans [0, longueur reçue].
    public mutating func apply(_ event: VoiceEvent) {
        switch event {
        case .speechStart(let sample):
            let start = min(max(sample, 0), audio.count)
            guard openSegmentStart == nil, start >= (closedSegments.last?.upperBound ?? 0) else { return }
            openSegmentStart = start
        case .speechEnd(let sample):
            let end = min(max(sample, 0), audio.count)
            guard let start = openSegmentStart, end > start else { return }
            closedSegments.append(start..<end)
            openSegmentStart = nil
        }
    }

    public var hasSpeech: Bool { !closedSegments.isEmpty || openSegmentStart != nil }

    /// Durée de l'audio reçu, en secondes.
    public var duration: Double { Double(audio.count) / sampleRate }

    /// L'audio de `segment`, borné à l'audio reçu.
    public func clip(of segment: Range<Int>) -> AudioClip {
        let lower = min(max(segment.lowerBound, 0), audio.count)
        let upper = min(max(segment.upperBound, lower), audio.count)
        return AudioClip(samples: Array(audio[lower..<upper]), sampleRate: sampleRate)
    }

    /// Le passage ouvert, limité à ses `maxSeconds` dernières secondes ; `nil` sans passage ouvert.
    public func openClip(maxSeconds: Double) -> AudioClip? {
        guard let start = openSegmentStart else { return nil }
        let limit = Int((max(maxSeconds, 0) * sampleRate).rounded())
        return clip(of: max(start, audio.count - limit)..<audio.count)
    }

    /// Du début du premier passage à la fin du dernier (ou à la fin de la prise si un passage est ouvert), élargi de
    /// `padding` secondes de chaque côté et borné à la prise ; `nil` sans voix. Les silences intérieurs sont gardés :
    /// le moteur final reçoit la parole avec son rythme.
    public func spokenClip(padding: Double) -> AudioClip? {
        guard let first = closedSegments.first?.lowerBound ?? openSegmentStart else { return nil }
        let last = openSegmentStart != nil ? audio.count : (closedSegments.last?.upperBound ?? audio.count)
        let pad = Int((max(padding, 0) * sampleRate).rounded())
        return clip(of: max(first - pad, 0)..<min(last + pad, audio.count))
    }
}
