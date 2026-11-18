import SupervoxCore
import SwiftUI

/// Onglet Voix. La fenêtre de réglages a une taille FIXE (`SettingsView.windowSize`) : de haut en bas, les deux filtres sur une
/// ligne, la liste qui défile (sections, coche sur la voix en vigueur, raison d'une voix inutilisable, marque de la ligne écoutée),
/// une bande de message de hauteur fixe, puis la ligne des boutons. La bande est toujours là, vide ou non : un message ne déplace
/// aucun bouton (comme l'onglet Historique).
///
/// Toute la logique est dans `VoicesModel` (lignes, états des boutons, écritures) et toutes les phrases dans `VoicesText` : cette vue
/// ne recalcule aucune règle. UNE seule feuille sert à l'éditeur et à la confirmation : plusieurs `.sheet` sur la même vue se
/// disputent (constat de l'étape 6).
public struct VoicesPane: View {
    @Bindable var model: VoicesModel
    /// Mesure : reçoit le cadre de chaque repère (`Probe`), en points dans le repère du volet. Sert aux tests de disposition ; `nil`
    /// en production.
    private let onMeasure: (@MainActor (Metrics) -> Void)?

    /// Les éléments dont la position est mesurée.
    public enum Probe: Hashable, Sendable {
        case filters, list, messageSlot, message, footer, useButton, listenButton, addButton, editButton, deleteButton
    }

    /// Ce que la mesure rapporte : le cadre de chaque repère présent.
    public struct Metrics: Equatable, Sendable {
        public var frames: [Probe: CGRect]
        public subscript(probe: Probe) -> CGRect? { frames[probe] }
    }

    public init(model: VoicesModel, onMeasure: (@MainActor (Metrics) -> Void)? = nil) {
        self.model = model
        self.onMeasure = onMeasure
    }

    static let coordinateSpaceName = "voicesPane"

