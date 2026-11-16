import AppKit
import SwiftUI

/// Le champ où l'on relit et corrige un texte avant de le coller : un `NSTextView` de texte brut dans un défileur.
///
/// Rien ne modifie le texte dans le dos de l'utilisateur (c'est souvent un prompt) : ni guillemets ni tirets typographiques,
/// ni remplacement, correction ou détection automatiques. L'annulation (⌘Z) est celle du champ, et d'aucune autre relecture
/// (voir `Coordinator`).
struct ReviewTextView: NSViewRepresentable {
    var text: String
    var isEditable: Bool
    /// Le champ prend la frappe dès qu'il est dans une fenêtre clé.
    var takesFocus: Bool
    var onEdit: @MainActor (String) -> Void
    /// ⌘Z (`.undo`) ou ⇧⌘Z (`.redo`) quand la pile d'annulation du champ n'a plus rien à défaire (ou refaire) : le panneau
    /// change alors de version du texte.
    var onHistoryEnd: @MainActor (EditingCommand) -> Void
    /// Une saisie en attente (texte marqué : touche morte, méthode de saisie) commence ou finit : tant qu'elle dure, le panneau ne
    /// change pas de version (voir `PanelModel.fieldIsComposing`).
    var onComposingChange: @MainActor (Bool) -> Void

    init(
        text: String, isEditable: Bool, takesFocus: Bool, onEdit: @escaping @MainActor (String) -> Void,
        onHistoryEnd: @escaping @MainActor (EditingCommand) -> Void,
        onComposingChange: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        self.text = text
        self.isEditable = isEditable
        self.takesFocus = takesFocus
        self.onEdit = onEdit
        self.onHistoryEnd = onHistoryEnd
        self.onComposingChange = onComposingChange
    }

    /// Le champ, configuré. Un `FocusingTextView` : voir `takesFocus`.
    static func makeTextView() -> NSTextView {
        let textView = FocusingTextView(frame: .zero)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        // Rien non plus ne s'insère, ne se complète ni ne se prédit : ni espaces « intelligents », ni complétion, ni
        // prédiction en ligne, ni Outils d'écriture (qui réécrivent le texte).
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.inlinePredictionType = .no
        textView.writingToolsBehavior = .none
        textView.setAccessibilityLabel("Texte à relire")
        textView.font = .preferredFont(forTextStyle: .callout)
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        return textView
    }

    /// Met le champ à jour. La chaîne n'est remplacée que si elle diffère de celle du champ : la remplacer par la même
    /// renverrait le curseur à la fin. Un texte remplacé de l'extérieur (une autre version, le texte reçu du modèle) vide la pile
    /// d'annulation du champ : ses actions visent des plages de l'ancien texte, et un ⌘Z sur un texte plus court lève
    /// `NSRangeException`. Une frappe, elle, remonte par `textDidChange` : le texte du modèle est alors déjà celui du champ, et
    /// rien n'est remplacé. Le champ et sa pile sont de plus neufs à chaque relecture.
    ///
    /// Jamais pendant une saisie en attente (touche morte, méthode de saisie : `hasMarkedText()`) : le texte marqué ne remonte
    /// pas par `textDidChange`, donc `text` a du retard, et la réécriture effacerait la saisie. Deux cas alors. Ou bien `text` est
    /// le dernier texte sur lequel le champ et le modèle étaient d'accord (`FocusingTextView.agreedText`) : un simple retard, rien
    /// à faire. Ou bien c'est un texte nouveau (une autre version) : il est gardé en attente (`pendingText`) et s'applique dès
    /// que la saisie est validée (`Coordinator.textDidChange`), de sorte que le champ et le contrôleur ne divergent jamais.
    static func update(_ textView: NSTextView, text: String, isEditable: Bool, takesFocus: Bool) {
        let field = textView as? FocusingTextView
        if textView.string == text {
            field?.agreedText = text
            field?.pendingText = nil
        } else if textView.hasMarkedText() {
            if let field, text != field.agreedText { field.pendingText = text }
        } else {
            textView.string = text
            textView.undoManager?.removeAllActions()
            field?.agreedText = text
            field?.pendingText = nil
        }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        (textView as? FocusingTextView)?.takesFocus = takesFocus
    }

