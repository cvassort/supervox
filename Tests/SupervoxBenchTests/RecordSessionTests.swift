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
    /// Journal ordonné : « start », « wait(d) », « stop ».
    private(set) var events: [String] = []
    func note(_ e: String) { events.append(e) }
    var inputDescription: String { "micro de test" }

    init(_ clips: [AudioClip]) { self.clips = clips }
    func start() throws { starts += 1; events.append("start") }
    func stop() -> AudioClip {
        stops += 1
        events.append("stop")
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

/// Date fixe des prises, pour le fichier de capture.
private let takeDate = Date(timeIntervalSince1970: 1_800_000_000)

/// Lance une session avec `enters` appuis sur Entrée disponibles (`nil` ensuite : fin d'entrée), ou, si `answers`
/// est donné, ces réponses dans l'ordre. Une prise gardée demande trois Entrée : démarrer, arrêter, garder.
private func run(_ h: Harness, items: [CorpusItem] = items, recorder: ScriptedRecorder, enters: Int = 0,
                 answers: [String]? = nil, overwrite: Bool = false,
                 tailDelay: Double = 0) throws -> (RecordSession.Summary, [String]) {
    var remaining = answers ?? Array(repeating: "", count: enters)
    var output: [String] = []
    var session = RecordSession(
        items: items, outputDirectory: h.dir, overwrite: overwrite, recorder: recorder,
        readLine: { remaining.isEmpty ? nil : remaining.removeFirst() },
        say: { output.append($0) }, tailDelay: tailDelay, wait: { recorder.note("wait(\($0))") })
    session.now = { takeDate }
    let summary = try session.run()
    return (summary, output)
}

@Test func tooShortTakeIsRefusedAskedAgainAndOnlyTheGoodTakeIsWritten() throws {
    let h = Harness(); defer { h.cleanup() }
    let recorder = ScriptedRecorder([take(seconds: 0.3, amplitude: 0.2), take(seconds: 1.0, amplitude: 0.8)])
    let (summary, out) = try run(h, items: [items[0]], recorder: recorder, enters: 5)

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
    let (summary, out) = try run(h, items: [items[0]], recorder: ScriptedRecorder([justUnder, exactly]), enters: 5)
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
                               enters: 3, overwrite: true)

    #expect(summary.recorded == ["p01"])
    let written = try WavFile.read(h.file("p01"))
    #expect(written.sampleRate == 16000 && abs(written.duration - 1.0) < 0.01)
}

@Test func skippedSentenceDoesNotStopTheNextOne() throws {
    let h = Harness(); defer { h.cleanup() }
    try FileManager.default.createDirectory(at: h.dir, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: h.file("p01"))
    let (summary, _) = try run(h, recorder: ScriptedRecorder([take(seconds: 1, amplitude: 0.5)]), enters: 3)
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
    _ = try run(h, items: [items[0]], recorder: ScriptedRecorder([take(seconds: 1, amplitude: 0.5)]), enters: 3)
    #expect(FileManager.default.fileExists(atPath: h.file("p01").path))
}

/// La fin de prise est protégée : après la 2e Entrée la capture continue `tailDelay` avant `stop()`.
/// Un `stop()` immédiat perdrait jusqu'à une fenêtre de tap (100 à 400 ms) de la fin de la phrase.
@Test func captureKeepsRunningForTheTailDelayBeforeStop() throws {
    let h = Harness(); defer { h.cleanup() }
    let recorder = ScriptedRecorder([take(seconds: 1, amplitude: 0.5)])
    _ = try run(h, items: [items[0]], recorder: recorder, enters: 3, tailDelay: RecordSession.defaultTailDelay)
    #expect(recorder.events == ["start", "wait(0.4)", "stop"])
    #expect(RecordSession.defaultTailDelay >= 0.4, "au moins la fenêtre maximale admise par le SDK (400 ms)")
}

/// Pas d'attente inutile quand l'entrée se ferme : la prise est jetée de toute façon.
@Test func noTailDelayWhenInputClosesWhileRecording() throws {
    let h = Harness(); defer { h.cleanup() }
    let recorder = ScriptedRecorder([take(seconds: 1, amplitude: 0.5)])
    _ = try run(h, items: [items[0]], recorder: recorder, enters: 1, tailDelay: 0.4)
    #expect(recorder.events == ["start", "stop"])
}

