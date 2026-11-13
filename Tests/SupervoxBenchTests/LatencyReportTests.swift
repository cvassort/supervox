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
    // Amendé par le contrôleur : l'essai sans contenu est un raté ; 1 raté sur 3 jugés ne permet ni « tenu » ni
    // « non tenu » à 95 % (P(X ≤ 1) = 0,972, P(X ≥ 1) = 0,271 pour Binomiale(3 ; 0,1)) : non établi.
    #expect(s.missed == 1 && s.judged == 3)
    #expect(s.meetsTarget == nil)
}

/// Test du brief, amendé à la règle binomiale. Il manquait au tour 2 (supprimé par erreur au lieu d'être amendé) ;
/// rétabli au tour 3. Totaux : rapide 1,5 s, lent 2,7 s, cible 2,0 s.
@Test func targetIsJudgedOnTheShareOfMissedTurnsAndUnknownWhenNothingMeasured() {
    let fast = TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: 0.3)
    let slow = TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: 1.5)
    // 2 lents sur 10 : P(X ≤ 2) = 0,930 et P(X ≥ 2) = 0,264 pour Binomiale(10 ; 0,1) → non établi.
    let twoSlow = Reports.summarizeLatency(Array(repeating: slow, count: 2) + Array(repeating: fast, count: 8), target: 2.0)
    #expect(twoSlow.missed == 2 && twoSlow.judged == 10)
    #expect(twoSlow.meetsTarget == nil)
    // 8 lents sur 10 : P(X ≥ 8) = 3,7 × 10⁻⁷ → non tenu.
    let eightSlow = Reports.summarizeLatency(Array(repeating: slow, count: 8) + Array(repeating: fast, count: 2), target: 2.0)
    #expect(eightSlow.missed == 8 && eightSlow.judged == 10)
    #expect(eightSlow.meetsTarget == false)
    // Rien de mesuré : ni tenu ni non tenu.
    let nothing = Reports.summarizeLatency([], target: 2.0)
    #expect(nothing.meetsTarget == nil)
    #expect(nothing.judged == 0 && nothing.missed == 0)
    let text = Reports.latencyVerdict(settings: settings600, trials: [])
    #expect(text.contains("Verdict avec ce détecteur de voix et 600 ms de silence"))
    #expect(text.components(separatedBy: "objectif de 2,0 s non établi — aucun essai jugé.").count == 3)  // les deux verdicts
}

/// Série entièrement suspecte de cache : aucun essai n'est jugé, le rapport le dit et ne conclut pas.
@Test func allSuspectSeriesIsReportedAsNotJudged() {
    let timing = TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: 0.3)
    let suspects = (1...5).map { LatencyTrial(number: $0, recording: "r", transcript: "t", sentence: "s", contentChunks: 1,
                                              outcome: .suspectCache(timing, reason: "un morceau")) }
    let md = Reports.latencyMarkdown(settings: settings600, recordings: [recording], withoutSpeech: [],
                                     trials: suspects)
    #expect(md.contains("5 essai(s) = 0 mesuré(s) + 0 sans contenu + 0 en échec + 5 suspect(s) de cache"))
    #expect(md.components(separatedBy: "objectif de 2,0 s non établi — aucun essai jugé.").count == 3)
    #expect(!md.contains("s tenu") && !md.contains("NON tenu"))
    #expect(md.contains("Attention : 5 essai(s) sur 5 suspect(s) de cache"))
}

// MARK: - Test binomial

/// Référence indépendante de l'implémentation : sommes directes de C(n, k) pᵏ (1 − p)ⁿ⁻ᵏ, coefficient calculé par
/// produit (l'implémentation passe par les logarithmes des factorielles).
private func referenceTails(_ x: Int, _ n: Int) -> (atMost: Double, atLeast: Double) {
    func pmf(_ k: Int) -> Double {
        var c = 1.0
        for i in 0..<k { c = c * Double(n - i) / Double(i + 1) }
        return c * pow(0.1, Double(k)) * pow(0.9, Double(n - k))
    }
    let atMost = (0...x).reduce(0.0) { $0 + pmf($1) }
    let atLeast = (x...n).reduce(0.0) { $0 + pmf($1) }
    return (atMost, atLeast)
}

