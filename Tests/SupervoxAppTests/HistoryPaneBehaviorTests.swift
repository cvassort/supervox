import AppKit
import SwiftUI
import Testing

@testable import SupervoxApp

/// Ce que le volet de l'onglet Historique fait de lui-même, vu dans une vraie vue d'hébergement (posée dans une fenêtre jamais
/// affichée) : relire le disque quand il apparaît, annuler une confirmation en attente quand il disparaît. Comme
/// `InterviewPaneBehaviorTests` : boucle bornée, aucune attente sans fin. Le modèle lit un VRAI `InterviewHistory` dans un dossier
/// temporaire.
@MainActor @Suite(.timeLimit(.minutes(1))) struct HistoryPaneBehaviorTests {
    /// Pose le volet dans une fenêtre jamais affichée.
    private func show(_ model: HistoryModel) -> (window: NSWindow, host: NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(HistoryPane(model: model).frame(width: 600, height: 460)))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 460)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        return (window, host)
    }

    /// Laisse SwiftUI faire sa mise en page et les tâches se poser, jusqu'à ce que la condition soit vraie (passages bornés).
    private func settle(_ host: NSView, until condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            pump(host)
            await Task.yield()
        }
    }

    /// Un passage de la boucle d'exécution (synchrone : `RunLoop.run` n'existe pas en contexte asynchrone).
    private func pump(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: Date())
    }

    /// L'apparition de l'onglet relit le disque : un entretien conclu pendant que la fenêtre était gardée s'y voit sans geste.
    @Test func appearingRereadsTheDisk() async throws {
        let rig = try HistoryModelTests.Rig()
        defer { rig.cleanUp() }
        let model = rig.makeModel()
        #expect(!model.isLoaded)
        try await rig.seed([HistoryModelTests.record(1)])

        let shown = show(model)
        await settle(shown.host) { model.isLoaded && model.records.count == 1 }

        #expect(model.isLoaded)
        #expect(model.records.count == 1, "l'apparition a relu le disque")
        withExtendedLifetime(shown.window) {}
    }

    /// La disparition du volet (autre onglet, fenêtre retirée) annule la confirmation en attente : elle ne survit pas à l'onglet quitté.
    @Test func disappearingCancelsAPendingConfirmation() async throws {
        let rig = try HistoryModelTests.Rig(retention: 365)
        defer { rig.cleanUp() }
        try await rig.seed([HistoryModelTests.record(1, daysAgo: 100)])
        let model = rig.makeModel()
        let shown = show(model)
        await settle(shown.host) { model.isLoaded }
        await model.requestRetention(30)
        #expect(model.confirmation == .retention, "une confirmation attend")

        shown.window.contentView = NSView()  // le volet disparaît
        await settle(shown.host) { model.confirmation == nil }

        #expect(model.confirmation == nil, "la confirmation ne survit pas au volet")
        #expect(model.pendingRetention == nil)
        #expect(rig.updates == 0, "rien n'a été confirmé ni écrit")
    }
}
