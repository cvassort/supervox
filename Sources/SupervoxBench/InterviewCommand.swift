import ArgumentParser
import Foundation
import SupervoxCore
import SupervoxEngines

// MARK: - Erreurs

enum InterviewError: Error, Equatable, CustomStringConvertible {
    case noWav
    case voiceNeedsVoiceModel
    case voiceModelNeedsVoice
    case missingEndpoint
    case invalidOption(String)
    case unreadableWav(name: String, reason: String)
    case emptyWav(String)
    case outputIsAnInput(String)

    var description: String {
        switch self {
        case .outputIsAnInput(let name):
            "--output désigne le fichier WAV d'entrée « \(name) » : il serait écrasé par le rapport. Choisir un autre fichier."
        case .noWav: "Au moins un fichier WAV est nécessaire : un par tour de la personne."
        case .voiceNeedsVoiceModel: "--voice demande aussi --voice-model."
        case .voiceModelNeedsVoice: "--voice-model demande aussi --voice."
        case .missingEndpoint:
            "Définissez \(EndpointConfig.baseURLVariable) et \(EndpointConfig.apiKeyVariable) pour lancer l'entretien du banc."
        case .invalidOption(let message): message
        case .unreadableWav(let name, let reason): "fichier WAV illisible « \(name) » : \(reason)"
        case .emptyWav(let name): "le fichier WAV « \(name) » ne contient aucun échantillon"
        }
    }
}

// MARK: - Moteurs et environnement

/// Ce que la commande demande à la fabrique de moteurs : l'endpoint et les choix de voix et de détecteur.
struct InterviewSetup {
    let endpoint: EndpointConfig
    let voiceModel: String?
    let voice: String?
    let turnSilence: Double
}

/// Les moteurs d'un entretien du banc. Les tests y mettent des doubles : aucun modèle, aucune voix, aucun réseau.
struct InterviewEngines: Sendable {
    let detector: any StreamingVoiceDetector
    let transcriber: any Transcriber
    let voice: any SpeechSynthesizer
    let fast: any LanguageModel
    let strong: any LanguageModel

    /// Les vrais moteurs. Rien n'est chargé ni téléchargé à la construction (le détecteur et la transcription le font à la préparation
    /// de l'entretien) ; aucune requête ne part avant la première réplique.
    ///
    /// La transcription est Parakeet, le moteur de l'entretien de l'application (`TranscriptionEngine.interviewDefault`, code lu). La
    /// voix : celle du fournisseur avec repli sur la voix du système quand `--voice-model` et `--voice` sont donnés, la voix du système
    /// sinon.
    static func real(_ setup: InterviewSetup) -> InterviewEngines {
        let client = OpenAICompatibleClient(config: setup.endpoint)
        let system = SystemSpeechSynthesizer(language: InterviewCommand.language)
        let voice: any SpeechSynthesizer
        if let model = setup.voiceModel, let identifier = setup.voice {
            voice = FallbackSpeechSynthesizer(
                primary: ProviderSpeechSynthesizer(endpoint: client, voice: ProviderVoice(model: model, identifier: identifier, extra: [:])),
                fallback: system)
        } else {
            voice = system
        }
        return InterviewEngines(
            detector: FluidStreamingVoiceDetector(minSilence: setup.turnSilence), transcriber: ParakeetTranscriber(), voice: voice,
            fast: client, strong: client)
    }
}

/// Tout ce que la commande lit ou écrit en dehors de ses arguments : l'environnement, la fabrique de moteurs, les attentes, l'horloge
/// et les sorties. Les tests en donnent des doubles.
struct InterviewRuntime: Sendable {
    var environment: [String: String]
    var makeEngines: @Sendable (InterviewSetup) -> InterviewEngines
    /// L'attente d'une durée simulée : la lecture d'un clip, le délai avant d'interrompre, le délai d'un tour sans réaction.
    var wait: @Sendable (Double) async -> Void
    var now: @Sendable () -> Double
    /// L'attente du chien de garde du micro (voir `InterviewCommand.watchdog`), distincte des précédentes : elle doit suspendre
    /// jusqu'à l'annulation, jamais rendre la main tout de suite (la boucle du chien de garde tournerait à vide).
    var watchdogSleep: @Sendable (Double) async throws -> Void
    /// L'attente de la limite de temps d'une transcription (`ConversationConfig.transcriptionTimeout`) : réelle en lancement réel.
    /// Elle doit rendre la main seulement quand le délai est écoulé : une attente qui rend tout de suite ferait échouer toute
    /// transcription.
    var transcriptionSleep: @Sendable (Double) async throws -> Void
    var say: @Sendable (String) -> Void
    var warn: @Sendable (String) -> Void
    var launchedAt: Date
    /// Pour les tests : chaque événement de l'entretien, après son traitement par le pilote.
    var observe: (@Sendable (ConversationEvent) -> Void)?