private func referenceVerdict(_ x: Int, _ n: Int) -> Bool? {
    let t = referenceTails(x, n)
    return t.atMost <= 0.05 ? true : (t.atLeast <= 0.05 ? false : nil)
}

/// Valeurs calculées à part (Python, `math.comb`) : 0,9²⁹ = 0,0471 → tenu ; 0,9²⁸ = 0,0523 → non établi ;
/// n = 40 : 0,9⁴⁰ = 0,0148 → tenu, P(X ≤ 1) = 0,0805 → non établi ; P(X ≥ 8) = 0,0419 → non tenu,
/// P(X ≥ 7) > 0,05 → non établi.
@Test func binomialVerdictMatchesExactValues() {
    #expect(Reports.binomialVerdict(missed: 0, judged: 29) == true)
    #expect(Reports.binomialVerdict(missed: 0, judged: 28) == nil)
    #expect(Reports.binomialVerdict(missed: 0, judged: 40) == true)
    #expect(Reports.binomialVerdict(missed: 1, judged: 40) == nil)
    #expect(Reports.binomialVerdict(missed: 8, judged: 40) == false)
    #expect(Reports.binomialVerdict(missed: 7, judged: 40) == nil)
    #expect(Reports.binomialVerdict(missed: 0, judged: 0) == nil)
    #expect(Reports.verdictThresholds(judged: 40).maxMissedForMet == 0)
    #expect(Reports.verdictThresholds(judged: 40).minMissedForNotMet == 8)
    #expect(Reports.verdictThresholds(judged: 28).maxMissedForMet == nil)
    #expect(Reports.minJudgedForMet == 29)
    #expect(abs(referenceTails(0, 29).atMost - pow(0.9, 29)) < 1e-12)   // la référence elle-même
}

/// L'implémentation suit la référence pour tout x, sur plusieurs tailles de série.
@Test func binomialVerdictAgreesWithDirectSumsForEveryCount() {
    for n in [1, 3, 10, 28, 29, 30, 40, 100] {
        for x in 0...n {
            #expect(Reports.binomialVerdict(missed: x, judged: n) == referenceVerdict(x, n), "n = \(n), x = \(x)")
        }
    }
}

/// Un essai sans contenu et un essai en échec comptent chacun comme un raté ; un suspect de cache n'est ni jugé ni
/// raté.
@Test func unansweredRunsAreMissesAndSuspectsAreNotJudged() {
    let fast = TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: 0.3)
    let slow = TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: 1.5)
    let empty = TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: nil, synthesis: nil)
    let s = Reports.summarizeLatency(Array(repeating: fast, count: 36) + [slow, empty], failed: 1, suspect: 5, target: 2.0)
    // 38 durées (36 rapides, 1 lente, 1 sans contenu) + 1 échec = 39 jugés ; + 5 suspects = 44 lancés.
    #expect(s.runs == 44 && s.judged == 39 && s.missed == 3 && s.measured == 37)
    #expect(s.meetsTarget == referenceVerdict(3, 39))
    let allFast = Reports.summarizeLatency(Array(repeating: fast, count: 29), suspect: 10, target: 2.0)
    #expect(allFast.judged == 29 && allFast.missed == 0 && allFast.meetsTarget == true)
    let oneEmpty = Reports.summarizeLatency(Array(repeating: fast, count: 28) + [empty], target: 2.0)
    #expect(oneEmpty.missed == 1 && oneEmpty.meetsTarget == nil)
    let oneFailed = Reports.summarizeLatency(Array(repeating: fast, count: 28), failed: 1, target: 2.0)
    #expect(oneFailed.missed == 1 && oneFailed.judged == 29 && oneFailed.meetsTarget == nil)
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
    try await launch(runs: runs, recordings: recordings, transcript: transcript, chat: chat, speak: speak, nonce: nonce,
                     registry: registry, sent: sent).trials
}

