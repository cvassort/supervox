import Foundation
import Synchronization
import SupervoxCore

@testable import Supervox

// Moteurs doubles de la cible `Supervox` : aucun vrai modèle, aucun disque, aucun réseau.

/// Un moteur de transcription double : compte ses préparations, se dit chargé après la première, répond `text`.
final class DoubleTranscriber: LoadableTranscriber, @unchecked Sendable {
    private struct State {
        var prepares = 0
        var prepared = false
        var calls = 0
        var completions = 0
        var offlineAtPrepare: [Bool] = []
        var error: (any Error)?
        var gate: Gate?
    }

    let name: String
    private let text: String
    private let state = Mutex(State())
    private let offlineProbe: @Sendable () -> Bool

    init(name: String = "double", text: String = "texte", offlineProbe: @escaping @Sendable () -> Bool = { false }) {
        self.name = name
        self.text = text
        self.offlineProbe = offlineProbe
    }

    /// L'état du réseau de FluidAudio (double) vu à chaque `prepare()`.
    var offlineAtPrepare: [Bool] { state.withLock { $0.offlineAtPrepare } }

    var prepares: Int { state.withLock { $0.prepares } }
    var transcriptions: Int { state.withLock { $0.calls } }
    /// Transcriptions rendues à l'appelant (après l'éventuelle porte).
    var completions: Int { state.withLock { $0.completions } }
    var isPrepared: Bool { state.withLock { $0.prepared } }
    func failPrepare(with error: (any Error)?) { state.withLock { $0.error = error } }
    /// Retient `transcribe` tant que la porte n'est pas ouverte (un moteur qui répond plus tard).
    func hold(with gate: Gate) { state.withLock { $0.gate = gate } }
    func markPrepared() { state.withLock { $0.prepared = true } }

    func prepare() async throws {
        let offline = offlineProbe()
        let error = state.withLock { state -> (any Error)? in
            state.prepares += 1
            state.offlineAtPrepare.append(offline)
            if state.error == nil { state.prepared = true }
            return state.error
        }
        if let error { throw error }
    }

    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        let gate = state.withLock { state -> Gate? in
            state.calls += 1
            return state.gate
        }
        await gate?.wait()
        state.withLock { $0.completions += 1 }
        return text
    }
}

/// Un détecteur de voix double : le premier bloc ouvre un passage de parole, les blocs suivants ne disent rien.
final class DoubleDetector: LoadableDetector, @unchecked Sendable {
    private struct State {
        var prepares = 0
        var prepared = false
        var blocks = 0
        var error: (any Error)?
        var prepareGate: Gate?
        var offlineAtPrepare: [Bool] = []
    }

    let blockSize = 1000
    private let state = Mutex(State())
    private let offlineProbe: @Sendable () -> Bool

    init(offlineProbe: @escaping @Sendable () -> Bool = { false }) { self.offlineProbe = offlineProbe }

    var offlineAtPrepare: [Bool] { state.withLock { $0.offlineAtPrepare } }

    var prepares: Int { state.withLock { $0.prepares } }
    var isPrepared: Bool { state.withLock { $0.prepared } }
    var blocks: Int { state.withLock { $0.blocks } }
    func failPrepare(with error: (any Error)?) { state.withLock { $0.error = error } }
    /// `prepare()` attend l'ouverture de cette porte avant de rendre la main.
    func holdPrepare(with gate: Gate) { state.withLock { $0.prepareGate = gate } }

    func prepare() async throws {
        let offline = offlineProbe()
        let (error, gate) = state.withLock { state -> ((any Error)?, Gate?) in
            state.prepares += 1
            state.offlineAtPrepare.append(offline)
            return (state.error, state.prepareGate)
        }
        await gate?.wait()
        if let error { throw error }
        state.withLock { $0.prepared = true }
    }

    func reset() async {}

    func process(_ block: [Float]) async throws -> VoiceEvent? {
        let index = state.withLock { state -> Int in
            state.blocks += 1
            return state.blocks - 1
        }
        return index == 0 ? .speechStart(sample: 0) : nil
    }
}

/// Le réseau de FluidAudio double : un drapeau (coupé ou non) que les moteurs doubles lisent à chaque préparation, et l'historique
/// de ses changements.
final class DoubleNetwork: Sendable {
    private let state = Mutex<(offline: Bool, changes: [Bool])>((false, []))
    var isOffline: Bool { state.withLock { $0.offline } }
    /// Chaque changement, dans l'ordre (`true` : coupé, `false` : rétabli).
    var changes: [Bool] { state.withLock { $0.changes } }
    func set(_ offline: Bool) {
        state.withLock {
            $0.offline = offline
            $0.changes.append(offline)
        }
    }
}

/// Les moteurs doubles que `EngineFactory` fabrique, gardés pour que le test les lise.
final class DoubleEngines: Sendable {
    let network: DoubleNetwork
    let parakeet: DoubleTranscriber
    let detector: DoubleDetector
    private let whispers = Mutex<[String: DoubleTranscriber]>([:])
    private let loadsOffline = Mutex<Bool>(true)

    init() {
        let network = DoubleNetwork()
        self.network = network
        parakeet = DoubleTranscriber(
            name: "parakeet", text: "texte parakeet", offlineProbe: { network.isOffline })
        detector = DoubleDetector(offlineProbe: { network.isOffline })
    }

    /// Le moteur Whisper de ce modèle (le même à chaque appel).
    func whisper(_ model: String) -> DoubleTranscriber {
        let network = network
        return whispers.withLock { whispers in
            if let existing = whispers[model] { return existing }
            let made = DoubleTranscriber(name: "whisperkit", text: "texte whisper", offlineProbe: { network.isOffline })
            whispers[model] = made
            return made
        }
    }

    /// Ce que répond la fabrique à « ce modèle se charge-t-il sans réseau ? ».
    func setWhisperLoadsOffline(_ value: Bool) { loadsOffline.withLock { $0 = value } }

    var factory: EngineFactory {
        EngineFactory(
            parakeet: { [self] in parakeet },
            detector: { [self] in detector },
            whisper: { [self] model, _ in whisper(model) },
            whisperLoadsOffline: { [self] _, _ in loadsOffline.withLock { $0 } },
            setOffline: { [network] in network.set($0) })
    }
}

/// Porte à ouvrir une fois ; `wait()` rend la main à l'ouverture ou si la tâche qui attend est annulée.
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
