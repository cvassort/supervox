import Foundation
import os
import Testing
@testable import SupervoxCore

// MARK: - Registre de générations (règle 3), pur

@Test func aCallbackOfTheCurrentGenerationIsPlayed() {
    var ledger = PlaybackLedger()
    let first = ledger.scheduled()
    let second = ledger.scheduled()
    #expect(first != second)
    #expect(ledger.end(forGeneration: first) == .played)
    #expect(ledger.end(forGeneration: second) == .played)
}

@Test func afterStopAllEveryEarlierGenerationIsStopped() {
    var ledger = PlaybackLedger()
    let first = ledger.scheduled()
    let second = ledger.scheduled()
    ledger.stopAll()
    #expect(ledger.end(forGeneration: first) == .stopped)
    #expect(ledger.end(forGeneration: second) == .stopped)
    ledger.stopAll()   // un second arrêt ne change rien
    #expect(ledger.end(forGeneration: second) == .stopped)
}

@Test func aClipScheduledAfterStopAllIsPlayedAndTheEarlierOnesStayStopped() {
    var ledger = PlaybackLedger()
    let early = ledger.scheduled()
    ledger.stopAll()
    let late = ledger.scheduled()
    #expect(ledger.end(forGeneration: late) == .played)
    #expect(ledger.end(forGeneration: early) == .stopped)
}

// MARK: - Suivi des lectures en file : un seul rappel par clip, rendu hors du fil de l'appelant

/// Ce que reçoivent les `onEnd`, dans l'ordre. `@unchecked` inutile : l'état est derrière un verrou, la classe est `Sendable`.
private final class Ends: Sendable {
    private let store = OSAllocatedUnfairLock(initialState: [(name: String, end: PlaybackEnd)]())
    func recorder(_ name: String) -> @Sendable (PlaybackEnd) -> Void {
        { end in self.store.withLock { $0.append((name, end)) } }
    }
    var all: [String] { store.withLock { $0.map { "\($0.name):\($0.end)" } } }
}

private func makeTracker() -> (tracker: PlaybackTracker, flush: () -> Void) {
    let queue = DispatchQueue(label: "test.playback-events")
    return (PlaybackTracker(events: queue), { queue.sync {} })
}

private func register(_ tracker: PlaybackTracker, _ name: String, _ ends: Ends, frames: Int64 = 100, now: Int64? = 0) -> Int {
    tracker.register(frames: frames, sampleRate: 100, nowSample: now, onEnd: ends.recorder(name))
}

@Test func theCallbackOfAClipRendersPlayedOnceInTheOrderOfTheCallbacks() {
    let (tracker, flush) = makeTracker()
    let ends = Ends()
    let a = register(tracker, "a", ends)
    let b = register(tracker, "b", ends)
    tracker.settle(a)
    tracker.settle(b)
    flush()
    #expect(ends.all == ["a:played", "b:played"])
    #expect(!tracker.hasPending)
}

@Test func aSecondCallbackForTheSamePlaybackDoesNotCallOnEnd() {
    let (tracker, flush) = makeTracker()
    let ends = Ends()
    let a = register(tracker, "a", ends)
    tracker.settle(a)
    tracker.settle(a)
    flush()
    #expect(ends.all == ["a:played"])
}

/// Le lecteur rappelle chaque clip, de façon synchrone, pendant son `stop()` : tous rendent `.stopped`, dans l'ordre.
@Test func stopAllRendersStoppedToEveryQueuedClipWhenThePlayerCallsBackDuringItsStop() {
    let (tracker, flush) = makeTracker()
    let ends = Ends()
    let a = register(tracker, "a", ends)
    let b = register(tracker, "b", ends)
    tracker.stopAll { tracker.settle(a); tracker.settle(b) }
    flush()
    #expect(ends.all == ["a:stopped", "b:stopped"])
    #expect(!tracker.hasPending)
}

/// Un lecteur qui ne rappelle rien en s'arrêtant (non mesuré avec plusieurs clips) : le suivi rend `.stopped` lui-même.
@Test func stopAllRendersStoppedToClipsThePlayerNeverCalledBackFor() {
    let (tracker, flush) = makeTracker()
    let ends = Ends()
    _ = register(tracker, "a", ends)
    let b = register(tracker, "b", ends)
    _ = register(tracker, "c", ends)
    tracker.stopAll { tracker.settle(b) }   // seul le deuxième est rappelé
    flush()
    #expect(ends.all == ["b:stopped", "a:stopped", "c:stopped"])
}

@Test func aNaturalCallbackArrivingAfterStopAllIsIgnored() {
    let (tracker, flush) = makeTracker()
    let ends = Ends()
    let a = register(tracker, "a", ends)
    tracker.stopAll {}
    tracker.settle(a)
    flush()
    #expect(ends.all == ["a:stopped"])
}

@Test func aClipQueuedAfterStopAllIsPlayed() {
    let (tracker, flush) = makeTracker()
    let ends = Ends()
    let a = register(tracker, "a", ends)
    tracker.stopAll {}
    let b = register(tracker, "b", ends)
    tracker.settle(a)
    tracker.settle(b)
    flush()
    #expect(ends.all == ["a:stopped", "b:played"])
}

