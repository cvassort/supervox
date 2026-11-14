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
}
