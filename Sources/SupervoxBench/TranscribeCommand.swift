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
/// - Chaque message d'échec passe par `redact` avant d'être gardé ou affiché.
func runEngines(_ engines: [any Transcriber], corpus: [CorpusItem], audio: (String) throws -> AudioClip,
                hasSpeech: (AudioClip) async throws -> Bool, vocabulary: [String] = [],
                language: String = "fr", redact: (String) -> String = { $0 },
                progress: (String) -> Void = { _ in }) async -> [String: [ItemResult]] {
    requireUniqueNames(engines)
    let inputs = await loadInputs(corpus, audio: audio, hasSpeech: hasSpeech, redact: redact)
    var out: [String: [ItemResult]] = [:]
    for engine in engines {
        out[engine.name] = await runPass(engine, label: engine.name, corpus: corpus, inputs: inputs,
                                         vocabulary: vocabulary, language: language, redact: redact, progress: progress).rows
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
/// remarque. Chaque message d'échec passe par `redact` avant d'être gardé ou affiché.
///
/// Un moteur arrêté par des pannes de transport consécutives (voir `runPass`) ne lance pas sa passe « +vocab » : ses
/// phrases parlées y sont en échec avec la même raison. Les moteurs suivants passent normalement.
///
/// `afterPass` reçoit, après chaque passe, toutes les lignes finies (conditions du moteur en cours lues à cet
/// instant) : la commande réécrit son rapport au fil de l'eau. La valeur rendue relit les conditions après les passes.
func runBenchmark(_ engines: [any Transcriber], corpus: [CorpusItem], audio: (String) throws -> AudioClip,
                  hasSpeech: (AudioClip) async throws -> Bool, vocabulary: [String], language: String = "fr",
                  redact: (String) -> String = { $0 }, progress: (String) -> Void = { _ in },
                  afterPass: ([EngineRun]) -> Void = { _ in }) async -> [EngineRun] {
    requireUniqueNames(engines)
    let inputs = await loadInputs(corpus, audio: audio, hasSpeech: hasSpeech, redact: redact)
    var runs: [EngineRun] = []
    for engine in engines {
        let note = (!vocabulary.isEmpty && !engine.acceptsVocabulary)
            ? "mesuré sans vocabulaire : l'adaptateur de ce moteur ne lui transmet pas de liste de termes" : nil
        let plain = await runPass(engine, label: engine.name, corpus: corpus, inputs: inputs, vocabulary: [],
                                  language: language, redact: redact, progress: progress)
        let plainRun = { (conditions: String) in
            EngineRun(engine: engine.name, label: engine.name, results: plain.rows, note: note, conditions: conditions)
        }
        guard !vocabulary.isEmpty && engine.acceptsVocabulary else {
            runs.append(plainRun(await engine.measurementConditions))
            afterPass(runs)
            continue
        }
        afterPass(runs + [plainRun(await engine.measurementConditions)])
        let primed = await runPass(engine, label: vocabularyLabel(engine.name), corpus: corpus, inputs: inputs,
                                   vocabulary: vocabulary, language: language, redact: redact, progress: progress,
                                   stoppedBefore: plain.stopped)
        // Lu après les passes : le moteur peut y dire ce qui s'est réellement appliqué.
        let conditions = await engine.measurementConditions
        runs.append(plainRun(conditions))
        runs.append(EngineRun(engine: engine.name, label: vocabularyLabel(engine.name), results: primed.rows, note: nil,
                              conditions: conditions))
        afterPass(runs)
    }
    return runs
}

/// Nombre de passes de `runBenchmark` : une par moteur, plus une par moteur qui accepte le vocabulaire donné.
func plannedPasses(_ engines: [any Transcriber], vocabulary: [String]) -> Int {
    engines.reduce(0) { $0 + 1 + (!vocabulary.isEmpty && $1.acceptsVocabulary ? 1 : 0) }
}

/// Pannes de transport consécutives (endpoint injoignable, ou muet au-delà du délai de requête) qui arrêtent un moteur.
let consecutiveTransportFailureLimit = 3

/// Étiquette d'un moteur mesuré avec le vocabulaire global, la même dans `transcribe` et `latency`.
func vocabularyLabel(_ engine: String) -> String { engine + "+vocab" }

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
                        hasSpeech: (AudioClip) async throws -> Bool, redact: (String) -> String) async -> [PassInput] {
    var inputs: [PassInput] = []
    for item in corpus {
        let clip: AudioClip
        do { clip = try audio(item.id) } catch {
            inputs.append(.failed(redact("audio illisible : \(describe(error))")))
            continue
        }
        do {
            inputs.append(.clip(clip, hasSpeech: try await hasSpeech(clip)))
        } catch {
            inputs.append(.failed(redact("détection de voix : \(describe(error))")))
        }
    }
    return inputs
}

/// Une passe d'un moteur sur tout le corpus : chargement, passage à vide avec le vocabulaire de la passe, puis une
/// transcription chronométrée par phrase parlée.
///
/// Après `consecutiveTransportFailureLimit` pannes de transport de suite (`EndpointError.transport`), le moteur est
/// arrêté : les phrases parlées restantes sont en échec avec cette raison, rendue dans `stopped`. Une réponse, même
/// une erreur HTTP, remet le compte à zéro ; une phrase sans voix n'appelle pas le moteur et ne change pas le compte.
/// `stoppedBefore` : moteur déjà arrêté, la passe n'appelle rien et chaque phrase parlée porte cette raison.
private func runPass(_ engine: any Transcriber, label: String, corpus: [CorpusItem], inputs: [PassInput],
                     vocabulary: [String], language: String, redact: (String) -> String,
                     progress: (String) -> Void, stoppedBefore: String? = nil) async -> (rows: [ItemResult], stopped: String?) {
    var setupFailure: String? = stoppedBefore
    if setupFailure == nil {
        progress("\(label) : chargement et préchauffage…")
        do { try await engine.prepare() } catch { setupFailure = redact("chargement : \(describe(error))") }
    }
    if setupFailure == nil {
        do { try await engine.warmUp(vocabulary: vocabulary) } catch { setupFailure = redact("préchauffage : \(describe(error))") }
    }
    if let setupFailure { progress("\(label) : \(setupFailure)") }
    else { progress("\(label) : transcription de \(corpus.count) phrase(s)…") }
    var transportFailures = 0
    var stopped: String? = stoppedBefore

    let clock = ContinuousClock()
    var rows: [ItemResult] = []
    for (item, input) in zip(corpus, inputs) {
        switch input {
        case .failed(let message):
            rows.append(ItemResult(id: item.id, hypothesis: nil, seconds: nil, failure: message, hasSpeech: true))
        case .clip(_, hasSpeech: false):
            rows.append(ItemResult(id: item.id, hypothesis: nil, seconds: nil, failure: nil, hasSpeech: false))
        case .clip(let clip, hasSpeech: true):
            if let failure = setupFailure ?? stopped {
                rows.append(ItemResult(id: item.id, hypothesis: nil, seconds: nil, failure: failure, hasSpeech: true))
                continue
            }
            let start = clock.now
            do {
                let text = try await engine.transcribe(clip, language: language, vocabulary: vocabulary)
                let elapsed = start.duration(to: clock.now)
                rows.append(ItemResult(id: item.id, hypothesis: text, seconds: seconds(elapsed), failure: nil, hasSpeech: true))
                transportFailures = 0
            } catch {
                rows.append(ItemResult(id: item.id, hypothesis: nil, seconds: nil, failure: redact(describe(error)), hasSpeech: true))
                if case .transport? = error as? EndpointError { transportFailures += 1 } else { transportFailures = 0 }
                if transportFailures == consecutiveTransportFailureLimit {
                    stopped = "moteur arrêté après \(consecutiveTransportFailureLimit) échecs de transport consécutifs "
                        + "(endpoint injoignable ou muet), phrase non envoyée"
                    progress("\(label) : \(stopped ?? "")")
                }
            }
        }
    }
    return (rows, stopped)
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

/// `--vocabulary`, partagé par `transcribe` et `latency` : mêmes règles de lecture, mêmes contrôles.
enum GlobalVocabulary {
    /// Lit le fichier (`nil` : pas de vocabulaire) et refuse un fichier sans terme. Si `whisperKitModel` est donné
    /// (WhisperKit sera mesuré avec ce vocabulaire), le budget d'amorce est contrôlé ici, avant tout chargement de
    /// modèle ; `countTokens` ne lit que le tokenizer (téléchargé s'il manque).
    static func load(_ path: String?, whisperKitModel: String?,
                     countTokens: ([String], String) async throws -> Int? = {
                         try await WhisperKitTranscriber.promptTokenCount($0, model: $1)
                     },
                     say: (String) -> Void) async throws -> [String] {
        guard let path else { return [] }
        let terms = VocabularyFile.parse(try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8))
        if terms.isEmpty { throw TranscribeError.emptyVocabulary(path) }
        guard let model = whisperKitModel else { return terms }
        let tokens = try await PromptBudget.check(terms, limit: WhisperKitTranscriber.promptTokenLimit) {
            try await countTokens($0, model)
        }
        if let tokens {
            say("Amorce WhisperKit : \(tokens) jetons sur \(WhisperKitTranscriber.promptTokenLimit).")
        } else {
            say("Attention : tokenizer du modèle WhisperKit « \(model) » non identifié, amorce non contrôlée "
                + "avant le chargement ; un dépassement fera échouer la mesure avec vocabulaire.")
        }
        return terms
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

    @Flag(name: .long, help: "Remplace transcription.md et transcription.json s'ils existent (sinon la commande refuse).")
    var overwrite = false

    @Option(name: .long, help: "Moteur endpoint : délai d'inactivité de chaque requête, en secondes (sans aucune donnée reçue).")
    var requestTimeout = OpenAICompatibleClient.defaultRequestTimeout

    static let reportFiles = ["transcription.md", "transcription.json"]

    func run() async throws {
        try await run(environment: ProcessInfo.processInfo.environment)
    }

    func run(environment: [String: String]) async throws {
        // Tout ce qui peut être refusé l'est avant de charger le moindre modèle et avant tout appel réseau.
        let names = try EngineList.parse(engines)
        let model = endpointModel?.trimmingCharacters(in: .whitespaces) ?? ""
        if names.contains("endpoint") && model.isEmpty { throw TranscribeError.missingEndpointModel }
        guard requestTimeout > 0 else { throw ValidationError("--request-timeout doit être positif") }
        // Variables de l'endpoint lues en tout premier, quand il est demandé.
        let endpointConfig = names.contains("endpoint") ? try EndpointConfig.fromEnvironment(environment) : nil
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try OutputGuard.checkIgnoredByGit(directory, content: "ces rapports contiennent ce que tu as dit (transcriptions) "
                                          + "et ton vocabulaire")
        try OutputGuard.checkNotExisting(Self.reportFiles.map { directory.appendingPathComponent($0) }, overwrite: overwrite)
        let items = try Corpus.load(from: URL(fileURLWithPath: corpus))
        let terms = try await GlobalVocabulary.load(vocabulary, whisperKitModel: names.contains("whisperkit") ? whisperkitModel : nil,
                                                    say: { print($0) })
        let clips = try CorpusAudio.load(items, from: URL(fileURLWithPath: audio, isDirectory: true))
        // Le détecteur de voix est chargé avant tout moteur : sans lui, la commande s'arrête.
        let detector = FluidVoiceDetector()
        try await detector.prepare()
        let transcribers: [any Transcriber] = names.map { name in
            switch name {
            case "whisperkit": WhisperKitTranscriber(model: whisperkitModel)
            case "parakeet": ParakeetTranscriber()
            case "apple": AppleSpeechTranscriber(locale: Self.appleLocale)
            default:   // `endpointConfig` est lu en tête dès que le moteur endpoint est demandé
                EndpointTranscriber(client: OpenAICompatibleClient(config: endpointConfig!, requestTimeout: requestTimeout),
                                    model: model)
            }
        }
        let redact = endpointConfig.map(endpointRedactor) ?? { $0 }
        let planned = plannedPasses(transcribers, vocabulary: terms)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let runs = await runBenchmark(
            transcribers, corpus: items,
            audio: { id in
                guard let clip = clips[id] else { throw TranscribeError.missingAudio([id]) }
                return clip
            },
            hasSpeech: { try await !detector.segments(in: $0).isEmpty },
            vocabulary: terms, language: Self.language, redact: redact,
            progress: { print($0) },
            afterPass: { done in
                // Rapport réécrit après chaque passe : un arrêt en cours de route garde les passes finies.
                do {
                    try writeReports(directory, corpus: items, runs: done, vocabulary: terms,
                                     progress: ReportProgress(done: done.count, planned: planned))
                } catch {
                    print("Attention : rapport partiel non écrit : \(describe(error))")
                }
            }
        )
        try writeReports(directory, corpus: items, runs: runs, vocabulary: terms, progress: nil)

        print("")
        print(Reports.markdownTable(Reports.summaries(corpus: items, runs: runs)))
        print("Rapport : \(directory.appendingPathComponent("transcription.md").path)")
    }

    /// `transcription.md` et `transcription.json`, écrits en entier à chaque fois (écriture atomique). Le contrôle du
    /// rapport existant est fait une fois, au lancement : les réécritures suivantes portent sur les fichiers du lancement.
    private func writeReports(_ directory: URL, corpus: [CorpusItem], runs: [EngineRun], vocabulary: [String],
                              progress: ReportProgress?) throws {
        let markdown = Reports.markdownReport(corpus: corpus, runs: runs, vocabulary: vocabulary, progress: progress)
        try markdown.write(to: directory.appendingPathComponent("transcription.md"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let json = TranscriptionJSON(language: Self.language, vocabulary: vocabulary, corpus: corpus, runs: runs,
                                     progress: progress)
        try encoder.encode(json).write(to: directory.appendingPathComponent("transcription.json"), options: .atomic)
    }
}
