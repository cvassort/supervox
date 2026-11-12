import ArgumentParser
import Foundation
import SupervoxCore
import Testing
@testable import SupervoxBench

// Contrôles faits avant tout chargement de modèle et tout appel réseau. Le vrai `git` est appelé sur de vrais dépôts
// créés dans un dossier temporaire ; les commandes sont lancées pour de vrai (`run(environment:)`), avec des entrées
// qui feraient échouer autrement toute étape suivante : l'erreur levée prouve l'ordre des contrôles.

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sv-pre-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Dépôt git neuf dont le `.gitignore` ignore `bench-data/`.
private func repository() throws -> URL {
    let root = try temporaryFolder()
    let git = Process()
    git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    git.arguments = ["git", "init", "-q", root.path]
    try git.run()
    git.waitUntilExit()
    try #require(git.terminationStatus == 0, "git init a échoué")
    try "bench-data/\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
    return root
}

private let fakeEnvironment = ["SUPERVOX_BASE_URL": "https://gw.example.test/v1", "SUPERVOX_API_KEY": "cle-de-test"]

// MARK: - Dossier suivi par git

@Test func outputInsideARepositoryMustBeIgnoredByGit() throws {
    let root = try repository(); defer { try? FileManager.default.removeItem(at: root) }
    // Dossiers absents : le contrôle se fait avant leur création.
    #expect(throws: OutputError.self) { try OutputGuard.checkIgnoredByGit(root.appendingPathComponent("resultats"), content: "x") }
    #expect(throws: OutputError.self) { try OutputGuard.checkIgnoredByGit(root, content: "x") }
    try OutputGuard.checkIgnoredByGit(root.appendingPathComponent("bench-data/essai/1"), content: "x")
    // Le dossier ignoré lui-même, encore absent : le motif « bench-data/ » ne vaut que pour un dossier.
    try OutputGuard.checkIgnoredByGit(root.appendingPathComponent("bench-data"), content: "x")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("bench-data/la"), withIntermediateDirectories: true)
    try OutputGuard.checkIgnoredByGit(root.appendingPathComponent("bench-data/la"), content: "x")
    // Le message dit pourquoi : ce que contiennent les fichiers.
    do {
        try OutputGuard.checkIgnoredByGit(root.appendingPathComponent("resultats"), content: "ces rapports contiennent ce que tu as dit")
    } catch {
        #expect("\(error)".contains("ces rapports contiennent ce que tu as dit") && "\(error)".contains("ignoré"))
    }
}

@Test func outputOutsideAnyRepositoryOrWithoutGitIsWrittenNormally() throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    try OutputGuard.checkIgnoredByGit(folder.appendingPathComponent("a/b"), content: "x")
    let root = try repository(); defer { try? FileManager.default.removeItem(at: root) }
    // `git` introuvable : rien ne peut être vérifié, on écrit normalement.
    try OutputGuard.checkIgnoredByGit(root.appendingPathComponent("resultats"), content: "x",
                                      git: ["/chemin/absent/git"])
}

// MARK: - Rapports existants

@Test func existingReportIsRefusedWithoutOverwriteAndNamed() throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let report = folder.appendingPathComponent("transcription.md")
    try OutputGuard.checkNotExisting([report], overwrite: false)
    try "ancien".write(to: report, atomically: true, encoding: .utf8)
    #expect(throws: OutputError.reportExists(report.path)) { try OutputGuard.checkNotExisting([report], overwrite: false) }
    try OutputGuard.checkNotExisting([report], overwrite: true)
    #expect(OutputError.reportExists(report.path).description.contains(report.path))
    #expect(OutputError.reportExists(report.path).description.contains("--overwrite"))
}

/// Corpus et audio absents : sans le contrôle en tête, `transcribe` échouerait sur le corpus, bien plus tard.
@Test func transcribeRefusesAnExistingReportBeforeReadingAnything() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    try "ancien".write(to: folder.appendingPathComponent("transcription.json"), atomically: true, encoding: .utf8)
    let command = try TranscribeCommand.parse(["--corpus", "/absent.tsv", "--audio", "/absent", "--engines", "parakeet",
                                               "--out", folder.path])
    await #expect(throws: OutputError.reportExists(folder.appendingPathComponent("transcription.json").path)) {
        try await command.run(environment: [:])
    }
}

