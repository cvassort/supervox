import ArgumentParser
import CryptoKit
import Foundation
import SupervoxCore
import SupervoxEngines

// MARK: - Consigne

/// Consigne d'intervieweur (design, section 6.2), envoyée comme message système ; le message de l'utilisateur est la
/// transcription.
let interviewerPrompt = "Tu mènes un entretien oral pour aider quelqu'un à préciser une demande destinée à un agent "
    + "de programmation. Pose une seule question à la fois. Fais des phrases courtes, faites pour être dites à voix "
    + "haute. Pas de liste, pas de mise en forme, pas de préambule."

/// Message système d'un essai : la consigne, suivie d'une référence propre à l'essai. La passerelle rend une requête
/// identique depuis son cache (toute la réponse d'un bloc, bien plus vite) : sans cette référence, deux essais sur le
/// même enregistrement enverraient la même requête.
func interviewerSystemMessage(nonce: String) -> String {
    interviewerPrompt + "\n\n(Référence technique de la requête, à ignorer : \(nonce).)"
}

// MARK: - Première phrase

/// La première phrase d'une réponse et le nombre de morceaux de contenu reçus jusqu'à elle.
struct FirstSentence: Equatable {
    let text: String
    let contentChunks: Int
}

/// Lit le flux jusqu'à la première phrase complète rendue par `SentenceSplitter`, puis arrête la lecture (ce qui annule
/// la requête). Si le flux se termine sans qu'aucune phrase ait été coupée, le texte restant (`flush()`) est la
/// première phrase. `nil` seulement si le flux n'a rendu aucun contenu. Les morceaux de réflexion sont ignorés.
///
/// Une tâche annulée voit la boucle se terminer sans erreur : le texte en attente n'est alors pas une phrase
/// complète, et l'annulation est levée au lieu de le rendre.
func readFirstSentence(_ stream: AsyncThrowingStream<ChatDelta, Error>) async throws -> FirstSentence? {
    var splitter = SentenceSplitter()
    var chunks = 0
    for try await delta in stream {
        guard case .content(let text) = delta else { continue }
        chunks += 1
        if let sentence = splitter.feed(text).first { return FirstSentence(text: sentence, contentChunks: chunks) }
    }
    if Task.isCancelled { throw CancellationError() }
    return splitter.flush().map { FirstSentence(text: $0, contentChunks: chunks) }
}

func firstSentence(of stream: AsyncThrowingStream<ChatDelta, Error>) async throws -> String? {
    try await readFirstSentence(stream)?.text
}

// MARK: - Essais

/// Un enregistrement prêt à mesurer : le clip coupé à la fin de voix détectée.
struct LatencyRecording {
    let id: String
    /// Clip à 16 kHz, coupé à `speechEnd`.
    let clip: AudioClip
    /// Fin de voix détectée, en secondes depuis le début de l'enregistrement.
    let speechEnd: Double
    /// Durée de l'enregistrement entier.
    let duration: Double
}

enum TrialStage: String, Equatable {
    case transcription = "transcription"
    case chat = "première phrase"
    case synthesis = "synthèse"
}

enum TrialOutcome: Equatable {
    /// Les trois étapes ont abouti.
    case measured(TurnTiming)
    /// Le modèle n'a rendu aucun texte de réponse (flux vide, ou réflexion seule) : compté, jamais moyenné.
    case noContent(TurnTiming, reason: String)
    /// Forme d'une réponse sortie d'un cache : première phrase entière dans le premier morceau de contenu, ou audio
    /// identique octet pour octet à celui d'un essai précédent. Rapporté à part, jamais moyenné.
    case suspectCache(TurnTiming, reason: String)
    /// Une étape a levé une erreur (HTTP, réseau, moteur) ; message sans adresse d'endpoint ni clé.
    case failed(stage: TrialStage, message: String)
}

struct LatencyTrial: Equatable {
    /// Numéro de l'essai, à partir de 1.
    let number: Int
    let recording: String
    let transcript: String?
    let sentence: String?
    let contentChunks: Int?
    let outcome: TrialOutcome
}

enum LatencyError: Error, Equatable, CustomStringConvertible {
    case duplicateRequest(String)
    case speechVariantsExhausted(sentence: String, maxSpaces: Int)
    case noRecordings(String)
    case noSpeech
    case invalidOption(String)
    case stopped(String)

