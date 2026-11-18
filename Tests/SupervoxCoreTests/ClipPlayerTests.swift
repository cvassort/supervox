import Foundation
import os
import Testing
@testable import SupervoxCore

// Le lecteur de sortie seule et l'encodeur qu'il utilise. Aucun test de la suite par défaut ne joue un son : l'encodeur se prouve
// en mémoire, le contrat de lecture par le double public `ScriptedClipPlayer`, et les deux fonctions pures de `SystemClipPlayer` sans
// le construire. Les seuls essais de `SystemClipPlayer` sont les essais matériels en fin de fichier, désactivés par défaut.

// MARK: - Règle 3 : encodeur WAV en mémoire

@Suite(.timeLimit(.minutes(1))) struct WavEncoderTests {
    /// Borne de l'aller-retour pour un échantillon `s` de [-1, 1] (code lu : `WavFile.pcm16` écrit `q = round(s × 32 767)`, arrondi
    /// au plus proche, `decode` rend `d = q / 32 768`).
    ///
    /// Dérivation. Posons `q = 32 767·s + e`, où `e` est l'écart d'arrondi. Alors
    /// `d − s = (32 767·s + e) / 32 768 − s = (e − s) / 32 768`, d'où `|d − s| ≤ (|e| + |s|) / 32 768`.
    /// - Arrondi exact : `|e| ≤ 1/2`.
    /// - Le produit `s × 32 767` est calculé en `Float` (24 bits de mantisse) : pour un produit dans [2^14, 2^15), un ulp vaut 2^-9 et
    ///   l'erreur d'arrondi du produit au plus 2^-10 ; plus petite en dessous. D'où `|e| ≤ 1/2 + 2^-10`.
    /// - La division par 32 768 (une puissance de deux) d'un entier de 16 bits est exacte en `Float`.
    /// Donc `|d − s| ≤ (|s| + 1/2 + 2^-10) / 32 768`, au plus `(1,5 + 2^-10) / 32 768` ≈ 4,58e-5 pour `|s| = 1`.
    ///
    /// Pourquoi pas « 1/32 768 » (le chiffre du brief) : le facteur d'écriture (32 767) et celui de lecture (32 768) diffèrent, et
    /// l'écart grandit avec `|s|`. Exemple calculé : `s = 32 766,49 / 32 767` s'écrit 32 766, se relit 32 766 / 32 768, écart ≈ 4,55e-5
    /// (> 1/32 768 ≈ 3,05e-5, ≤ la borne ≈ 4,58e-5). Ce n'est pas un comportement voulu : un codec rendu symétrique resterait sous la
    /// borne, et ce test aussi.
    static func bound(_ s: Float) -> Double { (Double(abs(s)) + 0.5 + 1.0 / 1024) / 32768 }

    /// Un balayage dense de [-1, 1] (pas de 1/4096, choix non mesuré), les extrêmes, et des points tombant à mi-chemin entre deux
    /// paliers de 16 bits : près de la pleine échelle (32 766, 32 700 : le pire cas de la dérivation), au milieu (16 000) et près de
    /// zéro (1, 0). Ces paliers sont des choix non mesurés.
    static let sweep: [Float] = {
        var values = stride(from: -1.0, through: 1.0, by: 1.0 / 4096).map { Float($0) }
        for k in [32766, 32700, 16000, 1, 0] {
            let half = (Double(k) + 0.5) / 32767
            values += [Float(half), Float(-half), Float(half).nextDown, Float(-half).nextUp]
        }
        return values + [1, -1, 0]
    }()

    @Test func theEncoderRoundTrips() throws {
        let clip = AudioClip(samples: Self.sweep, sampleRate: 22050)
        let decoded = try WavFile.decode(WavFile.data(from: clip))
        #expect(decoded.sampleRate == 22050)
        try #require(decoded.samples.count == clip.samples.count)
        let excess = zip(clip.samples, decoded.samples).filter { s, d in abs(Double(d) - Double(s)) > Self.bound(s) }
        #expect(excess.isEmpty, "\(excess.prefix(5))")

        // Un clip vide : un fichier valide de 44 octets, l'en-tête seul, qui se relit vide à la même fréquence.
        let empty = WavFile.data(from: AudioClip(samples: [], sampleRate: 16000))
        #expect(empty.count == 44)
        let reread = try WavFile.decode(empty)
        #expect(reread.samples.isEmpty && reread.sampleRate == 16000)
        // 2 octets par échantillon après l'en-tête.
        #expect(WavFile.data(from: clip).count == 44 + 2 * clip.samples.count)
    }

    /// `write(_:to:)` écrit exactement les octets de `data(from:)` : un seul encodeur.
    @Test func writeStoresExactlyTheEncodedBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("supervox-wav-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("clip.wav")
        let clip = AudioClip(samples: [0, 0.25, -0.5, 1, -1, 2, .nan], sampleRate: 24000)
        try WavFile.write(clip, to: url)
        #expect(try Data(contentsOf: url) == WavFile.data(from: clip))
    }
}


