import ArgumentParser
import Foundation
import Synchronization
import SupervoxCore
import SupervoxEngines
import Testing

@testable import SupervoxBench

// `supervox-bench interview` : un entretien entier à partir de fichiers WAV. Le moteur de conversation est la vraie
// `ConversationSession` ; le son est le vrai `WavTurnFeed` ; le détecteur de voix, la transcription, les deux modèles et la voix sont
// des doubles. Aucun réseau, aucun modèle téléchargé, aucune voix du système, aucun micro, aucun son. Les noms sont inventés
// (`exemple.invalid`).

// MARK: - Doubles

/// Détecteur de voix par l'énergie : un bloc dont l'amplitude moyenne dépasse 0,05 est de la voix ; trois blocs silencieux de suite
/// ferment le passage. Déterministe, sans modèle.
private final class EnergyDetector: StreamingVoiceDetector {
    let blockSize = 1_600
    private struct State {
        var processed = 0
        var open = false
        var quiet = 0
        var quietStart = 0
    }
    private let state = Mutex(State())
    private let totalProcessed = Mutex(0)

    /// Les échantillons reçus depuis le début, toutes prises confondues (`reset()` ne les remet pas à zéro).
    var total: Int { totalProcessed.withLock { $0 } }

    func prepare() async throws {}
    func reset() async { state.withLock { $0 = State() } }

    func process(_ block: [Float]) async throws -> VoiceEvent? {
        totalProcessed.withLock { $0 += block.count }
        let loud = block.reduce(0) { $0 + abs($1) } / Float(max(block.count, 1)) > 0.05
        return state.withLock { state in
            let start = state.processed
            state.processed += block.count
            if loud {
                state.quiet = 0
                guard !state.open else { return nil }
                state.open = true
                return .speechStart(sample: start)
            }
            guard state.open else { return nil }
            if state.quiet == 0 { state.quietStart = start }
            state.quiet += 1
            guard state.quiet >= 3 else { return nil }
            state.open = false
            return .speechEnd(sample: state.quietStart)
        }
    }
}

/// Une porte que le test ouvre : `pass()` attend l'ouverture, et lève `CancellationError` si la tâche est annulée avant (le moteur
/// abandonne alors sa transcription, comme `Deadline` le demande).
private final class TranscriptionHold: Sendable {
    private let opened = Mutex(false)
    func open() { opened.withLock { $0 = true } }
    func pass() async throws {
        while !opened.withLock({ $0 }) {
            try Task.checkCancellation()
            await Task.yield()
        }
    }
}

/// Transcription par l'amplitude : le tour `i` (rang à partir de 0) est un son d'amplitude 0,30 + 0,01 × i, et le texte rendu est
/// « tour i+1 » : ce que la conversation retient prouve de quel fichier chaque tour vient.
private final class AmplitudeTranscriber: Transcriber {
    let name = "double"
    private let clips = Mutex<[AudioClip]>([])
    private let failure: (any Error)?
    private let hold: TranscriptionHold?

    /// - Parameter hold: retient le premier appel jusqu'à l'ouverture de la porte (un moteur lent), ou à l'annulation de sa tâche.
    init(failure: (any Error)? = nil, hold: TranscriptionHold? = nil) {
        self.failure = failure
        self.hold = hold
    }

    var seen: [AudioClip] { clips.withLock { $0 } }

    func prepare() async throws {}

    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        let rank = clips.withLock { clips -> Int in
            clips.append(clip)
            return clips.count - 1
        }
        if rank == 0, let hold { try await hold.pass() }
        if let failure { throw failure }
        let peak = clip.samples.map { abs($0) }.max() ?? 0
        return "tour \(Int(((peak - 0.30) * 100).rounded()) + 1)"
    }
}

/// Un modèle dont chaque requête reçoit la réponse de même rang du script.
private final class ScriptedLanguageModel: LanguageModel {
    enum Reply {
        case chunks([String])
        case fail(any Error)

        static func text(_ chunks: String...) -> Reply { .chunks(chunks) }
    }

    private let script: [Reply]
    private let received = Mutex<[CompletionRequest]>([])

    init(_ script: [Reply]) { self.script = script }

    var requests: [CompletionRequest] { received.withLock { $0 } }