    var description: String {
        switch self {
        case .duplicateRequest(let what):
            "requête \(what) identique à une requête déjà envoyée : la passerelle pourrait la rendre depuis son cache"
        case .speechVariantsExhausted(let sentence, let maxSpaces):
            "le texte « \(sentence) » a déjà été envoyé à la synthèse avec 1 à \(maxSpaces) espaces finaux (registre du "
                + "dossier de sortie) : arrêt plutôt que de répéter une requête que la passerelle pourrait rendre depuis "
                + "son cache. Effacer le registre réautoriserait ces requêtes."
        case .noRecordings(let path): "aucun fichier .wav dans \(path)"
        case .noSpeech: "aucun enregistrement ne contient de voix détectée : rien à mesurer"
        case .invalidOption(let message): message
        case .stopped(let reason): "lancement arrêté avant la fin (rapport écrit avec les essais déjà faits) : \(reason)"
        }
    }
}

/// Registre des requêtes de synthèse déjà envoyées, pour qu'aucune ne soit répétée, y compris d'un lancement à
/// l'autre : la passerelle de l'endpoint rend une requête identique depuis son cache. Le registre ne garde que des
/// empreintes SHA-256 (jamais le texte), une par ligne, dans un fichier relu à l'ouverture et complété avant chaque
/// envoi. L'empreinte couvre `context` (modèle, voix, format, paramètres) et le texte envoyé.
final class SpeechRequestRegistry {
    /// Nombre maximal d'espaces finaux. Sondé sur l'endpoint, trois textes : 0 à 3 espaces, puis 0 et 40, puis 0,
    /// 120 et 250 ; pour chaque texte, l'audio rendu a eu la même taille en octets quel que soit le nombre d'espaces
    /// (pas les mêmes octets : deux synthèses d'un même texte diffèrent toujours). Même taille veut dire même durée
    /// pour un WAV de même format ; ce qui est dit n'a pas été réécouté.
    static let defaultMaxSpaces = 250

    let file: URL?
    let maxSpaces: Int
    private let context: String
    private var seen: Set<String>

    /// `file` nil : registre en mémoire seulement.
    init(file: URL?, context: String, maxSpaces: Int = SpeechRequestRegistry.defaultMaxSpaces) throws {
        self.file = file
        self.context = context
        self.maxSpaces = maxSpaces
        seen = []
        if let file, FileManager.default.fileExists(atPath: file.path) {
            let text = try String(contentsOf: file, encoding: .utf8)
            seen = Set(text.split(whereSeparator: \.isNewline).map(String.init))
        }
    }

    /// `sentence` suivie du plus petit nombre d'espaces (1 à `maxSpaces`) qui donne une requête jamais envoyée ; la
    /// requête est inscrite au registre avant d'être rendue. Lève `speechVariantsExhausted` à la borne.
    func uniqueInput(for sentence: String) throws -> String {
        for count in 1...maxSpaces {
            let input = sentence + String(repeating: " ", count: count)
            let digest = Self.digest(context + "\u{0}" + input)
            guard !seen.contains(digest) else { continue }
            try record(digest)
            return input
        }
        throw LatencyError.speechVariantsExhausted(sentence: sentence, maxSpaces: maxSpaces)
    }

    static func digest(_ text: String) -> String { digest(Data(text.utf8)) }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func record(_ digest: String) throws {
        if let file {
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data().write(to: file)
            }
            let handle = try FileHandle(forUpdating: file)
            defer { try? handle.close() }
            // Un fichier dont la dernière ligne n'a pas de fin de ligne ne doit pas coller la nouvelle empreinte à elle.
            let end = try handle.seekToEnd()
            var line = digest + "\n"
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1) != Data("\n".utf8) { line = "\n" + line }
                try handle.seek(toOffset: end)
            }
            try handle.write(contentsOf: Data(line.utf8))
        }
        seen.insert(digest)
    }
}

/// Essais d'un lancement, et la cause de son arrêt avant la fin, s'il y en a eu un.
struct LatencyTrials {
    let trials: [LatencyTrial]
    let stopReason: String?
}

