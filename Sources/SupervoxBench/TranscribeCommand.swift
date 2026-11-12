import ArgumentParser
import Foundation
import SupervoxCore
import SupervoxEngines

// MARK: - Déroulé d'un passage

/// Fait transcrire chaque phrase du corpus par chaque moteur, l'un après l'autre (jamais en parallèle : les durées
/// seraient faussées par la concurrence). Rend les résultats par nom de moteur, dans l'ordre du corpus.
///
/// - L'audio de chaque phrase est lu, et la présence de voix décidée, une seule fois pour tous les moteurs : tous
///   reçoivent exactement le même clip et la même décision.
/// - Une phrase sans voix n'est envoyée à aucun moteur (`hasSpeech: false`).
/// - Un audio illisible, ou une erreur du détecteur de voix, est un échec de la phrase pour chaque moteur : jamais une
///   décision par défaut, qui ferait transcrire du silence ou écarterait une phrase parlée sans le dire.
/// - `prepare()` puis `warmUp(vocabulary:)` ne sont pas chronométrés ; si l'un échoue, chaque phrase parlée porte
///   son erreur.
/// - Seul l'appel à `transcribe` est chronométré, avec une horloge monotone.
/// - `vocabulary` est passé tel quel à chaque appel : c'est la liste globale, jamais les termes d'une phrase.
/// - Deux moteurs du même nom s'écraseraient dans le dictionnaire : c'est une erreur de programmation (`precondition`) ;
///   la commande les refuse avant d'arriver ici.
func runEngines(_ engines: [any Transcriber], corpus: [CorpusItem], audio: (String) throws -> AudioClip,
                hasSpeech: (AudioClip) async throws -> Bool, vocabulary: [String] = [],
                language: String = "fr", progress: (String) -> Void = { _ in }) async -> [String: [ItemResult]] {
    requireUniqueNames(engines)
    let inputs = await loadInputs(corpus, audio: audio, hasSpeech: hasSpeech)
    var out: [String: [ItemResult]] = [:]
    for engine in engines {
        out[engine.name] = await runPass(engine, label: engine.name, corpus: corpus, inputs: inputs,
                                         vocabulary: vocabulary, language: language, progress: progress)
    }
    return out
}

/// Une ligne du rapport : un moteur, mesuré avec ou sans le vocabulaire global.
struct EngineRun {
    let engine: String
    let label: String
    let results: [ItemResult]
    let note: String?
    /// `Transcriber.measurementConditions` du moteur.
    let conditions: String
}

/// Passage complet du banc. Pour chaque moteur, dans l'ordre : passe sans vocabulaire, puis, si une liste globale est
/// donnée et que le moteur l'accepte, passe avec elle sous l'étiquette `<nom>+vocab`. Les deux passes d'un moteur
/// s'enchaînent avant le moteur suivant, et chacune est précédée de son passage à vide : la passe « +vocab » ne
/// démarre pas sur un modèle refroidi par les autres moteurs. Un moteur qui n'accepte pas de vocabulaire porte une
/// remarque.
func runBenchmark(_ engines: [any Transcriber], corpus: [CorpusItem], audio: (String) throws -> AudioClip,
                  hasSpeech: (AudioClip) async throws -> Bool, vocabulary: [String], language: String = "fr",
                  progress: (String) -> Void = { _ in }) async -> [EngineRun] {
    requireUniqueNames(engines)
    let inputs = await loadInputs(corpus, audio: audio, hasSpeech: hasSpeech)
    var runs: [EngineRun] = []
    for engine in engines {
        let note = (!vocabulary.isEmpty && !engine.acceptsVocabulary)
            ? "mesuré sans vocabulaire : l'adaptateur de ce moteur ne lui transmet pas de liste de termes" : nil
        let plain = await runPass(engine, label: engine.name, corpus: corpus, inputs: inputs, vocabulary: [],
                                  language: language, progress: progress)
        var primed: [ItemResult]?
        if !vocabulary.isEmpty && engine.acceptsVocabulary {
            primed = await runPass(engine, label: engine.name + "+vocab", corpus: corpus, inputs: inputs,
                                   vocabulary: vocabulary, language: language, progress: progress)
        }
        // Lu après les passes : le moteur peut y dire ce qui s'est réellement appliqué.
        let conditions = await engine.measurementConditions
        runs.append(EngineRun(engine: engine.name, label: engine.name, results: plain, note: note, conditions: conditions))
        if let primed {
            runs.append(EngineRun(engine: engine.name, label: engine.name + "+vocab", results: primed, note: nil,
                                  conditions: conditions))
        }
    }
    return runs
}

