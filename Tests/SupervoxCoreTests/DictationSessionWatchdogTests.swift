import Foundation
import Testing
@testable import SupervoxCore

// I3 : un micro qui s'arrête en pleine prise (casque débranché, entrée qui change) ne livre plus rien. Le chien de garde de la
// session le voit : en `recording`, aucune tranche pendant `timeout` secondes → échec de micro, rien n'est transcrit. L'horloge
// est celle de la session (`TestClock`) et l'attente est un `TickSleeper` : aucun test n'attend une durée réelle.

@Suite(.timeLimit(.minutes(1)))
struct DictationSessionWatchdogTests {
    private static let reason = "le micro s'est arrêté pendant la prise"

    /// Une session en `recording`, une tranche de parole livrée à l'instant 0, le chien de garde endormi.
    private func recordingRig(
        sleeper: TickSleeper, chunks: [AudioChunk] = [rampChunk(0..<1000)], events: [Int: VoiceEvent] = [0: .speechStart(sample: 0)],
        final: ScriptedTranscriber = ScriptedTranscriber(text: "texte")
    ) async -> Rig {
        let rig = makeRig(chunks: chunks, events: events, final: final, watchdog: sleeper.watchdog)
        await rig.session.start()
        await sleeper.waitForSleeps(1)
        return rig
    }

    @Test func aMicrophoneThatStopsAfterSpeechFailsTheSessionAndNothingIsTranscribed() async {
        let sleeper = TickSleeper()
        let rig = await recordingRig(sleeper: sleeper)
        #expect(await rig.session.phase == .recording)

        rig.clock.advance(by: 1.5)
        sleeper.tick()

        #expect(await rig.outcome() == .failed(.microphone(Self.reason)))
        #expect(rig.final.calls.isEmpty)
        #expect(rig.feed.stops == 1)
        // Le message se lit en mots simples.
        #expect(DictationFailure.microphone(Self.reason).message == "Le micro ne fonctionne pas : le micro s'est arrêté pendant la prise.")
        // Une fois la session terminée, le chien de garde est arrêté : plus aucune attente en cours.
        #expect(await until { !sleeper.isSleeping })
    }

    /// Avant toute parole, la coupure est aussi une panne de micro, pas « aucune parole ».
    @Test func aMicrophoneThatStopsBeforeAnySpeechIsAMicrophoneFailureNotSilence() async {
        let sleeper = TickSleeper()
        let rig = await recordingRig(sleeper: sleeper, events: [:])
        rig.clock.advance(by: 2)
        sleeper.tick()
        #expect(await rig.outcome() == .failed(.microphone(Self.reason)))
    }

    /// Un vrai micro livre des tranches même dans le silence : des tranches régulières ne déclenchent rien, longtemps après.
    @Test func regularChunksOfSilenceNeverTriggerTheWatchdog() async {
        let sleeper = TickSleeper()
        let rig = await recordingRig(sleeper: sleeper, events: [:])

        for round in 1...8 {
            rig.clock.advance(by: 0.5)
            rig.feed.push(AudioChunk(samples: [Float](repeating: 0, count: 1600), sampleRate: 16000))
            sleeper.tick()
            await sleeper.waitForSleeps(1 + round)
        }
        // Quatre secondes de silence livré : toujours en prise.
        #expect(await rig.session.phase == .recording)
        #expect(sleeper.requested.allSatisfy { $0 == 0.25 })

        await rig.session.cancel()
    }

    /// La limite : pile `timeout` sans tranche échoue, un peu moins ne fait rien.
    @Test func theWatchdogFiresAtTheTimeoutAndNotBefore() async {
        let sleeper = TickSleeper()
        let rig = await recordingRig(sleeper: sleeper, events: [:])

        rig.clock.advance(by: 0.99)
        sleeper.tick()
        await sleeper.waitForSleeps(2)
        #expect(await rig.session.phase == .recording)

        rig.clock.advance(by: 0.01)
        sleeper.tick()
        #expect(await rig.outcome() == .failed(.microphone(Self.reason)))
    }

    /// L'heure d'une tranche est celle de son arrivée au micro, pas celle où la pompe la traite : une pompe bloquée dans le
    /// détecteur pendant plus d'une seconde, avec des tranches qui s'accumulent derrière, n'est pas un micro mort.
    @Test func chunksThatQueueBehindASlowDetectorAreStillMicrophoneLife() async {
        let sleeper = TickSleeper()
        let rig = makeRig(chunks: [rampChunk(0..<1000)], watchdog: sleeper.watchdog)
        let held = rig.detector.hold(block: 0)
        await rig.session.start()
        await sleeper.waitForSleeps(1)
        await held.entered.wait()   // la pompe est dans le détecteur

        rig.clock.advance(by: 0.9)
        rig.feed.push(rampChunk(1000..<2000))
        rig.clock.advance(by: 0.9)
        rig.feed.push(rampChunk(2000..<3000))
        rig.clock.advance(by: 0.5)   // 2,3 s depuis le début, 0,5 s depuis la dernière tranche arrivée
        sleeper.tick()
        await sleeper.waitForSleeps(2)
        #expect(await rig.session.phase == .recording)

        held.release.open()
        await rig.session.cancel()
    }

