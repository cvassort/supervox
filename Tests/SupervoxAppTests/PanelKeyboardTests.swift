import AppKit
import Testing

@testable import SupervoxApp

/// La traduction d'une touche en commande d'édition : le panneau n'a pas de menu Édition (l'application est un agent de
/// barre de menus), il doit donc reconnaître lui-même ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V et ⌘A.
@Suite struct PanelEditingKeysTests {
    private let command: NSEvent.ModifierFlags = .command

    @Test func commandZIsUndo() {
        #expect(PanelEditingKeys.command(characters: "z", modifiers: command) == .undo)
    }

    @Test(arguments: ["z", "Z"])
    func shiftCommandZIsRedoWhateverTheCaseOfTheCharacter(_ characters: String) {
        #expect(PanelEditingKeys.command(characters: characters, modifiers: [.command, .shift]) == .redo)
    }

    @Test func commandX_C_V_AAreCutCopyPasteSelectAll() {
        #expect(PanelEditingKeys.command(characters: "x", modifiers: command) == .cut)
        #expect(PanelEditingKeys.command(characters: "c", modifiers: command) == .copy)
        #expect(PanelEditingKeys.command(characters: "v", modifiers: command) == .paste)
        #expect(PanelEditingKeys.command(characters: "a", modifiers: command) == .selectAll)
    }

    @Test(arguments: ["z", "x", "c", "v", "a"])
    func anOptionOrControlOnTopOfCommandIsNotAnEditingCommand(_ characters: String) {
        #expect(PanelEditingKeys.command(characters: characters, modifiers: [.command, .option]) == nil)
        #expect(PanelEditingKeys.command(characters: characters, modifiers: [.command, .control]) == nil)
        #expect(PanelEditingKeys.command(characters: characters, modifiers: [.command, .option, .control]) == nil)
        #expect(PanelEditingKeys.command(characters: characters, modifiers: [.command, .shift, .option]) == nil)
    }

    @Test(arguments: ["z", "x", "c", "v", "a"])
    func withoutCommandNothingIsTranslated(_ characters: String) {
        #expect(PanelEditingKeys.command(characters: characters, modifiers: []) == nil)
        #expect(PanelEditingKeys.command(characters: characters, modifiers: .shift) == nil)
        #expect(PanelEditingKeys.command(characters: characters, modifiers: .control) == nil)
        #expect(PanelEditingKeys.command(characters: characters, modifiers: .option) == nil)
    }

    @Test func anotherLetterOrAnythingElseIsNotTranslated() {
        #expect(PanelEditingKeys.command(characters: "b", modifiers: command) == nil)
        #expect(PanelEditingKeys.command(characters: "w", modifiers: command) == nil)
        #expect(PanelEditingKeys.command(characters: "", modifiers: command) == nil)
        #expect(PanelEditingKeys.command(characters: "zz", modifiers: command) == nil)
        #expect(PanelEditingKeys.command(characters: "1", modifiers: command) == nil)
    }

    /// Seul ⇧⌘Z est une commande avec Maj : ⇧⌘C, ⇧⌘V, ⇧⌘X, ⇧⌘A sont d'autres raccourcis (« coller en gardant le style »…).
    @Test(arguments: ["x", "c", "v", "a"])
    func shiftOnTopOfCommandOnlyMeansRedoForZ(_ characters: String) {
        #expect(PanelEditingKeys.command(characters: characters, modifiers: [.command, .shift]) == nil)
    }

    /// Verr. Maj, pavé numérique et touche de fonction ne sont pas des modificateurs de raccourci.
    @Test func capsLockAndOtherNonShortcutFlagsDoNotChangeTheCommand() {
        #expect(PanelEditingKeys.command(characters: "C", modifiers: [.command, .capsLock]) == .copy)
        #expect(PanelEditingKeys.command(characters: "z", modifiers: [.command, .numericPad]) == .undo)
    }

