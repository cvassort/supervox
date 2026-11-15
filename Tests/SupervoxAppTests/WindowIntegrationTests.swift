import AppKit
import SwiftUI
import Testing

@testable import SupervoxApp

/// Vraies fenêtres d'AppKit, jamais affichées mais créées : activé seulement avec `SUPERVOX_WINDOWS=1`. La suite par
/// défaut couvre le même câblage avec des doubles (`FakeSettingsWindow`, `FakePanelSurface`).
@MainActor @Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_WINDOWS"] == "1"))
struct WindowIntegrationTests {
    /// N1 : la vraie fenêtre de réglages appelle `onLeave` quand elle se ferme, cesse d'être active, ou quand
    /// l'application passe en arrière-plan. Les notifications sont envoyées à la main : rien ne s'affiche.
    @Test func settingsWindowCallsOnLeaveForCloseResignKeyAndAppDeactivation() {
        _ = NSApplication.shared
        var leaves = 0
        let surface = SettingsWindow(content: AnyView(Color.clear.frame(width: 10, height: 10)), onLeave: { leaves += 1 })
        let center = NotificationCenter.default

        center.post(name: NSWindow.willCloseNotification, object: surface.window)
        #expect(leaves == 1)
        center.post(name: NSWindow.didResignKeyNotification, object: surface.window)
        #expect(leaves == 2)
        center.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        #expect(leaves == 3)
        // Une autre fenêtre qui se ferme ne compte pas.
        center.post(name: NSWindow.willCloseNotification, object: NSWindow())
        #expect(leaves == 3)
        #expect(!surface.window.isVisible)
    }

    /// Le panneau flottant ne prend jamais la frappe ni le statut de fenêtre principale : l'application de premier plan
    /// les garde. Construit hors écran, jamais affiché.
    @Test func panelCanNeitherBecomeKeyNorMain() {
        let panel = FloatingPanel(content: Color.clear.frame(width: 10, height: 10))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.isVisible)
    }

    /// Le contenu d'essai : sa hauteur dépend du nombre de lignes, comme celle de la dictée.
    @MainActor @Observable final class GrowingContent {
        var lines = 2
    }

    struct GrowingView: View {
        let model: GrowingContent
        var body: some View {
            VStack(alignment: .leading) {
                ForEach(0..<model.lines, id: \.self) { Text("ligne \($0)").frame(height: 20) }
            }
            .frame(width: 300)
        }
    }

    /// La vraie surface du panneau : quand le contenu change de hauteur, la vue d'hébergement le dit, la hauteur demandée suit,
    /// et `resize(toHeight:)` donne cette hauteur à la vraie fenêtre. Fenêtre hors écran, jamais montrée à l'utilisateur.
    @Test func theRealSurfaceReportsAContentThatChangesHeightAndResizes() async throws {
        _ = NSApplication.shared
        let model = GrowingContent()
        let surface = FloatingPanelSurface(content: GrowingView(model: model))
        let panel = surface.panel
        let before = try #require(surface.contentHeight())
        panel.setFrame(NSRect(x: -20_000, y: -20_000, width: 320, height: before), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        var notified = 0
        surface.onContentSizeChange = { notified += 1 }

        model.lines = 6
        // Sans rien lire de la surface : seule la mise en page faite par la fenêtre elle-même peut signaler le changement.
        try await Task.sleep(for: .milliseconds(500))
        #expect(notified >= 1, "la vue d'hébergement n'a pas signalé le changement de taille")
        let after = try #require(surface.contentHeight())
        #expect(after > before + 50, "avant \(before), après \(after)")

        surface.resize(toHeight: after)
        #expect(abs(panel.frame.height - after) < 1)
    }
}
