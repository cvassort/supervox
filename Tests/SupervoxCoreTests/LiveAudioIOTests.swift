import AVFAudio
import AVFoundation
import Foundation
import os
import Testing
@testable import SupervoxCore

/// Ce que reçoit le test pendant une prise réelle : les tranches du micro (avec l'heure d'arrivée) et les fins de lecture.
/// Verrou : `store` (la classe est `Sendable`, sans `@unchecked`).
private final class Probe: Sendable {
    private struct Store {
        var chunkTimes: [UInt64] = []
        var ends: [(name: String, end: PlaybackEnd, at: UInt64, onMainThread: Bool)] = []
    }
    private let store = OSAllocatedUnfairLock(initialState: Store())

    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    func chunk() { store.withLock { $0.chunkTimes.append(Self.now) } }
    func onEnd(_ name: String) -> @Sendable (PlaybackEnd) -> Void {
        { end in
            let main = Thread.isMainThread
            self.store.withLock { $0.ends.append((name, end, Self.now, main)) }
        }
    }
    var chunkCount: Int { store.withLock { $0.chunkTimes.count } }
    func chunks(between start: UInt64, and end: UInt64) -> Int { store.withLock { $0.chunkTimes.filter { $0 >= start && $0 <= end }.count } }
    func ends(of name: String) -> [(end: PlaybackEnd, at: UInt64, onMainThread: Bool)] {
        store.withLock { $0.ends.filter { $0.name == name }.map { ($0.end, $0.at, $0.onMainThread) } }
    }
    static func seconds(from start: UInt64, to end: UInt64) -> Double { Double(end &- start) / 1e9 }
}

/// Attend, par sondages de 10 ms et jamais plus de `timeout` secondes, qu'une condition devienne vraie. Sondage de 10 ms et délai de
/// 10 s : choix non mesurés (le délai n'est qu'une borne de vivacité, un test suspendu doit échouer, non rester en vie).
private func wait(timeout: Double = 10, until condition: () -> Bool) async throws -> Bool {
    let limit = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1e9)
    while !condition() {
        if DispatchTime.now().uptimeNanoseconds > limit { return false }
        try await Task.sleep(for: .milliseconds(10))
    }
    return true
}

/// Ton de 440 Hz à faible amplitude (0,05, soit −26 dB pleine échelle, calculé : 20·log10(0,05)) : un essai réel ne doit pas surprendre.
/// Choix non mesuré : le niveau réellement entendu dépend du volume du système.
private func quietTone(seconds: Double) -> AudioClip {
    let rate = 22_050.0
    return AudioClip(samples: (0..<Int(seconds * rate)).map { 0.05 * Float(sin(2 * Double.pi * 440 * Double($0) / rate)) }, sampleRate: rate)
}

/// `true` si le micro est déjà autorisé : le statut est lu avant tout accès, et aucune invite n'est jamais déclenchée.
private func microphoneAuthorized() -> Bool {
    let authorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    if !authorized {
        Issue.record("non établi : le micro n'est pas autorisé pour cet hôte de test (aucune invite n'est déclenchée)", severity: .warning)
    }
    return authorized
}

/// Règle 6 : le vrai son, haut-parleurs et micro. À lancer à la main avec `SUPERVOX_SPEAKER=1` (l'autorisation du micro doit
/// être déjà accordée à l'hôte du test). Ne change aucun réglage du système ; ne mesure que des événements (fin de lecture,
/// tranches du micro), jamais ce qui s'entend. Un seul moteur à la fois : suite sérialisée.
@Suite("Son réel", .serialized)
struct RealAudioIOTests {
    private static let enabled = ProcessInfo.processInfo.environment["SUPERVOX_SPEAKER"] == "1"

    @Test(.enabled(if: enabled))
    func aToneEndsPlayedNoSoonerThanItsDurationWhileTheTapKeepsDelivering() async throws {
        guard microphoneAuthorized() else { return }
        let io = LiveAudioIO()
        let probe = Probe()
        try io.start { _ in probe.chunk() }
        #expect(try await wait { probe.chunkCount > 0 }, "aucune tranche du micro en 10 s")

        let duration = 0.5
        let before = DispatchTime.now().uptimeNanoseconds
        try io.play(quietTone(seconds: duration), onEnd: probe.onEnd("tone"))
        try await Task.sleep(for: .milliseconds(200))   // choix non mesuré : un moment bien après le début et avant la fin (0,5 s)
        let midway = io.playbackPosition
        #expect(try await wait { !probe.ends(of: "tone").isEmpty }, "aucune fin de lecture en 10 s")
        let ended = try #require(probe.ends(of: "tone").first)
        let elapsed = Probe.seconds(from: before, to: ended.at)

        Issue.record("fin \(ended.end) à \(elapsed) s de play() pour \(duration) s de son ; position à 0,2 s : \(midway.map { String($0) } ?? "nil") ; tranches du micro pendant la lecture : \(probe.chunks(between: before, and: ended.at)) ; sur le fil principal : \(ended.onMainThread)", severity: .warning)
        #expect(ended.end == .played)
        #expect(elapsed >= duration, "`.played` est arrivé après \(elapsed) s, avant la fin du son (\(duration) s)")
        #expect(!ended.onMainThread)
        // Seuil de 2 tranches : choix non mesuré. 0,5 s de lecture et des fenêtres de 100 ms (demandées au tap) en donnent environ 5 ;
        // 2 tolère un retard sans accepter l'absence de livraison.
        #expect(probe.chunks(between: before, and: ended.at) >= 2, "le micro n'a pas livré pendant la lecture")
        #expect(try #require(midway) > 0 && midway! <= duration, "position à mi-lecture : \(String(describing: midway))")
        #expect(io.playbackPosition == nil, "plus de clip en file : pas de position")
        #expect(probe.ends(of: "tone").count == 1)

        io.stop()
        let afterStop = probe.chunkCount
        try await Task.sleep(for: .milliseconds(400))   // 4 fenêtres du tap (100 ms chacune, valeur demandée) : choix non mesuré
        #expect(probe.chunkCount == afterStop, "tranches arrivées après stop()")
    }

