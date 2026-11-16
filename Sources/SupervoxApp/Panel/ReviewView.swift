import SwiftUI

/// La relecture dans le panneau : le texte dans un champ où l'on corrige, puis la rangée « Corriger à la voix », « Copier » et
/// « Coller » (l'action principale, ⌘↩), à laquelle s'ajoutent à gauche les flèches des versions quand elles existent. Elle ne
/// décide de rien : `DictationDisplay.Review` dit ce qui est possible, ceci le dessine.
///
/// Pendant le collage (`isPasting`), le titre devient « Collage… » avec son indicateur d'attente, le champ est en lecture seule,
/// « Copier » et « Coller » sont inactifs et il n'y a pas de bouton « Corriger à la voix ».
///
/// Pendant une correction à la voix, c'est le même écran : le champ est en lecture seule (à l'étape de la réécriture, il montre le
/// texte que le modèle envoie à mesure, à la place du brouillon), le titre dit l'étape, la forme d'onde et la durée de la consigne
/// s'ajoutent au-dessus du champ pendant l'écoute, « Corriger à la voix » devient « Terminer » (actif seulement à l'écoute),
/// « Copier » et « Coller » sont inactifs (on ne copie ni ne colle un texte que l'écran ne montre pas) et une ligne dit ce
/// qu'Échap fait. Les lignes d'aide sous la rangée sont décidées par `hintLines`.
///
/// La hauteur du champ est celle de son texte, entre `DictationText.editorMinHeight` et `editorMaxHeight`
/// (`ReviewTextView.sizeThatFits`) : le panneau grandit avec elle.
struct ReviewView: View {
    let display: DictationDisplay
    let review: DictationDisplay.Review
    /// Le libellé du raccourci global réel, nommé par l'aide de la correction ; `nil` s'il n'y en a aucun.
    var hotKeyLabel: String?
    let edit: @MainActor (String) -> Void
    let paste: @MainActor () -> Void
    let copy: @MainActor () -> Void
    /// ⌘Z ou ⇧⌘Z que la pile du champ n'a plus à défaire ou refaire : le changement de version.
    var history: @MainActor (EditingCommand) -> Void = { _ in }
    /// Une saisie en attente (texte marqué) commence ou finit dans le champ.
    var composing: @MainActor (Bool) -> Void = { _ in }
    var correct: @MainActor () -> Void = {}
    var previousVersion: @MainActor () -> Void = {}
    var nextVersion: @MainActor () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            header
            // La consigne qui se dit : la forme d'onde, au-dessus du champ qui garde le brouillon.
            if let bars = display.bars { Waveform(bars: bars) }
            field
            // La raison d'un collage qui n'a pas eu lieu, ou d'une correction qui n'a pas changé le texte, sous le texte qu'elle
            // désigne ; pendant une correction, ce que l'on attend de l'utilisateur.
            if let detail = display.detail { DetailText(text: detail) }
            actions
            // Aucune ligne, aucune vue : une pile vide compterait pour une vue dans l'espacement de celle-ci.
            if !hintLines.isEmpty { hints }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MoodIcon(mood: display.mood, workingLabel: display.activityLabel)
            Text(display.headline)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let duration = display.duration { DurationText(duration: duration) }
        }
    }

    /// `edit` va tel quel au champ : ni rognage, ni normalisation, ni report au tour suivant.
    private var field: some View {
        ReviewTextView(
            text: review.text, isEditable: review.isEditable, takesFocus: review.isEditable, onEdit: edit, onHistoryEnd: history,
            onComposingChange: composing)
            // Un champ vide le dit : `NSTextView` n'a pas de texte de substitution. Même place que le premier caractère (marge
            // de ligne de 5 points, 2 de marge du haut), sans prendre le clic.
            .overlay(alignment: .topLeading) {
                if review.showsPlaceholder {
                    Text(DictationText.reviewPlaceholder)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .opacity(review.isPasting ? 0.6 : 1)
    }

    private var actions: some View {
        ReviewActions(
            review: review, paste: paste, copy: copy, correct: correct, previousVersion: previousVersion,
            nextVersion: nextVersion)
    }

    /// Les lignes d'aide sous la rangée, dans l'ordre : l'aide de la relecture (aucune pendant le collage et la correction), celle
    /// de la correction (seulement quand on peut corriger, et pas sous un message : le bouton est juste au-dessus et le message est
    /// la nouvelle), puis ce qu'Échap fait pendant la correction. Chacune une seule fois.
    static func hintLines(display: DictationDisplay, review: DictationDisplay.Review, hotKeyLabel: String?) -> [String] {
        [
            review.hint,
            display.detail == nil ? review.correctionHint(hotKeyLabel: hotKeyLabel) : nil,
            display.cancelHint,
        ].compactMap { $0 }
    }

    private var hintLines: [String] {
        Self.hintLines(display: display, review: review, hotKeyLabel: hotKeyLabel)
    }

    /// Même gris que les messages (`DetailText.systemSecondary`) : deux lignes l'une sous l'autre ne se distinguent pas par la couleur.
    private var hints: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(hintLines.enumerated()), id: \.offset) { _, line in DetailText(text: line) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Un bouton de la rangée de la relecture, comme une donnée : ce qu'il dessine, ce qu'il dit à VoiceOver, s'il est actif, et ce
/// qu'il déclenche. `ReviewActions.buttons(for:)` la décide, `ReviewActions` la dessine ; les tests l'interrogent sans fenêtre.
struct ReviewButton: Equatable, Identifiable {
    enum Action: Equatable {
        case previousVersion, nextVersion, correct, copy, paste
    }

    var action: Action
    /// Le nom du symbole ; `nil` pour un bouton sans glyphe (« Coller »).
    var symbol: String?
    /// Le texte visible ; `nil` pour un bouton à icône seule (les versions).
    var title: String?
    /// L'info-bulle ; seulement celle des boutons à icône seule, qui n'ont pas de texte pour se nommer.
    var help: String?
    /// Ce que VoiceOver lit.
    var accessibilityLabel: String
    var isEnabled: Bool

    var id: Action { action }
    /// Une flèche de version : à gauche de la rangée, sans texte.
    var isVersion: Bool { action == .previousVersion || action == .nextVersion }
}

/// La rangée de la relecture. À gauche, « Version précédente » et « Version suivante », en boutons à flèche quand elles existent :
/// avec leur texte, les cinq boutons ne tiendraient pas dans les 488 points du panneau (voir `CorrectionViewTests`). À droite,
/// « Corriger à la voix » (« Terminer » pendant l'écoute), « Copier » et « Coller » : inactifs quand `canPressCorrect`,
/// `canCopy` et `canPaste` sont faux (texte blanc, collage ou correction en cours).
struct ReviewActions: View {
    let review: DictationDisplay.Review
    let paste: @MainActor () -> Void
    let copy: @MainActor () -> Void
    var correct: @MainActor () -> Void = {}
    var previousVersion: @MainActor () -> Void = {}
    var nextVersion: @MainActor () -> Void = {}

    /// Les boutons de cette relecture, dans l'ordre où ils se dessinent.
    static func buttons(for review: DictationDisplay.Review) -> [ReviewButton] {
        var buttons: [ReviewButton] = []
        if review.canGoBack {
            buttons.append(
                ReviewButton(
                    action: .previousVersion, symbol: "arrow.uturn.backward", title: nil,
                    help: DictationText.previousVersionLabel, accessibilityLabel: DictationText.previousVersionLabel,
                    isEnabled: true))
        }
        if review.canGoForward {
            buttons.append(
                ReviewButton(
                    action: .nextVersion, symbol: "arrow.uturn.forward", title: nil, help: DictationText.nextVersionLabel,
                    accessibilityLabel: DictationText.nextVersionLabel, isEnabled: true))
        }
        if review.showsCorrectButton {
            buttons.append(
                ReviewButton(
                    action: .correct, symbol: review.finishesCorrection ? "stop.fill" : "mic", title: review.correctTitle,
                    help: nil, accessibilityLabel: review.correctTitle, isEnabled: review.canPressCorrect))
        }
        let copyLabel = DictationText.copyLabel(for: review.copy)
        buttons.append(
            ReviewButton(
                action: .copy, symbol: CopyControls.symbol(for: review.copy), title: copyLabel, help: nil,
                accessibilityLabel: copyLabel, isEnabled: review.canCopy))
        buttons.append(
            ReviewButton(
                action: .paste, symbol: nil, title: DictationText.pasteLabel, help: nil,
                accessibilityLabel: DictationText.pasteLabel, isEnabled: review.canPaste))
        return buttons
    }

    /// Ce que déclenche un bouton : sa fermeture, et seulement elle.
    func run(_ action: ReviewButton.Action) {
        switch action {
        case .previousVersion: previousVersion()
        case .nextVersion: nextVersion()
        case .correct: correct()
        case .copy: copy()
        case .paste: paste()
        }
    }

    var body: some View {
        let buttons = Self.buttons(for: review)
        HStack(spacing: 8) {
            ForEach(buttons.filter(\.isVersion)) { versionButton($0) }
            Spacer(minLength: 0)
            ForEach(buttons.filter { !$0.isVersion }) { button in
                if button.action == .copy, button.isEnabled, review.copy == .failed {
                    Label(DictationText.copyFailure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if button.action == .paste {
                    Button(button.title ?? "") { run(button.action) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!button.isEnabled)
                } else {
                    Button {
                        run(button.action)
                    } label: {
                        Label(button.title ?? "", systemImage: button.symbol ?? "")
                            .font(.caption)
                    }
                    .controlSize(.small)
                    .disabled(!button.isEnabled)
                }
            }
        }
    }

    /// Une flèche sans texte : son libellé est celui de VoiceOver et de l'info-bulle. Pas de raccourci clavier ici : ⌘Z et
    /// ⇧⌘Z passent déjà par le champ (`ReviewView.history`).
    private func versionButton(_ button: ReviewButton) -> some View {
        Button {
            run(button.action)
        } label: {
            Label(button.accessibilityLabel, systemImage: button.symbol ?? "").labelStyle(.iconOnly)
        }
        .controlSize(.small)
        .help(button.help ?? "")
        .accessibilityLabel(button.accessibilityLabel)
        .disabled(!button.isEnabled)
    }
}
