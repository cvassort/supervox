import Foundation
import os
import Testing
@testable import SupervoxCore

// Le lecteur de sortie seule et l'encodeur qu'il utilise. Aucun test de la suite par défaut ne joue un son : l'encodeur se prouve
// en mémoire, le contrat de lecture par le double public `ScriptedClipPlayer`. Le seul essai de `SystemClipPlayer` est l'essai
// matériel en fin de fichier, désactivé par défaut.

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
    /// Donc `|d − s| ≤ (|s| + 1/2 + 2^-10) / 32 768`, au plus `(1,5 + 2^-10) / 32 768` ≈ 4,58e-5 pour `|s| = 1`. Le « 1/32 768 » du
    /// brief est dépassé près de ±1 : le facteur d'écriture (32 767) et celui de lecture (32 768) diffèrent, et cet écart grandit
    /// avec `|s|`. Le test l'épingle (`theBriefFigureIsExceededNearFullScale`).
    static func bound(_ s: Float) -> Double { (Double(abs(s)) + 0.5 + 1.0 / 1024) / 32768 }

    /// Un balayage dense de [-1, 1] (pas de 1/4096, choix non mesuré), les extrêmes, et des points tombant à mi-chemin entre deux
    /// paliers de 16 bits près de la pleine échelle (le pire cas de la dérivation).
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

    /// La borne dérivée n'est pas une marge de confort : près de la pleine échelle l'écart observé dépasse 1/32 768, la valeur du brief.
    @Test func theBriefFigureIsExceededNearFullScale() throws {
        let s = Float((32766.5 - 0.01) / 32767)   // arrondi vers 32 766 : e ≈ −0,49, s ≈ 1
        let decoded = try WavFile.decode(WavFile.data(from: AudioClip(samples: [s], sampleRate: 16000)))
        let gap = abs(Double(decoded.samples[0]) - Double(s))
        #expect(gap > 1.0 / 32768)
        #expect(gap <= Self.bound(s))
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

/// Chaque lecture est une tâche fille d'un groupe : si le test est annulé (limite de temps), l'annulation descend jusqu'à `play`.
/// Les attentes du double (`waitForPlays`) rendent la main à l'annulation.
@Suite(.timeLimit(.minutes(1))) struct ScriptedClipPlayerTests {
    @Test func playReturnsOnlyAtTheEnd() async throws {
        let player = ScriptedClipPlayer()
        let finishCalled = OSAllocatedUnfairLock(initialState: false)
        try await withThrowingTaskGroup(of: Bool.self) { group in
            defer { player.finish() }   // une expectation ratée ne laisse pas la lecture pendre
            group.addTask {
                try await player.play(first)
                return finishCalled.withLock { $0 }   // `finish()` avait-il été appelé quand `play` a rendu la main ?
            }
            await player.waitForPlays(1)
            // Sans ordre de fin, la lecture est toujours en cours (déterministe : `play` a enregistré le clip et sa lecture d'un seul
            // tenant, avant de libérer `waitForPlays`).
            #expect(player.isPlaying)
            #expect(player.clips == [first])
            finishCalled.withLock { $0 = true }
            player.finish()
            let sawFinish = try await group.next()
            #expect(sawFinish == true)
            #expect(!player.isPlaying)
            #expect(player.stopCount == 0)
        }
    }

    @Test func stopEndsPlay() async throws {
        let player = ScriptedClipPlayer()
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { player.finish() }
            group.addTask { try await player.play(first) }
            await player.waitForPlays(1)
            #expect(player.isPlaying)
            player.stop()
            try await group.next()
            #expect(!player.isPlaying)
            #expect(player.stopCount == 1)
            // Un `stop()` sans lecture en cours, et un second : comptés, sans effet.
            player.stop()
            player.stop()
            #expect(player.stopCount == 3)
        }
    }

    @Test func cancellingEndsPlay() async throws {
        let player = ScriptedClipPlayer()
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { player.finish() }
            group.addTask { try await player.play(first) }
            await player.waitForPlays(1)
            group.cancelAll()
            try await group.next()   // rend la main normalement : une lecture annulée est une lecture arrêtée
            #expect(!player.isPlaying)
            #expect(player.stopCount == 1)
        }
    }

    /// Une tâche déjà annulée quand `play` commence : `play` rend la main tout de suite et appelle `stop` une fois.
    @Test func aPlayStartedByACancelledTaskReturnsAtOnce() async throws {
        let player = ScriptedClipPlayer()
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { player.finish() }
            group.cancelAll()
            group.addTask { try await player.play(first) }
            try await group.next()
            #expect(!player.isPlaying)
            #expect(player.stopCount == 1)
            #expect(player.clips == [first])
        }
    }

    /// Un `stop()` arrivé avant `play` ne vaut que pour la lecture en cours, s'il y en a une : il n'arrête pas la suivante (même
    /// règle que `SystemClipPlayer`).
    @Test func aStopBeforePlayDoesNotEndTheNextPlay() async throws {
        let player = ScriptedClipPlayer()
        player.stop()
        try await withThrowingTaskGroup(of: Void.self) { group in
            defer { player.finish() }
            group.addTask { try await player.play(first) }
            await player.waitForPlays(1)
            #expect(player.isPlaying)
            player.finish()
            try await group.next()
            #expect(player.stopCount == 1)
        }
    }

    /// Une nouvelle lecture arrête la précédente, qui rend la main (même règle que `SystemClipPlayer`) ; ce n'est pas un `stop()`.
    @Test func aNewPlayEndsThePreviousOne() async throws {
        let player = ScriptedClipPlayer()
        try await withThrowingTaskGroup(of: String.self) { group in
            defer { player.finish() }
            group.addTask { try await player.play(first); return "premier" }
            await player.waitForPlays(1)
            group.addTask { try await player.play(second); return "second" }
            await player.waitForPlays(2)
            let firstReturned = try await group.next()
            #expect(firstReturned == "premier")
            #expect(player.isPlaying)
            player.finish()
            let secondReturned = try await group.next()
            #expect(secondReturned == "second")
            #expect(player.clips == [first, second])
            #expect(player.stopCount == 0)
        }
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

    /// `waitForPlays` rend la main à l'annulation, même si la lecture attendue n'arrive jamais.
    @Test func waitingForPlaysReturnsOnCancellation() async {
        let player = ScriptedClipPlayer()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await player.waitForPlays(1) }
            group.cancelAll()
            await group.next()
        }
        #expect(player.clips.isEmpty)
    }
}

