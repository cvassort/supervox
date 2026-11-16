import Foundation
import os
import Testing
@testable import SupervoxCore

// La limite de temps est injectée (`TickSleeper`) : le test fait rendre l'attente quand il veut, aucune durée réelle.
// Chaque opération signale son démarrage et son annulation par une porte : aucun test ne sonde ni ne dort.

@Suite(.timeLimit(.minutes(1)))
struct DeadlineTests {
    /// Une opération qui se suspend jusqu'à son annulation et le dit.
    private final class Probe: @unchecked Sendable {
        let started = Gate()
        let cancellationSeen = Gate()
        private let hold = Gate()   // jamais ouverte : l'opération ne rend la main que par annulation

        func run() async -> Int {
            started.open()
            await hold.wait()
            if Task.isCancelled { cancellationSeen.open() }
            return 1
        }
    }

    @Test func anOperationThatFinishesFirstReturnsItsValueAndTheTimerIsCancelled() async throws {
        let sleeper = TickSleeper()
        let value = try await Deadline.run(seconds: 120, sleep: { try await sleeper.sleep($0) }) { 42 }

        #expect(value == 42)
        #expect(await eventually { sleeper.cancelled == 1 })
        #expect(sleeper.requested == [120])
        // Le délai qui rendrait ensuite n'y change rien (l'attente est déjà annulée) : rien à constater de plus.
        sleeper.tick()
    }

    @Test func anOperationThatThrowsPropagatesItsErrorAndTheTimerIsCancelled() async {
        let sleeper = TickSleeper()
        do {
            _ = try await Deadline.run(seconds: 5, sleep: { try await sleeper.sleep($0) }) { () async throws -> Int in
                throw TestFailure("panne")
            }
            Issue.record("aucune erreur levée")
        } catch {
            #expect(error as? TestFailure == TestFailure("panne"))
        }
        #expect(await eventually { sleeper.cancelled == 1 })
    }

    @Test func aTimerThatReturnsFirstThrowsDeadlineExceededAndCancelsTheOperation() async {
        let sleeper = TickSleeper()
        let probe = Probe()
        let task = Task { try await Deadline.run(seconds: 120, sleep: { try await sleeper.sleep($0) }) { await probe.run() } }
        await probe.started.wait()
        await sleeper.waitForSleeps(1)

        sleeper.tick()

        let result = await task.result
        #expect(result.failureValue as? DeadlineExceeded == DeadlineExceeded())
        await probe.cancellationSeen.wait()
    }

    /// Un moteur sourd à l'annulation ne retient pas le délai : `run` n'attend pas la fin de l'opération qu'il abandonne
    /// (une implémentation par groupe de tâches, qui attend ses enfants, ne rendrait jamais la main).
    @Test func anOperationThatIgnoresCancellationDoesNotHoldTheDeadlineBack() async {
        let sleeper = TickSleeper()
        let deaf = DeafLatch()
        let started = Gate()
        let task = Task {
            try await Deadline.run(seconds: 120, sleep: { try await sleeper.sleep($0) }) { () async -> Int in
                started.open()
                await deaf.wait()
                return 7
            }
        }
        await started.wait()
        await sleeper.waitForSleeps(1)

        sleeper.tick()

        let result = await task.result
        #expect(result.failureValue as? DeadlineExceeded == DeadlineExceeded())
        deaf.open()   // le résultat tardif de l'opération abandonnée ne change plus rien
    }

    @Test func aCancelledCallerCancelsBothTheOperationAndTheTimerAndThrowsCancellationError() async {
        let sleeper = TickSleeper()
        let probe = Probe()
        let task = Task { try await Deadline.run(seconds: 120, sleep: { try await sleeper.sleep($0) }) { await probe.run() } }
        await probe.started.wait()
        await sleeper.waitForSleeps(1)

        task.cancel()

        let result = await task.result
        #expect(result.failureValue is CancellationError)
        await probe.cancellationSeen.wait()
        #expect(await eventually { sleeper.cancelled == 1 })
    }

    /// Une opération qui se termine « normalement » parce qu'on l'a annulée ne l'emporte pas sur l'annulation.
    @Test func aCancelledCallerNeverGetsTheValueOfAnOperationThatEndedBecauseOfTheCancellation() async {
        let sleeper = TickSleeper()
        let probe = Probe()   // rend 1 après son annulation, sans lever
        let task = Task { try await Deadline.run(seconds: 120, sleep: { try await sleeper.sleep($0) }) { await probe.run() } }
        await probe.started.wait()

        task.cancel()

        let result = await task.result
        #expect(result.failureValue is CancellationError, "\(result)")
    }

    /// Un appelant déjà annulé ne lance rien : ni l'opération, ni la minuterie. Sans la garde d'entrée, les deux tâches partent
    /// avant que le gestionnaire d'annulation ne les arrête.
    @Test func aCallerAlreadyCancelledOnEntryThrowsCancellationErrorAndStartsNothing() async {
        let sleeper = TickSleeper()
        let operationRan = OSAllocatedUnfairLock(initialState: false)
        let go = Gate()
        let task = Task { () async throws -> Int in
            await go.wait()   // rend la main tout de suite : la tâche est annulée
            return try await Deadline.run(seconds: 120, sleep: { try await sleeper.sleep($0) }) { operationRan.withLock { $0 = true }; return 1 }
        }
        task.cancel()
        go.open()

        #expect((await task.result).failureValue is CancellationError)
        for _ in 0..<1000 { await Task.yield() }   // une absence : un nombre borné de passages, sans durée
        #expect(sleeper.started == 0)
        #expect(!operationRan.withLock { $0 })
    }

    /// Une attente qui lève sans rendre (annulée) n'est pas un délai écoulé : seule une attente qui rend normalement l'est.
    @Test func aSleepThatThrowsIsNotATimeout() async throws {
        let slept = Gate()
        let hold = Gate()
        let task = Task {
            try await Deadline.run(seconds: 1, sleep: { _ in slept.open(); throw TestFailure("attente annulée") }) { () async -> Int in
                await hold.wait()
                return 9
            }
        }
        await slept.wait()
        // Laisse la minuterie, sur son fil, tirer ses conclusions de l'attente qui a levé (une absence à prouver : un nombre
        // borné de passages, sans durée). Un retard ne peut que faire passer à tort une implémentation fautive, jamais faire
        // tomber la bonne.
        for _ in 0..<5000 { await Task.yield() }
        hold.open()

        #expect(try await task.value == 9)
    }
}

extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