    @Test func cancellingStopsTheWatchdog() async {
        let sleeper = TickSleeper()
        let rig = await recordingRig(sleeper: sleeper)
        #expect(sleeper.isSleeping)

        await rig.session.cancel()

        #expect(await until { !sleeper.isSleeping && sleeper.cancelled == 1 })
        // Une horloge qui avance et un tic de plus ne changent rien : la session reste annulée.
        rig.clock.advance(by: 10)
        sleeper.tick()
        #expect(await rig.outcome() == .cancelled)
        #expect(sleeper.started == 1)
    }

    /// À `finish()`, le micro est arrêté exprès : le chien de garde s'arrête avant la transcription, qui peut durer.
    @Test func theWatchdogStopsWhenTheRecordingEndsAndNeverFailsAFinalizingSession() async {
        let sleeper = TickSleeper()
        let final = ScriptedTranscriber(reply: { _ in .hold })
        let rig = await recordingRig(sleeper: sleeper, final: final)

        let finishing = Task { await rig.session.finish() }
        await final.waitForCalls(1)
        #expect(await rig.session.phase == .finalizing)
        #expect(await until { !sleeper.isSleeping && sleeper.cancelled == 1 })

        rig.clock.advance(by: 30)
        sleeper.tick()
        #expect(await rig.session.phase == .finalizing)

        final.release(call: 0, text: "texte")
        await finishing.value
        #expect(await rig.outcome() == .finished("texte"))
    }

    @Test func anotherFailureStopsTheWatchdogToo() async {
        let sleeper = TickSleeper()
        let rig = makeRig(chunks: [rampChunk(0..<1000)], watchdog: sleeper.watchdog)
        rig.detector.processFailure = (block: 0, error: TestFailure("panne"))
        await rig.session.start()
        #expect(await rig.outcome() == .failed(.engine("panne")))
        #expect(await until { !sleeper.isSleeping })
    }

    /// Le temps que met `feed.start` à rendre la main (le vrai micro construit un moteur audio à traitement de la voix à chaque
    /// dictée) ne compte pas dans le délai de la première tranche : il court depuis l'ouverture, pas avant.
    @Test func theTimeTheMicrophoneTakesToOpenIsNotChargedAgainstTheTimeout() async {
        let sleeper = TickSleeper()
        let clock = TestClock()
        let feed = SlowStartFeed(duration: 5, clock: clock)
        let session = DictationSession(
            feed: feed, detector: ScriptedDetector(), preview: nil, final: ScriptedTranscriber(text: "texte"),
            config: DictationConfig(language: "fr", padding: 0), now: clock.reader, watchdog: sleeper.watchdog)
        let log = SnapshotLog(session.snapshots)

        await session.start()
        await sleeper.waitForSleeps(1)
        #expect(await session.phase == .recording)

        // Premier sondage : le micro n'a rien livré, mais il vient de s'ouvrir (l'ouverture a duré 5 s).
        sleeper.tick()
        await sleeper.waitForSleeps(2)
        #expect(await session.phase == .recording)

        // Le délai de la première tranche écoulé depuis l'ouverture : l'échec.
        clock.advance(by: 3)
        sleeper.tick()
        #expect(await log.waitForEnd().last?.phase == .failed(.microphone(Self.reason)))
    }

    // MARK: - Tolérance pour la première tranche (M3)

    /// Aucune tranche depuis l'ouverture : trois secondes de tolérance, pas une.
    @Test func theFirstChunkGetsThreeSecondsAfterTheMicrophoneOpened() async {
        let sleeper = TickSleeper()
        let clock = TestClock()
        let session = DictationSession(
            feed: SlowStartFeed(duration: 0, clock: clock), detector: ScriptedDetector(), preview: nil,
            final: ScriptedTranscriber(text: "texte"), config: DictationConfig(language: "fr", padding: 0),
            now: clock.reader, watchdog: sleeper.watchdog)
        let log = SnapshotLog(session.snapshots)
        await session.start()
        await sleeper.waitForSleeps(1)

        clock.advance(by: 2.9)
        sleeper.tick()
        await sleeper.waitForSleeps(2)
        #expect(await session.phase == .recording)

        clock.advance(by: 0.1)
        sleeper.tick()
        #expect(await log.waitForEnd().last?.phase == .failed(.microphone(Self.reason)))
    }

