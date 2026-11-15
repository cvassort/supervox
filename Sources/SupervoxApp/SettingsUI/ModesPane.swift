import SwiftUI

/// Onglet Modes : une ligne par mode, avec l'interrupteur « Relire avant de coller ». Toute la logique est dans `ModesModel`.
public struct ModesPane: View {
    let model: ModesModel

    public init(model: ModesModel) {
        self.model = model
    }

    /// Le message d'un enregistrement refusé est une rangée au-dessus du formulaire, comme dans l'onglet Transcription :
    /// il reste visible quand la liste défile, et ne recouvre rien.
    public var body: some View {
        VStack(spacing: 0) {
            if let message = model.message {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text(message).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
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
                    ForEach(model.rows) { row in
                        ModeRow(row: row, model: model)
                            // Recrée l'interrupteur après un enregistrement refusé : il revient à la valeur enregistrée.
                            // L'identité reste propre à chaque ligne : un `.id` commun aux quatre les confondrait.
                            .id("\(row.id)#\(model.revision)")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// Le titre du mode, sa note, et à droite l'interrupteur (absent d'un mode toujours relu).
private struct ModeRow: View {
    let row: ModesModel.Row
    let model: ModesModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                if let note = row.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            if !row.isLocked {
                // Le libellé est écrit à côté de l'interrupteur, à la même place sur chaque ligne ; l'interrupteur le garde
                // comme nom pour VoiceOver.
                HStack(spacing: 10) {
                    Text(ModesModel.toggleTitle).accessibilityHidden(true)
                    Toggle(ModesModel.toggleTitle, isOn: Binding(get: { row.reviews }, set: { [row] in model.setReview($0, for: row.id) }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .fixedSize()
            }
        }
    }
}