    /// La hauteur que prend `text` à cette largeur dans un champ comme `textView` (même police, mêmes marges) : le texte mis en
    /// page (TextKit 2) dans une mise en page jetable, plus les marges du haut et du bas. Le champ lui-même n'est que lu : ni
    /// son texte, ni sa sélection, ni sa pile d'annulation, ni son conteneur ne bougent (une mesure faite pendant la frappe ne
    /// doit rien défaire). `layoutManager` n'est jamais touché : il ramènerait le champ à TextKit 1.
    static func contentHeight(of text: String, like textView: NSTextView, width: CGFloat) -> CGFloat {
        let inset = textView.textContainerInset
        let padding = textView.textContainer?.lineFragmentPadding ?? 5
        let storage = NSTextContentStorage()
        storage.attributedString = NSAttributedString(
            string: text, attributes: [.font: textView.font ?? NSFont.preferredFont(forTextStyle: .callout)])
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: max(width - 2 * inset.width, 1), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = padding
        layout.textContainer = container
        storage.addTextLayoutManager(layout)
        layout.ensureLayout(for: layout.documentRange)
        return ceil(layout.usageBoundsForTextContainer.height + 2 * inset.height)
    }

    /// La hauteur du texte que le champ montre maintenant.
    static func contentHeight(of textView: NSTextView, width: CGFloat) -> CGFloat {
        contentHeight(of: textView.string, like: textView, width: width)
    }

    /// Le champ prend la hauteur de son texte à la largeur qu'on lui propose, entre les deux bornes de
    /// `DictationText.editorHeight` ; au-delà, il défile. SwiftUI redemande cette taille chaque fois que le texte change, y
    /// compris à la frappe : la fenêtre du panneau suit (`FirstClickHostingView.layout`).
    ///
    /// La mesure porte sur le texte que SwiftUI donne (`text`) et ne touche pas au champ vivant : elle est demandée en pleine
    /// frappe (le panneau se mesure dans `textDidChange`, quand `text` peut être en retard d'une frappe), et réécrire le champ
    /// à ce moment effacerait ce qui vient d'être tapé. Un retard se corrige de lui-même : le brouillon change, SwiftUI
    /// redemande la taille avec le nouveau texte.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView else { return nil }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? Self.fallbackWidth
        let content = Self.contentHeight(of: text, like: textView, width: width)
        return CGSize(width: width, height: DictationText.editorHeight(contentHeight: content))
    }

    /// La largeur du champ quand on ne lui en propose aucune : celle du panneau (520) moins ses marges (2 x 16) et celles de la
    /// carte du champ (2 x 8).
    private static let fallbackWidth: CGFloat = 472

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = Self.makeTextView()
        textView.delegate = context.coordinator
        (textView as? FocusingTextView)?.onHistoryEnd = onHistoryEnd
        (textView as? FocusingTextView)?.onComposingChange = onComposingChange
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        Self.update(textView, text: text, isEditable: isEditable, takesFocus: takesFocus)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onEdit = onEdit
        guard let textView = scrollView.documentView as? NSTextView else { return }
        (textView as? FocusingTextView)?.onHistoryEnd = onHistoryEnd
        (textView as? FocusingTextView)?.onComposingChange = onComposingChange
        Self.update(textView, text: text, isEditable: isEditable, takesFocus: takesFocus)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var onEdit: @MainActor (String) -> Void
        /// La pile d'annulation de ce champ, et d'aucun autre : sans elle, le champ prendrait celle de la fenêtre, que le
        /// panneau garde d'une relecture à la suivante. Un ⌘Z au début d'une relecture défairait alors la frappe d'un champ
        /// qui n'existe plus.
        private let undoStack = UndoManager()

        init(onEdit: @escaping @MainActor (String) -> Void) { self.onEdit = onEdit }

        func undoManager(for view: NSTextView) -> UndoManager? { undoStack }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if let field = textView as? FocusingTextView {
                // La saisie est validée : le changement de version qui attendait s'applique (le mot tapé avec la saisie est
                // sacrifié, mais ni le champ ni le contrôleur ne gardent un texte que l'autre ne connaît pas).
                field.applyPendingText()
                field.agreedText = textView.string
            }
            onEdit(textView.string)
        }
    }
}

