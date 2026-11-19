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

    /// Mesure le volet à cette taille. `after` : un geste joué APRÈS l'apparition du volet (qui efface le message d'avant), puis
    /// la mesure est reprise.
    private func measure(
        _ model: VoicesModel, width: CGFloat = SettingsView.windowSize.width, after: (() -> Void)? = nil
    ) throws -> VoicesPane.Metrics {
        var measured: VoicesPane.Metrics?
        let height = Self.paneHeight
        let host = NSHostingView(rootView: VoicesPane(model: model, onMeasure: { measured = $0 }).frame(width: width, height: height))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // Bornée : la mise en page se fait au passage de la boucle, jamais d'attente sans fin.
        for _ in 0..<300 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date())
        }
        if let after {
            after()
            for _ in 0..<300 {
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(mode: .default, before: Date())
            }
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

        // R7 (tour 2) : le refus (bande d'avis) est vraiment mesuré : il arrive APRÈS l'apparition du volet (qui efface le message
        // d'avant), le brouillon refusé fermé sans `cancel()` (qui effacerait le refus).
        let refused = Rig(settings).model
        let refuse = {
            refused.beginAdding()
            refused.draft?.name = " "
            refused.save()
            refused.draft = nil
        }
        let privacy = Rig(settings).model
        privacy.selection = .saved(saved.id)
        #expect(privacy.privacyText != nil)

        for (name, model, after) in [
            ("phrase la plus haute", failing, nil), ("refus", refused, refuse), ("vie privée", privacy, nil),
        ] as [(String, VoicesModel, (() -> Void)?)] {
            let metrics = try measure(model, after: after)
            if name == "refus" { #expect(refused.message == VoicesText.refusalEmptyName, "le refus est dans la bande") }
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

    // MARK: - B : l'éditeur (520×540, seule la zone des paramètres défile)

    /// Mesure l'éditeur à sa taille de feuille, posé dans une fenêtre jamais affichée (sans fenêtre, AppKit ne dimensionne pas le
    /// contenu d'une vue de défilement), passages bornés. Rend aussi l'hôte, pour y chercher les vues de défilement, et la fenêtre,
    /// que l'appelant garde en vie.
    private func measureEditor(_ model: VoicesModel) throws -> (metrics: VoiceEditor.Metrics, host: NSView, window: NSWindow) {
        var measured: VoiceEditor.Metrics?
        let host = NSHostingView(rootView: VoiceEditor(model: model, onMeasure: { measured = $0 }))
        host.frame = NSRect(origin: .zero, size: VoiceEditor.size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        for _ in 0..<300 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date())
        }
        return (try #require(measured, "l'éditeur n'a rien mesuré"), host, window)
    }

    /// Un brouillon de voix à `count` paramètres d'exemple.
    private func editing(_ count: Int) -> VoicesModel {
        let model = Rig(VoicesModelTests.settings()).model
        model.beginAdding()
        model.draft?.name = "Voix d'exemple A"
        model.draft?.parameters = (0..<count).map {
            VoicesModel.VoiceDraft.Parameter(key: "cle-exemple-\($0)", value: "valeur-exemple")
        }
        return model
    }

    /// Les vues de défilement d'AppKit sous `view` qui ont plus à montrer que leur fenêtre visible (on peut y faire défiler).
    static func scrollable(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scroll = view as? NSScrollView, let document = scroll.documentView,
            document.frame.height > scroll.contentView.bounds.height + 1
        {
            found.append(scroll)
        }
        for subview in view.subviews { found += scrollable(in: subview) }
        return found
    }

    static func inside(_ inner: CGRect?, _ outer: CGRect) -> Bool {
        guard let inner else { return false }
        return inner.minX >= outer.minX - 0.5 && inner.maxX <= outer.maxX + 0.5 && inner.minY >= outer.minY - 0.5
            && inner.maxY <= outer.maxY + 0.5
    }

    /// B1 : deux paramètres et le bouton « Ajouter un paramètre » se voient sans défiler : leurs cadres sont dans la feuille et dans
    /// la zone visible des paramètres ; rien ne défile.
    @Test func twoParametersAndTheAddButtonShowWithoutScrolling() throws {
        #expect(VoiceEditor.size == CGSize(width: 520, height: 540))
        let (metrics, host, window) = try measureEditor(editing(2))
        defer { withExtendedLifetime(window) {} }
        let sheet = CGRect(origin: .zero, size: VoiceEditor.size)
        let viewport = try #require(metrics[.parametersViewport])
        for probe in [VoiceEditor.Probe.parameterRow(0), .parameterRow(1)] {
            #expect(Self.inside(metrics[probe], sheet), "\(probe) : \(String(describing: metrics[probe]))")
            #expect(Self.inside(metrics[probe], viewport), "\(probe) dans la zone visible \(viewport)")
        }
        #expect(Self.inside(metrics[.addParameter], sheet), "\(String(describing: metrics[.addParameter]))")
        #expect(Self.inside(metrics[.saveButton], sheet))
        #expect(Self.scrollable(in: host).isEmpty, "rien ne défile avec deux paramètres")
    }

    /// B1 : avec douze paramètres, la zone des paramètres défile (une vue de défilement a plus à montrer que sa zone visible, et
    /// le douzième paramètre est au-delà), et elle seule : le titre, les six champs, « Ajouter un paramètre », « Annuler » et
    /// « Enregistrer » sont au même endroit qu'avec deux paramètres, à un point près ; la feuille garde sa taille.
    @Test func manyParametersScrollOnlyTheParameterZone() throws {
        let (few, _, fewWindow) = try measureEditor(editing(2))
        let (many, host, window) = try measureEditor(editing(12))
        defer { withExtendedLifetime((fewWindow, window)) {} }
        let viewport = try #require(many[.parametersViewport])
        let last = try #require(many[.parameterRow(11)])
        #expect(last.maxY > viewport.maxY + 1, "le douzième paramètre est au-delà de la zone visible : \(last) / \(viewport)")
        if let scroll = Self.scrollable(in: host).first, let document = scroll.documentView {
            print("Paramètres : zone visible \(scroll.contentView.bounds.height) points, contenu \(document.frame.height) points")
        }
        #expect(Self.scrollable(in: host).count == 1, "une seule zone défile : \(Self.scrollable(in: host).count)")
        for probe in [VoiceEditor.Probe.title, .fields, .cancelButton, .saveButton] {
            let a = try #require(few[probe]), b = try #require(many[probe])
            #expect(abs(a.minY - b.minY) < 1 && abs(a.maxY - b.maxY) < 1, "\(probe) a bougé : \(a) puis \(b)")
        }
        #expect(Self.inside(many[.addParameter], CGRect(origin: .zero, size: VoiceEditor.size)))
        #expect(abs(host.fittingSize.height - VoiceEditor.size.height) < 1, "\(host.fittingSize)")
    }

    /// B2 : la bande du refus garde sa hauteur fixe et ne recouvre ni la zone des paramètres, ni « Ajouter un paramètre », ni les
    /// boutons, avec trois paramètres (la zone visible à son plus haut).
    @Test func theRefusalBandCoversNothing() throws {
        let model = editing(3)
        model.draft?.name = ""
        model.save()
        #expect(model.message == VoicesText.refusalEmptyName)
        let (metrics, _, window) = try measureEditor(model)
        defer { withExtendedLifetime(window) {} }
        let band = try #require(metrics[.refusalSlot])
        #expect(abs(band.height - VoiceEditor.refusalSlotHeight) < 1, "\(band)")
        for probe in [VoiceEditor.Probe.parametersViewport, .addParameter, .cancelButton, .saveButton, .parameterRow(2)] {
            let frame = try #require(metrics[probe])
            #expect(!frame.insetBy(dx: 0.5, dy: 0.5).intersects(band), "\(probe) \(frame) sous la bande \(band)")
        }
    }

    /// Vu dans l'image de l'éditeur (tour 2) : la zone qui défile rognait le bord gauche des champs des paramètres. Chaque ligne
    /// a un retrait dans la zone : au moins 2 points sur les côtés, au moins 1 point au-dessus de la première ligne et sous la
    /// dernière ligne visible ; et deux lignes tiennent toujours sans défiler.
    @Test func theParameterFieldsAreNotClippedByTheirZone() throws {
        let (metrics, host, window) = try measureEditor(editing(2))
        defer { withExtendedLifetime(window) {} }
        let viewport = try #require(metrics[.parametersViewport])
        let first = try #require(metrics[.parameterRow(0)]), second = try #require(metrics[.parameterRow(1)])
        #expect(first.minX - viewport.minX >= 2, "à gauche : \(first) dans \(viewport)")
        #expect(viewport.maxX - first.maxX >= 2, "à droite : \(first) dans \(viewport)")
        #expect(first.minY - viewport.minY >= 1, "en haut : \(first) dans \(viewport)")
        #expect(viewport.maxY - second.maxY >= 1, "en bas : \(second) dans \(viewport)")
        #expect(Self.scrollable(in: host).isEmpty)
    }

    /// R2 (tour 2) : toute écriture de l'éditeur passe par une seule règle : sans brouillon en cours, elle est ignorée. Une écriture
    /// tardive de la liaison (un champ qui pousse sa valeur en perdant la main, après « Enregistrer » ou « Annuler ») ne recrée
    /// donc jamais un brouillon, ni la feuille. Avec un brouillon, elle s'applique.
    @Test func anEditorWriteNeverRecreatesADraft() {
        let model = Rig(VoicesModelTests.settings()).model
        let binding = VoiceEditor.draftBinding(model)
        #expect(model.draft == nil)
        binding.wrappedValue.name = "Voix d'exemple A"
        binding.wrappedValue = VoicesModel.VoiceDraft(name: "Voix d'exemple B")
        model.editDraft { $0.gender = .female }
        #expect(model.draft == nil, "sans brouillon, rien n'est recréé")
        #expect(VoicesPane.sheet(for: model) == nil, "et la feuille ne se rouvre pas")

        model.beginAdding()
        binding.wrappedValue.name = "Voix d'exemple A"
        model.editDraft { $0.gender = .female }
        #expect(model.draft?.name == "Voix d'exemple A" && model.draft?.gender == .female)
        model.cancel()
        binding.wrappedValue.name = "Voix d'exemple C"
        #expect(model.draft == nil, "après « Annuler », une écriture tardive est ignorée")
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
        // R6 (tour 2) : c'est le MODÈLE qui rend la langue du filtre telle qu'elle est écrite ; la vue n'y corrige rien.
        #expect(model.languages.contains(current), "\(model.languages)")
        #expect(Set(model.languages.map(VoicesModel.languageKey)).count == model.languages.count, "aucun doublon")
        #expect(VoicesPane.languageOptions(model.languages).map(\.code) == model.languages)
    }

    /// C1 (tâche 4, tour de correction 1) : le filtre montre la langue en clair, et garde le code pour valeur. Deux codes d'une même
    /// langue y ont deux libellés différents ; un code inventé y reste son code.
    @Test func theLanguageFilterShowsPlainNamesAndKeepsCodes() {
        let options = VoicesPane.languageOptions(["fr-CA", "fr_FR", "zz-ZZ"])
        #expect(options.map(\.code) == ["fr-CA", "fr_FR", "zz-ZZ"])
        #expect(options[0].label.contains("français") && options[1].label.contains("français"))
        #expect(options[0].label != options[1].label, "deux libellés différents pour deux codes du français")
        #expect(options[1].label == VoicesText.languageName("fr-FR"))
        #expect(options[2].label == "zz-ZZ")
        #expect(options.allSatisfy { !$0.label.contains("fr-") && !$0.label.contains("fr_") })
    }

    /// C1 : l'éditeur garde le code dans le champ (c'est ce qui est enregistré) et montre le nom en clair à côté ; rien à côté
    /// d'un code inconnu ou vide (il n'y a rien de plus clair à dire).
    @Test func theEditorShowsThePlainNameBesideTheCode() {
        #expect(VoiceEditor.languageHint("fr-FR") == VoicesText.languageName("fr-FR"))
        #expect(VoiceEditor.languageHint("fr-FR")?.contains("français") == true)
        #expect(VoiceEditor.languageHint("zz-ZZ") == nil)
        #expect(VoiceEditor.languageHint("") == nil)
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

    /// R9 (tour 2) : le sélecteur de genre de l'éditeur garde le genre d'origine de la voix parmi ses choix tant que l'éditeur est
    /// ouvert : on peut y revenir sans « Annuler ».
    @Test func theEditorKeepsTheOriginalGenderAmongItsChoices() {
        let original = VoiceGender.other("voix-exemple")
        let saved = VoicesModelTests.saved("Voix d'exemple A", id: 1, gender: original)
        let model = Rig(VoicesModelTests.settings(voices: [saved])).model
        model.selection = .saved(saved.id)
        model.beginEditing()
        #expect(model.draft?.originalGender == original)
        model.editDraft { $0.gender = .female }
        let options = VoiceEditor.genderOptions(current: model.draft?.gender, original: model.draft?.originalGender)
        #expect(options.contains(original), "le genre d'origine reste proposé : \(options)")
        #expect(options.contains(.female))
        model.editDraft { $0.gender = original }
        #expect(VoiceEditor.genderOptions(current: original, original: original).filter { $0 == original }.count == 1)
    }

    /// R8 (tour 2) : les libellés d'accessibilité, par le code (rien n'est vérifié avec VoiceOver). L'icône de la bande dit le genre
    /// du message ; le triangle d'une note dit « Avertissement » ; la coche de la ligne « Voix en vigueur » (absente de la liste)
    /// ne répète pas son titre ; les champs des paramètres se distinguent ; le bouton d'écoute porte son titre courant.
    @Test func theAccessibilityLabelsSayWhatTheIconsMean() {
        #expect(VoicesPane.iconLabel(.notice) == VoicesText.warningLabel)
        #expect(VoicesPane.iconLabel(.failure) == VoicesText.errorLabel)
        #expect(VoicesPane.iconLabel(.privacy) == VoicesText.informationLabel)
        #expect(Set([VoicesText.warningLabel, VoicesText.errorLabel, VoicesText.informationLabel]).count == 3)

        let rig = Rig(VoicesModelTests.settings(voice: VoiceChoice(identifier: "voix.exemple.absente", language: "fr-FR")))
        let rows = rig.model.rows
        let absent = rows.first { $0.id == .active }
        #expect(absent?.title == VoicesText.activeVoice)
        #expect(absent.map(VoicesPane.checkmarkLabel) == .some(nil), "la ligne dit déjà « Voix en vigueur »")
        let inForce = Rig(VoicesModelTests.settings()).model.rows.first { $0.isActive }
        #expect(inForce.map(VoicesPane.checkmarkLabel) == .some(VoicesText.activeVoice))
        let other = rows.first { !$0.isActive }
        #expect(other.map(VoicesPane.checkmarkLabel) == .some(nil))

        #expect(VoicesText.parameterKeyLabel(1) != VoicesText.parameterKeyLabel(2))
        #expect(VoicesText.parameterKeyLabel(1) == "Clé du paramètre 1")
        #expect(VoicesText.parameterValueLabel(2) == "Valeur du paramètre 2")
    }

    // MARK: - Apparition, disparition (décisions 1 et 2)

    /// Pose le volet dans une fenêtre jamais affichée.
    private func show(_ model: VoicesModel) -> (window: NSWindow, host: NSHostingView<AnyView>) {
        let host = NSHostingView(rootView: AnyView(VoicesPane(model: model).frame(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height)))
        host.frame = NSRect(origin: .zero, size: SettingsView.windowSize)
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

    // MARK: - R1 (tour 2) : la liste défile jusqu'à la ligne choisie

    /// La table d'AppKit qui porte la liste de SwiftUI, sous `view`.
    static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for subview in view.subviews { if let table = table(in: subview) { return table } }
        return nil
    }

    /// La ligne choisie de la table est dans sa partie visible.
    static func selectionIsVisible(in view: NSView) -> Bool {
        guard let table = table(in: view), table.selectedRow >= 0 else { return false }
        return NSLocationInRange(table.selectedRow, table.rows(in: table.visibleRect))
    }

    /// R1 : 40 voix installées inventées en `en-US`, filtre en `fr-FR` ; on enregistre une voix en `en-US`. Le filtre passe à
    /// `en-US` : la liste montre l'automatique, les 40 voix, puis la voix neuve, en bas, choisie. Mesure AppKit, dans une fenêtre
    /// jamais affichée : la table a plus de lignes que sa partie visible (sans défilement, la ligne du bas serait hors de vue), et
    /// la ligne choisie est dans la partie visible.
    @Test func theListScrollsToAJustSavedVoice() async throws {
        let installed = (1...40).map {
            SystemVoiceInfo(identifier: "voix.exemple.\($0)", language: "en-US", quality: 1, name: "Voix d'exemple \($0)")
        }
        let rig = Rig(VoicesModelTests.settings(), installed: installed)
        let model = rig.model
        #expect(model.language == "fr-FR")
        let shown = show(model)
        defer { withExtendedLifetime(shown.window) {} }
        await pump(shown.host) { false }
        model.beginAdding()
        var draft = VoicesModelTests.validDraft()
        draft.language = "en-US"
        model.draft = draft
        model.save()
        let saved = try #require(rig.settings.voices.first)
        #expect(model.language == "en-US")
        #expect(model.selection == .saved(saved.id))
        await pump(shown.host) { Self.selectionIsVisible(in: shown.host) }

        let table = try #require(Self.table(in: shown.host), "aucune table d'AppKit sous la liste")
        let range = table.rows(in: table.visibleRect)
        print("Liste : \(table.numberOfRows) lignes, visibles \(range.location)..<\(range.location + range.length), choisie \(table.selectedRow)")
        #expect(range.length > 0 && range.length < table.numberOfRows, "la liste a plus de lignes que sa partie visible")
        #expect(table.selectedRow == table.numberOfRows - 1, "la voix neuve est la dernière ligne, choisie")
        #expect(Self.selectionIsVisible(in: shown.host), "la ligne choisie est dans la partie visible")
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

    /// Décision 2, et R3 (tour 2, remplace « brouillon gardé ») : la disparition du volet (changement d'onglet, fenêtre retirée)
    /// arrête l'écoute (la lecture elle-même), annule une confirmation en attente et abandonne un brouillon ouvert.
    @Test func disappearingStopsThePreviewCancelsTheConfirmationAndAbandonsTheDraft() async throws {
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
        #expect(model.draft == nil, "un brouillon ouvert est abandonné")
        withExtendedLifetime([shown.window, again.window]) {}
    }
}
