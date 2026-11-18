import Foundation
import Testing

/// Contrôles par recherche dans les sources du dépôt, lancés avec la suite.
///
/// Ces gardes sont des filets contre la maladresse (une écriture naturelle ou voisine qui échappe à la relecture), pas contre une
/// écriture délibérée : un alias de type, une chaîne composée ou une variable intermédiaire passent. Chaque motif est épinglé par
/// des tests de forme (ce qu'il attrape, et une forme innocente proche qu'il laisse).
@Suite(.timeLimit(.minutes(1))) struct SourceScanTests {
    /// Racine du dépôt, retrouvée depuis ce fichier (`Tests/SupervoxCoreTests/`).
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Lignes de code (commentaires exclus) des fichiers `.swift` sous `folder`, avec leur emplacement.
    private static func codeLines(under folder: String) throws -> [(place: String, line: String)] {
        let base = root.appendingPathComponent(folder, isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty, "aucun fichier Swift sous \(folder)")
        return try files.flatMap { file in
            try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
                .enumerated()
                .filter { !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .map { (place: "\(file.path.dropFirst(base.path.count + 1)):\($0.offset + 1)", line: $0.element) }
        }
    }

    /// Texte des fichiers `.swift` sous `folder`, commentaires de ligne retirés, avec leur chemin relatif.
    private static func sources(under folder: String) throws -> [(place: String, code: String)] {
        let base = root.appendingPathComponent(folder, isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        try #require(!files.isEmpty, "aucun fichier Swift sous \(folder)")
        return try files.map { file in
            let code = try String(contentsOf: file, encoding: .utf8)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            return (place: String(file.path.dropFirst(base.path.count + 1)), code: code)
        }
    }

    /// m6 : le programme de l'application règle le journal de la bibliothèque audio (le texte transcrit n'y est pas écrit)
    /// avant de construire les moteurs.
    @Test func theApplicationQuietsTheAudioLibraryLoggerBeforeBuildingTheEngines() throws {
        let main = try #require(Self.sources(under: "Sources/Supervox").first { $0.place == "main.swift" })
        let quiet = try #require(main.code.range(of: "EngineLogging.keepTranscriptsOutOfLogs()"))
        let engines = try #require(main.code.range(of: "LiveDictationEngines()"))
        #expect(quiet.lowerBound < engines.lowerBound)
    }

    /// Amendement A de la tâche 9 : le son réel et la voix du système ne sont construits que par le programme (`main.swift`), hors de
    /// leur fichier de définition. Tests, outil de rendu et constructeurs par défaut n'en ont pas (`InterviewEnvironment.unavailable`).
    /// Les tests du cœur (`Tests/SupervoxCoreTests`) en ont le droit : leurs essais sur le matériel sont gardés par une variable
    /// d'environnement (`SUPERVOX_MIC`, `SUPERVOX_SPEAKER`, `SUPERVOX_SPEECH`), et `LiveAudioIO(device:)` y reçoit un double.
    static let realAudioOrSystemVoice = #"\b(?:LiveAudioIO|SystemSpeechSynthesizer)"# + construction
    /// Ce qui suit le nom du type quand on le construit : `(`, `.init`, `.self.init`, ou `= .init` (`let io: LiveAudioIO = .init()`),
    /// y compris par un type déclaré optionnel ou implicitement déballé (`LiveAudioIO? = .init()`, `! = .init()`).
    static let construction = #"\s*(?:\(|\.\s*init\b|\.\s*self\s*\.\s*init\b|[?!]?\s*=\s*\.\s*init\b)"#

    @Test func theRealSoundAndTheSystemVoiceAreBuiltOnlyByTheProgram() throws {
        let pattern = try Regex(Self.realAudioOrSystemVoice)
        let allowed: Set<String> = [
            "Supervox/main.swift", "SupervoxCore/Audio/AudioIO.swift", "SupervoxCore/Speech/SystemSpeechSynthesizer.swift",
        ]
        let sources = try Self.sources(under: "Sources")
        let main = try #require(sources.first { $0.place == "Supervox/main.swift" })
        #expect(main.code.contains(pattern), "le balayage doit voir le programme les construire")
        // Le banc est un programme lui aussi : sa commande `interview` construit la voix du système dans sa fabrique de vrais moteurs
        // (`InterviewEngines.real`), jamais le son réel : son seul `AudioIO` est `WavTurnFeed`, qui simule la lecture. Les tests du banc
        // ne font que construire cette fabrique (le constructeur de la voix range deux fermetures, code lu) ; ils ne la font pas parler.
        let benchVoice = "SupervoxBench/InterviewCommand.swift"
        let realAudio = try Regex(#"\bLiveAudioIO"# + Self.construction)
        let offending = sources
            .filter { !allowed.contains($0.place) && $0.code.contains(pattern) }
            .filter { $0.place != benchVoice || $0.code.contains(realAudio) }
            .map(\.place)
        #expect(offending.isEmpty, "\(offending)")
        let bench = try #require(sources.first { $0.place == benchVoice })
        #expect(bench.code.contains(pattern), "le balayage doit voir le banc construire la voix du système")
        let tests = try Self.sources(under: "Tests")
            .filter { !$0.place.hasPrefix("SupervoxCoreTests/") && $0.code.contains(pattern) }
            .map(\.place)
        #expect(tests.isEmpty, "\(tests)")
    }

    @Test(arguments: [
        "LiveAudioIO()", "LiveAudioIO ( )", "LiveAudioIO.init()", "SystemSpeechSynthesizer(language: \"fr-FR\")",
        "SystemSpeechSynthesizer . init(language: x)", "{ LiveAudioIO() }",
        // m-F : les formes par le type déclaré et par `.self`.
        "let io: LiveAudioIO = .init()", "let v: SystemSpeechSynthesizer = .init(language: l)", "LiveAudioIO.self.init()",
        "let io: LiveAudioIO? = .init()",
        "SystemSpeechSynthesizer.self.init(language: l)",
    ])
    func theRealSoundPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.realAudioOrSystemVoice)))
    }

    @Test func theRealSoundPatternLeavesOrdinaryUsesAlone() throws {
        let pattern = try Regex(Self.realAudioOrSystemVoice)
        for code in [
            "let io: LiveAudioIO", "ScriptedAudioIO()", "public final class LiveAudioIO: AudioIO {", "MyLiveAudioIO()",
            "makeSystemVoice: { made.systemVoice($0) }", "x is SystemSpeechSynthesizer",
            // m-F : formes proches et innocentes (une référence au type, une valeur qui n'est pas construite ici).
            "let io: LiveAudioIO = makeAudio()", "ObjectIdentifier(LiveAudioIO.self)", "let v: SystemSpeechSynthesizer = voice",
        ] {
            #expect(!code.contains(pattern), "\(code)")
        }
    }

    /// Formes interdites hors de `EndpointSession.swift` : la session partagée, quelle que soit la coupure de ligne
    /// (`URLSession.shared`, `session: .shared`, `URLSession = .shared`), et toute session construite à la main
    /// (`URLSession(`), qui pourrait recevoir une configuration avec cache.
    static let forbiddenSession =
        #"URLSession\s*\.\s*shared|session\s*:\s*\.shared\b|URLSession\s*=\s*\.shared\b|URLSession\s*\("#
        + #"|URLSession\s*\.\s*init\b|URLSession\s*=\s*\.\s*init\b"#

    /// C1 : la session partagée garde les réponses dans le cache disque. Toute requête vers un point d'accès passe
    /// par `EndpointSession`, seul fichier autorisé à construire une session.
    @Test func noSourceBuildsOrSharesAURLSessionOutsideEndpointSession() throws {
        let pattern = try Regex(Self.forbiddenSession)
        let offending = try Self.sources(under: "Sources")
            .filter { !$0.place.hasSuffix("Endpoint/EndpointSession.swift") && $0.code.contains(pattern) }
        #expect(offending.isEmpty, "\(offending.map(\.place))")
    }

    /// Le motif voit les écritures voisines, y compris coupées sur deux lignes.
    @Test(arguments: [
        "let s = URLSession.shared", "let s = URLSession\n    .shared", "call(session: .shared)",
        "init(session: URLSession = .shared)", "URLSession(configuration: .default)", "URLSession (configuration: c)",
        // m-F : la construction par `.init`, directe ou par le type déclaré.
        "URLSession.init(configuration: c)", "let s: URLSession = .init(configuration: c)",
    ])
    func theForbiddenPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.forbiddenSession)))
    }

    @Test func theForbiddenPatternLeavesOrdinaryUsesAlone() throws {
        let pattern = try Regex(Self.forbiddenSession)
        for code in [
            "let session: URLSession", "session: URLSession = EndpointSession.shared", "URLSessionTaskMetrics",
            // m-F : formes proches et innocentes.
            "URLSessionConfiguration.init()", "let s: URLSession = EndpointSession.make()",
        ] {
            #expect(!code.contains(pattern), "\(code)")
        }
    }

    /// Les serveurs des tests n'écoutent que sur la boucle locale : tout écouteur passe par `NWListener.loopbackOnly()`.
    @Test func testServersListenThroughTheLoopbackFactory() throws {
        let needle = "NWListener" + "("  // en deux morceaux : cette ligne ne se trouve pas elle-même
        let offending = try Self.codeLines(under: "Tests")
            .filter { $0.line.contains(needle) && !$0.place.hasPrefix("SupervoxCoreTests/LocalHTTPServer.swift:") }
        #expect(offending.isEmpty, "\(offending.map(\.place))")
    }

    /// Un `TextInserter` du système (presse-papiers général, ⌘V réel) n'est construit que par la cible `Supervox`, le programme :
    /// `AppController` reçoit son `inserter` de l'extérieur, sans valeur par défaut, et aucun test ne le construit. Formes
    /// interdites ailleurs, quelles que soient les espaces et la coupure de ligne : une valeur par défaut `= .system(` ou
    /// `= TextInserter.system(`, un argument `inserter: .system(` ou `inserter: TextInserter.system(`, et tout appel
    /// `TextInserter.system(`.
    static let forbiddenSystemInserter =
        #"(=|inserter\s*:)\s*(TextInserter\s*)?\.\s*system\s*\(|TextInserter\s*\.\s*system\s*\("#

    @Test func onlyTheSupervoxTargetBuildsTheSystemInserter() throws {
        let pattern = try Regex(Self.forbiddenSystemInserter)
        let offending = try Self.sources(under: "Sources")
            .filter { !$0.place.hasPrefix("Supervox/") && $0.code.contains(pattern) }
        #expect(offending.isEmpty, "\(offending.map(\.place))")
    }

    /// Les tests ne construisent jamais l'insertion du système : un collage fautif viserait le vrai presse-papiers.
    @Test func noTestBuildsTheSystemInserter() throws {
        let pattern = try Regex(Self.forbiddenSystemInserter)
        let offending = try Self.sources(under: "Tests")
            .filter { !$0.place.hasSuffix("SourceScanTests.swift") && $0.code.contains(pattern) }
        #expect(offending.isEmpty, "\(offending.map(\.place))")
    }

    @Test(arguments: [
        "inserter: TextInserter = .system()", "inserter: TextInserter = TextInserter.system()",
        "inserter: TextInserter =\n    .system()", "= .system (", "x = TextInserter . system(",
        "inserter: .system()", "inserter : .system ()", "inserter:\n    .system()", "inserter: TextInserter.system()",
        "inserter: TextInserter\n    .system()", "dictation: dictation, inserter: .system())",
        "let i = TextInserter.system()", "return TextInserter\n.system()",
    ])
    func theSystemInserterPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.forbiddenSystemInserter)))
    }

    @Test func theSystemInserterPatternLeavesOrdinaryUsesAlone() throws {
        let pattern = try Regex(Self.forbiddenSystemInserter)
        for code in [
            "inserter: rig.inserter)", "inserter: TextInserter,", "let system = SystemPermissions()",
            "public static func system() -> TextInserter {", "inserter: InsertionRig().inserter)",
            "let inserter: TextInserter",
        ] {
            #expect(!code.contains(pattern), "\(code)")
        }
    }

    /// Aucun test ne touche le presse-papiers général : ni `SystemPasteboard()` (qui prend `NSPasteboard.general`), ni
    /// `NSPasteboard.general`, ni `SystemPasteboard(board: .general)` (l'initialiseur interne, atteignable par `@testable`).
    /// Les essais d'intégration passent par un presse-papiers nommé (`SystemPasteboard(board:)`).
    static let forbiddenGeneralPasteboard =
        #"SystemPasteboard\s*\(\s*\)|NSPasteboard\s*\.\s*general|board\s*:\s*\.\s*general\b"#

    @Test func noTestTouchesTheGeneralPasteboard() throws {
        let pattern = try Regex(Self.forbiddenGeneralPasteboard)
        let offending = try Self.sources(under: "Tests")
            .filter { !$0.place.hasSuffix("SourceScanTests.swift") && $0.code.contains(pattern) }
        #expect(offending.isEmpty, "\(offending.map(\.place))")
    }

    @Test(arguments: [
        "let p = SystemPasteboard()", "SystemPasteboard ( )", "NSPasteboard.general", "NSPasteboard\n    .general",
        "SystemPasteboard(board: .general)", "SystemPasteboard(board:.general)", "SystemPasteboard(\n    board : . general)",
        "let b = SystemPasteboard(board: NSPasteboard.general)",
    ])
    func theGeneralPasteboardPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.forbiddenGeneralPasteboard)))
    }

    @Test func theGeneralPasteboardPatternLeavesANamedBoardAlone() throws {
        let pattern = try Regex(Self.forbiddenGeneralPasteboard)
        for code in [
            "SystemPasteboard(board: board)", "NSPasteboard(name: .init(\"x\"))", "board.name != .general",
            "SystemPasteboard(board: named)", "let generalBoard = 1", "board: .generalised",
        ] {
            #expect(!code.contains(pattern), "\(code)")
        }
    }

    /// Un message montré dans le panneau ne passe jamais par le texte brut d'une erreur quelconque (`String(describing:)`,
    /// interpolation de l'erreur) : une erreur système y met une adresse de service, un chemin ou une clé. Les chemins qui
    /// fabriquent ces messages : la capture audio, la session de dictée, la réécriture par le modèle et le contrôleur de dictée.
    static let forbiddenErrorText = #"String\s*\(\s*describing\s*:\s*error\s*\)|\\\(\s*error\s*\)|\\\(\s*String\s*\(\s*describing\s*:\s*error"#

    @Test func noPanelMessageCarriesTheRawTextOfAnError() throws {
        let pattern = try Regex(Self.forbiddenErrorText)
        let folders = [
            "Sources/SupervoxCore/Audio", "Sources/SupervoxCore/Speech", "Sources/SupervoxCore/Dictation", "Sources/SupervoxCore/Language", "Sources/SupervoxApp/Dictation",
            "Sources/SupervoxApp/Language", "Sources/SupervoxCore/Conversation", "Sources/SupervoxApp/Interview",
        ]
        let offending = try folders.flatMap { folder in
            try Self.sources(under: folder).filter { $0.code.contains(pattern) }.map { "\(folder)/\($0.place)" }
        }
        #expect(offending.isEmpty, "\(offending)")
    }

    @Test(arguments: [
        "AudioCaptureError.engineFailed(String(describing: error))", "\"voice processing : \\(error)\"",
        "String ( describing : error )", "\"\\( error )\"",
    ])
    func theErrorTextPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.forbiddenErrorText)))
    }

    @Test func theErrorTextPatternLeavesOrdinaryUsesAlone() throws {
        let pattern = try Regex(Self.forbiddenErrorText)
        for code in ["catch { fail(.engine(Self.describe(error))) }", "\"le moteur audio a échoué (\\(message))\"", "error as? AudioCaptureError"] {
            #expect(!code.contains(pattern), "\(code)")
        }
    }

    /// Une ligne de journal de la couche de mise en forme de l'application n'interpole que la nature d'une panne
    /// (`kind(of:)`) : jamais la panne elle-même (`\(failure)`, qui porterait le nom du fournisseur), le travail, la consigne ni
    /// le texte. Toute interpolation d'une ligne `log.` autre que `kind(of:` est refusée.
    static let forbiddenLogInterpolation = #"\blog\s*\.\s*\w+\s*\(.*\\\((?!\s*(?:self\s*\.\s*)?kind\s*\(\s*of\s*:)"#

    @Test func theRewritingLayerLogsOnlyTheKindOfAFailure() throws {
        let pattern = try Regex(Self.forbiddenLogInterpolation)
        let sources = try Self.sources(under: "Sources/SupervoxApp/Language")
        let logged = sources.filter { $0.code.contains("log.notice") }
        #expect(!logged.isEmpty, "le balayage doit voir au moins une ligne de journal")
        let offending = sources.filter { $0.code.contains(pattern) }.map(\.place)
        #expect(offending.isEmpty, "\(offending)")
    }

    @Test(arguments: [
        #"log.notice("mise en forme échouée : \(failure)")"#, #"log.notice("\(job.input)")"#, #"log.error("x \(error, privacy: .public)")"#,
        #"log . notice ( "\(provider.name)" )"#, #"log.notice("\(self.view.lastReply)")"#, #"log.notice("\(self.kindOf(end))")"#,
    ])
    func theLogInterpolationPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.forbiddenLogInterpolation)))
    }

    @Test func theLogInterpolationPatternLeavesTheKindAlone() throws {
        let pattern = try Regex(Self.forbiddenLogInterpolation)
        for code in [
            #"log.notice("mise en forme échouée : \(kind(of: failure), privacy: .public)")"#, #"log.notice("fini")"#,
            #"log.notice("entretien fini : \(self.kind(of: end), privacy: .public)")"#,
            #"let kind = String(describing: failure)"#,
        ] {
            #expect(!code.contains(pattern), "\(code)")
        }
    }

    /// m11 : les noms de moteur enregistrés (`"whisperkit"`, `"parakeet"`) ne sont écrits qu'à un endroit,
    /// `Settings/TranscriptionSettings.swift` (le type `TranscriptionEngine`) ; le reste de l'application et du programme compare
    /// des cas, jamais des chaînes. Le fichier d'origine doit bien porter `"whisperkit"` (`parakeet` y prend son nom de cas : le
    /// littéral n'y figure pas), sans quoi le balayage ne vérifierait rien.
    static let engineNames = ["\"whisperkit\"", "\"parakeet\""]

    @Test func engineNamesAreSpelledOnlyInTranscriptionSettings() throws {
        let home = "SupervoxApp/Settings/TranscriptionSettings.swift"
        let app = try Self.sources(under: "Sources/SupervoxApp").map { (place: "SupervoxApp/" + $0.place, code: $0.code) }
        let program = try Self.sources(under: "Sources/Supervox").map { (place: "Supervox/" + $0.place, code: $0.code) }
        let all = app + program
        let origin = try #require(all.first { $0.place == home })
        #expect(origin.code.contains("\"whisperkit\""), "\"whisperkit\" absent de \(home)")
        let offending = all.filter { $0.place != home }
            .flatMap { source in Self.engineNames.filter { source.code.contains($0) }.map { "\(source.place) : \($0)" } }
        #expect(offending.isEmpty, "\(offending)")
    }

    /// m5 : le texte brut d'une erreur (`localizedDescription`) peut porter une adresse, un chemin ou une clé ; il n'est jamais
    /// montré par le modèle de l'onglet Transcription ni construit par la couche de langage. Un contrôle qui ne lirait rien ne
    /// vérifierait rien : le fichier est bien là.
    @Test func noRawErrorTextInTheTranscriptionModelNorTheLanguageLayer() throws {
        let app = try Self.sources(under: "Sources/SupervoxApp")
        let model = try #require(app.first { $0.place == "SettingsUI/TranscriptionModel.swift" })
        #expect(!model.code.contains("localizedDescription"), "SettingsUI/TranscriptionModel.swift")
        let language = try Self.sources(under: "Sources/SupervoxCore/Language")
            + Self.sources(under: "Sources/SupervoxApp/Language").map { (place: "SupervoxApp/Language/" + $0.place, code: $0.code) }
        #expect(!language.isEmpty)
        let offending = language.filter { $0.code.contains("localizedDescription") }.map(\.place)
        #expect(offending.isEmpty, "\(offending)")
    }

    // MARK: - Aucun texte d'erreur du système montré ni journalisé (tâche 5)

    /// L'accès au texte d'erreur du système, sous toutes ses écritures : `error.localizedDescription`, `(error as NSError).…`,
    /// `\(error.localizedDescription, privacy: .public)`, avec espaces ou retour à la ligne devant le point, par chemin de clé
    /// (`map(\.localizedDescription)`) ou nu (dans une extension d'`Error`). Ni `\b` (la limite de mot d'Unicode ne coupe pas
    /// entre `.` et une lettre) ni lookbehind (`Regex` ne le gère pas) : un caractère qui n'est pas d'identifiant devant (ou le
    /// début du texte), et une borne derrière. Un autre identifiant qui le contient (`NSLocalizedDescriptionKey`,
    /// `localizedDescriptions`) n'est pas cet accès.
    static let systemErrorText = #"(?:^|[^A-Za-z0-9_])localizedDescription(?![A-Za-z0-9_])"#

    /// Les deux SEULS endroits qui gardent `localizedDescription` : le texte brut d'une panne de transport (`URLError`, …) n'est
    /// jamais montré tel quel, il est masqué (`errorBody`, `masked` : adresse, clé retirées) avant d'aller plus loin dans
    /// `EndpointError.transport`, que les écrans ne montrent que par une phrase fixe (`ProvidersModel.message(for:)`).
    static let endpointTransportSites: Set<String> = [
        "SupervoxCore/Endpoint/EndpointRequest.swift", "SupervoxCore/Endpoint/ModelListing.swift",
    ]

    /// Ni l'application (`Sources/SupervoxApp`) ni l'outil de rendu (`Sources/SupervoxSnapshots`) ne lisent le texte d'erreur du
    /// système : ni pour l'écran, ni pour le journal (un journal y met le TYPE de l'erreur). Hors de ces deux dossiers, seuls les
    /// deux sites de transport du cœur le gardent ; une panne de plus ailleurs (cœur, banc d'essai) doit être décidée ici, nommée
    /// avec sa raison. Le balayage voit les fichiers qui montrent les avis, et les deux sites de transport contiennent bien le
    /// motif (sans quoi un motif cassé ne verrait rien nulle part).
    @Test func theRawSystemErrorTextIsOnlyKeptByTheTwoEndpointTransportSites() throws {
        let pattern = try Regex(Self.systemErrorText)
        let all = try Self.sources(under: "Sources")
        for seen in [
            "SupervoxApp/AppController.swift", "SupervoxApp/SettingsUI/HotKeySettingsModel.swift",
            "SupervoxApp/SettingsUI/ProvidersModel.swift", "SupervoxSnapshots/main.swift",
        ] {
            #expect(all.contains { $0.place == seen }, "le balayage doit voir \(seen)")
        }
        let holding = Set(all.filter { $0.code.contains(pattern) }.map(\.place))
        #expect(Self.endpointTransportSites.isSubset(of: holding), "les sites de transport nommés gardent bien le motif : \(holding)")
        let offending = holding.subtracting(Self.endpointTransportSites).sorted()
        #expect(offending.isEmpty, "\(offending)")
    }

    @Test(arguments: [
        "panelModel.setNotice(error.localizedDescription, for: .save)", #"log.error("x \(error.localizedDescription, privacy: .public)")"#,
        "(error as NSError).localizedDescription", "error . localizedDescription", "error\n    .localizedDescription",
        #"errors.map(\.localizedDescription)"#, "self.localizedDescription", "return localizedDescription",
        "localizedDescription.isEmpty",
    ])
    func theSystemErrorTextPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.systemErrorText)))
    }

    @Test func theSystemErrorTextPatternLeavesOtherIdentifiersAlone() throws {
        let pattern = try Regex(Self.systemErrorText)
        for code in [
            "(error as? SettingsError)?.errorDescription", "SettingsError.sentence(forSaveError: error)",
            #"log.error("\(String(reflecting: type(of: error)), privacy: .public)")"#, "userInfo[NSLocalizedDescriptionKey]",
            "let myLocalizedDescription = 1", "let localizedDescriptions = [String]()", "var localizedDescriptionText = \"\"",
        ] {
            #expect(!code.contains(pattern), "\(code)")
        }
    }

    /// L'entretien (`Core/Conversation`) ne rend que des codes de panne et des phrases fixes : jamais le texte brut d'une erreur
    /// (`localizedDescription`), et aucun journal (le texte dit pourrait y passer). Ses rappels (`onChunk`, `onEnd`, `onText`) arrivent
    /// sur le fil que le système choisit : rien n'y suppose le fil principal. Le dossier doit bien contenir le moteur, sans quoi le
    /// balayage ne vérifierait rien.
    static let forbiddenLogging = #"\bLogger\s*\(|\bos_log\s*\(|\bprint\s*\(|\bNSLog\s*\(|\bdebugPrint\s*\("#

    @Test func theConversationEngineShowsNoRawErrorTextLogsNothingAndAssumesNoThread() throws {
        let sources = try Self.sources(under: "Sources/SupervoxCore/Conversation")
        #expect(sources.contains { $0.place == "ConversationChain.swift" }, "le balayage doit voir le moteur de l'entretien")
        let logging = try Regex(Self.forbiddenLogging)
        let mainThread = try Regex(Self.forbiddenMainThreadAssumption)
        let offending = sources.filter {
            $0.code.contains("localizedDescription") || $0.code.contains(logging) || $0.code.contains(mainThread)
        }.map(\.place)
        #expect(offending.isEmpty, "\(offending)")
    }

    /// La vue de l'entretien ne montre que des phrases fixes (`InterviewText`) : jamais le texte brut d'une erreur, et aucun journal
    /// (le texte dit pourrait y passer). Le balayage voit l'état, la table de phrases et la vue ; sans eux il ne vérifierait rien.
    /// Seul le contrôleur de l'entretien journalise, sous la règle de `theInterviewControllerLogsOnlyTheKindOfAnEvent`.
    @Test func theInterviewViewShowsNoRawErrorTextAndLogsNothing() throws {
        let state = try Self.sources(under: "Sources/SupervoxApp/Interview")
        #expect(state.contains { $0.place == "InterviewText.swift" }, "le balayage doit voir la table de phrases")
        #expect(state.contains { $0.place == "InterviewViewState.swift" }, "le balayage doit voir l'état de la vue")
        let view = try Self.sources(under: "Sources/SupervoxApp/Panel").filter { $0.place == "InterviewView.swift" }
        #expect(view.count == 1, "le balayage doit voir la vue de l'entretien")
        let logging = try Regex(Self.forbiddenLogging)
        let raw = (state + view).filter { $0.code.contains("localizedDescription") }.map(\.place)
        #expect(raw.isEmpty, "\(raw)")
        let logs = (state + view).filter { $0.place != "InterviewController.swift" && $0.code.contains(logging) }.map(\.place)
        #expect(logs.isEmpty, "\(logs)")
    }

    /// Règle 12 : une ligne de journal de `App/Interview` n'interpole que la nature d'une fin ou d'un refus (`kind(of:)`) : ni le
    /// texte dit, ni la réplique, ni le prompt, ni le nom d'un fournisseur.
    @Test func theInterviewControllerLogsOnlyTheKindOfAnEvent() throws {
        let pattern = try Regex(Self.forbiddenLogInterpolation)
        let sources = try Self.sources(under: "Sources/SupervoxApp/Interview")
        let controller = try #require(sources.first { $0.place == "InterviewController.swift" }, "le balayage doit voir le contrôleur")
        #expect(controller.code.contains("log.notice"), "le balayage doit voir au moins une ligne de journal")
        let offending = sources.filter { $0.code.contains(pattern) }.map(\.place)
        #expect(offending.isEmpty, "\(offending)")
    }

    /// Aucune annonce réelle du système dans la suite : l'annonce VoiceOver n'est postée que par `Panel/AccessibilityAnnouncing.swift`,
    /// que le contrôleur du panneau reçoit par `AccessibilityAnnouncing` (un double dans les tests). Aucun test ne nomme la
    /// réalisation du système. Toute construction d'`AppController` ou de `PanelController` dans les tests reçoit un annonceur
    /// (`theControllersBuiltByTestsReceiveAnAnnouncer`) : les tests qui lancent un entretien n'en postent aucune.
    @Test func theSystemAnnouncementIsPostedInOnePlaceAndNoTestNamesIt() throws {
        let sources = try Self.sources(under: "Sources/SupervoxApp")
        let home = try #require(sources.first { $0.place == "Panel/AccessibilityAnnouncing.swift" }, "le fichier de l'annonce a disparu")
        #expect(home.code.contains("AccessibilityNotification"))
        let offending = sources.filter { $0.place != "Panel/AccessibilityAnnouncing.swift" && $0.code.contains("AccessibilityNotification") }.map(\.place)
        #expect(offending.isEmpty, "\(offending)")
        let tests = try Self.sources(under: "Tests")
            .filter { !$0.place.hasSuffix("SourceScanTests.swift") && ($0.code.contains("AccessibilityNotification") || $0.code.contains("SystemAccessibilityAnnouncer")) }
            .map(\.place)
        #expect(tests.isEmpty, "\(tests)")
    }

    /// Les arguments d'un appel, de la parenthèse ouvrante à la fermante qui lui répond (le code des tests est bien formé).
    private static func callArguments(in code: String, from open: String.Index) -> Substring {
        var depth = 0
        var index = open
        while index < code.endIndex {
            switch code[index] {
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return code[open...index] }
            default: break
            }
            index = code.index(after: index)
        }
        return code[open...]
    }

    /// Chaque `AppController(…)` ou `PanelController(…)` construit par un test reçoit `announcer:` : sans lui, le défaut est
    /// l'annonceur du système, et un test qui pose un entretien posterait une vraie annonce VoiceOver.
    @Test func theControllersBuiltByTestsReceiveAnAnnouncer() throws {
        let construction = try Regex(#"\b(?:AppController|PanelController)\s*\("#)
        var seen = 0
        var offending: [String] = []
        for file in try Self.sources(under: "Tests") where !file.place.hasSuffix("SourceScanTests.swift") {
            for match in file.code.matches(of: construction) {
                seen += 1
                let open = file.code.index(before: match.range.upperBound)
                if !Self.callArguments(in: file.code, from: open).contains("announcer:") { offending.append(file.place) }
            }
        }
        #expect(seen >= 10, "le balayage doit voir les constructions des tests (\(seen))")
        #expect(offending.isEmpty, "\(offending)")
    }

    @Test func theAnnouncerScanSeesAConstructionWithoutAnnouncer() throws {
        let code = "let c = AppController(settingsStore: store, inserter: rig.inserter)\nlet d = PanelController(model: m, announcer: a)"
        let construction = try Regex(#"\b(?:AppController|PanelController)\s*\("#)
        let calls = code.matches(of: construction).map {
            Self.callArguments(in: code, from: code.index(before: $0.range.upperBound)).contains("announcer:")
        }
        #expect(calls == [false, true])
    }

    @Test(arguments: [
        "let log = Logger(subsystem: \"x\", category: \"y\")", "os_log(\"%@\", text)", "print(turn.text)", "NSLog(\"%@\", text)",
        "debugPrint (reply)",
    ])
    func theLoggingPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.forbiddenLogging)))
    }

    @Test func theLoggingPatternLeavesOrdinaryUsesAlone() throws {
        let pattern = try Regex(Self.forbiddenLogging)
        for code in ["let footprint = 1", "func blueprint() {}", "emit(.notice(.notUnderstood))", "let logger = self.log"] {
            #expect(!code.contains(pattern), "\(code)")
        }
    }

    /// Les identifiants de mode fixes (`ModeChip.rawID`, `cleanedID`, `interviewID`) ne sont écrits qu'à un endroit, dans
    /// `Panel/PanelModel.swift` : le reste de l'application les nomme par ces constantes. (`"prompt"`, trop courant, n'est pas
    /// balayé.) Le fichier d'origine doit bien les porter, sans quoi le balayage ne vérifierait rien.
    static let modeIdentifiers = ["\"dictee-brute\"", "\"dictee-nettoyee\"", "\"entretien\""]

    @Test func fixedModeIdentifiersAreSpelledOnlyInPanelModel() throws {
        let sources = try Self.sources(under: "Sources/SupervoxApp")
        let home = try #require(sources.first { $0.place == "Panel/PanelModel.swift" })
        for literal in Self.modeIdentifiers {
            #expect(home.code.contains(literal), "\(literal) absent de Panel/PanelModel.swift")
        }
        let offending = sources.filter { $0.place != "Panel/PanelModel.swift" }
            .flatMap { source in Self.modeIdentifiers.filter { source.code.contains($0) }.map { "\(source.place) : \($0)" } }
        #expect(offending.isEmpty, "\(offending)")
    }

    /// I1 : les rappels de `AVSpeechSynthesizer` arrivent sur le fil que le système choisit ; rien dans la couche de voix ne suppose
    /// le fil principal (`MainActor.assumeIsolated` planterait ailleurs). Ils copient et poussent dans un flux.
    static let forbiddenMainThreadAssumption = #"assumeIsolated|MainActor\s*\.\s*run\b|DispatchQueue\s*\.\s*main\s*\.\s*(sync|async)"#

    @Test func noSpeechCodeAssumesTheCallbackThread() throws {
        let pattern = try Regex(Self.forbiddenMainThreadAssumption)
        let sources = try Self.sources(under: "Sources/SupervoxCore/Speech")
        #expect(sources.contains { $0.place == "AVSpeechBufferSource.swift" }, "le balayage doit voir la couche système")
        let offending = sources.filter { $0.code.contains(pattern) }.map(\.place)
        #expect(offending.isEmpty, "\(offending)")
    }

    @Test(arguments: [
        "MainActor.assumeIsolated { onBuffer(buffer) }", "MainActor\n    .assumeIsolated {", "MainActor . run { x }",
        "DispatchQueue.main.async { }", "DispatchQueue . main . sync { }",
    ])
    func theMainThreadAssumptionPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.forbiddenMainThreadAssumption)))
    }

    @Test func theMainThreadAssumptionPatternLeavesOrdinaryUsesAlone() throws {
        let pattern = try Regex(Self.forbiddenMainThreadAssumption)
        for code in ["@MainActor final class AVSpeechBufferSource", "Task { @MainActor in }", "let mainQueue = 1", "events.yield(.end)"] {
            #expect(!code.contains(pattern), "\(code)")
        }
    }
    /// Tâche 10 : l'onglet Entretien ne recopie aucune borne. Ni la vue ni le modèle n'écrivent de plage littérale (`0.3...2.0`,
    /// `1...20`) : le modèle lit celles de `InterviewSettings`, la vue celles du modèle.
    static let literalRange = #"-?\d+(?:\.\d+)?\s*\.\.[.<]\s*\(?-?\d"#

    @Test func theInterviewTabReadsItsBoundsFromTheType() throws {
        let pattern = try Regex(Self.literalRange)
        let all = try Self.sources(under: "Sources/SupervoxApp/SettingsUI")
        let model = try #require(all.first { $0.place == "InterviewSettingsModel.swift" })
        let pane = try #require(all.first { $0.place == "InterviewPane.swift" })
        #expect(!model.code.contains(pattern), "plage littérale dans le modèle")
        #expect(!pane.code.contains(pattern), "plage littérale dans la vue")
        for range in ["maxQuestionsRange", "turnSilenceRange", "interruptMinDurationRange", "interruptLevelRange"] {
            #expect(model.code.contains("InterviewSettings.\(range)"), "le modèle ne lit pas \(range) dans le type")
            #expect(pane.code.contains("model.\(range)"), "la vue ne lit pas \(range) dans le modèle")
        }
    }

    @Test(arguments: ["0.3...2.0", "1 ... 20", "-50...(-10)", "0.1..<1.0", "in: 1...20"])
    func theLiteralRangePatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.literalRange)))
    }

    @Test func theLiteralRangePatternLeavesOrdinaryUsesAlone() throws {
        let pattern = try Regex(Self.literalRange)
        for code in ["{ InterviewSettings.turnSilenceRange }", "Array(0..<count)", "values[index...]", "let x: ClosedRange<Int>"] {
            #expect(!code.contains(pattern), "\(code)")
        }
    }
    /// Tâche 10 : plus aucune note ne renvoie à « une étape suivante » (l'entretien est là). Commentaires compris, comme le `grep`
    /// de la tâche.
    @Test func noSourceSpeaksOfANextStep() throws {
        let base = Self.root.appendingPathComponent("Sources", isDirectory: true)
        let files = try #require(FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        try #require(files.count > 50, "le balayage doit voir les sources")
        let offending = try files.filter { try String(contentsOf: $0, encoding: .utf8).contains("étape suivante") }
            .map { String($0.path.dropFirst(base.path.count + 1)) }
        #expect(offending.isEmpty, "\(offending)")
    }

    // MARK: - Historique des entretiens (tâche 11)

    /// Règle 6 : le code de l'historique (stockage, modèle, vue) ne journalise rien et ne montre jamais le texte brut d'une erreur : un
    /// chemin ou un texte d'entretien n'y passe donc jamais. Le balayage doit voir le stockage, le format et les deux fichiers de
    /// l'onglet, sans quoi il ne vérifierait rien.
    @Test func theHistoryCodeLogsNothingAndShowsNoRawErrorText() throws {
        let storage = try Self.sources(under: "Sources/SupervoxApp/History")
        #expect(storage.contains { $0.place == "InterviewHistory.swift" }, "le balayage doit voir le stockage")
        #expect(storage.contains { $0.place == "InterviewRecord.swift" }, "le balayage doit voir le format")
        let tab = try Self.sources(under: "Sources/SupervoxApp/SettingsUI").filter {
            ["HistoryModel.swift", "HistoryPane.swift"].contains($0.place)
        }
        #expect(tab.count == 2, "le balayage doit voir le modèle et la vue de l'onglet")
        let all = storage + tab
        let logging = try Regex(Self.forbiddenLogging)
        let rawError = try Regex(Self.forbiddenErrorText)
        #expect(all.filter { $0.code.contains("localizedDescription") }.isEmpty)
        #expect(all.filter { $0.code.contains(logging) }.map(\.place).isEmpty)
        #expect(all.filter { $0.code.contains(rawError) }.map(\.place).isEmpty)
    }

    /// Le dossier réel de l'historique (`Supervox/Historique`, à côté de `settings.json`) n'est nommé que par le programme `Supervox`
    /// (`main.swift`, qui le donne à `AppController(historyRoot:)`). Nulle part ailleurs sous `Sources`, et aucun test : un test, la
    /// purge au lancement ou l'outil de rendu toucheraient le vrai disque. Les deux faces : le programme le donne bien (sinon la
    /// fonction serait morte en production), et personne d'autre ne le fait. La valeur par défaut de `historyRoot` reste `nil`.
    static let realHistoryFolder = #"Supervox\s*/\s*Historique"#
    /// Construire un chemin qui finit par « Historique » avec `appending` ou `appendingPathComponent`.
    static let historyFolderBuilding = #"appending(?:PathComponent)?\s*\(\s*(?:path\s*:\s*)?"[^"]*Historique"#
    /// Une valeur par défaut de `historyRoot` qui n'est pas `nil`.
    static let historyRootDefault = #"historyRoot\s*:\s*URL\s*\?\s*=(?!\s*nil\b)"#

    @Test func onlyTheSupervoxProgramNamesTheRealHistoryFolder() throws {
        let chain = try Regex(Self.realHistoryFolder)
        let building = try Regex(Self.historyFolderBuilding)
        let sources = try Self.sources(under: "Sources")
        let main = try #require(sources.first { $0.place == "Supervox/main.swift" }, "le balayage doit voir le programme")
        #expect(main.code.contains(chain), "le programme doit nommer le vrai dossier")
        #expect(main.code.contains("historyRoot:"), "et le donner à AppController")
        // `main.swift` SEUL est exempté, pas toute la cible `Supervox` : `Tests/SupervoxTests` en dépend, et une constante du vrai dossier
        // dans un autre de ses fichiers serait atteignable par un test sans que ce balayage le voie.
        let elsewhere = sources.filter { $0.place != "Supervox/main.swift" && ($0.code.contains(chain) || $0.code.contains(building)) }
        #expect(elsewhere.map(\.place).isEmpty, "\(elsewhere.map(\.place))")

        // Dans les tests : la chaîne ET la construction d'un chemin finissant par « Historique » (un dossier temporaire de test ne porte
        // pas ce nom).
        let tests = try Self.sources(under: "Tests").filter {
            !$0.place.hasSuffix("SourceScanTests.swift") && ($0.code.contains(chain) || $0.code.contains(building))
        }
        #expect(tests.map(\.place).isEmpty, "\(tests.map(\.place))")

        let controller = try #require(sources.first { $0.place == "SupervoxApp/AppController.swift" })
        let nilDefaults = controller.code.matches(of: try Regex(#"historyRoot\s*:\s*URL\s*\?\s*=\s*nil\b"#)).count
        #expect(nilDefaults == 3, "les trois constructeurs d'AppController ont historyRoot à nil par défaut : \(nilDefaults)")
        let anyDefault = try Regex(Self.historyRootDefault)
        let otherDefaults = sources.filter { $0.code.contains(anyDefault) }.map(\.place)
        #expect(otherDefaults.isEmpty, "\(otherDefaults)")
    }

    /// Le dossier de données de l'application (`applicationSupportDirectory`, `SettingsStore.defaultFile()`) n'est atteint ni par un
    /// test ni par l'outil de rendu : un test ou une image écrirait dans le vrai dossier. Une seule exception : le test qui LIT le
    /// chemin de `defaultFile()` sans rien écrire (`defaultFileIsInApplicationSupport`).
    /// Pas de `\b` devant `defaultFile` : la limite de mot Unicode ne coupe pas entre `.` et une lettre (« SettingsStore.defaultFile »).
    static let realDataFolderAccess = #"applicationSupportDirectory|defaultFile\s*\(\s*\)"#

    @Test func noTestNorTheRenderToolReachesTheRealApplicationSupportFolder() throws {
        let pattern = try Regex(Self.realDataFolderAccess)
        let tests = try Self.sources(under: "Tests")
        let snapshots = try Self.sources(under: "Sources/SupervoxSnapshots")
        #expect(snapshots.contains { $0.place == "main.swift" }, "le balayage doit voir l'outil de rendu")
        let offending =
            tests.filter {
                !$0.place.hasSuffix("SourceScanTests.swift") && $0.place != "SupervoxAppTests/SettingsStoreTests.swift"
                    && $0.code.contains(pattern)
            }.map(\.place) + snapshots.filter { $0.code.contains(pattern) }.map { "SupervoxSnapshots/" + $0.place }
        #expect(offending.isEmpty, "\(offending)")

        // L'exception est étroite : un seul `defaultFile()`, dans le test qui ne fait que lire le chemin, aucun `applicationSupportDirectory`.
        let store = try #require(tests.first { $0.place == "SupervoxAppTests/SettingsStoreTests.swift" })
        #expect(store.code.matches(of: pattern).count == 1)
        #expect(store.code.contains("func defaultFileIsInApplicationSupport"))
        #expect(!store.code.contains("applicationSupportDirectory"))
    }

    @Test(arguments: [
        "let url = URL.applicationSupportDirectory", "try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask)",
        "let file = try SettingsStore.defaultFile()", "SettingsStore.defaultFile ( )",
    ])
    func theRealDataFolderPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.realDataFolderAccess)))
    }

    @Test func theRealDataFolderPatternLeavesOrdinaryUsesAlone() throws {
        let pattern = try Regex(Self.realDataFolderAccess)
        for code in ["let file = directory.appendingPathComponent(\"settings.json\")", "func defaultFileName() {}", "let supportDirectory = temporary"] {
            #expect(!code.contains(pattern), "\(code)")
        }
    }

    @Test(arguments: [
        #"let root = URL.applicationSupportDirectory.appending(path: "Supervox/Historique")"#,
        #"URL.applicationSupportDirectory.appending(path: "Supervox / Historique")"#,
    ])
    func theRealFolderPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.realHistoryFolder)))
    }

    @Test(arguments: [
        #"base.appending(path: "Historique", directoryHint: .isDirectory)"#,
        #"support.appendingPathComponent("Supervox/Historique", isDirectory: true)"#,
        #"x.appending ( path : "Autre/Historique" )"#,
    ])
    func theFolderBuildingPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.historyFolderBuilding)))
    }

    @Test(arguments: [
        #"historyRoot: URL? = URL.applicationSupportDirectory"#, #"historyRoot : URL ? = defaultRoot"#,
    ])
    func theRootDefaultPatternSeesAnyDefaultButNil(code: String) throws {
        #expect(code.contains(try Regex(Self.historyRootDefault)))
    }

    @Test func theRealFolderPatternsLeaveOrdinaryUsesAlone() throws {
        let chain = try Regex(Self.realHistoryFolder)
        let building = try Regex(Self.historyFolderBuilding)
        let rootDefault = try Regex(Self.historyRootDefault)
        for code in [#"Button("Historique…") { openHistory() }"#, #"case .history: "Historique""#, #"let title = "Historique""#] {
            #expect(!code.contains(chain) && !code.contains(building), "\(code)")
        }
        for code in ["historyRoot: URL? = nil,", "historyRoot: URL?, ", "historyRoot: root"] {
            #expect(!code.contains(rootDefault), "\(code)")
        }
    }

    // MARK: - Voix du système et lecteur de sortie seule (réglage des voix, tâche 1)

    /// Devant un nom : début de ligne ou un caractère qui n'est pas d'identifiant. Pas de `\b` : la limite de mot Unicode ne coupe pas
    /// entre `.` et une lettre, et `SupervoxCore.SystemClipPlayer()` passerait.
    static let nameStart = #"(?:^|[^A-Za-z0-9_])"#
    /// Demander au système la liste des voix installées.
    static let systemVoiceListing = nameStart + #"speechVoices(?![A-Za-z0-9_])"#
    /// Le lecteur de fichiers audio du système et son délégué ; pas le nœud de lecture du moteur (`…PlayerNode`), que la capture utilise.
    static let systemFilePlayer = nameStart + #"AVAudioPlayer(?!Node)"#
    /// Construire le vrai lecteur de sortie seule.
    ///
    /// Formes qui échappent à ces quatre gardes (filets contre la maladresse, pas contre une écriture délibérée) : une ligne entière de
    /// commentaire ; un alias (`typealias R = SystemClipPlayer` puis `R()`) ; un type gardé dans une valeur
    /// (`let t = SystemClipPlayer.self` puis `t.init()`) ; `SystemVoices.self.installed` ; les autres API du système qui listent des
    /// voix ou jouent un son, hors du brief.
    static let realClipPlayer = nameStart + #"SystemClipPlayer"# + construction
    /// Lire la vraie liste des voix installées.
    static let installedVoices = nameStart + #"SystemVoices\s*\.\s*installed(?![A-Za-z0-9_])"#

    /// Règle 6 : la liste des voix n'est demandée au système que par `SystemVoices.installed` ; le lecteur du système n'est nommé que
    /// par `Audio/ClipPlayer.swift` ; le vrai lecteur et la vraie liste ne sont pris que par le programme (`main.swift`) et leur fichier
    /// de définition. Le programme ne les prend pas encore : la preuve que le balayage voit quelque chose vient des fichiers de
    /// définition, qui doivent porter ce qu'ils définissent.
    @Test func theSystemVoiceListAndTheSystemPlayerStayInTheirFiles() throws {
        let speech = "SupervoxCore/Speech/SystemSpeechSynthesizer.swift"
        let player = "SupervoxCore/Audio/ClipPlayer.swift"
        let sources = try Self.sources(under: "Sources")
        let speechFile = try #require(sources.first { $0.place == speech }, "le balayage doit voir la voix du système")
        let playerFile = try #require(sources.first { $0.place == player }, "le balayage doit voir le lecteur")
        #expect(speechFile.code.contains(try Regex(Self.systemVoiceListing)), "la liste des voix doit être demandée dans \(speech)")
        #expect(speechFile.code.contains("enum SystemVoices"), "SystemVoices doit être défini dans \(speech)")
        #expect(playerFile.code.contains(try Regex(Self.systemFilePlayer)), "le lecteur du système doit être pris dans \(player)")
        #expect(playerFile.code.contains("final class SystemClipPlayer"), "SystemClipPlayer doit être défini dans \(player)")
        // m5 : la vraie liste est bien vue là où elle est prise aujourd'hui (le constructeur public de la voix du système).
        #expect(speechFile.code.contains(try Regex(Self.installedVoices)), "SystemVoices.installed doit être vu dans \(speech)")

        let rules: [(name: String, pattern: String, allowed: Set<String>)] = [
            ("speechVoices", Self.systemVoiceListing, [speech]),
            ("AVAudioPlayer", Self.systemFilePlayer, [player]),
            ("SystemClipPlayer(", Self.realClipPlayer, ["Supervox/main.swift", player]),
            ("SystemVoices.installed", Self.installedVoices, ["Supervox/main.swift", speech]),
        ]
        for rule in rules {
            let pattern = try Regex(rule.pattern)
            let offending = sources.filter { !rule.allowed.contains($0.place) && $0.code.contains(pattern) }.map(\.place)
            #expect(offending.isEmpty, "\(rule.name) : \(offending)")
        }
    }

    /// Aucun test hors de `SupervoxCoreTests` ne nomme la liste des voix, le lecteur du système, le vrai lecteur ni la vraie liste.
    @Test func noTestOutsideTheCoreNamesTheSystemVoiceListNorTheSystemPlayer() throws {
        let patterns = try [Self.systemVoiceListing, Self.systemFilePlayer, Self.realClipPlayer, Self.installedVoices].map { try Regex($0) }
        let tests = try Self.sources(under: "Tests")
        #expect(tests.contains { $0.place.hasPrefix("SupervoxAppTests/") }, "le balayage doit voir les tests de l'application")
        let offending = tests
            .filter { file in !file.place.hasPrefix("SupervoxCoreTests/") && patterns.contains { file.code.contains($0) } }
            .map(\.place)
        #expect(offending.isEmpty, "\(offending)")
    }

    @Test(arguments: [
        "AVSpeechSynthesisVoice.speechVoices()", "AVSpeechSynthesisVoice\n    .speechVoices ( )", "let all = AVSpeechSynthesisVoice.speechVoices",
        "speechVoices()",
    ])
    func theVoiceListingPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.systemVoiceListing)))
    }

    @Test(arguments: [
        "AVAudioPlayer(data: data)", "try AVAudioPlayer.init(data: data)", "AVFAudio.AVAudioPlayer(data: data)", "let p: AVAudioPlayer",
        "final class P: NSObject, AVAudioPlayerDelegate {", "AVAudioPlayer",
    ])
    func theSystemFilePlayerPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.systemFilePlayer)))
    }

    @Test(arguments: [
        "SystemClipPlayer()", "SystemClipPlayer ( )", "SystemClipPlayer.init()", "let p: SystemClipPlayer = .init()",
        "SupervoxCore.SystemClipPlayer()", "{ SystemClipPlayer() }", "SystemClipPlayer.self.init()", "player: SystemClipPlayer()",
        // m5 : par le type déclaré optionnel ou implicitement déballé.
        "let p: SystemClipPlayer? = .init()", "var p: SystemClipPlayer! = .init()", "let p: SystemClipPlayer ? = . init()",
    ])
    func theRealClipPlayerPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.realClipPlayer)))
    }

    @Test(arguments: [
        "SystemVoices.installed()", "voices: SystemVoices.installed,", "SystemVoices . installed", "SupervoxCore.SystemVoices.installed",
        "SystemVoices\n    .installed",
    ])
    func theInstalledVoicesPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.installedVoices)))
    }

    @Test func theVoiceAndPlayerPatternsLeaveOrdinaryUsesAlone() throws {
        let listing = try Regex(Self.systemVoiceListing)
        let filePlayer = try Regex(Self.systemFilePlayer)
        let clipPlayer = try Regex(Self.realClipPlayer)
        let installed = try Regex(Self.installedVoices)
        for code in ["myspeechVoices()", "_speechVoices()", "speechVoicesCount"] {
            #expect(!code.contains(listing), "\(code)")
        }
        for code in ["private let player = AVAudioPlayerNode()", "AVAudioPlayerNode.h", "MyAVAudioPlayer()", "ClipPlayer"] {
            #expect(!code.contains(filePlayer), "\(code)")
        }
        for code in ["ScriptedClipPlayer()", "MySystemClipPlayer()", "let p: SystemClipPlayer", "x is SystemClipPlayer",
                     "public final class SystemClipPlayer: ClipPlayer {", "let p: SystemClipPlayer = player",
                     "let p: SystemClipPlayer? = nil", "var p: SystemClipPlayer! = player"] {
            #expect(!code.contains(clipPlayer), "\(code)")
        }
        for code in ["SystemVoices.gender(.male)", "SystemVoices.installedCount", "MySystemVoices.installed", "enum SystemVoices {"] {
            #expect(!code.contains(installed), "\(code)")
        }
    }

    // MARK: - Onglet Voix et écoute d'une voix (réglage des voix, tâche 3)

    /// Les fichiers de l'onglet Voix et de l'écoute, par motif de nom et non par liste : `Voices*.swift` et `VoicePreview.swift` sous
    /// `SupervoxApp` (la vue de la tâche 4, `VoicesPane.swift`, est couverte dès qu'elle existe).
    static func isVoicesTabFile(_ place: String) -> Bool {
        guard place.hasPrefix("SupervoxApp/"), let name = place.split(separator: "/").last.map(String.init) else { return false }
        return (name.hasPrefix("Voices") && name.hasSuffix(".swift")) || name == "VoicePreview.swift"
    }

    /// Règles 7 et 11 : ni le texte brut d'une erreur, ni le repli sur la voix du système, dans l'onglet Voix et l'écoute. Le balayage
    /// prouve qu'il voit au moins les fichiers de la tâche 3.
    @Test func theVoicesTabAndThePreviewShowNoRawErrorTextAndNeverFallBack() throws {
        let files = try Self.sources(under: "Sources").filter { Self.isVoicesTabFile($0.place) }
        let seen = Set(files.map(\.place))
        for expected in [
            "SupervoxApp/SettingsUI/VoicesModel.swift", "SupervoxApp/SettingsUI/VoicesText.swift",
            "SupervoxApp/Interview/VoicePreview.swift",
        ] {
            #expect(seen.contains(expected), "le balayage doit voir \(expected)")
        }
        let raw = files.filter { $0.code.contains("localizedDescription") }.map(\.place)
        #expect(raw.isEmpty, "localizedDescription : \(raw)")
        let fallback = files.filter { $0.code.contains("FallbackSpeechSynthesizer") }.map(\.place)
        #expect(fallback.isEmpty, "FallbackSpeechSynthesizer : \(fallback)")
    }

    /// Amendement de la tâche 3 : l'écoute décide qui parle par la résolution unique (`resolve(in:secrets:)`, injectée) et par rien
    /// d'autre : ni la route suivie d'un `ProviderResolver` à la main, ni une `ProviderVoice` construite sur place.
    @Test func thePreviewDecidesWhoSpeaksOnlyThroughTheSingleResolution() throws {
        let preview = try #require(
            try Self.sources(under: "Sources").first { $0.place == "SupervoxApp/Interview/VoicePreview.swift" })
        for forbidden in ["ProviderResolver", "ProviderVoice(", ".route(in", ".providerVoice"] {
            #expect(!preview.code.contains(forbidden), "\(forbidden) dans VoicePreview.swift")
        }
    }

    @Test(arguments: [
        "SupervoxApp/SettingsUI/VoicesModel.swift", "SupervoxApp/SettingsUI/VoicesPane.swift",
        "SupervoxApp/SettingsUI/VoicesText.swift", "SupervoxApp/Interview/VoicePreview.swift",
    ])
    func theVoicesTabPatternSeesItsFiles(place: String) {
        #expect(Self.isVoicesTabFile(place))
    }

    @Test(arguments: [
        "SupervoxApp/Settings/VoiceRoute.swift", "SupervoxApp/Settings/SavedVoice.swift", "SupervoxCore/Speech/VoicesHelper.swift",
        "SupervoxApp/SettingsUI/InterviewPane.swift", "SupervoxApp/SettingsUI/MyVoices.swift",
    ])
    func theVoicesTabPatternLeavesOtherFilesAlone(place: String) {
        #expect(!Self.isVoicesTabFile(place))
    }
}
