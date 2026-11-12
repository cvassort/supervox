import Foundation
import SupervoxCore
import Synchronization
import Testing
@testable import SupervoxBench

// Le moteur local, le modèle et la synthèse sont simulés par des fermetures ; le découpage en phrases, le déroulé
// des essais, leur classement, l'agrégation et le rapport sont les vrais.

// MARK: - Tests du plan

@Test func totalIsSumOfLinks() {
    // les durées sont des Double : comparer avec une tolérance de 1e-9, jamais avec ==
    #expect(abs(TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: 0.3).total! - 1.5) < 1e-9)
    #expect(TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: nil, synthesis: nil).total == nil)
}

@Test func singleQuestionWithoutTrailingSpaceIsTheFirstSentence() async throws {
    // cas mesuré pendant le cadrage : le modèle rapide répond par une seule question, sans rien après le « ? »
    let one = AsyncThrowingStream<ChatDelta, Error> { c in
        c.yield(.content("Quel est l'objectif du refacto")); c.yield(.content("ring ?")); c.finish()
    }
    #expect(try await firstSentence(of: one) == "Quel est l'objectif du refactoring ?")
    let reasoningOnly = AsyncThrowingStream<ChatDelta, Error> { c in c.yield(.reasoning("je réfléchis")); c.finish() }
    #expect(try await firstSentence(of: reasoningOnly) == nil)
    let two = AsyncThrowingStream<ChatDelta, Error> { c in c.yield(.content("D'accord. Et ensuite ?")); c.finish() }
    #expect(try await firstSentence(of: two) == "D'accord.")
}

@Test func noContentRunIsReportedNotAveraged() {
    let t = [TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: 0.3),
             TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.6, synthesis: 0.5),
             TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: nil, synthesis: nil)]
    let s = Reports.summarizeLatency(t, target: 2.0)
    #expect(s.runs == 3 && s.noContent == 1)
    #expect(abs(s.medianTotal! - 1.7) < 1e-9)   // médiane de 1,5 et 1,9 : l'essai sans contenu n'y entre pas
    // Amendé par le contrôleur (tour de correction 1) : 1 essai sans réponse sur 3 dépasse 10 %, verdict non établi.
    #expect(s.meetsTarget == nil)
}

/// Jusqu'à 10 % d'essais sans réponse (sans contenu ou en échec), le verdict est rendu ; au-delà, il n'est pas
/// établi. Les suspects de cache ne comptent pas dans cette part, mais dans le total des essais.
@Test func verdictIsWithheldBeyondTenPercentUnanswered() {
    let measured = Array(repeating: TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: 0.3), count: 9)
    let empty = TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: nil, synthesis: nil)
    let oneInTen = Reports.summarizeLatency(measured + [empty], target: 2.0)
    #expect(oneInTen.runs == 10 && oneInTen.unanswered == 1 && oneInTen.meetsTarget == true)
    let withFailure = Reports.summarizeLatency(measured + [empty], failed: 1, target: 2.0)
    #expect(withFailure.runs == 11 && withFailure.unanswered == 2 && withFailure.meetsTarget == nil)
    let twoFailures = Reports.summarizeLatency(measured, failed: 2, target: 2.0)
    #expect(twoFailures.meetsTarget == nil && twoFailures.measured == 9)
    let suspects = Reports.summarizeLatency(measured + [empty], suspect: 5, target: 2.0)
    #expect(suspects.runs == 15 && suspects.measured == 9 && suspects.meetsTarget == true)
}

@Test func targetIsJudgedOnP90AndUnknownWhenNothingMeasured() {
    let slow = (0..<10).map { TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: $0 < 8 ? 0.3 : 1.5) }
    #expect(Reports.summarizeLatency(slow, target: 2.0).meetsTarget == false)   // médiane 1,5 mais p90 à 2,7
    #expect(Reports.summarizeLatency([], target: 2.0).meetsTarget == nil)
}

// MARK: - Première phrase

/// Les maillons sont la médiane de chaque étape sur les essais complets, pas sur les essais sans contenu.
@Test func linkMediansIgnoreNoContentRuns() {
    let t = [TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: 0.3),
             TurnTiming(silence: 0.6, transcription: 0.4, firstSentence: 0.6, synthesis: 0.5),
             TurnTiming(silence: 0.6, transcription: 9.0, firstSentence: nil, synthesis: nil)]
    let s = Reports.summarizeLatency(t, target: 2.0)
    #expect(abs(s.medianByLink["transcription"]! - 0.3) < 1e-9)
    #expect(abs(s.medianByLink["première phrase"]! - 0.5) < 1e-9)
    #expect(abs(s.medianByLink["synthèse"]! - 0.4) < 1e-9)
    #expect(abs(s.medianByLink["silence"]! - 0.6) < 1e-9)
    #expect(abs(s.p90Total! - 2.04) < 1e-9)   // totaux 1,5 et 2,1 : 1,5 + 0,6 × 0,9
}