// MARK: - Règle 4 : le double public `ScriptedClipPlayer`

private let first = AudioClip(samples: [0.1, 0.2, 0.3], sampleRate: 16000)
private let second = AudioClip(samples: [-0.4, 0.5], sampleRate: 22050)
private let silent = AudioClip(samples: [], sampleRate: 16000)

/// Attend une opération sans jamais se suspendre : au-delà de 30 s, `DeadlineExceeded` fait échouer le test, et l'opération abandonnée
/// n'est pas attendue (`Deadline.run`). 30 s est une borne anti-suspension (choix non mesuré), pas une borne de vitesse : un double
/// en mémoire rend la main bien avant.
private func bounded<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await Deadline.run(seconds: 30, sleep: { try await Task.sleep(for: .seconds($0)) }, operation)
}

/// Une lecture lancée dans sa propre tâche ; `bounded` attend sa fin.
private func playing(_ player: ScriptedClipPlayer, _ clip: AudioClip) -> Task<Void, any Error> {
    Task { try await player.play(clip) }
}

/// Une lecture lancée par une tâche déjà annulée avant l'appel de `play` (elle s'annule elle-même : aucun ordre à espérer).
private func playingFromACancelledTask(_ player: ScriptedClipPlayer, _ clip: AudioClip) -> Task<Void, any Error> {
    Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await player.play(clip)
    }
}

