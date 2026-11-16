import SwiftUI

/// La relecture dans le panneau : le texte dans un champ où l'on corrige, « Corriger à la voix », « Copier » et « Coller »
/// (l'action principale, ⌘↩). Elle ne décide de rien : `DictationDisplay.Review` dit ce qui est possible, ceci le dessine.
///
/// Pendant le collage (`isPasting`), le titre devient « Collage… » avec son indicateur d'attente, le champ est en lecture seule
/// et les boutons sont inactifs. Il n'y a pas de bouton « Corriger à la voix » à cette étape.
///
/// Pendant une correction à la voix, c'est le même écran : le champ est en lecture seule (à l'étape de la réécriture, il montre le
/// texte que le modèle envoie à mesure, à la place du brouillon), le titre dit l'étape, la forme d'onde et la durée de la consigne
/// s'ajoutent au-dessus du champ pendant l'écoute, et « Corriger à la voix » devient « Terminer ».
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
            // désigne ; pendant une correction, ce que l'on attend de l'utilisateur. Le même gris que les aides dessous.
            if let detail = display.detail { DetailText(text: detail, color: DetailText.systemSecondary) }
            actions
            hints
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

    /// L'aide de la relecture (aucune pendant le collage et la correction), puis celle de la correction. Même gris, le plus
    /// lisible (`DetailText.systemSecondary`) : deux lignes l'une sous l'autre ne se distinguent pas par la couleur.
    private var hints: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hint = review.hint { hintLine(hint) }
            if let correction = review.correctionHint(hotKeyLabel: hotKeyLabel) { hintLine(correction) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hintLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(DetailText.systemSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
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

    var body: some View {
        HStack(spacing: 8) {
            if review.canGoBack {
                VersionButton(
                    symbol: "arrow.uturn.backward", label: DictationText.previousVersionLabel, action: previousVersion)
            }
            if review.canGoForward {
                VersionButton(symbol: "arrow.uturn.forward", label: DictationText.nextVersionLabel, action: nextVersion)
            }
            Spacer(minLength: 0)
            if review.showsCorrectButton {
                Button {
                    correct()
                } label: {
                    Label(review.correctTitle, systemImage: review.finishesCorrection ? "stop.fill" : "mic")
                        .font(.caption)
                }
                .controlSize(.small)
                .disabled(!review.canPressCorrect)
            }
            CopyControls(state: review.copy, action: copy)
                .disabled(!review.canCopy)
            Button("Coller") { paste() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!review.canPaste)
        }
    }
}

/// Un bouton à flèche sans texte : son libellé est celui de VoiceOver et de l'info-bulle. Pas de raccourci clavier ici : ⌘Z et
/// ⇧⌘Z passent déjà par le champ (`ReviewView.history`).
private struct VersionButton: View {
    let symbol: String
    let label: String
    let action: @MainActor () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            Label(label, systemImage: symbol).labelStyle(.iconOnly)
        }
        .controlSize(.small)
        .help(label)
        .accessibilityLabel(label)
    }
}