private actor Counter {
    private var n = 0
    func next() -> Int { n += 1; return n }
}

/// Signal posé par le flux simulé quand le consommateur est bloqué sur le morceau suivant.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func signal() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
}

/// Une tâche annulée voit la boucle du flux se terminer sans erreur (comme `chatStream`) : le début de phrase déjà
/// reçu ne doit pas sortir par `flush()` comme si c'était la réponse entière. Le flux simulé rend un morceau sans
/// fin de phrase, puis, au morceau suivant, prévient le test et attend l'annulation avant de finir normalement :
/// l'annulation tombe donc à coup sûr après la lecture du début de phrase.
@Test func cancelledStreamNeverYieldsATailSentence() async throws {
    let reached = Gate()
    let calls = Counter()
    let stream = AsyncThrowingStream<ChatDelta, Error>(unfolding: {
        if await calls.next() == 1 { return .content("Quel est l'objectif") }
        await reached.signal()
        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        return nil   // fin normale, sans erreur
    })
    let task = Task { try await firstSentence(of: stream) }
    await reached.wait()
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
}

// MARK: - Déroulé des essais

private let recording = LatencyRecording(id: "r1", clip: AudioClip(samples: [Float](repeating: 0.1, count: 1600),
                                                                   sampleRate: 16000), speechEnd: 0.1, duration: 0.1)

/// Ce que les essais ont envoyé au modèle et à la synthèse.
private final class Sent: Sendable {
    private let log = Mutex<(systems: [String], users: [String], speech: [String])>(([], [], []))
    var systems: [String] { log.withLock { $0.systems } }
    var users: [String] { log.withLock { $0.users } }
    var speechInputs: [String] { log.withLock { $0.speech } }
    func chat(_ messages: [ChatMessage]) {
        log.withLock {
            $0.systems.append(messages.first { $0.role == "system" }?.content ?? "")
            $0.users.append(messages.first { $0.role == "user" }?.content ?? "")
        }
    }
    func speech(_ input: String) { log.withLock { $0.speech.append(input) } }
}

private func stream(_ deltas: [ChatDelta], delay: Duration = .zero, error: (any Error)? = nil)
    -> AsyncThrowingStream<ChatDelta, Error> {
    AsyncThrowingStream { c in
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            for d in deltas { c.yield(d) }
            c.finish(throwing: error)
        }
    }
}

private let streamed: [ChatDelta] = [.content("Quel est"), .content(" l'objectif"), .content(" ?"), .content(" Et")]

private func trials(runs: Int, recordings: [LatencyRecording] = [recording],
                    transcript: @escaping (AudioClip) async throws -> String = { _ in "je veux refactorer" },
                    chat: @escaping (Int) -> AsyncThrowingStream<ChatDelta, Error>,
                    speak: @escaping (Int, String) async throws -> Data = { n, _ in Data("audio \(n)".utf8) },
                    nonce: @escaping () -> String = { UUID().uuidString },
                    registry: SpeechRequestRegistry? = nil,
                    sent: Sent = Sent()) async throws -> [LatencyTrial] {
    var chatCalls = 0
    var speechCalls = 0
    return try await runLatencyTrials(
        recordings: recordings, runs: runs, silence: 0.6,
        speechRegistry: try registry ?? SpeechRequestRegistry(file: nil, context: "t"), nonce: nonce,
        redact: { $0.replacingOccurrences(of: "gw.example.test", with: "<endpoint>") },
        transcribe: transcript,
        chat: { messages in
            chatCalls += 1
            sent.chat(messages)
            return chat(chatCalls)
        },
        speak: { input in
            speechCalls += 1
            sent.speech(input)
            return try await speak(speechCalls, input)
        })
}

