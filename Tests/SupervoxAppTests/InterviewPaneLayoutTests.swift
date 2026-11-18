import AppKit
import SwiftUI
import Testing

@testable import SupervoxApp

/// La disposition de l'onglet Entretien dans la fenêtre de réglages, qui a une hauteur FIXE (`SettingsView.windowSize`) : ce qui se
/// règle passe avant ce qui se lit, et l'intitulé « Réglages avancés » doit être visible sans défiler.
///
/// Mesure : le volet est posé dans une vue d'hébergement de la taille de la fenêtre, sans fenêtre affichée ; le volet rapporte le bas
/// de l'intitulé (`GeometryReader`, repère du volet, défilement à zéro). C'est la hauteur de mise en page réelle de SwiftUI, pas une
/// estimation. Limites : (1) la barre d'onglets n'est pas mesurable hors fenêtre affichée : on laisse `tabStripAllowance` points
/// (choix non mesuré) ; (2) la mise en page dépend de la police du système et de la taille du texte : le test vaut pour la
/// configuration de la machine qui le lance ; (3) un bandeau d'erreur au-dessus du formulaire (une cinquantaine de points) pousse
/// l'intitulé plus bas, ce que ce test ne couvre pas.
@MainActor @Suite(.timeLimit(.minutes(1))) struct InterviewPaneLayoutTests {
    /// Marge pour la barre d'onglets, en points : choix non mesuré (la barre ne se mesure pas hors fenêtre affichée).
    static let tabStripAllowance: CGFloat = 60

    /// Le bas de l'intitulé « Réglages avancés », en points depuis le haut du volet, pour un volet de cette largeur. Le volet a le
    /// bouton « Choisir la voix… » (règle 4 de la tâche 4 : la vraie fenêtre le montre dès que l'onglet Voix existe).
    private func headingBottom(
        model: InterviewSettingsModel, width: CGFloat = SettingsView.windowSize.width, expanded: Bool = false
    ) throws -> CGFloat {
        var measured: CGFloat?
        let height = SettingsView.windowSize.height
        let pane = InterviewPane(
            model: model, advancedExpanded: expanded, chooseVoice: {}, onAdvancedHeadingBottom: { measured = $0 })
        let host = NSHostingView(rootView: pane.frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Bornée : la mise en page se fait au passage de la boucle, jamais d'attente sans fin.
        for _ in 0..<300 where measured == nil {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date())
        }
        return try #require(measured, "le volet n'a rien mesuré")
    }

    private func model(_ settings: AppSettings = .defaults) -> InterviewSettingsModel {
        var current = settings
        return InterviewSettingsModel(
            read: { current }, update: { change in change(&current) }, effectiveTurnSilence: { $0 })
    }

    /// L'exigence : à la taille par défaut de la fenêtre, l'intitulé « Réglages avancés » est visible sans défiler, avec la marge de
    /// la barre d'onglets.
    @Test func theAdvancedHeadingIsVisibleWithoutScrollingAtTheDefaultWindowSize() throws {
        let bottom = try headingBottom(model: model())
        #expect(bottom > 0)
        #expect(
            bottom <= SettingsView.windowSize.height - Self.tabStripAllowance,
            "intitulé à \(bottom) points du haut, fenêtre de \(SettingsView.windowSize.height) moins \(Self.tabStripAllowance)")
    }

    /// Même chose avec un gabarit long, la voix d'un fournisseur et le maintien : les notes sont EN BAS, ce qui s'y ajoute ne pousse
    /// pas l'intitulé. (Le gabarit, lui, défile dans son champ de hauteur bornée.)
    @Test func longNotesAndALongTemplateDoNotPushTheHeadingDown() throws {
        let plain = try headingBottom(model: model())
        var settings = AppSettings.defaults
        settings.interview.template = String(repeating: "Un gabarit très long, sur plusieurs lignes. ", count: 80)
        settings.hotKeyBehavior = .hold
        settings.providers = [Provider(id: UUID(), name: "Fournisseur d'exemple", baseURL: "https://example.com", kind: .openAICompatible, models: [])]
        settings.voice = VoiceChoice(providerID: settings.providers[0].id, model: "voix-modele", identifier: "voix-exemple")
        let loaded = try headingBottom(model: model(settings))
        #expect(loaded == plain, "ni le gabarit ni les notes du bas ne bougent l'intitulé")
    }

    /// Ouvrir le groupe ne déplace pas son intitulé : le contenu s'ouvre dessous.
    ///
    /// À un point près, pas à l'égalité exacte : selon la machine, la mise en page rend l'intitulé un quart de point plus haut
    /// quand le groupe est ouvert (mesuré : 394,5 contre 394,75, session ouverte, deux écrans ; égaux session verrouillée ; cause
    /// non établie). Un intitulé poussé par le contenu descendrait d'au moins une ligne de texte, bien au-delà d'un point.
    @Test func openingTheGroupDoesNotMoveItsHeading() throws {
        let opened = try headingBottom(model: model(), expanded: true)
        let closed = try headingBottom(model: model(), expanded: false)
        #expect(abs(opened - closed) < 1, "ouvert : \(opened), fermé : \(closed)")
    }

    /// Règle 4 (tâche 4) : le bouton « Choisir la voix… » est dans le volet (sous la ligne de vie privée, dans le bloc de notes du
    /// bas) ; sans onglet Voix, il n'y est pas. Son bas est mesuré et donné tel quel : le bloc de notes est sous le pli de la
    /// fenêtre fixe, le formulaire défile pour l'atteindre.
    @Test func theChooseVoiceButtonIsInThePaneOnlyWithTheVoicesTab() throws {
        func buttonBottom(_ chooseVoice: (@MainActor () -> Void)?) -> CGFloat? {
            var measured: CGFloat?
            let height = SettingsView.windowSize.height
            let pane = InterviewPane(model: model(), chooseVoice: chooseVoice, onChooseVoiceBottom: { measured = $0 })
            let host = NSHostingView(rootView: pane.frame(width: SettingsView.windowSize.width, height: height))
            host.frame = NSRect(x: 0, y: 0, width: SettingsView.windowSize.width, height: height)
            for _ in 0..<300 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(mode: .default, before: Date())
            }
            return measured
        }
        let measuredBottom = buttonBottom({})
        let bottom = try #require(measuredBottom, "le bouton n'est pas dans le volet")
        let heading = try headingBottom(model: model())
        print("Entretien : bas du bouton « Choisir la voix… » à \(bottom) points du haut du volet ; intitulé avancé à \(heading) ; hauteur utile \(SettingsView.windowSize.height - Self.tabStripAllowance)")
        #expect(bottom > heading, "le bouton est sous l'intitulé « Réglages avancés » (dans le bloc de notes du bas)")
        let withoutVoices = buttonBottom(nil)
        #expect(withoutVoices == nil, "sans onglet Voix, pas de bouton")
    }

    /// La mesure est vivante : un volet plus étroit passe les phrases à la ligne, et l'intitulé descend. Sans cela, un chiffre
    /// constant ne prouverait rien.
    @Test func theMeasureFollowsTheLayout() throws {
        let wide = try headingBottom(model: model())
        let narrow = try headingBottom(model: model(), width: 320)
        #expect(narrow > wide, "étroit : \(narrow), large : \(wide)")
    }
}