    func complete(_ request: CompletionRequest) -> AsyncThrowingStream<CompletionEvent, Error> {
        let index = received.withLock { received -> Int in
            received.append(request)
            return received.count - 1
        }
        let reply = script.indices.contains(index) ? script[index] : .fail(EndpointError.malformedResponse)
        return AsyncThrowingStream { continuation in
            switch reply {
            case .chunks(let chunks):
                for chunk in chunks { continuation.yield(.text(chunk)) }
                continuation.yield(.stop(.complete))
                continuation.finish()
            case .fail(let error):
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Une voix qui rend toujours un clip d'un quart de seconde.
private final class QuarterSecondVoice: SpeechSynthesizer {
    private let said = Mutex<[String]>([])
    var texts: [String] { said.withLock { $0 } }

    func synthesize(_ text: String) async throws -> Speech {
        said.withLock { $0.append(text) }
        return Speech(clip: tone(seconds: 0.25))
    }
}


// MARK: - Montage

private let endpointAddress = "https://exemple.invalid/v1"
private let endpointKey = "cle-exemple-secrete"
private let fastName = "modele-rapide-exemple"
private let strongName = "modele-fort-exemple"
private let voiceModelName = "modele-voix-exemple"
private let voiceName = "voix-exemple"

/// Les délais, lus de la commande et du moteur, jamais recopiés : la limite de temps d'une transcription, et le délai d'un tour sans
/// réaction qui en dérive.
private let engineConfig = InterviewCommand.conversationConfig(fastModel: fastName, strongModel: strongName, maxQuestions: 8)
private let engineDeadline = engineConfig.transcriptionTimeout
private let reactionDelay = InterviewCommand.reactionTimeout(for: engineConfig)

private let validEnvironment = [EndpointConfig.baseURLVariable: endpointAddress, EndpointConfig.apiKeyVariable: endpointKey]

private func interviewFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sv-interview-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Un tour parlé (`voice`, rang `turn` : amplitude 0,30 + 0,01 × rang) ou un silence.
private enum FixtureRecording {
    case voice(turn: Int, seconds: Double)
    case silence(seconds: Double)
}

private func writeWavs(_ recordings: [FixtureRecording], in folder: URL) throws -> [String] {
    try recordings.enumerated().map { index, recording in
        let clip: AudioClip
        switch recording {
        case .voice(let turn, let seconds): clip = tone(seconds: seconds, amplitude: 0.30 + 0.01 * Float(turn))
        case .silence(let seconds): clip = tone(seconds: seconds, amplitude: 0)
        }
        let file = folder.appendingPathComponent("tour\(index + 1).wav")
        try WavFile.write(clip, to: file)
        return file.path
    }
}

/// Une réplique de l'intervieweur : le marqueur sur la première ligne, puis une phrase.
private func question(_ marker: String, _ sentence: String) -> ScriptedLanguageModel.Reply { .text(marker + "\n", sentence) }

private func question(_ sentence: String) -> ScriptedLanguageModel.Reply { question("[SUITE]", sentence) }

/// Tout un entretien : doubles, sorties capturées, attentes, horloge.
private final class InterviewRig: Sendable {
    let detector = EnergyDetector()
    let transcriber: AmplitudeTranscriber
    let fast: ScriptedLanguageModel
    let strong: ScriptedLanguageModel
    let voice = QuarterSecondVoice()
    let stdout = LineLog()
    let stderr = LineLog()
    let clock = InterviewClock()
    /// Les attentes que le test tient (celle d'un tour sans réaction, celles qu'il nomme) ; toutes les autres rendent la main aussitôt.
    let board = WaitBoard()
    let watchdogBoard = WaitBoard()
    let holding: Set<Double>
    /// La limite de temps d'une transcription est tenue sur `board` (sinon elle ne se termine jamais, comme `never` de la commande).
    private let holdsEngineDeadline: Bool
    private let setups = Mutex<[InterviewSetup]>([])

    init(fast: [ScriptedLanguageModel.Reply], strong: [ScriptedLanguageModel.Reply] = [.text("Prompt final de l'exemple.")],
         transcriptionFailure: (any Error)? = nil, holding: Set<Double> = [], hold: TranscriptionHold? = nil,
         holdsEngineDeadline: Bool = false) {
        self.fast = ScriptedLanguageModel(fast)
        self.strong = ScriptedLanguageModel(strong)
        transcriber = AmplitudeTranscriber(failure: transcriptionFailure, hold: hold)
        self.holdsEngineDeadline = holdsEngineDeadline
        self.holding = holding.union([reactionDelay])
    }

    var builtSetups: [InterviewSetup] { setups.withLock { $0 } }

    func runtime(environment: [String: String] = validEnvironment) -> InterviewRuntime {
        let (board, watchdogBoard, clock, holding) = (board, watchdogBoard, clock, holding)
        let (stdout, stderr) = (stdout, stderr)
        let holdsEngineDeadline = holdsEngineDeadline
        return InterviewRuntime(
            environment: environment,
            makeEngines: { [self] setup in
                setups.withLock { $0.append(setup) }
                return InterviewEngines(detector: detector, transcriber: transcriber, voice: voice, fast: fast, strong: strong)
            },
            wait: { seconds in
                if holding.contains(seconds) { await board.wait(seconds) } else { await Task.yield() }
            },
            now: { clock.now() }, watchdogSleep: { await watchdogBoard.wait($0) },
            transcriptionSleep: { seconds in
                if holdsEngineDeadline { await board.wait(seconds) } else { try await Task.sleep(for: .seconds(1_000_000)) }
            },
            say: { stdout.add($0) }, warn: { stderr.add($0) }, launchedAt: Date(timeIntervalSince1970: 0), observe: nil)
    }

    var output: String { stdout.all.joined(separator: "\n") }
    var errors: String { stderr.all.joined(separator: "\n") }
}

private func parse(_ arguments: [String]) throws -> InterviewCommand {
    try InterviewCommand.parse(arguments)
}

/// Les arguments obligatoires de modèle.
private let models = ["--fast-model", fastName, "--strong-model", strongName]

/// Cherche la cause d'un `InterviewError` refusé.
private func refusal(_ body: () async throws -> Void) async -> InterviewError? {
    do { try await body() } catch let error as InterviewError { return error } catch {}
    return nil
}

// MARK: - Arguments (règle 1)

@Suite(.timeLimit(.minutes(1))) struct InterviewArgumentTests {
    @Test func theOptionsAreParsedWithTheirDefaults() throws {
        let command = try parse(["a.wav", "b.wav"] + models)
        #expect(command.wavs == ["a.wav", "b.wav"])
        #expect(command.fastModel == fastName && command.strongModel == strongName)
        #expect(command.voiceModel == nil && command.voice == nil)
        #expect(command.maxQuestions == 8)
        #expect(command.turnSilence == 0.5)
        #expect(command.interruptAfter == nil)
        #expect(command.output == nil && !command.overwrite)

        let all = try parse(
            ["a.wav"] + models + ["--voice-model", voiceModelName, "--voice", voiceName, "--max-questions", "3",
                                  "--interrupt-after", "0.5", "--turn-silence", "0.75", "--output", "rapport.md", "--overwrite"])
        #expect(all.voiceModel == voiceModelName && all.voice == voiceName && all.maxQuestions == 3)
        #expect(all.interruptAfter == 0.5 && all.turnSilence == 0.75 && all.output == "rapport.md" && all.overwrite)
    }

    @Test func theModelsAreRequired() {
        #expect(throws: (any Error).self) { try parse(["a.wav", "--strong-model", strongName]) }
        #expect(throws: (any Error).self) { try parse(["a.wav", "--fast-model", fastName]) }
    }

    @Test func atLeastOneWavIsRequiredAndNothingIsBuiltWithout() async throws {
        let session = InterviewRig(fast: [])
        let command = try parse(models)
        let error = await refusal { try await command.run(runtime: session.runtime()) }
        #expect(error == .noWav)
        #expect(session.builtSetups.isEmpty)
    }

    @Test func aVoiceWithoutAVoiceModelIsRefusedWithTheExactSentence() async throws {
        let session = InterviewRig(fast: [])
        let command = try parse(["a.wav"] + models + ["--voice", voiceName])
        let error = await refusal { try await command.run(runtime: session.runtime()) }
        #expect(error == .voiceNeedsVoiceModel)
        #expect(error?.description == "--voice demande aussi --voice-model.")
        #expect(session.builtSetups.isEmpty)
    }

    @Test func aVoiceModelWithoutAVoiceIsRefused() async throws {
        let session = InterviewRig(fast: [])
        let command = try parse(["a.wav"] + models + ["--voice-model", voiceModelName])
        let error = await refusal { try await command.run(runtime: session.runtime()) }
        #expect(error == .voiceModelNeedsVoice)
        #expect(error?.description == "--voice-model demande aussi --voice.")
    }

    @Test(arguments: [EndpointConfig.baseURLVariable, EndpointConfig.apiKeyVariable])
    func aMissingVariableIsReportedWithTheFixedSentenceAndNoValue(missing: String) async throws {
        var environment = validEnvironment
        environment[missing] = nil
        let session = InterviewRig(fast: [])
        let command = try parse(["a.wav"] + models)
        let error = await refusal { try await command.run(runtime: session.runtime(environment: environment)) }
        #expect(error == .missingEndpoint)
        let text = try #require(error?.description)
        #expect(text == "Définissez SUPERVOX_BASE_URL et SUPERVOX_API_KEY pour lancer l'entretien du banc.")
        // L'autre variable est définie : sa valeur ne se retrouve ni dans l'erreur ni sur une sortie.
        for secret in [endpointAddress, endpointKey, "exemple.invalid"] {
            #expect(!text.contains(secret) && !session.output.contains(secret) && !session.errors.contains(secret))
        }
        #expect(session.builtSetups.isEmpty)
    }

    @Test(arguments: [
        ["--max-questions", "0"], ["--interrupt-after=0"], ["--interrupt-after=-1"], ["--interrupt-after", "nan"],
        ["--turn-silence", "0"], ["--turn-silence", "0.29"], ["--turn-silence", "2.01"], ["--turn-silence", "inf"], ["--turn-silence", "nan"],
        ["--turn-silence=-0.5"],
    ])
    func anUnreasonableOptionIsRefusedBeforeAnythingIsBuilt(extra: [String]) async throws {
        let session = InterviewRig(fast: [])
        let command = try parse(["a.wav"] + models + extra)
        let error = await refusal { try await command.run(runtime: session.runtime()) }
        guard case .invalidOption? = error else {
            Issue.record("refus attendu, reçu \(String(describing: error))")
            return
        }
        #expect(session.builtSetups.isEmpty)
    }

    @Test func aTurnSilenceOutsideTheBoundsIsRefusedWithASentenceThatGivesThem() async throws {
        let session = InterviewRig(fast: [])
        for value in ["0.29", "2.01"] {
            let command = try parse(["a.wav"] + models + ["--turn-silence", value])
            let error = await refusal { try await command.run(runtime: session.runtime()) }
            guard case .invalidOption(let sentence)? = error else {
                Issue.record("refus attendu pour \(value), reçu \(String(describing: error))")
                continue
            }
            #expect(sentence.contains("0,3") && sentence.contains("2,0"), "\(sentence)")
        }
        #expect(session.builtSetups.isEmpty)
    }

    @Test func anUnreadableOrEmptyWavIsRefusedByItsNameBeforeAnythingIsBuilt() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let notWav = folder.appendingPathComponent("faux.wav")
        try "ceci n'est pas un WAV".write(to: notWav, atomically: true, encoding: .utf8)
        let empty = folder.appendingPathComponent("vide.wav")
        try WavFile.write(AudioClip(samples: [], sampleRate: 16_000), to: empty)

        let session = InterviewRig(fast: [])
        let first = try parse([notWav.path] + models)
        let error = await refusal { try await first.run(runtime: session.runtime()) }
        guard case .unreadableWav(let name, _)? = error else {
            Issue.record("refus attendu, reçu \(String(describing: error))")
            return
        }
        #expect(name == "faux.wav")   // le nom du fichier, pas son chemin
        let second = try parse([empty.path] + models)
        #expect(await refusal { try await second.run(runtime: session.runtime()) } == .emptyWav("vide.wav"))
        #expect(session.builtSetups.isEmpty)
    }
}

// MARK: - Le rapport et sa sortie (règle 3)

@Suite(.timeLimit(.minutes(1))) struct InterviewOutputTests {
    @Test func anExistingReportIsRefusedBeforeAnythingIsBuiltUnlessOverwriteIsGiven() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6)], in: folder)
        let report = folder.appendingPathComponent("rapport.md")
        try "ancien".write(to: report, atomically: true, encoding: .utf8)

