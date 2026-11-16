import Foundation
import Testing

/// Contrôles par recherche dans les sources du dépôt, lancés avec la suite.
@Suite struct SourceScanTests {
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

    /// Formes interdites hors de `EndpointSession.swift` : la session partagée, quelle que soit la coupure de ligne
    /// (`URLSession.shared`, `session: .shared`, `URLSession = .shared`), et toute session construite à la main
    /// (`URLSession(`), qui pourrait recevoir une configuration avec cache.
    static let forbiddenSession =
        #"URLSession\s*\.\s*shared|session\s*:\s*\.shared\b|URLSession\s*=\s*\.shared\b|URLSession\s*\("#

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
    ])
    func theForbiddenPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.forbiddenSession)))
    }

    @Test func theForbiddenPatternLeavesOrdinaryUsesAlone() throws {
        let pattern = try Regex(Self.forbiddenSession)
        for code in ["let session: URLSession", "session: URLSession = EndpointSession.shared", "URLSessionTaskMetrics"] {
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
            "Sources/SupervoxApp/Language",
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
    static let forbiddenLogInterpolation = #"\blog\s*\.\s*\w+\s*\(.*\\\((?!\s*kind\s*\(\s*of\s*:)"#

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
        #"log . notice ( "\(provider.name)" )"#,
    ])
    func theLogInterpolationPatternSeesNeighbouringSpellings(code: String) throws {
        #expect(code.contains(try Regex(Self.forbiddenLogInterpolation)))
    }

    @Test func theLogInterpolationPatternLeavesTheKindAlone() throws {
        let pattern = try Regex(Self.forbiddenLogInterpolation)
        for code in [
            #"log.notice("mise en forme échouée : \(kind(of: failure), privacy: .public)")"#, #"log.notice("fini")"#,
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
}
