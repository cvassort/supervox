import Foundation
import os
@testable import SupervoxCore

// Doubles de la session de dictée. Aucun ne dort : le temps vient de `TestClock`, et chaque double répond quand le
// test le décide (`Gate`, `ScriptedTranscriber.release`).

/// Porte à ouvrir une fois : `wait()` rend la main quand `open()` a été appelé (avant ou après).
final class Gate: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (isOpen: false, waiters: [CheckedContinuation<Void, Never>]()))

    func wait() async {
        await withCheckedContinuation { continuation in
            let passes = state.withLock { s -> Bool in
                if s.isOpen { return true }
                s.waiters.append(continuation)
                return false
            }
            if passes { continuation.resume() }
        }
    }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.resume() }
    }
}

/// L'horloge `now` de la session, que le test fait avancer.
final class TestClock: @unchecked Sendable {
    private let value: OSAllocatedUnfairLock<Double>
    init(_ start: Double = 0) { value = OSAllocatedUnfairLock(initialState: start) }
    func set(_ time: Double) { value.withLock { $0 = time } }
    func advance(by seconds: Double) { value.withLock { $0 += seconds } }
    var reader: @Sendable () -> Double { { [self] in value.withLock { $0 } } }
}

struct TestFailure: Error, CustomStringConvertible, Equatable {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Tranche de rampe : l'échantillon `i` vaut `i / 100 000`, ce qui permet de reconnaître chaque échantillon, son rang et
/// son ordre dans ce que reçoivent les doubles.
func rampSamples(_ range: Range<Int>) -> [Float] { range.map { Float($0) / 100_000 } }

func rampChunk(_ range: Range<Int>, rate: Double = 16000) -> AudioChunk {
    AudioChunk(samples: rampSamples(range), sampleRate: rate)
}

/// Micro de test : livre les tranches du script pendant `start` (comme `ScriptedMicrophoneFeed`), garde le rappel pour
/// que le test pousse d'autres tranches (`push`), et compte les appels.
final class TestFeed: MicrophoneFeed, @unchecked Sendable {
    private let inner: ScriptedMicrophoneFeed
    private let state = OSAllocatedUnfairLock(initialState: (starts: 0, stops: 0, handler: nil as (@Sendable (AudioChunk) -> Void)?))

    init(chunks: [AudioChunk] = [], startError: AudioCaptureError? = nil) {
        inner = ScriptedMicrophoneFeed(chunks: chunks, startError: startError)
    }

    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws {
        state.withLock {
            $0.starts += 1
            $0.handler = onChunk
        }
        try inner.start(onChunk: onChunk)
    }

    func stop() {
        state.withLock { $0.stops += 1 }
        inner.stop()
    }

    /// Une tranche de plus, comme le ferait le micro pendant la prise.
    func push(_ chunk: AudioChunk) {
        state.withLock { $0.handler }?(chunk)
    }
}

/// Détecteur scripté : rend l'événement prévu pour le bloc de rang `n` (0 pour le premier appel de `process`, le bloc
/// de fin de prise compris), et garde les blocs reçus.
final class ScriptedDetector: StreamingVoiceDetector, @unchecked Sendable {
    let blockSize: Int
    private let events: [Int: VoiceEvent]
    private let state = OSAllocatedUnfairLock(initialState: (blocks: [[Float]](), prepares: 0, resets: 0))
    /// Fait échouer `prepare()`.
    var prepareError: Error?
    /// Fait échouer `process` pour le bloc de rang donné.
    var processFailure: (block: Int, error: Error)?
    /// Ouverte par `prepare()` à son entrée.
    let prepareEntered = Gate()
    /// Si présente, `prepare()` attend son ouverture avant de rendre la main.
    var prepareRelease: Gate?

    init(blockSize: Int = 1000, events: [Int: VoiceEvent] = [:]) {
        self.blockSize = blockSize
        self.events = events
    }

    var blocks: [[Float]] { state.withLock { $0.blocks } }
    var prepares: Int { state.withLock { $0.prepares } }
    var resets: Int { state.withLock { $0.resets } }