        let refused = InterviewRig(fast: [question("Quelle est la première question ?")])
        let command = try parse(wavs + models + ["--output", report.path])
        await #expect(throws: OutputError.reportExists(report.path)) { try await command.run(runtime: refused.runtime()) }
        #expect(refused.builtSetups.isEmpty)
        #expect(try String(contentsOf: report, encoding: .utf8) == "ancien")

        let allowed = InterviewRig(fast: [question("Quelle est la première question ?")])
        let replacing = try parse(wavs + models + ["--output", report.path, "--overwrite"])
        try await replacing.run(runtime: allowed.runtime())
        #expect(try String(contentsOf: report, encoding: .utf8).hasPrefix("# Entretien du banc"))
    }

    @Test func overwriteNeverReplacesAnInputWavWhateverTheSpellingOfItsPath() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6), .voice(turn: 1, seconds: 0.6)], in: folder)
        let before = try Data(contentsOf: URL(fileURLWithPath: wavs[1]))

        var spellings = [wavs[1], folder.path + "/./tour2.wav", folder.path + "/sous/../tour2.wav"]
        // Une autre casse n'est le même fichier que sur un volume qui l'ignore (le réglage par défaut de macOS) ; ailleurs, c'est un
        // autre nom, sans risque pour l'entrée.
        let otherCase = folder.path + "/TOUR2.WAV"
        if FileManager.default.fileExists(atPath: otherCase) { spellings.append(otherCase) }
        for spelling in spellings {
            let session = InterviewRig(fast: [])
            let command = try parse(wavs + models + ["--output", spelling, "--overwrite"])
            let error = await refusal { try await command.run(runtime: session.runtime()) }
            #expect(error == .outputIsAnInput("tour2.wav"), "\(spelling)")
            #expect(session.builtSetups.isEmpty)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: wavs[1])) == before, "le fichier d'entrée a été touché")
    }

    /// Deux noms, un seul fichier (lien physique) : la comparaison des chemins ne les rapproche pas, seule l'identité du fichier le fait.
    /// Dans les deux sens : la sortie est le lien de l'entrée, ou l'entrée est le lien de la sortie.
    @Test func overwriteNeverReplacesAnInputWavThroughAHardLink() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6), .voice(turn: 1, seconds: 0.6)], in: folder)
        let original = URL(fileURLWithPath: wavs[1])
        let link = folder.appendingPathComponent("lien-vers-tour2.md")
        try FileManager.default.linkItem(at: original, to: link)
        // Précondition lue par un autre chemin que le code testé : les deux noms désignent bien le même fichier (même numéro d'inode).
        var (first, second) = (stat(), stat())
        try #require(stat(original.path, &first) == 0 && stat(link.path, &second) == 0)
        try #require(first.st_ino == second.st_ino && first.st_nlink == 2, "le lien physique n'a pas été créé")
        let before = try Data(contentsOf: original)

        // La sortie est un autre nom du fichier d'entrée.
        let outputIsTheLink = InterviewRig(fast: [])
        let first1 = try parse(wavs + models + ["--output", link.path, "--overwrite"])
        let refused = await refusal { try await first1.run(runtime: outputIsTheLink.runtime()) }
        #expect(refused == .outputIsAnInput("tour2.wav"))
        #expect(outputIsTheLink.builtSetups.isEmpty)

        // L'entrée est donnée sous le nom du lien, la sortie sous le nom d'origine.
        let inputIsTheLink = InterviewRig(fast: [])
        let second1 = try parse([wavs[0], link.path] + models + ["--output", original.path, "--overwrite"])
        let refusedAgain = await refusal { try await second1.run(runtime: inputIsTheLink.runtime()) }
        #expect(refusedAgain == .outputIsAnInput("lien-vers-tour2.md"))
        #expect(inputIsTheLink.builtSetups.isEmpty)

        #expect(try Data(contentsOf: original) == before, "le fichier d'entrée a été touché")
        #expect(try Data(contentsOf: link) == before)
    }

    /// Sans fichier à comparer (ni l'entrée ni la sortie n'existent), ce sont les chemins résolus qui le sont : la commande refuse
    /// comme pour un fichier qui existe, au lieu de laisser la lecture de l'entrée absente se plaindre à sa place.
    @Test func anOutputThatDoesNotExistYetIsComparedByItsResolvedPathWithAnInputThatDoesNotExistEither() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let absent = folder.appendingPathComponent("absent.wav").path
        let session = InterviewRig(fast: [])
        let command = try parse([absent] + models + ["--output", folder.path + "/sous/../absent.wav", "--overwrite"])

        let refused = await refusal { try await command.run(runtime: session.runtime()) }

        #expect(refused == .outputIsAnInput("absent.wav"))
        #expect(session.builtSetups.isEmpty)
    }

    @Test func overwriteNeverReplacesAFileGitTracksEvenInAFolderAPatternIgnores() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", folder.path] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            try #require(process.terminationStatus == 0, "git \(arguments) a échoué")
        }
        try git(["init", "-q"])
        try "sortie/\nlibre/\n".write(to: folder.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        let tracked = folder.appendingPathComponent("sortie/rapport.md")
        try FileManager.default.createDirectory(at: tracked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "suivi".write(to: tracked, atomically: true, encoding: .utf8)
        try git(["add", "-f", "sortie/rapport.md"])
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6)], in: folder)

        // Mesuré : git ne tient pas pour « ignoré » un dossier qui contient un fichier suivi (`git check-ignore`), donc la garde du
        // dossier (`OutputGuard.checkIgnoredByGit`) refuse le fichier suivi, `--overwrite` ou non : cette option ne lève que la garde
        // « le rapport existe déjà ».
        for extra in [["--overwrite"], [String]()] {
            let session = InterviewRig(fast: [])
            let command = try parse(wavs + models + ["--output", tracked.path] + extra)
            await #expect(throws: OutputError.self) { try await command.run(runtime: session.runtime()) }
            #expect(session.builtSetups.isEmpty)
        }
        #expect(try String(contentsOf: tracked, encoding: .utf8) == "suivi")

        // Un dossier ignoré qui ne contient rien de suivi : accepté.
        let free = folder.appendingPathComponent("libre/rapport.md")
        let rig = InterviewRig(fast: [question("Quelle est la première question ?")])
        try await parse(wavs + models + ["--output", free.path]).run(runtime: rig.runtime())
        #expect(try String(contentsOf: free, encoding: .utf8).hasPrefix("# Entretien du banc"))
    }

    @Test func aReportInsideAGitRepositoryThatDoesNotIgnoreItIsRefusedBeforeAnythingIsBuilt() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "init", "-q", folder.path]
        try git.run()
        git.waitUntilExit()
        try #require(git.terminationStatus == 0)
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6)], in: folder)

        let session = InterviewRig(fast: [])
        let command = try parse(wavs + models + ["--output", folder.appendingPathComponent("sortie/rapport.md").path])
        await #expect(throws: OutputError.self) { try await command.run(runtime: session.runtime()) }
        #expect(session.builtSetups.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("sortie").path))
    }

    @Test func neitherTheKeyNorTheAddressNorAModelNameIsWrittenAnywhere() async throws {
        // Le modèle répète tout ce qu'il connaît : sans retrait, la conversation du rapport porterait la clé, l'adresse et les noms.
        let echo = "Je suis joignable à \(endpointAddress), sur \(endpointAddress.dropFirst(8)), avec la clé \(endpointKey), "
            + "modèles \(fastName) et \(strongName), voix \(voiceName) du modèle \(voiceModelName). Autre question ?"
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6)], in: folder)
        let secrets = [endpointKey, endpointAddress, "exemple.invalid", fastName, strongName, voiceModelName, voiceName]

        // Une fois avec un fichier de rapport, une fois sur la sortie standard.
        let report = folder.appendingPathComponent("rapport.md")
        for output in [["--output", report.path], [String]()] {
            let session = InterviewRig(fast: [question(echo)], strong: [.text("Prompt du modèle \(strongName) sur \(endpointAddress).")])
            let command = try parse(wavs + models + ["--voice-model", voiceModelName, "--voice", voiceName] + output)
            try await command.run(runtime: session.runtime())

            // Le test n'est pas vide : les doubles ont bien reçu l'adresse, la clé, les noms de la ligne de commande.
            let setup = try #require(session.builtSetups.first)
            #expect(setup.endpoint.baseURL.absoluteString == endpointAddress && setup.endpoint.apiKey == endpointKey)
            #expect(setup.voiceModel == voiceModelName && setup.voice == voiceName)
            #expect(session.fast.requests.first?.model == fastName)
            #expect(session.strong.requests.first?.model == strongName)
            #expect(session.voice.texts.first?.contains(endpointKey) == true, "la voix a dit ce que le modèle a répondu")

            let written = output.isEmpty ? session.output : try String(contentsOf: report, encoding: .utf8) + session.output
            for secret in secrets {
                #expect(!written.contains(secret), "« \(secret) » est écrit")
                #expect(!session.errors.contains(secret))
            }
            // Retiré, pas disparu : le reste de la phrase est là, avec les marques de retrait.
            #expect(written.contains("Je suis joignable à <endpoint>"))
            #expect(written.contains("<modèle>") && written.contains("***"))
            try? FileManager.default.removeItem(at: report)
        }
    }
}

