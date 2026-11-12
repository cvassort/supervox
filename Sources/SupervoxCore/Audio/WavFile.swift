import Foundation

/// Un enregistrement mono en mémoire : échantillons flottants dans [-1, 1] à une fréquence donnée.
public struct AudioClip: Equatable, Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

public enum WavFileError: Error, Equatable {
    /// Pas de bloc `RIFF`/`WAVE`, ou fichier trop court pour contenir un en-tête.
    case notAWavFile
    /// Un bloc `fmt ` ou `data` manque, est illisible, ou annonce plus d'octets que le fichier n'en contient.
    case malformed(String)
    /// Format valide mais non géré : seul le PCM entier 16 bits mono est accepté.
    case unsupported(String)
}

/// WAV PCM 16 bits mono, little-endian. Pas d'autre format : c'est ce que le banc écrit et relit.
public enum WavFile {
    public static func write(_ clip: AudioClip, to url: URL) throws {
        let dataSize = clip.samples.count * 2
        let rate = UInt32(clip.sampleRate.rounded())
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); u32(UInt32(36 + dataSize)); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(Data("data".utf8)); u32(UInt32(dataSize))
        for s in clip.samples { u16(UInt16(bitPattern: pcm16(s))) }
        try d.write(to: url, options: .atomic)
    }

    /// `Int16(_:)` plante hors de [-32768, 32767] et sur NaN : on écrête et NaN devient du silence.
    private static func pcm16(_ s: Float) -> Int16 {
        if s.isNaN { return 0 }
        return Int16((max(-1, min(1, s)) * 32767).rounded())
    }

    public static func read(_ url: URL) throws -> AudioClip {
        let d = try Data(contentsOf: url)
        func u16(_ o: Int) -> Int { Int(d[d.startIndex + o]) | Int(d[d.startIndex + o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        func tag(_ o: Int) -> String { String(decoding: d[(d.startIndex + o)..<(d.startIndex + o + 4)], as: UTF8.self) }

        guard d.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else { throw WavFileError.notAWavFile }

        var sampleRate: Int?
        var offset = 12
        // On parcourt les blocs : un bloc LIST ou autre peut précéder `data`. Chaque bloc est aligné sur un nombre pair d'octets.
        while offset + 8 <= d.count {
            let id = tag(offset)
            let size = u32(offset + 4)
            let body = offset + 8
            switch id {
            case "fmt ":
                guard size >= 16, body + 16 <= d.count else { throw WavFileError.malformed("bloc fmt tronqué") }
                let format = u16(body), channels = u16(body + 2), bits = u16(body + 14)
                guard format == 1 else { throw WavFileError.unsupported("format \(format), PCM entier attendu") }
                guard channels == 1 else { throw WavFileError.unsupported("\(channels) canaux, mono attendu") }
                guard bits == 16 else { throw WavFileError.unsupported("\(bits) bits, 16 attendus") }
                sampleRate = u32(body + 4)
            case "data":
                guard let rate = sampleRate else { throw WavFileError.malformed("bloc data avant le bloc fmt") }
                guard rate > 0 else { throw WavFileError.malformed("fréquence nulle") }
                guard body + size <= d.count else { throw WavFileError.malformed("bloc data tronqué") }
                let count = size / 2
                let samples = (0..<count).map { i -> Float in
                    Float(Int16(bitPattern: UInt16(u16(body + 2 * i)))) / 32768
                }
                return AudioClip(samples: samples, sampleRate: Double(rate))
            default:
                break
            }
            offset = body + size + (size & 1)
        }
        throw WavFileError.malformed(sampleRate == nil ? "bloc fmt absent" : "bloc data absent")
    }
}
