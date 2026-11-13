import Synchronization
import Testing

@testable import SupervoxApp

/// Sonde double : les états sont réglés par le test, les demandes sont comptées.
/// `requestMicrophone` fait passer le micro à l'état `answer`, comme le ferait l'utilisateur.
final class FakePermissionsProbe: PermissionsProbe {
    struct State {
        var microphone: PermissionState
        var accessibility: PermissionState
        var answer = true
        var microphoneRequests = 0
        var accessibilityPrompts = 0
    }

    let state: Mutex<State>

    init(microphone: PermissionState, accessibility: PermissionState) {
        state = Mutex(State(microphone: microphone, accessibility: accessibility))
    }

    func microphone() -> PermissionState { state.withLock { $0.microphone } }
    func accessibility() -> PermissionState { state.withLock { $0.accessibility } }

    func requestMicrophone() async -> Bool {
        state.withLock {
            $0.microphoneRequests += 1
            $0.microphone = $0.answer ? .granted : .denied
            return $0.answer
        }
    }

    func promptAccessibility() { state.withLock { $0.accessibilityPrompts += 1 } }

    var microphoneRequests: Int { state.withLock { $0.microphoneRequests } }
    var accessibilityPrompts: Int { state.withLock { $0.accessibilityPrompts } }

    func set(microphone: PermissionState? = nil, accessibility: PermissionState? = nil) {
        state.withLock {
            if let microphone { $0.microphone = microphone }
            if let accessibility { $0.accessibility = accessibility }
        }
    }
}

@MainActor @Suite struct PermissionsModelTests {
    @Test func microphoneIsRequestedBeforeAccessibility() async {
        let probe = FakePermissionsProbe(microphone: .notDetermined, accessibility: .denied)
        let model = PermissionsModel(probe: probe)

        await model.requestNext()
        #expect(probe.microphoneRequests == 1)
        #expect(probe.accessibilityPrompts == 0)
        #expect(model.microphone == .granted)

        // Micro décidé : l'appel suivant passe à l'Accessibilité, sans redemander le micro.
        await model.requestNext()
        #expect(probe.microphoneRequests == 1)
        #expect(probe.accessibilityPrompts == 1)
    }

    @Test(arguments: [PermissionState.granted, .denied])
    func decidedMicrophoneMovesOnToAccessibility(microphone: PermissionState) async {
        let probe = FakePermissionsProbe(microphone: microphone, accessibility: .denied)
        let model = PermissionsModel(probe: probe)

        await model.requestNext()
        #expect(probe.microphoneRequests == 0)
        #expect(probe.accessibilityPrompts == 1)
    }

    @Test func grantedAccessibilityIsNotPromptedAgain() async {
        let probe = FakePermissionsProbe(microphone: .granted, accessibility: .granted)
        let model = PermissionsModel(probe: probe)

        await model.requestNext()
        #expect(probe.microphoneRequests == 0)
        #expect(probe.accessibilityPrompts == 0)
        #expect(!model.canRequest)
    }

    @Test func permissionStateIsRereadOnEachOpen() {
        let probe = FakePermissionsProbe(microphone: .granted, accessibility: .granted)
        let model = PermissionsModel(probe: probe)
        #expect(model.accessibility == .granted)

        // Retirée en cours de route : le modèle suit.
        probe.set(microphone: .denied, accessibility: .denied)
        model.refresh()
        #expect(model.microphone == .denied)
        #expect(model.accessibility == .denied)

        // Rendue : le modèle suit dans l'autre sens.
        probe.set(microphone: .granted, accessibility: .granted)
        model.refresh()
        #expect(model.microphone == .granted)
        #expect(model.accessibility == .granted)
    }

