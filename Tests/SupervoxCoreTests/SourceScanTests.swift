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
    /// fabriquent ces messages : la capture audio, la session de dictée et le contrôleur de dictée.
    static let forbiddenErrorText = #"String\s*\(\s*describing\s*:\s*error\s*\)|\\\(\s*error\s*\)|\\\(\s*String\s*\(\s*describing\s*:\s*error"#

    @Test func noPanelMessageCarriesTheRawTextOfAnError() throws {
        let pattern = try Regex(Self.forbiddenErrorText)
        let folders = ["Sources/SupervoxCore/Audio", "Sources/SupervoxCore/Dictation", "Sources/SupervoxApp/Dictation"]
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
}