private func requireUniqueNames(_ engines: [any Transcriber]) {
    let names = engines.map(\.name)
    precondition(Set(names).count == names.count, "deux moteurs portent le même nom : \(names)")
}

/// Entrée d'une phrase, préparée une fois pour tous les moteurs.
private enum PassInput {
    case clip(AudioClip, hasSpeech: Bool)
    /// Audio illisible ou détection de voix en échec : le message est l'échec de la phrase.
    case failed(String)
}

private func loadInputs(_ corpus: [CorpusItem], audio: (String) throws -> AudioClip,
                        hasSpeech: (AudioClip) async throws -> Bool) async -> [PassInput] {
    var inputs: [PassInput] = []
    for item in corpus {
        let clip: AudioClip
        do { clip = try audio(item.id) } catch {
            inputs.append(.failed("audio illisible : \(describe(error))"))
            continue
        }
        do {
            inputs.append(.clip(clip, hasSpeech: try await hasSpeech(clip)))
        } catch {
            inputs.append(.failed("détection de voix : \(describe(error))"))
        }
    }
    return inputs
}

/// Une passe d'un moteur sur tout le corpus : chargement, passage à vide avec le vocabulaire de la passe, puis une
/// transcription chronométrée par phrase parlée.
private func runPass(_ engine: any Transcriber, label: String, corpus: [CorpusItem], inputs: [PassInput],
                     vocabulary: [String], language: String, progress: (String) -> Void) async -> [ItemResult] {
    progress("\(label) : chargement et préchauffage…")
    var setupFailure: String?
    do { try await engine.prepare() } catch { setupFailure = "chargement : \(describe(error))" }
    if setupFailure == nil {
        do { try await engine.warmUp(vocabulary: vocabulary) } catch { setupFailure = "préchauffage : \(describe(error))" }
    }
    if let setupFailure { progress("\(label) : \(setupFailure)") }
    else { progress("\(label) : transcription de \(corpus.count) phrase(s)…") }

    let clock = ContinuousClock()
    var rows: [ItemResult] = []
    for (item, input) in zip(corpus, inputs) {
        switch input {
        case .failed(let message):
            rows.append(ItemResult(id: item.id, hypothesis: nil, seconds: nil, failure: message, hasSpeech: true))
        case .clip(_, hasSpeech: false):
            rows.append(ItemResult(id: item.id, hypothesis: nil, seconds: nil, failure: nil, hasSpeech: false))
        case .clip(let clip, hasSpeech: true):
            if let setupFailure {
                rows.append(ItemResult(id: item.id, hypothesis: nil, seconds: nil, failure: setupFailure, hasSpeech: true))
                continue
            }
            let start = clock.now
            do {
                let text = try await engine.transcribe(clip, language: language, vocabulary: vocabulary)
                let elapsed = start.duration(to: clock.now)
                rows.append(ItemResult(id: item.id, hypothesis: text, seconds: seconds(elapsed), failure: nil, hasSpeech: true))
            } catch {
                rows.append(ItemResult(id: item.id, hypothesis: nil, seconds: nil, failure: describe(error), hasSpeech: true))
            }
        }
    }
    return rows
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

/// Message d'erreur lisible : `description` du type s'il en a une, sinon la forme Swift du cas avec ses valeurs
/// (ex. `http(status: 503, body: "…")`). On n'utilise pas `localizedDescription` : pour une erreur Swift sans
/// traduction, il rend « The operation couldn't be completed » et perd le détail.
func describe(_ error: any Error) -> String {
    String(describing: error)
}

// MARK: - Entrées de la commande

enum TranscribeError: Error, Equatable, CustomStringConvertible {
    case noEngine
    case unknownEngine(String)
    case duplicateEngine(String)
    case missingAudio([String])
    case unreadableAudio(id: String, reason: String)
    case emptyAudio(String)
    case missingEndpointModel
    case emptyVocabulary(String)
    case vocabularyTooLong(tokens: Int, limit: Int)

    var description: String {
        switch self {
        case .noEngine: "aucun moteur demandé"
        case .unknownEngine(let name): "moteur inconnu : « \(name) » (attendus : \(EngineList.known.joined(separator: ", ")))"
        case .duplicateEngine(let name): "moteur demandé deux fois : « \(name) »"
        case .missingAudio(let ids): "aucun fichier audio pour \(ids.count) phrase(s) du corpus : \(ids.joined(separator: ", "))"
        case .unreadableAudio(let id, let reason): "audio de « \(id) » illisible : \(reason)"
        case .emptyAudio(let id): "audio de « \(id) » vide"
        case .missingEndpointModel: "le moteur endpoint demande --endpoint-model"
        case .emptyVocabulary(let path): "le fichier de vocabulaire \(path) ne contient aucun terme"
        case .vocabularyTooLong(let tokens, let limit):
            "le vocabulaire fait \(tokens) jetons d'amorce pour WhisperKit, \(limit) au plus : retirer des termes "
                + "(WhisperKit ne garderait que les \(limit) derniers jetons, en silence)"
        }
    }
}

/// Liste `--engines` : noms séparés par des virgules, sans doublon (un doublon écraserait les résultats de l'autre).
enum EngineList {
    static let known = ["whisperkit", "parakeet", "apple", "endpoint"]

    static func parse(_ text: String) throws -> [String] {
        let names = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { throw TranscribeError.noEngine }
        var seen: Set<String> = []
        for name in names {
            guard known.contains(name) else { throw TranscribeError.unknownEngine(name) }
            guard seen.insert(name).inserted else { throw TranscribeError.duplicateEngine(name) }
        }
        return names
    }
}

/// Fichier `--vocabulary` : un terme par ligne ; lignes vides et lignes commençant par `#` ignorées ; espaces rognés ;
/// doublons retirés (premier gardé).
enum VocabularyFile {
    static func parse(_ contents: String) -> [String] {
        var terms: [String] = []
        for line in contents.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }) {
            let term = line.trimmingCharacters(in: .whitespaces)
            if term.isEmpty || term.hasPrefix("#") || terms.contains(term) { continue }
            terms.append(term)
        }
        return terms
    }
}

