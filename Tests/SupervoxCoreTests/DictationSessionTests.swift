import Foundation
import os
import Testing
@testable import SupervoxCore

// MARK: - Niveau affichable

@Test func levelMapsMinusSixtyDecibelsToZeroAndZeroDecibelsToOne() {
    let tolerance: Float = 1e-5
    #expect(DictationSession.level(of: []) == 0)
    #expect(DictationSession.level(of: [Float](repeating: 0, count: 100)) == 0)
    // Signal constant d'amplitude a : RMS = a, donc 20·log10(a) dB.
    #expect(abs(DictationSession.level(of: [Float](repeating: 1, count: 100)) - 1) < tolerance)
    #expect(abs(DictationSession.level(of: [Float](repeating: 0.001, count: 100)) - 0) < tolerance)   // -60 dB
    #expect(abs(DictationSession.level(of: [Float](repeating: 0.01, count: 100)) - 1.0 / 3) < tolerance)   // -40 dB
    #expect(abs(DictationSession.level(of: [Float](repeating: 0.1, count: 100)) - 2.0 / 3) < tolerance)   // -20 dB
    // Le signe ne compte pas : c'est une puissance.
    #expect(abs(DictationSession.level(of: [0.1, -0.1, 0.1, -0.1]) - 2.0 / 3) < tolerance)
}

@Test func levelStaysWithinZeroAndOne() {
    #expect(DictationSession.level(of: [Float](repeating: 0.0001, count: 10)) == 0)   // sous -60 dB
    #expect(DictationSession.level(of: [Float](repeating: 8, count: 10)) == 1)        // au-dessus de 0 dB
    #expect(DictationSession.level(of: [.nan, 0.5]) == 0)
    #expect(DictationSession.level(of: [.infinity]) == 1)
}

// MARK: - Types

@Test func everyFailureHasACompleteFrenchSentence() {
    let messages = [
        DictationFailure.microphone("accès refusé").message,
        DictationFailure.noSpeech.message,
        DictationFailure.engine("modèle absent").message,
    ]
    for message in messages {
        #expect(message.last == ".", "\(message)")
        #expect(message.first?.isUppercase == true, "\(message)")
    }
    #expect(DictationFailure.microphone("accès refusé").message.contains("accès refusé"))
    #expect(DictationFailure.engine("modèle absent").message.contains("modèle absent"))
    // Une raison qui finit déjà par un point ne donne pas « .. ».
    #expect(!DictationFailure.microphone("accès refusé.").message.contains(".."))
    #expect(DictationFailure.microphone("accès refusé.").message.hasSuffix("accès refusé."))
}

@Test func defaultConfigurationValues() {
    let config = DictationConfig(language: "fr")
    #expect(config.language == "fr")
    #expect(config.vocabulary.isEmpty)
    #expect(config.previewInterval == 0.5)
    #expect(config.previewWindow == 15)
    #expect(config.padding == 0.3)
    #expect(config.maxDuration == 300)
}

// MARK: - Session : prise, fin, annulation

/// Dix blocs de 1 000 échantillons (16 kHz, le détecteur double a des blocs de 1 000), en trois tranches inégales.
private let tenBlocks = [rampChunk(0..<1500), rampChunk(1500..<4000), rampChunk(4000..<10000)]