private func launch(runs: Int, recordings: [LatencyRecording] = [recording],
                    transcript: @escaping (AudioClip) async throws -> String = { _ in "je veux refactorer" },
                    chat: @escaping (Int) -> AsyncThrowingStream<ChatDelta, Error>,
                    speak: @escaping (Int, String) async throws -> Data = { n, _ in Data("audio \(n)".utf8) },
                    nonce: @escaping () -> String = { UUID().uuidString },
                    registry: SpeechRequestRegistry? = nil,
                    sent: Sent = Sent()) async throws -> LatencyTrials {
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
            return SpeechAudio(data: try await speak(speechCalls, input))
        })
}

/// Ce qui est chronométré : la transcription, l'attente de la première phrase (dès l'envoi), la synthèse ; le
/// silence est la constante donnée. Les durées simulées sont des bornes basses (l'horloge ne peut que les dépasser).
/// Aucune borne haute absolue : sur une machine chargée, une attente de 40 ms peut durer plus d'une demi-seconde.
/// À la place, un invariant : les trois maillons s'enchaînent, donc leur somme ne peut pas dépasser la durée
/// réelle de tout l'essai. Un maillon qui chronométrerait aussi l'étape voisine la compterait deux fois.
@Test func eachLinkTimesItsOwnStep() async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let out = try await trials(
        runs: 1,
        transcript: { _ in try await Task.sleep(for: .milliseconds(100)); return "je veux refactorer" },
        chat: { _ in stream(streamed, delay: .milliseconds(150)) },
        speak: { _, _ in try await Task.sleep(for: .milliseconds(80)); return Data([1]) })
    let elapsed = clock.now - start
    let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    guard case .measured(let t) = out[0].outcome else { Issue.record("essai non mesuré : \(out[0].outcome)"); return }
    #expect(abs(t.silence - 0.6) < 1e-9)
    #expect(t.transcription >= 0.1)
    #expect(t.firstSentence! >= 0.15)
    #expect(t.synthesis! >= 0.08)
    #expect(t.transcription + t.firstSentence! + t.synthesis! <= wall)
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

/// À la borne du nombre d'espaces, le lancement s'arrête au lieu de répéter une requête, et garde les essais déjà
/// faits ; le rapport dit l'arrêt et sa cause.
@Test func speechRegistryStopsAtTheSpaceBoundAndKeepsMeasuredRuns() async throws {
    let registry = try SpeechRequestRegistry(file: nil, context: "t", maxSpaces: 2)
    let result = try await launch(runs: 4, chat: { _ in stream(streamed) }, registry: registry)
    #expect(result.trials.count == 2)
    #expect(result.stopReason?.contains("essai 3") == true && result.stopReason?.contains("1 à 2 espaces") == true)
    let md = Reports.latencyMarkdown(settings: settings600, recordings: [recording], withoutSpeech: [],
                                     trials: result.trials, stopReason: result.stopReason)
    #expect(md.contains("**Lancement arrêté avant la fin** : 2 essai(s) faits sur 30 prévus") && md.contains("1 à 2 espaces"))
}