    @Test(.enabled(if: enabled))
    func stopPlaybackInTheMiddleRendersStoppedToEveryQueuedClipAndTheEngineKeepsGoing() async throws {
        guard microphoneAuthorized() else { return }
        let io = LiveAudioIO()
        let probe = Probe()
        try io.start { _ in probe.chunk() }
        #expect(try await wait { probe.chunkCount > 0 })

        let before = DispatchTime.now().uptimeNanoseconds
        try io.play(quietTone(seconds: 3), onEnd: probe.onEnd("a"))
        try io.play(quietTone(seconds: 3), onEnd: probe.onEnd("b"))
        try await Task.sleep(for: .milliseconds(300))   // choix non mesuré : bien dans les 3 s des clips en file
        let stoppedAt = DispatchTime.now().uptimeNanoseconds
        io.stopPlayback()
        #expect(try await wait { !probe.ends(of: "a").isEmpty && !probe.ends(of: "b").isEmpty }, "`.stopped` n'est pas arrivé en 10 s")
        let a = try #require(probe.ends(of: "a").first), b = try #require(probe.ends(of: "b").first)
        Issue.record("a : \(a.end), \(Probe.seconds(from: stoppedAt, to: a.at)) s après stopPlayback() ; b : \(b.end), \(Probe.seconds(from: stoppedAt, to: b.at)) s après ; lecture lancée \(Probe.seconds(from: before, to: stoppedAt)) s avant l'arrêt ; sur le fil principal : \(a.onMainThread || b.onMainThread)", severity: .warning)
        #expect(a.end == .stopped && b.end == .stopped)
        #expect(!a.onMainThread && !b.onMainThread)
        #expect(io.playbackPosition == nil)

        // Aucune fin naturelle ne vient s'ajouter, et le moteur et le micro continuent : un nouveau clip se joue jusqu'au bout.
        let chunksAtStop = probe.chunkCount
        try io.play(quietTone(seconds: 0.3), onEnd: probe.onEnd("c"))
        #expect(try await wait { !probe.ends(of: "c").isEmpty })
        #expect(probe.ends(of: "c").first?.end == .played)
        #expect(probe.chunkCount > chunksAtStop, "le micro s'est arrêté avec la lecture")
        #expect(probe.ends(of: "a").count == 1 && probe.ends(of: "b").count == 1, "un clip a reçu deux fins")
        io.stop()
    }

    /// Cycle `stop()` → `start()` → `play()` sur la même instance (non essayé à la tâche 1), clip en file au moment de `stop()`.
    @Test(.enabled(if: enabled))
    func stopRendersStoppedToTheQueuedClipAndTheSameInstanceCanStartAndPlayAgain() async throws {
        guard microphoneAuthorized() else { return }
        let io = LiveAudioIO()
        let probe = Probe()
        try io.start { _ in probe.chunk() }
        #expect(try await wait { probe.chunkCount > 0 })
        try io.play(quietTone(seconds: 3), onEnd: probe.onEnd("a"))
        try await Task.sleep(for: .milliseconds(200))   // choix non mesuré : le clip joue encore (3 s) au moment du stop()
        io.stop()
        #expect(try await wait { !probe.ends(of: "a").isEmpty })
        #expect(probe.ends(of: "a").first?.end == .stopped)
        #expect(throws: AudioCaptureError.notRunning) { try io.play(quietTone(seconds: 0.1)) { _ in } }

        let second = Probe()
        try io.start { _ in second.chunk() }
        #expect(try await wait { second.chunkCount > 0 }, "aucune tranche après le redémarrage")
        try io.play(quietTone(seconds: 0.3), onEnd: second.onEnd("b"))
        #expect(try await wait { !second.ends(of: "b").isEmpty })
        #expect(second.ends(of: "b").first?.end == .played)
        io.stop()
        #expect(probe.ends(of: "a").count == 1)
    }
}
