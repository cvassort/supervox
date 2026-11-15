import AVFAudio
import Foundation
import os
import Testing
@testable import SupervoxCore

/// Reçoit les tranches d'un `onChunk` `@Sendable`, depuis le fil audio.
private final class ReceivedChunks: @unchecked Sendable {
    private let store = OSAllocatedUnfairLock(initialState: [AudioChunk]())
    var chunks: [AudioChunk] { store.withLock { $0 } }
    func append(_ chunk: AudioChunk) { store.withLock { $0.append(chunk) } }
    var seconds: Double { chunks.reduce(0) { $0 + Double($1.samples.count) / $1.sampleRate } }
}

/// Un seul micro à la fois : ces tests partagent le périphérique d'entrée et le voice processing. Lancés en
/// parallèle, ils ont pendu au premier essai (cause non établie) ; en série, ils passent.
@Suite("Micro réel", .serialized)
struct RealMicrophoneTests {
    /// Test d'intégration avec un vrai micro : à lancer à la main avec `SUPERVOX_MIC=1`.
    /// Il enregistre environ une seconde de bruit ambiant, uniquement en mémoire : rien n'est écrit sur disque
    /// et aucune valeur d'échantillon n'est affichée.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_MIC"] == "1"))
    func captureRecordsAboutOneSecondTwiceFromTheSameInstance() async throws {
        let capture = AudioCapture()
        // Deux cycles sur la même instance : c'est ce que fait `record`, une capture par phrase.
        for cycle in 1...2 {
            try capture.start()
            let t0 = DispatchTime.now().uptimeNanoseconds
            let hostAtReturn = mach_absolute_time()
            try await Task.sleep(for: .seconds(1))
            let t1 = DispatchTime.now().uptimeNanoseconds
            let clip = capture.stop()
            let elapsed = Double(t1 - t0) / 1e9
            let missingTail = elapsed - clip.duration

            #expect(clip.sampleRate > 0, "cycle \(cycle)")
            #expect(clip.duration >= 0.5 && clip.duration <= 2, "cycle \(cycle) : durée \(clip.duration) s")
            #expect(!capture.inputDescription.isEmpty)
            // Contrat de `stop()` : au plus une fenêtre de tap (100 ms) manque entre le temps écoulé et le clip.
            // Tolérance 0,15 s = fenêtre de 100 ms + 50 ms de marge d'ordonnancement ; mesuré : écarts de 0,01 à 0,07 s
            // sur 14 prises. Avec des fenêtres de 400 ms, ce test échouerait.
            #expect(missingTail <= 0.15, "cycle \(cycle) : il manque \(missingTail) s en fin de prise")
            // Un accès refusé donne du silence parfait : on le signale sans jamais exposer le contenu.
            let silent = clip.samples.allSatisfy { $0 == 0 }
            // > 0 : le 1er échantillon du clip a été capté APRÈS le retour de start() (début de prise perdu) ; < 0 : avant.
            let firstOffset = capture.firstSampleHostTime.map {
                AVAudioTime.seconds(forHostTime: $0) - AVAudioTime.seconds(forHostTime: hostAtReturn)
            }
            let latency = capture.startLatency.map { String($0) } ?? "nil"
            let facts = "\(clip.samples.count) échantillons à \(clip.sampleRate) Hz, durée \(clip.duration) s, écoulé \(elapsed) s"
            let facts2 = "écart \(missingTail) s, délai 1er buffer \(latency) s, silence parfait : \(silent), 1er échantillon capté à \(firstOffset.map { String($0) } ?? "nil") s du retour de start()"
            Issue.record("cycle \(cycle) : \(facts), \(facts2), entrée : \(capture.inputDescription)", severity: .warning)
        }
    }

    /// Même précaution que ci-dessus : une seconde de bruit ambiant, en mémoire seulement, aucune valeur affichée.
    /// Avec `SUPERVOX_MIC=1`, l'autorisation du micro doit déjà être accordée à l'hôte du test.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_MIC"] == "1"))
    func captureDeliversChunksTotallingAboutOneSecondAndNoneAfterStop() async throws {
        let capture = AudioCapture()
        let received = ReceivedChunks()
        try capture.start { received.append($0) }
        try await Task.sleep(for: .seconds(1))
        let clip = capture.stop()
        let delivered = received.chunks.count

        Issue.record("\(delivered) tranches, durée totale \(received.seconds) s, fréquence \(received.chunks.first?.sampleRate ?? 0) Hz, clip de \(clip.duration) s", severity: .warning)
        #expect(delivered > 1, "tranches reçues : \(delivered)")
        #expect(received.seconds >= 0.6 && received.seconds <= 1.4, "durée totale des tranches : \(received.seconds) s")
        #expect(received.chunks.allSatisfy { $0.sampleRate > 0 && !$0.samples.isEmpty })
        // Le clip rendu par `stop()` contient toutes les tranches livrées ; il peut en contenir une de plus : une fenêtre
        // ajoutée au tampon juste avant que `stop()` ferme la livraison n'est pas livrée (constaté : 0,7 s contre 0,6 s).
        #expect(clip.samples.count >= received.chunks.reduce(0) { $0 + $1.samples.count })
        // Contrat de `stop()` : rien n'arrive après son retour.
        try await Task.sleep(for: .milliseconds(400))
        #expect(received.chunks.count == delivered, "tranches arrivées après stop() : \(received.chunks.count - delivered)")
    }

