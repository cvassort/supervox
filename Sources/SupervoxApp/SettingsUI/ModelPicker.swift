import SwiftUI

/// Ce qu'un sélecteur de modèle propose, par fournisseur (`ModesModel.pickerContent(selected:)`). Un type de données à part : la
/// vue n'a rien à décider, et les tests lisent ce qu'elle montrerait.
public struct ModelPickerContent: Equatable, Sendable {
    /// Un modèle proposé, avec le libellé du menu (marqué quand il n'est plus dans la dernière liste).
    public struct Item: Equatable, Identifiable, Sendable {
        public let choice: ModelChoice
        public let label: String
        public var id: String { "\(choice.providerID.uuidString)/\(choice.model)" }
    }

    /// Un fournisseur et ses modèles. `emptyNote` renvoie à l'onglet Fournisseurs quand sa dernière liste est vide.
    public struct Group: Equatable, Identifiable, Sendable {
        public let providerID: UUID
        /// Le nom du fournisseur, rogné s'il est long.
        public let title: String
        public let items: [Item]
        public let emptyNote: String?
        public var id: UUID { providerID }
    }

    public let groups: [Group]
    /// Le choix déjà fait dont le fournisseur est supprimé : il reste affiché, marqué, jamais effacé seul.
    public let removedProviderChoice: Item?
    /// Dit qu'aucun fournisseur n'est enregistré, quand c'est le cas.
    public let emptyNote: String?
}

/// Un sélecteur de modèle : « aucun choix » (le modèle fort pour un mode, aucun pour les réglages), puis les modèles de chaque
/// fournisseur. Les explications (fournisseur sans liste, sans fournisseur) sont écrites dessous : un menu fermé ne les montre pas.
struct ModelPicker: View {
    let title: String
    let noneTitle: String
    let content: ModelPickerContent
    let selection: ModelChoice?
    let onSelect: (ModelChoice?) -> Void

    /// `ModelChoice` n'est pas `Hashable` : les étiquettes du menu sont des clés propres à ce sélecteur.
    private enum Tag: Hashable {
        case none
        case model(provider: UUID, name: String)

        init(_ choice: ModelChoice?) {
            if let choice { self = .model(provider: choice.providerID, name: choice.model) } else { self = .none }
        }
    }

    var body: some View {
        Picker(
            title,
            selection: Binding(
                get: { Tag(selection) },
                set: { tag in
                    switch tag {
                    case .none: onSelect(nil)
                    case .model(let provider, let name): onSelect(ModelChoice(providerID: provider, model: name))
                    }
                })
        ) {
            Text(noneTitle).tag(Tag.none)
            if let removed = content.removedProviderChoice {
                Text(removed.label).tag(Tag(removed.choice))
            }
            ForEach(content.groups) { group in
                if !group.items.isEmpty {
                    Section(group.title) {
                        ForEach(group.items) { item in Text(item.label).tag(Tag(item.choice)) }
                    }
                }
            }
        }
        ForEach(content.groups.filter { $0.emptyNote != nil }) { group in
            if let note = group.emptyNote {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if let note = content.emptyNote {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