/// Un champ qui, s'il le demande (`takesFocus`), devient premier répondeur dès que deux conditions sont réunies, dans
/// n'importe quel ordre : il est dans une fenêtre, et cette fenêtre est clé. Le panneau devient clé au changement d'étape,
/// avant que SwiftUI ait posé le champ ; ou l'inverse.
final class FocusingTextView: NSTextView {
    var takesFocus = false {
        // Seulement au passage de faux à vrai : SwiftUI répète la valeur à chaque mise à jour, et l'utilisateur qui est allé
        // sur un bouton ne doit pas être ramené au champ.
        didSet { if takesFocus && !oldValue { focusIfPossible() } }
    }

    /// Appelé quand une saisie en attente (texte marqué) commence ou finit.
    var onComposingChange: (@MainActor (Bool) -> Void)?
    private var wasComposing = false

    /// Appelé quand ⌘Z (⇧⌘Z) n'a rien à défaire (refaire) dans la pile de ce champ.
    var onHistoryEnd: (@MainActor (EditingCommand) -> Void)?

    /// Le dernier texte sur lequel le champ et le modèle étaient d'accord : posé par `ReviewTextView.update` et par chaque
    /// frappe remontée. Pendant une saisie en attente, un texte du modèle qui lui est égal n'est qu'un retard.
    var agreedText: String?
    /// Un texte venu de l'extérieur pendant une saisie en attente : il remplace celui du champ dès qu'elle est validée.
    var pendingText: String?

    /// Remplace le texte par celui qui attendait, si la saisie est validée. La pile d'annulation est vidée, comme à tout
    /// remplacement venu de l'extérieur.
    func applyPendingText() {
        guard let pending = pendingText, !hasMarkedText() else { return }
        pendingText = nil
        if string != pending {
            string = pending
            undoManager?.removeAllActions()
        }
    }

    /// Le panneau sait quand une saisie est en attente (`PanelModel.fieldIsComposing`).
    private func reportComposing() {
        let composing = hasMarkedText()
        guard composing != wasComposing else { return }
        wasComposing = composing
        onComposingChange?(composing)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        reportComposing()
    }

    override func unmarkText() {
        super.unmarkText()
        reportComposing()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        reportComposing()
    }

    override func didChangeText() {
        super.didChangeText()
        reportComposing()
    }

    /// ⌘Z : la pile de ce champ d'abord (la frappe faite après une réécriture se défait la première), puis, quand elle est vide,
    /// la version précédente du texte. Rien ne se défait ni ne se change dans un champ en lecture seule (pendant une
    /// correction, le texte est celui que le modèle reçoit), et aucune version ne change pendant une saisie en attente : le champ
    /// ne remplacerait pas son texte, que le contrôleur croirait pourtant changé.
    func undoOrPreviousVersion() {
        guard isEditable else { return }
        if let manager = undoManager, manager.canUndo {
            manager.undo()
            // L'annulation ne prévient personne par elle-même : le brouillon du contrôleur reste le texte affiché.
            didChangeText()
        } else if !hasMarkedText() {
            onHistoryEnd?(.undo)
        }
    }

    /// ⇧⌘Z : de même, avec la version suivante.
    func redoOrNextVersion() {
        guard isEditable else { return }
        if let manager = undoManager, manager.canRedo {
            manager.redo()
            didChangeText()
        } else if !hasMarkedText() {
            onHistoryEnd?(.redo)
        }
    }

    /// `undo:` et `redo:`, tels que le panneau les envoie (`FloatingPanel.performKeyEquivalent`), passent par les deux méthodes
    /// ci-dessus. Interceptés ici plutôt que déclarés `@objc` : une méthode de ce sélecteur ferait avertir de `#selector` le
    /// test qui lit le menu Édition par `Selector(("undo:"))`.
    override func tryToPerform(_ action: Selector, with object: Any?) -> Bool {
        if action == NSSelectorFromString("undo:") {
            undoOrPreviousVersion()
            return true
        }
        if action == NSSelectorFromString("redo:") {
            redoOrNextVersion()
            return true
        }
        return super.tryToPerform(action, with: object)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowDidBecomeKey), name: NSWindow.didBecomeKeyNotification, object: window)
        focusIfPossible()
    }

    @objc private func windowDidBecomeKey(_ notification: Notification) { focusIfPossible() }

    private func focusIfPossible() {
        guard takesFocus, let window, window.isKeyWindow, window.firstResponder !== self else { return }
        window.makeFirstResponder(self)
    }
}
