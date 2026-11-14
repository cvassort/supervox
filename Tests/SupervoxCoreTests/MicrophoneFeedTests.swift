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

@Test func scriptedFeedDeliversNothingMoreOnceStopIsCalled() throws {
    let script = [chunk(1), chunk(2), chunk(3)]
    let feed = ScriptedMicrophoneFeed(chunks: script)
    let received = Received()

    // `stop()` pendant la livraison de la 1re tranche : les suivantes ne doivent jamais arriver.
    try feed.start { chunk in
        received.append(chunk)
        feed.stop()
    }

    #expect(received.chunks == [script[0]])
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