@Test func transcribeRefusesAnOutputFolderTrackedByGit() async throws {
    let root = try repository(); defer { try? FileManager.default.removeItem(at: root) }
    let command = try TranscribeCommand.parse(["--corpus", "/absent.tsv", "--audio", "/absent", "--engines", "parakeet",
                                               "--out", root.appendingPathComponent("resultats").path])
    await #expect(throws: OutputError.self) { try await command.run(environment: [:]) }
}

@Test func latencyRefusesAnExistingReportBeforeReadingAnything() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    try "ancien".write(to: folder.appendingPathComponent("latence.md"), atomically: true, encoding: .utf8)
    let command = try LatencyCommand.parse(["--audio", "/absent", "--engine", "parakeet", "--chat-model", "m",
                                            "--tts-model", "t", "--voice", "v", "--out", folder.path])
    await #expect(throws: OutputError.reportExists(folder.appendingPathComponent("latence.md").path)) {
        try await command.run(environment: fakeEnvironment)
    }
}

/// Le registre des requêtes de synthèse est cumulatif : sa présence n'est pas un rapport existant.
@Test func latencySpeechRegistryAloneDoesNotBlockANewLaunch() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    try "abc\n".write(to: folder.appendingPathComponent(LatencyCommand.speechRegistryFile), atomically: true, encoding: .utf8)
    let command = try LatencyCommand.parse(["--audio", "/absent", "--engine", "parakeet", "--chat-model", "m",
                                            "--tts-model", "t", "--voice", "v", "--out", folder.path])
    // L'erreur vient de l'étape suivante (dossier audio absent), pas du contrôle de sortie.
    await #expect { try await command.run(environment: fakeEnvironment) } throws: { !($0 is OutputError) }
}

@Test func latencyRefusesAnOutputFolderTrackedByGit() async throws {
    let root = try repository(); defer { try? FileManager.default.removeItem(at: root) }
    let command = try LatencyCommand.parse(["--audio", "/absent", "--engine", "parakeet", "--chat-model", "m",
                                            "--tts-model", "t", "--voice", "v", "--out", root.path])
    await #expect(throws: OutputError.self) { try await command.run(environment: fakeEnvironment) }
}

@Test func recordRefusesAnOutputFolderTrackedByGit() throws {
    let root = try repository(); defer { try? FileManager.default.removeItem(at: root) }
    var command = try RecordCommand.parse(["--corpus", "/absent.tsv", "--out", root.appendingPathComponent("prises").path])
    #expect(throws: OutputError.self) { try command.run() }
    command = try RecordCommand.parse(["--corpus", "/absent.tsv", "--out", root.appendingPathComponent("bench-data/prises").path])
    #expect { try command.run() } throws: { !($0 is OutputError) }   // ignoré : l'erreur suivante vient du corpus absent
}

// MARK: - Variables d'endpoint lues en premier

/// Avec le moteur endpoint, l'environnement est lu avant le corpus, l'audio et tout modèle.
@Test func transcribeReadsEndpointVariablesFirst() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let command = try TranscribeCommand.parse(["--corpus", "/absent.tsv", "--audio", "/absent", "--engines", "apple,endpoint",
                                               "--endpoint-model", "m", "--out", folder.path])
    await #expect(throws: EndpointError.missingVariable("SUPERVOX_BASE_URL")) { try await command.run(environment: [:]) }
}

// MARK: - Vocabulaire global partagé par transcribe et latency

@Test func globalVocabularyChecksThePromptBudgetOnlyWhenWhisperKitIsMeasured() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("vocabulaire.txt")
    try "# termes\nKubernetes\nKeycloak\n".write(to: file, atomically: true, encoding: .utf8)
    var counted: [[String]] = []
    await #expect(throws: TranscribeError.vocabularyTooLong(tokens: 500, limit: 111)) {
        _ = try await GlobalVocabulary.load(file.path, whisperKitModel: "large-v3", countTokens: { terms, _ in
            counted.append(terms); return 500
        }, say: { _ in })
    }
    #expect(counted == [["Kubernetes", "Keycloak"]])
    let terms = try await GlobalVocabulary.load(file.path, whisperKitModel: nil, countTokens: { _, _ in
        Issue.record("budget compté sans WhisperKit"); return 0
    }, say: { _ in })
    #expect(terms == ["Kubernetes", "Keycloak"])
    #expect(try await GlobalVocabulary.load(nil, whisperKitModel: "large-v3", countTokens: { _, _ in 500 }, say: { _ in }) == [])
    try "# rien\n\n".write(to: file, atomically: true, encoding: .utf8)
    await #expect(throws: TranscribeError.emptyVocabulary(file.path)) {
        _ = try await GlobalVocabulary.load(file.path, whisperKitModel: nil, countTokens: { _, _ in 0 }, say: { _ in })
    }
}