    /// Une première tranche tardive (2,5 s) reçue : la tolérance est celle de l'écart entre tranches, 1 s.
    @Test func onceAChunkHasArrivedTheGapBetweenChunksIsOneSecond() async {
        let sleeper = TickSleeper()
        let rig = makeRig(chunks: [], events: [:], watchdog: sleeper.watchdog)
        await rig.session.start()
        await sleeper.waitForSleeps(1)

        rig.clock.advance(by: 2.5)
        rig.feed.push(AudioChunk(samples: [Float](repeating: 0, count: 1600), sampleRate: 16000))
        sleeper.tick()
        await sleeper.waitForSleeps(2)
        #expect(await rig.session.phase == .recording)

        rig.clock.advance(by: 0.9)
        sleeper.tick()
        await sleeper.waitForSleeps(3)
        #expect(await rig.session.phase == .recording)

        rig.clock.advance(by: 0.1)
        sleeper.tick()
        #expect(await rig.outcome() == .failed(.microphone(Self.reason)))
    }

    /// Une tranche livrée pendant l'ouverture compte comme première tranche : la limite d'une seconde s'applique ensuite.
    @Test func aChunkDeliveredWhileTheMicrophoneOpensEndsTheFirstChunkTolerance() async {
        let sleeper = TickSleeper()
        let rig = await recordingRig(sleeper: sleeper)   // une tranche livrée à l'ouverture
        rig.clock.advance(by: 1.0)
        sleeper.tick()
        #expect(await rig.outcome() == .failed(.microphone(Self.reason)))
    }

    /// Un micro qui ne démarre pas : la session échoue à l'ouverture, aucune surveillance n'est lancée.
    @Test func noWatchdogRunsWhenTheMicrophoneDoesNotStart() async {
        let sleeper = TickSleeper()
        let rig = makeRig(startError: .noInputDevice, watchdog: sleeper.watchdog)
        await rig.session.start()
        #expect(await rig.outcome() == .failed(.microphone("aucun micro utilisable n'a été trouvé")))
        #expect(sleeper.started == 0)
    }

    /// Pas de chien de garde (le défaut, celui de `live` et des autres tests) : un micro qui se tait n'est pas surveillé.
    @Test func withoutAWatchdogNothingIsWatched() async {
        let rig = makeRig(chunks: [rampChunk(0..<1000)])
        await rig.session.start()
        // La tranche livrée à l'ouverture est traitée par la pompe avant que l'horloge ne saute (sinon la durée maximale, et
        // non le micro, terminerait la prise).
        _ = await rig.log.wait { $0.level > 0 }
        rig.clock.advance(by: 3600)
        await settleBriefly()
        #expect(await rig.session.phase == .recording)
        #expect(await rig.session.watchdogTimeout == nil)
        await rig.session.cancel()
    }

    @Test func theApplicationsWatchdogIsOneSecondChecked4TimesASecond() {
        #expect(MicrophoneWatchdog.system.timeout == 1)
        #expect(MicrophoneWatchdog.system.firstChunkTimeout == 3)
        #expect(MicrophoneWatchdog.system.pollInterval == 0.25)
    }

    /// Une session libérée sans phase terminale ne laisse aucune tâche : le chien de garde se termine avec elle.
    @Test func aSessionThatIsDroppedLeavesNoWatchdogTask() async {
        let sleeper = TickSleeper()
        var rig: Rig? = makeRig(chunks: [rampChunk(0..<1000)], watchdog: sleeper.watchdog)
        await rig?.session.start()
        await sleeper.waitForSleeps(1)
        #expect(sleeper.isSleeping)

        rig = nil

        #expect(await until { !sleeper.isSleeping })
        #expect(sleeper.cancelled == 1)
    }
}

/// Rend la main aux tâches en attente un nombre borné de fois (pour prouver qu'une chose n'a PAS lieu).
private func settleBriefly() async {
    for _ in 0..<200 { await Task.yield() }
}

/// Rend la main jusqu'à ce que `condition` soit vraie (au plus quelques milliers de passages, sans horloge).
private func until(_ condition: () -> Bool) async -> Bool {
    for round in 0..<20000 {
        if condition() { return true }
        if round % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) } else { await Task.yield() }
    }
    return condition()
}

/// Un micro dont l'ouverture dure `duration` secondes de l'horloge du test, sans livrer de tranche.
private final class SlowStartFeed: MicrophoneFeed, @unchecked Sendable {
    private let duration: Double
    private let clock: TestClock

    init(duration: Double, clock: TestClock) {
        self.duration = duration
        self.clock = clock
    }

    func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws { clock.advance(by: duration) }
    func stop() {}
}