/// Un registre dont la dernière ligne n'a pas de fin de ligne : la nouvelle empreinte va sur sa propre ligne.
@Test func registryAppendsOnItsOwnLineAfterAnUnterminatedFile() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("sv-registre-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("ancienne-empreinte".utf8).write(to: file)
    let registry = try SpeechRequestRegistry(file: file, context: "t")
    _ = try registry.uniqueInput(for: "Bonjour.")
    let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 3 && lines[0] == "ancienne-empreinte" && lines[1].count == 64 && lines[2].isEmpty)
    // Relu, le registre reconnaît les deux empreintes : la même requête n'est pas renvoyée.
    #expect(try SpeechRequestRegistry(file: file, context: "t").uniqueInput(for: "Bonjour.") == "Bonjour.  ")
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
@Test func duplicateChatRequestStopsTheCommand() async throws {
    let result = try await launch(runs: 3, chat: { _ in stream(streamed) }, nonce: { "fixe" })
    #expect(result.trials.count == 1 && result.stopReason?.contains("essai 2") == true)
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
    // Jugés : 3 (le suspect est écarté) ; ratés : l'échec et le sans contenu. P(X ≥ 2) = 0,028 pour
    // Binomiale(3 ; 0,1) : on peut affirmer que plus de 10 % des tours ratent, non tenu.
    #expect(md.contains("NON tenu — 2 essai(s) au-dessus de la cible ou sans réponse sur 3 jugé(s)"))
    #expect(md.contains("2 essai(s) sans réponse (1 sans contenu, 1 en échec), comptés comme ratés dans le verdict"))
    #expect(!md.contains("indicatif") && !md.contains("0,74") && !md.contains("deux séries"))
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
/// détecteur, (1 + ⌈0,6 / 0,256⌉) × 0,256 = 1,024 s. Le verdict brut suit, et la ligne dit quand les deux diffèrent.
@Test func headlineVerdictCountsLiveDetectionAndSaysWhenRawDiffers() {
    #expect(abs(settings600.liveSilence - 1.024) < 1e-9)
    // Total brut 1,5 s, en direct 1,924 s : 0 raté sur 30, tenu des deux côtés (0,9³⁰ = 0,042).
    let fast = Reports.latencyVerdict(settings: settings600, trials: measuredTrials(30, synthesis: 0.3))
    #expect(fast.contains("au lieu de 0,60 s) : objectif de 2,0 s tenu — 0 essai(s) au-dessus de la cible ou sans réponse sur 30 jugé(s)"))
    #expect(fast.contains("Verdict de la chaîne mesurée (transcription, modèle, synthèse) avec un silence constant de 600 ms : objectif de 2,0 s tenu"))
    #expect(!fast.contains("diffèrent") && !fast.contains("comptés comme ratés"))
    #expect(fast.contains("détection en direct comptée, médiane 1,92 s, 90e centile 1,92 s ; silence constant, médiane 1,50 s"))
    // Total brut 1,7 s, en direct 2,124 s : brut tenu, en direct 30 ratés sur 30, non tenu.
    let close = Reports.latencyVerdict(settings: settings600, trials: measuredTrials(30, synthesis: 0.5))
    #expect(close.contains("objectif de 2,0 s NON tenu — 30 essai(s) au-dessus de la cible ou sans réponse sur 30 jugé(s)"))
    #expect(close.contains("Les deux verdicts diffèrent"))
    // Non établi : la ligne dit combien de ratés permettraient de conclure, pour ce n.
    let short = Reports.latencyVerdict(settings: settings600, trials: measuredTrials(40, synthesis: 0.3)
        + measuredTrials(3, synthesis: 0.5).map { LatencyTrial(number: $0.number + 40, recording: "r", transcript: "t",
                                                               sentence: "s", contentChunks: 3, outcome: $0.outcome) })
    #expect(short.contains("non établi — 3 essai(s) au-dessus de la cible ou sans réponse sur 43 jugé(s)"))
    // 10 essais sans raté : P(X ≤ 0) = 0,9¹⁰ = 0,349, et « tenu » est impossible à cette taille.
    let ten = Reports.latencyVerdict(settings: settings600, trials: measuredTrials(10, synthesis: 0.3))
    #expect(ten.contains("non établi — 0 essai(s) au-dessus de la cible ou sans réponse sur 10 jugé(s)"))
    #expect(ten.contains("« tenu » est impossible, même sans raté (il faut au moins 29 essais jugés)"))
    // Seuils pour n = 43, calculés à part (Python, fractions exactes) et non lus dans l'implémentation :
    // P(X ≤ 0) = 0,0108 et P(X ≤ 1) = 0,0623 → « tenu » au plus 0 raté ; P(X ≥ 9) = 0,0244 et P(X ≥ 8) = 0,0607
    // → « non tenu » à partir de 9.
    #expect(short.contains("avec 43 essai(s) jugé(s), « tenu » exige au plus 0 raté(s), « non tenu » au moins 9 raté(s)."))
}

/// Le plancher en direct ne fait qu'allonger les totaux : le verdict de tête n'est jamais plus favorable que le brut.
@Test func headlineVerdictIsNeverMoreFavourableThanRaw() {
    func rank(_ v: Bool?) -> Int { v == true ? 2 : (v == nil ? 1 : 0) }
    for synthesis in stride(from: 0.1, through: 1.3, by: 0.1) {
        for slowCount in [0, 1, 3, 8] {
            let timings = (0..<40).map { TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4,
                                                    synthesis: $0 < slowCount ? synthesis + 0.5 : synthesis) }
            let raw = Reports.summarizeLatency(timings, target: 2.0)
            let live = Reports.summarizeLatency(timings.map { $0.withSilence(settings600.liveSilence) }, target: 2.0)
            #expect(rank(live.meetsTarget) <= rank(raw.meetsTarget), "synthèse \(synthesis), lents \(slowCount)")
        }
    }
}

