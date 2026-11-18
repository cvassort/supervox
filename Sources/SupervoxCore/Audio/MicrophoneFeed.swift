import Foundation
import os

/// Une tranche de micro : échantillons mono flottants (premier canal) à la fréquence où ils ont été captés.
public struct AudioChunk: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

/// Source de tranches de micro : ce que la session de dictée demande au micro, et que les tests remplacent.
///
/// Contrat de `onChunk` (le même pour le vrai micro et pour `ScriptedMicrophoneFeed`) :
/// - appelé **hors du fil principal**, dans l'ordre des tranches, éventuellement sur le fil audio : il doit rester
///   bref (copie, file sans attente, `AsyncStream.Continuation.yield`) ;
/// - il ne prend aucun verrou que l'appelant de `stop()` pourrait tenir pendant cet appel : `stop()` attend la fin
///   d'un `onChunk` en cours, donc un appelant qui tient un verrou `V` en appelant `stop()` pendant qu'un `onChunk`
///   attend `V` provoque un interblocage ;
/// - il n'appelle **jamais** `stop()` : c'est une erreur de programmation, qui arrête le processus (précondition).
public protocol MicrophoneFeed: Sendable {
    /// Démarre la capture ; voir le contrat de `onChunk` ci-dessus.
    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws
    /// Arrête la capture. Attend la fin d'un `onChunk` en cours ; aucun `onChunk` n'arrive après le retour de `stop()`.
    /// Ne pas l'appeler depuis `onChunk`.
    func stop()
}

/// Porte de livraison d'une prise : les appels à `onChunk` passent par `deliver`, sous un verrou ; `close` prend ce
/// verrou, donc attend l'appel en cours et empêche tout appel ultérieur. Une porte neuve par prise : un bloc en retard
/// d'une prise précédente garde sa porte, fermée, et ne peut pas atteindre le gestionnaire de la prise suivante.
final class DeliveryGate: @unchecked Sendable {
    private let open = OSAllocatedUnfairLock(initialState: true)
    /// Identifiant (mach) du fil qui est dans `deliver`, 0 sinon. Verrou séparé : `close` peut le lire pendant que
    /// `open` est tenu par la livraison.
    private let deliveringThread = OSAllocatedUnfairLock<UInt32>(initialState: 0)

    private static var currentThread: UInt32 { pthread_mach_thread_np(pthread_self()) }

    var isCurrentThreadDelivering: Bool { deliveringThread.withLock { $0 } == Self.currentThread }

    /// Exécute `body` sous le verrou de livraison si la porte est ouverte. `false` si elle est fermée.
    @discardableResult
    func deliver(_ body: () -> Void) -> Bool {
        open.withLockUnchecked { isOpen in
            guard isOpen else { return false }
            deliveringThread.withLock { $0 = Self.currentThread }
            body()
            deliveringThread.withLock { $0 = 0 }
            return true
        }
    }

    /// Arrête les livraisons ; ne rend la main qu'après la fin d'une livraison en cours.
    func close() {
        assertNotDelivering()
        open.withLock { $0 = false }
    }

    /// `stop()` depuis `onChunk` : le verrou de livraison serait pris deux fois par le même fil, ce que le système
    /// sanctionne par la mort du processus (mesuré avec `OSAllocatedUnfairLock`). On préfère un message clair.
    ///
    /// Le même contrôle sert aux appels de la lecture (`play()`, `stopPlayback()`) : ils prennent le verrou de cycle de vie que `stop()`
    /// tient en attendant la fin de `onChunk`, donc `onChunk` qui les appelle pendant un `stop()` d'un autre fil bloquerait les deux.
    func assertNotDelivering(calling call: String = "stop()") {
        precondition(!isCurrentThreadDelivering,
                     "\(call) appelé depuis onChunk : erreur de programmation. Signaler un autre contexte qui appellera \(call).")
    }
}

/// Micro scripté, pour les tests et l'outil de rendu : `start` livre toutes les tranches, dans l'ordre, sur le fil de
/// l'appelant, **avant de rendre la main**. Les tests de la session s'appuient sur cette synchronicité.
///
/// Même contrat que le vrai micro : `stop()` appelé d'un autre fil attend la fin du `onChunk` en cours puis interrompt
/// les tranches restantes ; `stop()` depuis `onChunk` arrête le processus (précondition). Une instance peut être
/// redémarrée après `stop()` : `start` rejoue alors le script depuis le début.
public final class ScriptedMicrophoneFeed: MicrophoneFeed {
    private let chunks: [AudioChunk]
    private let startError: AudioCaptureError?
    private let gate = OSAllocatedUnfairLock<DeliveryGate?>(initialState: nil)

    public init(chunks: [AudioChunk], startError: AudioCaptureError? = nil) {
        self.chunks = chunks
        self.startError = startError
    }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        if let startError { throw startError }
        let take = DeliveryGate()
        gate.withLock { $0 = take }
        for chunk in chunks {
            if !take.deliver({ onChunk(chunk) }) { return }
        }
    }

    public func stop() {
        gate.withLock { $0 }?.close()
    }
}

/// Ce que `LiveMicrophoneFeed` demande à la capture : l'unique endroit où il décide de garder ou non le tampon interne.
/// `AudioCapture` la satisfait ; les tests la remplacent pour vérifier ce câblage sans micro.
protocol StreamingCapture: Sendable {
    func startStreaming(onChunk: @escaping @Sendable (AudioChunk) -> Void, accumulate: Bool) throws
    func stop() -> AudioClip
}

extension AudioCapture: StreamingCapture {
    func startStreaming(onChunk: @escaping @Sendable (AudioChunk) -> Void, accumulate: Bool) throws {
        try start(onChunk: onChunk, accumulate: accumulate)
    }
}

/// Ce que `LiveAudioIO` demande à l'appareil : la capture de `StreamingCapture` et la lecture dans le même moteur. `AudioCapture`
/// la satisfait ; les tests la remplacent pour vérifier le câblage (un seul objet reçoit `start` et `play`) sans matériel.
protocol PlaybackCapture: StreamingCapture {
    func play(_ clip: AudioClip, onEnd: @escaping @Sendable (PlaybackEnd) -> Void) throws
    func stopPlayback()
    var playbackPosition: Double? { get }
}

extension AudioCapture: PlaybackCapture {}

/// Le vrai micro, vu comme une `MicrophoneFeed` : possède une `AudioCapture` qui ne déclenche jamais l'invite système
/// (l'application demande l'autorisation par son propre parcours) ; sans autorisation, `start` lève
/// `AudioCaptureError.microphoneAccessDenied`. Les tranches sont à la fréquence native du micro, premier canal.
///
/// Le tampon interne d'`AudioCapture` n'accumule rien (`accumulate: false`) : une dictée longue ne fait pas grossir
/// la mémoire. `@unchecked Sendable` : `AudioCapture` sérialise elle-même `start` et `stop`.
public final class LiveMicrophoneFeed: MicrophoneFeed, @unchecked Sendable {
    let capture: any StreamingCapture

    public convenience init(voiceProcessing: Bool = true) {
        self.init(capture: AudioCapture(voiceProcessing: voiceProcessing, promptsForAccess: false))
    }

    /// Pour les tests : une capture factice à la place du micro.
    init(capture: any StreamingCapture) {
        self.capture = capture
    }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        try capture.startStreaming(onChunk: onChunk, accumulate: false)
    }

    public func stop() {
        _ = capture.stop()
    }
}
