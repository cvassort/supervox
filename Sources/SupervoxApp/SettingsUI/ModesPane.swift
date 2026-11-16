import SwiftUI

/// Onglet Modes : les modèles fort et rapide en tête (sous l'introduction), puis une ligne par mode (modifier, dupliquer,
/// déplacer, supprimer) ; le bouton qui ajoute un mode est au bas de la fenêtre. Toute la logique est dans `ModesModel`.
public struct ModesPane: View {
    let model: ModesModel
    /// Le mode dont la feuille est ouverte.
    @State private var editing: ModeSheetTarget?
    /// Le mode dont la suppression attend confirmation.
    @State private var removal: ModesModel.Row?

    public init(model: ModesModel) {
        self.model = model
    }

    /// Le message d'un enregistrement refusé est une rangée au-dessus du formulaire, comme dans l'onglet Transcription : il reste
    /// visible quand la liste défile, et ne recouvre rien.
    public var body: some View {
        VStack(spacing: 0) {
            if let message = model.message {
                ModesMessageLine(text: message)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            Form {
                Section {
                    Text(ModesModel.header)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section {
                    // Fournisseur sans liste, ou aucun fournisseur : dit une fois, avant les sélecteurs.
                    ModelPickerNotes(content: model.pickerContent(selected: nil))
                    ModelSetting(
                        title: ModesModel.strongTitle, note: ModesModel.strongNote, model: model,
                        selection: model.strongModel, onSelect: { model.setStrongModel($0) })
                    ModelSetting(
                        title: ModesModel.fastTitle, note: ModesModel.fastNote, model: model,
                        selection: model.fastModel, onSelect: { model.setFastModel($0) })
                } header: {
                    Text("Modèles")
                }
                Section {
                    let rows = model.rows
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        ModeRow(
                            row: row, isFirst: index == 0, isLast: index == rows.count - 1, model: model,
                            edit: { editing = ModeSheetTarget(id: $0) }, remove: { removal = $0 }
                        )
                        // Recrée l'interrupteur après un enregistrement refusé : il revient à la valeur enregistrée.
                        // L'identité reste propre à chaque ligne : un `.id` commun à toutes les confondrait.
                        .id("\(row.id)#\(model.revision)")
                    }
                } header: {
                    Text("Modes")
                }
            }
            .formStyle(.grouped)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                AddModeButton(model: model, edit: { editing = ModeSheetTarget(id: $0) })
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .sheet(item: $editing) { target in
            ModeEditor(model: model, id: target.id)
        }
        .sheet(item: $removal) { row in
            DeletionSheet(
                title: Self.deletionTitle(for: row), message: Self.deletionMessage(for: row),
                cancel: { removal = nil },
                confirm: {
                    removal = nil
                    model.delete(row.id)
                })
        }
        // Un fournisseur ajouté dans l'onglet voisin de la même fenêtre ne la présente pas de nouveau : l'onglet relit ses réglages
        // à chaque affichage.
        .onAppear { model.reload() }
        .onDisappear { model.cancelRecording() }
    }

    public static func deletionTitle(for row: ModesModel.Row) -> String { "Supprimer le mode « \(row.title) » ?" }

    /// Ce qu'une suppression fait perdre. Dictée nettoyée et Prompt se remettent par « Ajouter un mode », avec leur consigne
    /// d'origine.
    public static func deletionMessage(for row: ModesModel.Row) -> String {
        if ModeChip.fixed.contains(where: { $0.id == row.id }) {
            return "Le mode, votre consigne et son raccourci seront supprimés. Vous pourrez le remettre avec « Ajouter un mode », avec sa consigne d'origine."
        }
        return "Le mode, sa consigne et son raccourci seront supprimés. Cette action ne peut pas être annulée."
    }
}

/// Un mode dont la feuille est ouverte.
struct ModeSheetTarget: Identifiable {
    let id: String
}

/// Un modèle fort ou rapide : le sélecteur et, dessous, ce qu'il sert à faire.
private struct ModelSetting: View {
    let title: String
    let note: String
    let model: ModesModel
    let selection: ModelChoice?
    let onSelect: (ModelChoice?) -> Void

    var body: some View {
        ModelPicker(
            title: title, noneTitle: ModesModel.noModelTitle, content: model.pickerContent(selected: selection),
            selection: selection, onSelect: onSelect
        )
        // Recrée le menu après un enregistrement refusé : il revient au choix enregistré.
        .id("\(title)#\(model.revision)")
        if selection != nil, model.pickerContent(selected: selection).removedProviderChoice != nil {
            WarningLine(text: ModesModel.removedProviderNote)
        }
        Text(note)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Le titre du mode et ce qu'il fait, à droite « Modifier… » et le menu des autres gestes ; dessous, l'interrupteur de relecture,
/// sur toute la largeur comme les autres réglages à interrupteur.
private struct ModeRow: View {
    let row: ModesModel.Row
    let isFirst: Bool
    let isLast: Bool
    let model: ModesModel
    let edit: (String) -> Void
    let remove: (ModesModel.Row) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title).font(.headline)
                    Text(row.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let note = row.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Button("Modifier…") { edit(row.id) }
                    Menu {
                        Button("Dupliquer") {
                            let id = model.duplicate(row.id)
                            if model.contains(id) { edit(id) }
                        }
                        Button("Monter") { model.move(row.id, by: -1) }.disabled(isFirst)
                        Button("Descendre") { model.move(row.id, by: 1) }.disabled(isLast)
                        Divider()
                        Button("Supprimer…", role: .destructive) { remove(row) }.disabled(!row.canDelete)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .accessibilityLabel("Autres actions pour « \(row.title) »")
                }
                .fixedSize()
                .controlSize(.small)
            }
            if !row.isReviewLocked {
                Toggle(
                    ModesModel.toggleTitle,
                    isOn: Binding(get: { row.reviews }, set: { [row] in model.setReview($0, for: row.id) })
                )
                .toggleStyle(.switch)
            }
        }
        .padding(.vertical, 2)
    }
}

/// « Ajouter un mode » : un mode neuf, ou, tant qu'il en manque, Dictée nettoyée ou Prompt remis avec leur consigne d'origine.
private struct AddModeButton: View {
    let model: ModesModel
    let edit: (String) -> Void

    var body: some View {
        let missing = model.missingBaseModes
        if missing.isEmpty {
            Button("Ajouter un mode") { addNew() }
        } else {
            Menu("Ajouter un mode") {
                Button("Nouveau mode") { addNew() }
                Divider()
                ForEach(missing) { chip in
                    Button("Remettre « \(chip.title) »") { model.addBase(chip.id) }
                }
            }
            .fixedSize()
        }
    }

    private func addNew() {
        let id = model.add()
        if model.contains(id) { edit(id) }
    }
}

/// Un message de l'onglet : refus ou échec. Le texte reste dans la couleur du texte courant ; la couleur ne porte que sur l'icône.
struct ModesMessageLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// Une réserve : l'icône est orange, le texte reste dans la couleur du texte courant (un texte orange clair se lit mal).
struct WarningLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}