/// Budget d'amorce de WhisperKit : contrôlé avant tout chargement de modèle, pour qu'un vocabulaire trop long n'envoie
/// pas toute la ligne « whisperkit+vocab » en échec après des minutes de passes sans vocabulaire.
enum PromptBudget {
    /// `count` rend le nombre de jetons de l'amorce, ou `nil` s'il ne peut pas être calculé. Rend ce nombre ; lève
    /// `vocabularyTooLong` au-delà de `limit`. Aucune troncature.
    @discardableResult
    static func check(_ vocabulary: [String], limit: Int, count: ([String]) async throws -> Int?) async throws -> Int? {
        guard let tokens = try await count(vocabulary) else { return nil }
        guard tokens <= limit else { throw TranscribeError.vocabularyTooLong(tokens: tokens, limit: limit) }
        return tokens
    }
}

/// Audio du corpus : `<dossier>/<id>.wav` pour chaque phrase.
enum CorpusAudio {
    /// Lit tous les fichiers avant tout chargement de modèle. Un identifiant sans fichier arrête tout (liste complète
    /// des manquants) : un corpus incomplet comparerait les moteurs sur autre chose que ce qui a été déclaré.
    /// Un WAV qui n'est pas à 16 kHz est rééchantillonné ici, une fois, pour tous les moteurs.
    static func load(_ corpus: [CorpusItem], from directory: URL) throws -> [String: AudioClip] {
        let files = corpus.map { ($0.id, directory.appendingPathComponent($0.id + ".wav")) }
        let missing = files.filter { !FileManager.default.fileExists(atPath: $0.1.path) }.map(\.0)
        guard missing.isEmpty else { throw TranscribeError.missingAudio(missing) }

        var clips: [String: AudioClip] = [:]
        for (id, url) in files {
            let raw: AudioClip
            do { raw = try WavFile.read(url) } catch { throw TranscribeError.unreadableAudio(id: id, reason: describe(error)) }
            guard !raw.samples.isEmpty else { throw TranscribeError.emptyAudio(id) }
            let clip = Resampler.resample(raw, to: transcriberSampleRate)
            guard !clip.samples.isEmpty else {
                throw TranscribeError.unreadableAudio(id: id, reason: "rééchantillonnage à 16 kHz impossible")
            }
            clips[id] = clip
        }
        return clips
    }
}