    func prepare() async throws {
        state.withLock { $0.prepares += 1 }
        prepareEntered.open()
        await prepareRelease?.wait()
        if let prepareError { throw prepareError }
    }

    func reset() async { state.withLock { $0.resets += 1 } }

    func process(_ block: [Float]) async throws -> VoiceEvent? {
        precondition(block.count == blockSize, "bloc de \(block.count) échantillons, \(blockSize) attendus")
        let index = state.withLock { s -> Int in
            s.blocks.append(block)
            return s.blocks.count - 1
        }
        if let processFailure, processFailure.block == index { throw processFailure.error }
        return events[index]
    }
}

/// Moteur de transcription à réponse commandée. La réponse à l'appel de rang `n` vient de `reply(n)` ; `.hold` retient
/// l'appel jusqu'à `release(call:)`.
final class ScriptedTranscriber: Transcriber, @unchecked Sendable {
    enum Reply { case text(String), fail(Error), hold }
    struct Call: Equatable {
        var clip: AudioClip
        var language: String
        var vocabulary: [String]
    }
    private enum Held {
        case waiting(CheckedContinuation<String, Error>)
        case released(Result<String, Error>)
    }
    private struct State {
        var calls: [Call] = []
        var held: [Int: Held] = [:]
        var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
        var prepares = 0
    }

    let name: String
    var prepareError: Error?
    private let reply: @Sendable (Int) -> Reply
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(name: String = "double", reply: @escaping @Sendable (Int) -> Reply) {
        self.name = name
        self.reply = reply
    }

    convenience init(name: String = "double", text: String) {
        self.init(name: name, reply: { _ in .text(text) })
    }

    var calls: [Call] { state.withLock { $0.calls } }
    var prepares: Int { state.withLock { $0.prepares } }

    func prepare() async throws {
        state.withLock { $0.prepares += 1 }
        if let prepareError { throw prepareError }
    }

    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        let (index, ready) = state.withLock { s -> (Int, [CheckedContinuation<Void, Never>]) in
            s.calls.append(Call(clip: clip, language: language, vocabulary: vocabulary))
            let ready = s.waiters.filter { $0.count <= s.calls.count }.map(\.continuation)
            s.waiters.removeAll { $0.count <= s.calls.count }
            return (s.calls.count - 1, ready)
        }
        for waiter in ready { waiter.resume() }
        switch reply(index) {
        case .text(let text): return text
        case .fail(let error): throw error
        case .hold:
            return try await withCheckedThrowingContinuation { continuation in
                let early = state.withLock { s -> Result<String, Error>? in
                    if case .released(let result) = s.held[index] {
                        s.held[index] = nil
                        return result
                    }
                    s.held[index] = .waiting(continuation)
                    return nil
                }
                if let early { continuation.resume(with: early) }
            }
        }
    }

    /// Rend la main à l'appel retenu de rang `call`, avec `result`.
    func release(call: Int, with result: Result<String, Error>) {
        let waiting = state.withLock { s -> CheckedContinuation<String, Error>? in
            if case .waiting(let continuation) = s.held[call] {
                s.held[call] = nil
                return continuation
            }
            s.held[call] = .released(result)
            return nil
        }
        waiting?.resume(with: result)
    }

    func release(call: Int, text: String) { release(call: call, with: .success(text)) }

