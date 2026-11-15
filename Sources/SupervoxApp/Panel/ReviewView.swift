import SwiftUI

/// La relecture dans le panneau : le texte dans un champ où l'on corrige, « Copier » et « Coller » (l'action principale, ⌘↩).
/// Elle ne décide de rien : `DictationDisplay.Review` dit ce qui est possible, ceci le dessine.
///
/// Pendant le collage (`isPasting`), le titre devient « Collage… » avec son indicateur d'attente, le champ est en lecture seule
/// et les boutons sont inactifs. Il n'y a pas de bouton « Corriger à la voix » à cette étape.
///
/// La hauteur du champ est celle de son texte, entre `DictationText.editorMinHeight` et `editorMaxHeight`
/// (`ReviewTextView.sizeThatFits`) : le panneau grandit avec elle.
struct ReviewView: View {
    let display: DictationDisplay
    let review: DictationDisplay.Review
    let edit: @MainActor (String) -> Void
    let paste: @MainActor () -> Void
    let copy: @MainActor () -> Void

    var body: some View {
        VStack(spacing: 10) {
            header
            field
            // La raison d'un collage qui n'a pas eu lieu, sous le texte qu'elle désigne.
            if let detail = display.detail { DetailText(text: detail) }
            actions
            if !review.isPasting {
                Text(DictationText.reviewHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MoodIcon(mood: display.mood)
            Text(display.headline)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    /// `edit` va tel quel au champ : ni rognage, ni normalisation, ni report au tour suivant.
    private var field: some View {
        ReviewTextView(text: review.text, isEditable: review.isEditable, takesFocus: review.isEditable, onEdit: edit)
            .padding(8)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            .opacity(review.isPasting ? 0.6 : 1)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            CopyControls(state: review.copy, action: copy)
                .disabled(!review.canCopy)
            Button("Coller") { paste() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!review.canPaste)
        }
    }
}