    static var live: InterviewRuntime {
        InterviewRuntime(
            environment: ProcessInfo.processInfo.environment, makeEngines: InterviewEngines.real,
            wait: { try? await Task.sleep(for: .seconds($0)) }, now: { ProcessInfo.processInfo.systemUptime },
            watchdogSleep: { try await Task.sleep(for: .seconds($0)) },
            transcriptionSleep: { try await Task.sleep(for: .seconds($0)) },
            say: { print($0) }, warn: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }, launchedAt: Date(), observe: nil)
    }
}

// MARK: - La commande

/// `supervox-bench interview <tour1.wav> <tour2.wav> … --fast-model <m> --strong-model <m> …` : mène un entretien entier à partir de
/// fichiers WAV contre le service que donnent les variables d'environnement. Aucun micro, aucun haut-parleur : le son est un
/// `WavTurnFeed`, et le moteur de conversation est la vraie `ConversationSession`. Jamais lancée par le pipeline.
struct InterviewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "interview",
        abstract: "Mène un entretien entier à partir de fichiers WAV (un par tour de la personne), sans micro ni haut-parleur.",
        discussion: """
            L'adresse et la clé du service viennent de SUPERVOX_BASE_URL et SUPERVOX_API_KEY. Le tour i n'est poussé qu'après la fin de \
            la réplique i−1 (ou, avec --interrupt-after, quelques secondes après son début). Après le dernier fichier, la commande \
            demande la conclusion et rend le prompt ; le code de sortie est non nul si l'entretien ne rend pas de prompt.

            Les durées du rapport ne sont pas comparables aux mesures de latence des étapes précédentes (`latency`) : la forme des \
            requêtes est différente (historique de la conversation, consigne de système avec le nombre de questions restantes). Ni la \
            clé, ni l'adresse, ni les noms de modèle et de voix ne sont écrits dans le rapport ni sur la sortie : ils y sont retirés partout, \
            y compris dans les phrases fixes du rapport et dans la conversation, où un nom qui est un mot courant devient « <modèle> ».
            """)

    @Argument(help: "Un fichier WAV par tour de la personne, dans l'ordre.")
    var wavs: [String] = []

    @Option(name: .long, help: "Le modèle rapide, qui mène les tours (nom tel que le service le connaît).")
    var fastModel: String

    @Option(name: .long, help: "Le modèle fort, qui rédige le prompt à la conclusion.")
    var strongModel: String

    @Option(name: .long, help: "Le modèle de voix du service (avec --voice). Sans eux, la voix du système.")
    var voiceModel: String?

    @Option(name: .long, help: "L'identifiant de la voix du service (avec --voice-model).")
    var voice: String?

    /// 8 questions : le défaut des réglages de l'application (`InterviewSettings.maxQuestions`, code lu).
    @Option(name: .long, help: "Nombre de questions au plus avant que l'entretien se conclue de lui-même.")
    var maxQuestions = 8

    @Option(name: .long, help: "Pousse chaque tour suivant ce nombre de secondes après le début de la lecture de la réplique : une interruption.")
    var interruptAfter: Double?

    /// 0,5 s : le défaut des réglages de l'application (`InterviewSettings.turnSilence`, code lu).
    @Option(name: .long, help: "Silence qui ferme un tour pour le détecteur de voix, en secondes (0,3 à 2,0).")
    var turnSilence = 0.5

    @Option(name: .long, help: "Fichier du rapport (Markdown). Sans lui, le rapport est écrit sur la sortie standard.")
    var output: String?

    @Flag(name: .long, help: "Remplace le fichier du rapport s'il existe (sinon la commande refuse).")
    var overwrite = false

    static let language = "fr"
    /// Les bornes du silence de fin de tour : 0,3 à 2,0 s, celles des réglages de l'application (`InterviewSettings.turnSilenceRange`,
    /// code lu ; le banc ne dépend pas de l'application, donc la valeur est recopiée). Le silence poussé après chaque tour suit la
    /// valeur choisie (`WavTurnFeed.trailingSilence(detectorSilence:blockSeconds:)`).
    static let turnSilenceRange: ClosedRange<Double> = 0.3...2.0
    /// Seuil d'interruption : 0,30 s de voix à −30 dB pleine échelle ; valeurs par défaut des réglages de l'application
    /// (`InterviewSettings`, code lu), non confirmées sur le matériel.
    static let interruptMinDuration = 0.30
    static let interruptLevel = -30.0
    /// Secondes entre deux vérifications du chien de garde : 3 600, choix non mesuré ; il n'a aucune tranche à surveiller (voir `watchdog`).
    static let watchdogPoll = 3_600.0

    /// Le chien de garde du micro **ne peut pas se déclencher** : le `WavTurnFeed` ne livre aucune tranche pendant que le modèle réfléchit
    /// et que la réplique « joue », alors qu'un vrai micro en livre toujours, et le chien de garde de l'application (1 s sans tranche)
    /// ferait échouer l'entretien sur `.microphone("silent")`. Un délai infini ne s'écoule jamais.
    static func watchdog(sleep: @escaping @Sendable (Double) async throws -> Void) -> MicrophoneWatchdog {
        MicrophoneWatchdog(timeout: .infinity, firstChunkTimeout: .infinity, pollInterval: watchdogPoll, sleep: sleep)
    }

    /// La configuration de l'entretien. Le délai de transcription est celui du moteur (`ConversationConfig.transcriptionTimeout`, sa
    /// valeur par défaut), jamais recopié.
    static func conversationConfig(fastModel: String, strongModel: String, maxQuestions: Int) -> ConversationConfig {
        ConversationConfig(
            fastModel: fastModel, strongModel: strongModel, maxQuestions: maxQuestions, template: "", language: language,
            vocabulary: [], interruptMinDuration: interruptMinDuration, interruptLevel: interruptLevel)
    }

    /// Marge ajoutée au délai de transcription du moteur : 30 s, choix non mesuré.
    static let reactionMargin = 30.0

    /// Le délai au bout duquel un tour sans réaction est noté « sans réaction » : celui de transcription du moteur, plus la marge. Il
    /// doit lui rester supérieur : un moteur lent mais dans son droit (transcription encore sous son délai) ne fait pas partir le tour
    /// suivant, et une transcription qui dépasse son délai tombe en panne (`.failed`) avant lui.
    static func reactionTimeout(for config: ConversationConfig) -> Double {
        config.transcriptionTimeout + reactionMargin
    }

    func run() async throws {
        try await run(runtime: .live)
    }

    func run(runtime: InterviewRuntime) async throws {
        // Tout ce qui peut être refusé l'est avant de lire un fichier, de charger un modèle et de faire une requête.
        try checkArguments()
        let endpoint: EndpointConfig
        do {
            endpoint = try EndpointConfig.fromEnvironment(runtime.environment)
        } catch EndpointError.missingVariable {
            throw InterviewError.missingEndpoint
        }
        let redact = interviewRedactor(endpoint, names: [fastModel, strongModel, voiceModel, voice].compactMap { $0 })
        let say: @Sendable (String) -> Void = { runtime.say(redact($0)) }
        let warn: @Sendable (String) -> Void = { runtime.warn(redact($0)) }
        let reportFile = output.map { URL(fileURLWithPath: $0) }
        if let reportFile {
            try OutputGuard.checkIgnoredByGit(
                reportFile.deletingLastPathComponent(),
                content: "ce rapport contient ce que tu as dit (transcriptions) et les réponses du modèle")
            try OutputGuard.checkNotExisting([reportFile], overwrite: overwrite)
        }

        let turns = try wavs.map(Self.loadTurn)
        say("\(turns.count) fichier(s) WAV : \(turns.map { Reports.decimal($0.duration, digits: 1) + " s" }.joined(separator: ", ")).")

        let engines = runtime.makeEngines(
            InterviewSetup(endpoint: endpoint, voiceModel: voiceModel, voice: voice, turnSilence: turnSilence))
        // Le silence poussé après chaque tour couvre les blocs dont le détecteur a besoin pour fermer le passage ; la durée d'un bloc
        // est celle du détecteur (`blockSize` à 16 kHz), pas une valeur recopiée.
        let trailing = WavTurnFeed.trailingSilence(
            detectorSilence: turnSilence, blockSeconds: Double(engines.detector.blockSize) / transcriberSampleRate)
        let feed = WavTurnFeed(turns: turns, trailingSilence: trailing, wait: runtime.wait, now: runtime.now)
        let fast = SignalRecordingModel(engines.fast)
        // 1 000 000 s (onze jours), choix non mesuré : une attente qui ne se termine qu'à l'annulation de sa tâche.
        let never: @Sendable (Double) async throws -> Void = { _ in try await Task.sleep(for: .seconds(1_000_000)) }
        // Sans aperçu : le passage est poussé d'un coup, un aperçu toutes les secondes ne montrerait rien et chargerait le moteur de
        // transcription pendant la mesure (son attente ne revient jamais). La limite de temps d'une transcription, elle, est réelle.
        let config = Self.conversationConfig(fastModel: fastModel, strongModel: strongModel, maxQuestions: maxQuestions)
        let session = ConversationSession(
            audio: feed, detector: engines.detector, transcriber: engines.transcriber, fastModel: fast, strongModel: engines.strong,
            voice: engines.voice,
            config: config, watchdog: Self.watchdog(sleep: runtime.watchdogSleep), now: runtime.now, sleep: never,
            transcriptionSleep: runtime.transcriptionSleep)

        let trace = await InterviewDriver.run(
            engine: session, feed: feed, interruptAfter: interruptAfter, reactionTimeout: Self.reactionTimeout(for: config),
            wait: runtime.wait, now: runtime.now,
            observe: runtime.observe, progress: say)
        withExtendedLifetime(session) {}

        let report = InterviewReport(
            launchedAt: runtime.launchedAt, turnCount: turns.count, trace: trace, signals: fast.recorded, maxQuestions: maxQuestions,
            turnSilence: turnSilence, interruptAfter: interruptAfter,
            voiceDescription: voiceModel != nil
                ? "celle du fournisseur, avec repli sur la voix du système" : "celle du système")
        let markdown = redact(report.markdown())
        if let reportFile {
            try FileManager.default.createDirectory(at: reportFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try markdown.write(to: reportFile, atomically: true, encoding: .utf8)
            say("")
            say("Fin : \(report.endReason).")
            if let prompt = report.prompt { say("Prompt :\n\n\(prompt)\n") }
            say("Rapport : \(reportFile.path)")
        } else {
            say("")
            say(markdown)
        }
        if !report.succeeded {
            warn("L'entretien n'a pas rendu de prompt : \(report.endReason).")
            throw ExitCode.failure
        }
    }

    /// Les contrôles des arguments, sans rien lire ni rien demander à l'environnement.
    private func checkArguments() throws {
        guard !wavs.isEmpty else { throw InterviewError.noWav }
        if voice != nil, voiceModel == nil { throw InterviewError.voiceNeedsVoiceModel }
        if voiceModel != nil, voice == nil { throw InterviewError.voiceModelNeedsVoice }
        // Jamais le rapport sur un fichier d'entrée, `--overwrite` ou non : il serait lu au départ, puis écrasé à la fin. Ce sont les
        // fichiers qui sont comparés, pas leurs chemins (`OutputGuard.isSameFile`) : un lien physique, une autre casse sur un volume qui
        // l'ignore, `/var` et `/private/var` désignent le même fichier sous des chemins différents.
        if let output {
            let target = URL(fileURLWithPath: output)
            for path in wavs {
                let input = URL(fileURLWithPath: path)
                if OutputGuard.isSameFile(input, target) {
                    throw InterviewError.outputIsAnInput(input.standardizedFileURL.resolvingSymlinksInPath().lastPathComponent)
                }
            }
        }
        guard maxQuestions >= 1 else { throw InterviewError.invalidOption("--max-questions doit être au moins 1.") }
        if let interruptAfter, !(interruptAfter.isFinite && interruptAfter > 0) {
            throw InterviewError.invalidOption("--interrupt-after doit être un nombre de secondes positif.")
        }
        guard turnSilence.isFinite, Self.turnSilenceRange.contains(turnSilence) else {
            let bounds = Self.turnSilenceRange
            throw InterviewError.invalidOption(
                "--turn-silence doit être compris entre \(Reports.decimal(bounds.lowerBound, digits: 1)) et "
                    + "\(Reports.decimal(bounds.upperBound, digits: 1)) secondes (les bornes des réglages de l'application).")
        }
    }

    /// Un fichier WAV lu et ramené à 16 kHz, comme le font les autres commandes du banc.
    static func loadTurn(_ path: String) throws -> AudioClip {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let clip: AudioClip
        do {
            clip = Resampler.resample(try WavFile.read(URL(fileURLWithPath: path)), to: transcriberSampleRate)
        } catch {
            throw InterviewError.unreadableWav(name: name, reason: describe(error))
        }
        guard !clip.samples.isEmpty else { throw InterviewError.emptyWav(name) }
        return clip
    }
}