@Test func stopAllWithNothingQueuedDoesNotCallThePlayer() {
    let (tracker, _) = makeTracker()
    let stopped = OSAllocatedUnfairLock(initialState: 0)
    tracker.stopAll { stopped.withLock { $0 += 1 } }
    #expect(stopped.withLock { $0 } == 0)
}

/// `stopAll` rend la main sans attendre la file des événements : file suspendue, rien n'est encore livré au retour, et
/// tout arrive à la reprise. C'est ce qui garde `onEnd` hors du fil de l'appelant (peut-être le fil principal).
@Test func stopAllDoesNotWaitForTheEventQueueAndNothingRunsOnTheCallersThread() {
    let queue = DispatchQueue(label: "test.playback-events")
    let tracker = PlaybackTracker(events: queue)
    let ends = Ends()
    _ = register(tracker, "a", ends)
    queue.suspend()
    tracker.stopAll {}
    #expect(ends.all.isEmpty)
    queue.resume()
    queue.sync {}
    #expect(ends.all == ["a:stopped"])
}

/// Le défaut que la mesure de la tâche 1 annonce : `player.stop()` appelle les gestionnaires, de façon synchrone, sur le fil
/// appelant. Un verrou tenu autour de cet appel, que le gestionnaire reprend aussi, tue le processus (réentrée d'un verrou
/// non récursif) : le test tourne donc dans un processus fils.
@Test func stopAllHoldsNoLockWhileThePlayerCallsItsHandlersSynchronously() async {
    await #expect(processExitsWith: .success) {
        let queue = DispatchQueue(label: "test.playback-events")
        let tracker = PlaybackTracker(events: queue)
        let a = tracker.register(frames: 10, sampleRate: 10, nowSample: 0) { _ in }
        let b = tracker.register(frames: 10, sampleRate: 10, nowSample: 0) { _ in }
        tracker.stopAll { tracker.settle(a); tracker.settle(b) }
        queue.sync {}
        if tracker.hasPending { exit(2) }
    }
}

// MARK: - Position du clip en cours (calcul pur, puis suivi)

@Test func thePositionIsTheElapsedTimeSinceTheStartOfTheClipBoundedByItsDuration() {
    // Clip de 200 trames à 100 Hz (2 s) commencé à la trame 50.
    #expect(PlaybackTracker.position(sampleTime: 50, start: 50, frames: 200, sampleRate: 100) == 0)
    #expect(PlaybackTracker.position(sampleTime: 150, start: 50, frames: 200, sampleRate: 100) == 1)
    #expect(PlaybackTracker.position(sampleTime: 10, start: 50, frames: 200, sampleRate: 100) == 0)       // avant le début
    #expect(PlaybackTracker.position(sampleTime: 9_999, start: 50, frames: 200, sampleRate: 100) == 2)    // après la fin
}

@Test func thePositionIsNilWithoutPlaybackAndFollowsTheClipAtTheHead() {
    let (tracker, _) = makeTracker()
    let ends = Ends()
    #expect(tracker.position(currentSample: { 0 }) == nil)
    let a = register(tracker, "a", ends, frames: 200, now: 0)    // 0 à 2 s
    let b = register(tracker, "b", ends, frames: 300, now: 0)    // 2 s à 5 s : commence à la fin du précédent
    #expect(tracker.position(currentSample: { 100 }) == 1)
    #expect(tracker.position(currentSample: { 250 }) == 2)       // borné à la durée du clip en tête
    tracker.settle(a)
    #expect(tracker.position(currentSample: { 250 }) == 0.5)     // le second clip a commencé à 200
    tracker.settle(b)
    #expect(tracker.position(currentSample: { 250 }) == nil)
}

@Test func aClipQueuedWhileIdleStartsNowNotAtTheEndOfAnEarlierOne() {
    let (tracker, _) = makeTracker()
    let ends = Ends()
    let a = register(tracker, "a", ends, frames: 100, now: 0)
    tracker.settle(a)
    // Le lecteur a tourné à vide jusqu'à la trame 1 000 : le clip suivant commence à 1 000, pas à 100.
    _ = register(tracker, "b", ends, frames: 100, now: 1_000)
    #expect(tracker.position(currentSample: { 1_050 }) == 0.5)
}

@Test func theTimelineRestartsAfterStopAll() {
    let (tracker, _) = makeTracker()
    let ends = Ends()
    _ = register(tracker, "a", ends, frames: 10_000, now: 0)
    tracker.stopAll {}
    // `stop()` du lecteur remet son temps à 0 : le clip suivant commence à 0 et non à la fin du clip arrêté.
    _ = register(tracker, "b", ends, frames: 100, now: nil)
    #expect(tracker.position(currentSample: { 50 }) == 0.5)
}

// MARK: - `stopPlayback()` depuis `onEnd` : erreur de programmation (précondition, comme `stop()` depuis `onChunk`)

@Test func stopPlaybackFromOnEndIsAProgrammingError() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let capture = AudioCapture()
        // Si la précondition manquait, `stopPlayback()` ne ferait rien, le processus rendrait 0 et le test échouerait.
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            let generation = capture.playback.register(frames: 10, sampleRate: 10, nowSample: 0) { _ in
                capture.stopPlayback()
                finished.resume()
            }
            capture.playback.settle(generation)
        }
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("erreur de programmation"))
}
