import Foundation
import os
import Testing
@testable import SupervoxCore

private func chunk(_ first: Float, count: Int = 3, rate: Double = 48000) -> AudioChunk {
    AudioChunk(samples: (0..<count).map { first + Float($0) }, sampleRate: rate)
}

/// Reçoit les tranches d'un `onChunk` `@Sendable`.
private final class Received: @unchecked Sendable {
    private let store = OSAllocatedUnfairLock(initialState: [AudioChunk]())
    var chunks: [AudioChunk] { store.withLock { $0 } }
    func append(_ chunk: AudioChunk) { store.withLock { $0.append(chunk) } }
}

@Test func scriptedFeedDeliversEveryChunkInOrderBeforeStartReturns() throws {
    let script = [chunk(1), chunk(10, rate: 16000), chunk(100, count: 1), chunk(1000, count: 0)]
    let feed = ScriptedMicrophoneFeed(chunks: script)
    let received = Received()

    try feed.start { received.append($0) }

    // Pas d'attente : la livraison est synchrone, c'est ce sur quoi les tests de la session s'appuient.
    #expect(received.chunks == script)
}

@Test func scriptedFeedStartErrorIsThrownAndNothingIsDelivered() {
    let feed = ScriptedMicrophoneFeed(chunks: [chunk(1), chunk(2)], startError: .noInputDevice)
    let received = Received()

    #expect(throws: AudioCaptureError.noInputDevice) {
        try feed.start { received.append($0) }
    }
    #expect(received.chunks.isEmpty)
}

/// `stop()` appelé d'un autre fil pendant une livraison : il attend la fin de l'appel en cours (même contrat que le
/// vrai micro), et rien n'arrive après son retour. Les attentes à délai ne peuvent produire qu'un faux succès, jamais
/// un faux échec. Quelles tranches suivantes passent avant que `stop()` prenne effet dépend de l'ordonnancement : on ne
/// l'affirme donc pas ; on affirme seulement que le compte ne bouge plus une fois `stop()` revenu.
@Test func scriptedFeedStopWaitsForTheDeliveryInProgressAndDeliversNothingAfterItReturns() throws {
    let script = (1...50).map { chunk(Float($0)) }
    let feed = ScriptedMicrophoneFeed(chunks: script)
    let received = Received()
    let entered = DispatchSemaphore(value: 0)
    let stopReturned = DispatchSemaphore(value: 0)
    let countWhenStopReturned = OSAllocatedUnfairLock(initialState: -1)

    // Un fil dédié, pas la file globale de GCD : ce test attend par sémaphore, donc en occupant un fil du groupe coopératif ; quand
    // tous ces fils attendent (lanceur à peu de cœurs, tests en parallèle), la file globale n'est plus servie et l'attente expire.
    Thread.detachNewThread {
        entered.wait()
        feed.stop()
        countWhenStopReturned.withLock { $0 = received.chunks.count }
        stopReturned.signal()
    }
    try feed.start { chunk in
        received.append(chunk)
        if received.chunks.count == 1 {
            entered.signal()
            // Le fil de `stop()` est lancé ; tant qu'on est ici, il ne doit pas en revenir.
            let early = stopReturned.wait(timeout: .now() + 0.2)
            #expect(early == .timedOut, "stop() est revenu pendant une livraison")
        }
    }

    #expect(stopReturned.wait(timeout: .now() + 10) == .success)
    #expect(countWhenStopReturned.withLock { $0 } >= 1)
    #expect(received.chunks.count == countWhenStopReturned.withLock { $0 }, "des tranches sont arrivées après le retour de stop()")
}

@Test func scriptedFeedCanBeStartedAgainAfterStop() throws {
    let script = [chunk(1), chunk(2)]
    let feed = ScriptedMicrophoneFeed(chunks: script)
    let first = Received()
    let second = Received()

    try feed.start { first.append($0) }
    feed.stop()
    try feed.start { second.append($0) }

    #expect(first.chunks == script)
    #expect(second.chunks == script)
}

@Test func deliveryGateKnowsWhenTheCurrentThreadIsDelivering() {
    let gate = DeliveryGate()
    #expect(!gate.isCurrentThreadDelivering)
    var delivered = false
    var insideDuringDelivery = false
    let accepted = gate.deliver {
        delivered = true
        insideDuringDelivery = gate.isCurrentThreadDelivering
    }
    #expect(accepted && delivered && insideDuringDelivery)
    #expect(!gate.isCurrentThreadDelivering)
}

@Test func deliveryGateRefusesDeliveriesOnceClosed() {
    let gate = DeliveryGate()
    gate.close()
    var delivered = false
    let accepted = gate.deliver { delivered = true }
    #expect(!accepted && !delivered)
}

/// Appeler `stop()` depuis `onChunk` est une erreur de programmation : le processus s'arrête sur la précondition,
/// pour le micro scripté comme pour le vrai micro. Test à sortie de processus : le corps tourne dans un processus
/// fils, dont on lit le message d'erreur (sans lui, une mort du processus pour une autre raison passerait pour bonne).
@Test func scriptedFeedStopFromOnChunkIsAProgrammingError() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let feed = ScriptedMicrophoneFeed(chunks: [AudioChunk(samples: [1], sampleRate: 16000)])
        try feed.start { _ in feed.stop() }
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("erreur de programmation"))
}

@Test func deliveryGateClosedFromInsideADeliveryIsAProgrammingError() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let gate = DeliveryGate()
        gate.deliver { gate.close() }
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("erreur de programmation"))
}
