import SupervoxCore
import SwiftUI

/// Onglet Transcription : moteur, modèle WhisperKit, langue, vocabulaire, et les modèles locaux à télécharger ou
/// supprimer. Toute la logique est dans `TranscriptionModel`.
public struct TranscriptionPane: View {
    let model: TranscriptionModel
    @State private var vocabulary: String
    @State private var removal: LocalModel?
    @FocusState private var vocabularyFocused: Bool

    /// `draft` : le texte que le champ de vocabulaire montre à l'ouverture (`nil` : le vocabulaire enregistré). Sert au rendu
    /// d'un refus, où le champ garde ce que l'utilisateur a tapé.
    public init(model: TranscriptionModel, draft: String? = nil) {
        self.model = model
        _vocabulary = State(initialValue: draft ?? model.vocabularyText)
    }

    /// Le bandeau général est une rangée au-dessus du formulaire, jamais posé par-dessus : il ne recouvre rien, à aucune
    /// taille de fenêtre. Les messages du vocabulaire s'affichent dans sa section, à côté du champ.
    public var body: some View {
        VStack(spacing: 0) {
            if let message = model.message, model.messageArea == .general {
                MessageLine(text: message, kind: model.messageKind)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            Form {
                engineSection
                languageSection
                vocabularySection
                modelsSection
            }
            .formStyle(.grouped)
        }
        .sheet(item: $removal) { removed in
            DeletionSheet(
                title: "Supprimer « \(removed.title) » de ce Mac ?", message: model.deletionConfirmation(for: removed),
                cancel: { removal = nil },
                confirm: {
                    removal = nil
                    Task { await model.delete(removed.id) }
                })
        }
    }

    // MARK: - Moteur

    private var engineSection: some View {
        Section {
            Picker(
                "Moteur de dictée",
                selection: Binding(get: { model.settings.engine }, set: { model.setEngine($0) })
            ) {
                ForEach(TranscriptionEngine.allCases, id: \.self) { engine in
                    Text(engine.title).tag(engine)
                }
            }
            .pickerStyle(.radioGroup)
            if model.settings.engine == .whisperKit {
                Picker(
                    "Modèle WhisperKit",
                    selection: Binding(get: { model.settings.whisperModel }, set: { model.setWhisperModel($0) })
                ) {
                    ForEach(whisperChoices, id: \.name) { choice in
                        Text(choice.title).tag(choice.name)
                    }
                }
            }
        } header: {
            Text("Moteur")
        } footer: {
            Text(
                "WhisperKit est le plus précis dans les mesures du projet ; Parakeet est bien plus rapide et fournit l'aperçu du texte pendant que vous parlez. Le moteur choisi télécharge son modèle à la première dictée s'il n'est pas déjà sur ce Mac."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Les variantes du catalogue, plus celle des réglages si le catalogue ne la propose pas (réglage modifié à la main).
    private var whisperChoices: [(name: String, title: String)] {
        var choices = model.whisperModels.compactMap { listed in
            TranscriptionModel.whisperVariant(of: listed).map { (name: $0, title: listed.title) }
        }
        if !choices.contains(where: { $0.name == model.settings.whisperModel }) {
            choices.append((name: model.settings.whisperModel, title: model.settings.whisperModel))
        }
        return choices
    }

    // MARK: - Langue

    private var languageSection: some View {
        Section {
            Picker(
                "Langue de dictée",
                selection: Binding(get: { model.settings.language }, set: { model.setLanguage($0) })
            ) {
                ForEach(languageChoices, id: \.code) { language in
                    Text(language.name).tag(language.code)
                }
            }
        } footer: {
            Text("La langue s'applique à WhisperKit ; Parakeet n'en tient pas compte.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var languageChoices: [(code: String, name: String)] {
        var choices = TranscriptionModel.languages
        if !choices.contains(where: { $0.code == model.settings.language }) {
            choices.append((code: model.settings.language, name: model.settings.language))
        }
        return choices
    }

    // MARK: - Vocabulaire

    private var vocabularySection: some View {
        Section {
            TextEditor(text: $vocabulary)
                .font(.body)
                .frame(minHeight: 84, maxHeight: 160)  // une longue liste défile dans le champ, elle ne l'agrandit pas
                .focused($vocabularyFocused)
                .onChange(of: vocabularyFocused) { _, focused in
                    if !focused { applyVocabulary() }
                }
                .accessibilityLabel("Vocabulaire")
                .overlay(alignment: .topLeading) {
                    if vocabulary.isEmpty {
                        Text("Un terme par ligne, par exemple :\nKubernetes\nPostgreSQL")
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
            if let message = model.message, model.messageArea == .vocabulary {
                MessageLine(text: message, kind: model.messageKind)
            }
            HStack {
                Spacer()
                Button("Enregistrer le vocabulaire") { applyVocabulary() }
                    .disabled(PendingVocabulary.isUnchanged(draft: vocabulary, saved: model.settings.vocabulary))
            }
        } header: {
            Text("Vocabulaire")
        } footer: {
            Text(
                "Un terme par ligne : noms propres, sigles, mots techniques. Le moteur s'en sert pour mieux les reconnaître et les écrire. Une liste trop longue pour le moteur est refusée."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Un refus, un échec d'enregistrement ou une saisie dépassée laissent le texte tapé dans le champ, avec le message à côté :
    /// l'utilisateur retire des termes au lieu de tout retaper. Seul un vocabulaire enregistré est remis en forme.
    private func applyVocabulary() {
        let submitted = vocabulary
        Task {
            let outcome = await model.setVocabulary(text: submitted)
            vocabulary = TranscriptionModel.fieldText(
                afterSubmitting: submitted, outcome: outcome, current: vocabulary, saved: model.vocabularyText)
        }
    }

    // MARK: - Modèles

    private var modelsSection: some View {
        Section {
            if !model.hasListed {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Lecture des modèles présents sur ce Mac…").foregroundStyle(.secondary)
                }
            } else if model.models.isEmpty {
                Text("Les modèles locaux ne sont pas disponibles dans cette version.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.models) { local in
                ModelRow(model: model, local: local, onDelete: { removal = local })
            }
        } header: {
            Text("Modèles sur ce Mac")
        } footer: {
            if !model.models.isEmpty {
                Text("Les modèles se téléchargent depuis Internet, puis tournent sur ce Mac : avec ces moteurs, l'audio ne quitte pas l'ordinateur.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Le texte saisi comparé à ce qui est enregistré, après la même mise en forme que l'enregistrement.
@MainActor enum PendingVocabulary {
    static func isUnchanged(draft: String, saved: [String]) -> Bool {
        TranscriptionModel.terms(in: draft) == saved
    }
}

/// Une ligne de la liste : titre, explication, état, et le bouton que l'état permet.
private struct ModelRow: View {
    let model: TranscriptionModel
    let local: LocalModel
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(local.title).font(.headline)
                if model.isUsedByChosenEngine(local.id) {
                    Text("moteur choisi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ForEach(TranscriptionModel.actions(for: local.state), id: \.label) { action in
                    Button(action.label) {
                        switch action.kind {
                        case .download: Task { await model.download(local.id) }
                        case .delete: onDelete()
                        }
                    }
                    .controlSize(.small)
                }
            }
            Text(local.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            stateView
            if let note = local.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var stateView: some View {
        switch local.state {
        case .ready:
            Label(TranscriptionModel.stateLabel(local.state), systemImage: "checkmark.circle.fill")
                .labelStyle(StateLabelStyle(tint: .green))
        case .absent:
            Label(TranscriptionModel.stateLabel(local.state), systemImage: "arrow.down.circle")
                .labelStyle(StateLabelStyle(tint: .secondary))
        case .incomplete:
            Label(TranscriptionModel.stateLabel(local.state), systemImage: "exclamationmark.triangle.fill")
                .labelStyle(StateLabelStyle(tint: .orange))
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text(TranscriptionModel.stateLabel(local.state)).font(.callout)
                // Une fraction seulement si la bibliothèque la donne ; sinon une barre indéterminée.
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
        case .failed:
            Label(TranscriptionModel.stateLabel(local.state), systemImage: "xmark.circle.fill")
                .labelStyle(StateLabelStyle(tint: .red))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// La couleur porte sur l'icône seule : un texte vert ou rouge clair sur fond clair se lit mal.
private struct StateLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(tint)
            configuration.title.font(.callout)
        }
    }
}

/// Un message de l'onglet : refus ou échec, réserve, ou information. Le texte reste dans la couleur du texte courant ; la
/// couleur ne porte que sur l'icône.
private struct MessageLine: View {
    let text: String
    let kind: TranscriptionMessageKind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch kind {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .error: .red
        case .warning: .orange
        case .info: .secondary
        }
    }
}

/// La confirmation de suppression d'un modèle. Une feuille de l'application (et non une boîte de dialogue du système) pour
/// que `supervox-snapshots` puisse la rendre telle quelle.
public struct DeletionSheet: View {
    let title: String
    let message: String
    let cancel: () -> Void
    let confirm: () -> Void

    public init(title: String, message: String, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.title = title
        self.message = message
        self.cancel = cancel
        self.confirm = confirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Supprimer", role: .destructive, action: confirm)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 420)
    }
}
