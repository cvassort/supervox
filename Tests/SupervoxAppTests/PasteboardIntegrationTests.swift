import AppKit
import Foundation
import Testing

@testable import SupervoxApp

/// Le vrai presse-papiers du système, mais jamais le général : chaque test crée un presse-papiers NOMMÉ, unique,
/// et le libère à la fin. Désactivé sauf `SUPERVOX_PASTEBOARD=1`. Aucune touche n'est postée (poseur double).
@MainActor @Suite(.enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_PASTEBOARD"] == "1"), .serialized)
struct PasteboardIntegrationTests {
    /// Exécute `body` sur un presse-papiers nommé neuf, puis le libère.
    private func withNamedBoard(_ body: @MainActor (NSPasteboard, SystemPasteboard) async throws -> Void) async throws {
        let board = NSPasteboard(name: NSPasteboard.Name("dev.supervox.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        #expect(board.name != .general)
        try await body(board, SystemPasteboard(board: board))
    }

    static let imageAndFile = PasteboardContents(items: [
        ["public.png": Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF]), "public.tiff": Data([0x49, 0x49, 0x2A])],
        ["public.file-url": Data("file:///exemple/photo.png".utf8)],
    ])

    @Test("écrire puis lire rend le même contenu, et changeCount monte à chaque écriture")
    func writeThenReadRoundTrips() async throws {
        try await withNamedBoard { _, pasteboard in
            let before = pasteboard.changeCount
            pasteboard.write(Self.imageAndFile)
            #expect(pasteboard.changeCount > before)
            #expect(pasteboard.read() == Self.imageAndFile)
        }
    }

    @Test("un contenu vide vide le presse-papiers")
    func emptyContentsClearsTheBoard() async throws {
        try await withNamedBoard { _, pasteboard in
            pasteboard.write(Self.imageAndFile)
            pasteboard.write(PasteboardContents(items: []))
            #expect(pasteboard.read() == PasteboardContents(items: []))
        }
    }

    @Test("le texte transitoire est lisible comme texte et porte les deux marques ; non transitoire, le texte seul")
    func transientTextCarriesTheMarkers() async throws {
        try await withNamedBoard { board, pasteboard in
            pasteboard.writeText("dictée privée", transient: true)
            #expect(board.string(forType: .string) == "dictée privée")
            let types = Set((board.types ?? []).map(\.rawValue))
            #expect(types.isSuperset(of: ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"]))

            pasteboard.writeText("dictée publique", transient: false)
            #expect(board.string(forType: .string) == "dictée publique")
            let plainTypes = Set((board.types ?? []).map(\.rawValue))
            #expect(plainTypes.isDisjoint(with: ["org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType"]))
        }
    }

    @Test("insertion complète sur un presse-papiers réel : l'image et le fichier d'origine sont restaurés à l'identique")
    func fullInsertionRestoresNonTextualContents() async throws {
        try await withNamedBoard { board, pasteboard in
            pasteboard.write(Self.imageAndFile)
            let log = CallLog()
            let keys = FakeKeyPoster(log: log)
            let waiter = FakeWait(log: log)
            // Au moment du collage (pendant l'attente de restauration), le texte dicté est bien dans le presse-papiers.
            var seenDuringPaste: String?
            waiter.onWait = { _ in seenDuringPaste = board.string(forType: .string) }
            let inserter = TextInserter(
                pasteboard: pasteboard, keys: keys, layout: HotKeyTests.ansi, isTrusted: { true },
                wait: { await waiter.wait($0) })

            let outcome = await inserter.insert("dictée de test")
            #expect(outcome == .pasted)
            #expect(seenDuringPaste == "dictée de test")
            #expect(pasteboard.read() == Self.imageAndFile)
            #expect(log.entries == ["modifiersHeld", "postPaste(9)", "wait(0.4)"])
        }
    }

    @Test("insertion complète : un contenu écrit par une autre application pendant l'attente n'est pas écrasé")
    func fullInsertionLeavesAConcurrentCopyAlone() async throws {
        try await withNamedBoard { board, pasteboard in
            pasteboard.write(Self.imageAndFile)
            let log = CallLog()
            let waiter = FakeWait(log: log)
            waiter.onWait = { _ in
                board.clearContents()
                board.setString("copié ailleurs", forType: .string)
            }
            let inserter = TextInserter(
                pasteboard: pasteboard, keys: FakeKeyPoster(log: log), layout: HotKeyTests.ansi,
                isTrusted: { true }, wait: { await waiter.wait($0) })

            _ = await inserter.insert("dictée de test")
            #expect(board.string(forType: .string) == "copié ailleurs")
        }
    }

    @Test("sans Accessibilité, le texte reste sur le presse-papiers réel")
    func withoutAccessibilityTheTextStaysOnTheRealBoard() async throws {
        try await withNamedBoard { board, pasteboard in
            pasteboard.write(Self.imageAndFile)
            let log = CallLog()
            let inserter = TextInserter(
                pasteboard: pasteboard, keys: FakeKeyPoster(log: log), layout: HotKeyTests.ansi,
                isTrusted: { false }, wait: { await FakeWait(log: log).wait($0) })
            let outcome = await inserter.insert("dictée de test")
            guard case .copied = outcome else {
                Issue.record("résultat inattendu")
                return
            }
            #expect(board.string(forType: .string) == "dictée de test")
        }
    }
}
