import FluidAudio
import Foundation
import Synchronization
import SupervoxCore
import Testing
import WhisperKit

@testable import SupervoxEngines

/// `prepare()` des moteurs partagés entre sessions : un seul chargement à la fois, un second appel pendant le premier attend
/// le même résultat, un chargement échoué peut être retenté. Le chargeur est injecté : aucun vrai modèle n'est chargé ni
/// téléchargé, aucun disque lu. (Un `WhisperKit` ne se fabrique pas sans modèle : pour lui, le chargeur échoue ; la réussite
/// est vue sur Parakeet, dont le gestionnaire se fabrique vide, et dans `SingleFlightTests` du cœur.)
@Suite(.timeLimit(.minutes(1))) struct EnginePrepareTests {
    struct Failure: Error, Equatable {}

    /// Porte à ouvrir une fois ; `wait()` rend la main à l'ouverture, ou si la tâche qui attend est annulée (la limite de
    /// temps du test annule le test : il échoue au lieu de pendre).
    final class Gate: Sendable {
        private let state = Mutex<(isOpen: Bool, waiters: [UUID: CheckedContinuation<Void, Never>])>((false, [:]))

        func wait() async {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let now = state.withLock { state -> Bool in
                        if state.isOpen || Task.isCancelled { return true }
                        state.waiters[id] = continuation
                        return false
                    }
                    if now { continuation.resume() }
                }
            } onCancel: {
                state.withLock { $0.waiters.removeValue(forKey: id) }?.resume()
            }
        }

        func open() {
            let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
                state.isOpen = true
                defer { state.waiters = [:] }
                return Array(state.waiters.values)
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    final class Calls: Sendable {
        private let count = Mutex(0)
        func record() { count.withLock { $0 += 1 } }
        var value: Int { count.withLock { $0 } }
    }

    private func settle() async {
        for _ in 0..<200 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }

    // MARK: - Parakeet

    @Test func twoParakeetPreparesAtTheSameTimeLoadOnce() async throws {
        let calls = Calls()
        let entered = Gate()
        let release = Gate()
        let transcriber = ParakeetTranscriber(loader: {
            calls.record()
            entered.open()
            await release.wait()
            return AsrManager(config: .default)
        })

        let first = Task { try await transcriber.prepare() }
        await entered.wait()
        let second = Task { try await transcriber.prepare() }
        await settle()
        #expect(calls.value == 1)

        release.open()
        try await first.value
        try await second.value
        #expect(calls.value == 1)

        // Chargé : plus aucun appel du chargeur.
        try await transcriber.prepare()
        #expect(calls.value == 1)
    }

    @Test func aFailedParakeetLoadReachesBothCallersAndCanBeRetried() async throws {
        let calls = Calls()
        let entered = Gate()
        let release = Gate()
        let transcriber = ParakeetTranscriber(loader: {
            calls.record()
            if calls.value == 1 {
                entered.open()
                await release.wait()
                throw Failure()
            }
            return AsrManager(config: .default)
        })

        let first = Task { try await transcriber.prepare() }
        await entered.wait()
        let second = Task { try await transcriber.prepare() }
        await settle()
        release.open()
        for task in [first, second] {
            await #expect(throws: Failure.self) { try await task.value }
        }
        #expect(calls.value == 1)

        try await transcriber.prepare()
        #expect(calls.value == 2)
    }

    /// I4 : un moteur dit s'il est déjà chargé en mémoire (la dictée en tient compte pour sa mention « Chargement du modèle… »).
    @Test func parakeetSaysWhetherItIsLoaded() async throws {
        let transcriber = ParakeetTranscriber(loader: { AsrManager(config: .default) })
        #expect(await transcriber.isPrepared == false)
        try await transcriber.prepare()
        #expect(await transcriber.isPrepared == true)
    }

    @Test func aParakeetWhoseLoadFailedIsNotLoaded() async {
        let transcriber = ParakeetTranscriber(loader: { throw Failure() })
        _ = try? await transcriber.prepare()
        #expect(await transcriber.isPrepared == false)
    }

    @Test func aWhisperKitWhoseLoadFailedIsNotLoaded() async {
        let transcriber = WhisperKitTranscriber(model: "base", downloadBase: nil, loader: { _, _ in throw Failure() })
        #expect(await transcriber.isPrepared == false)
        _ = try? await transcriber.prepare()
        #expect(await transcriber.isPrepared == false)
    }

    @Test func aFreshVoiceDetectorIsNotLoaded() async {
        #expect(await FluidStreamingVoiceDetector().isPrepared == false)
    }

    // MARK: - WhisperKit

    @Test func twoWhisperKitPreparesAtTheSameTimeLoadOnceAndShareTheFailure() async throws {
        let calls = Calls()
        let entered = Gate()
        let release = Gate()
        let transcriber = WhisperKitTranscriber(
            model: "base", downloadBase: nil,
            loader: { _, _ in
                calls.record()
                entered.open()
                await release.wait()
                throw Failure()
            })

        let first = Task { try await transcriber.prepare() }
        await entered.wait()
        let second = Task { try await transcriber.prepare() }
        await settle()
        #expect(calls.value == 1)

        release.open()
        for task in [first, second] {
            await #expect(throws: Failure.self) { try await task.value }
        }
        #expect(calls.value == 1)
    }

    @Test func aFailedWhisperKitLoadCanBeRetried() async {
        let calls = Calls()
        let transcriber = WhisperKitTranscriber(
            model: "base", downloadBase: nil,
            loader: { _, _ in
                calls.record()
                throw Failure()
            })
        await #expect(throws: Failure.self) { try await transcriber.prepare() }
        await #expect(throws: Failure.self) { try await transcriber.prepare() }
        #expect(calls.value == 2)
    }

    @Test func theWhisperKitLoaderReceivesTheModelAndTheDownloadBase() async {
        let seen = Mutex<[String]>([])
        let base = URL(fileURLWithPath: "/tmp/supervox-test-base")
        let transcriber = WhisperKitTranscriber(
            model: "small", downloadBase: base,
            loader: { model, downloadBase in
                seen.withLock { $0.append("\(model)|\(downloadBase?.path ?? "nil")") }
                throw Failure()
            })
        _ = try? await transcriber.prepare()
        #expect(seen.withLock { $0 } == ["small|/tmp/supervox-test-base"])
    }
}