    /// Rend la main quand `count` appels au moins ont été faits.
    func waitForCalls(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { s -> Bool in
                if s.calls.count >= count { return true }
                s.waiters.append((count, continuation))
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// Lit `session.snapshots` et laisse le test attendre un état sans sonder ni dormir.
final class SnapshotLog: @unchecked Sendable {
    private struct Waiter {
        var matches: @Sendable (DictationSnapshot) -> Bool
        var continuation: CheckedContinuation<DictationSnapshot?, Never>
    }
    private let state = OSAllocatedUnfairLock(initialState: (items: [DictationSnapshot](), ended: false, waiters: [Waiter]()))

    init(_ stream: AsyncStream<DictationSnapshot>) {
        Task { [self] in
            for await snapshot in stream { append(snapshot) }
            end()
        }
    }

    private func append(_ snapshot: DictationSnapshot) {
        let ready = state.withLock { s -> [CheckedContinuation<DictationSnapshot?, Never>] in
            s.items.append(snapshot)
            let ready = s.waiters.filter { $0.matches(snapshot) }.map(\.continuation)
            s.waiters.removeAll { $0.matches(snapshot) }
            return ready
        }
        for continuation in ready { continuation.resume(returning: snapshot) }
    }

    private func end() {
        let waiters = state.withLock { s -> [Waiter] in
            s.ended = true
            defer { s.waiters = [] }
            return s.waiters
        }
        for waiter in waiters { waiter.continuation.resume(returning: nil) }
    }

    /// Le premier instantané (déjà reçu ou à venir) qui satisfait `matches` ; `nil` si le flux se termine sans.
    func wait(_ matches: @escaping @Sendable (DictationSnapshot) -> Bool) async -> DictationSnapshot? {
        await withCheckedContinuation { continuation in
            let found = state.withLock { s -> DictationSnapshot?? in
                if let item = s.items.first(where: matches) { return .some(item) }
                if s.ended { return .some(nil) }
                s.waiters.append(Waiter(matches: matches, continuation: continuation))
                return nil
            }
            if let found { continuation.resume(returning: found) }
        }
    }

    @discardableResult
    func wait(phase: DictationPhase) async -> DictationSnapshot? { await wait { $0.phase == phase } }

    /// Attend la fin du flux (phase terminale) et rend tout ce qui a été reçu.
    @discardableResult
    func waitForEnd() async -> [DictationSnapshot] {
        _ = await wait { _ in false }
        return state.withLock { $0.items }
    }

    var items: [DictationSnapshot] { state.withLock { $0.items } }

    /// Les phases traversées, sans répétition consécutive.
    var phases: [DictationPhase] {
        var result: [DictationPhase] = []
        for item in items where result.last != item.phase { result.append(item.phase) }
        return result
    }
}

/// La session et ses doubles.
struct Rig {
    let session: DictationSession
    let feed: TestFeed
    let detector: ScriptedDetector
    let final: ScriptedTranscriber
    let preview: ScriptedTranscriber?
    let clock: TestClock
    let log: SnapshotLog

    /// Attend la phase terminale et la rend.
    func outcome() async -> DictationPhase? { await log.waitForEnd().last?.phase }
}

func makeRig(chunks: [AudioChunk] = [], startError: AudioCaptureError? = nil, events: [Int: VoiceEvent] = [:],
             blockSize: Int = 1000, final: ScriptedTranscriber = ScriptedTranscriber(text: "texte"),
             preview: ScriptedTranscriber? = nil, config: DictationConfig = DictationConfig(language: "fr", padding: 0),
             clock: TestClock = TestClock(),
             makeResampler: (@Sendable (Double, Double) -> StreamingResampler?)? = nil) -> Rig {
    let feed = TestFeed(chunks: chunks, startError: startError)
    let detector = ScriptedDetector(blockSize: blockSize, events: events)
    let session = makeSession(feed: feed, detector: detector, preview: preview, final: final, config: config,
                              clock: clock, makeResampler: makeResampler)
    return Rig(session: session, feed: feed, detector: detector, final: final, preview: preview, clock: clock,
               log: SnapshotLog(session.snapshots))
}

func makeSession(feed: TestFeed, detector: ScriptedDetector, preview: ScriptedTranscriber?, final: ScriptedTranscriber,
                 config: DictationConfig, clock: TestClock,
                 makeResampler: (@Sendable (Double, Double) -> StreamingResampler?)? = nil) -> DictationSession {
    if let makeResampler {
        return DictationSession(feed: feed, detector: detector, preview: preview, final: final, config: config,
                                now: clock.reader, makeResampler: makeResampler)
    }
    return DictationSession(feed: feed, detector: detector, preview: preview, final: final, config: config, now: clock.reader)
}
