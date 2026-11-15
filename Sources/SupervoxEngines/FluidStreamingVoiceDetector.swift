import FluidAudio
import Foundation
import SupervoxCore

/// Détection de voix au fil de l'eau par `VadManager` de FluidAudio (Silero VAD v6, Core ML), même modèle et mêmes
/// seuils que `FluidVoiceDetector` : `VadManager.processStreamingChunk` (FluidAudio 0.18.3,
/// `VadManager+Streaming.swift`).
///
/// Ce que fait la bibliothèque : chaque bloc de 4096 échantillons (256 ms à 16 kHz) reçoit une probabilité de voix.
/// - `speechStart` : au premier bloc dont la probabilité atteint le seuil d'entrée ; l'indice rendu est le début de ce
///   bloc (moins `speechPadding`, ici 0). Ce bloc peut précéder le vrai début de la voix (de moins d'un bloc) ou le
///   suivre (le bloc où la voix commence peut rester sous le seuil). Mesuré sur 12 prises de voix de synthèse : de
///   -2 688 à +384 échantillons (`streamingDetectorStartStaysWithinOneBlockOfTheVoice`). La marge de
///   `SpeechTimeline.spokenClip(padding:)` doit donc couvrir un bloc des deux côtés.
/// - `speechEnd` : quand la probabilité est restée sous le seuil de sortie pendant au moins `minSilence` ; l'indice
///   rendu est le début du premier bloc sous ce seuil (plus `speechPadding`, ici 0). L'événement date donc la fin au
///   début du silence, mais n'arrive que plus tard : la bibliothèque compte `minSilence` à partir de la fin du premier
///   bloc silencieux, il faut donc 1 + ⌈`minSilence` / 0,256 s⌉ blocs silencieux, soit 4 blocs (1,024 s) avec 0,6 s.
///   Mesuré sur voix de synthèse (3 phrases × 4 calages, non généralisable à une voix réelle) : une seconde de silence
///   après la voix ne suffit jamais avec 0,6 s, 1,5 s suffit toujours, et `minSilence: 0.1` (2 blocs) ferme à 1 s
///   (`streamingDetectorMinSilenceSetsWhenTheSegmentCloses`) ; le passage reste alors ouvert dans `SpeechTimeline`, ce qui est sans conséquence pour
///   `spokenClip`, qui l'arrête à la fin de la prise.
/// Les indices comptent les échantillons reçus depuis le début de la prise (`reset()`), pas depuis l'appel en cours.
///
/// `speechPadding` à 0 (défaut de la bibliothèque : 0,1 s) : l'instant donné est celui où le modèle entend la voix
/// commencer ou cesser ; la marge autour de la parole est l'affaire de `SpeechTimeline.spokenClip(padding:)`.
///
/// Concurrence : `prepare`, `reset`, `process` (et le `flush` du protocole, qui appelle `process`) peuvent être appelés
/// depuis plusieurs tâches ; ils passent un par un par une `SerialGate`, dans l'ordre d'arrivée à la porte. Un acteur
/// seul ne suffit pas : pendant l'attente du modèle, il accepte un autre appel qui lit le même état, et le dernier
/// écrit gagne (blocs perdus, indices décalés). L'ordre entre deux tâches indépendantes n'est pas défini : pour que les
/// blocs soient traités dans l'ordre de la prise, ils sont envoyés d'une seule tâche, en attendant chaque résultat.
/// `reset()` attend la fin du `process` en cours, puis remet l'état à neuf : les appels arrivés après lui voient la
/// nouvelle prise, ceux arrivés avant, l'ancienne. `prepare()` charge le modèle une seule fois, même appelé en
/// parallèle. Si `process` lève une erreur d'inférence, l'état n'avance pas : les indices suivants seraient décalés d'un
/// bloc ; la prise en cours est à abandonner (`reset()`).
public actor FluidStreamingVoiceDetector: StreamingVoiceDetector {
    /// Silence qui ferme un passage de voix, en secondes. 0,6 s : une pause de respiration au milieu d'une phrase
    /// ne coupe pas le passage ; la valeur du défaut de la bibliothèque (0,75 s) rend la fin plus tardive.
    public let minSilence: Double

    public nonisolated var blockSize: Int { VadManager.chunkSize }

    /// Nombre de chargements du modèle depuis la création : 1 après le premier `prepare()` ou `process`, quel que soit
    /// le nombre d'appels simultanés (pour les tests et les rapports).
    public private(set) var modelLoadCount = 0

    private let gate = SerialGate()
    private var manager: VadManager?
    /// État initial de la bibliothèque : `VadManager.makeStreamState()` ne fait que rendre `VadStreamState.initial()`
    /// (FluidAudio 0.18.3, `VadManager+Streaming.swift`, code lu) ; le construire ici évite une attente entre le
    /// chargement du modèle et un état utilisable.
    private var state = VadStreamState.initial()

    public init(minSilence: Double = 0.6) {
        self.minSilence = minSilence
    }

    /// Vrai quand le modèle est chargé en mémoire.
    public var isPrepared: Bool { manager != nil }

    public func prepare() async throws {
        await gate.enter()
        defer { gate.leave() }
        _ = try await loadedManager()
    }

    public func reset() async {
        await gate.enter()
        defer { gate.leave() }
        state = VadStreamState.initial()
    }

    public func process(_ block: [Float]) async throws -> VoiceEvent? {
        guard block.count == blockSize else {
            // `VadManager` complèterait un bloc court avec du silence : les indices des événements suivants dériveraient.
            throw TranscriberError.engine("bloc de \(block.count) échantillons, \(blockSize) attendus")
        }
        await gate.enter()
        defer { gate.leave() }
        let manager = try await loadedManager()
        let config = VadSegmentationConfig(minSilenceDuration: minSilence, speechPadding: 0)
        let result = try await manager.processStreamingChunk(block, state: state, config: config)
        state = result.state
        guard let event = result.event else { return nil }
        switch event.kind {
        case .speechStart: return .speechStart(sample: event.sampleIndex)
        case .speechEnd: return .speechEnd(sample: event.sampleIndex)
        }
    }

    /// À n'appeler que porte prise (`gate`).
    private func loadedManager() async throws -> VadManager {
        if let manager { return manager }
        let loaded = try await VadManager()
        manager = loaded
        modelLoadCount += 1
        return loaded
    }
}