    /// Le micro vu comme `MicrophoneFeed` : même contrôle, par l'adaptateur de la dictée.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_MIC"] == "1"))
    func liveMicrophoneFeedDeliversChunksTotallingAboutOneSecondAndNoneAfterStop() async throws {
        let feed = LiveMicrophoneFeed()
        let received = ReceivedChunks()
        try feed.start { received.append($0) }
        try await Task.sleep(for: .seconds(1))
        feed.stop()
        let delivered = received.chunks.count
        // La dictée n'a pas besoin du clip : le tampon interne ne doit rien avoir gardé.
        #expect(feed.capture.stop().samples.isEmpty)

        #expect(received.seconds >= 0.6 && received.seconds <= 1.4, "durée totale des tranches : \(received.seconds) s")
        try await Task.sleep(for: .milliseconds(400))
        #expect(received.chunks.count == delivered, "tranches arrivées après stop() : \(received.chunks.count - delivered)")
    }
}

// MARK: - Traitement du tap, sans micro (tampons synthétiques)

/// 4 800 images à 48 kHz : une rampe qui commence à `first`, pour reconnaître chaque tranche.
private func syntheticWindow(first: Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
    buffer.frameLength = 4800
    for i in 0..<4800 {
        buffer.floatChannelData![0][i] = first + Float(i)
        buffer.floatChannelData![1][i] = -1   // le 2e canal ne doit jamais apparaître
    }
    return buffer
}

private let anyTime = AVAudioTime(hostTime: 0)

/// La garantie du contrat de `stop()` : aucun `onChunk` après son retour. Deux fils : A est dans une livraison,
/// B appelle `stop()`. Les attentes à délai ne peuvent produire qu'un faux succès, jamais un faux échec.
@Test func stopWaitsForTheDeliveryInProgressAndNothingIsDeliveredAfterItReturns() {
    let capture = AudioCapture()
    let received = ReceivedChunks()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let stopReturned = DispatchSemaphore(value: 0)
    let tapDone = DispatchSemaphore(value: 0)
    nonisolated(unsafe) let tap = capture.makeTap(sampleRate: 48000, accumulate: false) { chunk in
        received.append(chunk)
        if received.chunks.count == 1 {
            entered.signal()
            release.wait()
        }
    }
    nonisolated(unsafe) let window = syntheticWindow(first: 0)

    DispatchQueue.global().async {   // fil A : le tap, bloqué dans `onChunk`
        tap(window, anyTime)
        tapDone.signal()
    }
    #expect(entered.wait(timeout: .now() + 10) == .success)
    DispatchQueue.global().async {   // fil B
        _ = capture.stop()
        stopReturned.signal()
    }
    #expect(stopReturned.wait(timeout: .now() + 0.2) == .timedOut, "stop() est revenu pendant une livraison")
    release.signal()
    #expect(stopReturned.wait(timeout: .now() + 10) == .success)
    #expect(tapDone.wait(timeout: .now() + 10) == .success)

    tap(window, anyTime)   // un bloc du tap en retard, après le retour de stop()
    #expect(received.chunks.count == 1)
}

/// Un bloc de la prise précédente, encore en vol après un nouveau `start`, ne doit pas appeler l'ancien `onChunk`.
@Test func aLateTapBlockOfAnEarlierTakeNeverReachesTheNewTakeHandler() {
    let capture = AudioCapture()
    let first = ReceivedChunks()
    let second = ReceivedChunks()
    nonisolated(unsafe) let oldTap = capture.makeTap(sampleRate: 48000, accumulate: false) { first.append($0) }
    _ = capture.stop()
    nonisolated(unsafe) let newTap = capture.makeTap(sampleRate: 48000, accumulate: false) { second.append($0) }
    let window = syntheticWindow(first: 0)

    oldTap(window, anyTime)
    newTap(window, anyTime)

    #expect(first.chunks.isEmpty)
    #expect(second.chunks.count == 1)
}

@Test func tapDeliversTheFirstChannelOnlyAtTheNativeRate() {
    let capture = AudioCapture()
    let received = ReceivedChunks()
    let tap = capture.makeTap(sampleRate: 48000, accumulate: true) { received.append($0) }

    tap(syntheticWindow(first: 10), anyTime)

    let chunk = received.chunks.first
    #expect(chunk?.sampleRate == 48000)
    #expect(chunk?.samples.count == 4800)
    #expect(chunk?.samples.first == 10 && chunk?.samples.last == 10 + 4799)
}

