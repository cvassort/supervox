import AVFAudio
import Foundation
import os
import Testing
@testable import SupervoxCore

// Ce que `AudioCapture.stop()` fait de la lecture, sans moteur démarré (aucun matériel : le lecteur n'est jamais touché pour de bon).

private final class Log: Sendable {
    private let store = OSAllocatedUnfairLock(initialState: [String]())
    var all: [String] { store.withLock { $0 } }
    func add(_ line: String) { store.withLock { $0.append(line) } }
}

/// Mesuré à la tâche 2 (panne F2c, matériel) : `engine.stop()` seul rappelle le gestionnaire du lecteur sans que le registre sache
/// qu'il y a eu arrêt, donc un clip coupé serait rendu `.played`. La lecture doit donc passer avant le moteur. Ce test fait jouer
/// au « moteur » ce rôle : il rappelle le gestionnaire pendant son arrêt, comme `engine.stop()`.
@Test func stopEndsThePlaybackBeforeTheEngineSoACutClipIsStopped() {
    let queue = DispatchQueue(label: "test.playback-events")
    let tracker = PlaybackTracker(events: queue)
    let ends = Log()
    let order = Log()
    let generation = tracker.register(frames: 100, sampleRate: 100, nowSample: 0) { ends.add("a:\($0)") }
    AudioCapture.stopSequence(
        closeDeliveries: { order.add("livraisons") },
        stopPlayback: { order.add("lecture"); tracker.stopAll(force: false) { order.add("lecteur") } },
        stopEngine: { order.add("moteur"); tracker.settle(generation) })   // le moteur rappelle le gestionnaire du lecteur
    queue.sync {}
    #expect(order.all == ["livraisons", "lecture", "lecteur", "moteur"])
    #expect(ends.all == ["a:stopped"])
}

/// L'ordre des trois étapes de `stop()` est celui de `stopSequence` : livraisons, lecture, moteur.
@Test func stopSequenceRunsTheDeliveriesThenThePlaybackThenTheEngine() {
    let order = Log()
    AudioCapture.stopSequence(
        closeDeliveries: { order.add("livraisons") }, stopPlayback: { order.add("lecture") }, stopEngine: { order.add("moteur") })
    #expect(order.all == ["livraisons", "lecture", "moteur"])
}

/// `AudioCapture.stop()` rend `.stopped` à un clip en file, même sans moteur démarré (lecteur non attaché). Processus fils :
/// si `player.stop()` sur un nœud non attaché levait une exception, le fils mourrait ; si `stop()` ne coupait pas la lecture,
/// la fin ne serait pas `.stopped`.
@Test func captureStopRendersStoppedToAQueuedClipWithoutAnEngine() async {
    await #expect(processExitsWith: .success) {
        let capture = AudioCapture()
        let got = OSAllocatedUnfairLock(initialState: [PlaybackEnd]())
        _ = capture.playback.register(frames: 10, sampleRate: 10, nowSample: 0) { end in got.withLock { $0.append(end) } }
        _ = capture.stop()
        capture.playback.flushEvents()
        exit(got.withLock { $0 } == [.stopped] ? 0 : 4)
    }
}

// MARK: - Le lecteur qui a joué est arrêté par `stop()`, même sans clip en file ; la dictée, qui n'en joue aucun, ne le touche pas

@Test func stopStopsAPlayerThatHasPlayedEvenWithNoClipQueued() {
    let stops = Log()
    let capture = AudioCapture(playerStop: { stops.add("player.stop") })
    capture.playerStarted = true   // ce que fait `play()` après `startPlayer()` ; le moteur lui-même n'est pas démarré ici
    _ = capture.stop()
    #expect(stops.all == ["player.stop"])
    #expect(!capture.playerStarted, "un second stop() ne rappelle pas le lecteur")
    _ = capture.stop()
    #expect(stops.all == ["player.stop"])
}

/// La dictée ne joue rien : `stop()` ne touche pas au lecteur (le comportement de capture ne change pas).
@Test func stopLeavesAPlayerThatNeverPlayedAlone() {
    let stops = Log()
    let capture = AudioCapture(playerStop: { stops.add("player.stop") })
    _ = capture.stop()
    #expect(stops.all.isEmpty)
}

@Test func stopPlaybackStopsThePlayerOnlyWhenAClipIsQueuedAndForgetsItWasStarted() {
    let stops = Log()
    let capture = AudioCapture(playerStop: { stops.add("player.stop") })
    capture.playerStarted = true
    capture.stopPlayback()   // rien en file : le lecteur n'est pas appelé
    #expect(stops.all.isEmpty)
    _ = capture.playback.register(frames: 10, sampleRate: 10, nowSample: 0) { _ in }
    capture.stopPlayback()
    #expect(stops.all == ["player.stop"])
    #expect(!capture.playerStarted)
}

@Test func stopAllWithForceCallsThePlayerEvenWithNothingQueuedAndNeverForcedDoesNot() {
    let queue = DispatchQueue(label: "test.playback-events")
    let tracker = PlaybackTracker(events: queue)
    let calls = Log()
    tracker.stopAll(force: true) { calls.add("forcé") }
    tracker.stopAll(force: false) { calls.add("non forcé") }
    #expect(calls.all == ["forcé"])
}