@Suite(.timeLimit(.minutes(1))) struct ScriptedClipPlayerTests {
    @Test func playReturnsOnlyAtTheEnd() async throws {
        let player = ScriptedClipPlayer()
        let finishCalled = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            try await player.play(first)
            return finishCalled.withLock { $0 }   // `finish()` avait-il été appelé quand `play` a rendu la main ?
        }
        defer { task.cancel(); player.finish() }
        try await bounded { await player.waitForPlays(1) }
        // Sans ordre de fin, la lecture est toujours en cours (déterministe : `play` a enregistré le clip et sa lecture d'un seul
        // tenant, avant de libérer `waitForPlays`).
        #expect(player.isPlaying)
        #expect(player.clips == [first])
        finishCalled.withLock { $0 = true }
        player.finish()
        let sawFinish = try await bounded { try await task.value }
        #expect(sawFinish)
        #expect(!player.isPlaying)
        #expect(player.stopCount == 0)
    }

    @Test func stopEndsPlay() async throws {
        let player = ScriptedClipPlayer()
        let task = playing(player, first)
        defer { task.cancel(); player.finish() }
        try await bounded { await player.waitForPlays(1) }
        #expect(player.isPlaying)
        player.stop()
        try await bounded { try await task.value }
        #expect(!player.isPlaying)
        #expect(player.stopCount == 1)
        // Un `stop()` sans lecture en cours, et un second : comptés, sans effet.
        player.stop()
        player.stop()
        #expect(player.stopCount == 3)
    }

    @Test func cancellingEndsPlay() async throws {
        let player = ScriptedClipPlayer()
        let task = playing(player, first)
        defer { task.cancel(); player.finish() }
        try await bounded { await player.waitForPlays(1) }
        task.cancel()
        try await bounded { try await task.value }   // rend la main normalement : une lecture annulée est une lecture arrêtée
        #expect(!player.isPlaying)
        #expect(player.stopCount == 1)
    }

    /// Une tâche déjà annulée quand `play` commence : `play` rend la main tout de suite et compte un arrêt.
    @Test func aPlayStartedByACancelledTaskReturnsAtOnce() async throws {
        let player = ScriptedClipPlayer()
        let task = playingFromACancelledTask(player, first)
        defer { player.finish() }
        try await bounded { try await task.value }
        #expect(!player.isPlaying)
        #expect(player.stopCount == 1)
        #expect(player.clips == [first])
    }

    /// m2 : l'annulation d'un appel n'arrête que SA lecture. B joue ; un appel A, d'une tâche annulée, passe par le gestionnaire
    /// d'annulation pendant que la lecture en cours est celle de B : B continue. (Le scénario « A remplacée par B, puis A annulée »
    /// n'est pas déterministe avec un double : A sort de sa portée d'annulation dès qu'elle est remplacée. Ce cas-ci fait passer le
    /// gestionnaire de A devant la lecture de B à coup sûr.)
    @Test func cancellingOneCallDoesNotStopAnotherCallsPlay() async throws {
        let player = ScriptedClipPlayer()
        let b = playing(player, second)
        defer { b.cancel(); player.finish() }
        try await bounded { await player.waitForPlays(1) }
        let a = playingFromACancelledTask(player, first)
        try await bounded { try await a.value }
        #expect(player.isPlaying, "la lecture de B doit continuer")
        #expect(player.stopCount == 1)
        player.finish()
        try await bounded { try await b.value }
    }

    /// Un `stop()` arrivé avant `play` ne vaut que pour la lecture en cours, s'il y en a une : il n'arrête pas la suivante (même
    /// règle que `SystemClipPlayer`).
    @Test func aStopBeforePlayDoesNotEndTheNextPlay() async throws {
        let player = ScriptedClipPlayer()
        player.stop()
        let task = playing(player, first)
        defer { task.cancel(); player.finish() }
        try await bounded { await player.waitForPlays(1) }
        #expect(player.isPlaying)
        player.finish()
        try await bounded { try await task.value }
        #expect(player.stopCount == 1)
    }

    /// Une nouvelle lecture arrête la précédente, qui rend la main (même règle que `SystemClipPlayer`) ; ce n'est pas un `stop()`.
    @Test func aNewPlayEndsThePreviousOne() async throws {
        let player = ScriptedClipPlayer()
        let a = playing(player, first)
        defer { a.cancel(); player.finish() }
        try await bounded { await player.waitForPlays(1) }
        let b = playing(player, second)
        defer { b.cancel() }
        try await bounded { await player.waitForPlays(2) }
        try await bounded { try await a.value }
        #expect(player.isPlaying)
        player.finish()
        try await bounded { try await b.value }
        #expect(player.clips == [first, second])
        #expect(player.stopCount == 0)
    }

    /// m1 : un clip vide arrête la lecture en cours puis rend la main, sans lever ; ce n'est pas un `stop()`.
    @Test func anEmptyClipStopsTheCurrentPlayAndReturns() async throws {
        let player = ScriptedClipPlayer()
        let a = playing(player, first)
        defer { a.cancel(); player.finish() }
        try await bounded { await player.waitForPlays(1) }
        try await bounded { try await player.play(silent) }
        try await bounded { try await a.value }
        #expect(!player.isPlaying)
        #expect(player.clips == [first, silent])
        #expect(player.stopCount == 0)
        // Dans les modes immédiat et en échec aussi : rendu tout de suite, sans lever.
        try await ScriptedClipPlayer(completion: .immediate).play(silent)
        try await ScriptedClipPlayer(completion: .failing).play(silent)
    }

    @Test func anImmediatePlayerReturnsAtOnceAndKeepsEveryClip() async throws {
        let player = ScriptedClipPlayer(completion: .immediate)
        try await player.play(first)
        try await player.play(second)
        #expect(player.clips == [first, second])
        #expect(!player.isPlaying)
    }

    @Test func aFailingPlayerThrowsFailedAndKeepsTheClip() async {
        let player = ScriptedClipPlayer(completion: .failing)
        await #expect(throws: ClipPlayerError.failed) { try await player.play(first) }
        #expect(player.clips == [first])
        #expect(!player.isPlaying)
    }

    /// `waitForPlays` d'une tâche annulée avant de s'inscrire rend la main (contrôle d'annulation sous le verrou).
    @Test func waitingForPlaysCancelledBeforeRegisteringReturns() async throws {
        let player = ScriptedClipPlayer()
        let waiting = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await player.waitForPlays(1)
        }
        try await bounded { await waiting.value }
        #expect(player.registeredWaiters == 0)
    }

    /// `waitForPlays` déjà inscrite puis annulée rend la main (gestionnaire d'annulation).
    @Test func waitingForPlaysCancelledAfterRegisteringReturns() async throws {
        let player = ScriptedClipPlayer()
        let waiting = Task { await player.waitForPlays(1) }
        defer { waiting.cancel() }
        // L'inscription est observée, pas supposée : on cède la main jusqu'à la voir (sous la borne anti-suspension).
        try await bounded {
            while player.registeredWaiters < 1 {
                try Task.checkCancellation()
                await Task.yield()
            }
        }
        waiting.cancel()
        try await bounded { await waiting.value }
        #expect(player.registeredWaiters == 0)
        #expect(player.clips.isEmpty)
    }
}