@Test func accumulateFalseKeepsNothingInTheInternalBuffer() {
    let capture = AudioCapture()
    let received = ReceivedChunks()
    let tap = capture.makeTap(sampleRate: 48000, accumulate: false) { received.append($0) }

    for index in 0..<5 { tap(syntheticWindow(first: Float(index)), anyTime) }

    #expect(received.chunks.count == 5)
    #expect(capture.stop().samples.isEmpty)
}

@Test func accumulateTrueKeepsEveryWindowInTheInternalBufferForStop() {
    let capture = AudioCapture()
    let received = ReceivedChunks()
    let tap = capture.makeTap(sampleRate: 48000, accumulate: true) { received.append($0) }

    for index in 0..<3 { tap(syntheticWindow(first: Float(index) * 10000), anyTime) }
    let clip = capture.stop()

    #expect(received.chunks.count == 3)
    #expect(clip.samples == received.chunks.flatMap(\.samples))
    #expect(clip.sampleRate == 48000)
}

@Test func tapWithoutHandlerStillRecordsForTheBench() {
    let capture = AudioCapture()
    let tap = capture.makeTap(sampleRate: 48000, accumulate: true, onChunk: nil)

    tap(syntheticWindow(first: 0), anyTime)

    #expect(capture.stop().samples.count == 4800)
}

/// Appeler `stop()` depuis `onChunk` : erreur de programmation, le processus s'arrête (précondition).
@Test func captureStopFromOnChunkIsAProgrammingError() async throws {
    let result = try await #require(processExitsWith: .failure, observing: [\.standardErrorContent]) {
        let capture = AudioCapture()
        let tap = capture.makeTap(sampleRate: 48000, accumulate: false) { _ in _ = capture.stop() }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        let window = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        window.frameLength = 480
        tap(window, AVAudioTime(hostTime: 0))
    }
    #expect(String(decoding: result.standardErrorContent, as: UTF8.self).contains("erreur de programmation"))
}

// MARK: - Décision d'accès au micro (pure : aucune permission réelle n'est touchée)

private let settingsPath = "Réglages Système > Confidentialité et sécurité > Micro"

private func refusalMessage(_ decision: AudioCapture.AccessDecision) -> String? {
    guard case .refused(.microphoneAccessDenied(let message)) = decision else { return nil }
    return message
}

@Test func deniedAccessPointsToSystemSettingsAndNotToATerminal() throws {
    for prompts in [true, false] {
        let message = try #require(refusalMessage(AudioCapture.accessDecision(for: .denied, promptsForAccess: prompts)))
        #expect(message.contains(settingsPath), "\(message)")
        #expect(!message.contains("terminal"), "\(message)")
    }
}

@Test func undeterminedAccessWithoutPromptIsRefusedWithoutAsking() throws {
    let decision = AudioCapture.accessDecision(for: .notDetermined, promptsForAccess: false)
    let message = try #require(refusalMessage(decision))
    #expect(message.contains(settingsPath), "\(message)")
    #expect(AudioCapture.accessDecision(for: .notDetermined, promptsForAccess: true) == .askUser)
}

@Test func authorizedAccessIsGrantedAndRestrictedIsRefused() {
    #expect(AudioCapture.accessDecision(for: .authorized, promptsForAccess: false) == .granted)
    #expect(AudioCapture.accessDecision(for: .authorized, promptsForAccess: true) == .granted)
    for prompts in [true, false] {
        #expect(refusalMessage(AudioCapture.accessDecision(for: .restricted, promptsForAccess: prompts)) != nil)
    }
}

/// La raison d'une panne du moteur audio, montrée dans le panneau : le code du système, jamais le texte de l'erreur.
@Test func theReasonOfAnAudioEngineFailureIsTheSystemCodeAndNothingOfTheErrorsText() {
    let error = NSError(
        domain: "https://exemple.invalid/service", code: -10868,
        userInfo: [NSLocalizedDescriptionKey: "échec avec la clé sk-123 vers https://exemple.invalid/v1"])
    let reason = AudioCapture.reason(for: error)
    #expect(reason.contains("-10868"))
    #expect(!reason.contains("exemple.invalid"))
    #expect(!reason.contains("sk-123"))
    #expect(!reason.contains("clé"))
}

@Test func theReasonOfAnErrorThatIsNotAnNSErrorStillHasNoText() {
    struct Odd: Error, CustomStringConvertible { var description: String { "https://exemple.invalid/secret" } }
    #expect(!AudioCapture.reason(for: Odd()).contains("exemple.invalid"))
}
