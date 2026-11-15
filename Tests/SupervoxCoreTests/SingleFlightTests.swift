import Foundation
import Testing

@testable import SupervoxCore

/// `SingleFlight` : un travail à la fois, partagé par ceux qui arrivent pendant qu'il tourne. Aucune attente réelle : le
/// travail du test attend une porte que le test ouvre.
@Suite(.timeLimit(.minutes(1))) struct SingleFlightTests {
    struct Failure: Error, Equatable { let label: String }

    actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    /// Laisse passer ce qui est déjà en route (pour prouver qu'un second travail ne démarre PAS).
    private func settle() async {
        for _ in 0..<200 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }

    @Test func aCallArrivingDuringTheWorkJoinsItInsteadOfStartingASecond() async throws {
        let flight = SingleFlight()
        let started = Counter()
        let entered = Gate()
        let release = Gate()
        let work: @Sendable () async throws -> Void = {
            await started.increment()
            entered.open()
            await release.wait()
        }

        let first = Task { try await flight.run(work) }
        await entered.wait()
        let second = Task { try await flight.run(work) }
        await settle()
        // Le premier travail tourne encore, et personne n'en a lancé un autre.
        #expect(await started.value == 1)
        #expect(flight.isRunning)

        release.open()
        try await first.value
        try await second.value
        #expect(await started.value == 1)
        #expect(!flight.isRunning)
    }

    @Test func aFailureReachesEveryoneWhoWaitedForIt() async {
        let flight = SingleFlight()
        let entered = Gate()
        let release = Gate()
        let work: @Sendable () async throws -> Void = {
            entered.open()
            await release.wait()
            throw Failure(label: "chargement")
        }

        let first = Task { try await flight.run(work) }
        await entered.wait()
        let second = Task { try await flight.run(work) }
        await settle()
        release.open()

        for task in [first, second] {
            do {
                try await task.value
                Issue.record("le travail aurait dû échouer")
            } catch {
                #expect(error as? Failure == Failure(label: "chargement"))
            }
        }
    }

    @Test func aFailedWorkCanBeTriedAgain() async throws {
        let flight = SingleFlight()
        let attempts = Counter()
        let flaky: @Sendable () async throws -> Void = {
            await attempts.increment()
            if await attempts.value == 1 { throw Failure(label: "premier essai") }
        }

        await #expect(throws: Failure.self) { try await flight.run(flaky) }
        #expect(!flight.isRunning)
        try await flight.run(flaky)
        #expect(await attempts.value == 2)
    }

    /// L'annulation d'un appelant n'annule pas le travail : un autre appelant l'attend encore.
    @Test func cancellingTheCallerThatStartedTheWorkDoesNotCancelIt() async throws {
        let flight = SingleFlight()
        let entered = Gate()
        let release = Gate()
        let finished = Counter()
        let work: @Sendable () async throws -> Void = {
            entered.open()
            await release.wait()
            #expect(!Task.isCancelled)
            await finished.increment()
        }

        let first = Task { try await flight.run(work) }
        await entered.wait()
        let second = Task { try await flight.run(work) }
        await settle()
        first.cancel()
        await settle()
        #expect(await finished.value == 0)

        release.open()
        try await second.value
        #expect(await finished.value == 1)
    }

    @Test func aFinishedWorkLeavesTheRoomToTheNextOne() async throws {
        let flight = SingleFlight()
        let runs = Counter()
        let work: @Sendable () async throws -> Void = { await runs.increment() }
        try await flight.run(work)
        try await flight.run(work)
        #expect(await runs.value == 2)
    }
}
