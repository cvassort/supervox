import SwiftUI

/// Onglet Historique. La fenêtre de réglages a une taille FIXE (`SettingsView.windowSize`) : l'en-tête et le pied (durée de
/// conservation, « Tout supprimer… ») gardent leur hauteur, la zone du milieu prend le reste. À gauche la liste des entretiens
/// (elle défile), à droite le détail de celui qui est choisi (il défile : un prompt ou une conversation longs ne poussent jamais le
/// pied hors de la fenêtre). Sans entretien, la phrase « Aucun entretien gardé pour l'instant. » prend la zone.
///
/// Toute la logique est dans `HistoryModel`, dont viennent aussi les phrases et les confirmations ; cette vue n'en recopie aucune.
public struct HistoryPane: View {
    @Bindable var model: HistoryModel
    /// Mesure : reçoit le cadre de chaque repère (`Probe`), en points dans le repère du volet, défilement à zéro. Sert aux tests qui
    /// exigent que le pied tienne dans la fenêtre, que la liste garde de la place et qu'aucun bouton ne bouge quand un message
    /// apparaît ; `nil` en production.
    private let onMeasure: (@MainActor (Metrics) -> Void)?

    /// Les éléments dont la position est mesurée.
    public enum Probe: Hashable, Sendable {
        case mainArea, messageSlot, footer, deleteButton, copyPromptButton, copyConversationButton
    }

    /// Ce que la mesure rapporte : le cadre de chaque repère présent.
    public struct Metrics: Equatable, Sendable {
        public var frames: [Probe: CGRect]
        public subscript(probe: Probe) -> CGRect? { frames[probe] }
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
            VStack(alignment: .leading, spacing: 4) {
                Text(HistoryModel.header)
                if let note = model.headerNote { Text(note) }
                if let note = model.retentionNote { Text(note) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            mainArea
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(frameProbe(.mainArea))
            Divider()
            // Le message (échec ou « Copié. ») vit dans un emplacement de hauteur FIXE, toujours là, vide ou non : il ne décale jamais
            // rien. Inséré dans le flux au-dessus du contenu, il descendait le détail d'une rangée, et un double clic sur « Copier le
            // prompt » tombait sur « Supprimer ».
            messageSlot
                .background(frameProbe(.messageSlot))
            footer
                .background(frameProbe(.footer))
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(MetricsKey.self) { frames in
            if onMeasure != nil, !frames.isEmpty { onMeasure?(Metrics(frames: frames)) }
        }
        // Un entretien conclu pendant que la fenêtre était gardée s'y voit à chaque affichage de l'onglet.
        .onAppear { Task { await model.reload() } }
        // Une confirmation en attente ne survit pas à l'onglet quitté.
        .onDisappear { model.cancelConfirmation() }
        // UNE seule feuille pour les trois confirmations (durée, un entretien, tout) : plusieurs `.sheet` sur la même vue se disputent.
        .sheet(isPresented: Binding(get: { model.confirmation != nil }, set: { if !$0 { model.cancelConfirmation() } })) {
            HistoryConfirmationSheet(
                text: model.confirmationText ?? "", confirmTitle: model.confirmationButtonTitle ?? HistoryModel.deleteTitle,
                cancel: { model.cancelConfirmation() }, confirm: { Task { await model.confirm() } })
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
                Button(HistoryModel.deleteTitle, role: .destructive) { model.requestDeleteSelected() }
                    .controlSize(.small)
                    .disabled(model.selectedRecord == nil)
                    .background(frameProbe(.deleteButton))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let prompt = model.promptText {
                        section(
                            HistoryModel.promptTitle, copy: HistoryModel.copyPromptTitle, probe: .copyPromptButton,
                            action: { model.copyPrompt() }
                        ) {
                            Text(prompt)
                        }
                    }
                    section(
                        HistoryModel.conversationTitle, copy: HistoryModel.copyConversationTitle,
                        probe: .copyConversationButton, action: { model.copyConversation() }
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
        _ title: String, copy: String, probe: Probe, action: @escaping () -> Void, @ViewBuilder text: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer(minLength: 8)
                Button(copy, action: action).controlSize(.small).background(frameProbe(probe))
            }
            text()
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Emplacement du message

    /// Hauteur de l'emplacement du message, en points : deux lignes de texte courant (la phrase la plus longue de l'onglet tient sur
    /// deux lignes à 600 points de large : vu en image) et ses marges. Choix non mesuré. Un message plus long est coupé en fin de
    /// ligne ; son texte entier reste dans l'infobulle et pour VoiceOver.
    static let messageSlotHeight: CGFloat = 44

    private var messageSlot: some View {
        ZStack(alignment: .leading) {
            Color.clear
            if let message = model.message {
                HistoryMessageLine(text: message, isFailure: model.messageIsFailure)
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.messageSlotHeight)
        .background(.bar)
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
                    selection: Binding(get: { model.shownRetention }, set: { value in Task { await model.requestRetention(value) } })
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

    /// Rapporte le cadre de cet élément (seulement quand quelqu'un mesure).
    private func frameProbe(_ probe: Probe) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: MetricsKey.self,
                value: onMeasure == nil ? [:] : [probe: geometry.frame(in: .named(Self.coordinateSpaceName))])
        }
    }
}

/// Les cadres mesurés arrivent séparément ; la clé les réunit.
private struct MetricsKey: PreferenceKey {
    static let defaultValue: [HistoryPane.Probe: CGRect] = [:]
    static func reduce(value: inout [HistoryPane.Probe: CGRect], nextValue: () -> [HistoryPane.Probe: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Un message de l'onglet : un échec (icône d'erreur rouge) ou « Copié. » (coche verte). Le texte garde la couleur du texte courant ;
/// deux lignes au plus (l'emplacement a une hauteur fixe).
struct HistoryMessageLine: View {
    let text: String
    let isFailure: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if isFailure {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(text)
                .font(.callout)
                .lineLimit(2)
                .help(text)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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
