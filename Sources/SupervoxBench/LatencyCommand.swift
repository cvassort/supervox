import ArgumentParser
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
    /// Toute la première phrase est arrivée dans le premier morceau de contenu : forme d'une réponse sortie du cache
    /// de la passerelle. Rapporté à part, jamais moyenné.
    case suspectCache(TurnTiming)
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
    case noRecordings(String)
    case noSpeech
    case invalidOption(String)

    var description: String {
        switch self {
        case .duplicateRequest(let what):
            "requête \(what) identique à une requête déjà envoyée : la passerelle pourrait la rendre depuis son cache"
        case .noRecordings(let path): "aucun fichier .wav dans \(path)"
        case .noSpeech: "aucun enregistrement ne contient de voix détectée : rien à mesurer"
        case .invalidOption(let message): message
        }
    }
}

/// Déroule `runs` essais, à tour de rôle sur les enregistrements (essai 1 sur le premier, 2 sur le deuxième…), l'un
/// après l'autre. Pour chaque essai :
/// 1. `silence` est la constante donnée ;
/// 2. `transcription` : durée de `transcribe` sur le clip coupé ; un texte vide arrête l'essai (rien à envoyer) ;
/// 3. `firstSentence` : de l'appel à `chat` (la requête part à l'appel) à la première phrase complète ;
/// 4. `synthesis` : durée de `speak` sur cette phrase, suivie d'espaces dont le nombre est propre à l'essai
///    (`spaceOffset` + numéro de l'essai) : la requête est unique sans changer ce qui est dit.
///
/// Chaque requête de chat porte une référence `nonce()` dans son message système. Une requête de chat ou de synthèse
/// identique à une précédente arrête tout (`duplicateRequest`) : elle pourrait sortir du cache.
/// Une erreur sur un essai est notée pour cet essai, passée par `redact`, et les essais suivants continuent ;
/// seule l'annulation de la tâche arrête le déroulé.
func runLatencyTrials(recordings: [LatencyRecording], runs: Int, silence: Double, spaceOffset: Int,
                      nonce: () -> String, redact: (String) -> String,
                      transcribe: (AudioClip) async throws -> String,
                      chat: ([ChatMessage]) -> AsyncThrowingStream<ChatDelta, Error>,
                      speak: (String) async throws -> Data,
                      progress: (String) -> Void = { _ in }) async throws -> [LatencyTrial] {
    precondition(!recordings.isEmpty && runs > 0, "au moins un enregistrement et un essai")
    let clock = ContinuousClock()
    var sentChats: Set<String> = []
    var sentSpeech: Set<String> = []
    var trials: [LatencyTrial] = []

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
            trials.append(trial(nil, nil, .failed(stage: .transcription, message: try failure(error))))
            continue
        }
        let transcription = seconds(start.duration(to: clock.now))
        guard !transcript.isEmpty else {
            trials.append(trial("", nil, .failed(stage: .transcription, message: "transcription vide")))
            continue
        }

        // Première phrase.
        let system = interviewerSystemMessage(nonce: nonce())
        guard sentChats.insert(system + "\u{0}" + transcript).inserted else { throw LatencyError.duplicateRequest("de chat") }
        let noContent = TurnTiming(silence: silence, transcription: transcription, firstSentence: nil, synthesis: nil)
        start = clock.now
        let first: FirstSentence?
        do {
            first = try await readFirstSentence(chat([ChatMessage(role: "system", content: system),
                                                      ChatMessage(role: "user", content: transcript)]))
        } catch EndpointError.malformedResponse {
            let after = decimal(seconds(start.duration(to: clock.now)))
            trials.append(trial(transcript, nil, .noContent(noContent, reason: "flux vide, sans réponse ni réflexion (après \(after) s)")))
            continue
        } catch {
            trials.append(trial(transcript, nil, .failed(stage: .chat, message: try failure(error))))
            continue
        }
        let firstSentence = seconds(start.duration(to: clock.now))
        guard let first else {
            trials.append(trial(transcript, nil, .noContent(noContent, reason: "réflexion seule, aucun texte de réponse (après \(decimal(firstSentence)) s)")))
            continue
        }

        // Synthèse de la première phrase.
        let input = first.text + String(repeating: " ", count: spaceOffset + number)
        guard sentSpeech.insert(input).inserted else { throw LatencyError.duplicateRequest("de synthèse") }
        start = clock.now
        do {
            _ = try await speak(input)
        } catch {
            trials.append(trial(transcript, first, .failed(stage: .synthesis, message: try failure(error))))
            continue
        }
        let timing = TurnTiming(silence: silence, transcription: transcription, firstSentence: firstSentence,
                                synthesis: seconds(start.duration(to: clock.now)))
        trials.append(trial(transcript, first, first.contentChunks == 1 ? .suspectCache(timing) : .measured(timing)))
        progress("essai \(number)/\(runs) (\(recording.id)) : \(decimal(timing.total ?? 0)) s")
    }
    return trials
}