@Test func latencyRefusesAnEmptyVocabularyFileBeforeAnyLoad() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("vocabulaire.txt")
    try "\n".write(to: file, atomically: true, encoding: .utf8)
    let command = try LatencyCommand.parse(["--audio", "/absent", "--engine", "parakeet", "--chat-model", "m",
                                            "--tts-model", "t", "--voice", "v", "--vocabulary", file.path,
                                            "--out", folder.appendingPathComponent("sortie").path])
    await #expect(throws: TranscribeError.emptyVocabulary(file.path)) { try await command.run(environment: fakeEnvironment) }
}

/// Un moteur qui n'accepte pas de vocabulaire serait mesuré sans lui, sous une étiquette trompeuse : refusé.
@Test func latencyRefusesAVocabularyForAnEngineThatIgnoresIt() async throws {
    let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("vocabulaire.txt")
    try "Keycloak\n".write(to: file, atomically: true, encoding: .utf8)
    let command = try LatencyCommand.parse(["--audio", "/absent", "--engine", "apple", "--chat-model", "m",
                                            "--tts-model", "t", "--voice", "v", "--vocabulary", file.path,
                                            "--out", folder.appendingPathComponent("sortie").path])
    await #expect { try await command.run(environment: fakeEnvironment) } throws: { error in
        guard case LatencyError.invalidOption(let message) = error else { return false }
        return message.contains("apple") && message.contains("vocabulaire")
    }
}

/// Le vocabulaire de la mesure atteint le passage à vide et chaque transcription chronométrée ; l'étiquette dit la
/// configuration mesurée.
@Test func latencyTranscriptionIsWarmedUpAndRunWithTheVocabulary() async throws {
    let log = EventLog()
    let spy = VocabularySpy(name: "parakeet", acceptsVocabulary: true, log: log)
    let primed = try await prepareLatencyTranscription(spy, vocabulary: ["Keycloak"], language: "fr")
    #expect(primed.label == "parakeet+vocab")
    _ = try await primed.transcribe(AudioClip(samples: [0.1], sampleRate: 16000))
    #expect(await log.events == ["parakeet prepare", "parakeet warmUp [\"Keycloak\"]", "parakeet transcribe [\"Keycloak\"]"])

    let plain = try await prepareLatencyTranscription(VocabularySpy(name: "parakeet"), vocabulary: [], language: "fr")
    #expect(plain.label == "parakeet")
}

// MARK: - Masquage dans transcribe

/// Une erreur de l'endpoint qui porte son adresse ou son hôte (corps de passerelle, texte d'URLError) est masquée à
/// la source : rapport Markdown, JSON et tableau de la console.
@Test func transcribeFailuresAreRedactedInEveryOutput() async throws {
    struct Leaky: Transcriber {
        let name = "endpoint"
        func prepare() async throws {}
        func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
            throw EndpointError.http(status: 502, body: "upstream https://gw.example.test/v1 down (gw.example.test)")
        }
    }
    let redact = endpointRedactor(EndpointConfig(baseURL: URL(string: "https://gw.example.test/v1")!, apiKey: "cle"))
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: [])]
    let runs = await runBenchmark([Leaky()], corpus: corpus, audio: { AudioClip(samples: [0.1], sampleRate: Double($0)!) },
                                  hasSpeech: { _ in true }, vocabulary: [], redact: redact)
    let markdown = Reports.markdownReport(corpus: corpus, runs: runs, vocabulary: [])
    let encoder = JSONEncoder()
    let json = String(decoding: try encoder.encode(TranscriptionJSON(language: "fr", vocabulary: [], corpus: corpus, runs: runs)),
                      as: UTF8.self)
    let console = Reports.markdownTable(Reports.summaries(corpus: corpus, runs: runs))
    for output in [markdown, json, console] {
        #expect(output.contains("502") && !output.contains("gw.example.test"))
    }
}