// MARK: - Refaire une prise

/// Après une prise, « r » puis Entrée la refait : la phrase est redemandée, seule la prise gardée est écrite.
@Test func aTakeCanBeRedoneAndOnlyTheKeptTakeIsWritten() throws {
    let h = Harness(); defer { h.cleanup() }
    let recorder = ScriptedRecorder([take(seconds: 1.0, amplitude: 0.2), take(seconds: 1.5, amplitude: 0.8)])
    let (summary, out) = try run(h, items: [items[0]], recorder: recorder, answers: ["", "", "r", "", "", ""])
    #expect(summary == .init(recorded: ["p01"], skipped: [], interrupted: false))
    #expect(recorder.starts == 2)
    #expect(out.filter { $0.contains("Entrée pour garder, r puis Entrée pour refaire") }.count == 2)
    #expect(out.filter { $0.hasPrefix("[p01]") }.count == 2, "la même phrase est redemandée")
    let written = try WavFile.read(h.file("p01"))
    #expect(abs(written.duration - 1.5) < 0.01 && abs(peak(written) - 0.8) < 0.05, "la seconde prise, pas la première")
}

/// Refaire une prise ne touche pas au fichier existant tant qu'aucune nouvelle prise n'est gardée.
@Test func redoingDoesNotTouchTheExistingFileUntilATakeIsKept() throws {
    let h = Harness(); defer { h.cleanup() }
    try FileManager.default.createDirectory(at: h.dir, withIntermediateDirectories: true)
    let original = Data("contenu d'origine".utf8)
    try original.write(to: h.file("p01"))
    let (summary, _) = try run(h, items: [items[0]], recorder: ScriptedRecorder([take(seconds: 1, amplitude: 0.5)]),
                               answers: ["", "", "r"], overwrite: true)   // refaire, puis fin d'entrée
    #expect(summary.interrupted && summary.recorded.isEmpty)
    #expect(try Data(contentsOf: h.file("p01")) == original)
}

/// Une réponse autre que vide ou « r » est redemandée ; « R » vaut « r » ; une fin d'entrée à cette question jette
/// la prise (elle n'a pas été gardée).
@Test func unclearAnswerIsAskedAgainAndEndOfInputDiscardsTheTake() throws {
    let h = Harness(); defer { h.cleanup() }
    let recorder = ScriptedRecorder([take(seconds: 1, amplitude: 0.2), take(seconds: 1, amplitude: 0.8)])
    let (summary, out) = try run(h, items: [items[0]], recorder: recorder, answers: ["", "", "oui", " R ", "", "", "", ""])
    #expect(summary.recorded == ["p01"] && recorder.starts == 2)
    #expect(out.contains { $0.contains("non comprise") })
    #expect(abs(peak(try WavFile.read(h.file("p01"))) - 0.8) < 0.05)

    let h2 = Harness(); defer { h2.cleanup() }
    let (closed, _) = try run(h2, items: [items[0]], recorder: ScriptedRecorder([take(seconds: 1, amplitude: 0.5)]), enters: 2)
    #expect(closed.interrupted && closed.recorded.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: h2.file("p01").path))
}

// MARK: - Fichier de capture

/// Chaque prise gardée laisse, à côté des fichiers, le périphérique d'entrée, sa fréquence native et la date ; une
/// session suivante complète le fichier sans effacer les prises précédentes.
@Test func eachKeptTakeIsDescribedInTheCaptureFile() throws {
    let h = Harness(); defer { h.cleanup() }
    _ = try run(h, items: [items[0]], recorder: ScriptedRecorder([take(seconds: 1, amplitude: 0.5)]), enters: 3)
    _ = try run(h, items: [items[1]], recorder: ScriptedRecorder([take(seconds: 1, amplitude: 0.5)]), enters: 3)
    let takes = try CaptureLog.read(h.dir)
    #expect(takes == ["p01": CaptureTake(input: "micro de test", nativeSampleRate: 48000, date: takeDate),
                      "p02": CaptureTake(input: "micro de test", nativeSampleRate: 48000, date: takeDate)])
    #expect(try CaptureLog.read(h.dir.appendingPathComponent("absent")) == [:])
}
