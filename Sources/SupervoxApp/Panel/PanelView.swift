import SwiftUI

/// Contenu du panneau : pastilles de modes en haut, la dictée au centre (« Prêt » avec le raccourci, ou la dictée en cours) ou, pendant
/// un entretien, la vue de l'entretien à sa place, ligne des permissions et ligne d'avis si besoin, menu « … » en bas à droite.
public struct PanelView: View {
    let model: PanelModel
    let permissions: PermissionsModel
    let openSettings: @MainActor () -> Void
    let quit: @MainActor () -> Void

    public init(
        model: PanelModel, permissions: PermissionsModel,
        openSettings: @escaping @MainActor () -> Void, quit: @escaping @MainActor () -> Void
    ) {
        self.model = model
        self.permissions = permissions
        self.openSettings = openSettings
        self.quit = quit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            chips
            if let welcome = model.welcome {
                welcomeLine(welcome)
            }
            switch model.content {
            case .interview(let interview): InterviewView(state: interview, conclude: { model.concludeInterview() })
            case .dictation: dictation
            }
            if let summary = permissions.summary {
                permissionsLine(summary)
            }
            footer
        }
        .padding(16)
        .frame(width: 520)
    }

    /// Les entrées du menu « … », dans l'ordre (UNE source : la vue les montre, les tests les lisent).
    var menuEntries: [PanelMenuEntry] { PanelMenuEntry.entries(hasHistory: model.canOpenHistory) }

    /// Les entrées avec leur état : « Historique… » est grisée tant qu'un entretien ou une dictée tient le panneau (l'ouvrir
    /// l'annulerait sans rien demander). L'état vient du modèle, pas de la vue.
    var menuItems: [(entry: PanelMenuEntry, isEnabled: Bool)] {
        menuEntries.map { ($0, $0 == .history ? model.isHistoryEntryEnabled : true) }
    }

    private func run(_ entry: PanelMenuEntry) {
        switch entry {
        case .settings: openSettings()
        case .history: model.openHistory()
        case .quit: quit()
        }
    }

    private var chips: some View {
        ModeChips(
            modes: model.modes, selectedID: model.selectedModeID, locked: model.modesLocked, select: { model.chipTapped($0) })
    }

    /// La dictée : prêt, préparation, enregistrement, transcription, échec ou texte copié, et le dernier texte à copier.
    private var dictation: some View {
        DictationView(
            display: model.dictationDisplay, hotKeyLabel: model.hotKeyLabel, actions: .wired(to: model))
    }

    private func welcomeLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "hand.wave.fill")
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionsLine(_ summary: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(summary)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if permissions.canRequest {
                Button("Autoriser…") {
                    Task { await permissions.requestNext() }
                }
                .controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Avis en entier, sur autant de lignes qu'il faut : pas d'infobulle, l'application
            // n'est jamais active pendant que le panneau est ouvert.
            VStack(alignment: .leading, spacing: 4) {
                // `noticeLines` donne l'ordre testé ; identifiés par rang, deux avis au texte identique
                // restent deux lignes.
                ForEach(Array(model.noticeLines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(DetailText.systemSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(menuItems, id: \.entry) { item in
                    if item.entry == .quit { Divider() }
                    Button(item.entry.title) { run(item.entry) }
                        .disabled(!item.isEnabled)
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Plus")
        }
    }
}

/// Pastille de mode : capsule pleine si choisie, discrète sinon.
struct ModeChipButton: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Une entrée du menu « … » du panneau (publique : l'outil de rendu en dessine un aperçu à partir de la même source).
public enum PanelMenuEntry: Hashable, Sendable {
    case settings, history, quit

    public var title: String {
        switch self {
        case .settings: "Réglages…"
        case .history: "Historique…"
        case .quit: "Quitter Supervox"
        }
    }

    /// Réglages, puis Historique (seulement si un historique est branché), puis Quitter après un séparateur.
    public static func entries(hasHistory: Bool) -> [PanelMenuEntry] {
        hasHistory ? [.settings, .history, .quit] : [.settings, .quit]
    }
}
