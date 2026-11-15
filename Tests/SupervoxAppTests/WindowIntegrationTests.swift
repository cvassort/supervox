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

    /// Le panneau ne devient clé qu'avec `available` ou `focused`, et jamais principal : l'application de premier plan garde
    /// le statut de fenêtre principale. Construit hors écran, jamais affiché.
    @Test func panelCanBecomeKeyOnlyWithAvailableOrFocusedAndNeverMain() {
        let panel = FloatingPanel(content: Color.clear.frame(width: 10, height: 10))
        #expect(panel.keyboard == .none)
        #expect(!panel.canBecomeKey, "par défaut le panneau ne prend pas la frappe")
        #expect(!panel.canBecomeMain)
        panel.keyboard = .available
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        panel.keyboard = .focused
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        panel.keyboard = .none
        #expect(!panel.canBecomeKey)
        #expect(!panel.isVisible)
    }

    /// L'activation, telle que le système la voit : l'application au premier plan et si Supervox l'est. `NSApp.isActive` ne
    /// convient pas : il passe à vrai dès qu'un panneau non activant devient clé (constaté), sans que le système change
    /// d'application active.
    private struct Activation: Equatable {
        var frontmostProcess: pid_t?
        var supervoxIsActive: Bool

        static func snapshot() -> Activation {
            Activation(
                frontmostProcess: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                supervoxIsActive: NSRunningApplication.current.isActive)
        }
    }

    /// Un champ de relecture que le test pose ou non dans la vue, pour essayer les deux ordres.
    @MainActor @Observable final class FieldSlot {
        var present = false
        var text = ""
    }

    struct FieldView: View {
        let slot: FieldSlot
        var body: some View {
            if slot.present {
                ReviewTextView(text: slot.text, isEditable: true, takesFocus: true, onEdit: { slot.text = $0 })
                    .frame(width: 300, height: 80)
            } else {
                Color.clear.frame(width: 300, height: 80)
            }
        }
    }

    /// La vraie surface avec un champ de relecture, hors écran : placée loin de tout écran, jamais montrée à l'utilisateur.
    private func offscreenSurface(_ slot: FieldSlot) -> FloatingPanelSurface {
        let surface = FloatingPanelSurface(content: FieldView(slot: slot))
        surface.panel.setFrame(NSRect(x: -20_000, y: -20_000, width: 320, height: 100), display: false)
        surface.panel.orderFrontRegardless()
        return surface
    }

    private func reviewField(in panel: NSWindow) -> NSTextView? {
        func find(_ view: NSView) -> NSTextView? {
            if let textView = view as? NSTextView { return textView }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        return panel.contentView.flatMap(find)
    }

    /// Attend (sans borne de durée dans l'assertion : seule une attente maximale de sécurité) que la condition soit vraie.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// Fenêtre rendue clé, puis champ ajouté : le champ prend la frappe dès qu'il arrive dans la fenêtre.
    @Test func theFieldTakesTheKeyboardWhenItArrivesInAnAlreadyKeyWindow() async throws {
        _ = NSApplication.shared
        let slot = FieldSlot()
        let surface = offscreenSurface(slot)
        let panel = surface.panel
        defer { panel.orderOut(nil) }
        let front = Activation.snapshot()

        surface.setKeyboard(.focused)
        try #require(panel.isKeyWindow, "le panneau n'est pas devenu clé")
        #expect(reviewField(in: panel) == nil)

        slot.present = true
        #expect(await waitUntil { reviewField(in: panel) != nil }, "SwiftUI n'a pas posé le champ")
        let field = try #require(reviewField(in: panel))
        #expect(await waitUntil { panel.firstResponder === field }, "le champ n'est pas le premier répondeur")
        #expect(Activation.snapshot() == front, "l'application ne doit pas être activée")
    }

    /// Champ ajouté, puis fenêtre rendue clé : le champ prend la frappe dès que la fenêtre devient clé.
    @Test func theFieldTakesTheKeyboardWhenItsWindowBecomesKey() async throws {
        _ = NSApplication.shared
        let slot = FieldSlot()
        slot.present = true
        let surface = offscreenSurface(slot)
        let panel = surface.panel
        defer { panel.orderOut(nil) }
        let front = Activation.snapshot()

        #expect(await waitUntil { reviewField(in: panel) != nil }, "SwiftUI n'a pas posé le champ")
        let field = try #require(reviewField(in: panel))
        // AppKit choisit lui-même un premier répondeur initial quand la fenêtre passe à l'écran (constaté) : on le retire pour
        // que seule la prise de la clé puisse donner la frappe au champ.
        panel.makeFirstResponder(nil)
        #expect(panel.firstResponder !== field, "la fenêtre n'est pas clé : le champ n'a pas à prendre la frappe")

        surface.setKeyboard(.focused)
        try #require(panel.isKeyWindow, "le panneau n'est pas devenu clé")
        #expect(panel.firstResponder === field)
        #expect(Activation.snapshot() == front, "l'application ne doit pas être activée")
    }

    /// Le champ est prêt à recevoir une frappe : `insertText` l'écrit, `undoManager.undo()` le défait.
    private func focusedField(_ slot: FieldSlot) async throws -> (FloatingPanelSurface, NSTextView) {
        _ = NSApplication.shared
        slot.present = true
        let surface = offscreenSurface(slot)
        surface.setKeyboard(.focused)
        try #require(surface.panel.isKeyWindow, "le panneau n'est pas devenu clé")
        #expect(await waitUntil { reviewField(in: surface.panel) != nil })
        let field = try #require(reviewField(in: surface.panel))
        #expect(await waitUntil { surface.panel.firstResponder === field })
        return (surface, field)
    }

    @Test func typingInTheFieldThenUndoRestoresTheTextBefore() async throws {
        let slot = FieldSlot()
        let (surface, field) = try await focusedField(slot)
        defer { surface.panel.orderOut(nil) }

        field.insertText("bonjour", replacementRange: NSRange(location: 0, length: 0))
        #expect(field.string == "bonjour")
        #expect(slot.text == "bonjour", "la frappe remonte par onEdit")
        let undoManager = try #require(field.undoManager)
        undoManager.undo()
        #expect(field.string == "")
    }

    /// Un ⌘Z fabriqué, passé directement à la fenêtre (rien n'est posté au système) : annule comme `undoManager.undo()`.
    @Test func aCommandZEventPassedToThePanelUndoesTheTyping() async throws {
        let slot = FieldSlot()
        let (surface, field) = try await focusedField(slot)
        defer { surface.panel.orderOut(nil) }
        let panel = surface.panel

        field.insertText("bonjour", replacementRange: NSRange(location: 0, length: 0))
        #expect(field.string == "bonjour")

        // La touche physique est celle du W de l'ANSI (13) : la lettre est lue sur `charactersIgnoringModifiers`, pas sur le
        // code de touche, pour suivre la disposition du clavier.
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, characters: "z", charactersIgnoringModifiers: "z", isARepeat: false, keyCode: 13))
        #expect(panel.performKeyEquivalent(with: event))
        #expect(field.string == "")
    }

    /// ⌘A, lui, ne touche pas au presse-papiers : il suffit à montrer que la traduction passe par la chaîne des répondeurs.
    @Test func aCommandAEventPassedToThePanelSelectsAllTheText() async throws {
        let slot = FieldSlot()
        let (surface, field) = try await focusedField(slot)
        defer { surface.panel.orderOut(nil) }
        let panel = surface.panel

        field.insertText("bonjour", replacementRange: NSRange(location: 0, length: 0))
        field.setSelectedRange(NSRange(location: 2, length: 0))
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(panel.performKeyEquivalent(with: event))
        #expect(field.selectedRange() == NSRange(location: 0, length: 7))
    }

    /// ⌥⌘Z n'est pas ⌘Z : le panneau ne le traduit pas.
    @Test func anOptionCommandZEventIsNotTranslated() async throws {
        let slot = FieldSlot()
        let (surface, field) = try await focusedField(slot)
        defer { surface.panel.orderOut(nil) }
        let panel = surface.panel

        field.insertText("bonjour", replacementRange: NSRange(location: 0, length: 0))
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "z", charactersIgnoringModifiers: "z",
                isARepeat: false, keyCode: 6))
        #expect(!panel.performKeyEquivalent(with: event))
        #expect(field.string == "bonjour")
    }

    /// Rendre le clavier : un panneau clé passe à `none`, il cesse d'être clé et ne peut plus le redevenir.
    @Test func settingNoKeyboardOnAKeyPanelTakesItsKeyStatusAway() async throws {
        let slot = FieldSlot()
        let (surface, _) = try await focusedField(slot)
        defer { surface.panel.orderOut(nil) }

        surface.setKeyboard(.none)
        #expect(!surface.panel.isKeyWindow)
        #expect(!surface.panel.canBecomeKey)
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