// MARK: - Règle 5 : `SystemClipPlayer`, fonctions pures (sans le construire, sans matériel)

@Suite(.timeLimit(.minutes(1))) struct SystemClipPlayerPureTests {
    /// m8 : la plage est celle des réponses de fournisseur (`ProviderSpeechSynthesizer.acceptedSampleRates`) ; NaN et infinis dehors.
    @Test func onlyAFrequencyAcceptedElsewhereIsPlayable() {
        let accepted = ProviderSpeechSynthesizer.acceptedSampleRates
        #expect(SystemClipPlayer.isPlayable(sampleRate: accepted.lowerBound))
        #expect(SystemClipPlayer.isPlayable(sampleRate: accepted.upperBound))
        #expect(SystemClipPlayer.isPlayable(sampleRate: 22050))
        for rate in [accepted.lowerBound.nextDown, accepted.upperBound.nextUp, 0, -16000, .nan, .infinity, -.infinity, 1e12] {
            #expect(!SystemClipPlayer.isPlayable(sampleRate: rate), "\(rate)")
        }
    }

    /// Point 8 : fin de secours à la durée du clip plus 2 s (valeur du plan, choix non mesuré) ; une durée non finie ou négative
    /// donne une borne finie, la marge seule.
    @Test func theFallbackEndIsTheClipDurationPlusTheMargin() {
        #expect(SystemClipPlayer.fallbackMargin == 2)
        #expect(SystemClipPlayer.fallbackDelay(clipDuration: 0) == 2)
        #expect(SystemClipPlayer.fallbackDelay(clipDuration: 3) == 5)
        for duration in [Double.infinity, -.infinity, .nan, -1] {
            let delay = SystemClipPlayer.fallbackDelay(clipDuration: duration)
            #expect(delay.isFinite && delay == 2, "\(duration)")
        }
    }
}

// MARK: - Règle 5 : essais matériels de `SystemClipPlayer`, désactivés

