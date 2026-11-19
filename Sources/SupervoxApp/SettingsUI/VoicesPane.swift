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
        // Décision 2 et R3 (tour 2) : la vue disparaît (autre onglet, fenêtre retirée) : l'onglet est quitté (`VoicesModel.leave` :
        // écoute arrêtée, confirmation annulée, brouillon abandonné). Le changement d'onglet passe aussi par `SettingsView` (R5).
        .onDisappear { model.leave() }
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

    /// Les entrées du sélecteur de langue, sur `VoicesModel.languages` telles quelles (le modèle y écrit la langue du filtre comme
    /// elle l'est : R6). Le libellé est la langue en clair (`VoicesText.languageName`) : deux codes d'une même langue y restent
    /// distincts.
    struct LanguageOption: Hashable {
        let code: String
        let label: String
    }

    static func languageOptions(_ languages: [String]) -> [LanguageOption] {
        languages.map { LanguageOption(code: $0, label: VoicesText.languageName($0)) }
    }

    /// Ce que VoiceOver dit de l'icône de la bande (R8) : le genre du message, que l'icône et la couleur seules portaient.
    static func iconLabel(_ kind: Band.Kind) -> String {
        switch kind {
        case .notice: VoicesText.warningLabel
        case .failure: VoicesText.errorLabel
        case .privacy: VoicesText.informationLabel
        }
    }

    /// Ce que VoiceOver dit de la coche (R8) : « Voix en vigueur » sur la ligne cochée ; rien (coche cachée) sur une autre ligne, et
    /// sur la ligne « Voix en vigueur » absente de la liste, dont le titre le dit déjà.
    static func checkmarkLabel(_ row: VoicesModel.Row) -> String? {
        row.isActive && row.id != .active ? VoicesText.activeVoice : nil
    }

    private var filters: some View {
        HStack(spacing: 16) {
            Picker(VoicesText.languageFilterLabel, selection: $model.language) {
                Text(VoicesText.allLanguages).tag(String?.none)
                ForEach(Self.languageOptions(model.languages), id: \.code) { option in
                    Text(option.label).tag(Optional(option.code))
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
        // R1 (tour 2) : la liste défile jusqu'à la ligne choisie quand la sélection change (une voix qu'on vient d'enregistrer est
        // choisie par le modèle, souvent en bas de la liste). Au passage suivant de la boucle principale : la même mise à jour change
        // le filtre, et la table n'a ses nouvelles lignes qu'après (mesuré : appelé tout de suite, la liste s'arrêtait avant la ligne).
        return ScrollViewReader { proxy in
            List(selection: $model.selection) {
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
            .onChange(of: model.selection) { _, selection in
                guard let selection else { return }
                Task { @MainActor in
                    proxy.scrollTo(selection)
                    await Task.yield()
                    proxy.scrollTo(selection)
                }
            }
        }
    }

    private func rowView(_ row: VoicesModel.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // La coche garde sa place sur chaque ligne : les titres restent alignés.
            VoicesRowMark(systemName: "checkmark")
                .font(.callout.weight(.semibold))
                .opacity(row.isActive ? 1 : 0)
                .frame(width: 14)
                .accessibilityHidden(Self.checkmarkLabel(row) == nil)
                .accessibilityLabel(Self.checkmarkLabel(row) ?? "")
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
                            .accessibilityLabel(VoicesText.warningLabel)
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
            VoicesRowMark(systemName: "speaker.wave.2.fill")
                .accessibilityLabel(VoicesText.listeningMark)
        }
    }

    /// Une marque de ligne est à la couleur d'accent, sauf sur la ligne surlignée, dont le fond l'est déjà : elle y suit le texte.
    static func marksUseAccent(_ prominence: BackgroundProminence) -> Bool {
        prominence != .increased
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
    /// peut y arriver tient sur ces lignes à la largeur de la fenêtre (`SettingsView.windowSize`) : mesuré par
    /// `VoicesPaneLayoutTests`. Choix de la marge non mesuré.
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
            // Le titre courant seulement : les deux titres de réserve sont cachés (R8).
            .accessibilityLabel(listen.title)
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

/// La coche de la voix en vigueur et le haut-parleur de la ligne écoutée (`VoicesPane.marksUseAccent`) : la liste pose
/// `backgroundProminence` à `.increased` sur la ligne surlignée.
private struct VoicesRowMark: View {
    let systemName: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(VoicesPane.marksUseAccent(prominence) ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
    }
}

/// Une ligne de la bande : son icône (un avis, une panne, la vie privée) et sa phrase, sur `VoicesPane.messageLineLimit` lignes au
/// plus (la bande a une hauteur fixe). Le texte entier reste dans l'infobulle et pour VoiceOver.
struct VoicesMessageLine: View {
    let band: VoicesPane.Band

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon.frame(width: 16).accessibilityLabel(VoicesPane.iconLabel(band.kind))
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
    /// Mesure : reçoit le cadre de chaque repère (`Probe`), en points dans le repère de la feuille. Sert aux tests de disposition ;
    /// `nil` dans l'application.
    private let onMeasure: (@MainActor (Metrics) -> Void)?

    /// Les repères mesurés de la feuille.
    public enum Probe: Hashable, Sendable {
        case title, fields, parametersViewport, parameterRow(Int), addParameter, refusalSlot, cancelButton, saveButton
    }

    public struct Metrics: Equatable, Sendable {
        public var frames: [Probe: CGRect]
        public subscript(probe: Probe) -> CGRect? { frames[probe] }
    }

    public init(model: VoicesModel, onMeasure: (@MainActor (Metrics) -> Void)? = nil) {
        self.model = model
        self.onMeasure = onMeasure
    }

    static let coordinateSpaceName = "voiceEditor"

    private func frameProbe(_ probe: Probe) -> some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: VoiceEditorMetricsKey.self,
                value: onMeasure == nil ? [:] : [probe: geometry.frame(in: .named(Self.coordinateSpaceName))])
        }
    }

    /// Le nom en clair montré à côté du champ de la langue (le champ garde le code, qui est enregistré) ; `nil` pour un code
    /// sans nom (inconnu, vide) : il n'y a rien de plus clair à dire.
    static func languageHint(_ code: String) -> String? {
        let name = VoicesText.languageName(code)
        return name == code ? nil : name
    }

    /// La taille de la feuille, en points : 520×540 (décision du contrôleur, tour 1 : les six champs, deux paramètres et
    /// « Ajouter un paramètre » se voient sans défiler). Choix non mesuré, vu en image.
    public static let size = CGSize(width: 520, height: 540)

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

    /// Les genres proposés : non précisé, féminin, masculin, neutre, le genre d'origine de la voix (R9 : on peut y revenir tant que
    /// l'éditeur est ouvert) et le genre « autre » du brouillon s'il en a un.
    static func genderOptions(current: VoiceGender?, original: VoiceGender? = nil) -> [VoiceGender?] {
        var options: [VoiceGender?] = [nil, .female, .male, .neutral]
        for extra in [original, current] {
            if let extra, !options.contains(extra) { options.append(extra) }
        }
        return options
    }

    /// Les genres proposés pour ce brouillon (son genre et son genre d'origine).
    static func genderOptions(for draft: VoicesModel.VoiceDraft) -> [VoiceGender?] {
        genderOptions(current: draft.gender, original: draft.originalGender)
    }

    /// Paramètres visibles sans défiler : au-delà, seule la zone des paramètres défile (décision du contrôleur, tour 1).
    static let visibleParameterRows = 3
    /// Hauteur d'une ligne de paramètre et écart entre deux lignes, en points : un champ arrondi et sa marge. Choix non mesuré, vu
    /// en image.
    static let parameterRowHeight: CGFloat = 24
    static let parameterSpacing: CGFloat = 6

    /// Retrait des lignes dans la zone qui défile, en points : la zone rogne ce qui dépasse, et le bord arrondi des champs touchait
    /// ses bords (vu dans l'image de l'éditeur, tour 2).
    static let parameterInset = CGSize(width: 3, height: 2)

    /// La hauteur de la zone visible des paramètres : jusqu'à `visibleParameterRows` lignes et leur retrait, puis elle défile.
    static func parametersViewportHeight(count: Int) -> CGFloat {
        let shown = min(max(count, 0), visibleParameterRows)
        return CGFloat(shown) * parameterRowHeight + CGFloat(max(shown - 1, 0)) * parameterSpacing + 2 * parameterInset.height
    }

    /// Les six champs, sur une grille : ils ne défilent jamais.
    private func fields(_ draft: Binding<VoicesModel.VoiceDraft>) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                fieldLabel(VoicesText.nameField)
                TextField(VoicesText.nameField, text: draft.name).labelsHidden()
            }
            GridRow {
                fieldLabel(VoicesText.providerField)
                Picker(VoicesText.providerField, selection: draft.providerID) {
                    ForEach(
                        Self.providerOptions(speaking: model.speakingProviders, current: draft.wrappedValue.providerID),
                        id: \.id
                    ) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
            }
            GridRow {
                fieldLabel(VoicesText.modelField)
                HStack(spacing: 6) {
                    TextField(VoicesText.modelField, text: draft.model).labelsHidden()
                    let models = model.models(for: draft.wrappedValue.providerID)
                    if !models.isEmpty {
                        Menu {
                            ForEach(models, id: \.self) { name in
                                Button(name) { model.editDraft { $0.model = name } }
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
            GridRow {
                fieldLabel(VoicesText.identifierField)
                TextField(VoicesText.identifierField, text: draft.identifier).labelsHidden()
            }
            GridRow {
                fieldLabel(VoicesText.languageField)
                HStack(spacing: 8) {
                    TextField(VoicesText.languageField, text: draft.language).labelsHidden()
                    if let hint = Self.languageHint(draft.wrappedValue.language) {
                        Text(hint).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }
                }
            }
            GridRow {
                fieldLabel(VoicesText.genderField)
                Picker(
                    VoicesText.genderField,
                    selection: Binding(
                        get: { Self.genderOptions(for: draft.wrappedValue).firstIndex(of: draft.wrappedValue.gender) ?? 0 },
                        set: { index in
                            let options = Self.genderOptions(for: draft.wrappedValue)
                            if options.indices.contains(index) { model.editDraft { $0.gender = options[index] } }
                        })
                ) {
                    ForEach(Array(Self.genderOptions(for: draft.wrappedValue).enumerated()), id: \.offset) { index, gender in
                        Text(VoicesText.editorGenderTitle(gender)).tag(index)
                    }
                }
                .labelsHidden()
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).gridColumnAlignment(.trailing)
    }

    /// Les paramètres : leur titre, leur zone (qui défile seule au-delà de `visibleParameterRows` lignes), le bouton d'ajout.
    private func parameters(_ draft: Binding<VoicesModel.VoiceDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(VoicesText.parametersTitle).font(.subheadline.weight(.semibold))
            let count = draft.wrappedValue.parameters.count
            if count > 0 {
                ScrollView(.vertical) {
                    VStack(spacing: Self.parameterSpacing) {
                        ForEach(Array(draft.wrappedValue.parameters.enumerated()), id: \.element.id) { index, parameter in
                            HStack(spacing: 8) {
                                TextField(VoicesText.keyField, text: Self.parameterBinding(model, id: parameter.id, \.key))
                                    .accessibilityLabel(VoicesText.parameterKeyLabel(index + 1))
                                TextField(VoicesText.valueField, text: Self.parameterBinding(model, id: parameter.id, \.value))
                                    .accessibilityLabel(VoicesText.parameterValueLabel(index + 1))
                                Button {
                                    model.editDraft { $0.parameters.removeAll { $0.id == parameter.id } }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help(VoicesText.removeParameterTitle)
                                .accessibilityLabel(VoicesText.removeParameterTitle)
                            }
                            .frame(height: Self.parameterRowHeight)
                            .background(frameProbe(.parameterRow(index)))
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, Self.parameterInset.width)
                    .padding(.vertical, Self.parameterInset.height)
                }
                .frame(height: Self.parametersViewportHeight(count: count))
                .background(frameProbe(.parametersViewport))
            }
            Button(VoicesText.addParameterTitle) {
                model.editDraft { $0.parameters.append(VoicesModel.VoiceDraft.Parameter(key: "", value: "")) }
            }
            .background(frameProbe(.addParameter))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Hauteur de la bande du refus, en points : deux lignes de texte `callout` et leurs marges. Choix non mesuré, vu en image.
    static let refusalSlotHeight: CGFloat = 44

    /// La liaison des champs de l'éditeur : elle lit le brouillon et n'écrit que par `VoicesModel.editDraft` (sans brouillon en
    /// cours, l'écriture est ignorée : R2).
    static func draftBinding(_ model: VoicesModel) -> Binding<VoicesModel.VoiceDraft> {
        Binding(get: { model.draft ?? VoicesModel.VoiceDraft() }, set: { new in model.editDraft { $0 = new } })
    }

    /// La liaison d'un champ de paramètre (T1, tour 3), PAR IDENTIFIANT et non par indice : elle lit la clé (ou la valeur) du
    /// paramètre `id` du brouillon, chaîne vide s'il n'existe plus ; elle écrit par `VoicesModel.editDraft`, en retrouvant le
    /// paramètre par `id`, et n'écrit rien s'il n'existe plus (ni brouillon, ni paramètre). Une liaison d'élément de collection
    /// lisait `parameters[indice]` : gardée par un champ après le retrait de sa ligne, elle sortait du tableau (mesuré : le
    /// processus de test tombe, « Index out of range »).
    static func parameterBinding(
        _ model: VoicesModel, id: VoicesModel.VoiceDraft.Parameter.ID,
        _ field: WritableKeyPath<VoicesModel.VoiceDraft.Parameter, String> & Sendable
    ) -> Binding<String> {
        Binding(
            get: { model.draft?.parameters.first { $0.id == id }?[keyPath: field] ?? "" },
            set: { new in
                model.editDraft { draft in
                    guard let index = draft.parameters.firstIndex(where: { $0.id == id }) else { return }
                    draft.parameters[index][keyPath: field] = new
                }
            })
    }

    public var body: some View {
        let draft = Self.draftBinding(model)
        VStack(spacing: 0) {
            Text(draft.wrappedValue.editing == nil ? VoicesText.editorAddTitle : VoicesText.editorEditTitle)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .background(frameProbe(.title))
            fields(draft)
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .background(frameProbe(.fields))
            parameters(draft)
                .padding(.horizontal, 20)
                .padding(.top, 16)
            Spacer(minLength: 0)
            ZStack(alignment: .leading) {
                Color.clear
                if let message = model.message {
                    VoicesMessageLine(band: VoicesPane.Band(text: message, kind: .notice))
                        .padding(.horizontal, 20)
                }
            }
            .frame(height: Self.refusalSlotHeight)
            .background(frameProbe(.refusalSlot))
            HStack {
                Spacer()
                Button(VoicesText.cancelTitle, role: .cancel) { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                    .background(frameProbe(.cancelButton))
                Button(VoicesText.saveTitle) { model.save() }
                    .keyboardShortcut(.defaultAction)
                    .background(frameProbe(.saveButton))
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .coordinateSpace(name: Self.coordinateSpaceName)
        .onPreferenceChange(VoiceEditorMetricsKey.self) { frames in
            if onMeasure != nil, !frames.isEmpty { onMeasure?(Metrics(frames: frames)) }
        }
    }
}

/// Les cadres mesurés de l'éditeur arrivent séparément ; la clé les réunit.
private struct VoiceEditorMetricsKey: PreferenceKey {
    static let defaultValue: [VoiceEditor.Probe: CGRect] = [:]
    static func reduce(value: inout [VoiceEditor.Probe: CGRect], nextValue: () -> [VoiceEditor.Probe: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
