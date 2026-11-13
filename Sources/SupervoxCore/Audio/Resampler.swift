import AVFAudio
import Foundation

/// Changement de fréquence d'échantillonnage par `AVAudioConverter` (filtre anti-repliement inclus).
public enum Resampler {
    /// Rééchantillonne un clip mono.
    ///
    /// La signature ne lève pas d'erreur : si le convertisseur ne peut pas être créé ou échoue en cours de route,
    /// le résultat est un clip **vide** à la fréquence demandée (jamais un clip tronqué ou faux présenté comme bon).
    /// L'appelant détecte ce cas par la durée nulle ; `record` le refuse comme un enregistrement trop court.
    /// Une fréquence source ou cible <= 0 est une erreur de programmation (`precondition`).
    public static func resample(_ clip: AudioClip, to sampleRate: Double) -> AudioClip {
        precondition(sampleRate > 0 && clip.sampleRate > 0, "fréquence d'échantillonnage invalide")
        if clip.sampleRate == sampleRate { return clip }
        let empty = AudioClip(samples: [], sampleRate: sampleRate)
        if clip.samples.isEmpty { return empty }

        guard
            let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate, channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat),
            let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(clip.samples.count))
        else { return empty }

        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { src in
            input.floatChannelData![0].update(from: src.baseAddress!, count: src.count)
        }

        // Capacité d'un passage : un peu plus que le résultat attendu. On boucle quand même jusqu'à la fin de flux :
        // le convertisseur garde une queue de filtre qui ne sort qu'une fois la fin du flux signalée.
        let expected = Int((Double(clip.samples.count) * sampleRate / clip.sampleRate).rounded(.up))
        let chunk = AVAudioFrameCount(max(expected + 1024, 4096))
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else { return empty }

        var result: [Float] = []
        result.reserveCapacity(expected + 64)
        var delivered = false
        while true {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if delivered {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                delivered = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error || error != nil { return empty }
            let n = Int(output.frameLength)
            if n > 0 { result.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: n)) }
            if status == .endOfStream { break }
            if n == 0 && status != .haveData { break }   // garde-fou contre une boucle sans progrès
        }
        return AudioClip(samples: result, sampleRate: sampleRate)
    }
}
