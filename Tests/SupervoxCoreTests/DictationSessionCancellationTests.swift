import Foundation
import Testing
@testable import SupervoxCore

// Tour de correction 1 : les relectures de phase qui évitent un effet de bord (appel au moteur final, passe d'aperçu,
// bloc au détecteur) ont chacune leur test. Les moteurs doubles retiennent l'appel à l'endroit voulu : aucune attente.

@Suite(.timeLimit(.minutes(1)))
struct DictationSessionCancellationTests {
    private static let config = DictationConfig(language: "fr", previewInterval: 0.5, padding: 0)

    /// L'utilisateur annule pendant l'inférence du dernier bloc partiel (`flush`) : l'audio d'une dictée annulée ne part
    /// pas au moteur final (qui peut être distant).
    @Test func cancelWhileTheLastBlockIsBeingFlushedNeverCallsTheFinalEngine() async {
        let rig = makeRig(chunks: [rampChunk(0..<2500)], events: [2: .speechStart(sample: 2000)])
        let flush = rig.detector.hold(block: 2)   // le bloc de rang 2 est le reste de 500 échantillons, complété
        await rig.session.start()
        let finishing = Task { await rig.session.finish() }
        await flush.entered.wait()

        await rig.session.cancel()
        flush.release.open()
        await finishing.value

        #expect(await rig.outcome() == .cancelled)
        #expect(rig.final.calls.isEmpty)
        #expect(await rig.session.phase == .cancelled)
    }

    /// Pendant la vidange de fin de prise (`finalizing`), la pompe finit de traiter une tranche : elle ne doit pas lancer
    /// de passe d'aperçu, qui retarderait le moteur final (le moteur d'aperçu peut être le même).
    @Test func noPreviewPassIsStartedWhileFinalizing() async {
        let preview = ScriptedTranscriber(text: "x")
        let rig = makeRig(chunks: [rampChunk(0..<1000)], events: [0: .speechStart(sample: 0)], preview: preview,
                          config: Self.config)
        let drain = rig.detector.hold(block: 0)
        await rig.session.start()
        await drain.entered.wait()   // la pompe est dans le détecteur, avec la première tranche
        let finishing = Task { await rig.session.finish() }
        await rig.log.wait(phase: .finalizing)

        drain.release.open()
        await finishing.value

        #expect(await rig.outcome() == .finished("texte"))
        #expect(await rig.session.previewPassesLaunched == 0)
        #expect(preview.calls.isEmpty)
    }

    /// Annulée pendant le traitement d'une tranche de trois blocs, avec d'autres tranches en file : le détecteur ne
    /// reçoit plus aucun bloc, ni du reste de la tranche en cours ni des tranches suivantes.
    @Test func afterCancelTheDetectorReceivesNoMoreBlocks() async {
        let chunks = [rampChunk(0..<3000), rampChunk(3000..<6000), rampChunk(6000..<9000)]
        let rig = makeRig(chunks: chunks)
        let held = rig.detector.hold(block: 0)
        await rig.session.start()
        await held.entered.wait()

        await rig.session.cancel()
        held.release.open()
        await rig.session.waitUntilPumpEnds()

        #expect(rig.detector.blocks.count == 1)
        #expect(await rig.outcome() == .cancelled)
        #expect(rig.feed.stops == 1)
    }
}

// MARK: - cancel() annule le travail en cours

/// Les moteurs doubles de ces tests respectent l'annulation de tâche (`honorsCancellation`) : un moteur qui l'ignore
/// finit son calcul pour rien, mais la session ne dépend pas de lui.
@Suite(.timeLimit(.minutes(1)))
struct DictationSessionCancelsWorkTests {
    private static let config = DictationConfig(language: "fr", previewInterval: 0.5, padding: 0)