/// Retire d'un message l'adresse de l'endpoint (complète et nom d'hôte) et la clé.
func endpointRedactor(_ config: EndpointConfig) -> (String) -> String {
    let address = config.baseURL.absoluteString
    var secrets = [address, address.hasSuffix("/") ? String(address.dropLast()) : address]
    if let host = config.baseURL.host(), !host.isEmpty { secrets.append(host) }
    let key = config.apiKey
    return { text in
        var out = key.isEmpty ? text : text.replacingOccurrences(of: key, with: "***")
        for secret in secrets where !secret.isEmpty {
            out = out.replacingOccurrences(of: secret, with: "<endpoint>", options: .caseInsensitive)
        }
        return out
    }
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
    var runs = 10

    @Option(name: .long, help: "Objectif, en secondes, jugé sur le 90e centile.")
    var target = 2.0

    @Option(name: .long, help: "Variante du modèle WhisperKit.")
    var whisperkitModel = "large-v3-v20240930_turbo"

    @Option(name: .long, help: "Dossier de sortie : latence.md.")
    var out: String

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
        // Tout ce qui peut être refusé l'est avant de charger le moindre modèle.
        guard Self.localEngines.contains(engine) else {
            throw LatencyError.invalidOption("moteur « \(engine) » refusé : moteur local attendu (\(Self.localEngines.joined(separator: ", "))) ; "
                                             + "un moteur distant recevrait le même audio à chaque essai et pourrait répondre depuis un cache")
        }
        guard runs > 0 else { throw LatencyError.invalidOption("--runs doit être positif") }
        guard silenceMs >= 0 else { throw LatencyError.invalidOption("--silence-ms ne peut pas être négatif") }
        guard target > 0 else { throw LatencyError.invalidOption("--target doit être positif") }
        let extras = try Self.parseExtras(ttsExtra)
        let config = try EndpointConfig.fromEnvironment(ProcessInfo.processInfo.environment)
        let redact = endpointRedactor(config)

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

        let transcriber: any Transcriber = switch engine {
        case "whisperkit": WhisperKitTranscriber(model: whisperkitModel)
        case "parakeet": ParakeetTranscriber()
        default: AppleSpeechTranscriber(locale: TranscribeCommand.appleLocale)
        }
        print("\(engine) : chargement et préchauffage…")
        try await transcriber.prepare()
        try await transcriber.warmUp(vocabulary: [])

        let client = OpenAICompatibleClient(config: config)
        let (chatModel, ttsModel, voice) = (self.chatModel, self.ttsModel, self.voice)
        let trials = try await runLatencyTrials(
            recordings: recordings, runs: runs, silence: Double(silenceMs) / 1000, spaceOffset: Int.random(in: 0..<32),
            nonce: { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased() },
            redact: redact,
            transcribe: { try await transcriber.transcribe($0, language: Self.language, vocabulary: []) },
            chat: { client.chatStream(model: chatModel, messages: $0, maxTokens: Self.maxTokens) },
            speak: { try await client.speech(model: ttsModel, input: $0, voice: voice, format: Self.speechFormat, extra: extras) },
            progress: { print($0) })

        let settings = LatencySettings(engine: engine, chatModel: chatModel, ttsModel: ttsModel, voice: voice,
                                       ttsExtra: extras, silenceMs: silenceMs, target: target, maxTokens: Self.maxTokens,
                                       runs: runs, detector: FluidVoiceDetector.conditions,
                                       detectorHop: FluidVoiceDetector.hopSeconds)
        let markdown = Reports.latencyMarkdown(settings: settings, recordings: recordings, withoutSpeech: withoutSpeech,
                                               trials: trials)
        let outDirectory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outDirectory, withIntermediateDirectories: true)
        let report = outDirectory.appendingPathComponent("latence.md")
        try markdown.write(to: report, atomically: true, encoding: .utf8)
        print("")
        print(Reports.latencyVerdict(settings: settings, trials: trials))
        print("Rapport : \(report.path)")
    }
}
