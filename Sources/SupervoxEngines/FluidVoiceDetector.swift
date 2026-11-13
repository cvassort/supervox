import FluidAudio
import Foundation
import SupervoxCore

/// Détection de voix par `VadManager` de FluidAudio (modèle Silero VAD v6 converti pour Core ML), sur un clip entier :
/// `VadManager.segmentSpeech(_:config:)`.
///
/// Ce que fait la bibliothèque (FluidAudio 0.18.3, `VadManager+SpeechSegmentation.swift`) : le clip est découpé en
/// tranches de 4096 échantillons (256 ms à 16 kHz) ; le modèle rend une probabilité de voix par tranche, rapportée au
/// début de la tranche. La voix commence à la première tranche dont la probabilité atteint le seuil d'entrée (0,85,
/// `VadConfig.defaultThreshold`) et s'arrête au début de la première tranche sous le seuil de sortie (0,85 − 0,15 =
/// 0,70), si au moins `minSilenceDuration` de tranches sous ce seuil suivent. Les bornes tombent donc sur une grille
/// de 256 ms : la fin de voix est placée au début de la tranche où la voix a cessé d'être reconnue.
///
/// Mesuré (tests d'intégration, voix de synthèse de `say` suivie de silence numérique, 3 phrases × 4 calages sur la
/// grille) : la fin placée est toujours en retard sur la vraie fin, de 0,045 à 0,314 s. Le modèle juge encore « voix »
/// la tranche qui suit la fin, même quand elle ne contient que du silence (traînée du modèle récurrent) : le retard
/// peut donc dépasser une tranche. Jamais en avance sur ces mesures : couper le clip à cet instant ne coupe pas de mot.
///
/// Réglages choisis, différents des défauts de la bibliothèque :
/// - `speechPadding` à 0 (défaut 0,1 s) : le défaut repousse chaque fin de 100 ms ; on veut l'instant où le modèle
///   cesse d'entendre de la voix, pas une marge.
/// - `minSilenceDuration` à 0,25 s (défaut 0,75 s) : un passage encore ouvert en fin de clip est fermé à la fin du
///   clip, quel que soit le silence en attente. Avec 0,75 s, il faut 4 tranches sous le seuil (plus d'1 s de clip)
///   pour fermer ; avec 0,25 s, 2 tranches (512 ms). Une pause plus courte à l'intérieur d'une phrase peut couper la
///   voix en deux passages : sans effet ici, on ne lit que le début du premier et la fin du dernier.
/// Les autres réglages sont ceux de la bibliothèque (voix d'au moins 0,15 s, passage coupé au-delà de 14 s).
public actor FluidVoiceDetector: VoiceDetector {
    public static let segmentation = VadSegmentationConfig(minSilenceDuration: 0.25, speechPadding: 0)

    /// Pas du modèle : une probabilité de voix par tranche de cette durée (0,256 s).
    public static let hopSeconds = Double(VadManager.chunkSize) / Double(VadManager.sampleRate)

    /// Les réglages qui déplacent les bornes, pour les rapports.
    public static var conditions: String {
        let hop = hopSeconds
        let entry = VadConfig.default.defaultThreshold
        let exit = segmentation.effectiveNegativeThreshold(baseThreshold: entry)
        return "Silero VAD (FluidAudio), tranches de \(Int(hop * 1000)) ms, seuil d'entrée \(String(format: "%.2f", entry).replacingOccurrences(of: ".", with: ",")), "
            + "de sortie \(String(format: "%.2f", exit).replacingOccurrences(of: ".", with: ",")), silence de fermeture \(Int(segmentation.minSilenceDuration * 1000)) ms, "
            + "sans marge autour de la voix : la fin de voix tombe sur une grille de \(Int(hop * 1000)) ms, en retard sur "
            + "la vraie fin (0,045 à 0,314 s mesurés sur voix de synthèse : le modèle entend encore de la voix dans la "
            + "tranche qui suit)"
    }

    private var manager: VadManager?

    public init() {}

    /// Charge le modèle (téléchargé au premier usage). Les appels suivants ne rechargent rien.
    public func prepare() async throws {
        if manager != nil { return }
        manager = try await VadManager()
    }

    public func segments(in clip: AudioClip) async throws -> [SpeechSegment] {
        try await prepare()
        guard let manager else { throw TranscriberError.engine("détecteur de voix non chargé") }
        let rate = Double(VadManager.sampleRate)
        let samples = clip.sampleRate == rate ? clip.samples : Resampler.resample(clip, to: rate).samples
        guard !samples.isEmpty else { return [] }
        return try await manager.segmentSpeech(samples, config: Self.segmentation)
            .map { SpeechSegment(start: $0.startTime, end: $0.endTime) }
    }
}
