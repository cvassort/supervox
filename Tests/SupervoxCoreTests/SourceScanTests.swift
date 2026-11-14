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
}