/// Ce qui est chronométré : la transcription, l'attente de la première phrase (dès l'envoi), la synthèse ; le
/// silence est la constante donnée. Les durées simulées sont des bornes basses (l'horloge ne peut que les dépasser).
@Test func eachLinkTimesItsOwnStep() async throws {
    let out = try await trials(
        runs: 1,
        transcript: { _ in try await Task.sleep(for: .milliseconds(40)); return "je veux refactorer" },
        chat: { _ in stream(streamed, delay: .milliseconds(60)) },
        speak: { _, _ in try await Task.sleep(for: .milliseconds(30)); return Data([1]) })
    guard case .measured(let t) = out[0].outcome else { Issue.record("essai non mesuré : \(out[0].outcome)"); return }
    #expect(abs(t.silence - 0.6) < 1e-9)
    #expect(t.transcription >= 0.04 && t.transcription < 0.5)
    #expect(t.firstSentence! >= 0.06 && t.firstSentence! < 0.5)
    #expect(t.synthesis! >= 0.03 && t.synthesis! < 0.5)
    #expect(out[0].sentence == "Quel est l'objectif ?" && out[0].transcript == "je veux refactorer")
    #expect(out[0].contentChunks == 4)
}

/// La passerelle rend une requête identique depuis son cache : chaque requête de chat et de synthèse doit être
/// unique, y compris d'un essai à l'autre sur le même enregistrement et quand le modèle répète la même phrase.
/// La synthèse ne diffère que par des espaces en fin de texte : ce qui est dit ne change pas.
@Test func everyChatAndSpeechRequestIsUnique() async throws {
    let sent = Sent()
    _ = try await trials(runs: 5, chat: { _ in stream(streamed) }, sent: sent)
    let systems = sent.systems, users = sent.users, inputs = sent.speechInputs
    #expect(systems.count == 5 && Set(systems).count == 5)
    #expect(systems.allSatisfy { $0.hasPrefix(interviewerPrompt) })
    #expect(users == Array(repeating: "je veux refactorer", count: 5))
    #expect(inputs.count == 5 && Set(inputs).count == 5)
    #expect(inputs.allSatisfy { $0.trimmingCharacters(in: .whitespaces) == "Quel est l'objectif ?" })
}

/// Le registre des requêtes de synthèse est relu d'un lancement à l'autre dans le même dossier : deux lancements où le
/// modèle répète la même phrase n'envoient jamais deux fois la même requête. Le fichier ne garde que des empreintes.
@Test func speechRequestsStayUniqueAcrossLaunchesSharingAnOutputFolder() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sv-registre-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent(LatencyCommand.speechRegistryFile)
    let first = Sent(), second = Sent()
    _ = try await trials(runs: 3, chat: { _ in stream(streamed) },
                         registry: try SpeechRequestRegistry(file: file, context: "t|v"), sent: first)
    _ = try await trials(runs: 3, chat: { _ in stream(streamed) },
                         registry: try SpeechRequestRegistry(file: file, context: "t|v"), sent: second)
    let all = first.speechInputs + second.speechInputs
    #expect(all.count == 6 && Set(all).count == 6)
    let stored = try String(contentsOf: file, encoding: .utf8)
    #expect(stored.split(separator: "\n").count == 6 && !stored.contains("objectif"))
    // Une autre voix est une autre requête : le registre ne la bloque pas.
    let otherVoice = try SpeechRequestRegistry(file: file, context: "t|w")
    #expect(try otherVoice.uniqueInput(for: "Quel est l'objectif ?") == "Quel est l'objectif ? ")
}

/// À la borne du nombre d'espaces, la commande s'arrête au lieu de répéter une requête.
@Test func speechRegistryStopsAtTheSpaceBound() async throws {
    let registry = try SpeechRequestRegistry(file: nil, context: "t", maxSpaces: 2)
    await #expect(throws: LatencyError.speechVariantsExhausted(sentence: "Quel est l'objectif ?", maxSpaces: 2)) {
        _ = try await trials(runs: 3, chat: { _ in stream(streamed) }, registry: registry)
    }
}

/// Deux synthèses d'un même texte ont toujours rendu des octets différents : un audio identique octet pour octet à
/// celui d'un essai précédent a la forme d'une réponse sortie d'un cache, et l'essai est mis à part.
@Test func identicalSynthesisAudioIsFlaggedAsPossiblyCached() async throws {
    let out = try await trials(runs: 3, chat: { _ in stream(streamed) },
                               speak: { n, _ in Data(n == 2 ? "autre".utf8 : "même".utf8) })
    guard case .measured = out[0].outcome, case .measured = out[1].outcome,
          case .suspectCache(_, let reason) = out[2].outcome
    else { Issue.record("classement inattendu : \(out.map(\.outcome))"); return }
    #expect(reason.contains("essai 1"))
}

/// Un générateur d'aléa défaillant ne doit pas laisser partir deux requêtes identiques : la commande s'arrête.
@Test func duplicateChatRequestStopsTheCommand() async {
    await #expect(throws: LatencyError.self) {
        _ = try await trials(runs: 2, chat: { _ in stream(streamed) }, nonce: { "fixe" })
    }
}