    public var body: some View {
        VStack(spacing: 0) {
            filters
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(frameProbe(.filters))
            Divider()
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(frameProbe(.list))
            Divider()
            messageSlot
                .background(frameProbe(.messageSlot))
            footer
                .background(frameProbe(.footer))
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(VoicesMetricsKey.self) { frames in
            if onMeasure != nil, !frames.isEmpty { onMeasure?(Metrics(frames: frames)) }
        }
        // Décision 1 : à chaque apparition de l'onglet, les réglages et la liste des voix sont relus (un fournisseur changé dans un
        // autre onglet change ce que dit la ligne de vie privée) et le message d'avant s'efface.
        .onAppear {
            model.reload()
            model.clearMessage()
        }
        // Décision 2 : la vue disparaît (autre onglet : c'est le seul chemin du changement d'onglet, comme pour l'onglet Historique ;
        // fenêtre retirée) : l'écoute s'arrête et une confirmation en attente est annulée. Un brouillon d'éditeur ouvert est GARDÉ : il est le contenu de la feuille, qui fait elle-même perdre la clé à la
        // fenêtre (voir `SettingsView.content`, `onLeave`).
        .onDisappear {
            model.stopListening()
            model.cancelConfirmation()
        }
        // UNE seule feuille pour l'éditeur et la confirmation.
        .sheet(isPresented: Binding(get: { Self.sheet(for: model) != nil }, set: { if !$0 { Self.dismissSheet(model) } })) {
            switch Self.sheet(for: model) {
            case .editor:
                VoiceEditor(model: model)
            case .confirmation:
                HistoryConfirmationSheet(
                    text: model.confirmationText ?? "", confirmTitle: VoicesText.confirmDeleteTitle,
                    cancel: { model.cancelConfirmation() }, confirm: { model.confirmDeletion() })
            case nil:
                EmptyView()
            }
        }
    }

    // MARK: - Feuille

    /// Ce que la feuille unique montre : l'éditeur tant qu'un brouillon est ouvert, sinon la confirmation d'une suppression en
    /// attente, sinon rien.
    enum Sheet: Equatable {
        case editor, confirmation
    }

    static func sheet(for model: VoicesModel) -> Sheet? {
        if model.draft != nil { return .editor }
        if model.pendingDeletion != nil { return .confirmation }
        return nil
    }

    /// La feuille fermée par la personne (Échap) : le brouillon est abandonné, ou la confirmation annulée.
    static func dismissSheet(_ model: VoicesModel) {
        switch sheet(for: model) {
        case .editor: model.cancel()
        case .confirmation: model.cancelConfirmation()
        case nil: break
        }
    }

    // MARK: - Filtres

    /// Les langues du sélecteur. `VoicesModel.languages` contient toujours la langue en cours, mais dédoublonne sans casse et en
    /// confondant `-` et `_` : la langue en cours peut y figurer sous une autre écriture (`fr_FR` pour `fr-FR`). L'entrée de même clé
    /// prend alors l'écriture exacte de la langue en cours, pour que le sélecteur ait toujours une étiquette égale à sa valeur.
    static func languageOptions(_ languages: [String], current: String?) -> [String] {
        guard let current else { return languages }
        let key = VoicesModel.languageKey(current)
        return languages.map { VoicesModel.languageKey($0) == key ? current : $0 }
    }

    private var filters: some View {
        HStack(spacing: 16) {
            Picker(VoicesText.languageFilterLabel, selection: $model.language) {
                Text(VoicesText.allLanguages).tag(String?.none)
                ForEach(Self.languageOptions(model.languages, current: model.language), id: \.self) { language in
                    Text(language).tag(Optional(language))
                }
            }
            .fixedSize()
            Picker(VoicesText.genderFilterLabel, selection: $model.gender) {
                ForEach(VoicesModel.GenderFilter.allCases, id: \.self) { filter in
                    Text(VoicesText.genderFilterTitle(filter)).tag(filter)
                }
            }
            .fixedSize()
            Spacer(minLength: 0)
        }
    }

    // MARK: - Liste

    private var list: some View {
        let rows = model.rows
        let system = rows.filter { $0.section == .system }
        let saved = rows.filter { $0.section == .provider }
        return List(selection: $model.selection) {
            if !system.isEmpty {
                Section(VoicesText.systemSection) {
                    ForEach(system) { row in rowView(row).tag(row.id) }
                }
            }
            if !saved.isEmpty {
                Section(VoicesText.providerSection) {
                    ForEach(saved) { row in rowView(row).tag(row.id) }
                }
            }
        }
        .listStyle(.inset)
    }

    private func rowView(_ row: VoicesModel.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // La coche garde sa place sur chaque ligne : les titres restent alignés.
            Image(systemName: "checkmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.tint)
                .opacity(row.isActive ? 1 : 0)
                .frame(width: 14)
                .accessibilityHidden(!row.isActive)
                .accessibilityLabel(VoicesText.activeVoice)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = row.note {
                    Label {
                        Text(note).foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if model.listeningRow == row.id {
                listeningMark
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    /// La marque de la ligne écoutée : l'indicateur d'activité pendant la préparation, le haut-parleur pendant la lecture.
    @ViewBuilder
    private var listeningMark: some View {
        if model.previewState == .preparing {
            ProgressView().controlSize(.small).accessibilityLabel(VoicesText.listeningMark)
        } else {
            Image(systemName: "speaker.wave.2.fill")
                .foregroundStyle(.tint)
                .accessibilityLabel(VoicesText.listeningMark)
        }
    }

    // MARK: - Bande de message

    /// Ce que la bande montre. Ordre de priorité (décision 5) : `message` d'abord (un refus d'enregistrement, ou la suppression de
    /// la voix en vigueur), puis `previewMessage` (la panne de l'écoute), et à défaut `privacyText` (ce qu'écouter la voix choisie
    /// envoie). Le modèle ne date ni `message` ni l'état de l'écoute : « la plus récente gagne » est tenu par le geste d'écoute, qui
    /// efface `message` avant d'écouter (`toggleListening`) ; un refus postérieur à une panne d'écoute passe devant elle par l'ordre.
    struct Band: Equatable {
        enum Kind: Equatable { case notice, failure, privacy }
        var text: String
        var kind: Kind
    }

    static func band(message: String?, previewMessage: String?, privacy: String?) -> Band? {
        if let message { return Band(text: message, kind: .notice) }
        if let previewMessage { return Band(text: previewMessage, kind: .failure) }
        if let privacy { return Band(text: privacy, kind: .privacy) }
        return nil
    }

    /// Hauteur de la bande, en points : `messageLineLimit` lignes de texte `callout` et leurs marges. La phrase la plus longue qui
    /// peut y arriver tient sur ces lignes à 600 points de large : mesuré par `VoicesPaneLayoutTests`. Choix de la marge non mesuré.
    static let messageSlotHeight: CGFloat = 62
    static let messageLineLimit = 3
    /// Largeur du texte de la bande : la fenêtre moins les marges (20 points de chaque côté) et l'icône (16 points et 8 d'écart).
    /// Code lu (les marges et l'icône ci-dessous).
    static var messageTextWidth: CGFloat { SettingsView.windowSize.width - 40 - 24 }

    private var messageSlot: some View {
        ZStack(alignment: .leading) {
            Color.clear
            if let band = Self.band(
                message: model.message, previewMessage: model.previewMessage, privacy: model.privacyText)
            {
                VoicesMessageLine(band: band)
                    .padding(.horizontal, 20)
                    .background(frameProbe(.message))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.messageSlotHeight)
        .background(.bar)
    }

    // MARK: - Boutons

    /// Le bouton d'écoute (décision 3) : « Arrêter » dès qu'une ligne s'écoute, quelle que soit la ligne choisie (l'arrêt est
    /// global : une écoute en cours n'est jamais sans bouton d'arrêt), avec l'indicateur d'activité pendant la préparation ; sinon
    /// « Écouter », actif selon `canListen`.
    struct ListenButton: Equatable {
        var title: String
        var showsProgress: Bool
        var isEnabled: Bool
        var stops: Bool
    }

    static func listenButton(listeningRow: VoicesModel.Row.ID?, state: VoicePreview.State, canListen: Bool) -> ListenButton {
        if listeningRow != nil {
            return ListenButton(title: VoicesText.stopTitle, showsProgress: state == .preparing, isEnabled: true, stops: true)
        }
        return ListenButton(title: VoicesText.listenTitle, showsProgress: false, isEnabled: canListen, stops: false)
    }

    /// Le geste du bouton d'écoute : arrêter l'écoute en cours, ou effacer le message d'avant puis écouter la voix choisie (la
    /// panne éventuelle de cette écoute est alors ce que la bande montre : décision 5).
    static func toggleListening(_ model: VoicesModel) {
        if listenButton(listeningRow: model.listeningRow, state: model.previewState, canListen: model.canListen).stops {
            model.stopListening()
        } else {
            model.clearMessage()
            model.listen()
        }
    }

    private var footer: some View {
        let listen = Self.listenButton(
            listeningRow: model.listeningRow, state: model.previewState, canListen: model.canListen)
        return HStack(spacing: 8) {
            Button(VoicesText.useTitle) { model.use() }
                .disabled(!model.canUse)
                .background(frameProbe(.useButton))
            Button {
                Self.toggleListening(model)
            } label: {
                HStack(spacing: 6) {
                    // Les deux titres réservent leur place : passer de l'un à l'autre ne déplace aucun bouton.
                    ZStack {
                        Text(VoicesText.listenTitle).hidden()
                        Text(VoicesText.stopTitle).hidden()
                        Text(listen.title)
                    }
                    ProgressView()
                        .controlSize(.mini)
                        .opacity(listen.showsProgress ? 1 : 0)
                        .accessibilityHidden(!listen.showsProgress)
                }
            }
            .disabled(!listen.isEnabled)
            .background(frameProbe(.listenButton))
            Spacer(minLength: 8)
            Button(VoicesText.addTitle) { model.beginAdding() }
                .background(frameProbe(.addButton))
            Button(VoicesText.editTitle) { model.beginEditing() }
                .disabled(!model.canEdit)
                .background(frameProbe(.editButton))
            Button(VoicesText.deleteTitle, role: .destructive) { model.requestDeletion() }
                .disabled(!model.canDelete)
                .background(frameProbe(.deleteButton))
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
                key: VoicesMetricsKey.self,
                value: onMeasure == nil ? [:] : [probe: geometry.frame(in: .named(Self.coordinateSpaceName))])
        }
    }
}

/// Les cadres mesurés arrivent séparément ; la clé les réunit.
private struct VoicesMetricsKey: PreferenceKey {
    static let defaultValue: [VoicesPane.Probe: CGRect] = [:]
    static func reduce(value: inout [VoicesPane.Probe: CGRect], nextValue: () -> [VoicesPane.Probe: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Une ligne de la bande : son icône (un avis, une panne, la vie privée) et sa phrase, sur `VoicesPane.messageLineLimit` lignes au
/// plus (la bande a une hauteur fixe). Le texte entier reste dans l'infobulle et pour VoiceOver.
struct VoicesMessageLine: View {
    let band: VoicesPane.Band

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 16)
            Text(band.text)
                .font(.callout)
                .foregroundStyle(band.kind == .privacy ? .secondary : .primary)
                .lineLimit(VoicesPane.messageLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .help(band.text)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch band.kind {
        case .notice: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        case .failure: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .privacy: Image(systemName: "lock.shield").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Éditeur

/// L'éditeur d'une voix de fournisseur, dans la feuille de l'onglet : il tient dans `VoiceEditor.size` et son formulaire défile si
/// les paramètres sont nombreux. Le refus d'un enregistrement s'affiche dans une bande de hauteur fixe au-dessus des boutons.
public struct VoiceEditor: View {
    @Bindable var model: VoicesModel

    public init(model: VoicesModel) {
        self.model = model
    }

    /// La taille de la feuille, en points (brief : 520×420). Choix non mesuré, vu en image.
    public static let size = CGSize(width: 520, height: 420)

    /// Les fournisseurs proposés : ceux qui savent parler ; le fournisseur du brouillon s'il n'y est pas (supprimé, ou qui ne sait
    /// pas parler : le modèle ne donne que les fournisseurs qui parlent, la vue ne peut pas dire lequel des deux), sous un libellé
    /// neutre ; et « aucun » si le brouillon n'en a pas ou s'il n'y a rien d'autre. Le sélecteur a ainsi toujours une étiquette égale
    /// à sa valeur ; l'enregistrement refuse un fournisseur qui ne parle pas (`VoicesText.refusalNoProvider`).
    static func providerOptions(speaking: [Provider], current: UUID?) -> [(id: UUID?, title: String)] {
        var options: [(id: UUID?, title: String)] = speaking.map { ($0.id, Provider.shortName($0.name)) }
        if let current, !speaking.contains(where: { $0.id == current }) {
            options.insert((current, VoicesText.unusableProvider), at: 0)
        }
        if current == nil || options.isEmpty {
            options.insert((nil, VoicesText.noSpeakingProvider), at: 0)
        }
        return options
    }

    /// Les genres proposés : non précisé, féminin, masculin, neutre, et le genre « autre » du brouillon s'il en a un.
    static func genderOptions(current: VoiceGender?) -> [VoiceGender?] {
        var options: [VoiceGender?] = [nil, .female, .male, .neutral]
        if let current, !options.contains(current) { options.append(current) }
        return options
    }

    /// Hauteur de la bande du refus, en points : deux lignes de texte `callout` et leurs marges. Choix non mesuré, vu en image.
    static let refusalSlotHeight: CGFloat = 44

    public var body: some View {
        let draft = Binding(get: { model.draft ?? VoicesModel.VoiceDraft() }, set: { model.draft = $0 })
        VStack(spacing: 0) {
            Text(draft.wrappedValue.editing == nil ? VoicesText.editorAddTitle : VoicesText.editorEditTitle)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Form {
                Section {
                    TextField(VoicesText.nameField, text: draft.name)
                    Picker(VoicesText.providerField, selection: draft.providerID) {
                        ForEach(
                            Self.providerOptions(
                                speaking: model.speakingProviders, current: draft.wrappedValue.providerID),
                            id: \.id
                        ) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    LabeledContent(VoicesText.modelField) {
                        HStack(spacing: 6) {
                            TextField(VoicesText.modelField, text: draft.model).labelsHidden()
                            let models = model.models(for: draft.wrappedValue.providerID)
                            if !models.isEmpty {
                                Menu {
                                    ForEach(models, id: \.self) { name in
                                        Button(name) { model.draft?.model = name }
                                    }
                                } label: {
                                    Image(systemName: "list.bullet")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .help(VoicesText.modelMenu)
                                .accessibilityLabel(VoicesText.modelMenu)
                            }
                        }
                    }
                    TextField(VoicesText.identifierField, text: draft.identifier)
                    TextField(VoicesText.languageField, text: draft.language)
                    Picker(
                        VoicesText.genderField,
                        selection: Binding(
                            get: { Self.genderOptions(current: draft.wrappedValue.gender).firstIndex(of: draft.wrappedValue.gender) ?? 0 },
                            set: { index in
                                let options = Self.genderOptions(current: draft.wrappedValue.gender)
                                if options.indices.contains(index) { model.draft?.gender = options[index] }
                            })
                    ) {
                        ForEach(Array(Self.genderOptions(current: draft.wrappedValue.gender).enumerated()), id: \.offset) { index, gender in
                            Text(VoicesText.editorGenderTitle(gender)).tag(index)
                        }
                    }
                }
                Section(VoicesText.parametersTitle) {
                    ForEach(draft.parameters) { $parameter in
                        HStack(spacing: 8) {
                            TextField(VoicesText.keyField, text: $parameter.key)
                            TextField(VoicesText.valueField, text: $parameter.value)
                            Button {
                                model.draft?.parameters.removeAll { $0.id == parameter.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help(VoicesText.removeParameterTitle)
                            .accessibilityLabel(VoicesText.removeParameterTitle)
                        }
                    }
                    Button(VoicesText.addParameterTitle) {
                        model.draft?.parameters.append(VoicesModel.VoiceDraft.Parameter(key: "", value: ""))
                    }
                }
            }
            .formStyle(.grouped)
            ZStack(alignment: .leading) {
                Color.clear
                if let message = model.message {
                    VoicesMessageLine(band: VoicesPane.Band(text: message, kind: .notice))
                        .padding(.horizontal, 20)
                }
            }
            .frame(height: Self.refusalSlotHeight)
            HStack {
                Spacer()
                Button(VoicesText.cancelTitle, role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(VoicesText.saveTitle) { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }
}
