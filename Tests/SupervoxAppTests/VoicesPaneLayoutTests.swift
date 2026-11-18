import AppKit
import Foundation
import SupervoxCore
import SwiftUI
import Testing

@testable import SupervoxApp

/// L'onglet Voix (tâche 4) : sa disposition dans la fenêtre de taille FIXE (`SettingsView.windowSize`), les règles d'affichage que
/// la vue tient elle-même (bande de message, bouton d'écoute, options des sélecteurs, feuille unique), et ce que le volet fait quand
/// il apparaît ou disparaît.
///
/// Mesure : le volet est posé dans une vue d'hébergement, sans fenêtre affichée ; il rapporte le cadre de ses repères
/// (`GeometryReader`, repère du volet). C'est la mise en page réelle de SwiftUI. Limites (celles de `HistoryPaneLayoutTests`) : la
/// barre d'onglets n'est pas comptée (marge `tabStripAllowance`, choix non mesuré) ; la mise en page dépend de la police et de la
/// taille du texte du système. Comportement : le volet est posé dans une fenêtre JAMAIS affichée (comme `HistoryPaneBehaviorTests`),
/// boucle bornée. Écoute réelle (`VoicePreview`) sur voix et lecteur doubles : aucun son, aucune vraie voix, aucune vraie liste.
@MainActor @Suite(.timeLimit(.minutes(1))) struct VoicesPaneLayoutTests {
    typealias Rig = VoicesModelTests.Rig
    /// Écrit en toutes lettres : `= .system(` se lirait comme la construction de l'insertion du système.
    typealias RowID = VoicesModel.Row.ID

    static var paneHeight: CGFloat { SettingsView.windowSize.height - InterviewPaneLayoutTests.tabStripAllowance }
    static let buttons: [VoicesPane.Probe] = [.useButton, .listenButton, .addButton, .editButton, .deleteButton]

    /// Mesure le volet à cette taille.
    private func measure(_ model: VoicesModel, width: CGFloat = SettingsView.windowSize.width) throws -> VoicesPane.Metrics {
        var measured: VoicesPane.Metrics?
        let height = Self.paneHeight
        let host = NSHostingView(rootView: VoicesPane(model: model, onMeasure: { measured = $0 }).frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Bornée : la mise en page se fait au passage de la boucle, jamais d'attente sans fin.
        for _ in 0..<300 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date())
        }
        return try #require(measured, "le volet n'a rien mesuré")
    }

    /// Un nom de fournisseur au plus long qu'une phrase puisse citer (`Provider.shortNameLimit` caractères, puis « … »).
    static let longProviderName = Provider.shortName("Fournisseur d'exemple, Fournisseur d'exemple, Fournisseur d'exemple")

    /// Toutes les phrases qui peuvent arriver dans la bande, cherchées dans le code : chaque panne de l'écoute (les 19 cas de
    /// fournisseur de la table de la tâche 3 compris), chaque refus du brouillon, la suppression de la voix en vigueur, la phrase de
    /// chaque refus d'enregistrement (`SettingsError.sentence`), et les trois notes de vie privée ; le nom d'un fournisseur au plus
    /// long.
    static func bandSentences() -> [(name: String, text: String, failure: VoicePreview.Failure?)] {
        struct OtherError: Error {}
        var failures: [VoicePreview.Failure] = [
            .notInstalled, .unusable(.providerRemoved), .unusable(.providerCannotSpeak), .unusable(.incomplete), .silent, .timedOut,
            .playback, .unavailable, .microphoneBusy,
        ]
        failures += VoicePreviewTests.providerFailures.map { failure, _ in
            if case .noKey = failure { return .provider(.noKey(provider: longProviderName)) }
            return .provider(failure)
        }
        var list: [(name: String, text: String, failure: VoicePreview.Failure?)] = failures.map {
            ("\($0)", VoicesText.failure($0), $0)
        }
        let others: [(String, String)] = [
            ("refusalEmptyName", VoicesText.refusalEmptyName), ("refusalNoProvider", VoicesText.refusalNoProvider),
            ("refusalEmptyModel", VoicesText.refusalEmptyModel), ("refusalEmptyIdentifier", VoicesText.refusalEmptyIdentifier),
            ("refusalEmptyKey", VoicesText.refusalEmptyKey), ("refusalReservedKey", VoicesText.refusalReservedKey),
            ("refusalDuplicateKey", VoicesText.refusalDuplicateKey),
            ("refusalTooManyParameters", VoicesText.refusalTooManyParameters), ("deletedActive", VoicesText.deletedActive),
            ("newerVersionKept", SettingsError.sentence(
                forSaveError: SettingsError.newerVersionKept(fileName: "settings.json", version: 9))),
            ("unreadableFileKept", SettingsError.sentence(
                forSaveError: SettingsError.unreadableFileKept(fileName: "settings.json"))),
            ("autre erreur", SettingsError.sentence(forSaveError: OtherError())),
            ("privacyNothingSent", VoicesText.privacyNothingSent), ("privacyCannotSpeak", VoicesText.privacyCannotSpeak),
            ("privacyProvider", VoicesText.privacyProvider(longProviderName)),
        ]
        list += others.map { ($0.0, $0.1, nil) }
        return list
    }

    /// La hauteur d'un texte de la bande (police `callout`, largeur de la bande).
    static func bandHeight(_ text: String, width: CGFloat = VoicesPane.messageTextWidth) -> CGFloat {
        NSHostingView(
            rootView: Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).frame(width: width, alignment: .leading)
        ).fittingSize.height
    }

    /// La phrase la plus HAUTE de la bande (puis la plus longue, à hauteur égale) : celle que les tests et l'image montrent.
    static func tallestBandSentence() -> (name: String, text: String, failure: VoicePreview.Failure?) {
        bandSentences().max { lhs, rhs in
            (bandHeight(lhs.text), lhs.text.count) < (bandHeight(rhs.text), rhs.text.count)
        }!
    }

    /// Toute phrase que l'éditeur peut montrer pendant un brouillon (refus, échec d'enregistrement des réglages) tient dans sa bande
    /// de refus, à la largeur de la feuille (marges de 20 points, icône et espace de 24, comme la bande de l'onglet).
    @Test func everyEditorSentenceFitsTheRefusalSlot() throws {
        let editorTextWidth = VoiceEditor.size.width - 40 - 24
        let sentences = Self.bandSentences().filter {
            $0.name.hasPrefix("refusal") || ["newerVersionKept", "unreadableFileKept", "autre erreur"].contains($0.name)
        }
        #expect(sentences.count == 11, "\(sentences.count) phrases")
        let tallest = try #require(sentences.max { Self.bandHeight($0.text, width: editorTextWidth) < Self.bandHeight($1.text, width: editorTextWidth) })
        let height = Self.bandHeight(tallest.text, width: editorTextWidth)
        print("Bande de l'éditeur : phrase la plus haute « \(tallest.name) », \(height) points ; bande : \(VoiceEditor.refusalSlotHeight)")
        #expect(height > Self.bandHeight("Une ligne.", width: editorTextWidth), "la mesure est vivante")
        for sentence in sentences {
            #expect(
                Self.bandHeight(sentence.text, width: editorTextWidth) + 4 <= VoiceEditor.refusalSlotHeight,
                "\(sentence.name) : \(Self.bandHeight(sentence.text, width: editorTextWidth)) points")
        }
    }

    /// Un modèle dont l'écoute d'une voix de fournisseur échoue par cette `RewriteFailure` (la résolution la lève : c'est le
    /// chemin de `VoicePreview` pour `.provider`). Aucune voix n'est fabriquée.
    static func failingModel(_ failure: RewriteFailure, settings: AppSettings) -> VoicesModel {
        let installed = VoicesModelTests.installed
        let preview = VoicePreview(
            makeVoice: { _, _ in PreviewVoice(.forbidden) }, makePlayer: { ScriptedClipPlayer(completion: .immediate) },
            resolve: { _, _ in throw failure }, systemVoices: { installed }, microphoneHeld: { false },
            sleep: { _ in })
        var current = settings
        return VoicesModel(
            read: { current }, update: { change in change(&current) }, systemVoices: { installed },
            preview: preview, microphoneBusy: { false })
    }

    // MARK: - Règle 1 : disposition

    /// La phrase la plus haute de la bande tient dans ses lignes à la largeur de la fenêtre, et la bande a la place de ces lignes ;
    /// la mesure est vivante (une phrase de quatre lignes est vue trop haute).
    @Test func everyBandSentenceFitsTheFixedSlot() throws {
        let sentences = Self.bandSentences()
        #expect(sentences.count >= 40, "\(sentences.count) phrases")
        let oneLine = Self.bandHeight("Une ligne.")
        #expect(oneLine > 0)
        let capacity = oneLine * CGFloat(VoicesPane.messageLineLimit) + 2
        for sentence in sentences {
            #expect(!sentence.text.isEmpty)
            #expect(
                Self.bandHeight(sentence.text) <= capacity,
                "\(sentence.name) : \(Self.bandHeight(sentence.text)) points pour \(VoicesPane.messageLineLimit) lignes de \(oneLine)")
        }
        let tallest = Self.tallestBandSentence()
        print("Bande : phrase la plus haute « \(tallest.name) », \(tallest.text.count) caractères, \(Self.bandHeight(tallest.text)) points ; une ligne : \(oneLine) ; bande : \(VoicesPane.messageSlotHeight)")
        #expect(VoicesPane.messageSlotHeight >= Self.bandHeight(tallest.text) + 4, "la bande a la place de la phrase la plus haute")
        #expect(Self.bandHeight(String(repeating: "mot ", count: 200)) > capacity, "la mesure est vivante")
    }

    /// Règle 1 : un message ne déplace AUCUN bouton. La ligne de base n'a rien dans la bande (aucune ligne choisie) ; l'autre montre
    /// la phrase la plus haute de la bande (une panne d'écoute de fournisseur, par la résolution qui la lève) ; un refus du brouillon
    /// et la note de vie privée sont aussi mesurés. Les boutons, le pied, la liste et les filtres restent à un point près (décision
    /// 6), et la phrase est dans la bande.
    @Test("règle 1 : la position des cinq boutons, du pied, de la liste et des filtres est la même avec et sans message, pour la phrase la plus haute de la bande")
    func aMessageNeverMovesTheButtons() async throws {
        let saved = VoicesModelTests.saved("Voix d'exemple A", id: 1)
        let settings = VoicesModelTests.settings(voices: [saved])
        let probes = Self.buttons + [.footer, .list, .filters, .messageSlot]

        let base = Rig(settings).model
        #expect(base.message == nil && base.previewMessage == nil && base.privacyText == nil)
        let baseline = try measure(base)
        for probe in probes { _ = try #require(baseline[probe], "\(probe) n'est pas mesuré") }
        #expect(baseline[.message] == nil, "rien dans la bande")

        let tallest = Self.tallestBandSentence()
        guard case .provider(let failure)? = tallest.failure else {
            Issue.record("la phrase la plus haute (\(tallest.name)) n'est pas une panne de fournisseur : étendre ce test pour l'atteindre")
            return
        }
        let failing = Self.failingModel(failure, settings: settings)
        failing.selection = .saved(saved.id)
        failing.listen()
        #expect(await until { failing.previewMessage != nil })
        #expect(failing.previewMessage == tallest.text)

        let refused = Rig(settings).model
        refused.beginAdding()
        refused.draft?.name = " "
        refused.save()
        #expect(refused.message == VoicesText.refusalEmptyName)
        refused.cancel()
        let privacy = Rig(settings).model
        privacy.selection = .saved(saved.id)
        #expect(privacy.privacyText != nil)

        for (name, model) in [("phrase la plus haute", failing), ("vie privée", privacy)] {
            let metrics = try measure(model)
            for probe in probes {
                let expected = try #require(baseline[probe])
                let actual = try #require(metrics[probe], "\(probe) n'est pas mesuré avec « \(name) »")
                #expect(
                    abs(actual.minY - expected.minY) < 1 && abs(actual.maxY - expected.maxY) < 1
                        && abs(actual.minX - expected.minX) < 1 && abs(actual.maxX - expected.maxX) < 1,
                    "\(probe) bouge avec « \(name) » : \(actual) au lieu de \(expected)")
            }
            let message = try #require(metrics[.message], "la phrase n'est pas dans la bande (\(name))")
            let slot = try #require(metrics[.messageSlot])
            #expect(message.minY >= slot.minY - 0.5 && message.maxY <= slot.maxY + 0.5, "\(name) : \(message) hors de \(slot)")
        }
    }

    /// Les cinq boutons tiennent sur une ligne dans la largeur de la fenêtre, sans se chevaucher, quand l'écoute est en cours
    /// (« Arrêter » et son indicateur) comme au repos ; le pied est collé au bas du volet.
    @Test func theFiveButtonsFitInTheWindowWidthWithoutOverlapping() async throws {
        let gate = TestGate()
        defer { gate.open() }
        let rig = Rig(VoicesModelTests.settings(), systemVoice: PreviewVoice(.held(gate, VoicePreviewTests.clip)))
        let model = rig.model
        model.selection = RowID.system(identifier: "voix.exemple.a")
        let idle = try measure(model)
        model.listen()
        #expect(model.previewState == .preparing)
        let preparing = try measure(model)
        for (name, metrics) in [("repos", idle), ("préparation", preparing)] {
            let frames = try Self.buttons.map { try #require(metrics[$0], "\($0) (\(name))") }
            for frame in frames {
                #expect(frame.minX >= 0 && frame.maxX <= SettingsView.windowSize.width, "\(name) : \(frame)")
            }
            for (left, right) in zip(frames, frames.dropFirst()) {
                #expect(left.maxX <= right.minX + 0.5, "\(name) : \(left) chevauche \(right)")
            }
            #expect(abs(try #require(metrics[.footer]).maxY - Self.paneHeight) < 1, "\(name) : pied au bas du volet")
            #expect(try #require(metrics[.list]).height >= 150, "\(name) : la liste garde de la place")
        }
        for probe in Self.buttons {
            let before = try #require(idle[probe])
            let after = try #require(preparing[probe])
            #expect(abs(before.minX - after.minX) < 1 && abs(before.maxX - after.maxX) < 1, "\(probe) bouge : « Écouter » devient « Arrêter »")
        }
        model.stopListening()
    }

    // MARK: - Règle 2 : une seule feuille

    /// Une seule feuille : l'éditeur tant qu'un brouillon est ouvert, sinon la confirmation, sinon rien ; la fermer (Échap) abandonne
    /// le brouillon ou annule la confirmation. Et le volet ne déclare qu'UNE feuille (aucune autre présentation modale).
    @Test func oneSheetServesTheEditorAndTheConfirmation() throws {
        let saved = VoicesModelTests.saved("Voix d'exemple A", id: 1)
        let rig = Rig(VoicesModelTests.settings(voices: [saved]))
        let model = rig.model
        #expect(VoicesPane.sheet(for: model) == nil)
        model.selection = .saved(saved.id)
        model.requestDeletion()
        #expect(VoicesPane.sheet(for: model) == .confirmation)
        VoicesPane.dismissSheet(model)
        #expect(model.pendingDeletion == nil && VoicesPane.sheet(for: model) == nil)
        model.beginEditing()
        #expect(VoicesPane.sheet(for: model) == .editor)
        VoicesPane.dismissSheet(model)
        #expect(model.draft == nil && VoicesPane.sheet(for: model) == nil)
        #expect(rig.updates == 0)

        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Sources/SupervoxApp/SettingsUI/VoicesPane.swift"),
            encoding: .utf8)
        // Les modificateurs, en début de ligne (`Self.sheet(for:` n'en est pas un).
        let modifiers = source.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(modifiers.filter { $0.hasPrefix(".sheet(") }.count == 1, "une seule feuille")
        for other in [".confirmationDialog(", ".alert(", ".popover(", ".fullScreenCover("] {
            #expect(!modifiers.contains { $0.hasPrefix(other) }, "aucune autre présentation : \(other)")
        }
    }

    /// L'éditeur tient dans 520×420 et son formulaire défile : avec le plus grand nombre de paramètres permis, sa taille ne bouge
    /// pas.
    @Test func theEditorKeepsItsSizeWithManyParameters() {
        let rig = Rig(VoicesModelTests.settings())
        let model = rig.model
        model.beginAdding()
        model.draft?.parameters = (0..<VoiceChoice.maxExtraEntries).map {
            VoicesModel.VoiceDraft.Parameter(key: "cle-exemple-\($0)", value: "valeur-exemple")
        }
        let host = NSHostingView(rootView: VoiceEditor(model: model))
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.width - VoiceEditor.size.width) < 1 && abs(host.fittingSize.height - VoiceEditor.size.height) < 1, "\(host.fittingSize)")
        #expect(VoiceEditor.size == CGSize(width: 520, height: 420))
    }

    // MARK: - Décisions 3 à 5 : ce que la vue montre

    /// La coche et le haut-parleur sont à la couleur d'accent, sauf sur la ligne surlignée (fond déjà à la couleur d'accent : vu
    /// dans l'image `reglages-voix-ecoute`, la marque y disparaissait) ; là, ils suivent le texte surligné. Ce test tient la règle
    /// de choix ; que la liste pose bien `backgroundProminence` à `.increased` sur la ligne choisie se voit dans les images.
    @Test func theRowMarksStayVisibleOnTheHighlightedRow() {
        #expect(VoicesPane.marksUseAccent(.standard))
        #expect(!VoicesPane.marksUseAccent(.increased))
    }

    /// Décision 3 : « Arrêter » dès qu'une ligne s'écoute, quelle que soit la ligne choisie, avec l'indicateur en préparation ;
    /// sinon « Écouter », actif selon `canListen`.
    @Test func theListenButtonStopsAnyListeningAndOtherwiseFollowsCanListen() {
        let row = RowID.system(identifier: "voix.exemple.a")
        #expect(
            VoicesPane.listenButton(listeningRow: row, state: .preparing, canListen: false)
                == .init(title: VoicesText.stopTitle, showsProgress: true, isEnabled: true, stops: true))
        #expect(
            VoicesPane.listenButton(listeningRow: row, state: .playing, canListen: false)
                == .init(title: VoicesText.stopTitle, showsProgress: false, isEnabled: true, stops: true))
        #expect(
            VoicesPane.listenButton(listeningRow: nil, state: .idle, canListen: true)
                == .init(title: VoicesText.listenTitle, showsProgress: false, isEnabled: true, stops: false))
        #expect(
            VoicesPane.listenButton(listeningRow: nil, state: .failed(.playback), canListen: false)
                == .init(title: VoicesText.listenTitle, showsProgress: false, isEnabled: false, stops: false))
    }

    /// Décision 3, sur le vrai modèle : la ligne écoutée n'est plus la ligne choisie (une autre est choisie) ; le geste du bouton
    /// arrête quand même l'écoute en cours.
    @Test func theListenGestureStopsEvenWhenAnotherRowIsChosen() async {
        let gate = TestGate()
        defer { gate.open() }
        let rig = Rig(VoicesModelTests.settings(), systemVoice: PreviewVoice(.held(gate, VoicePreviewTests.clip)))
        let model = rig.model
        model.selection = RowID.system(identifier: "voix.exemple.a")
        VoicesPane.toggleListening(model)
        #expect(model.listeningRow == RowID.system(identifier: "voix.exemple.a"))
        #expect(await until { rig.factory.system.texts.count == 1 }, "la synthèse est en cours (retenue par la porte)")
        model.selection = RowID.system(identifier: "voix.exemple.b")
        VoicesPane.toggleListening(model)
        #expect(model.listeningRow == nil)
        #expect(model.previewState == .idle)
        gate.open()
        #expect(await until { rig.factory.system.sawCancellation }, "l'écoute elle-même est arrêtée")
        await settle()
        #expect(rig.player.clips.isEmpty, "rien n'est joué")
    }

    /// Décision 5 : `message` d'abord, puis la panne de l'écoute, puis la vie privée ; rien sans aucun des trois.
    @Test func theBandShowsMessageThenPreviewFailureThenPrivacy() {
        #expect(VoicesPane.band(message: "m", previewMessage: "p", privacy: "v") == .init(text: "m", kind: .notice))
        #expect(VoicesPane.band(message: nil, previewMessage: "p", privacy: "v") == .init(text: "p", kind: .failure))
        #expect(VoicesPane.band(message: nil, previewMessage: nil, privacy: "v") == .init(text: "v", kind: .privacy))
        #expect(VoicesPane.band(message: nil, previewMessage: nil, privacy: nil) == nil)
    }

    /// Décision 5, sur le vrai modèle : la plus récente gagne. Une panne d'écoute après un refus d'enregistrement : le geste
    /// d'écoute efface le refus, la panne se voit. Un refus après une panne d'écoute : le refus se voit (il passe devant).
    @Test func theMostRecentOfARefusalAndAListeningFailureIsShown() async {
        let saved = VoicesModelTests.saved("Voix d'exemple A", id: 1)
        let model = Self.failingModel(.notFound, settings: VoicesModelTests.settings(voices: [saved]))
        model.selection = .saved(saved.id)
        model.beginAdding()
        model.save()  // brouillon sans nom : refusé
        model.draft = nil
        #expect(model.message == VoicesText.refusalEmptyName)
        func shown() -> String? {
            VoicesPane.band(message: model.message, previewMessage: model.previewMessage, privacy: model.privacyText)?.text
        }
        #expect(shown() == VoicesText.refusalEmptyName)

        VoicesPane.toggleListening(model)
        #expect(await until { model.previewMessage != nil })
        #expect(shown() == VoicesText.failure(.provider(.notFound)), "la panne d'écoute, plus récente, se voit")

        model.beginAdding()
        model.save()
        model.draft = nil
        #expect(shown() == VoicesText.refusalEmptyName, "le refus, plus récent, se voit")
    }

    /// Décision 4 : le sélecteur de langue a toujours une étiquette ÉGALE à sa valeur, même quand la langue en cours est écrite
    /// autrement qu'une langue de la liste (dédoublonnée sans casse, `-` et `_` confondus).
    @Test(arguments: ["fr_FR", "fr-fr", "FR-FR", "fr-FR", "it-IT"])
    func theLanguagePickerAlwaysHasATagForItsValue(_ current: String) {
        let rig = Rig(VoicesModelTests.settings(voice: VoiceChoice(language: current)))
        let model = rig.model
        #expect(model.language == current)
        let options = VoicesPane.languageOptions(model.languages, current: model.language)
        #expect(options.contains(current), "\(options)")
        #expect(options.count == model.languages.count, "aucune entrée ajoutée ni perdue")
        #expect(Set(options.map(VoicesModel.languageKey)).count == options.count, "aucun doublon")
        #expect(VoicesPane.languageOptions(model.languages, current: nil) == model.languages)
    }

    /// L'éditeur : le sélecteur du fournisseur et celui du genre ont toujours une étiquette égale à la valeur du brouillon.
    @Test func theEditorPickersAlwaysHaveATagForTheDraftValue() {
        let speaking = [VoicesModelTests.provider]
        let removed = UUID()
        #expect(VoiceEditor.providerOptions(speaking: speaking, current: removed).map(\.id).contains(removed))
        #expect(VoiceEditor.providerOptions(speaking: speaking, current: removed).first?.title == VoicesText.unusableProvider)
        #expect(VoiceEditor.providerOptions(speaking: speaking, current: nil).map(\.id) == [nil, VoicesModelTests.provider.id])
        #expect(VoiceEditor.providerOptions(speaking: [], current: nil).map(\.id) == [nil])
        #expect(VoiceEditor.providerOptions(speaking: speaking, current: VoicesModelTests.provider.id).map(\.id) == [VoicesModelTests.provider.id])
        for gender: VoiceGender? in [nil, .female, .male, .neutral, .other("voix-exemple")] {
            #expect(VoiceEditor.genderOptions(current: gender).contains(gender))
        }
        #expect(VoiceEditor.genderOptions(current: .other("voix-exemple")).count == 5)
        #expect(VoiceEditor.genderOptions(current: nil).count == 4)
    }

    // MARK: - Apparition, disparition (décisions 1 et 2)

    /// Pose le volet dans une fenêtre jamais affichée.
    private func show(_ model: VoicesModel) -> (window: NSWindow, host: NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(VoicesPane(model: model).frame(width: 600, height: 460)))
        host.frame = NSRect(x: 0, y: 0, width: 600, height: 460)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        return (window, host)
    }

    private func pump(_ host: NSView, until condition: () -> Bool) async {
        for _ in 0..<400 where !condition() {
            pumpOnce(host)
            await Task.yield()
        }
    }

    /// Un passage de la boucle d'exécution (synchrone : `RunLoop.run` n'existe pas en contexte asynchrone).
    private func pumpOnce(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(mode: .default, before: Date())
    }

    /// Décision 1 : un fournisseur retiré des réglages pendant que l'onglet n'est pas affiché ; à l'apparition du volet, sans
    /// aucun geste, la ligne de vie privée le montre, et le message d'avant est effacé.
    @Test func appearingRereadsTheSettingsAndClearsTheMessage() async {
        let saved = VoicesModelTests.saved("Voix d'exemple A", id: 1)
        let rig = Rig(VoicesModelTests.settings(voices: [saved]))
        let model = rig.model
        model.selection = .saved(saved.id)
        model.beginAdding()
        model.save()  // refusé : un message
        model.draft = nil
        #expect(model.message != nil)
        #expect(model.privacyText == VoicesText.privacyProvider("Fournisseur d'exemple"))
        rig.settings.providers.removeAll { $0.id == VoicesModelTests.provider.id }
        #expect(model.privacyText == VoicesText.privacyProvider("Fournisseur d'exemple"), "pas encore relu")

        let shown = show(model)
        await pump(shown.host) { model.privacyText == VoicesText.privacyCannotSpeak && model.message == nil }

        #expect(model.privacyText == VoicesText.privacyCannotSpeak, "l'apparition a relu les réglages")
        #expect(model.message == nil, "et effacé le message d'avant")
        withExtendedLifetime(shown.window) {}
    }

    /// Décision 2 : la disparition du volet (fenêtre retirée) arrête l'écoute (la lecture elle-même) et annule une confirmation en
    /// attente ; un brouillon ouvert est gardé.
    @Test func disappearingStopsThePreviewCancelsTheConfirmationAndKeepsTheDraft() async throws {
        let saved = VoicesModelTests.saved("Voix d'exemple A", id: 1)
        let rig = Rig(VoicesModelTests.settings(voices: [saved]), player: ScriptedClipPlayer(completion: .manual))
        let model = rig.model
        let shown = show(model)
        await pump(shown.host) { false }
        model.selection = RowID.system(identifier: "voix.exemple.a")
        model.listen()
        #expect(await until { rig.player.isPlaying }, "la lecture a commencé")
        model.selection = .saved(saved.id)
        model.requestDeletion()
        #expect(model.pendingDeletion == saved.id)

        shown.window.contentView = NSView()  // le volet disparaît
        await pump(shown.host) { model.pendingDeletion == nil && !rig.player.isPlaying }

        #expect(model.listeningRow == nil && model.previewState == .idle)
        #expect(!rig.player.isPlaying, "la lecture est arrêtée")
        #expect(model.pendingDeletion == nil, "la confirmation ne survit pas au volet")
        #expect(rig.updates == 0)

        let again = show(model)
        await pump(again.host) { false }
        model.selection = .saved(saved.id)
        model.beginEditing()
        again.window.contentView = NSView()
        await pump(again.host) { false }
        #expect(model.draft != nil, "un brouillon ouvert est gardé")
        withExtendedLifetime([shown.window, again.window]) {}
    }
}
