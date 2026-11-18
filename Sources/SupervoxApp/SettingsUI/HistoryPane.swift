import SwiftUI

/// Onglet Historique. La fenêtre de réglages a une taille FIXE (`SettingsView.windowSize`) : l'en-tête et le pied (durée de
/// conservation, « Tout supprimer… ») gardent leur hauteur, la zone du milieu prend le reste. À gauche la liste des entretiens
/// (elle défile), à droite le détail de celui qui est choisi (il défile : un prompt ou une conversation longs ne poussent jamais le
/// pied hors de la fenêtre). Sans entretien, la phrase « Aucun entretien gardé pour l'instant. » prend la zone.
///
/// Toute la logique est dans `HistoryModel`, dont viennent aussi les phrases et les confirmations ; cette vue n'en recopie aucune.
public struct HistoryPane: View {
    @Bindable var model: HistoryModel
    /// Mesure : reçoit la hauteur de la zone du milieu et le bas du pied, en points depuis le haut du volet. Sert aux tests qui exigent
    /// que le pied tienne dans la fenêtre et que la liste garde de la place ; `nil` en production.
    private let onMeasure: (@MainActor (Metrics) -> Void)?

    /// Ce que la mesure rapporte.
    public struct Metrics: Equatable, Sendable {
        public var mainAreaHeight: CGFloat
        public var footerMaxY: CGFloat
    }

    public init(model: HistoryModel, onMeasure: (@MainActor (Metrics) -> Void)? = nil) {
        self.model = model
        self.onMeasure = onMeasure
    }

    /// Largeur de la liste, en points : choix non mesuré, vu en image (le détail reçoit le reste, de quoi mettre sur une ligne la date
    /// et « Supprimer »).
    static let listWidth: CGFloat = 210
    static let coordinateSpaceName = "historyPane"

    public var body: some View {
        VStack(spacing: 0) {
            // Le message (échec ou « Copié. ») est une rangée au-dessus du contenu, comme dans les autres onglets.
            if let message = model.message {
                HistoryMessageLine(text: message, isFailure: model.messageIsFailure)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            Text(HistoryModel.header)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(mainProbe)
            Divider()
            footer
                .background(footerProbe)
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(MetricsKey.self) { metrics in
            if let metrics { onMeasure?(metrics) }
        }
        // Un entretien conclu pendant que la fenêtre était gardée s'y voit à chaque affichage de l'onglet.
        .onAppear { Task { await model.reload() } }
        // Une confirmation en attente ne survit pas à l'onglet quitté.
        .onDisappear {
            model.cancelRetention()
            model.cancelDeleteAll()
        }
        .sheet(
            isPresented: Binding(get: { model.retentionConfirmation != nil }, set: { if !$0 { model.cancelRetention() } })
        ) {
            HistoryConfirmationSheet(
                text: model.retentionConfirmation ?? "", confirmTitle: HistoryModel.deleteTitle,
                cancel: { model.cancelRetention() }, confirm: { model.confirmRetention() })
        }
        .sheet(isPresented: Binding(get: { model.pendingDeleteAll }, set: { if !$0 { model.cancelDeleteAll() } })) {
            HistoryConfirmationSheet(
                text: model.deleteAllConfirmation ?? "", confirmTitle: "Tout supprimer",
                cancel: { model.cancelDeleteAll() }, confirm: { Task { await model.deleteAll() } })
        }
    }

    // MARK: - Zone du milieu

    @ViewBuilder
    private var mainArea: some View {
        if !model.isLoaded {
            Color.clear
        } else if model.records.isEmpty {
            Text(HistoryModel.empty)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                list.frame(width: Self.listWidth)
                Divider()
                detail
            }
        }
    }

    private var list: some View {
        List(model.rows, selection: $model.selection) { row in
            VStack(alignment: .leading, spacing: 2) {
                Text(row.dateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(row.title)
                    .lineLimit(2)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.selectedRow?.dateText ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(HistoryModel.deleteTitle, role: .destructive) { Task { await model.deleteSelected() } }
                    .controlSize(.small)
                    .disabled(model.selectedRecord == nil)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let prompt = model.promptText {
                        section(HistoryModel.promptTitle, copy: HistoryModel.copyPromptTitle, action: { model.copyPrompt() }) {
                            Text(prompt)
                        }
                    }
                    section(
                        HistoryModel.conversationTitle, copy: HistoryModel.copyConversationTitle,
                        action: { model.copyConversation() }
                    ) {
                        Text(model.conversationText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Une section du détail : son titre et son bouton de copie sur une ligne, le texte dessous (sélectionnable).
    private func section(
        _ title: String, copy: String, action: @escaping () -> Void, @ViewBuilder text: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer(minLength: 8)
                Button(copy, action: action).controlSize(.small)
            }
            text()
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pied

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let note = model.unreadableNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text(HistoryModel.retentionTitle)
                Picker(
                    HistoryModel.retentionTitle,
                    selection: Binding(get: { model.retentionDays }, set: { model.requestRetention($0) })
                ) {
                    ForEach(model.retentionChoices, id: \.days) { choice in
                        Text(choice.label).tag(choice.days)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 8)
                Button(HistoryModel.deleteAllTitle) { Task { await model.requestDeleteAll() } }
                    .disabled(model.fileCount == 0)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    // MARK: - Mesure

    private var mainProbe: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: MetricsKey.self,
                value: onMeasure == nil ? nil : Metrics(mainAreaHeight: geometry.size.height, footerMaxY: -1))
        }
    }

    private var footerProbe: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: MetricsKey.self,
                value: onMeasure == nil
                    ? nil : Metrics(mainAreaHeight: -1, footerMaxY: geometry.frame(in: .named(Self.coordinateSpaceName)).maxY))
        }
    }
}

/// Les deux mesures arrivent séparément ; la clé les réunit.
private struct MetricsKey: PreferenceKey {
    static let defaultValue: HistoryPane.Metrics? = nil
    static func reduce(value: inout HistoryPane.Metrics?, nextValue: () -> HistoryPane.Metrics?) {
        guard let next = nextValue() else { return }
        guard var merged = value else {
            value = next
            return
        }
        if next.mainAreaHeight >= 0 { merged.mainAreaHeight = next.mainAreaHeight }
        if next.footerMaxY >= 0 { merged.footerMaxY = next.footerMaxY }
        value = merged
    }
}

/// Un message de l'onglet : un échec (icône d'erreur rouge) ou « Copié. » (coche verte). Le texte garde la couleur du texte courant.
struct HistoryMessageLine: View {
    let text: String
    let isFailure: Bool

    var body: some View {
        if isFailure {
            ModesMessageLine(text: text)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(text).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }
}

/// La confirmation d'une suppression de l'historique : la phrase de `HistoryModel`, « Annuler » et le bouton destructeur.
public struct HistoryConfirmationSheet: View {
    let text: String
    let confirmTitle: String
    let cancel: () -> Void
    let confirm: () -> Void

    public init(text: String, confirmTitle: String, cancel: @escaping () -> Void, confirm: @escaping () -> Void) {
        self.text = text
        self.confirmTitle = confirmTitle
        self.cancel = cancel
        self.confirm = confirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(text)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Annuler", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: .destructive, action: confirm)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
