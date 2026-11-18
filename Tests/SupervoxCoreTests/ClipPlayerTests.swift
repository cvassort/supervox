import Foundation
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