/// ESSAIS MATÉRIELS. Ce qu'ils font à la machine : ils JOUENT du son par la sortie audio par défaut (haut-parleurs ou casque
/// branché), au volume du système, à amplitude 0,2 (valeur du brief, choix non mesuré), sans ouvrir le micro. Environ 2,6 s de son au
/// total (0,3 s ; puis quatre lectures coupées après 0,5 s ; plus 0,3 s pour la seconde lecture du chevauchement). Désactivés par
/// défaut : ils ne tournent que si `SUPERVOX_PLAYER=1`, variable que seul l'utilisateur positionne. En série, pour ne pas mêler les sons.
/// Chaque lecture est attendue sous `Deadline.run` (3 s, valeur du brief, choix non mesuré) : un délégué qui ne viendrait pas fait
/// échouer l'essai au lieu de le suspendre.
@Suite(.serialized, .timeLimit(.minutes(1)), .enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_PLAYER"] == "1"))
struct SystemClipPlayerHardwareTests {
    /// Un la à 440 Hz (valeur du brief, choix non mesuré) à 44,1 kHz, de `seconds` secondes.
    static func tone(seconds: Double) -> AudioClip {
        let rate = 44_100.0
        return AudioClip(samples: (0..<Int(rate * seconds)).map { Float(0.2 * sin(2 * Double.pi * 440 * Double($0) / rate)) },
                         sampleRate: rate)
    }

    /// Clip long des arrêts : 2 s (valeur du plan, choix non mesuré). L'arrêt est demandé après 0,5 s (choix non mesuré : la lecture
    /// a commencé ; un `stop()` antérieur au début réel serait perdu, par contrat).
    static let longTone = tone(seconds: 2)
    static let stopAfter = Duration.milliseconds(500)

    static func bounded<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Deadline.run(seconds: 3, sleep: { try await Task.sleep(for: .seconds($0)) }, operation)
    }

    /// 0,3 s de son (valeur du brief) : `play` rend la main avant 3 s, et pas avant 0,25 s (une lecture qui rend plus tôt n'a pas
    /// attendu la fin ; marge choisie, non mesurée).
    @Test func aShortToneIsPlayedAndPlayReturnsWithinThreeSeconds() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        try await Self.bounded { try await SystemClipPlayer().play(Self.tone(seconds: 0.3)) }
        #expect(clock.now - start >= .milliseconds(250))
    }

    @Test func stopEndsALongToneBeforeItsEnd() async throws {
        let player = SystemClipPlayer()
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { try await player.play(Self.longTone) }
        defer { task.cancel() }
        try await Task.sleep(for: Self.stopAfter)
        player.stop()
        try await Self.bounded { try await task.value }   // sans lever
        #expect(clock.now - start < .seconds(2), "play doit rendre la main avant la fin du clip")
    }

    @Test func cancellingEndsALongToneBeforeItsEnd() async throws {
        let player = SystemClipPlayer()
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { try await player.play(Self.longTone) }
        defer { task.cancel() }
        try await Task.sleep(for: Self.stopAfter)
        task.cancel()
        try await Self.bounded { try await task.value }
        #expect(clock.now - start < .seconds(2), "play doit rendre la main avant la fin du clip")
    }

    @Test func aSecondPlayEndsTheFirstBeforeItsEnd() async throws {
        let player = SystemClipPlayer()
        let clock = ContinuousClock()
        let start = clock.now
        let first = Task { try await player.play(Self.longTone) }
        defer { first.cancel() }
        try await Task.sleep(for: Self.stopAfter)
        let second = Task { try await player.play(Self.tone(seconds: 0.3)) }
        defer { second.cancel() }
        try await Self.bounded { try await first.value }
        #expect(clock.now - start < .seconds(2), "la première lecture doit rendre la main avant la fin de son clip")
        try await Self.bounded { try await second.value }
    }

    @Test func anEmptyClipEndsTheCurrentToneBeforeItsEnd() async throws {
        let player = SystemClipPlayer()
        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { try await player.play(Self.longTone) }
        defer { task.cancel() }
        try await Task.sleep(for: Self.stopAfter)
        try await Self.bounded { try await player.play(AudioClip(samples: [], sampleRate: 44_100)) }
        try await Self.bounded { try await task.value }
        #expect(clock.now - start < .seconds(2), "play doit rendre la main avant la fin du clip")
    }
}
