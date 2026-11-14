import SupervoxCore
import SwiftUI

/// Onglet Transcription : moteur, modèle WhisperKit, langue, vocabulaire, et les modèles locaux à télécharger ou
/// supprimer. Toute la logique est dans `TranscriptionModel`.
public struct TranscriptionPane: View {
    let model: TranscriptionModel
    @State private var vocabulary: String
    @State private var removal: LocalModel?
    @FocusState private var vocabularyFocused: Bool

    public init(model: TranscriptionModel) {
        self.model = model
        _vocabulary = State(initialValue: model.vocabularyText)
    }

    public var body: some View {
        Form {
            engineSection
            languageSection
            vocabularySection
            modelsSection
        }
        .formStyle(.grouped)
        // Le message reste visible quel que soit l'endroit où le défilement s'est arrêté.
        .safeAreaInset(edge: .bottom) {
            if let message = model.message {
                MessageBanner(text: message, kind: model.messageKind)
            }
        }
        .confirmationDialog(
            "Supprimer « \(removal?.title ?? "") » de ce Mac ?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { removed in
            Button("Supprimer", role: .destructive) { Task { await model.delete(removed.id) } }
        } message: { removed in
            Text(
                model.isUsedByChosenEngine(removed.id)
                    ? "C'est le modèle du moteur choisi : la prochaine dictée devra le télécharger de nouveau."
                    : "Vous pourrez le télécharger de nouveau plus tard.")
        }
    }

    // MARK: - Moteur

    private var engineSection: some View {
        Section {
            Picker(
                "Moteur de dictée",
                selection: Binding(get: { model.settings.engine }, set: { model.setEngine($0) })
            ) {
                Text("WhisperKit").tag("whisperkit")
                Text("Parakeet").tag("parakeet")
            }
            .pickerStyle(.radioGroup)
            if model.settings.engine == "whisperkit" {
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
                .frame(minHeight: 84)
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

    private func applyVocabulary() {
        let draft = vocabulary
        Task {
            await model.setVocabulary(text: draft)
            // Refusé ou normalisé (lignes vides et doublons retirés) : le champ montre ce qui est enregistré.
            vocabulary = model.vocabularyText
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
                if let action = TranscriptionModel.action(for: local.state) {
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

/// Bandeau du message de l'onglet : refus ou échec, réserve, ou information.
private struct MessageBanner: View {
    let text: String
    let kind: TranscriptionMessageKind

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
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