    @Test func selectorsAreTheStandardResponderActions() {
        #expect(PanelEditingKeys.selector(for: .undo) == NSSelectorFromString("undo:"))
        #expect(PanelEditingKeys.selector(for: .redo) == NSSelectorFromString("redo:"))
        #expect(PanelEditingKeys.selector(for: .cut) == NSSelectorFromString("cut:"))
        #expect(PanelEditingKeys.selector(for: .copy) == NSSelectorFromString("copy:"))
        #expect(PanelEditingKeys.selector(for: .paste) == NSSelectorFromString("paste:"))
        #expect(PanelEditingKeys.selector(for: .selectAll) == NSSelectorFromString("selectAll:"))
    }
}

/// Le champ de relecture : un texte brut, que rien ne modifie dans le dos de l'utilisateur (c'est un prompt).
@MainActor @Suite struct ReviewTextViewTests {
    @Test func theFieldIsPlainTextWithUndo() {
        let textView = ReviewTextView.makeTextView()
        #expect(!textView.isRichText)
        #expect(!textView.importsGraphics)
        #expect(textView.allowsUndo)
    }

    /// Vérifié sur un `NSTextView` nu (sonde) : `isAutomaticLinkDetectionEnabled`, `isAutomaticDataDetectionEnabled` et
    /// `importsGraphics` valent déjà `false` par défaut ; ces trois assertions ne tomberaient donc pas sans `makeTextView`,
    /// elles gardent seulement contre un changement de défaut. Les autres valent `true` par défaut (`isRichText`, citations,
    /// tirets, remplacement, correction orthographique, insertion intelligente, complétion).
    @Test func nothingRewritesWhatTheUserTypes() {
        let textView = ReviewTextView.makeTextView()
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled)
        #expect(!textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled)
        #expect(!textView.isAutomaticSpellingCorrectionEnabled)
        #expect(!textView.isAutomaticLinkDetectionEnabled)
        #expect(!textView.isAutomaticDataDetectionEnabled)
    }

    /// Réglages voisins qui modifient aussi un texte à l'insu de l'utilisateur ; tous `true` ou par défaut sur un champ nu.
    @Test func smartInsertionCompletionPredictionAndWritingToolsAreOff() {
        let textView = ReviewTextView.makeTextView()
        #expect(!textView.smartInsertDeleteEnabled)
        #expect(!textView.isAutomaticTextCompletionEnabled)
        #expect(textView.inlinePredictionType == .no)
        #expect(textView.writingToolsBehavior == .none)
    }

    @Test func theFieldHasAnAccessibilityLabel() {
        let textView = ReviewTextView.makeTextView()
        #expect(textView.accessibilityLabel() == "Texte à relire")
    }

    @Test func theFieldUsesTheSystemCalloutFont() {
        let textView = ReviewTextView.makeTextView()
        #expect(textView.font == NSFont.preferredFont(forTextStyle: .callout))
    }

    @Test func aDifferentStringReplacesTheFieldsAndTheSameOneLeavesItAlone() {
        let textView = ReviewTextView.makeTextView()
        ReviewTextView.update(textView, text: "bonjour", isEditable: true, takesFocus: false)
        #expect(textView.string == "bonjour")

        // Le curseur est au milieu : remplacer la chaîne par la même le renverrait à la fin.
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        ReviewTextView.update(textView, text: "bonjour", isEditable: true, takesFocus: false)
        #expect(textView.selectedRange() == NSRange(location: 3, length: 0))

        ReviewTextView.update(textView, text: "au revoir", isEditable: true, takesFocus: false)
        #expect(textView.string == "au revoir")
    }

    @Test func editabilityFollowsTheModel() {
        let textView = ReviewTextView.makeTextView()
        ReviewTextView.update(textView, text: "", isEditable: false, takesFocus: false)
        #expect(!textView.isEditable)
        ReviewTextView.update(textView, text: "", isEditable: true, takesFocus: false)
        #expect(textView.isEditable)
    }
}