/// Un flux vide (`.malformedResponse`) et un flux de réflexion seule sont des essais « sans contenu », comptés à part ;
/// les essais suivants continuent.
@Test func emptyAndReasoningOnlyStreamsAreNoContentRuns() async throws {
    let out = try await trials(runs: 3, chat: { n in
        switch n {
        case 1: stream([], error: EndpointError.malformedResponse)
        case 2: stream([.reasoning("je réfléchis")])
        default: stream(streamed)
        }
    })
    guard case .noContent(let a, _) = out[0].outcome, case .noContent(let b, _) = out[1].outcome,
          case .measured = out[2].outcome
    else { Issue.record("classement inattendu : \(out.map(\.outcome))"); return }
    #expect(a.firstSentence == nil && a.total == nil && b.firstSentence == nil && b.total == nil)
}

/// Une panne HTTP ou réseau sur un essai est rapportée pour cet essai, avec son étape et son message ; l'adresse de
/// l'endpoint en est retirée ; la commande continue.
@Test func failedStepIsReportedAndTheCommandContinues() async throws {
    let out = try await trials(
        runs: 3,
        chat: { n in n == 1 ? stream([], error: EndpointError.http(status: 503, body: "https://gw.example.test/v1 down"))
                            : stream(streamed) },
        speak: { n, _ in
            if n == 1 { throw EndpointError.transport("délai dépassé") }
            return Data([1])
        })
    guard case .failed(let stage1, let message1) = out[0].outcome, case .failed(let stage2, let message2) = out[1].outcome,
          case .measured = out[2].outcome
    else { Issue.record("classement inattendu : \(out.map(\.outcome))"); return }
    #expect(stage1 == .chat && message1.contains("503") && !message1.contains("gw.example.test"))
    #expect(stage2 == .synthesis && message2.contains("délai dépassé"))
}

/// Une transcription vide n'est pas envoyée au modèle : l'essai est un échec de transcription.
@Test func emptyTranscriptIsNotSentToTheModel() async throws {
    let sent = Sent()
    let out = try await trials(runs: 1, transcript: { _ in "  " }, chat: { _ in stream(streamed) }, sent: sent)
    guard case .failed(.transcription, _) = out[0].outcome else { Issue.record("\(out[0].outcome)"); return }
    #expect(sent.systems.isEmpty)
}

/// Forme d'une réponse sortie du cache, observée sur la passerelle : toute la réponse en un seul morceau. Un essai
/// dont la première phrase est complète dès le premier morceau de contenu est mis à part, jamais moyenné.
@Test func answerInOneChunkIsFlaggedAsPossiblyCached() async throws {
    let out = try await trials(runs: 3, chat: { n in
        switch n {
        case 1: stream([.content("Quel est l'objectif ?")])
        case 2: stream([.content("D'accord. Quel est l'objectif ?")])
        default: stream(streamed)
        }
    })
    guard case .suspectCache = out[0].outcome, case .suspectCache = out[1].outcome, case .measured = out[2].outcome
    else { Issue.record("classement inattendu : \(out.map(\.outcome))"); return }
}

/// `--runs` est le nombre total d'essais, répartis à tour de rôle sur les enregistrements.
@Test func runsAreSpreadRoundRobinOverRecordings() async throws {
    let second = LatencyRecording(id: "r2", clip: recording.clip, speechEnd: 0.1, duration: 0.1)
    let out = try await trials(runs: 5, recordings: [recording, second], chat: { _ in stream(streamed) })
    #expect(out.map(\.recording) == ["r1", "r2", "r1", "r2", "r1"])
    #expect(out.map(\.number) == [1, 2, 3, 4, 5])
}

// MARK: - Rapport

@Test func endpointRedactorRemovesAddressHostAndKey() {
    let redact = endpointRedactor(EndpointConfig(baseURL: URL(string: "https://gw.example.test/llm/")!, apiKey: "sk-secret"))
    let text = redact("POST https://gw.example.test/llm/v1/chat refusé pour gw.example.test avec sk-secret")
    #expect(!text.contains("gw.example.test") && !text.contains("sk-secret"))
    #expect(text.contains("<endpoint>"))
}

