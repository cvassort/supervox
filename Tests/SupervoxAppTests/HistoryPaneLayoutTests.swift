import AppKit
import SupervoxCore
import SwiftUI
import Testing

@testable import SupervoxApp

/// La disposition de l'onglet Historique dans la fenêtre de réglages, qui a une taille FIXE (`SettingsView.windowSize`) : la liste et
/// le détail doivent tenir et défiler, le pied (durée, « Tout supprimer… ») doit rester dans la fenêtre quoi que contiennent la liste
/// et le détail, et la zone du milieu doit garder de la place.
///
/// Mesure : le volet est posé dans une vue d'hébergement, sans fenêtre affichée ; il rapporte la hauteur de la zone du milieu et le
/// bas du pied (`GeometryReader`, repère du volet). C'est la hauteur de mise en page réelle de SwiftUI, pas une estimation. Limites :
/// (1) la barre d'onglets n'est pas mesurable hors fenêtre affichée : le volet reçoit la hauteur de la fenêtre moins
/// `tabStripAllowance` (choix non mesuré, la même marge que l'onglet Entretien) ; (2) la mise en page dépend de la police et de la
/// taille du texte du système : le test vaut pour la configuration de la machine qui le lance.
@MainActor @Suite(.timeLimit(.minutes(1))) struct HistoryPaneLayoutTests {
    static let tabStripAllowance = InterviewPaneLayoutTests.tabStripAllowance
    static var paneHeight: CGFloat { SettingsView.windowSize.height - tabStripAllowance }

    /// Mesure le volet à cette taille.
    private func measure(_ model: HistoryModel, width: CGFloat = SettingsView.windowSize.width) throws -> HistoryPane.Metrics {
        var measured: HistoryPane.Metrics?
        let height = Self.paneHeight
        let host = NSHostingView(rootView: HistoryPane(model: model, onMeasure: { measured = $0 }).frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Bornée : la mise en page se fait au passage de la boucle, jamais d'attente sans fin.
        for _ in 0..<300 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date())
        }
        return try #require(measured, "le volet n'a rien mesuré")
    }

    /// Un historique chargé de `count` entretiens aux textes très longs, un fichier illisible, et un message d'échec : tout ce qui peut
    /// pousser le pied.
    private func loadedModel(_ rig: HistoryModelTests.Rig, count: Int, longTexts: Bool, withExtras: Bool) async throws -> HistoryModel {
        var records: [InterviewRecord] = []
        for number in 1...max(count, 1) where count > 0 {
            var conversation = Conversation()
            let turns = longTexts ? 60 : 1
            for turn in 0..<turns {
                conversation.appendInterviewer("Question d'exemple numéro \(turn), assez longue pour passer à la ligne dans le détail ? " + String(repeating: "mot ", count: longTexts ? 40 : 1))
                conversation.appendUser("Réponse d'exemple numéro \(turn). " + String(repeating: "texte ", count: longTexts ? 40 : 1))
            }
            let prompt = longTexts
                ? (0..<80).map { "Ligne \($0) du prompt d'exemple, assez longue pour passer à la ligne sur plusieurs lignes du détail." }.joined(separator: "\n")
                : "Un prompt court."
            records.append(
                InterviewRecord(
                    id: InterviewHistoryTests.id(number), date: HistoryModelTests.now.addingTimeInterval(-Double(number) * 3600),
                    prompt: prompt, conversation: conversation))
        }
        if count > 0 { try await rig.seed(records) }
        if withExtras {
            try FileManager.default.createDirectory(at: rig.root, withIntermediateDirectories: true)
            try Data("pas du json".utf8).write(to: rig.root.appendingPathComponent("abîmé.json"))
        }
        let model = rig.makeModel()
        await model.reload()
        if withExtras {
            rig.copyAccepts = false
            model.copyPrompt()  // pose un message d'échec : la rangée du haut apparaît.
            try #require(model.message != nil)
        }
        return model
    }

    @Test("le pied est collé au bas de la fenêtre, ni poussé dehors ni remonté, avec 40 entretiens très longs, un illisible et un message")
    func theFooterStaysAtTheBottomWithTheWorstContent() async throws {
        let rig = try HistoryModelTests.Rig()
        defer { rig.cleanUp() }
        let model = try await loadedModel(rig, count: 40, longTexts: true, withExtras: true)
        #expect(model.unreadableNote != nil)

        let metrics = try measure(model)

        #expect(abs(try #require(metrics[.footer]).maxY - Self.paneHeight) < 0.5, "pied à \(metrics[.footer]?.maxY ?? -1) points, volet de \(Self.paneHeight)")
    }

    @Test("même pied, même place, avec un seul entretien court, sans entretien, et avant la première lecture")
    func theFooterDoesNotDependOnTheContent() async throws {
        let rig = try HistoryModelTests.Rig()
        defer { rig.cleanUp() }
        let one = try await loadedModel(rig, count: 1, longTexts: false, withExtras: false)
        #expect(abs(try #require(try measure(one)[.footer]).maxY - Self.paneHeight) < 0.5)

        let emptyRig = try HistoryModelTests.Rig()
        defer { emptyRig.cleanUp() }
        let empty = emptyRig.makeModel()
        #expect(abs(try #require(try measure(empty)[.footer]).maxY - Self.paneHeight) < 0.5, "avant la première lecture")
        await empty.reload()
        #expect(empty.records.isEmpty && empty.isLoaded)
        #expect(abs(try #require(try measure(empty)[.footer]).maxY - Self.paneHeight) < 0.5, "sans entretien")
    }

    /// La liste et le détail gardent de la place : même avec l'en-tête, le message et la note des fichiers illisibles, la zone du
    /// milieu fait au moins ce qu'il faut pour montrer quelques lignes.
    @Test("la zone du milieu garde au moins 150 points avec l'en-tête, le message et la note des illisibles")
    func theMainAreaKeepsRoom() async throws {
        let rig = try HistoryModelTests.Rig()
        defer { rig.cleanUp() }
        let model = try await loadedModel(rig, count: 40, longTexts: true, withExtras: true)

        let metrics = try measure(model)

        #expect(try #require(metrics[.mainArea]).height >= 150, "zone du milieu de \(metrics[.mainArea]?.height ?? -1) points")
    }

    @Test("la mesure est vivante : un volet plus étroit passe l'en-tête à la ligne et la zone du milieu rétrécit")
    func theMeasureFollowsTheLayout() async throws {
        let rig = try HistoryModelTests.Rig()
        defer { rig.cleanUp() }
        let model = try await loadedModel(rig, count: 3, longTexts: false, withExtras: false)

        let wide = try measure(model)
        let narrow = try measure(model, width: 360)

        #expect(try #require(narrow[.mainArea]).height < (try #require(wide[.mainArea])).height, "étroit : \(narrow[.mainArea]?.height ?? -1), large : \(wide[.mainArea]?.height ?? -1)")
    }

    /// C1 (revue) : un message (« Copié. », un refus de copie, un échec d'écriture long) ne décale AUCUN bouton du détail : un double
    /// clic sur « Copier le prompt » ne peut pas tomber sur « Supprimer » parce que le premier clic a fait apparaître « Copié. ».
    /// Mesure : les cadres de mise en page SwiftUI dans le repère du volet, défilement à zéro, volet hébergé sans fenêtre. Limite :
    /// c'est la géométrie de la mise en page, pas un clic réel ; une animation ou un défilement non mesurés ne sont pas couverts.
    @Test("C1 : la position de « Supprimer », des deux « Copier », du pied et de la zone du milieu est la même avec et sans message")
    func aMessageNeverMovesTheDetailButtons() async throws {
        let probes: [HistoryPane.Probe] = [.deleteButton, .copyPromptButton, .copyConversationButton, .footer, .mainArea]

        let baseRig = try HistoryModelTests.Rig()
        defer { baseRig.cleanUp() }
        let base = try await loadedModel(baseRig, count: 2, longTexts: false, withExtras: false)
        #expect(base.message == nil)
        let baseline = try measure(base)
        for probe in probes { _ = try #require(baseline[probe], "\(probe) n'est pas mesuré") }

        // « Copié. »
        let copiedRig = try HistoryModelTests.Rig()
        defer { copiedRig.cleanUp() }
        let copied = try await loadedModel(copiedRig, count: 2, longTexts: false, withExtras: false)
        copied.copyPrompt()
        #expect(copied.message == "Copié.")

        // Refus de copie.
        let refusedRig = try HistoryModelTests.Rig()
        defer { refusedRig.cleanUp() }
        let refused = try await loadedModel(refusedRig, count: 2, longTexts: false, withExtras: false)
        refusedRig.copyAccepts = false
        refused.copyPrompt()
        #expect(refused.message == HistoryModel.copyFailure)

        // Échec d'écriture : la phrase la plus longue de l'onglet.
        let failedRig = try HistoryModelTests.Rig()
        defer { failedRig.cleanUp() }
        let failed = try await loadedModel(failedRig, count: 2, longTexts: false, withExtras: false)
        await failed.requestDeleteAll()
        #expect(chmod(failedRig.root.path, 0o500) == 0)
        await failed.deleteAll()
        #expect(failed.message == HistoryModel.writeFailure)
        // La liste reste la même (deux entretiens) : l'échec n'a rien supprimé.
        #expect(failed.records.count == 2)

        for (name, model) in [("Copié.", copied), ("refus de copie", refused), ("échec d'écriture", failed)] {
            let metrics = try measure(model)
            for probe in probes {
                let expected = try #require(baseline[probe])
                let actual = try #require(metrics[probe], "\(probe) n'est pas mesuré avec « \(name) »")
                #expect(
                    abs(actual.minY - expected.minY) < 0.5 && abs(actual.maxY - expected.maxY) < 0.5
                        && abs(actual.minX - expected.minX) < 0.5,
                    "\(probe) bouge avec « \(name) » : \(actual) au lieu de \(expected)")
            }
        }
    }

    /// C-1 : la ligne « Ne rien garder » (sous l'en-tête) et la ligne « la durée a changé hors de cet onglet » avec son bouton (dans le
    /// pied) coexistent : la zone du milieu garde de la place, le pied reste au bas, le message reste dans sa bande.
    @Test("C-1 : avec la ligne « Ne rien garder » sous l'en-tête et la ligne de durée dans le pied, le pied reste en bas et la zone du milieu garde 150 points")
    func theKeepNothingLineAndTheRetentionNoteStillFit() async throws {
        let rig = try HistoryModelTests.Rig(retention: 30)
        defer { rig.cleanUp() }
        let model = try await loadedModel(rig, count: 3, longTexts: true, withExtras: true)  // écrit avec 30 jours
        rig.settings.history.retentionDays = 0  // réglé ensuite sur « Ne rien garder »
        try await rig.history.confirmRetention(365)
        await model.reload()
        #expect(model.headerNote != nil && model.retentionNote != nil)

        let metrics = try measure(model)

        #expect(abs(try #require(metrics[.footer]).maxY - Self.paneHeight) < 0.5)
        #expect(try #require(metrics[.mainArea]).height >= 150, "zone du milieu de \(metrics[.mainArea]?.height ?? -1) points")
    }

    /// Section 3 du lot : la ligne de durée et son bouton ne déplacent AUCUN autre bouton. Ils vivent dans le pied, au-dessus de la ligne du
    /// sélecteur (le pied est collé au bas de la fenêtre et grandit vers le haut) : en disparaissant après un clic, rien d'autre ne passe
    /// sous le pointeur ; ni les boutons du détail (en haut), ni la ligne du sélecteur et de « Tout supprimer… » (en bas) ne bougent.
    /// Trois cas, chacun avec SA ligne de base (même durée des réglages, même ligne d'en-tête) : « durée changée » (bouton « 30 jours »),
    /// « Ne rien garder » oublié (bouton « 30 jours »), et le libellé le plus long : réglages sur « Ne rien garder », dossier à 1 an
    /// (bouton « Confirmer « Ne rien garder » », avec la ligne d'en-tête de « Ne rien garder » dans les deux).
    @Test("la ligne de durée et son bouton, libellé le plus long compris, ne déplacent ni les boutons du détail ni la ligne du sélecteur, et tiennent dans la fenêtre")
    func theRetentionNoteAndItsButtonMoveNothingElse() async throws {
        let probes: [HistoryPane.Probe] = [.deleteButton, .copyPromptButton, .copyConversationButton, .retentionRow]
        typealias Case = (name: String, settings: Int, baselineConfirmed: Int?, confirmed: Int, button: String)
        let cases: [Case] = [
            ("durée changée", 30, nil, 365, "Confirmer «\u{00A0}30 jours\u{00A0}»"),
            ("« Ne rien garder » oublié", 30, nil, 0, "Confirmer «\u{00A0}30 jours\u{00A0}»"),
            ("libellé le plus long", 0, 0, 365, "Confirmer «\u{00A0}Ne rien garder\u{00A0}»"),
        ]
        for item in cases {
            // Les entretiens sont écrits avec 30 jours, puis les réglages et le dossier sont posés comme le cas le demande.
            func make(confirmed: Int?) async throws -> (HistoryModelTests.Rig, HistoryModel) {
                let rig = try HistoryModelTests.Rig(retention: 30)
                let model = try await loadedModel(rig, count: 2, longTexts: false, withExtras: false)
                rig.settings.history.retentionDays = item.settings
                if let confirmed { try await rig.history.confirmRetention(confirmed) }
                await model.reload()
                return (rig, model)
            }
            let (baseRig, base) = try await make(confirmed: item.baselineConfirmed)
            defer { baseRig.cleanUp() }
            #expect(base.retentionNote == nil, "\(item.name) : la ligne de base n'a pas de ligne de durée")
            let baseline = try measure(base)
            for probe in probes { _ = try #require(baseline[probe], "\(probe) n'est pas mesuré") }

            let (rig, model) = try await make(confirmed: item.confirmed)
            defer { rig.cleanUp() }
            #expect(model.retentionNote != nil, "\(item.name)")
            #expect(model.confirmRetentionButtonTitle == item.button, "\(item.name)")

            let metrics = try measure(model)

            for probe in probes {
                let expected = try #require(baseline[probe])
                let actual = try #require(metrics[probe])
                #expect(
                    abs(actual.minY - expected.minY) < 0.5 && abs(actual.maxY - expected.maxY) < 0.5
                        && abs(actual.minX - expected.minX) < 0.5,
                    "\(probe) bouge avec « \(item.name) » : \(actual) au lieu de \(expected)")
            }
            let button = try #require(metrics[.confirmRetentionButton], "le bouton n'est pas mesuré (\(item.name))")
            #expect(button.maxY <= Self.paneHeight && button.minX >= 0 && button.maxX <= SettingsView.windowSize.width, "\(button)")
            let area = try #require(metrics[.mainArea])
            #expect(button.minY >= area.maxY - 0.5, "le bouton est dans le pied, sous la zone du milieu (\(item.name))")
        }
    }

    /// Les phrases de la bande du message tiennent sur DEUX lignes : l'emplacement a une hauteur fixe et coupe au-delà (la phrase la plus
    /// longue est celle du dossier écrit et des réglages refusés). Mesure : un `Text` en police `callout` à la largeur utile de la bande
    /// (largeur de la fenêtre moins les marges de 20 points et l'icône), hauteur idéale comparée à celle de deux lignes.
    @Test("chaque phrase de la bande du message tient sur deux lignes dans la largeur de la fenêtre")
    func everyMessageSentenceFitsTheFixedSlot() throws {
        let sentences = [
            HistoryModel.copyFailure, HistoryModel.writeFailure, HistoryModel.retentionNotedButNotSavedFailure,
            SettingsError.newerVersionKept(fileName: "settings.json", version: 9).errorDescription ?? "",
            SettingsError.unreadableFileKept(fileName: "settings.json").errorDescription ?? "",
        ]
        let usable = SettingsView.windowSize.width - 40 - 24
        func height(_ text: String) -> CGFloat {
            let host = NSHostingView(
                rootView: Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).frame(width: usable, alignment: .leading))
            return host.fittingSize.height
        }
        let oneLine = height("Une ligne.")
        #expect(oneLine > 0)
        for sentence in sentences {
            #expect(!sentence.isEmpty)
            #expect(height(sentence) <= oneLine * 2 + 2, "\(sentence.count) caractères : \(height(sentence)) points pour deux lignes de \(oneLine)")
        }
        // La mesure est vivante : une phrase de trois lignes est vue comme trop haute.
        #expect(height(String(repeating: "mot ", count: 120)) > oneLine * 2 + 2)
    }
}
