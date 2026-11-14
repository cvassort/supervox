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

    /// C1 : la session partagée garde les réponses dans le cache disque. Toute requête vers un point d'accès passe
    /// par `EndpointSession.shared`, sans stockage. Formes cherchées : `URLSession.shared`, `session: .shared` (point
    /// d'appel) et `URLSession = .shared` (valeur par défaut).
    @Test func noSourceUsesTheSharedURLSession() throws {
        let pattern = try Regex(#"URLSession\s*\.\s*shared|session\s*:\s*\.shared\b|URLSession\s*=\s*\.shared\b"#)
        let offending = try Self.codeLines(under: "Sources").filter { $0.line.contains(pattern) }
        #expect(offending.isEmpty, "\(offending.map(\.place))")
    }

    /// Les serveurs des tests n'écoutent que sur la boucle locale : tout écouteur passe par `NWListener.loopbackOnly()`.
    @Test func testServersListenThroughTheLoopbackFactory() throws {
        let needle = "NWListener" + "("  // en deux morceaux : cette ligne ne se trouve pas elle-même
        let offending = try Self.codeLines(under: "Tests")
            .filter { $0.line.contains(needle) && !$0.place.hasPrefix("SupervoxCoreTests/LocalHTTPServer.swift:") }
        #expect(offending.isEmpty, "\(offending.map(\.place))")
    }
}