// MARK: - Commande

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Fait transcrire les enregistrements du corpus par chaque moteur et compare les taux d'erreur."
    )

    /// Le banc mesure la dictée en français ; la locale d'Apple suit.
    static let language = "fr"
    static let appleLocale = "fr-FR"

    @Option(name: .long, help: "Fichier du corpus (TSV : id, texte, termes).")
    var corpus: String

    @Option(name: .long, help: "Dossier des enregistrements : <dossier>/<id>.wav.")
    var audio: String

    @Option(name: .long, help: "Moteurs, séparés par des virgules : whisperkit, parakeet, apple, endpoint.")
    var engines = "whisperkit,parakeet,apple"

    @Option(name: .long, help: "Identifiant du modèle de transcription de l'endpoint (obligatoire avec le moteur endpoint).")
    var endpointModel: String?

    @Option(name: .long, help: "Variante du modèle WhisperKit.")
    var whisperkitModel = "large-v3-v20240930_turbo"

    @Option(name: .long, help: ArgumentHelp(
        "Vocabulaire global, un terme par ligne. Les moteurs qui l'acceptent sont mesurés sans puis avec.",
        discussion: "Avec WhisperKit, la liste devient une amorce de \(WhisperKitTranscriber.promptTokenLimit) jetons au plus ; "
            + "le compte est vérifié avant tout chargement de modèle, et un dépassement arrête la commande."))
    var vocabulary: String?

    @Option(name: .long, help: "Dossier de sortie : transcription.md et transcription.json.")
    var out: String

    func run() async throws {
        // Tout ce qui peut être refusé l'est avant de charger le moindre modèle.
        let names = try EngineList.parse(engines)
        let model = endpointModel?.trimmingCharacters(in: .whitespaces) ?? ""
        if names.contains("endpoint") && model.isEmpty { throw TranscribeError.missingEndpointModel }
        let items = try Corpus.load(from: URL(fileURLWithPath: corpus))
        var terms: [String] = []
        if let vocabulary {
            terms = VocabularyFile.parse(try String(contentsOf: URL(fileURLWithPath: vocabulary), encoding: .utf8))
            if terms.isEmpty { throw TranscribeError.emptyVocabulary(vocabulary) }
        }
        if names.contains("whisperkit") && !terms.isEmpty {
            let model = whisperkitModel
            let tokens = try await PromptBudget.check(terms, limit: WhisperKitTranscriber.promptTokenLimit) {
                try await WhisperKitTranscriber.promptTokenCount($0, model: model)
            }
            if let tokens {
                print("Amorce WhisperKit : \(tokens) jetons sur \(WhisperKitTranscriber.promptTokenLimit).")
            } else {
                print("Attention : tokenizer du modèle WhisperKit « \(model) » non identifié, amorce non contrôlée "
                      + "avant le chargement ; un dépassement fera échouer la ligne whisperkit+vocab.")
            }
        }
        let clips = try CorpusAudio.load(items, from: URL(fileURLWithPath: audio, isDirectory: true))
        // Le détecteur de voix est chargé avant tout moteur : sans lui, la commande s'arrête.
        let detector = FluidVoiceDetector()
        try await detector.prepare()
        let transcribers: [any Transcriber] = try names.map { name in
            switch name {
            case "whisperkit": WhisperKitTranscriber(model: whisperkitModel)
            case "parakeet": ParakeetTranscriber()
            case "apple": AppleSpeechTranscriber(locale: Self.appleLocale)
            default:
                EndpointTranscriber(client: OpenAICompatibleClient(config: try EndpointConfig.fromEnvironment(
                    ProcessInfo.processInfo.environment)), model: model)
            }
        }

        let runs = await runBenchmark(
            transcribers, corpus: items,
            audio: { id in
                guard let clip = clips[id] else { throw TranscribeError.missingAudio([id]) }
                return clip
            },
            hasSpeech: { try await !detector.segments(in: $0).isEmpty },
            vocabulary: terms, language: Self.language,
            progress: { print($0) }
        )

        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let markdown = Reports.markdownReport(corpus: items, runs: runs, vocabulary: terms)
        try markdown.write(to: directory.appendingPathComponent("transcription.md"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = TranscriptionJSON(language: Self.language, vocabulary: terms, corpus: items, runs: runs)
        try encoder.encode(json).write(to: directory.appendingPathComponent("transcription.json"), options: .atomic)

        print("")
        print(Reports.markdownTable(Reports.summaries(corpus: items, runs: runs)))
        print("Rapport : \(directory.appendingPathComponent("transcription.md").path)")
    }
}
