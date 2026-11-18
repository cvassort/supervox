import AppKit
import SwiftUI
import Testing

@testable import SupervoxApp

/// Ce que le volet de l'onglet Entretien fait de lui-même, vu dans une vraie vue d'hébergement (posée dans une fenêtre jamais
/// affichée) : relire les réglages quand il apparaît, enregistrer le gabarit tapé quand il disparaît. Le gabarit enregistré à la
/// perte de main du champ (`@FocusState`) ne peut pas se simuler hors fenêtre affichée : il n'est pas testé ici.
@MainActor @Suite(.timeLimit(.minutes(1))) struct InterviewPaneBehaviorTests {
    /// Un modèle sur des réglages en mémoire.
    @MainActor private final class Store {
        var settings = AppSettings.defaults
        var updates = 0
        func makeModel() -> InterviewSettingsModel {
            InterviewSettingsModel(
                read: { self.settings },
                update: { change in
                    self.updates += 1
                    change(&self.settings)
                },
                effectiveTurnSilence: { $0 })
        }
    }

    /// Pose le volet dans une fenêtre jamais affichée et laisse SwiftUI faire apparaître la vue (passages bornés de la boucle).
    private func show(_ model: InterviewSettingsModel) -> (window: NSWindow, host: NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(InterviewPane(model: model).frame(width: 600, height: 460)))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 460)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        return (window, host)
    }

    private func settle(_ host: NSView, until condition: () -> Bool) {
        for _ in 0..<300 where !condition() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date())
        }
    }

    /// L'apparition de l'onglet relit les réglages : un réglage écrit ailleurs pendant que la fenêtre était gardée s'y voit sans geste.
    @Test func appearingRereadsTheSettings() throws {
        let store = Store()
        let model = store.makeModel()
        store.settings.interview.maxQuestions = 14  // écrit ailleurs après la construction du modèle
        #expect(model.maxQuestions == InterviewSettings.defaults.maxQuestions, "pas encore relu")
        let shown = show(model)
        settle(shown.host) { model.maxQuestions == 14 }
        #expect(model.maxQuestions == 14)
        withExtendedLifetime(shown.window) {}
    }

    /// La disparition du volet (autre onglet, fenêtre retirée) enregistre le gabarit tapé : une seule écriture, aucune avant.
    @Test func disappearingSavesTheTypedTemplate() throws {
        let store = Store()
        let model = store.makeModel()
        let shown = show(model)
        settle(shown.host) { false }  // laisse apparaître la vue
        model.template = "Tapé dans le champ."
        #expect(store.updates == 0, "rien n'est écrit pendant la frappe")

        shown.window.contentView = NSView()  // le volet disparaît
        settle(shown.host) { store.updates > 0 }

        #expect(store.settings.interview.template == "Tapé dans le champ.")
        #expect(store.updates == 1)
    }
}