@Test func reportSeparatesFlaggedFailedAndNoContentRunsAndStatesLimits() async throws {
    let out = try await trials(runs: 4, chat: { n in
        switch n {
        case 1: stream([.content("Quel est l'objectif ?")])                                       // suspect
        case 2: stream([], error: EndpointError.http(status: 500, body: "https://gw.example.test panne"))   // échec
        case 3: stream([.reasoning("hmm")])                                                       // sans contenu
        default: stream(streamed)                                                                 // mesuré
        }
    })
    let settings = LatencySettings(engine: "parakeet", chatModel: "m", ttsModel: "t", voice: "v", ttsExtra: [:],
                                   silenceMs: 600, target: 2.0, maxTokens: 300, runs: 4, detector: "détecteur",
                                   detectorHop: 0.256)
    let md = Reports.latencyMarkdown(settings: settings, recordings: [recording], withoutSpeech: ["muet"], trials: out)
    #expect(md.contains("4 essai(s) = 1 mesuré(s) + 1 sans contenu + 1 en échec + 1 suspect(s) de cache"))
    #expect(md.contains("sur 1 essai(s) mesuré(s) sur 4"))
    #expect(md.contains("non établi") && md.contains("2 essai(s) sur 4 sans réponse"))   // 50 % sans réponse
    #expect(md.contains("Verdict indicatif"))
    #expect(md.contains("constante ajoutée") && md.contains("en bloc"))
    #expect(md.contains("muet"))
    // 600 ms comptées par tranches de 256 ms, à partir de la fin de la première tranche silencieuse : (1 + 3) × 0,256.
    #expect(md.contains("au plus tôt 1,02 s") && md.contains("soit 0,42 s de plus"))
    #expect(!md.contains("gw.example.test"))
}

private let settings600 = LatencySettings(engine: "parakeet", chatModel: "m", ttsModel: "t", voice: "v", ttsExtra: [:],
                                          silenceMs: 600, target: 2.0, maxTokens: 300, runs: 30, detector: "détecteur",
                                          detectorHop: 0.256)

private func measuredTrials(_ count: Int, synthesis: Double, suspects: Int = 0) -> [LatencyTrial] {
    let timing = TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: synthesis)
    return (1...count).map { LatencyTrial(number: $0, recording: "r", transcript: "t", sentence: "s", contentChunks: 3,
                                          outcome: .measured(timing)) }
        + (0..<suspects).map { LatencyTrial(number: count + 1 + $0, recording: "r", transcript: "t", sentence: "s",
                                            contentChunks: 1, outcome: .suspectCache(timing, reason: "un morceau")) }
}

/// Le verdict de tête compte la détection en direct : le silence constant (0,6 s) est remplacé par le plancher du
/// détecteur, (1 + ⌈0,6 / 0,256⌉) × 0,256 = 1,024 s. Le p90 brut suit, et la ligne dit quand les deux diffèrent.
@Test func headlineVerdictCountsLiveDetectionAndSaysWhenRawDiffers() {
    #expect(abs(settings600.liveSilence - 1.024) < 1e-9)
    // Total brut 1,5 s, en direct 1,924 s : tenu des deux côtés.
    let fast = Reports.latencyVerdict(settings: settings600, trials: measuredTrials(30, synthesis: 0.3))
    #expect(fast.contains("au lieu de 0,60 s) : objectif de 2,0 s tenu — p90 1,92 s sur 30 essai(s) mesuré(s) sur 30"))
    #expect(fast.contains("p90 brut, silence constant de 600 ms : objectif de 2,0 s tenu — p90 1,50 s"))
    #expect(!fast.contains("diffèrent") && !fast.contains("indicatif"))
    // Total brut 1,7 s, en direct 2,124 s : le brut tiendrait, le verdict de tête ne tient pas.
    let close = Reports.latencyVerdict(settings: settings600, trials: measuredTrials(30, synthesis: 0.5))
    #expect(close.contains("objectif de 2,0 s NON tenu — p90 2,12 s"))
    #expect(close.contains("Les deux verdicts diffèrent"))
}

/// Sous 29 essais mesurés, la ligne de verdict elle-même le dit indicatif ; au-delà de 10 % de suspects de cache,
/// une ligne le signale.
@Test func fewMeasuredRunsGiveAnIndicativeVerdictAndManySuspectsAreFlagged() {
    let few = Reports.latencyVerdict(settings: settings600, trials: measuredTrials(28, synthesis: 0.3, suspects: 4))
    let headline = few.split(separator: "\n").first { $0.hasPrefix("Verdict") }.map(String.init) ?? ""
    #expect(headline.contains("tenu") && headline.contains("Verdict indicatif : 28 essai(s) mesuré(s), moins de 29"))
    #expect(few.contains("4 essai(s) sur 32 suspect(s) de cache, plus de 10 %"))
}
