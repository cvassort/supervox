import Foundation
import os
import Testing
@testable import SupervoxCore

private func spoken(_ tag: Float, fellBack: Bool = false) -> Speech {
    Speech(clip: AudioClip(samples: [tag], sampleRate: 8000), fellBack: fellBack)
}

/// Une voix double : compte ses appels et son annulation, et répond comme le test le décide.
private final class ScriptedVoice: SpeechSynthesizer, @unchecked Sendable {
    enum Reply: Sendable { case speech(Speech), fail(SpeechError), hang }
    private let state = OSAllocatedUnfairLock(initialState: (calls: [String](), cancelled: 0))
    private let reply: Reply
    let entered = Gate()
    init(_ reply: Reply) { self.reply = reply }
    var calls: [String] { state.withLock { $0.calls } }
    var cancelled: Int { state.withLock { $0.cancelled } }

    func synthesize(_ text: String) async throws -> Speech {
        state.withLock { $0.calls.append(text) }
        entered.open()
        switch reply {
        case .speech(let speech): return speech
        case .fail(let error): throw error
        case .hang:
            do { try await Task.sleep(for: .seconds(1_000_000)) } catch {
                state.withLock { $0.cancelled += 1 }
                throw error
            }
            return spoken(9)
        }
    }
}

private func fallback(_ primary: ScriptedVoice, _ secondary: ScriptedVoice, sleeper: TickSleeper = TickSleeper(), timeout: Double = 4)
    -> FallbackSpeechSynthesizer {
    FallbackSpeechSynthesizer(primary: primary, fallback: secondary, timeout: timeout, sleep: { try await sleeper.sleep($0) })
}

