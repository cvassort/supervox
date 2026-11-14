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
public protocol MicrophoneFeed: Sendable {
    /// Démarre la capture. `onChunk` est appelé **hors du fil principal**, dans l'ordre des tranches. Il doit rester
    /// bref (il peut s'exécuter sur le fil audio) et ne doit pas appeler `stop()`.
    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws
    /// Arrête la capture. Aucun `onChunk` n'arrive après le retour de `stop()`.
    func stop()
}

/// Micro scripté, pour les tests et l'outil de rendu : `start` livre toutes les tranches, dans l'ordre, sur le fil de
/// l'appelant, **avant de rendre la main**. Les tests de la session s'appuient sur cette synchronicité.
///
/// `stop()` appelé pendant la livraison (depuis `onChunk`) interrompt les tranches restantes. Une instance peut être
/// redémarrée après `stop()` : `start` rejoue alors le script depuis le début.
public final class ScriptedMicrophoneFeed: MicrophoneFeed {
    private let chunks: [AudioChunk]
    private let startError: AudioCaptureError?
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    public init(chunks: [AudioChunk], startError: AudioCaptureError? = nil) {
        self.chunks = chunks
        self.startError = startError
    }

    public func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        if let startError { throw startError }
        stopped.withLock { $0 = false }
        for chunk in chunks {
            if stopped.withLock({ $0 }) { return }
            onChunk(chunk)
        }
    }

    public func stop() {
        stopped.withLock { $0 = true }
    }
}