/// Déroule `runs` essais, à tour de rôle sur les enregistrements (essai 1 sur le premier, 2 sur le deuxième…), l'un
/// après l'autre. Pour chaque essai :
/// 1. `silence` est la constante donnée ;
/// 2. `transcription` : durée de `transcribe` sur le clip coupé ; un texte vide arrête l'essai (rien à envoyer) ;
/// 3. `firstSentence` : de l'appel à `chat` (la requête part à l'appel) à la première phrase complète ;
/// 4. `synthesis` : durée de `speak` sur cette phrase, suivie des espaces que choisit `speechRegistry` pour que la
///    requête n'ait jamais été envoyée (sondé : l'audio garde la même taille en octets, pas les mêmes octets ; ce qui
///    est dit n'a pas été réécouté).
///
/// Chaque requête de chat porte une référence `nonce()` dans son message système ; une requête de chat identique à
/// une précédente arrête tout (`duplicateRequest`) : elle pourrait sortir du cache. Un essai est « suspect de cache »
/// si sa première phrase est arrivée entière dans le premier morceau de contenu, ou si l'audio de sa synthèse est
/// identique octet pour octet à celui d'un essai précédent du lancement.
/// Une erreur sur un essai est notée pour cet essai, passée par `redact`, et les essais suivants continuent. Une
/// requête de chat en double, la borne d'espaces du registre atteinte ou une erreur d'écriture du registre arrêtent
/// le déroulé : les essais déjà faits sont rendus avec la cause de l'arrêt (`stopReason`), l'essai en cours est
/// abandonné. L'annulation de la tâche, elle, est levée.
/// `afterTrial` reçoit tous les essais faits, après chaque essai classé : la commande réécrit son rapport.
func runLatencyTrials(recordings: [LatencyRecording], runs: Int, silence: Double, speechRegistry: SpeechRequestRegistry,
                      nonce: () -> String, redact: (String) -> String,
                      transcribe: (AudioClip) async throws -> String,
                      chat: ([ChatMessage]) -> AsyncThrowingStream<ChatDelta, Error>,
                      speak: (String) async throws -> Data,
                      progress: (String) -> Void = { _ in },
                      afterTrial: ([LatencyTrial]) -> Void = { _ in }) async throws -> LatencyTrials {
    precondition(!recordings.isEmpty && runs > 0, "au moins un enregistrement et un essai")
    let clock = ContinuousClock()
    var sentChats: Set<String> = []
    var audioSeen: [String: Int] = [:]   // empreinte de l'audio → numéro de l'essai
    var stopReason: String?
    var trials: [LatencyTrial] = []
    // Seul point d'ajout d'un essai : chacun est rendu à `afterTrial` dès qu'il est classé, hors chrono.
    func keep(_ trial: LatencyTrial) {
        trials.append(trial)
        afterTrial(trials)
    }

    for index in 0..<runs {
        let recording = recordings[index % recordings.count]
        let number = index + 1
        func trial(_ transcript: String?, _ first: FirstSentence?, _ outcome: TrialOutcome) -> LatencyTrial {
            LatencyTrial(number: number, recording: recording.id, transcript: transcript, sentence: first?.text,
                         contentChunks: first?.contentChunks, outcome: outcome)
        }
        func failure(_ error: any Error) throws -> String {
            if error is CancellationError { throw error }
            return redact(describe(error))
        }

        // Transcription.
        var start = clock.now
        let transcript: String
        do {
            transcript = try await transcribe(recording.clip).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            keep(trial(nil, nil, .failed(stage: .transcription, message: try failure(error))))
            continue
        }
        let transcription = seconds(start.duration(to: clock.now))
        guard !transcript.isEmpty else {
            keep(trial("", nil, .failed(stage: .transcription, message: "transcription vide")))
            continue
        }

        // Première phrase.
        let system = interviewerSystemMessage(nonce: nonce())
        guard sentChats.insert(system + "\u{0}" + transcript).inserted else {
            stopReason = "essai \(number) : \(LatencyError.duplicateRequest("de chat"))"
            break
        }
        let noContent = TurnTiming(silence: silence, transcription: transcription, firstSentence: nil, synthesis: nil)
        start = clock.now
        let first: FirstSentence?
        do {
            first = try await readFirstSentence(chat([ChatMessage(role: "system", content: system),
                                                      ChatMessage(role: "user", content: transcript)]))
        } catch EndpointError.malformedResponse {
            let after = decimal(seconds(start.duration(to: clock.now)))
            keep(trial(transcript, nil, .noContent(noContent, reason: "flux vide, sans réponse ni réflexion (après \(after) s)")))
            continue
        } catch {
            keep(trial(transcript, nil, .failed(stage: .chat, message: try failure(error))))
            continue
        }
        let firstSentence = seconds(start.duration(to: clock.now))
        guard let first else {
            keep(trial(transcript, nil, .noContent(noContent, reason: "réflexion seule, aucun texte de réponse (après \(decimal(firstSentence)) s)")))
            continue
        }

        // Synthèse de la première phrase.
        let input: String
        do {
            input = try speechRegistry.uniqueInput(for: first.text)
        } catch {
            stopReason = "essai \(number), registre des requêtes de synthèse : \(describe(error))"
            break
        }
        start = clock.now
        let audio: Data
        do {
            audio = try await speak(input)
        } catch {
            keep(trial(transcript, first, .failed(stage: .synthesis, message: try failure(error))))
            continue
        }
        let timing = TurnTiming(silence: silence, transcription: transcription, firstSentence: firstSentence,
                                synthesis: seconds(start.duration(to: clock.now)))
        let audioDigest = SpeechRequestRegistry.digest(audio)
        let outcome: TrialOutcome
        if let earlier = audioSeen[audioDigest] {
            outcome = .suspectCache(timing, reason: "audio de synthèse identique octet pour octet à celui de l'essai \(earlier)")
        } else if first.contentChunks == 1 {
            outcome = .suspectCache(timing, reason: "première phrase arrivée entière dans le premier morceau de contenu")
        } else {
            outcome = .measured(timing)
        }
        audioSeen[audioDigest] = audioSeen[audioDigest] ?? number
        keep(trial(transcript, first, outcome))
        progress("essai \(number)/\(runs) (\(recording.id)) : \(decimal(timing.total ?? 0)) s")
    }
    return LatencyTrials(trials: trials, stopReason: stopReason)
}

