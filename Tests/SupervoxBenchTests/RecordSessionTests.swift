import Foundation
import SupervoxCore
import Testing
@testable import SupervoxBench

// Seul le micro est simulé : les fichiers sont réellement écrits dans un dossier temporaire puis relus avec `WavFile.read`.

/// Enregistreur scripté : rend les clips dans l'ordre, et compte les démarrages et arrêts.
private final class ScriptedRecorder: ClipRecorder, @unchecked Sendable {
    private var clips: [AudioClip]
    private(set) var starts = 0
    private(set) var stops = 0
    var inputDescription: String { "micro de test" }

    init(_ clips: [AudioClip]) { self.clips = clips }
    func start() throws { starts += 1 }
    func stop() -> AudioClip {
        stops += 1
        return clips.isEmpty ? AudioClip(samples: [], sampleRate: 48000) : clips.removeFirst()
    }
}

/// Un sinus d'amplitude donnée à 48 kHz : l'amplitude identifie la prise dans le fichier écrit.
private func take(seconds: Double, amplitude: Float) -> AudioClip {
    let n = Int(seconds * 48000)
    return AudioClip(samples: (0..<n).map { amplitude * Float(sin(2 * .pi * 300 * Double($0) / 48000)) }, sampleRate: 48000)
}

private func peak(_ clip: AudioClip) -> Float {
    clip.samples[400..<(clip.samples.count - 400)].map { abs($0) }.max() ?? 0
}

