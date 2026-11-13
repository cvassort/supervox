import SwiftUI

/// Contenu du panneau : pastilles de modes en haut, état « Prêt » au centre avec le raccourci,
/// ligne des permissions et ligne d'avis si besoin, menu « … » en bas à droite.
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
            ready
            if let summary = permissions.summary {
                permissionsLine(summary)
            }
            footer
        }
        .padding(16)
        .frame(width: 520)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(model.modes) { mode in
                ModeChipButton(
                    title: mode.title, isSelected: mode.id == model.selectedModeID
                ) { model.select(mode.id) }
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 6) {
            Text("Prêt")
                .font(.title2.weight(.semibold))
            if let label = model.hotKeyLabel {
                Text(label)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 84)
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
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Réglages…") { openSettings() }
                Divider()
                Button("Quitter Supervox") { quit() }
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
private struct ModeChipButton: View {
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
