import FluidAudio
import Foundation
import SupervoxCore

/// Détection de voix au fil de l'eau par `VadManager` de FluidAudio (Silero VAD v6, Core ML), même modèle et mêmes
/// seuils que `FluidVoiceDetector` : `VadManager.processStreamingChunk` (FluidAudio 0.18.3,
/// `VadManager+Streaming.swift`).
///
/// Ce que fait la bibliothèque : chaque bloc de 4096 échantillons (256 ms à 16 kHz) reçoit une probabilité de voix.
/// - `speechStart` : au premier bloc dont la probabilité atteint le seuil d'entrée ; l'indice rendu est le début de ce
///   bloc (moins `speechPadding`, ici 0).
/// - `speechEnd` : quand la probabilité est restée sous le seuil de sortie pendant au moins `minSilence` ; l'indice
///   rendu est le début du premier bloc sous ce seuil (plus `speechPadding`, ici 0). L'événement date donc la fin au
///   début du silence, mais n'arrive que plus tard : la bibliothèque compte `minSilence` à partir de la fin du premier
///   bloc silencieux, il faut donc 1 + ⌈`minSilence` / 0,256 s⌉ blocs silencieux, soit 4 blocs (1,024 s) avec 0,6 s.
///   Mesuré (voix de synthèse, 3 phrases × 4 calages) : une seconde de silence après la voix ne suffit jamais, 1,5 s
///   suffit toujours ; le passage reste alors ouvert dans `SpeechTimeline`, ce qui est sans conséquence pour
///   `spokenClip`, qui l'arrête à la fin de la prise.
/// Les indices comptent les échantillons reçus depuis le début de la prise (`reset()`), pas depuis l'appel en cours.
///
/// `speechPadding` à 0 (défaut de la bibliothèque : 0,1 s) : l'instant donné est celui où le modèle entend la voix
/// commencer ou cesser ; la marge autour de la parole est l'affaire de `SpeechTimeline.spokenClip(padding:)`.
///
/// L'état de flux (modèle récurrent, voix en cours, silence en attente) est gardé ici, d'un bloc à l'autre : les
/// appels à `process` se font l'un après l'autre. Le détecteur étant un acteur, un appel concurrent entrerait pendant
/// l'attente du modèle et ferait perdre l'état d'un des deux blocs ; l'appelant (la session de dictée) les sérialise.
public actor FluidStreamingVoiceDetector: StreamingVoiceDetector {
    /// Silence qui ferme un passage de voix, en secondes. 0,6 s : une pause de respiration au milieu d'une phrase
    /// ne coupe pas le passage ; la valeur du défaut de la bibliothèque (0,75 s) rend la fin plus tardive.
    public let minSilence: Double

    public nonisolated var blockSize: Int { VadManager.chunkSize }

    private var manager: VadManager?
    private var state: VadStreamState?

    public init(minSilence: Double = 0.6) {
        self.minSilence = minSilence
    }

    public func prepare() async throws {
        if manager != nil { return }
        let loaded = try await VadManager()
        manager = loaded
        state = await loaded.makeStreamState()
    }

    public func reset() async {
        state = await manager?.makeStreamState()
    }

    public func process(_ block: [Float]) async throws -> VoiceEvent? {
        guard block.count == blockSize else {
            // `VadManager` complèterait un bloc court avec du silence : les indices des événements suivants dériveraient.
            throw TranscriberError.engine("bloc de \(block.count) échantillons, \(blockSize) attendus")
        }
        try await prepare()
        guard let manager, let current = state else { throw TranscriberError.engine("détecteur de voix non chargé") }
        let config = VadSegmentationConfig(minSilenceDuration: minSilence, speechPadding: 0)
        let result = try await manager.processStreamingChunk(block, state: current, config: config)
        state = result.state
        guard let event = result.event else { return nil }
        switch event.kind {
        case .speechStart: return .speechStart(sample: event.sampleIndex)
        case .speechEnd: return .speechEnd(sample: event.sampleIndex)
        }
    }
}
