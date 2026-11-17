import SwiftUI

/// L'entretien dans le panneau : l'orbe et l'état, la question de Supervox, la dernière réplique de la personne, le compteur, l'avis,
/// « Conclure », puis le pied (Échap, vie privée). Elle ne décide de rien : `InterviewViewState` dit quoi montrer, ceci le dessine.
///
/// Hauteur naturelle, comme la dictée : le panneau suit son contenu. La réplique de Supervox et celle de la personne vivent dans une
/// zone qui défile, plafonnée (`scrollMaxHeight`) et ancrée en haut : un texte long ne coupe jamais le début de la réplique, et le
/// pied et le menu « … » ne sont jamais poussés hors du panneau (`panelHeightBudget`, que `InterviewViewStateTests` mesure au pire cas).
struct InterviewView: View {
    let state: InterviewViewState
    /// « Conclure » : `PanelModel.concludeInterview`.
    let conclude: @MainActor () -> Void
    /// « Réduire les animations » : lu ici, donné à l'orbe, qui ne bouge plus.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Hauteur de la zone qui défile : 200 points, de l'ordre de treize lignes de `callout` (15 points la ligne, relevé sur les images de
    /// la dictée). Choix de mise en page, non mesuré sur un écran réel.
    static let scrollMaxHeight: CGFloat = 200
    /// Ce que le panneau d'entretien ne doit jamais dépasser au pire cas réaliste (textes très longs, avis le plus long, note de
    /// maintien, deux fournisseurs dans la vie privée) : 600 points, pour 591 mesurés sur l'image `entretien-pire-cas` (largeur de 520
    /// points). Choix de mise en page ; la hauteur utile d'un écran réel n'est pas établie ici.
    static let panelHeightBudget: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {  // espacements : choix de mise en page, non mesurés
            header
            if !state.questionText.isEmpty || state.shownReply != nil { texts }
            if let notice = state.notice { noticeLine(notice) }
            if let note = state.shownHoldNote { DetailText(text: note) }
            HStack {
                Spacer(minLength: 0)
                ConcludeButton(state: state, action: conclude)
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
            InterviewOrb(state: state, reduceMotion: reduceMotion)
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

    /// La réplique de Supervox et celle de la personne, entières, dans une zone qui défile ; la zone prend la hauteur du texte
    /// jusqu'à `scrollMaxHeight`, et reste ancrée en haut (le début de la réplique est ce qu'on lit d'abord).
    private var texts: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if !state.questionText.isEmpty { supervoxText }
                if let reply = state.shownReply { replyCard(reply) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: Self.scrollMaxHeight)
    }

    /// La réplique de Supervox, en cours ou la dernière.
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

    /// L'avis du moment (une phrase de `InterviewText`, au plus quatre lignes) ; il est annoncé à VoiceOver à son apparition
    /// (`PanelModel.setInterview`), pas relu à chaque mise à jour.
    private func noticeLine(_ notice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(DetailText.systemSecondary)
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

// MARK: - Conclure

/// « Conclure » : grisé en préparation et en conclusion. Reçoit l'état de l'entretien et lit `InterviewViewState.canConclude`, le seul
/// endroit qui le calcule : aucun booléen libre à écrire dans la vue.
struct ConcludeButton: View {
    let state: InterviewViewState
    let action: @MainActor () -> Void

    var body: some View {
        Button(action: action) {
            Text(InterviewText.concludeLabel)
        }
        .buttonStyle(ConcludeButtonStyle())
        .disabled(!state.canConclude)
        .accessibilityHint(InterviewText.concludeHelp)
    }
}

/// Le style de « Conclure » : une teinte d'accent pleine quand il est actif, un gris atténué quand il est grisé, **indépendants de
/// l'état clé de la fenêtre**. Le style du système (`borderedProminent`) se rend gris dans un panneau qui n'a pas la frappe, ce qui
/// rendait le bouton actif et le bouton grisé presque pareils ; le panneau n'a la frappe que si le contrôleur la lui donne.
struct ConcludeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ConcludeLabel(configuration: configuration)
    }

    private struct ConcludeLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(.medium))
                // Teintes, rayon et marges : choix de mise en page, jugés sur les images, clair et sombre.
                .foregroundStyle(isEnabled ? AnyShapeStyle(.white) : AnyShapeStyle(Color.primary.opacity(0.5)))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    isEnabled
                        ? AnyShapeStyle(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1))
                        : AnyShapeStyle(Color.primary.opacity(0.12)),
                    in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
    }
}

// MARK: - L'orbe

/// Ce que l'orbe dit à VoiceOver : le titre de l'état comme libellé, une image, rien d'un bouton. Une valeur testée, appliquée par ce
/// seul modificateur : l'orbe n'a pas d'autre chemin vers l'accessibilité.
struct OrbAccessibility: ViewModifier {
    let label: String
    let traits: AccessibilityTraits

    init(title: String) {
        label = title
        traits = .isImage
    }

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(traits)
    }
}

