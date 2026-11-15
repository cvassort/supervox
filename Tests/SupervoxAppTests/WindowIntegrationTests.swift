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

    /// « L'application n'est pas activée » ne se prouve pas hors d'un vrai écran : `NSApp.isActive` passe à vrai dès qu'un
    /// panneau non activant devient clé (constaté), et la sonde du système (`NSRunningApplication.current.isActive`, application
    /// au premier plan) ne peut pas échouer dans le processus de test (exécutable sans bundle ni bureau ; en provoquer
    /// l'échec exigerait d'activer vraiment l'application). La règle est donc à l'essai manuel ; ce test garde la
    /// configuration qui la porte.
    @Test func thePanelIsANonActivatingPanel() {
        let panel = FloatingPanel(content: Color.clear.frame(width: 10, height: 10))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.isFloatingPanel)
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

        surface.setKeyboard(.focused)
        try #require(panel.isKeyWindow, "le panneau n'est pas devenu clé")
        #expect(reviewField(in: panel) == nil)

        slot.present = true
        #expect(await waitUntil { reviewField(in: panel) != nil }, "SwiftUI n'a pas posé le champ")
        let field = try #require(reviewField(in: panel))
        #expect(await waitUntil { panel.firstResponder === field }, "le champ n'est pas le premier répondeur")
    }

    /// Champ ajouté, puis fenêtre rendue clé : le champ prend la frappe dès que la fenêtre devient clé.
    @Test func theFieldTakesTheKeyboardWhenItsWindowBecomesKey() async throws {
        _ = NSApplication.shared
        let slot = FieldSlot()
        slot.present = true
        let surface = offscreenSurface(slot)
        let panel = surface.panel
        defer { panel.orderOut(nil) }

        #expect(await waitUntil { reviewField(in: panel) != nil }, "SwiftUI n'a pas posé le champ")
        let field = try #require(reviewField(in: panel))
        // AppKit choisit lui-même un premier répondeur initial quand la fenêtre passe à l'écran (constaté) : on le retire pour
        // que seule la prise de la clé puisse donner la frappe au champ.
        panel.makeFirstResponder(nil)
        #expect(panel.firstResponder !== field, "la fenêtre n'est pas clé : le champ n'a pas à prendre la frappe")

        surface.setKeyboard(.focused)
        try #require(panel.isKeyWindow, "le panneau n'est pas devenu clé")
        #expect(panel.firstResponder === field)
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

    /// La pile d'annulation est celle du champ, pas celle du panneau (qui sert d'une relecture à la suivante) : au début d'une
    /// relecture, rien ne se défait, et ⌘Z ne fait rien revenir de la relecture d'avant.
    @Test func theUndoStackDoesNotPassFromOneReviewToTheNext() async throws {
        let slot = FieldSlot()
        let (surface, first) = try await focusedField(slot)
        defer { surface.panel.orderOut(nil) }
        let panel = surface.panel

        first.insertText("bonjour", replacementRange: NSRange(location: 0, length: 0))
        try #require(first.undoManager?.canUndo == true, "la première relecture n'a rien à annuler : le test ne prouve rien")

        // Fin de la relecture : le champ part, le panneau est caché puis remontré pour la suivante.
        slot.present = false
        #expect(await waitUntil { reviewField(in: panel) == nil })
        surface.hide()
        panel.orderFrontRegardless()
        slot.text = "Un autre texte."
        slot.present = true
        #expect(await waitUntil { reviewField(in: panel) != nil })
        let second = try #require(reviewField(in: panel))
        try #require(second !== first)
        surface.setKeyboard(.focused)
        try #require(panel.isKeyWindow, "le panneau n'est pas devenu clé")
        #expect(await waitUntil { panel.firstResponder === second })
        #expect(second.string == "Un autre texte.")

        // `#require` : sans pile propre, le ⌘Z qui suit défait la frappe d'un champ disparu et lève une exception d'AppKit.
        try #require(second.undoManager?.canUndo == false, "la pile du panneau est passée à la relecture suivante")
        // Rien à défaire : ⌘Z ne touche à rien (AppKit répond « pris » même sans rien à défaire : seul le texte compte).
        _ = try panel.performKeyEquivalent(with: keyEvent("z", .command, in: panel, keyCode: 6))
        #expect(second.string == "Un autre texte.")

        // La relecture en cours garde la sienne.
        second.insertText(" Ajout.", replacementRange: NSRange(location: second.string.utf16.count, length: 0))
        try #require(second.undoManager?.canUndo == true)
        #expect(try panel.performKeyEquivalent(with: keyEvent("z", .command, in: panel, keyCode: 6)))
        #expect(second.string == "Un autre texte.")
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

    private func keyEvent(
        _ characters: String, _ flags: NSEvent.ModifierFlags, type: NSEvent.EventType = .keyDown, in window: NSWindow,
        keyCode: UInt16 = 0
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: keyCode))
    }

    /// ⌘Z rend le texte d'avant, ⇧⌘Z rend le texte tapé : `redo:` trouve bien un répondeur.
    @Test func commandZThenShiftCommandZUndoesThenRedoesTheTyping() async throws {
        let slot = FieldSlot()
        let (surface, field) = try await focusedField(slot)
        defer { surface.panel.orderOut(nil) }
        let panel = surface.panel

        field.insertText("bonjour", replacementRange: NSRange(location: 0, length: 0))
        #expect(try panel.performKeyEquivalent(with: keyEvent("z", .command, in: panel, keyCode: 6)))
        #expect(field.string == "")
        #expect(try panel.performKeyEquivalent(with: keyEvent("Z", [.command, .shift], in: panel, keyCode: 6)))
        #expect(field.string == "bonjour")
    }

    /// Panneau sans clavier : aucune commande n'est traduite, même si un champ est encore premier répondeur.
    @Test func withoutAKeyboardThePanelTranslatesNothing() async throws {
        let slot = FieldSlot()
        let (surface, field) = try await focusedField(slot)
        defer { surface.panel.orderOut(nil) }
        let panel = surface.panel
        field.insertText("bonjour", replacementRange: NSRange(location: 0, length: 0))
        field.setSelectedRange(NSRange(location: 2, length: 0))
        surface.setKeyboard(.none)
        try #require(panel.firstResponder === field)

        #expect(try !panel.performKeyEquivalent(with: keyEvent("a", .command, in: panel)))
        #expect(field.selectedRange() == NSRange(location: 2, length: 0))
    }

    /// Un événement qui n'est pas un appui de touche n'est pas lu (`charactersIgnoringModifiers` lèverait sur un autre type).
    @Test func anEventThatIsNotAKeyDownIsNotTranslated() async throws {
        let slot = FieldSlot()
        let (surface, field) = try await focusedField(slot)
        defer { surface.panel.orderOut(nil) }
        let panel = surface.panel
        field.insertText("bonjour", replacementRange: NSRange(location: 0, length: 0))
        field.setSelectedRange(NSRange(location: 2, length: 0))

        #expect(try !panel.performKeyEquivalent(with: keyEvent("a", .command, type: .keyUp, in: panel)))
        #expect(field.selectedRange() == NSRange(location: 2, length: 0))
    }

    /// Un délégué d'application qui répond à `selectAll:` : `NSApp.sendAction(to: nil)` l'atteindrait en dernier recours.
    @MainActor final class SelectAllDelegate: NSObject, NSApplicationDelegate {
        private(set) var received = 0
        @objc func selectAll(_ sender: Any?) { received += 1 }
    }

    /// La commande reste dans la chaîne des répondeurs du panneau : elle ne déborde pas sur la fenêtre principale ni sur le
    /// délégué de l'application. (Une seconde fenêtre principale ne peut pas être montée hors écran : une fenêtre ordinaire ne
    /// devient clé ni principale dans une application inactive ; le délégué est l'autre fin de la même chaîne élargie.)
    @Test func aCommandStaysInThePanelsResponderChain() async throws {
        _ = NSApplication.shared
        let delegate = SelectAllDelegate()
        let previous = NSApp.delegate
        NSApp.delegate = delegate
        defer { NSApp.delegate = previous }

        // Le panneau, clé, a pour premier répondeur la fenêtre elle-même : personne dans sa chaîne ne répond à `selectAll:`.
        let slot = FieldSlot()
        let surface = offscreenSurface(slot)
        defer { surface.panel.orderOut(nil) }
        surface.setKeyboard(.focused)
        try #require(surface.panel.isKeyWindow)

        let handled = try surface.panel.performKeyEquivalent(with: keyEvent("a", .command, in: surface.panel))
        #expect(!handled)
        #expect(delegate.received == 0, "la commande a atteint le délégué de l'application")
    }

    /// `takesFocus` ne reprend le focus qu'au passage de faux à vrai : une mise à jour SwiftUI qui répète `true` ne ramène
    /// pas l'utilisateur au champ.
    @Test func takesFocusOnlyGrabsTheFocusWhenItChanges() async throws {
        let slot = FieldSlot()
        let (surface, field) = try await focusedField(slot)
        defer { surface.panel.orderOut(nil) }
        let panel = surface.panel

        panel.makeFirstResponder(nil)
        try #require(panel.firstResponder !== field)
        ReviewTextView.update(field, text: field.string, isEditable: true, takesFocus: true)
        #expect(panel.firstResponder !== field, "une mise à jour sans changement a repris le focus")

        ReviewTextView.update(field, text: field.string, isEditable: true, takesFocus: false)
        ReviewTextView.update(field, text: field.string, isEditable: true, takesFocus: true)
        #expect(panel.firstResponder === field)
    }

    /// Fermer un panneau clé : un seul retrait de l'écran, sans remise devant ; le panneau n'a plus la frappe.
    @Test func hidingAKeyPanelIsASingleOrderOutAndTakesItsKeyboardAway() async throws {
        let slot = FieldSlot()
        let (surface, _) = try await focusedField(slot)
        let panel = surface.panel
        let before = panel.orderings.count

        surface.hide()
        #expect(panel.orderings.count - before == 1)
        #expect(panel.orderings.last?.kind == .out)
        #expect(panel.keyboard == .none)
        #expect(!panel.isKeyWindow)
        #expect(!panel.isVisible)
    }

    /// Rendre la frappe panneau ouvert : retirer puis remettre, sans animation autour, animation rétablie ensuite.
    @Test func handingTheKeyboardBackOfAnOpenPanelRemovesAndRestoresItWithoutAnimation() async throws {
        let slot = FieldSlot()
        let (surface, _) = try await focusedField(slot)
        defer { surface.panel.orderOut(nil) }
        let panel = surface.panel
        let normal = panel.animationBehavior
        try #require(normal != .none)
        let before = panel.orderings.count

        surface.setKeyboard(.available)
        let made = Array(panel.orderings.dropFirst(before))
        #expect(made == [.init(kind: .out, animation: .none), .init(kind: .front, animation: .none)])
        #expect(panel.animationBehavior == normal)
        #expect(panel.isVisible)
        #expect(!panel.isKeyWindow)
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

    /// L'aide de la relecture suit la frappe du vrai panneau, dans les deux sens : la perte de la clé (un clic dans une autre
    /// application) retire ⌘↩ de l'aide, sa reprise (un clic dans le champ) le remet. Les notifications sont postées à la main
    /// sur le panneau, hors écran : elles sont internes au processus, et rien n'est envoyé au système. Le contrôleur est celui
    /// de l'application : c'est lui qui relie la surface au modèle.
    @Test func theReviewHintFollowsTheRealPanelLosingAndRegainingTheKey() async throws {
        _ = NSApplication.shared
        let model = PanelModel(lastModeID: ModeChip.rawID)
        model.dictation = DictationViewState(stage: .review, draft: "Un texte.")
        let surface = FloatingPanelSurface(
            content: PanelView(model: model, permissions: PermissionsModel(probe: WindowProbe()), openSettings: {}, quit: {}))
        let controller = PanelController(
            model: model, escapeRegistrar: HotKeyTests.FakeRegistrar(), clickMonitor: FakeClickMonitor(), surface: surface)
        _ = controller
        let panel = surface.panel
        panel.setFrame(NSRect(x: -20_000, y: -20_000, width: 520, height: 400), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let center = NotificationCenter.default
        func hint() -> String { model.dictationDisplay.review?.hint ?? "(aucune aide)" }

        #expect(hint() == DictationText.reviewNoKeyboardHint, "le panneau n'est pas clé : pas de ⌘↩")

        center.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        #expect(model.panelHasKeyboard)
        #expect(hint() == DictationText.reviewHint)

        // Un clic dans une autre application.
        center.post(name: NSWindow.didResignKeyNotification, object: panel)
        #expect(!model.panelHasKeyboard)
        #expect(hint() == DictationText.reviewNoKeyboardHint)
        #expect(!hint().contains("⌘↩"))

        // Un clic dans le champ.
        center.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        #expect(hint() == DictationText.reviewHint)

        // Une autre fenêtre qui prend ou perd la clé ne compte pas.
        center.post(name: NSWindow.didResignKeyNotification, object: NSWindow())
        #expect(model.panelHasKeyboard)
        center.post(name: NSWindow.didResignKeyNotification, object: panel)
        center.post(name: NSWindow.didBecomeKeyNotification, object: NSWindow())
        #expect(!model.panelHasKeyboard)
    }

    /// Sans notification postée, le vrai panneau que l'on rend clé, puis auquel on rend l'application de dessous, le dit tout
    /// seul : AppKit poste lui-même `didBecomeKey` et `didResignKey`.
    @Test func theRealPanelReportsItsOwnKeyChanges() async throws {
        _ = NSApplication.shared
        let slot = FieldSlot()
        let surface = offscreenSurface(slot)
        defer { surface.panel.orderOut(nil) }
        var changes: [Bool] = []
        surface.onKeyChange = { changes.append($0) }

        surface.setKeyboard(.focused)
        try #require(surface.panel.isKeyWindow)
        #expect(changes == [true])
        surface.setKeyboard(.available)
        #expect(!surface.panel.isKeyWindow)
        #expect(changes == [true, false])
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

    /// Le vrai panneau avec la vue de relecture, clé : ⌘↩ (un événement fabriqué, remis au panneau sans rien poster au système)
    /// déclenche « Coller » une fois ; Retour seul ne colle pas et ajoute une ligne au texte.
    @Test func commandReturnPastesOnceAndReturnAloneInsertsALine() async throws {
        _ = NSApplication.shared
        let model = PanelModel(lastModeID: ModeChip.rawID)
        model.dictation = DictationViewState(stage: .review, draft: "Un texte.")
        var pastes = 0
        model.onPaste = { pastes += 1 }
        let surface = FloatingPanelSurface(
            content: PanelView(model: model, permissions: PermissionsModel(probe: WindowProbe()), openSettings: {}, quit: {}))
        let panel = surface.panel
        panel.setFrame(NSRect(x: -20_000, y: -20_000, width: 520, height: 400), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        surface.setKeyboard(.focused)
        try #require(panel.isKeyWindow, "le panneau n'est pas devenu clé")
        let field = try #require(await waitUntil { reviewField(in: panel) != nil } ? reviewField(in: panel) : nil)
        try #require(await waitUntil { panel.firstResponder === field }, "le champ n'a pas la frappe")

        let commandReturn = try keyEvent("\r", .command, in: panel, keyCode: 36)
        #expect(panel.performKeyEquivalent(with: commandReturn), "⌘↩ n'a été pris par personne")
        #expect(pastes == 1)
        #expect(field.string == "Un texte.", "⌘↩ a aussi écrit dans le champ")

        // Retour seul : pas un équivalent de touche, et le champ reçoit la touche et ajoute une ligne.
        let plain = try keyEvent("\r", [], in: panel, keyCode: 36)
        #expect(!panel.performKeyEquivalent(with: plain))
        field.setSelectedRange(NSRange(location: field.string.utf16.count, length: 0))
        field.keyDown(with: plain)
        #expect(field.string == "Un texte.\n")
        #expect(pastes == 1, "Retour seul a collé")
        #expect(model.dictation.draft == "Un texte.\n")
    }

    /// Le vrai panneau avec la vraie vue de relecture, hors écran : la frappe dans le champ (insertion de texte, aucun événement
    /// clavier) fait grandir la hauteur que le panneau demande, et la vue d'hébergement le signale sans qu'on lise la surface.
    /// Puis le texte s'efface : la hauteur redescend à la borne basse. Ce que ce test ne dit pas : la frappe réelle au clavier.
    @Test func typingInTheReviewFieldGrowsThePanelAndNotifiesIt() async throws {
        _ = NSApplication.shared
        let model = PanelModel(lastModeID: ModeChip.rawID)
        model.dictation = DictationViewState(stage: .review, draft: "Une ligne.")
        let surface = FloatingPanelSurface(
            content: PanelView(model: model, permissions: PermissionsModel(probe: WindowProbe()), openSettings: {}, quit: {}))
        let panel = surface.panel
        let before = try #require(surface.contentHeight())
        panel.setFrame(NSRect(x: -20_000, y: -20_000, width: 520, height: before), display: false)
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        let field = try #require(await waitUntil { reviewField(in: panel) != nil } ? reviewField(in: panel) : nil)
        var notified = 0
        surface.onContentSizeChange = { notified += 1 }

        let lines = (1...10).map { "ligne \($0)" }.joined(separator: "\n")
        field.insertText(lines, replacementRange: NSRange(location: field.string.utf16.count, length: 0))
        #expect(model.dictation.draft.hasSuffix("ligne 10"))
        // D'abord sans lire la surface : seule la mise en page faite par la fenêtre elle-même peut signaler la hauteur.
        #expect(await waitUntil { notified >= 1 }, "la vue d'hébergement n'a pas signalé la hauteur")
        #expect(await waitUntil { (surface.contentHeight() ?? 0) > before + 80 }, "la hauteur n'a pas grandi à la frappe")
        let grown = try #require(surface.contentHeight())

        // Beaucoup plus de lignes : la hauteur ne dépasse pas la borne haute du champ.
        field.insertText(
            (1...200).map { "autre \($0)" }.joined(separator: "\n"), replacementRange: NSRange(location: 0, length: 0))
        // Le champ était à sa borne basse : à sa borne haute, le panneau a gagné exactement l'écart des deux bornes, pas plus.
        let ceiling = before + DictationText.editorMaxHeight - DictationText.editorMinHeight
        #expect(
            await waitUntil { abs((surface.contentHeight() ?? 0) - ceiling) < 1 },
            "avant \(before), maintenant \(surface.contentHeight() ?? 0), borne haute attendue \(ceiling)")
        #expect(grown < ceiling - 20, "dix lignes sont déjà à la borne : le test ne distingue plus la croissance du plafond")

        // Le texte effacé : retour à la borne basse.
        field.insertText("", replacementRange: NSRange(location: 0, length: field.string.utf16.count))
        #expect(await waitUntil { (surface.contentHeight() ?? .infinity) <= before + 1 }, "la hauteur n'est pas redescendue")
    }
}

private struct WindowProbe: PermissionsProbe {
    func microphone() -> PermissionState { .granted }
    func accessibility() -> PermissionState { .granted }
    func requestMicrophone() async -> Bool { true }
    func promptAccessibility() {}
}