    /// Une passe d'aperçu retenue sur le passage ouvert.
    private func rigWithAPreviewPassInProgress(
        final: ScriptedTranscriber = ScriptedTranscriber(text: "texte")
    ) async -> (rig: Rig, preview: ScriptedTranscriber) {
        let preview = ScriptedTranscriber(honorsCancellation: true, reply: { _ in .hold })
        let rig = makeRig(events: [0: .speechStart(sample: 0)], final: final, preview: preview, config: Self.config)
        await rig.session.start()
        rig.clock.set(0.125)
        rig.feed.push(rampChunk(0..<1000))
        await preview.waitForCalls(1)
        return (rig, preview)
    }

    @Test func cancelCancelsThePreviewPassInProgress() async {
        let (rig, preview) = await rigWithAPreviewPassInProgress()

        await rig.session.cancel()

        await preview.cancellation(of: 0).wait()
        #expect(await rig.outcome() == .cancelled)
    }

    @Test func leavingRecordingCancelsThePreviewPassInProgress() async {
        // Le moteur d'aperçu peut être le même que le moteur final : une passe d'aperçu ne le retient pas pendant `finalizing`.
        let (rig, preview) = await rigWithAPreviewPassInProgress()

        await rig.session.finish()

        await preview.cancellation(of: 0).wait()
        #expect(await rig.outcome() == .finished("texte"))
    }

    @Test func cancelCancelsTheFinalTranscriptionInProgress() async {
        let final = ScriptedTranscriber(honorsCancellation: true, reply: { _ in .hold })
        let rig = makeRig(chunks: [rampChunk(0..<2000)], events: [0: .speechStart(sample: 0)], final: final)
        await rig.session.start()
        let finishing = Task { await rig.session.finish() }
        await final.waitForCalls(1)

        await rig.session.cancel()

        await final.cancellation(of: 0).wait()
        await finishing.value
        #expect(await rig.outcome() == .cancelled)
        #expect(await rig.session.phase == .cancelled)
    }

    @Test func aCancelledCallerOfFinishCancelsTheFinalTranscriptionAndTheTakeIsCancelledNotFailed() async {
        let final = ScriptedTranscriber(honorsCancellation: true, reply: { _ in .hold })
        let rig = makeRig(chunks: [rampChunk(0..<2000)], events: [0: .speechStart(sample: 0)], final: final)
        await rig.session.start()
        let finishing = Task { await rig.session.finish() }
        await final.waitForCalls(1)

        finishing.cancel()

        await final.cancellation(of: 0).wait()
        await finishing.value
        #expect(await rig.outcome() == .cancelled)
    }

    @Test func aCancellationErrorFromTheFinalEngineIsACancellationNotAnEngineFailure() async {
        let final = ScriptedTranscriber(reply: { _ in .fail(CancellationError()) })
        let rig = makeRig(chunks: [rampChunk(0..<2000)], events: [0: .speechStart(sample: 0)], final: final)
        await rig.session.start()
        await rig.session.finish()
        #expect(await rig.outcome() == .cancelled)
    }
}

// MARK: - Session libérée

@Suite(.timeLimit(.minutes(1)))
struct DictationSessionReleaseTests {
    /// Une session qu'on laisse partir sans `finish()` ni `cancel()` ne laisse ni micro ouvert ni lecteur pendu.
    @Test func aSessionReleasedWhileRecordingStopsTheMicrophoneAndClosesTheStream() async {
        let feed = TestFeed(chunks: [rampChunk(0..<2000)])
        let clock = TestClock()
        var session: DictationSession? = makeSession(
            feed: feed, detector: ScriptedDetector(), preview: nil, final: ScriptedTranscriber(text: "x"),
            config: DictationConfig(language: "fr"), clock: clock)
        let log = SnapshotLog(session!.snapshots)
        await session!.start()
        #expect(feed.stops == 0)

        session = nil

        await log.waitForEnd()
        #expect(feed.stops == 1)
        #expect(log.items.last?.phase == .recording)   // aucune phase terminale n'a été inventée
    }
}
