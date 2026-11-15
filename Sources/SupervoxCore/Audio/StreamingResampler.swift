import AVFAudio
import Foundation

/// Rééchantillonnage **continu** d'un flux mono, tranche après tranche, avec un seul `AVAudioConverter` pour toute
/// la prise.
///
/// Pourquoi pas `Resampler.resample` sur chaque tranche : chaque appel crée un convertisseur neuf, dont le filtre
/// repart de zéro, et la sortie s'écarte de celle du clip entier (mesuré dans `StreamingResamplerTests`). Ici l'état
/// du filtre passe d'une tranche à l'autre : la sortie est identique à celle du clip entier, quel que soit le découpage.
///
/// - Même convention que `Resampler` : mono, Float32, qualité maximale.
/// - Fil : les appels sont sérialisés par un verrou interne ; l'ordre des tranches est celui des appels à `push`.
/// - Erreur du convertisseur : l'instance cesse de produire (`push` et `finish` rendent `[]`) et `hasFailed` passe à
///   `true`, définitivement. La signature ne lève pas d'erreur, comme `Resampler` : l'appelant lit `hasFailed` (après
///   `finish()` au plus tard) pour ne pas prendre un flux tronqué pour un flux complet.
public final class StreamingResampler: @unchecked Sendable {
    private let lock = NSLock()
    /// `nil` quand les deux fréquences sont égales : les échantillons passent tels quels.
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat?
    private let outFormat: AVAudioFormat?
    private let ratio: Double
    private var finished = false
    private var failed = false
    /// Pour les tests : appelée avant chaque conversion, `true` simule une erreur du convertisseur.
    var injectedFault: (() -> Bool)?

    /// `true` si une conversion a échoué : la sortie de cette instance est alors incomplète (voir ci-dessus).
    public var hasFailed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    /// `nil` si une fréquence est nulle, négative ou non finie, ou si le système refuse de créer le convertisseur.
    public init?(from: Double, to: Double) {
        guard from.isFinite, to.isFinite, from > 0, to > 0 else { return nil }
        ratio = to / from
        if from == to {
            converter = nil
            inFormat = nil
            outFormat = nil
            return
        }
        guard
            let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
        self.inFormat = inFormat
        self.outFormat = outFormat
    }

    /// Rééchantillonne la tranche suivante. Le filtre garde quelques échantillons en réserve : la sortie d'une tranche
    /// peut être un peu plus courte ou plus longue que le rapport des fréquences ; le total est complété par `finish()`.
    public func push(_ samples: [Float]) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, !failed, !samples.isEmpty else { return [] }
        guard let converter, let inFormat, let outFormat else { return samples }

        guard let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            failed = true
            return []
        }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }
        var supplied = false
        return drain(converter, outFormat, expected: samples.count) { inputStatus in
            if supplied {
                // Plus rien pour l'instant, mais le flux continue : le filtre garde son état.
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
    }

    /// Signale la fin du flux et rend la queue du filtre. L'instance ne sert plus ensuite : `push` et `finish`
    /// rendent alors `[]`.
    public func finish() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return [] }
        finished = true
        guard !failed, let converter, let outFormat else { return [] }
        return drain(converter, outFormat, expected: 0) { inputStatus in
            inputStatus.pointee = .endOfStream
            return nil
        }
    }

    /// Appelle le convertisseur jusqu'à ce qu'il n'ait plus rien à rendre. Appelée verrou pris.
    private func drain(_ converter: AVAudioConverter, _ outFormat: AVAudioFormat, expected: Int,
                       supplying: @escaping (UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer?) -> [Float] {
        // Un peu plus que le résultat attendu ; la boucle reprend si le convertisseur a davantage à rendre.
        let capacity = AVAudioFrameCount(max(Int((Double(expected) * ratio).rounded(.up)) + 1024, 4096))
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            failed = true
            return []
        }
        var result: [Float] = []
        result.reserveCapacity(Int(capacity))
        while true {
            output.frameLength = 0
            if injectedFault?() == true {
                failed = true
                return []
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in supplying(inputStatus) }
            if status == .error || error != nil {
                failed = true
                return []
            }
            let n = Int(output.frameLength)
            if n > 0 { result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: n)) }
            // `.haveData` : la sortie était pleine, il peut en rester. Autrement (`.inputRanDry`, `.endOfStream`) c'est fini.
            if status != .haveData || n == 0 { break }
        }
        return result
    }
}