private struct Harness {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sv-rec-" + UUID().uuidString)
    var said: [String] = []
    func file(_ id: String) -> URL { dir.appendingPathComponent(id + ".wav") }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

private let items = [CorpusItem(id: "p01", text: "Le worker Celery plante.", terms: []),
                     CorpusItem(id: "p02", text: "Merci.", terms: [])]

/// Lance une session avec `enters` appuis sur Entrée disponibles (`nil` ensuite : fin d'entrée).
private func run(_ h: Harness, items: [CorpusItem] = items, recorder: ScriptedRecorder, enters: Int,
                 overwrite: Bool = false) throws -> (RecordSession.Summary, [String]) {
    var remaining = enters
    var output: [String] = []
    let session = RecordSession(
        items: items, outputDirectory: h.dir, overwrite: overwrite, recorder: recorder,
        readLine: { if remaining > 0 { remaining -= 1; return "" } else { return nil } },
        say: { output.append($0) })
    let summary = try session.run()
    return (summary, output)
}

@Test func tooShortTakeIsRefusedAskedAgainAndOnlyTheGoodTakeIsWritten() throws {
    let h = Harness(); defer { h.cleanup() }
    let recorder = ScriptedRecorder([take(seconds: 0.3, amplitude: 0.2), take(seconds: 1.0, amplitude: 0.8)])
    let (summary, out) = try run(h, items: [items[0]], recorder: recorder, enters: 4)

    #expect(summary == .init(recorded: ["p01"], skipped: [], interrupted: false))
    #expect(recorder.starts == 2 && recorder.stops == 2)
    #expect(out.contains { $0.contains("trop court") })
    #expect(out.filter { $0.hasPrefix("[p01]") }.count == 2, "la même phrase est redemandée")
    let written = try WavFile.read(h.file("p01"))
    #expect(written.sampleRate == 16000)
    #expect(abs(written.duration - 1.0) < 0.01)
    #expect(abs(peak(written) - 0.8) < 0.05, "le fichier contient la seconde prise, pas la première")
}

/// La règle est « moins de 0,5 s est refusé » : 0,5 s pile passe.
@Test func durationThresholdIsInclusiveAtHalfASecond() throws {
    let h = Harness(); defer { h.cleanup() }
    let justUnder = take(seconds: 0.49, amplitude: 0.5)
    let exactly = take(seconds: 0.5, amplitude: 0.5)
    let (summary, out) = try run(h, items: [items[0]], recorder: ScriptedRecorder([justUnder, exactly]), enters: 4)
    #expect(summary.recorded == ["p01"])
    #expect(out.filter { $0.contains("trop court") }.count == 1)
}

@Test func existingFileIsNotOverwrittenWithoutFlagAndNothingIsRecorded() throws {
    let h = Harness(); defer { h.cleanup() }
    try FileManager.default.createDirectory(at: h.dir, withIntermediateDirectories: true)
    let original = Data("contenu d'origine".utf8)
    try original.write(to: h.file("p01"))
    let recorder = ScriptedRecorder([take(seconds: 1, amplitude: 0.5)])

    let (summary, out) = try run(h, items: [items[0]], recorder: recorder, enters: 2)

    #expect(summary == .init(recorded: [], skipped: ["p01"], interrupted: false))
    #expect(try Data(contentsOf: h.file("p01")) == original)
    #expect(recorder.starts == 0, "on ne fait pas dire la phrase pour refuser ensuite d'écrire")
    #expect(out.contains { $0.contains("--overwrite") })
}

@Test func existingFileIsReplacedWithOverwriteFlag() throws {
    let h = Harness(); defer { h.cleanup() }
    try FileManager.default.createDirectory(at: h.dir, withIntermediateDirectories: true)
    try Data("contenu d'origine".utf8).write(to: h.file("p01"))

    let (summary, _) = try run(h, items: [items[0]], recorder: ScriptedRecorder([take(seconds: 1, amplitude: 0.5)]),
                               enters: 2, overwrite: true)

    #expect(summary.recorded == ["p01"])
    let written = try WavFile.read(h.file("p01"))
    #expect(written.sampleRate == 16000 && abs(written.duration - 1.0) < 0.01)
}

@Test func skippedSentenceDoesNotStopTheNextOne() throws {
    let h = Harness(); defer { h.cleanup() }
    try FileManager.default.createDirectory(at: h.dir, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: h.file("p01"))
    let (summary, _) = try run(h, recorder: ScriptedRecorder([take(seconds: 1, amplitude: 0.5)]), enters: 2)
    #expect(summary == .init(recorded: ["p02"], skipped: ["p01"], interrupted: false))
    #expect(FileManager.default.fileExists(atPath: h.file("p02").path))
}

@Test func endOfInputAtFirstPromptEndsSessionWithoutRecording() throws {
    let h = Harness(); defer { h.cleanup() }
    let recorder = ScriptedRecorder([])
    let (summary, _) = try run(h, recorder: recorder, enters: 0)
    #expect(summary.interrupted && summary.recorded.isEmpty)
    #expect(recorder.starts == 0)
}

@Test func endOfInputWhileRecordingReleasesMicAndWritesNothing() throws {
    let h = Harness(); defer { h.cleanup() }
    let recorder = ScriptedRecorder([take(seconds: 1, amplitude: 0.5)])
    let (summary, _) = try run(h, recorder: recorder, enters: 1)   // « démarrer » puis plus rien
    #expect(summary.interrupted && summary.recorded.isEmpty)
    #expect(recorder.starts == 1 && recorder.stops == 1, "le micro est libéré")
    #expect(!FileManager.default.fileExists(atPath: h.file("p01").path))
}

/// Sans cette sortie, une entrée fermée pendant la boucle « trop court » redemanderait la phrase indéfiniment.
@Test func endOfInputInsideTheTooShortRetryLoopTerminates() throws {
    let h = Harness(); defer { h.cleanup() }
    let recorder = ScriptedRecorder([take(seconds: 0.1, amplitude: 0.5)])
    let (summary, out) = try run(h, recorder: recorder, enters: 2)   // une prise trop courte, puis fin d'entrée
    #expect(summary.interrupted && summary.recorded.isEmpty)
    #expect(out.contains { $0.contains("trop court") })
    #expect(try FileManager.default.contentsOfDirectory(atPath: h.dir.path).isEmpty)
}

@Test func unsafeIDsAreRejectedBeforeAnyRecording() throws {
    for bad in ["../evil", "a/b", ".caché", ".."] {
        let h = Harness(); defer { h.cleanup() }
        let recorder = ScriptedRecorder([take(seconds: 1, amplitude: 0.5)])
        let corpus = [items[0], CorpusItem(id: bad, text: "x", terms: [])]
        #expect(throws: RecordError.unsafeID(bad)) { _ = try run(h, items: corpus, recorder: recorder, enters: 10) }
        #expect(recorder.starts == 0, "refusé avant la première phrase : \(bad)")
    }
}

@Test func outputDirectoryIsCreatedWhenMissing() throws {
    let h = Harness(); defer { h.cleanup() }
    #expect(!FileManager.default.fileExists(atPath: h.dir.path))
    _ = try run(h, items: [items[0]], recorder: ScriptedRecorder([take(seconds: 1, amplitude: 0.5)]), enters: 2)
    #expect(FileManager.default.fileExists(atPath: h.file("p01").path))
}