// MARK: - Règle 5 : essai matériel de `SystemClipPlayer`, désactivé

/// ESSAI MATÉRIEL. Ce qu'il fait à la machine : il JOUE un son, 0,3 s d'un la à 440 Hz à volume modéré (amplitude 0,2), par la
/// sortie audio par défaut (haut-parleurs ou casque branché). Il n'ouvre pas le micro. Désactivé par défaut ; il ne tourne que si
/// `SUPERVOX_PLAYER=1`, variable que seul l'utilisateur positionne. Il vérifie que `play` rend la main avant 3 s (borne du brief,
/// choix non mesuré) et pas avant 0,25 s (le clip dure 0,3 s : une lecture qui rend plus tôt n'a pas attendu la fin ; marge choisie,
/// non mesurée).
@Suite(.timeLimit(.minutes(1))) struct SystemClipPlayerHardwareTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_PLAYER"] == "1"))
    func aShortToneIsPlayedAndPlayReturnsWithinThreeSeconds() async throws {
        let rate = 44_100.0
        let tone = AudioClip(samples: (0..<Int(rate * 0.3)).map { Float(0.2 * sin(2 * Double.pi * 440 * Double($0) / rate)) }, sampleRate: rate)
        let clock = ContinuousClock()
        let start = clock.now
        try await Deadline.run(seconds: 3, sleep: { try await Task.sleep(for: .seconds($0)) }) {
            try await SystemClipPlayer().play(tone)
        }
        #expect(clock.now - start >= .milliseconds(250))
    }
}
