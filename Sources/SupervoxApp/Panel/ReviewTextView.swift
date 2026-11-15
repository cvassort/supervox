import AppKit
import SwiftUI

/// Le champ où l'on relit et corrige un texte avant de le coller : un `NSTextView` de texte brut dans un défileur.
///
/// Rien ne modifie le texte dans le dos de l'utilisateur (c'est souvent un prompt) : ni guillemets ni tirets typographiques,
/// ni remplacement, correction ou détection automatiques. L'annulation (⌘Z) est celle du champ.
struct ReviewTextView: NSViewRepresentable {
    var text: String
    var isEditable: Bool
    /// Le champ prend la frappe dès qu'il est dans une fenêtre clé.
    var takesFocus: Bool
    var onEdit: @MainActor (String) -> Void

    init(text: String, isEditable: Bool, takesFocus: Bool, onEdit: @escaping @MainActor (String) -> Void) {
        self.text = text
        self.isEditable = isEditable
        self.takesFocus = takesFocus
        self.onEdit = onEdit
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
    /// renverrait le curseur à la fin et vide la pile d'annulation.
    static func update(_ textView: NSTextView, text: String, isEditable: Bool, takesFocus: Bool) {
        if textView.string != text { textView.string = text }
        if textView.isEditable != isEditable { textView.isEditable = isEditable }
        (textView as? FocusingTextView)?.takesFocus = takesFocus
    }

    func makeCoordinator() -> Coordinator { Coordinator(onEdit: onEdit) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = Self.makeTextView()
        textView.delegate = context.coordinator
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
        Self.update(textView, text: text, isEditable: isEditable, takesFocus: takesFocus)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var onEdit: @MainActor (String) -> Void

        init(onEdit: @escaping @MainActor (String) -> Void) { self.onEdit = onEdit }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            onEdit(textView.string)
        }
    }
}

/// Un champ qui, s'il le demande (`takesFocus`), devient premier répondeur dès que deux conditions sont réunies, dans
/// n'importe quel ordre : il est dans une fenêtre, et cette fenêtre est clé. Le panneau devient clé au changement d'étape,
/// avant que SwiftUI ait posé le champ ; ou l'inverse.
final class FocusingTextView: NSTextView {
    var takesFocus = false {
        didSet { if takesFocus { focusIfPossible() } }
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