/// Comment l'orbe se dessine : une fonction pure de `(niveau, phase, texte seul, « Réduire les animations »)`.
///
/// Seule l'écoute suit le niveau du micro : pendant que Supervox parle ou réfléchit, le micro entend aussi l'écho et le bruit ambiant,
/// et une orbe qui pulse dirait « je vous écoute » quand Supervox parle. Le symbole dit qui a la parole : un micro en écoute, une onde
/// quand Supervox parle (un bulle de texte sans voix), trois points discrets en attente. En conclusion, un signe d'activité lent.
/// Avec « Réduire les animations » l'orbe reste fixe, l'intensité passe par l'opacité seulement (fondu court admis).
struct OrbAppearance: Equatable {
    /// Taille du halo, 1 au repos.
    let scale: CGFloat
    let opacity: Double
    /// Le nom du symbole du système au cœur de l'orbe.
    let symbol: String
    /// Le symbole pulse lentement (la conclusion, qui peut durer) ; jamais avec « Réduire les animations ».
    let pulses: Bool

    /// De combien le halo grandit au niveau 1 : 15 %. Choix non mesuré.
    static let growth: CGFloat = 0.15
    /// Opacité d'une phase d'attente : 45 %. Choix non mesuré.
    static let waitingOpacity = 0.45
    /// Opacité au silence, avec « Réduire les animations » : la moitié de l'opacité pleine, le niveau 1 la rend entière. Choix non
    /// mesuré.
    static let quietShare = 0.5

    init(level: Float, phase: InterviewPhase, textOnly: Bool = false, reduceMotion: Bool) {
        // Un niveau absurde (NaN, négatif, infini) ne casse pas l'orbe : NaN est le silence. Seule l'écoute le lit.
        let clamped = phase == .listening && !level.isNaN ? min(max(Double(level), 0), 1) : 0
        let base: Double =
            switch phase {
            case .listening, .speaking: 1
            case .preparing, .thinking, .concluding: Self.waitingOpacity
            }
        if reduceMotion && phase == .listening {
            scale = 1
            opacity = base * (Self.quietShare + (1 - Self.quietShare) * clamped)
        } else {
            scale = 1 + Self.growth * CGFloat(clamped)
            opacity = base
        }
        symbol =
            switch phase {
            case .listening: "mic.fill"
            case .speaking: textOnly ? "text.bubble.fill" : "waveform"
            case .preparing, .thinking, .concluding: "ellipsis"
            }
        pulses = phase == .concluding && !reduceMotion
    }
}

/// L'orbe : un cœur à symbole et un halo qui, à l'écoute seulement, suit le niveau du micro. Aucune animation en boucle sauf le
/// signe lent de la conclusion ; sans « Réduire les animations » le halo suit le niveau, avec elle il ne bouge plus du tout.
struct InterviewOrb: View {
    let state: InterviewViewState
    let reduceMotion: Bool

    /// Le cadre fixe de l'orbe : 92 points ; le halo au plus grand (76 × 1,15 = 87,4) y tient, la vue ne change pas de taille avec le
    /// niveau. Cœur de 52 points, symbole de 22 : choix de mise en page, jugés sur les images.
    static let frame: CGFloat = 92
    /// Le halo de 76 points est centré dans le cadre : son bord est à 8 points du bord gauche du cadre ; ce décalage est rendu pour
    /// que l'orbe s'aligne sur la colonne des textes.
    static let haloInset: CGFloat = (frame - 76) / 2

    var body: some View {
        let look = OrbAppearance(level: state.level, phase: state.phase, textOnly: state.textOnly, reduceMotion: reduceMotion)
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.22))
                .frame(width: 76, height: 76)
                .scaleEffect(look.scale)
            Circle()
                .fill(LinearGradient(
                    colors: [Color.accentColor.opacity(0.95), Color.accentColor.opacity(0.65)], startPoint: .top, endPoint: .bottom))
                .frame(width: 52, height: 52)
            // Décoratif : le titre de l'état, porté par l'orbe, dit déjà qui a la parole.
            Image(systemName: look.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating, isActive: look.pulses)
                .accessibilityHidden(true)
        }
        .opacity(look.opacity)
        .frame(width: Self.frame, height: Self.frame)
        .padding(.leading, -Self.haloInset)
        // Un fondu de 0,1 s sous « Réduire les animations » (opacité seule), un lissage de 0,12 s sinon ; choix non mesurés.
        .animation(reduceMotion ? .linear(duration: 0.1) : .easeOut(duration: 0.12), value: look)
        .modifier(OrbAccessibility(title: state.title))
    }
}

// MARK: - Pastilles

/// Les pastilles de modes : inactives pendant l'entretien (`PanelModel.modesLocked`).
struct ModeChips: View {
    let modes: [ModeChip]
    let selectedID: String
    let locked: Bool
    let select: @MainActor (String) -> Void

    /// L'aide VoiceOver d'une pastille : pourquoi elle ne répond plus, pour celles qu'on ne peut plus choisir ; rien sinon.
    static func accessibilityHint(locked: Bool, isSelected: Bool) -> String? {
        locked && !isSelected ? InterviewText.modeLockedHint : nil
    }

    var body: some View {
        // Les pastilles des réglages, dans leur ordre ; à la ligne quand elles débordent, le panneau grandit.
        ChipFlowLayout {
            ForEach(modes) { mode in
                let isSelected = mode.id == selectedID
                ModeChipButton(title: mode.title, isSelected: isSelected) { select(mode.id) }
                    // Le mode en cours reste lisible (un bouton inactif est estompé par le système) ; les autres, qu'on ne peut plus
                    // choisir, s'effacent à moitié (choix de mise en page).
                    .disabled(locked && !isSelected)
                    .opacity(locked && !isSelected ? 0.5 : 1)
                    .accessibilityHint(Self.accessibilityHint(locked: locked, isSelected: isSelected) ?? "")
            }
        }
    }
}