    @Test func summaryNamesWhatIsMissingAndItsConsequence() throws {
        let probe = FakePermissionsProbe(microphone: .granted, accessibility: .denied)
        let model = PermissionsModel(probe: probe)
        let accessibilityOnly = try #require(model.summary)
        #expect(accessibilityOnly.contains("Accessibilité"))
        #expect(accessibilityOnly.contains("copié, pas collé"))
        #expect(!accessibilityOnly.localizedCaseInsensitiveContains("micro"))

        probe.set(microphone: .notDetermined, accessibility: .granted)
        model.refresh()
        let microphoneOnly = try #require(model.summary)
        #expect(microphoneOnly.localizedCaseInsensitiveContains("micro"))
        #expect(microphoneOnly.contains("dictée"))
        #expect(!microphoneOnly.contains("Accessibilité"))

        probe.set(microphone: .denied, accessibility: .denied)
        model.refresh()
        let both = try #require(model.summary)
        #expect(both.localizedCaseInsensitiveContains("micro"))
        #expect(both.contains("dictée"))
        #expect(both.contains("Accessibilité"))
        #expect(both.contains("copié, pas collé"))
        // Micro refusé : la demande ne le rouvrira pas, la phrase dit où le rendre.
        #expect(both.contains("Réglages Système"))
    }

    @Test func summaryIsNilWhenEverythingIsGranted() {
        let probe = FakePermissionsProbe(microphone: .granted, accessibility: .granted)
        let model = PermissionsModel(probe: probe)
        #expect(model.summary == nil)

        // Et redevient non nil dès qu'il manque quelque chose : nil n'est pas une constante.
        probe.set(accessibility: .denied)
        model.refresh()
        #expect(model.summary != nil)
    }

    /// Micro refusé et Accessibilité accordée : `requestNext` n'aurait rien à demander,
    /// le panneau ne doit donc pas offrir de bouton inerte.
    @Test func nothingToRequestWhenMicrophoneIsDeniedAndAccessibilityGranted() async {
        let probe = FakePermissionsProbe(microphone: .denied, accessibility: .granted)
        let model = PermissionsModel(probe: probe)
        #expect(!model.canRequest)
        #expect(model.summary != nil)

        probe.set(microphone: .notDetermined)
        model.refresh()
        #expect(model.canRequest)
    }

    /// Deux clics sur « Autoriser… » : la seconde demande, faite pendant que la première attend la
    /// réponse de l'utilisateur, est ignorée.
    @Test func secondRequestWhileOneIsPendingIsIgnored() async throws {
        let probe = GatedPermissionsProbe()
        let model = PermissionsModel(probe: probe)

        let first = Task { await model.requestNext() }
        // Attend que la première demande soit en cours (pas de borne de durée : un nombre de tours).
        var turns = 0
        while probe.microphoneRequests == 0, turns < 100_000 {
            await Task.yield()
            turns += 1
        }
        try #require(probe.microphoneRequests == 1)
        #expect(!model.canRequest)

        // Lancée à part : si elle n'était pas ignorée, elle attendrait elle aussi la réponse.
        let second = Task { await model.requestNext() }
        for _ in 0..<1_000 { await Task.yield() }
        #expect(probe.microphoneRequests == 1)
        #expect(probe.accessibilityPrompts == 0)

        probe.answer()
        await first.value
        await second.value
        #expect(model.microphone == .granted)
        #expect(model.canRequest)
    }
}

/// Sonde dont la demande de micro attend que le test réponde, comme une invite restée ouverte.
final class GatedPermissionsProbe: PermissionsProbe {
    private struct State {
        var microphone = PermissionState.notDetermined
        var microphoneRequests = 0
        var accessibilityPrompts = 0
        var pending: [CheckedContinuation<Void, Never>] = []
        var answered = false
    }

    private let state = Mutex(State())

    var microphoneRequests: Int { state.withLock { $0.microphoneRequests } }
    var accessibilityPrompts: Int { state.withLock { $0.accessibilityPrompts } }

    func microphone() -> PermissionState { state.withLock { $0.microphone } }
    func accessibility() -> PermissionState { .denied }
    func promptAccessibility() { state.withLock { $0.accessibilityPrompts += 1 } }

    func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            let resumeNow = state.withLock { state -> Bool in
                state.microphoneRequests += 1
                if state.answered { return true }
                state.pending.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return true
    }

    /// L'utilisateur accepte : le micro est accordé et toute demande en attente se termine.
    func answer() {
        let pending = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.answered = true
            state.microphone = .granted
            defer { state.pending = [] }
            return state.pending
        }
        for continuation in pending { continuation.resume() }
    }
}

