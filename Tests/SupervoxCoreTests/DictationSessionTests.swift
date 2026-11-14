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
        // Le flux d'instantanés est clos : seule la phase de la session montre si le résultat tardif a été pris en compte.
        #expect(await rig.session.phase == .cancelled)
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
        // Un second appel au moteur (à tort) répondrait « deux » tout de suite, au lieu de retenir le test.
        let final = ScriptedTranscriber(reply: { $0 == 0 ? .hold : .text("deux") })
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
        #expect(await rig.session.phase == .finished("un"))
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

    @Test func aFinishRequestedWhilePreparingEndsTheTakeWithoutEverOpeningTheMicrophone() async {
        // `finish()` est retenu pendant `preparing` : la touche relâchée trop tôt n'est pas perdue. Le micro n'est pas
        // ouvert pour une prise qui n'aurait duré que quelques millisecondes : fin directe, sans parole.
        let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)])
        let release = Gate()
        rig.detector.prepareRelease = release
        let starting = Task { await rig.session.start() }
        await rig.detector.prepareEntered.wait()

        await rig.session.finish()
        release.open()
        await starting.value

        #expect(await rig.outcome() == .failed(.noSpeech))
        #expect(rig.log.phases == [.idle, .preparing, .failed(.noSpeech)])
        #expect(rig.feed.starts == 0)
        #expect(rig.final.calls.isEmpty)
    }

    @Test func cancelAfterARetainedFinishIsCancelled() async {
        let rig = makeRig(chunks: tenBlocks, events: [3: .speechStart(sample: 3000)])
        let release = Gate()
        rig.detector.prepareRelease = release
        let starting = Task { await rig.session.start() }
        await rig.detector.prepareEntered.wait()

        await rig.session.finish()
        await rig.session.cancel()
        release.open()
        await starting.value

        #expect(await rig.outcome() == .cancelled)
        #expect(rig.log.phases == [.idle, .preparing, .cancelled])
        #expect(rig.feed.starts == 0)
    }

    @Test func aFinishRetainedWhilePreparingAndARefusedMicrophoneStillFailsOnTheFinishRule() async {
        // Le micro n'est même pas demandé : la panne de `feed.start` n'est pas atteinte.
        let rig = makeRig(startError: .noInputDevice)
        let release = Gate()
        rig.detector.prepareRelease = release
        let starting = Task { await rig.session.start() }
        await rig.detector.prepareEntered.wait()

        await rig.session.finish()
        release.open()
        await starting.value

        #expect(await rig.outcome() == .failed(.noSpeech))
        #expect(rig.feed.starts == 0)
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

// MARK: - Aperçu, niveau, durée maximale, rééchantillonnage

/// Pousse le bloc de rang `block` (1 000 échantillons de la rampe) à l'instant `time` et attend que la session l'ait
/// traité : chaque tranche traitée donne un instantané dont `elapsed` vaut `time`. Les instants sont des multiples de
/// 1/8 s, exacts en binaire.
private func pushBlock(_ block: Int, at time: Double, in rig: Rig) async {
    rig.clock.set(time)
    rig.feed.push(rampChunk(block * 1000..<(block + 1) * 1000))
    _ = await rig.log.wait { $0.elapsed == time }
}

private func ramp(_ range: Range<Int>) -> AudioClip { AudioClip(samples: rampSamples(range), sampleRate: 16000) }

@Suite(.timeLimit(.minutes(1)))
struct DictationPreviewTests {
    private static let config = DictationConfig(language: "fr", vocabulary: ["alpha"], previewInterval: 0.5, padding: 0)

    @Test func closedSegmentsAreTranscribedOnceAndFrozenTheOpenOneAtMostOncePerIntervalAndNeverTwoPassesAtOnce() async {
        let preview = ScriptedTranscriber(reply: { _ in .hold })
        let rig = makeRig(events: [1: .speechStart(sample: 1000), 6: .speechEnd(sample: 6000), 8: .speechStart(sample: 8000)],
                          preview: preview, config: Self.config)
        await rig.session.start()

        await pushBlock(0, at: 0.125, in: rig)
        await pushBlock(1, at: 0.25, in: rig)   // la voix commence : première passe sur le passage ouvert, tout de suite
        await preview.waitForCalls(1)
        #expect(preview.calls[0] == .init(clip: ramp(1000..<2000), language: "fr", vocabulary: ["alpha"]))
        preview.release(call: 0, text: "bon")
        _ = await rig.log.wait { $0.liveText == "bon" }

        await pushBlock(2, at: 0.5, in: rig)    // 0,25 s depuis la passe : trop tôt, pas de passe
        await pushBlock(3, at: 0.875, in: rig)  // 0,625 s : une passe, sur tout le passage ouvert
        await preview.waitForCalls(2)
        #expect(preview.calls[1].clip == ramp(1000..<4000))

        await pushBlock(4, at: 2.0, in: rig)    // l'intervalle est écoulé mais la passe précédente n'a pas rendu : pas de passe
        preview.release(call: 1, text: "bon jour")
        _ = await rig.log.wait { $0.liveText == "bon jour" }

        await pushBlock(5, at: 2.125, in: rig)
        await preview.waitForCalls(3)
        #expect(preview.calls[2].clip == ramp(1000..<6000))   // la passe sautée à 2,0 n'a donc pas eu lieu
        preview.release(call: 2, text: "bon jour à tous")
        _ = await rig.log.wait { $0.liveText == "bon jour à tous" }

        await pushBlock(6, at: 2.25, in: rig)   // la voix s'arrête : le passage clos part seul, sans attendre l'intervalle
        await preview.waitForCalls(4)
        #expect(preview.calls[3].clip == ramp(1000..<6000))
        // Pendant la passe du passage clos, le texte du passage ouvert reste affiché : pas de clignotement.
        #expect(rig.log.items.last?.liveText == "bon jour à tous")
        await pushBlock(7, at: 2.5, in: rig)
        preview.release(call: 3, text: "Bonjour à tous.")
        _ = await rig.log.wait { $0.liveText == "Bonjour à tous." }

        await pushBlock(8, at: 2.625, in: rig)  // un second passage commence
        await preview.waitForCalls(5)
        #expect(preview.calls[4].clip == ramp(8000..<9000))   // et le premier, figé, n'est pas retranscrit
        preview.release(call: 4, text: "Deux")
        _ = await rig.log.wait { $0.liveText == "Bonjour à tous. Deux" }

        await rig.session.finish()
        #expect(await rig.outcome() == .finished("texte"))
        #expect(preview.calls.count == 5)
        #expect(rig.final.calls.count == 1)
    }

    @Test func theOpenSegmentPreviewOnlyGetsTheLastPreviewWindowSeconds() async {
        let preview = ScriptedTranscriber(text: "x")
        // 0,15 s à 16 kHz = 2 400 échantillons.
        let config = DictationConfig(language: "fr", previewInterval: 0.5, previewWindow: 0.15, padding: 0)
        let rig = makeRig(events: [1: .speechStart(sample: 1000)], preview: preview, config: config)
        await rig.session.start()
        for block in 0..<6 { await pushBlock(block, at: Double(block + 1) / 8, in: rig) }
        await preview.waitForCalls(2)

        // Première passe à 0,25 s, au bloc 1 (2 000 échantillons reçus, passage ouvert depuis 1 000) ; la suivante, 0,5 s
        // plus tard, au bloc 5 (6 000 reçus) : le passage ouvert fait 5 000 échantillons, la fenêtre n'en donne que 2 400.
        #expect(preview.calls[0].clip == ramp(1000..<2000))
        #expect(preview.calls[1].clip == ramp(3600..<6000))
        await rig.session.cancel()
    }

    @Test func withoutAPreviewEngineTheSessionRunsAndLiveTextStaysEmpty() async {
        let rig = makeRig(events: [1: .speechStart(sample: 1000)], preview: nil, config: Self.config)
        await rig.session.start()
        await pushBlock(0, at: 0.125, in: rig)
        await pushBlock(1, at: 0.25, in: rig)
        await pushBlock(2, at: 1.0, in: rig)

        await rig.session.finish()

        #expect(await rig.outcome() == .finished("texte"))
        #expect(rig.log.items.allSatisfy { $0.liveText.isEmpty })
    }

    @Test func aPreviewEngineErrorKeepsTheLiveTextAndTheSessionGoesOn() async {
        // Appel 0 : le passage ouvert, « a ». Appel 1 : le passage clos, en erreur ; il garde « a » (jamais retenté).
        // Appel 2 : le second passage ouvert, en erreur aussi ; appel 3 : réussit.
        let preview = ScriptedTranscriber(reply: { index in
            switch index {
            case 0: .text("a")
            case 1, 2: .fail(TestFailure("moteur d'aperçu en panne"))
            default: .text("b")
            }
        })
        let rig = makeRig(events: [1: .speechStart(sample: 1000), 2: .speechEnd(sample: 2000), 4: .speechStart(sample: 4000)],
                          preview: preview, config: Self.config)
        await rig.session.start()
        await pushBlock(0, at: 0.125, in: rig)
        await pushBlock(1, at: 0.25, in: rig)
        _ = await rig.log.wait { $0.liveText == "a" }

        await pushBlock(2, at: 0.375, in: rig)  // passage clos : passe en erreur
        await preview.waitForCalls(2)
        await pushBlock(3, at: 5.0, in: rig)    // plus de passage à transcrire : si la passe close était retentée, ce serait l'appel 2
        await pushBlock(4, at: 6.0, in: rig)    // second passage ouvert : appel 2, en erreur
        await preview.waitForCalls(3)
        #expect(preview.calls[2].clip == ramp(4000..<5000))
        #expect(rig.log.items.last?.liveText == "a")
        await pushBlock(5, at: 7.0, in: rig)    // appel 3 : réussit
        _ = await rig.log.wait { $0.liveText == "a b" }

        await rig.session.finish()
        #expect(await rig.outcome() == .finished("texte"))
        // Une fois affiché, « a » ne disparaît pas (ni sur l'erreur du passage clos, ni sur celle du passage ouvert).
        let texts = rig.log.items.map(\.liveText)
        let firstA = texts.firstIndex(of: "a")
        #expect(firstA != nil)
        #expect(texts.drop(while: { $0 != "a" }).allSatisfy { $0 == "a" || $0 == "a b" })
    }

    @Test func aPreviewEnginePrepareErrorDisablesThePreviewButNotTheSession() async {
        let preview = ScriptedTranscriber(text: "x")
        preview.prepareError = TestFailure("aperçu indisponible")
        let rig = makeRig(events: [1: .speechStart(sample: 1000)], preview: preview, config: Self.config)
        await rig.session.start()
        await pushBlock(0, at: 0.125, in: rig)
        await pushBlock(1, at: 0.25, in: rig)
        await pushBlock(2, at: 1.0, in: rig)

        await rig.session.finish()

        #expect(await rig.outcome() == .finished("texte"))
        #expect(preview.calls.isEmpty)
    }

    @Test func aPreviewResultThatArrivesWhileFinalizingChangesNothing() async {
        let preview = ScriptedTranscriber(reply: { _ in .hold })
        let final = ScriptedTranscriber(reply: { _ in .hold })
        let rig = makeRig(events: [1: .speechStart(sample: 1000)], final: final, preview: preview, config: Self.config)
        let previewHandled = Gate()
        await rig.session.onPreviewPassFinished { previewHandled.open() }
        await rig.session.start()
        await pushBlock(0, at: 0.125, in: rig)
        await pushBlock(1, at: 0.25, in: rig)
        await preview.waitForCalls(1)
        let finishing = Task { await rig.session.finish() }
        await final.waitForCalls(1)   // la prise est en `finalizing`

        preview.release(call: 0, text: "trop tard")
        await previewHandled.wait()   // la session a reçu la passe d'aperçu
        final.release(call: 0, text: "définitif")
        await finishing.value

        #expect(await rig.outcome() == .finished("définitif"))
        #expect(rig.log.items.allSatisfy { $0.liveText.isEmpty })
    }

    @Test func aPreviewResultForASegmentThatClosedInTheMeantimeIsDroppedItsOwnPassGivesTheText() async {
        let preview = ScriptedTranscriber(reply: { _ in .hold })
        let rig = makeRig(events: [1: .speechStart(sample: 1000), 3: .speechEnd(sample: 3000)], preview: preview, config: Self.config)
        let handled = Gate()
        await rig.session.onPreviewPassFinished { handled.open() }
        await rig.session.start()
        await pushBlock(0, at: 0.125, in: rig)
        await pushBlock(1, at: 0.25, in: rig)   // passe 0 sur le passage ouvert, retenue
        await preview.waitForCalls(1)
        await pushBlock(2, at: 0.375, in: rig)
        await pushBlock(3, at: 0.5, in: rig)    // le passage se ferme pendant la passe 0

        preview.release(call: 0, text: "périmé")
        await handled.wait()
        await preview.waitForCalls(2)           // la passe du passage clos part dès que la précédente a rendu
        #expect(preview.calls[1].clip == ramp(1000..<3000))
        #expect(rig.log.items.allSatisfy { $0.liveText != "périmé" })
        preview.release(call: 1, text: "vrai")
        _ = await rig.log.wait { $0.liveText == "vrai" }
        await rig.session.cancel()
    }

    // MARK: Niveau et temps écoulé

    @Test func everyChunkPublishesItsLevelAndTheElapsedTimeFromTheClock() async {
        let clock = TestClock(2)
        let rig = makeRig(clock: clock)
        await rig.session.start()

        clock.set(5)
        let loud = [Float](repeating: 0.1, count: 1000)
        rig.feed.push(AudioChunk(samples: loud, sampleRate: 16000))
        let first = await rig.log.wait { $0.elapsed == 3 }
        clock.set(5.5)
        rig.feed.push(AudioChunk(samples: [Float](repeating: 0, count: 1000), sampleRate: 16000))
        let second = await rig.log.wait { $0.elapsed == 3.5 }

        #expect(first?.level == DictationSession.level(of: loud))
        #expect(first?.level ?? 0 > 0.5)
        #expect(second?.level == 0)
        await rig.session.cancel()
    }

    // MARK: Durée maximale

    @Test func reachingMaxDurationFinalizesTheSessionByItself() async {
        let config = DictationConfig(language: "fr", padding: 0, maxDuration: 10)
        let rig = makeRig(events: [1: .speechStart(sample: 1000)], config: config)
        await rig.session.start()
        await pushBlock(0, at: 1, in: rig)
        await pushBlock(1, at: 9.875, in: rig)
        #expect(rig.log.phases == [.idle, .preparing, .recording])   // 9,875 s : pas encore

        await pushBlock(2, at: 10, in: rig)   // pas de `finish()` : la durée maximale suffit

        #expect(await rig.outcome() == .finished("texte"))
        #expect(rig.log.phases == [.idle, .preparing, .recording, .finalizing, .finished("texte")])
        #expect(rig.feed.stops == 1)
        #expect(rig.final.calls.map(\.clip) == [ramp(1000..<3000)])
    }

    // MARK: Rééchantillonnage

    @Test func chunksAtTheMicrophoneRateAreResampledTo16kHzContinuously() async {
        let chunks = (0..<3).map { rampChunk($0 * 4800..<($0 + 1) * 4800, rate: 48000) }
        let reference = StreamingResampler(from: 48000, to: 16000)!
        let expected = chunks.flatMap { reference.push($0.samples) } + reference.finish()
        let rig = makeRig(chunks: chunks, events: [0: .speechStart(sample: 0)])

        await rig.session.start()
        await rig.session.finish()

        #expect(expected.count > 4000)
        #expect(rig.final.calls.map(\.clip) == [AudioClip(samples: expected, sampleRate: 16000)])
    }

    @Test func aConverterFailureWhileRecordingFailsTheTakeWithAMicrophoneError() async {
        let rig = makeRig(chunks: [rampChunk(0..<4800, rate: 48000)], events: [0: .speechStart(sample: 0)],
                          makeResampler: { from, to in
            let resampler = StreamingResampler(from: from, to: to)
            resampler?.injectedFault = { true }
            return resampler
        })

        await rig.session.start()

        guard case .failed(.microphone(let reason)) = await rig.outcome() else {
            Issue.record("phase terminale inattendue")
            return
        }
        #expect(!reason.isEmpty)
        #expect(rig.feed.stops == 1)
        #expect(rig.final.calls.isEmpty)
    }

    @Test func aConverterFailureInTheTailAtTheEndOfTheTakeIsNotTakenForACompleteTake() async {
        let armed = OSAllocatedUnfairLock(initialState: false)
        let rig = makeRig(events: [0: .speechStart(sample: 0)], makeResampler: { from, to in
            let resampler = StreamingResampler(from: from, to: to)
            resampler?.injectedFault = { armed.withLock { $0 } }
            return resampler
        })
        await rig.session.start()
        rig.clock.set(1)
        rig.feed.push(rampChunk(0..<4800, rate: 48000))
        _ = await rig.log.wait { $0.elapsed == 1 }
        armed.withLock { $0 = true }   // la panne n'arrive qu'à `finish()` : la queue du filtre

        await rig.session.finish()

        guard case .failed(.microphone) = await rig.outcome() else {
            Issue.record("la prise tronquée est partie au moteur final : \(String(describing: await rig.outcome()))")
            return
        }
        #expect(rig.final.calls.isEmpty)
    }

    @Test func aRateThatChangesDuringTheTakeFailsIt() async {
        let rig = makeRig()
        await rig.session.start()
        await pushBlock(0, at: 0.125, in: rig)

        rig.feed.push(rampChunk(0..<4800, rate: 48000))

        guard case .failed(.microphone) = await rig.outcome() else {
            Issue.record("phase terminale inattendue")
            return
        }
        #expect(rig.feed.stops == 1)
    }

    @Test func anUnusableMicrophoneRateFailsTheTake() async {
        let rig = makeRig(chunks: [AudioChunk(samples: [0.1, 0.2], sampleRate: 0)])
        await rig.session.start()
        guard case .failed(.microphone) = await rig.outcome() else {
            Issue.record("phase terminale inattendue")
            return
        }
        #expect(rig.feed.stops == 1)
    }
}