/// Au-delà de 10 % de suspects de cache, une ligne le signale ; ils ne sont pas jugés.
@Test func manySuspectsAreFlaggedAndNotJudged() {
    let text = Reports.latencyVerdict(settings: settings600, trials: measuredTrials(28, synthesis: 0.3, suspects: 4))
    #expect(text.contains("4 essai(s) sur 32 suspect(s) de cache, plus de 10 %"))
    #expect(text.contains("sur 28 jugé(s)"))
}

/// Le rapport nomme la configuration de transcription réellement mesurée, vocabulaire compris.
@Test func reportNamesTheMeasuredTranscriptionConfiguration() {
    let primed = LatencySettings(engine: "parakeet+vocab", vocabulary: ["Keycloak", "Celery"], chatModel: "m", ttsModel: "t",
                                 voice: "v", ttsExtra: [:], silenceMs: 600, target: 2.0, maxTokens: 300, runs: 1,
                                 detector: "détecteur", detectorHop: 0.256)
    let md = Reports.latencyMarkdown(settings: primed, recordings: [recording], withoutSpeech: [], trials: [])
    #expect(md.contains("`parakeet+vocab` (vocabulaire global de 2 terme(s)") && md.contains("Keycloak, Celery"))
    let plain = Reports.latencyMarkdown(settings: settings600, recordings: [recording], withoutSpeech: [], trials: [])
    #expect(plain.contains("`parakeet` (sans vocabulaire)"))
}

// MARK: - Écriture au fil de l'eau

/// Chaque essai, quelle que soit son issue (mesuré, en échec, sans contenu), est rendu dès qu'il est classé : la
/// commande réécrit le rapport après chaque essai, et un Ctrl-C ne perd que l'essai en cours.
@Test func everyTrialIsHandedOverAsSoonAsItIsClassified() async throws {
    var counts: [Int] = []
    var chatCalls = 0
    var transcriptions = 0
    _ = try await runLatencyTrials(
        recordings: [recording], runs: 5, silence: 0.6, speechRegistry: try SpeechRequestRegistry(file: nil, context: "t"),
        nonce: { UUID().uuidString }, redact: { $0 },
        transcribe: { _ in
            transcriptions += 1
            if transcriptions == 1 { throw TranscriberError.engine("moteur en panne") }   // échec de transcription
            return "je veux refactorer"
        },
        chat: { _ in
            chatCalls += 1
            switch chatCalls {
            case 1: return stream([], error: EndpointError.transport("délai"))   // échec
            case 2: return stream([.reasoning("hmm")])                          // sans contenu
            default: return stream(streamed)                                    // mesurés
            }
        },
        speak: { _ in SpeechAudio(data: Data(UUID().uuidString.utf8)) },
        afterTrial: { counts.append($0.count) })
    #expect(counts == [1, 2, 3, 4, 5])
}