/// Charge et préchauffe `transcriber` avec le vocabulaire de la mesure, hors chrono ; rend l'étiquette de la
/// configuration mesurée (`parakeet` ou `parakeet+vocab`, comme dans `transcribe`) et la transcription à chronométrer,
/// qui reçoit le même vocabulaire à chaque essai.
func prepareLatencyTranscription(_ transcriber: any Transcriber, vocabulary: [String], language: String) async throws
    -> (label: String, transcribe: (AudioClip) async throws -> String) {
    try await transcriber.prepare()
    try await transcriber.warmUp(vocabulary: vocabulary)
    let label = vocabulary.isEmpty ? transcriber.name : vocabularyLabel(transcriber.name)
    return (label, { try await transcriber.transcribe($0, language: language, vocabulary: vocabulary) })
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func decimal(_ value: Double) -> String {
    String(format: "%.2f", value).replacingOccurrences(of: ".", with: ",")
}

// MARK: - Commande

struct LatencyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "latency",
        abstract: "Mesure le délai entre la fin de la parole et la première phrase synthétisée de la réponse."
    )

    static let language = "fr"
    static let localEngines = ["whisperkit", "parakeet", "apple"]
    /// Plafond de jetons de la réponse : seule la première phrase est attendue, mais un modèle qui réfléchit
    /// consomme ce plafond avant de répondre.
    static let maxTokens = 300
    static let speechFormat = "wav"
    /// Registre des requêtes de synthèse déjà envoyées (empreintes), dans le dossier de sortie.
    static let speechRegistryFile = "latence-synthese-envoyee.sha256"

    @Option(name: .long, help: "Dossier des enregistrements : tous ses fichiers .wav, par ordre de nom.")
    var audio: String

    @Option(name: .long, help: "Moteur de transcription local : whisperkit, parakeet ou apple.")
    var engine: String

    @Option(name: .long, help: "Identifiant du modèle de chat de l'endpoint.")
    var chatModel: String

    @Option(name: .long, help: "Identifiant du modèle de synthèse vocale de l'endpoint.")
    var ttsModel: String

    @Option(name: .long, help: "Voix de synthèse.")
    var voice: String

    @Option(name: .long, help: "Paramètre supplémentaire de la synthèse, key=value (répétable).")
    var ttsExtra: [String] = []

    @Option(name: .long, help: "Silence de fin de tour ajouté à chaque essai, en millisecondes.")
    var silenceMs = 600

    @Option(name: .long, help: "Nombre total d'essais, répartis à tour de rôle sur les enregistrements.")
    var runs = 40

    @Option(name: .long, help: "Objectif, en secondes : au plus un tour sur dix au-dessus (test binomial exact à 95 %).")
    var target = 2.0

    @Option(name: .long, help: "Variante du modèle WhisperKit.")
    var whisperkitModel = "large-v3-v20240930_turbo"

    @Option(name: .long, help: ArgumentHelp(
        "Vocabulaire global, un terme par ligne : le moteur est préchauffé et mesuré avec lui (étiquette <moteur>+vocab).",
        discussion: "Même format et mêmes contrôles que dans transcribe. Avec WhisperKit, l'amorce est comptée avant "
            + "tout chargement de modèle. Refusé avec un moteur qui n'accepte pas de vocabulaire (apple)."))
    var vocabulary: String?

    @Option(name: .long, help: "Dossier de sortie : latence.md, et le registre des requêtes de synthèse déjà envoyées.")
    var out: String

    @Flag(name: .long, help: "Remplace latence.md s'il existe (sinon la commande refuse). Le registre des requêtes de synthèse n'est jamais effacé.")
    var overwrite = false

    static let reportFile = "latence.md"

    @Option(name: .long, help: "Délai d'inactivité de chaque requête à l'endpoint, en secondes (sans aucune donnée reçue) : l'essai est alors en échec.")
    var requestTimeout = OpenAICompatibleClient.defaultRequestTimeout

    /// `key=value` ; la clé est non vide, la valeur peut l'être.
    static func parseExtras(_ items: [String]) throws -> [String: String] {
        var extras: [String: String] = [:]
        for item in items {
            guard let equal = item.firstIndex(of: "="), equal != item.startIndex else {
                throw LatencyError.invalidOption("--tts-extra attend key=value : « \(item) »")
            }
            extras[String(item[..<equal])] = String(item[item.index(after: equal)...])
        }
        return extras
    }

    func run() async throws {
        try await run(environment: ProcessInfo.processInfo.environment)
    }

    func makeTranscriber() -> any Transcriber {
        switch engine {
        case "whisperkit": WhisperKitTranscriber(model: whisperkitModel)
        case "parakeet": ParakeetTranscriber()
        default: AppleSpeechTranscriber(locale: TranscribeCommand.appleLocale)
        }
    }

    func run(environment: [String: String]) async throws {
        // Tout ce qui peut être refusé l'est avant de charger le moindre modèle et avant tout appel réseau.
        guard Self.localEngines.contains(engine) else {
            throw LatencyError.invalidOption("moteur « \(engine) » refusé : moteur local attendu (\(Self.localEngines.joined(separator: ", "))) ; "
                                             + "un moteur distant recevrait le même audio à chaque essai et pourrait répondre depuis un cache")
        }
        guard runs > 0 else { throw LatencyError.invalidOption("--runs doit être positif") }
        guard silenceMs >= 0 else { throw LatencyError.invalidOption("--silence-ms ne peut pas être négatif") }
        guard target > 0 else { throw LatencyError.invalidOption("--target doit être positif") }
        guard requestTimeout > 0 else { throw LatencyError.invalidOption("--request-timeout doit être positif") }
        let extras = try Self.parseExtras(ttsExtra)
        let config = try EndpointConfig.fromEnvironment(environment)
        let redact = endpointRedactor(config)
        let outDirectory = URL(fileURLWithPath: out, isDirectory: true)
        try OutputGuard.checkIgnoredByGit(outDirectory, content: "ce rapport contient ce que tu as dit (transcriptions) "
                                          + "et les réponses du modèle")
        // Le registre des requêtes de synthèse reste cumulatif : seul le rapport est protégé.
        try OutputGuard.checkNotExisting([outDirectory.appendingPathComponent(Self.reportFile)], overwrite: overwrite)
        let transcriber = makeTranscriber()
        if vocabulary != nil && !transcriber.acceptsVocabulary {
            throw LatencyError.invalidOption("le moteur \(engine) n'accepte pas de vocabulaire : --vocabulary serait "
                                             + "ignoré et la mesure porterait une étiquette trompeuse")
        }
        let terms = try await GlobalVocabulary.load(vocabulary, whisperKitModel: engine == "whisperkit" ? whisperkitModel : nil,
                                                    say: { print($0) })

        let directory = URL(fileURLWithPath: audio, isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw LatencyError.noRecordings(audio) }

        // Fin de voix de chaque enregistrement, une fois, hors chrono.
        let detector = FluidVoiceDetector()
        try await detector.prepare()
        var recordings: [LatencyRecording] = []
        var withoutSpeech: [String] = []
        for file in files {
            let id = file.deletingPathExtension().lastPathComponent
            let clip = Resampler.resample(try WavFile.read(file), to: transcriberSampleRate)
            guard let end = try await detector.segments(in: clip).last?.end else { withoutSpeech.append(id); continue }
            let count = min(clip.samples.count, Int((end * clip.sampleRate).rounded()))
            recordings.append(LatencyRecording(id: id, clip: AudioClip(samples: Array(clip.samples[..<count]),
                                                                       sampleRate: clip.sampleRate),
                                               speechEnd: end, duration: clip.duration))
        }
        guard !recordings.isEmpty else { throw LatencyError.noSpeech }
        print("\(recordings.count) enregistrement(s) avec voix, \(withoutSpeech.count) sans ; \(runs) essai(s).")
        if runs < recordings.count {
            print("Attention : moins d'essais que d'enregistrements, \(recordings.count - runs) enregistrement(s) ne seront pas mesurés.")
        }

        print("\(engine) : chargement et préchauffage…")
        let transcription = try await prepareLatencyTranscription(transcriber, vocabulary: terms, language: Self.language)

        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        let extrasKey = extras.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&")
        let registry = try SpeechRequestRegistry(
            file: outDirectory.appendingPathComponent(Self.speechRegistryFile),
            context: [ttsModel, voice, Self.speechFormat, extrasKey].joined(separator: "\u{0}"))

        let client = OpenAICompatibleClient(config: config, requestTimeout: requestTimeout)
        let (chatModel, ttsModel, voice) = (self.chatModel, self.ttsModel, self.voice)
        var settings = LatencySettings(engine: transcription.label, vocabulary: terms, chatModel: chatModel, ttsModel: ttsModel,
                                       voice: voice, ttsExtra: extras, silenceMs: silenceMs, target: target,
                                       maxTokens: Self.maxTokens, runs: runs, detector: FluidVoiceDetector.conditions,
                                       detectorHop: FluidVoiceDetector.hopSeconds)
        settings.requestTimeout = requestTimeout
        let report = outDirectory.appendingPathComponent(Self.reportFile)
        let result = try await runLatencyTrials(
            recordings: recordings, runs: runs, silence: Double(silenceMs) / 1000, speechRegistry: registry,
            nonce: { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased() },
            redact: redact,
            transcribe: transcription.transcribe,
            chat: { client.chatStream(model: chatModel, messages: $0, maxTokens: Self.maxTokens) },
            speak: { try await client.speech(model: ttsModel, input: $0, voice: voice, format: Self.speechFormat, extra: extras) },
            progress: { print($0) },
            afterTrial: { done in
                // Rapport réécrit après chaque essai : un arrêt en cours de route garde les essais faits.
                let partial = Reports.latencyMarkdown(settings: settings, recordings: recordings, withoutSpeech: withoutSpeech,
                                                      trials: done, progress: ReportProgress(done: done.count, planned: runs))
                do { try partial.write(to: report, atomically: true, encoding: .utf8) } catch {
                    print("Attention : rapport partiel non écrit : \(describe(error))")
                }
            })

        let trials = result.trials
        let markdown = Reports.latencyMarkdown(settings: settings, recordings: recordings, withoutSpeech: withoutSpeech,
                                               trials: trials, stopReason: result.stopReason)
        try markdown.write(to: report, atomically: true, encoding: .utf8)
        print("")
        print(Reports.latencyVerdict(settings: settings, trials: trials))
        print("Rapport : \(report.path)")
        if let reason = result.stopReason { throw LatencyError.stopped(reason) }
    }
}