// MARK: - Les moteurs réels

@Suite(.timeLimit(.minutes(1))) struct InterviewRealEnginesTests {
    private func setup(voice: Bool, silence: Double = 0.75) -> InterviewSetup {
        InterviewSetup(
            endpoint: EndpointConfig(baseURL: URL(string: endpointAddress)!, apiKey: endpointKey),
            voiceModel: voice ? voiceModelName : nil, voice: voice ? voiceName : nil, turnSilence: silence)
    }

    @Test func theVoiceOfTheProviderFallsBackOnTheSystemVoiceOnlyWhenBothVoiceOptionsAreGiven() {
        #expect(InterviewEngines.real(setup(voice: true)).voice is FallbackSpeechSynthesizer)
        #expect(InterviewEngines.real(setup(voice: false)).voice is SystemSpeechSynthesizer)
    }

    @Test func theTurnSilenceReachesTheDetectorAndTheEnginesAreTheOnesOfTheInterview() async throws {
        let engines = InterviewEngines.real(setup(voice: false, silence: 0.75))
        let detector = try #require(engines.detector as? FluidStreamingVoiceDetector)
        let silence = await detector.minSilence
        #expect(silence == 0.75)
        #expect(engines.transcriber is ParakeetTranscriber)
        #expect(engines.fast is OpenAICompatibleClient && engines.strong is OpenAICompatibleClient)
    }

    /// Le comportement, sur le vrai moteur : un son qui ne livre aucune tranche pendant longtemps (le banc, pendant que le modèle
    /// réfléchit et que la réplique « joue ») fait échouer le chien de garde de l'application (`MicrophoneWatchdog.system`), pas celui du
    /// banc. L'horloge est celle du test : 100 s passent d'un coup, puis le chien de garde est interrogé une fois.
    @Test(arguments: [false, true])
    func aFeedThatDeliversNothingFailsTheApplicationWatchdogButNotTheBenchOne(bench: Bool) async throws {
        let clock = InterviewClock()
        let polls = WaitBoard()
        var watchdog = bench ? InterviewCommand.watchdog(sleep: { await polls.wait($0) }) : MicrophoneWatchdog.system
        if !bench { watchdog.sleep = { await polls.wait($0) } }
        let never: @Sendable (Double) async throws -> Void = { _ in try await Task.sleep(for: .seconds(1_000_000)) }
        let session = ConversationSession(
            audio: WavTurnFeed(turns: [], wait: { _ in }, now: { clock.now() }), detector: EnergyDetector(),
            transcriber: AmplitudeTranscriber(), fastModel: ScriptedLanguageModel([]), strongModel: ScriptedLanguageModel([]),
            voice: QuarterSecondVoice(),
            config: InterviewCommand.conversationConfig(fastModel: fastName, strongModel: strongName, maxQuestions: 8),
            watchdog: watchdog, now: { clock.now() }, sleep: never, transcriptionSleep: never)
        let stream = await session.start()
        var events = stream.makeAsyncIterator()
        var listening = false
        while !listening, let event = await events.next() { listening = event == .state(.listening) }
        try #require(listening)

        // Le chien de garde attend sa prochaine vérification ; 100 s plus tard, il la fait.
        try #require(await settle { polls.pendingSeconds.count == 1 })
        clock.advance(100)
        #expect(polls.release(seconds: polls.pendingSeconds[0]))
        if bench {
            // Il a vérifié et n'a rien trouvé : il attend la suivante. L'entretien tourne toujours, il s'arrête sur demande.
            try #require(await settle { polls.requests.count == 2 })
            await session.cancel()
        }
        var end: ConversationEnd?
        while let event = await events.next() { if case .finished(let ended) = event { end = ended } }
        if bench {
            #expect(end == .cancelled)
        } else {
            guard case .failed(.microphone(let code), _)? = end else {
                Issue.record("panne du micro attendue, reçu \(String(describing: end))")
                return
            }
            #expect(code == ConversationFailure.Code.silent)
        }
    }
}