@Test func partialLatencyReportIsMarkedAsSuch() {
    let trials = measuredTrials(3, synthesis: 0.3)
    let partial = Reports.latencyMarkdown(settings: settings600, recordings: [recording], withoutSpeech: [], trials: trials,
                                          progress: ReportProgress(done: 3, planned: 30))
    let head = partial.components(separatedBy: "## Verdict").first ?? ""
    #expect(head.contains("**Rapport partiel**") && head.contains("3 essai(s) sur 30"))
    #expect(!Reports.latencyMarkdown(settings: settings600, recordings: [recording], withoutSpeech: [], trials: trials)
        .contains("partiel"))
}

/// Le délai de requête est dit dans ce qui est mesuré.
@Test func latencyReportStatesTheRequestTimeout() {
    var settings = settings600
    settings.requestTimeout = 12
    let md = Reports.latencyMarkdown(settings: settings, recordings: [recording], withoutSpeech: [], trials: [])
    #expect(md.contains("12 s sans aucune donnée reçue"))
}

// MARK: - Connexion de la synthèse

/// La connexion de chaque appel de synthèse est relevée (protocole, réutilisation) et rapportée essai par essai et en
/// une ligne ; le rapport ne prétend plus que la connexion est réutilisée sans l'avoir observé.
@Test func synthesisConnectionIsReportedPerTrialAndSummarised() async throws {
    let observed: [ConnectionInfo?] = [ConnectionInfo(networkProtocol: "h2", reused: false),
                                       ConnectionInfo(networkProtocol: "h2", reused: true), nil]
    var calls = 0
    let result = try await runLatencyTrials(
        recordings: [recording], runs: 3, silence: 0.6, speechRegistry: try SpeechRequestRegistry(file: nil, context: "t"),
        nonce: { UUID().uuidString }, redact: { $0 }, transcribe: { _ in "je veux refactorer" },
        chat: { _ in stream(streamed) },
        speak: { _ in calls += 1; return SpeechAudio(data: Data("audio \(calls)".utf8), connection: observed[calls - 1]) })
    #expect(result.trials.map(\.connection) == observed)
    let md = Reports.latencyMarkdown(settings: settings600, recordings: [recording], withoutSpeech: [], trials: result.trials)
    let detail = md.components(separatedBy: "## Détail des essais").last ?? ""
    #expect(detail.contains("| h2, nouvelle |") && detail.contains("| h2, réutilisée |") && detail.contains("| non relevée |"))
    #expect(md.contains("Connexion de la synthèse, relevée à chaque essai (URLSessionTaskMetrics) : h2, 1 nouvelle(s) et 1 réutilisée(s) ; non relevée sur 1 essai(s)"))
    #expect(!md.contains("les suivants la réutilisent"))
}

// MARK: - Libellé des deux verdicts

/// Le verdict de tête dit qu'il dépend du détecteur et de son silence ; le second porte sur la chaîne mesurée avec un
/// silence constant. L'ordre ne change pas.
@Test func verdictsAreLabelledForWhatTheyMeasure() {
    let text = Reports.latencyVerdict(settings: settings600, trials: measuredTrials(30, synthesis: 0.3))
    let head = text.range(of: "Verdict avec ce détecteur de voix et 600 ms de silence")
    let raw = text.range(of: "Verdict de la chaîne mesurée (transcription, modèle, synthèse) avec un silence constant de 600 ms")
    #expect(head != nil && raw != nil && head!.lowerBound < raw!.lowerBound)
    #expect(text.contains("Un autre détecteur de voix, ou un autre découpage du silence par le détecteur, déplacerait surtout le premier verdict."))
    #expect(text.contains("il dépend encore du détecteur par l'endroit où chaque clip est coupé"))
    #expect(!text.contains("pas le second"))
}

