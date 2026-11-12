import Foundation
import Testing
@testable import SupervoxCore

private func tempWavURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
}

@Test func wavRoundTripKeepsSamplesWithin16BitPrecision() throws {
    let clip = AudioClip(samples: (0..<1600).map { Float(sin(Double($0) * 0.05)) * 0.5 }, sampleRate: 16000)
    let url = tempWavURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try WavFile.write(clip, to: url)
    let back = try WavFile.read(url)
    #expect(back.sampleRate == 16000 && back.samples.count == 1600)
    #expect(zip(clip.samples, back.samples).allSatisfy { abs($0 - $1) < 1.0 / 16384 })
}

@Test func wavReadRejectsNonWavFile() {
    let url = tempWavURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try? Data("pas un wav".utf8).write(to: url)
    #expect(throws: (any Error).self) { try WavFile.read(url) }
}

/// Le fichier produit doit être un WAV canonique : un lecteur tiers (afplay, afinfo) le lit sur la foi de l'en-tête.
@Test func wavFileHasCanonicalMono16BitHeader() throws {
    let url = tempWavURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try WavFile.write(AudioClip(samples: [0, 0.5, -0.5, 1], sampleRate: 16000), to: url)
    let d = [UInt8](try Data(contentsOf: url))
    func u16(_ o: Int) -> Int { Int(d[o]) | Int(d[o + 1]) << 8 }
    func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
    #expect(String(decoding: d[0..<4], as: UTF8.self) == "RIFF")
    #expect(String(decoding: d[8..<16], as: UTF8.self) == "WAVEfmt ")
    #expect(u32(4) == d.count - 8)          // taille RIFF
    #expect(u16(20) == 1)                   // PCM
    #expect(u16(22) == 1)                   // mono
    #expect(u32(24) == 16000)               // fréquence
    #expect(u32(28) == 32000)               // octets par seconde
    #expect(u16(32) == 2)                   // alignement
    #expect(u16(34) == 16)                  // bits par échantillon
    #expect(String(decoding: d[36..<40], as: UTF8.self) == "data")
    #expect(u32(40) == 8 && d.count == 44 + 8)
}

/// La conversion en Int16 plante sur une valeur hors plage ou non finie : on écrête, et NaN devient du silence.
@Test func wavWriteClampsOutOfRangeAndNonFiniteSamples() throws {
    let url = tempWavURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try WavFile.write(AudioClip(samples: [2.0, -3.0, .nan, .infinity, -.infinity], sampleRate: 16000), to: url)
    let back = try WavFile.read(url).samples
    #expect(back.count == 5)
    #expect(abs(back[0] - 1) < 1e-3 && abs(back[1] + 1) < 1e-3)
    #expect(back[2] == 0)
    #expect(abs(back[3] - 1) < 1e-3 && abs(back[4] + 1) < 1e-3)
}

@Test func wavRoundTripOfEmptyClip() throws {
    let url = tempWavURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try WavFile.write(AudioClip(samples: [], sampleRate: 16000), to: url)
    let back = try WavFile.read(url)
    #expect(back.samples.isEmpty && back.sampleRate == 16000)
}

/// Un lecteur doit parcourir les blocs, pas supposer un en-tête de 44 octets : un bloc LIST avant `data` est courant.
@Test func wavReadSkipsUnknownChunksAndHonoursOddPadding() throws {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
    let list = Data("abc".utf8)                       // 3 octets : un octet de bourrage suit
    let pcm: [Int16] = [16384, -16384]
    d.append(Data("RIFF".utf8)); u32(0); d.append(Data("WAVE".utf8))
    d.append(Data("LIST".utf8)); u32(UInt32(list.count)); d.append(list); d.append(0)
    d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(1); u32(8000); u32(16000); u16(2); u16(16)
    d.append(Data("data".utf8)); u32(4); for s in pcm { u16(UInt16(bitPattern: s)) }
    let url = tempWavURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try d.write(to: url)
    let clip = try WavFile.read(url)
    #expect(clip.sampleRate == 8000)
    #expect(clip.samples.count == 2)
    #expect(abs(clip.samples[0] - 0.5) < 1e-3 && abs(clip.samples[1] + 0.5) < 1e-3)
}

@Test func wavReadRejectsStereoAndNon16BitFiles() throws {
    func wav(channels: UInt16, bits: UInt16) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(Data("RIFF".utf8)); u32(40); d.append(Data("WAVE".utf8))
        d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(16000)
        u32(16000 * UInt32(channels) * UInt32(bits / 8)); u16(channels * bits / 8); u16(bits)
        d.append(Data("data".utf8)); u32(4); u32(0)
        return d
    }
    for (channels, bits) in [(UInt16(2), UInt16(16)), (UInt16(1), UInt16(24))] {
        let url = tempWavURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try wav(channels: channels, bits: bits).write(to: url)
        #expect(throws: WavFileError.self) { try WavFile.read(url) }
    }
}

/// Un fichier tronqué (taille de bloc déclarée supérieure au contenu) ne doit ni planter ni être lu à moitié en silence.
@Test func wavReadRejectsTruncatedDataChunk() throws {
    let url = tempWavURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try WavFile.write(AudioClip(samples: Array(repeating: 0.1, count: 100), sampleRate: 16000), to: url)
    let full = try Data(contentsOf: url)
    try full.prefix(full.count - 50).write(to: url)
    #expect(throws: WavFileError.self) { try WavFile.read(url) }
}