// MARK: - Un entretien entier (règles 2 et 4)

@Suite(.timeLimit(.minutes(1))) struct InterviewRunTests {
    private func report(_ file: URL) throws -> String { try String(contentsOf: file, encoding: .utf8) }

    @Test func anInterviewRunsFromTheFilesAndEndsWithThePromptAfterTheLastReply() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6), .voice(turn: 1, seconds: 0.6)], in: folder)
        let session = InterviewRig(fast: [question("Quelle est la première question ?"), question("[PROPOSER]", "Puis-je conclure ?")])
        let file = folder.appendingPathComponent("rapport.md")
        let command = try parse(wavs + models + ["--output", file.path, "--turn-silence", "0.75"])

        try await command.run(runtime: session.runtime())

        // Chaque fichier est un tour, dans l'ordre : la transcription a reçu deux passages, d'amplitudes 0,30 et 0,31.
        #expect(session.transcriber.seen.count == 2)
        let text = try report(file)
        #expect(text.hasPrefix("# Entretien du banc"))
        #expect(text.contains("Vous : tour 1\n\nSupervox : Quelle est la première question ?\n\nVous : tour 2\n\n"
                              + "Supervox : Puis-je conclure ?"))
        // La conversation revient au modèle : la seconde requête a l'historique de la première.
        #expect(session.fast.requests.count == 2)
        let second = try #require(session.fast.requests.last)
        #expect(second.input == "tour 2")
        #expect(second.history == [CompletionTurn(role: .user, text: "tour 1"),
                                   CompletionTurn(role: .assistant, text: "Quelle est la première question ?")])
        // La conclusion est demandée une fois, après le dernier fichier, avec toute la conversation.
        #expect(session.strong.requests.count == 1)
        let conclusion = try #require(session.strong.requests.first)
        #expect(conclusion.input.contains("Vous : tour 1") && conclusion.input.contains("Supervox : Puis-je conclure ?"))
        // Le rapport.
        #expect(text.contains("- Fin : prompt rédigé."))
        #expect(text.contains("- Tours poussés : 2 sur 2 ; textes rendus par la transcription : 2."))
        #expect(text.contains("- Questions posées : 2 (au plus 8)."))
        #expect(text.contains("- Signal de chaque réplique du modèle rapide : suite (une question) ; proposition de conclure."))
        #expect(text.contains("l'intervieweur a proposé de conclure"))
        #expect(text.contains("- Interruptions : 0."))
        #expect(text.contains("Silence de fin de tour du détecteur : 0,75 s"))
        #expect(text.contains("tour suivant poussé après la fin de la réplique."))
        #expect(text.contains("Prompt final de l'exemple."))
        // Les trois durées de chaque tour sont mesurées, et le rapport dit qu'elles ne se comparent pas aux étapes précédentes.
        let rows = text.components(separatedBy: "\n").filter { $0.hasPrefix("| 1 |") || $0.hasPrefix("| 2 |") }
        #expect(rows.count == 2 && rows.allSatisfy { !$0.contains("—") })
        #expect(text.contains("ne sont pas comparables aux mesures de latence des étapes précédentes"))
        // La console : les tours, la fin, le prompt, le chemin du rapport.
        #expect(session.stdout.all.contains("Tour 1 sur 2 poussé.") && session.stdout.all.contains("Tour 2 sur 2 poussé."))
        #expect(session.stdout.all.contains("Fin : prompt rédigé."))
        #expect(session.output.contains("Prompt :\n\nPrompt final de l'exemple."))
        #expect(session.output.contains("Rapport : \(file.path)"))
        #expect(session.errors.isEmpty)
        // La voix a dit les deux répliques, une phrase chacune.
        #expect(session.voice.texts == ["Quelle est la première question ?", "Puis-je conclure ?"])
        // Les moteurs ont reçu les options de la ligne de commande, et le chien de garde du banc est celui qui est monté.
        #expect(session.builtSetups.map(\.turnSilence) == [0.75])
        #expect(session.builtSetups.map(\.voiceModel) == [nil])
        #expect(fastRequestModel(session) == fastName && session.strong.requests.first?.model == strongName)
        let sleeping = await settle { session.watchdogBoard.requests == [InterviewCommand.watchdogPoll] }
        #expect(sleeping, "le chien de garde monté n'est pas celui du banc : \(session.watchdogBoard.requests)")
    }

    private func fastRequestModel(_ session: InterviewRig) -> String? { session.fast.requests.first?.model }

    @Test func withoutAnOutputFileTheReportGoesToTheStandardOutput() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6)], in: folder)
        let session = InterviewRig(fast: [question("Quelle est la première question ?")])

        try await parse(wavs + models).run(runtime: session.runtime())

        #expect(session.output.contains("# Entretien du banc"))
        #expect(session.output.contains("## Prompt"))
    }

    @Test func theQuestionLimitConcludesTheInterviewBeforeTheLastFileIsPushed() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs((0..<3).map { .voice(turn: $0, seconds: 0.6) }, in: folder)
        let session = InterviewRig(fast: [question("Quelle est la première question ?")])
        let file = folder.appendingPathComponent("rapport.md")

        try await parse(wavs + models + ["--max-questions", "1", "--output", file.path]).run(runtime: session.runtime())

        // Le moteur conclut de lui-même après la réponse au tour 2 : le tour 3 n'est jamais poussé.
        #expect(session.transcriber.seen.count == 2)
        #expect(session.fast.requests.count == 1)
        #expect(session.strong.requests.count == 1)
        let text = try report(file)
        #expect(text.contains("- Tours poussés : 2 sur 3 ; textes rendus par la transcription : 2."))
        #expect(text.contains("Vous : tour 1\n\nSupervox : Quelle est la première question ?\n\nVous : tour 2"))
        #expect(text.contains("- Fin : prompt rédigé."))
    }

    /// Les bornes de l'application (0,3 à 2,0 s) sont acceptées, et le silence poussé après chaque tour suit la valeur : le détecteur
    /// double (blocs de 0,1 s) reçoit la voix du tour (0,6 s) et le silence qui lui convient, dont la somme est mesurée à un bloc près.
    @Test(arguments: [(0.3, 2.0), (0.5, 2.0), (2.0, 3.1)])
    func theSilencePushedAfterATurnFollowsTheTurnSilence(silence: Double, trailing: Double) async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6)], in: folder)
        let session = InterviewRig(fast: [question("Quelle est la première question ?")])

        try await parse(wavs + models + ["--turn-silence", "\(silence)"]).run(runtime: session.runtime())

        #expect(session.builtSetups.map(\.turnSilence) == [silence])
        let pushed = Int(((0.6 + trailing) * 16_000).rounded())
        let received = session.detector.total
        #expect(received <= pushed && received >= pushed - 2 * 1_600, "\(received) échantillons reçus, \(pushed) poussés")
    }

    @Test func aReplyThatConcludesEndsTheInterviewWithoutPushingTheNextFileOrAskingForTheConclusionTwice() async throws {
        // Une réplique `[CONCLURE]` : le vrai moteur émet `.speakingEnded` puis `.state(.concluding)` et ne reprend pas l'écoute. Un
        // pilote qui poussait le tour suivant dès `.speakingEnded` (au lieu du `.state(.listening)` qui suit) pousserait le tour 2.
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs((0..<3).map { .voice(turn: $0, seconds: 0.6) }, in: folder)
        let session = InterviewRig(fast: [question("[CONCLURE]", "Merci, c'est noté.")])
        let file = folder.appendingPathComponent("rapport.md")

        try await parse(wavs + models + ["--output", file.path]).run(runtime: session.runtime())

        #expect(session.transcriber.seen.count == 1)
        #expect(session.fast.requests.count == 1)
        #expect(session.strong.requests.count == 1)
        #expect(session.voice.texts == ["Merci, c'est noté."])
        let text = try report(file)
        #expect(text.contains("- Tours poussés : 1 sur 3 ; textes rendus par la transcription : 1."))
        // Une conclusion n'est pas une question : `.speakingStarted(question: 0)`.
        #expect(text.contains("- Questions posées : 0 (au plus 8)."))
        #expect(text.contains("- Signal de chaque réplique du modèle rapide : conclusion."))
        #expect(text.contains("Vous : tour 1\n\nSupervox : Merci, c'est noté."))
        #expect(text.contains("- Fin : prompt rédigé."))
    }

    @Test(arguments: [(0.0, "rien"), (0.2, "« Quelle est la première question ? »")])
    func anInterruptionCutsTheReplyAndTheReportSaysWhatWasHeard(elapsed: Double, heard: String) async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6), .voice(turn: 1, seconds: 0.6)], in: folder)
        // Les attentes de 0,5 s (le délai avant d'interrompre) et d'un quart de seconde (la lecture du clip) sont tenues par le test.
        let session = InterviewRig(fast: [question("Quelle est la première question ?"), question("Et ensuite ?")], holding: [0.5, 0.25])
        let file = folder.appendingPathComponent("rapport.md")
        let command = try parse(wavs + models + ["--interrupt-after", "0.5", "--output", file.path])
        let runtime = session.runtime()
        let running = Task { try await command.run(runtime: runtime) }

        // La première réplique est en cours de lecture (clip d'un quart de seconde) et le délai d'interruption est armé.
        try #require(await settle { session.board.pendingSeconds.contains(0.5) && session.board.pendingSeconds.contains(0.25) })
        #expect(session.transcriber.seen.count == 1, "le tour 2 n'est pas poussé avant la fin du délai")
        session.clock.advance(elapsed)
        #expect(session.board.release(seconds: 0.5))

        // Le tour 2 coupe la parole : tant que la lecture du clip est tenue, la réplique ne peut pas finir d'elle-même, et le moteur
        // ne transcrit ce tour que s'il l'a entendu en interrompant (pendant la réplique, un passage n'est jamais un tour sans cela).
        // Seulement alors, la lecture de la suite est laissée se terminer.
        try #require(await settle { session.transcriber.seen.count == 2 })
        let releaser = Task {
            while !Task.isCancelled {
                session.board.release(seconds: 0.25)
                await Task.yield()
            }
        }
        defer { releaser.cancel() }
        try await finished(running)

        let text = try report(file)
        #expect(text.contains("- Interruptions : 1 (ce qui avait été entendu : \(heard))."), "\(text)")
        if elapsed == 0 {
            // Rien entendu : la réplique n'est pas retenue, et le tour 2 rejoint le tour 1.
            #expect(text.contains("Vous : tour 1 tour 2"))
            #expect(!text.contains("Supervox : Quelle est la première question ?"))
        } else {
            #expect(text.contains("Vous : tour 1\n\nSupervox : Quelle est la première question ?\n\nVous : tour 2"))
        }
        #expect(text.contains("- Fin : prompt rédigé."))
    }

    @Test func aFileWithoutVoiceIsNotedAndTheNextTurnStillGoes() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.silence(seconds: 1), .voice(turn: 1, seconds: 0.6)], in: folder)
        let session = InterviewRig(fast: [question("Quelle est la première question ?")])
        let file = folder.appendingPathComponent("rapport.md")
        let command = try parse(wavs + models + ["--output", file.path])
        let runtime = session.runtime()
        let running = Task { try await command.run(runtime: runtime) }

        // Le moteur ne réagit pas au premier fichier : l'attente d'un tour sans réaction est armée, le test la rend.
        try #require(await settle { session.board.pendingSeconds == [reactionDelay] })
        #expect(session.board.release(seconds: reactionDelay))
        try await finished(running)

        let text = try report(file)
        #expect(text.contains("- Tours poussés : 2 sur 2 ; textes rendus par la transcription : 1."))
        #expect(text.contains("aucune réaction du moteur"))
        #expect(text.contains("Vous : tour 2"))
        #expect(session.transcriber.seen.count == 1)
    }

    @Test func aSingleFileWithoutVoiceEndsWithNothingSaidAndANonZeroExit() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.silence(seconds: 1)], in: folder)
        let session = InterviewRig(fast: [])
        let file = folder.appendingPathComponent("rapport.md")
        let command = try parse(wavs + models + ["--output", file.path])
        let runtime = session.runtime()
        let running = Task { try await command.run(runtime: runtime) }

        try #require(await settle { session.board.pendingSeconds == [reactionDelay] })
        session.board.release(seconds: reactionDelay)
        await #expect(throws: ExitCode.self) { try await finished(running) }

        #expect(try report(file).contains("- Fin : rien n'a été dit"))
        #expect(session.strong.requests.isEmpty)
        #expect(session.fast.requests.isEmpty)
    }

    // MARK: Un moteur lent (I-1)

    @Test func aSlowTranscriptionUnderTheEngineDeadlineDoesNotLetTheNextTurnGo() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6), .voice(turn: 1, seconds: 0.6)], in: folder)
        let hold = TranscriptionHold()
        let session = InterviewRig(
            fast: [question("Quelle est la première question ?"), question("Et ensuite ?")], hold: hold, holdsEngineDeadline: true)
        let file = folder.appendingPathComponent("rapport.md")
        let command = try parse(wavs + models + ["--output", file.path])
        let runtime = session.runtime()
        let running = Task { try await command.run(runtime: runtime) }
        defer { running.cancel() }

        // Le tour 1 est en cours de transcription (le moteur est lent) : sa limite et le délai du tour sans réaction sont armés.
        try #require(await settle { session.board.pendingSeconds.sorted() == [engineDeadline, reactionDelay].sorted() })
        #expect(reactionDelay > engineDeadline, "le délai d'un tour muet doit dépasser la limite de transcription du moteur")
        // Le temps passe jusqu'à la limite du moteur, sans l'atteindre : tout ce qui expire avant est libéré. Un délai plus court que
        // la limite (60 s contre 120 s) ferait ici partir le tour suivant, pendant que le tour 1 se transcrit encore.
        session.board.releaseAll(lessThan: engineDeadline)
        await quiesce()
        #expect(session.transcriber.seen.count == 1)
        hold.open()
        try await finished(running)

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("aucune réaction du moteur"), "le tour 1 a répondu, lentement")
        #expect(text.contains("- Tours poussés : 2 sur 2 ; textes rendus par la transcription : 2."))
        #expect(text.contains("Vous : tour 1\n\nSupervox : Quelle est la première question ?\n\nVous : tour 2\n\nSupervox : Et ensuite ?"))
    }

    @Test func aTranscriptionBeyondTheEngineDeadlineEndsTheInterviewBeforeTheNextTurnGoes() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6), .voice(turn: 1, seconds: 0.6)], in: folder)
        let session = InterviewRig(fast: [], hold: TranscriptionHold(), holdsEngineDeadline: true)   // la porte ne s'ouvre jamais
        let file = folder.appendingPathComponent("rapport.md")
        let command = try parse(wavs + models + ["--output", file.path])
        let runtime = session.runtime()
        let running = Task { try await command.run(runtime: runtime) }
        defer { running.cancel() }

        try #require(await settle { session.board.pendingSeconds.count == 2 })
        // Le temps passe : la première attente qui expire est celle du moteur, pas celle du tour sans réaction.
        let first = try #require(session.board.pendingSeconds.min())
        try #require(first == engineDeadline)
        session.board.release(seconds: first)
        await #expect(throws: ExitCode.self) { try await finished(running) }

        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("- Fin : panne d'un moteur (code transcriptionTimedOut)."))
        #expect(text.contains("- Tours poussés : 1 sur 2"))
        #expect(!text.contains("aucune réaction du moteur"))
        #expect(session.transcriber.seen.count == 1)
    }

    // MARK: Fin en échec (règle 4)

    @Test func aFailedInterviewWritesTheReportThenExitsNonZeroWithoutAnyValue() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6)], in: folder)
        let failure = TranscriberError.engine("panne vers \(endpointAddress) clé \(endpointKey)")
        let session = InterviewRig(fast: [], transcriptionFailure: failure)
        let file = folder.appendingPathComponent("rapport.md")
        let command = try parse(wavs + models + ["--output", file.path])

        await #expect(throws: ExitCode.self) { try await command.run(runtime: session.runtime()) }

        let text = try report(file)
        #expect(text.contains("- Fin : panne d'un moteur (code transcriptionFailed)."))
        #expect(session.strong.requests.isEmpty, "une panne ne demande pas de prompt")
        #expect(session.errors.contains("L'entretien n'a pas rendu de prompt"))
        for secret in [endpointAddress, endpointKey, "exemple.invalid"] {
            #expect(!text.contains(secret) && !session.output.contains(secret) && !session.errors.contains(secret))
        }
    }

    @Test func aStrongModelFailureIsReportedWithAFixedSentenceAndExitsNonZero() async throws {
        let folder = try interviewFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let wavs = try writeWavs([.voice(turn: 0, seconds: 0.6)], in: folder)
        let body = "corps d'erreur de exemple.invalid"
        let session = InterviewRig(
            fast: [question("Quelle est la première question ?")], strong: [.fail(EndpointError.http(status: 500, body: body))])
        let file = folder.appendingPathComponent("rapport.md")
        let command = try parse(wavs + models + ["--output", file.path])

        await #expect(throws: ExitCode.self) { try await command.run(runtime: session.runtime()) }

        let text = try report(file)
        #expect(text.contains("- Fin : le modèle fort n'a pas rédigé le prompt : "))
        #expect(text.contains("Vous : tour 1"), "la conversation reste")
        #expect(!text.contains(body) && !session.output.contains(body) && !session.errors.contains(body))
    }
}