// MARK: - Enregistrements : clip non coupé, fichiers illisibles

private func wavFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sv-lat-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Un fichier .wav illisible (stéréo, ou pas un WAV) est ignoré avec un avertissement qui le nomme ; les autres sont
/// mesurés. Une voix encore ouverte à la fin du clip (passage fermé par la bibliothèque à la fin du clip) est signalée,
/// et le clip n'est pas coupé.
@Test func recordingsAreLoadedSkippingUnreadableFilesAndFlaggingUncutClips() async throws {
    let folder = try wavFolder(); defer { try? FileManager.default.removeItem(at: folder) }
    let oneSecond = AudioClip(samples: [Float](repeating: 0.1, count: 16000), sampleRate: 16000)
    try WavFile.write(oneSecond, to: folder.appendingPathComponent("a.wav"))
    try WavFile.write(oneSecond, to: folder.appendingPathComponent("b.wav"))
    try Data("pas un wav".utf8).write(to: folder.appendingPathComponent("c.wav"))
    var stereo = try Data(contentsOf: folder.appendingPathComponent("a.wav"))
    stereo[22] = 2   // champ « canaux » de l'en-tête fmt
    try stereo.write(to: folder.appendingPathComponent("d.wav"))

    // Détecteur simulé, appelé dans l'ordre des noms sur les seuls fichiers lisibles : « a » a sa voix jusqu'à 0,5 s,
    // « b » jusqu'à la fin du clip (ce que rend la bibliothèque pour un passage encore ouvert).
    var ends = [0.5, 1.0]
    var warnings: [String] = []
    let loaded = try await LatencyAudio.load(folder, segments: { _ in [SpeechSegment(start: 0, end: ends.removeFirst())] },
                                             warn: { warnings.append($0) })
    #expect(loaded.recordings.map(\.id) == ["a", "b"] && loaded.withoutSpeech.isEmpty)
    #expect(loaded.recordings[0].openAtClipEnd == false && loaded.recordings[0].clip.samples.count == 8000)
    #expect(loaded.recordings[1].openAtClipEnd == true && loaded.recordings[1].clip.samples.count == 16000)
    #expect(loaded.unreadable.count == 2 && loaded.unreadable[0].hasPrefix("c.wav") && loaded.unreadable[1].hasPrefix("d.wav"))
    #expect(loaded.unreadable[1].contains("canaux"))
    #expect(warnings.count == 2 && warnings[0].contains("c.wav") && warnings[1].contains("d.wav"))

    let silent = try await LatencyAudio.load(folder, segments: { _ in [] }, warn: { _ in })
    #expect(silent.recordings.isEmpty && silent.withoutSpeech == ["a", "b"])

    let md = Reports.latencyMarkdown(settings: settings600, recordings: loaded.recordings, withoutSpeech: [],
                                     unreadable: loaded.unreadable, trials: [])
    #expect(md.contains("| b | 1,00 | 1,00 | voix encore ouverte à la fin du clip : clip non coupé |"))
    #expect(md.contains("| a | 1,00 | 0,50 |  |"))
    #expect(md.contains("Ignorés, illisibles : `c.wav : ") && md.contains("`d.wav : "))
}

@Test func latencyReportStatesTheLaunchDateModelsAndCapture() {
    let launch = LaunchInfo(date: Date(timeIntervalSince1970: 1_800_000_000), models: ["chat `m`", "synthèse `t`"],
                            capture: "Capture : micro de test.")
    let md = Reports.latencyMarkdown(settings: settings600, recordings: [recording], withoutSpeech: [], trials: [],
                                     launch: launch)
    #expect(md.contains("## Lancement") && md.contains("2027-01-15T") && md.contains("chat `m`") && md.contains("Capture : micro de test."))
}
