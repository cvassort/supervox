import Foundation
import os
import Testing
@testable import SupervoxCore

/// Capture factice : note ce que `LiveMicrophoneFeed` lui demande, sans micro.
private final class RecordingCapture: StreamingCapture {
    struct Call: Equatable { var accumulate: Bool }
    private let state = OSAllocatedUnfairLock(initialState: (starts: [Call](), stops: 0, handler: nil as (@Sendable (AudioChunk) -> Void)?))
    var starts: [Call] { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    var handler: (@Sendable (AudioChunk) -> Void)? { state.withLock { $0.handler } }

    func startStreaming(onChunk: @escaping @Sendable (AudioChunk) -> Void, accumulate: Bool) throws {
        state.withLock {
            $0.starts.append(Call(accumulate: accumulate))
            $0.handler = onChunk
        }
    }

    func stop() -> AudioClip {
        state.withLock { $0.stops += 1 }
        return AudioClip(samples: [], sampleRate: 16000)
    }
}

/// Constat C1 de la revue de la tâche 1 : rien, dans la suite par défaut, n'échouait si le micro repassait à
/// `accumulate: true` (le tampon interne grossirait alors pendant toute la dictée).
@Test func liveMicrophoneFeedAsksTheCaptureToKeepNothing() throws {
    let capture = RecordingCapture()
    let feed = LiveMicrophoneFeed(capture: capture)

    try feed.start { _ in }

    #expect(capture.starts == [.init(accumulate: false)])
}

@Test func liveMicrophoneFeedForwardsChunksAndStopsTheCapture() throws {
    let capture = RecordingCapture()
    let feed = LiveMicrophoneFeed(capture: capture)
    let received = OSAllocatedUnfairLock(initialState: [AudioChunk]())

    try feed.start { chunk in received.withLock { $0.append(chunk) } }
    let chunk = AudioChunk(samples: [0.1, 0.2], sampleRate: 48000)
    capture.handler?(chunk)
    feed.stop()

    #expect(received.withLock { $0 } == [chunk])
    #expect(capture.stops == 1)
}
