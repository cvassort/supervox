import SwiftUI

/// La dictée dans le panneau : l'état, la durée, la forme d'onde, le texte en direct, le message et le dernier texte à
/// copier. Elle ne décide de rien : `DictationDisplay` dit quoi montrer, ceci le dessine.
///
/// Hauteur constante. La fenêtre du panneau prend sa taille quand elle s'ouvre, pas quand son contenu change : une zone qui
/// grandirait en cours de dictée serait coupée. Toute la zone a donc la même hauteur dans tous les états, et chaque texte
/// est borné (`DictationText`, `lineLimit`) pour ne jamais la dépasser.
struct DictationView: View {
    let display: DictationDisplay
    /// Le raccourci, montré sous « Prêt » ; `nil` s'il n'y en a aucun.
    let hotKeyLabel: String?
    /// Le texte vient d'être copié : le bouton le dit.
    let copied: Bool
    let copy: @MainActor () -> Void

    /// Hauteur de la zone, en points : le plus haut des états (un message de quatre lignes et le dernier texte, ou le
    /// texte en direct de quatre lignes avec la forme d'onde), vérifié sur les images.
    static let height: CGFloat = 200

    var body: some View {
        VStack(spacing: 10) {
            if display.mood == .ready, display.transcript == nil {
                Spacer(minLength: 0)
                ready
                Spacer(minLength: 0)
            } else {
                header
                if let bars = display.bars { Waveform(bars: bars) }
                if let live = display.liveText { liveText(live) }
                if let detail = display.detail { detailLine(detail) }
                if let transcript = display.transcript { TranscriptCard(transcript: transcript, copied: copied, copy: copy) }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.height, maxHeight: Self.height, alignment: .top)
    }

    // MARK: - Prêt

    private var ready: some View {
        VStack(spacing: 6) {
            Text(display.headline)
                .font(.title2.weight(.semibold))
            if display.showsHotKey, let label = hotKeyLabel {
                Text(label)
                    .font(.callout.monospaced())
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
                    Text(label).font(.callout.monospaced()).foregroundStyle(.secondary)
                }
            } else {
                MoodIcon(mood: display.mood)
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

    private func liveText(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            // Pendant la transcription finale, le texte en direct s'efface : il va être remplacé.
            .foregroundStyle(display.mood == .working ? .secondary : .primary)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func detailLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// L'icône du ton du titre : un point rouge pendant l'enregistrement, un indicateur d'attente pendant
/// la préparation et la transcription.
private struct MoodIcon: View {
    let mood: DictationDisplay.Mood

    var body: some View {
        switch mood {
        case .recording:
            // Plein et fixe : un indicateur qui pulse se lit mal sur une image, et se règle sur le mouvement réduit.
            Image(systemName: "circle.fill")
                .foregroundStyle(.red)
                .accessibilityLabel("Enregistrement en cours")
        case .working:
            ProgressView().controlSize(.small).frame(width: 16, height: 16)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
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
    let copied: Bool
    let copy: @MainActor () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(transcript.label ?? "Texte dicté")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copié" : "Copier", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .controlSize(.small)
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
