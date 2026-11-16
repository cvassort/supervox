import SwiftUI

/// La dictée dans le panneau : l'état, la durée, la forme d'onde, le texte en direct, le message et le dernier texte à
/// copier. Elle ne décide de rien : `DictationDisplay` dit quoi montrer, ceci le dessine.
///
/// Hauteur naturelle. Le panneau suit son contenu (`PanelController.contentChanged` : la fenêtre, ancrée par le haut, grandit et
/// rétrécit vers le bas), donc chaque état prend la place qu'il lui faut. Pendant l'enregistrement et la transcription, la
/// place de quatre lignes de texte en direct est réservée dès le début : la fenêtre ne saute pas à chaque ligne qui s'ajoute.
/// Tout texte est borné (`DictationText`, `lineLimit`), donc la hauteur l'est aussi.
struct DictationView: View {
    let display: DictationDisplay
    /// Le raccourci, montré sous « Prêt » ; `nil` s'il n'y en a aucun.
    let hotKeyLabel: String?
    let copy: @MainActor () -> Void
    /// Le texte en relecture a changé (le texte entier, tel quel) ; sans effet hors relecture.
    let edit: @MainActor (String) -> Void
    let paste: @MainActor () -> Void
    /// ⌘Z ou ⇧⌘Z en bout de pile du champ : changer de version.
    var history: @MainActor (EditingCommand) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 10) {
            if let review = display.review {
                ReviewView(display: display, review: review, edit: edit, paste: paste, copy: copy, history: history)
            } else if display.mood == .ready, display.transcript == nil {
                ready
                    .frame(maxWidth: .infinity, minHeight: 84)
            } else {
                header
                if let bars = display.bars { Waveform(bars: bars) }
                // Pendant la prise (durée affichée), la place du texte est réservée même sans texte encore. Pendant la mise en
                // forme, elle l'est aussi : la phrase d'attente d'abord, puis le texte du modèle à mesure qu'il arrive.
                if display.duration != nil {
                    liveText(display.liveText ?? "", dimmed: display.mood == .working)
                } else if let waiting = display.waitingText {
                    liveText(waiting, dimmed: true)
                } else if let received = display.liveText {  // la mise en forme : sans durée
                    liveText(received, dimmed: false, label: display.streamLabel)
                }
                if let detail = display.detail { DetailText(text: detail) }
                if let hint = display.cancelHint { DetailText(text: hint, color: DetailText.systemSecondary) }
                if let transcript = display.transcript { TranscriptCard(transcript: transcript, copy: copy) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Prêt

    private var ready: some View {
        VStack(spacing: 6) {
            Text(display.headline)
                .font(.title2.weight(.semibold))
            if display.showsHotKey, let label = hotKeyLabel {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Les autres états

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if display.mood == .ready {
                // « Prêt », avec le dernier texte dessous : un titre simple, pas l'écran d'accueil.
                Text(display.headline).font(.headline)
                if display.showsHotKey, let label = hotKeyLabel {
                    Text(label).font(.callout).foregroundStyle(.secondary)
                }
            } else {
                MoodIcon(mood: display.mood, workingLabel: display.activityLabel)
                Text(display.headline)
                    .font(.headline)
                    .lineLimit(display.mood == .info ? 3 : 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let duration = display.duration {
                Text(duration)
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Durée \(duration)")
            }
        }
    }

    /// `dimmed` : le texte s'efface (la transcription finale va le remplacer ; ou c'est la phrase d'attente, non du texte).
    ///
    /// `label` : la réponse du modèle, exposée à VoiceOver sous ce libellé, le texte en valeur (sans le « … » de tête, qui se
    /// lirait « points de suspension »). `updatesFrequently` : le texte change à chaque morceau, VoiceOver ne l'annonce pas à
    /// chaque fois ; il le lit quand on s'y place.
    @ViewBuilder
    private func liveText(_ text: String, dimmed: Bool, label: String? = nil) -> some View {
        if let label {
            liveTextBody(text, dimmed: dimmed)
                .accessibilityLabel(label)
                .accessibilityValue(text.hasPrefix("… ") ? String(text.dropFirst(2)) : text)
                .accessibilityAddTraits(.updatesFrequently)
        } else {
            liveTextBody(text, dimmed: dimmed)
        }
    }

    private func liveTextBody(_ text: String, dimmed: Bool) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(dimmed ? AnyShapeStyle(DetailText.systemSecondary) : AnyShapeStyle(.primary))
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            // La place de quatre lignes (une ligne de `callout` fait 15 points, relevé sur les images), réservée pendant
            // la prise : `lineLimit(_:reservesSpace:)` ne la réservait pas ici (mesuré : une ligne pour un texte vide).
            .frame(maxWidth: .infinity, minHeight: 4 * 15 + 2, alignment: .topLeading)
    }
}

/// Le message sous le titre : quatre lignes au plus en `caption` (`DictationText.detailLimit`).
struct DetailText: View {
    let text: String
    var color: Color = .secondary

    /// Le gris des deux textes qui disent quoi attendre et comment annuler (« En attente… », la phrase d'Échap). Mesuré sur les
    /// images : le style `.secondary` de SwiftUI et `NSColor.secondaryLabelColor` rendent le même gris, à 3,08:1 sur le fond
    /// clair du panneau (sous les 4,5:1 des petits textes) ; 80 % du texte principal donne plus de 4,5:1, clair et sombre (l'image rend un gris plus pâle que l’opacité, hors fenêtre clé).
    static let systemSecondary = Color.primary.opacity(0.8)

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// L'icône du ton du titre : un point rouge pendant l'enregistrement, un indicateur d'attente pendant
/// la préparation et la transcription.
struct MoodIcon: View {
    let mood: DictationDisplay.Mood
    /// Le libellé que VoiceOver lit pour l'indicateur d'attente ; sans lui, l'indicateur garde son libellé du système.
    var workingLabel: String?

    var body: some View {
        switch mood {
        case .recording:
            // Plein et fixe : un indicateur qui pulse se lit mal sur une image, et se règle sur le mouvement réduit.
            Image(systemName: "circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Enregistrement en cours")
        case .working:
            if let workingLabel {
                ProgressView().controlSize(.small).frame(width: 16, height: 16).accessibilityLabel(workingLabel)
            } else {
                ProgressView().controlSize(.small).frame(width: 16, height: 16)
            }
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .review:
            // Décorative : « À relire » est à côté, VoiceOver ne doit pas lire un nom de symbole avant lui.
            Image(systemName: "square.and.pencil").foregroundStyle(.secondary).accessibilityHidden(true)
        case .info, .ready:
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
        }
    }
}

/// La forme d'onde : une barre par niveau, la plus récente à droite.
private struct Waveform: View {
    let bars: [Float]

    private static let height: CGFloat = 32

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, level in
                Capsule()
                    .fill(Color.accentColor.opacity(level > 0 ? 1 : 0.3))
                    .frame(width: 5, height: max(3, CGFloat(level) * Self.height))
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height)
        .accessibilityHidden(true)
    }
}

/// Le dernier texte dicté, sa fin, et le bouton « Copier ».
private struct TranscriptCard: View {
    let transcript: DictationDisplay.Transcript
    let copy: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transcript.label ?? "Texte dicté")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                CopyControls(state: transcript.copy, action: copy)
            }
            Text(transcript.text)
                .font(.callout)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.disabled)
        }
        .padding(8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// « Copier » (« Copié » une fois fait), et à sa gauche « Copie impossible » quand le presse-papiers a refusé : le même bouton
/// sur la carte du dernier texte et dans la relecture. Les deux vues sont des enfants directs de la rangée qui l'emploie.
struct CopyControls: View {
    let state: CopyState
    let action: @MainActor () -> Void

    var body: some View {
        if state == .failed {
            Label(DictationText.copyFailure, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
        Button {
            action()
        } label: {
            Label(DictationText.copyLabel(for: state), systemImage: state == .copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
        }
        .controlSize(.small)
    }
}