@Suite(.timeLimit(.minutes(1)))
struct DictationSessionFlowTests {
    @Test func aTakeGoesThroughEveryPhaseAndEndsWithTheFinalText() async {
        let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000), 6: .speechEnd(sample: 6000)])

        await rig.session.start()
        await rig.session.finish()

        #expect(await rig.outcome() == .finished("texte"))
        #expect(rig.log.phases == [.idle, .preparing, .recording, .finalizing, .finished("texte")])
        #expect(rig.detector.prepares == 1)
        #expect(rig.detector.resets == 1)
        #expect(rig.final.prepares == 1)
    }

    @Test func noSpeechDetectedFailsAndTheFinalEngineIsNeverCalled() async {
        let rig = makeRig(chunks: tenBlocks)   // le détecteur n'entend rien

        await rig.session.start()
        await rig.session.finish()

        #expect(await rig.outcome() == .failed(.noSpeech))
        #expect(rig.final.calls.isEmpty)
        #expect(rig.feed.stops == 1)
    }

    @Test func theFinalEngineGetsTheSpokenClipWithPaddingLanguageAndVocabularyExactlyOnce() async {
        let config = DictationConfig(language: "fr", vocabulary: ["alpha", "beta"], padding: 0.1)
        let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000), 6: .speechEnd(sample: 6000)],
                          final: ScriptedTranscriber(text: "  Bonjour\n"), config: config)

        await rig.session.start()
        await rig.session.finish()

        // 0,1 s à 16 kHz = 1 600 échantillons de chaque côté de 3 000..<6 000.
        let expected = AudioClip(samples: rampSamples(1400..<7600), sampleRate: 16000)
        #expect(rig.final.calls == [.init(clip: expected, language: "fr", vocabulary: ["alpha", "beta"])])
        #expect(await rig.outcome() == .finished("Bonjour"))
    }

    @Test func aSegmentStillOpenAtFinishIsTranscribedUpToTheEndOfTheTake() async {
        // Le détecteur n'envoie `speechEnd` qu'après environ une seconde de silence : à `finish()` le passage reste ouvert.
        let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)])

        await rig.session.start()
        await rig.session.finish()

        #expect(rig.final.calls.map(\.clip) == [AudioClip(samples: rampSamples(3000..<10000), sampleRate: 16000)])
    }

    @Test func theLastPartialBlockIsFlushedToTheDetectorBeforeDecidingThereIsNoSpeech() async {
        // 2 500 échantillons : deux blocs entiers et un reste de 500 ; la voix n'est entendue que dans le bloc de fin.
        let rig = makeRig(chunks: [rampChunk(0..<2500)], events: [2: .speechStart(sample: 2000)])

        await rig.session.start()
        await rig.session.finish()

        #expect(rig.detector.blocks.count == 3)
        #expect(rig.detector.blocks[2] == rampSamples(2000..<2500) + [Float](repeating: 0, count: 500))
        #expect(rig.final.calls.map(\.clip) == [AudioClip(samples: rampSamples(2000..<2500), sampleRate: 16000)])
        #expect(await rig.outcome() == .finished("texte"))
    }

    @Test func emptyOrBlankFinalTextIsNoSpeech() async {
        for text in ["", "  \n\t "] {
            let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)], final: ScriptedTranscriber(text: text))
            await rig.session.start()
            await rig.session.finish()
            #expect(await rig.outcome() == .failed(.noSpeech), "texte : \(text.debugDescription)")
        }
    }

    @Test func chunksDeliveredBeforeFeedStartReturnsAreAllProcessedInOrder() async {
        // Le micro scripté livre tout pendant `feed.start()`, en 200 tranches de tailles variées : aucune ne se perd,
        // l'ordre est celui de la prise. Les blocs vus par le détecteur reconstituent donc la rampe.
        var chunks: [AudioChunk] = []
        var next = 0
        for i in 0..<200 {
            let size = 37 + (i * 13) % 211
            chunks.append(rampChunk(next..<(next + size)))
            next += size
        }
        let rig = makeRig(chunks: chunks)

        await rig.session.start()
        await rig.session.finish()

        let seen = rig.detector.blocks.flatMap { $0 }
        let fullBlocks = next / 1000 * 1000
        #expect(seen.prefix(fullBlocks) == rampSamples(0..<fullBlocks)[...])
        // Dernier bloc : le reste, complété de zéros.
        #expect(rig.detector.blocks.count == next / 1000 + (next % 1000 == 0 ? 0 : 1))
        #expect(Array(seen.dropFirst(fullBlocks)) == rampSamples(fullBlocks..<next) + [Float](repeating: 0, count: (1000 - next % 1000) % 1000))
    }

    // MARK: Annulation

    @Test func cancelDuringFinalizingWinsAndTheLateEngineResultChangesNothing() async {
        let final = ScriptedTranscriber(reply: { _ in .hold })
        let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)], final: final)
        await rig.session.start()
        let finishing = Task { await rig.session.finish() }
        await final.waitForCalls(1)
        await rig.log.wait(phase: .finalizing)

        await rig.session.cancel()
        final.release(call: 0, text: "arrivé trop tard")
        await finishing.value

        #expect(await rig.outcome() == .cancelled)
        #expect(rig.log.phases == [.idle, .preparing, .recording, .finalizing, .cancelled])
    }

    @Test func cancelWhileRecordingStopsTheCaptureAndNeverCallsTheEngines() async {
        let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)])
        await rig.session.start()

        await rig.session.cancel()

        #expect(await rig.outcome() == .cancelled)
        #expect(rig.feed.stops == 1)
        #expect(rig.final.calls.isEmpty)
    }

    @Test func cancelWhilePreparingNeverOpensTheMicrophone() async {
        let rig = makeRig(chunks: tenBlocks)
        let release = Gate()
        rig.detector.prepareRelease = release
        let starting = Task { await rig.session.start() }
        await rig.detector.prepareEntered.wait()

        await rig.session.cancel()
        release.open()
        await starting.value

        #expect(await rig.outcome() == .cancelled)
        #expect(rig.feed.starts == 0)
    }

    @Test func cancelBeforeStartIsCancelled() async {
        let rig = makeRig()
        await rig.session.cancel()
        #expect(await rig.outcome() == .cancelled)
        #expect(rig.log.phases == [.idle, .cancelled])
    }

    // MARK: Appels répétés

    @Test func aSecondFinishChangesNothing() async {
        let final = ScriptedTranscriber(reply: { _ in .hold })
        let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)], final: final)
        await rig.session.start()
        let first = Task { await rig.session.finish() }
        await final.waitForCalls(1)

        await rig.session.finish()   // pendant `finalizing`
        final.release(call: 0, text: "un")
        await first.value
        await rig.session.finish()   // après `finished`

        #expect(final.calls.count == 1)
        #expect(await rig.outcome() == .finished("un"))
        #expect(rig.feed.stops == 1)
    }

    @Test func finishAfterCancelAndCancelAfterFinishChangeNothing() async {
        let cancelled = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)])
        await cancelled.session.start()
        await cancelled.session.cancel()
        await cancelled.session.finish()
        #expect(await cancelled.outcome() == .cancelled)
        #expect(cancelled.final.calls.isEmpty)

        let finished = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)])
        await finished.session.start()
        await finished.session.finish()
        await finished.session.cancel()
        #expect(await finished.outcome() == .finished("texte"))
    }

    @Test func aSecondStartChangesNothing() async {
        let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)])

        await rig.session.start()
        await rig.session.start()
        await rig.session.finish()
        await rig.session.start()   // après la fin

        await rig.log.waitForEnd()
        #expect(rig.feed.starts == 1)
        #expect(rig.detector.prepares == 1)
        #expect(rig.log.phases == [.idle, .preparing, .recording, .finalizing, .finished("texte")])
    }

    @Test func finishWhilePreparingHasNoEffect() async {
        // Décision du brief : `finish()` ne vaut que depuis `recording`. La prise démarre donc quand même ; c'est à
        // l'appelant (tâche 6) de rappeler `finish()` s'il l'a demandé trop tôt.
        let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)])
        let release = Gate()
        rig.detector.prepareRelease = release
        let starting = Task { await rig.session.start() }
        await rig.detector.prepareEntered.wait()

        await rig.session.finish()
        release.open()
        await starting.value

        await rig.session.cancel()
        // Pas de `finalizing` : le `finish()` du début n'a rien déclenché.
        await rig.log.waitForEnd()
        #expect(rig.log.phases == [.idle, .preparing, .recording, .cancelled])
    }

    // MARK: Échecs

    @Test func microphoneStartErrorFailsWithoutEverRecording() async {
        let reason = "accès refusé : l'autoriser dans Réglages Système"
        let rig = makeRig(startError: .microphoneAccessDenied(reason))

        await rig.session.start()

        #expect(await rig.outcome() == .failed(.microphone(reason)))
        #expect(rig.log.phases == [.idle, .preparing, .failed(.microphone(reason))])
        #expect(rig.final.calls.isEmpty)
    }

    @Test func microphoneErrorsWithoutAMessageGetAFrenchOne() async {
        let rig = makeRig(startError: .noInputDevice)
        await rig.session.start()
        #expect(await rig.outcome() == .failed(.microphone("aucun micro utilisable n'a été trouvé")))
    }

    @Test func finalEngineErrorFailsWithItsMessageAndTheCaptureIsStopped() async {
        let final = ScriptedTranscriber(reply: { _ in .fail(TestFailure("modèle indisponible")) })
        let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)], final: final)

        await rig.session.start()
        await rig.session.finish()

        #expect(await rig.outcome() == .failed(.engine("modèle indisponible")))
        #expect(rig.feed.stops == 1)
    }

    @Test func detectorPrepareErrorFailsBeforeTheMicrophoneOpens() async {
        let rig = makeRig(chunks: tenBlocks)
        rig.detector.prepareError = TestFailure("modèle de voix absent")

        await rig.session.start()

        #expect(await rig.outcome() == .failed(.engine("modèle de voix absent")))
        #expect(rig.feed.starts == 0)
    }

    @Test func finalEnginePrepareErrorFailsBeforeTheMicrophoneOpens() async {
        let final = ScriptedTranscriber(text: "x")
        final.prepareError = TestFailure("modèle final absent")
        let rig = makeRig(chunks: tenBlocks, final: final)

        await rig.session.start()

        #expect(await rig.outcome() == .failed(.engine("modèle final absent")))
        #expect(rig.feed.starts == 0)
    }

    @Test func detectorErrorWhileRecordingAbandonsTheTakeAndStopsTheCapture() async {
        let rig = makeRig(chunks: tenBlocks)
        rig.detector.processFailure = (block: 4, error: TestFailure("inférence en échec"))

        await rig.session.start()

        #expect(await rig.outcome() == .failed(.engine("inférence en échec")))
        #expect(rig.feed.stops == 1)
        #expect(rig.final.calls.isEmpty)
        // Le détecteur n'a plus reçu de bloc après l'erreur (la prise est à abandonner, voir `FluidStreamingVoiceDetector`).
        #expect(rig.detector.blocks.count == 5)
    }

    @Test func aSecondFinishAfterAFailureChangesNothing() async {
        let rig = makeRig(chunks: tenBlocks)
        await rig.session.start()
        await rig.session.finish()
        await rig.session.finish()
        #expect(await rig.outcome() == .failed(.noSpeech))
        #expect(rig.log.phases == [.idle, .preparing, .recording, .finalizing, .failed(.noSpeech)])
    }
}