@Suite(.timeLimit(.minutes(1))) struct FallbackSpeechTests {
    @Test func theChosenVoiceSpeaksWhileItWorksAndTheFallbackIsNotCalled() async throws {
        let primary = ScriptedVoice(.speech(spoken(1))), secondary = ScriptedVoice(.speech(spoken(2)))
        let voice = fallback(primary, secondary)
        #expect(try await voice.synthesize("Un") == spoken(1))
        #expect(try await voice.synthesize("Deux") == spoken(1))
        #expect(primary.calls == ["Un", "Deux"] && secondary.calls.isEmpty)
    }

    @Test func aChosenVoiceThatThrowsIsReplacedByTheFallbackWithFellBack() async throws {
        let primary = ScriptedVoice(.fail(.timedOut)), secondary = ScriptedVoice(.speech(spoken(2)))
        let speech = try await fallback(primary, secondary).synthesize("Bonjour")
        #expect(speech == spoken(2, fellBack: true))
        #expect(primary.calls == ["Bonjour"] && secondary.calls == ["Bonjour"])
    }

    /// Ensuite, la voix choisie n'est plus appelée de tout l'entretien : chaque phrase suivante part droit chez la voix de secours.
    @Test func afterAFailureTheChosenVoiceIsNeverCalledAgain() async throws {
        let primary = ScriptedVoice(.fail(.empty)), secondary = ScriptedVoice(.speech(spoken(2)))
        let voice = fallback(primary, secondary)
        for sentence in ["Un", "Deux", "Trois", "Quatre"] {
            #expect(try await voice.synthesize(sentence) == spoken(2, fellBack: true))
        }
        #expect(primary.calls == ["Un"])
        #expect(secondary.calls == ["Un", "Deux", "Trois", "Quatre"])
    }

    @Test func aChosenVoiceThatSaysNothingInTimeIsReplacedAndItsRequestIsCancelled() async throws {
        let primary = ScriptedVoice(.hang), secondary = ScriptedVoice(.speech(spoken(2))), sleeper = TickSleeper()
        let voice = fallback(primary, secondary, sleeper: sleeper, timeout: 4)
        let task = Task { try await voice.synthesize("Bonjour") }
        await primary.entered.wait()
        await sleeper.waitForSleeps(1)
        #expect(sleeper.requested == [4])

        sleeper.tick()

        #expect(try await outcome(task).get() == spoken(2, fellBack: true))
        #expect(await eventually { primary.cancelled == 1 })
        // Et la voix choisie reste écartée pour la phrase suivante.
        #expect(try await voice.synthesize("Suite") == spoken(2, fellBack: true))
        #expect(primary.calls == ["Bonjour"])
    }

    @Test func aChosenVoiceThatAnswersBeforeTheTimeoutKeepsItsPlaceAndItsTimerIsCancelled() async throws {
        let primary = ScriptedVoice(.speech(spoken(1))), secondary = ScriptedVoice(.speech(spoken(2))), sleeper = TickSleeper()
        let voice = fallback(primary, secondary, sleeper: sleeper)
        #expect(try await voice.synthesize("Bonjour") == spoken(1))
        #expect(await eventually { sleeper.cancelled == 1 })
        #expect(try await voice.synthesize("Suite") == spoken(1))
        #expect(secondary.calls.isEmpty)
    }

    @Test func whenBothVoicesFailTheErrorOfTheFallbackIsThrown() async {
        let primary = ScriptedVoice(.fail(.timedOut)), secondary = ScriptedVoice(.fail(.noVoice(language: "fr-FR")))
        await #expect(throws: SpeechError.noVoice(language: "fr-FR")) { try await fallback(primary, secondary).synthesize("Bonjour") }
    }

    /// L'annulation de l'appelant n'est jamais un échec : pas de repli, la voix choisie reste en place.
    @Test func aCallerCancelledWhileTheChosenVoiceWorksCausesNoFallback() async throws {
        let primary = ScriptedVoice(.hang), secondary = ScriptedVoice(.speech(spoken(2)))
        let voice = fallback(primary, secondary)
        let task = Task { try await voice.synthesize("Bonjour") }
        await primary.entered.wait()

        task.cancel()

        #expect((await outcome(task)).failureValue is CancellationError)
        #expect(secondary.calls.isEmpty)
        #expect(await eventually { primary.cancelled == 1 })
        // La voix choisie n'a pas été écartée : une phrase suivante lui revient.
        let next = Task { try await voice.synthesize("Suite") }
        #expect(await eventually { primary.calls.count == 2 })
        next.cancel()
        _ = await outcome(next)
        #expect(primary.calls == ["Bonjour", "Suite"] && secondary.calls.isEmpty)
    }

    @Test func aCancellationSurfacingAsAnotherErrorFromTheChosenVoiceIsStillACancellation() async {
        let latch = DeafLatch(), entered = Gate()
        final class Deaf: SpeechSynthesizer, @unchecked Sendable {
            let latch: DeafLatch, entered: Gate
            init(_ latch: DeafLatch, _ entered: Gate) { self.latch = latch; self.entered = entered }
            func synthesize(_ text: String) async throws -> Speech {
                entered.open()
                await latch.wait()
                throw SpeechError.timedOut
            }
        }
        let secondary = ScriptedVoice(.speech(spoken(2)))
        let voice = FallbackSpeechSynthesizer(primary: Deaf(latch, entered), fallback: secondary, sleep: { _ in try await Task.sleep(for: .seconds(1_000_000)) })
        let task = Task { try await voice.synthesize("Bonjour") }
        await entered.wait()
        task.cancel()
        latch.open()
        #expect((await outcome(task)).failureValue is CancellationError)
        #expect(secondary.calls.isEmpty)
    }

    @Test func aCallerCancelledWhileTheFallbackWorksGetsACancellation() async {
        let primary = ScriptedVoice(.fail(.empty)), secondary = ScriptedVoice(.hang)
        let voice = fallback(primary, secondary)
        let task = Task { try await voice.synthesize("Bonjour") }
        await secondary.entered.wait()
        task.cancel()
        #expect((await outcome(task)).failureValue is CancellationError)
    }

    @Test func theDefaultTimeoutIsFourSeconds() async {
        let primary = ScriptedVoice(.hang), secondary = ScriptedVoice(.speech(spoken(2))), sleeper = TickSleeper()
        let voice = FallbackSpeechSynthesizer(primary: primary, fallback: secondary, sleep: { try await sleeper.sleep($0) })
        let task = Task { try await voice.synthesize("Bonjour") }
        await sleeper.waitForSleeps(1)
        #expect(sleeper.requested == [4])
        sleeper.tick()
        _ = await outcome(task)
    }
}
