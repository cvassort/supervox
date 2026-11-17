import SwiftUI

/// L'entretien dans le panneau : l'orbe et l'état, la question de Supervox, la dernière réplique de la personne, le compteur, l'avis,
/// « Conclure », puis le pied (Échap, vie privée). Elle ne décide de rien : `InterviewViewState` dit quoi montrer, ceci le dessine.
///
/// Hauteur naturelle, comme la dictée : le panneau suit son contenu. Les deux textes sont bornés (`InterviewText.questionLimit`,
/// `DictationText.transcriptLimit`, `lineLimit`), donc la hauteur l'est aussi.
struct InterviewView: View {
    let state: InterviewViewState
    /// « Conclure » : `PanelModel.concludeInterview`.
    let conclude: @MainActor () -> Void
    /// « Réduire les animations » : lu ici, donné à l'orbe, qui ne bouge plus.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if !state.questionText.isEmpty { supervoxText }
            if let reply = state.shownReply { replyCard(reply) }
            if let notice = state.notice { noticeLine(notice) }
            if let note = state.shownHoldNote { DetailText(text: note) }
            HStack {
                Spacer(minLength: 0)
                ConcludeButton(enabled: state.canConclude, action: conclude)
            }
            VStack(alignment: .leading, spacing: 4) {
                if let cancel = state.cancelHint { DetailText(text: cancel) }
                DetailText(text: state.privacy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            InterviewOrb(level: state.level, phase: state.phase, reduceMotion: reduceMotion)
            VStack(alignment: .leading, spacing: 4) {
                // L'orbe porte déjà le titre pour VoiceOver : le texte ne se lit pas une seconde fois.
                Text(state.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
                if let counter = state.counter {
                    Text(counter)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(DetailText.systemSecondary)
                }
                if let hint = state.hint { DetailText(text: hint) }
            }
            Spacer(minLength: 0)
        }
    }

    /// La réplique de Supervox, en cours ou la dernière : sa fin si elle est longue.
    private var supervoxText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(InterviewText.supervoxLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(DetailText.systemSecondary)
            Text(state.questionText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// La dernière réplique de la personne, ou sa transcription provisoire : elle change à mesure qu'on parle, VoiceOver ne
    /// l'annonce pas à chaque fois.
    private func replyCard(_ reply: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(InterviewText.youLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(DetailText.systemSecondary)
            Text(reply)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func noticeLine(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(notice)
                .font(.callout)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// « Conclure » : grisé en préparation et en conclusion (`InterviewViewState.canConclude`).
struct ConcludeButton: View {
    let enabled: Bool
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(InterviewText.concludeLabel)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!enabled)
        .accessibilityHint(InterviewText.concludeHelp)
    }
}

/// Ce que l'orbe dit à VoiceOver : le titre de l'état comme libellé, et rien d'un bouton. Une donnée, que l'orbe applique et que le
/// test interroge.
struct OrbAccessibility {
    let label: String
    let traits: AccessibilityTraits

    init(phase: InterviewPhase) {
        label = InterviewText.title(phase)
        traits = .isImage
    }
}

/// Comment l'orbe se dessine pour un niveau de micro : une fonction pure de `(niveau, phase, « Réduire les animations »)`.
///
/// Normalement l'orbe grandit avec le niveau. Avec « Réduire les animations » elle reste fixe et l'intensité passe par l'opacité
/// seulement. Une phase d'attente (préparation, réflexion, conclusion) l'éteint : ce n'est pas à la personne de parler.
struct OrbAppearance: Equatable {
    /// Taille du halo, 1 au repos.
    let scale: CGFloat
    let opacity: Double

    /// De combien le halo grandit au niveau 1 : 15 %. Choix non mesuré.
    static let growth: CGFloat = 0.15
    /// Opacité d'une phase d'attente : 45 %. Choix non mesuré.
    static let waitingOpacity = 0.45
    /// Opacité au silence, avec « Réduire les animations » : la moitié de l'opacité pleine, le niveau 1 la rend entière. Choix non
    /// mesuré.
    static let quietShare = 0.5

    init(level: Float, phase: InterviewPhase, reduceMotion: Bool) {
        // Un niveau absurde (NaN, négatif, infini) ne casse pas l'orbe : NaN est le silence.
        let clamped = level.isNaN ? 0 : min(max(Double(level), 0), 1)
        let base: Double =
            switch phase {
            case .listening, .speaking: 1
            case .preparing, .thinking, .concluding: Self.waitingOpacity
            }
        if reduceMotion {
            scale = 1
            opacity = base * (Self.quietShare + (1 - Self.quietShare) * clamped)
        } else {
            scale = 1 + Self.growth * CGFloat(clamped)
            opacity = base
        }
    }
}

/// L'orbe : un cœur et un halo qui suit le niveau du micro. Pas d'animation en boucle : seul le niveau la fait bouger, et sans
/// « Réduire les animations » elle ne bouge plus du tout.
struct InterviewOrb: View {
    let level: Float
    let phase: InterviewPhase
    let reduceMotion: Bool

    /// Le cadre fixe de l'orbe : le halo au plus grand (76 × 1,15 = 87,4) y tient, la vue ne change pas de taille avec le niveau.
    static let frame: CGFloat = 92

    var body: some View {
        let look = OrbAppearance(level: level, phase: phase, reduceMotion: reduceMotion)
        let accessibility = OrbAccessibility(phase: phase)
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.22))
                .frame(width: 76, height: 76)
                .scaleEffect(look.scale)
            Circle()
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                .frame(width: 52, height: 52)
        }
        .opacity(look.opacity)
        .frame(width: Self.frame, height: Self.frame)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: look)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility.label)
        .accessibilityAddTraits(accessibility.traits)
    }
}

/// Les pastilles de modes : inactives pendant l'entretien (`PanelModel.modesLocked`).
struct ModeChips: View {
    let modes: [ModeChip]
    let selectedID: String
    let locked: Bool
    let select: @MainActor (String) -> Void

    var body: some View {
        // Les pastilles des réglages, dans leur ordre ; à la ligne quand elles débordent, le panneau grandit.
        ChipFlowLayout {
            ForEach(modes) { mode in
                ModeChipButton(title: mode.title, isSelected: mode.id == selectedID) { select(mode.id) }
                    // Le mode en cours reste lisible (un bouton inactif est estompé par le système) ; les autres, qu'on ne peut plus
                    // choisir, s'effacent.
                    .disabled(locked && mode.id != selectedID)
                    .opacity(locked && mode.id != selectedID ? 0.5 : 1)
            }
        }
    }
}
