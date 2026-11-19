import Foundation
import Observation
import SupervoxCore

/// L'onglet Voix : les voix du système installées et les voix de fournisseurs enregistrées, la voix en vigueur cochée, l'écoute
/// d'une voix, l'ajout, la modification et la suppression d'une voix de fournisseur.
///
/// Les réglages vivent dans `AppSettings` : le modèle n'en garde aucune copie à réécrire. `read` donne les réglages en vigueur,
/// `update` les modifie et les enregistre (en production, `AppController.updateSettings`). Chaque geste relit les réglages en vigueur
/// dans la fermeture d'`update`, y applique SON changement, en UNE écriture : ce qui s'est écrit ailleurs entre-temps reste. Après
/// chaque geste, réussi ou non, l'affichage est ce que `read` donne ; un refus le dit dans `message` par la phrase d'une
/// `SettingsError` ou une phrase fixe (jamais le texte d'une erreur).
///
/// La voix en vigueur : la ligne cochée est la PREMIÈRE ligne affichée que `VoiceChoice.isSameVoice(as:)` désigne (une seule) ;
/// sans ligne, une ligne « Voix en vigueur » la montre. « Modifier » ou « supprimer » la voix en vigueur s'entendent de cette ligne,
/// décidée sur les réglages relus au moment de l'écriture, par la même fonction que l'affichage.
@MainActor @Observable
public final class VoicesModel {
    public typealias Update = @MainActor ((inout AppSettings) -> Void) throws -> Void

    public enum Section: Equatable, Sendable {
        case system, provider
    }

    /// Le filtre de genre ; une ligne appartient à un seul groupe (`Row.genderGroup`, jamais `.all`).
    public enum GenderFilter: CaseIterable, Equatable, Sendable {
        case all, female, male, neutral, unspecified
    }

    public struct Row: Identifiable, Equatable, Sendable {
        public enum ID: Hashable, Sendable {
            /// La meilleure voix du système pour cette langue.
            case automatic(language: String)
            /// Une voix du système installée.
            case system(identifier: String)
            /// Une voix enregistrée (`AppSettings.voices`), par son `id`.
            case saved(UUID)
            /// La voix en vigueur, quand aucune autre ligne ne la montre.
            case active
        }

        public var id: ID
        public var section: Section
        /// Le nom : celui de la voix, « Automatique » ou « Voix en vigueur ».
        public var title: String
        /// Langue, genre et qualité d'une voix du système ; fournisseur et modèle d'une voix enregistrée.
        public var detail: String
        public var language: String
        public var genderGroup: GenderFilter
        /// La voix que la ligne désigne (pour une voix enregistrée, telle qu'enregistrée).
        public var choice: VoiceChoice
        /// La ligne cochée : la voix en vigueur.
        public var isActive: Bool
        /// Ce qui ne va pas : la raison d'une voix inutilisable, ou « n'est plus installée » / « n'est pas enregistrée ».
        public var note: String?
        /// « Utiliser cette voix » est possible.
        public var canUse: Bool

        /// Une voix enregistrée : elle se modifie et se supprime.
        public var savedID: UUID? {
            if case .saved(let id) = id { return id }
            return nil
        }
    }

    /// Le brouillon d'une voix de fournisseur.
    public struct VoiceDraft: Equatable, Sendable {
        public struct Parameter: Equatable, Identifiable, Sendable {
            public var id = UUID()
            public var key: String
            public var value: String

            public init(key: String, value: String) {
                self.key = key
                self.value = value
            }
        }

        /// La voix enregistrée modifiée ; `nil` : une voix neuve.
        public var editing: UUID?
        public var name: String
        public var providerID: UUID?
        /// Choisi dans la liste du fournisseur (`models(for:)`) ou saisi librement.
        public var model: String
        public var identifier: String
        public var language: String
        public var gender: VoiceGender?
        public var parameters: [Parameter]

        public init(
            editing: UUID? = nil, name: String = "", providerID: UUID? = nil, model: String = "", identifier: String = "",
            language: String = VoiceChoice.system.language, gender: VoiceGender? = nil, parameters: [Parameter] = []
        ) {
            self.editing = editing
            self.name = name
            self.providerID = providerID
            self.model = model
            self.identifier = identifier
            self.language = language
            self.gender = gender
            self.parameters = parameters
        }
    }

    // MARK: - État

    /// Les réglages tels que `read` les a donnés la dernière fois.
    private var settings: AppSettings
    /// Les voix installées à la dernière lecture.
    private var installed: [SystemVoiceInfo]
    /// Le filtre de langue ; `nil` : toutes les langues. Au départ, la langue de la voix en vigueur. Un changement qui cache la
    /// ligne choisie la désélectionne et arrête l'écoute. Tout changement efface une panne d'écoute affichée.
    public var language: String? {
        didSet { filtersChanged(language != oldValue) }
    }
    /// Le filtre de genre ; même règle que la langue.
    public var gender: GenderFilter = .all {
        didSet { filtersChanged(gender != oldValue) }
    }
    /// La ligne choisie. Une ligne que les filtres cachent n'est jamais visée par un geste (`selectedRow` ne la rend pas). Un
    /// changement efface une panne d'écoute affichée ; une écoute en cours continue (« Arrêter » reste là).
    public var selection: Row.ID? {
        didSet { if selection != oldValue { clearFailedPreview() } }
    }
    public var draft: VoiceDraft?
    public private(set) var message: String?
    public private(set) var previewState: VoicePreview.State = .idle
    /// La ligne dont l'écoute est en préparation ou en lecture ; `nil` sinon (fin, arrêt, panne, remplacement).
    public private(set) var listeningRow: Row.ID?
    /// La voix enregistrée dont la suppression attend la confirmation (visée au moment de la demande), `nil` sinon.
    public private(set) var pendingDeletion: UUID?

    @ObservationIgnored private let read: @MainActor () -> AppSettings
    @ObservationIgnored private let update: Update
    @ObservationIgnored private let systemVoices: @Sendable () -> [SystemVoiceInfo]
    @ObservationIgnored private let preview: VoicePreview
    @ObservationIgnored private let microphoneBusy: @MainActor () -> Bool

    /// - Parameter microphoneBusy: un reflet d'AFFICHAGE (l'appelant y lit l'état observable du panneau) : il grise « Écouter »
    ///   et ne décide de rien ; la garantie est dans `VoicePreview.start`, qui refuse l'écoute tant qu'un micro est tenu.
    public init(
        read: @escaping @MainActor () -> AppSettings, update: @escaping Update,
        systemVoices: @escaping @Sendable () -> [SystemVoiceInfo], preview: VoicePreview,
        microphoneBusy: @escaping @MainActor () -> Bool
    ) {
        self.read = read
        self.update = update
        self.systemVoices = systemVoices
        self.preview = preview
        self.microphoneBusy = microphoneBusy
        let settings = read()
        self.settings = settings
        installed = systemVoices()
        language = settings.voice.normalized.language
    }

    /// Relit les réglages et la liste des voix (à chaque affichage de l'onglet). Le message reste.
    public func reload() {
        settings = read()
        installed = systemVoices()
    }

    /// Efface le message de l'onglet (apparition du volet, présentation de la fenêtre, geste d'écoute). Pas tant qu'un brouillon
    /// est ouvert : le message est alors le refus que l'éditeur montre (R3, tour 2).
    public func clearMessage() {
        guard draft == nil else { return }
        message = nil
    }

    /// LA règle d'écriture de l'éditeur (R2, tour 2) : sans brouillon en cours, l'écriture est ignorée. Une écriture tardive (un
    /// champ qui pousse sa valeur en perdant la main, après « Enregistrer » ou « Annuler ») ne recrée donc jamais un brouillon, ni
    /// la feuille.
    public func editDraft(_ change: (inout VoiceDraft) -> Void) {
        guard var edited = draft else { return }
        change(&edited)
        draft = edited
    }

    /// L'onglet est quitté (son volet disparaît, un autre onglet est choisi) : l'écoute en cours s'arrête, la confirmation en
    /// attente est annulée et le brouillon est abandonné (R3, tour 2 : remplace « brouillon gardé »). Jamais appelé quand la
    /// fenêtre perd la clé (`onLeave`) : la feuille elle-même la lui fait perdre, et la fermerait à peine ouverte.
    public func leave() {
        stopListening()
        cancelConfirmation()
        if draft != nil { cancel() }
    }

    // MARK: - Lignes

    /// Les lignes montrées : celles qui passent les filtres, et toujours la voix en vigueur.
    public var rows: [Row] {
        Self.allRows(settings: settings, installed: installed).filter { row in
            let languageMatches = language.map { Self.languageKey(row.language) == Self.languageKey($0) } ?? true
            let genderMatches = gender == .all || row.genderGroup == gender
            return row.isActive || (languageMatches && genderMatches)
        }
    }

    /// Les langues proposées par le filtre (voix installées et enregistrées, et toujours la langue en cours du filtre, même si
    /// plus aucune voix ne la porte), triées, sans doublon.
    public var languages: [String] {
        var seen = Set<String>()
        let listed = Self.allRows(settings: settings, installed: installed)
            .filter { $0.id != .active }
            .map(\.language)
        return (listed + (language.map { [$0] } ?? []))
            .sorted()
            .filter { seen.insert(Self.languageKey($0)).inserted }
    }

    /// La ligne choisie, si elle est montrée (`rows`) ; `nil` sinon.
    public var selectedRow: Row? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    public var canUse: Bool { selectedRow?.canUse ?? false }
    /// Faux tant que le micro est tenu (reflet d'affichage : l'écoute refuse d'elle-même).
    public var canListen: Bool { selectedRow != nil && !microphoneBusy() }
    public var canEdit: Bool { selectedRow?.savedID != nil }
    public var canDelete: Bool { selectedRow?.savedID != nil }

    /// Toutes les lignes, dans l'ordre : par langue installée, « Automatique » puis les voix de la langue par nom ; puis les voix
    /// enregistrées par langue, puis nom ; la ligne « Voix en vigueur » en tête de sa section si nulle autre ne la montre.
    static func allRows(settings: AppSettings, installed: [SystemVoiceInfo]) -> [Row] {
        var system: [Row] = []
        var languagesSeen = Set<String>()
        let languages = installed.map(\.language).sorted().filter { languagesSeen.insert(languageKey($0)).inserted }
        for language in languages {
            system.append(
                Row(
                    id: .automatic(language: language), section: .system, title: VoicesText.automatic,
                    detail: "\(VoicesText.languageName(language)) · \(VoicesText.automaticDetail)", language: language,
                    genderGroup: .unspecified,
                    choice: VoiceChoice(language: language), isActive: false, note: nil, canUse: true))
            let voices = installed
                .filter { languageKey($0.language) == languageKey(language) }
                .sorted { (sortKey($0.name), $0.identifier) < (sortKey($1.name), $1.identifier) }
            for voice in voices {
                let gender = voiceGender(voice.gender)
                system.append(
                    Row(
                        id: .system(identifier: voice.identifier), section: .system,
                        title: voice.name.isEmpty ? voice.identifier : voice.name,
                        detail: "\(VoicesText.languageName(voice.language)) · \(VoicesText.genderTitle(gender)) · "
                            + VoicesText.quality(voice.quality),
                        language: voice.language, genderGroup: group(gender),
                        choice: VoiceChoice(identifier: voice.identifier, language: voice.language, gender: gender),
                        isActive: false, note: nil, canUse: true))
            }
        }

        let saved = settings.voices.enumerated()
            .sorted { lhs, rhs in
                let left = (languageKey(lhs.element.voice.normalized.language), sortKey(lhs.element.name), lhs.offset)
                let right = (languageKey(rhs.element.voice.normalized.language), sortKey(rhs.element.name), rhs.offset)
                return left < right
            }
            .map { savedRow($0.element, settings: settings) }

        var rows = system + saved
        let active = settings.voice
        if let index = rows.firstIndex(where: { active.isSameVoice(as: $0.choice) }) {
            rows[index].isActive = true
            // La voix déjà en vigueur : « Utiliser cette voix » n'a rien à faire (tâche 4, C3).
            rows[index].canUse = false
        } else {
            let normalized = active.normalized
            let isSystem = normalized.providerID == nil
            let row = Row(
                id: .active, section: isSystem ? .system : .provider, title: VoicesText.activeVoice,
                detail: isSystem
                    ? "\(VoicesText.languageName(normalized.language)) · \(normalized.identifier ?? VoicesText.automatic)"
                    : providerDetail(normalized, settings: settings),
                language: normalized.language, genderGroup: group(normalized.gender), choice: active, isActive: true,
                note: isSystem ? VoicesText.noLongerInstalled : VoicesText.notSaved, canUse: false)
            rows.insert(row, at: isSystem ? 0 : system.count)
        }
        return rows
    }

    private static func savedRow(_ saved: SavedVoice, settings: AppSettings) -> Row {
        let voice = saved.voice.normalized
        let note: String?
        switch saved.voice.route(in: settings) {
        case .provider: note = nil
        case .system(_, _, because: let reason?): note = VoicesText.reason(reason)
        case .system: note = nil
        }
        let usable: Bool = if case .provider = saved.voice.route(in: settings) { true } else { false }
        return Row(
            id: .saved(saved.id), section: .provider, title: saved.name, detail: providerDetail(voice, settings: settings),
            language: voice.language, genderGroup: group(voice.gender), choice: saved.voice, isActive: false, note: note,
            canUse: usable)
    }

    /// « Fournisseur · modèle · langue en clair » (le fournisseur absent des réglages : « Fournisseur supprimé » ; sans langue,
    /// rien à sa place — une voix normalisée en a toujours une).
    private static func providerDetail(_ voice: VoiceChoice, settings: AppSettings) -> String {
        let provider = settings.providers.first { $0.id == voice.providerID }
        let name = provider.map { Provider.shortName($0.name) } ?? VoicesText.providerRemovedName
        let language = voice.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil : VoicesText.languageName(voice.language)
        return [name, voice.model, language].compactMap { $0 }.joined(separator: " · ")
    }

    /// La ligne cochée, sur ces réglages : celle de l'affichage.
    static func activeRowID(settings: AppSettings, installed: [SystemVoiceInfo]) -> Row.ID? {
        allRows(settings: settings, installed: installed).first { $0.isActive }?.id
    }

    private static func voiceGender(_ gender: SystemVoiceGender?) -> VoiceGender? {
        switch gender {
        case .female?: .female
        case .male?: .male
        case nil: nil
        }
    }

    private static func group(_ gender: VoiceGender?) -> GenderFilter {
        switch gender {
        case .female?: .female
        case .male?: .male
        case .neutral?: .neutral
        case .other?, nil: .unspecified
        }
    }

    /// Sans casse, `_` et `-` confondus : la règle de `isSameVoice(as:)`.
    static func languageKey(_ language: String) -> String {
        language.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// Ordre des noms : sans casse ni accents, indépendant de la langue du système.
    private static func sortKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: - Vie privée (règle 10)

    /// Ce que l'écoute de la voix choisie envoie, selon `route(in:)` : rien (voix du système ; voix de fournisseur qui ne peut pas
    /// parler, qui le dit), ou la phrase d'essai et la lecture de la clé (voix de fournisseur). `nil` sans ligne choisie.
    public var privacyText: String? {
        guard let row = selectedRow else { return nil }
        switch row.choice.route(in: settings) {
        case .provider(let provider, _): return VoicesText.privacyProvider(Provider.shortName(provider.name))
        case .system(_, _, because: .some): return VoicesText.privacyCannotSpeak
        case .system: return VoicesText.privacyNothingSent
        }
    }

    // MARK: - Utiliser (règle 6)

    /// Écrit la voix de la ligne choisie dans `settings.voice`, et rien d'autre : une voix du système sans fournisseur, une voix
    /// enregistrée sous sa forme normalisée. Relit d'abord les réglages : sans effet pour une ligne qui ne peut pas servir ou qui
    /// n'existe plus.
    public func use() {
        reload()
        guard let row = selectedRow, row.canUse else { return }
        let voice: VoiceChoice = switch row.id {
        case .saved: row.choice.normalized
        case .automatic, .system, .active:
            VoiceChoice(identifier: row.choice.identifier, language: row.choice.language, gender: row.choice.gender)
        }
        commit { $0.voice = voice }
    }

    // MARK: - Écouter (règles 7 à 9)

    /// La phrase de l'état de l'écoute : celle de la panne, `nil` sinon.
    public var previewMessage: String? {
        if case .failed(let failure) = previewState { return VoicesText.failure(failure) }
        return nil
    }

    /// Écoute la voix choisie. Relit d'abord les réglages et la liste des voix, puis décide et lance sur ce même instantané : la
    /// note de vie privée et l'écoute ne peuvent pas diverger. Une voix du système désignée absente de la liste :
    /// `.failed(.notInstalled)`, sans fabriquer de voix (contrôlé par l'écoute, `VoicePreview`, seul endroit) ; un micro tenu :
    /// `.failed(.microphoneBusy)` (refusé par l'écoute).
    public func listen() {
        reload()
        guard let row = selectedRow else { return }
        let id = row.id
        preview.start(row.choice, settings: settings) { [weak self] state in
            guard let self else { return }
            previewState = state
            switch state {
            case .preparing, .playing: listeningRow = id
            case .idle, .failed: listeningRow = nil
            }
        }
    }

    /// Arrête l'écoute en cours. Une seule règle pour l'état (R4, tour 2) : seule une écoute en préparation ou en lecture revient
    /// au repos ; une panne affichée survit (la fenêtre qui perd la clé appelle cet arrêt : `onLeave`) et n'est effacée que par les
    /// gestes qui la rendent ancienne (`clearFailedPreview`).
    public func stopListening() {
        preview.stop()
        listeningRow = nil
        switch previewState {
        case .preparing, .playing: previewState = .idle
        case .idle, .failed: break
        }
    }

    /// Une panne d'écoute affichée est effacée (une écoute en cours n'est pas touchée). Appelé par les gestes qui la rendent
    /// ancienne : changement de sélection ou de filtre, écriture réussie (`use`, `save`, suppression confirmée).
    private func clearFailedPreview() {
        if case .failed = previewState { previewState = .idle }
    }

    private func filtersChanged(_ changed: Bool) {
        if changed { clearFailedPreview() }
        dropHiddenSelection()
    }

    /// Un filtre a caché la ligne choisie : elle n'est plus choisie, l'écoute en cours s'arrête, et une demande de suppression
    /// en attente est lâchée avec elle.
    private func dropHiddenSelection() {
        guard let selection, !rows.contains(where: { $0.id == selection }) else { return }
        self.selection = nil
        pendingDeletion = nil
        stopListening()
    }

    // MARK: - Supprimer (règle 6)

    /// La question posée avant de supprimer, `nil` sans demande en cours.
    public var confirmationText: String? {
        guard let id = pendingDeletion, let saved = settings.voices.first(where: { $0.id == id }) else { return nil }
        let isActive = Self.activeRowID(settings: settings, installed: installed) == .saved(id)
        return VoicesText.deleteConfirmation(name: saved.name, isActive: isActive)
    }

    public func requestDeletion() {
        guard let id = selectedRow?.savedID else { return }
        pendingDeletion = id
    }

    public func cancelConfirmation() {
        pendingDeletion = nil
    }

    /// Supprime la voix visée par la demande, en une écriture, si elle est encore la ligne choisie et montrée (sinon la demande est
    /// consommée sans rien écrire). Si c'était la voix en vigueur (la ligne cochée, sur les réglages relus), la voix automatique du
    /// système en français la remplace dans la même écriture, et le message le dit.
    public func confirmDeletion() {
        guard let id = pendingDeletion else { return }
        pendingDeletion = nil
        guard selectedRow?.savedID == id else { return }
        let installed = installed
        var wasActive = false
        let written = commit { settings in
            wasActive = Self.activeRowID(settings: settings, installed: installed) == .saved(id)
            settings.voices.removeAll { $0.id == id }
            if wasActive { settings.voice = .system }
        }
        guard written else { return }
        if selection == .saved(id) { selection = nil }
        if wasActive { message = VoicesText.deletedActive }
    }

    // MARK: - Brouillon (règle 5)

    /// Les fournisseurs qui savent parler (`ProviderKind.canSpeak`).
    public var speakingProviders: [Provider] {
        settings.providers.filter { $0.kind.canSpeak }
    }

    /// Les modèles connus d'un fournisseur qui sait parler ; vide sinon (le modèle se saisit alors librement).
    public func models(for providerID: UUID?) -> [String] {
        speakingProviders.first { $0.id == providerID }?.models ?? []
    }

    public func beginAdding() {
        message = nil
        draft = VoiceDraft(providerID: speakingProviders.first?.id, language: settings.voice.normalized.language)
    }

    /// Ouvre le brouillon de la voix enregistrée choisie.
    public func beginEditing() {
        guard let id = selectedRow?.savedID, let saved = settings.voices.first(where: { $0.id == id }) else { return }
        message = nil
        let voice = saved.voice
        draft = VoiceDraft(
            editing: id, name: saved.name, providerID: voice.providerID, model: voice.model ?? "",
            identifier: voice.identifier ?? "", language: voice.language, gender: voice.gender,
            parameters: voice.extra.sorted { $0.key < $1.key }.map { VoiceDraft.Parameter(key: $0.key, value: $0.value) })
    }

    /// Ferme le brouillon sans rien écrire.
    public func cancel() {
        draft = nil
        message = nil
    }

    // Laissé : pas de refus « voix supprimée ailleurs » ici (`git grep` : seul ce modèle écrit `voices`).

    /// Enregistre le brouillon, ou dit pourquoi il ne s'enregistre pas (une phrase par cas, rien d'écrit, le brouillon reste).
    /// Accepté : `voices` est écrit en une fois sur les réglages relus (une voix modifiée l'est en place) ; modifier la voix en
    /// vigueur (la ligne cochée) écrit aussi `settings.voice`, dans la même écriture. Ce qui est écrit est la forme normalisée.
    public func save() {
        guard let draft else { return }
        if let refusal = refusal(of: draft) {
            message = refusal
            return
        }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = draft.editing ?? UUID()
        let installed = installed
        let written = commit { settings in
            let index = settings.voices.firstIndex { $0.id == id }
            var voice = index.map { settings.voices[$0].voice } ?? VoiceChoice()
            voice.providerID = draft.providerID
            voice.model = draft.model
            voice.identifier = draft.identifier
            voice.language = draft.language
            voice.gender = draft.gender
            voice.extra = Dictionary(
                draft.parameters.map { ($0.key.trimmingCharacters(in: .whitespacesAndNewlines), $0.value) },
                uniquingKeysWith: { first, _ in first })
            voice = voice.normalized
            if let index {
                let wasActive = Self.activeRowID(settings: settings, installed: installed) == .saved(id)
                settings.voices[index].name = name
                settings.voices[index].voice = voice
                if wasActive { settings.voice = voice }
            } else {
                settings.voices.append(SavedVoice(id: id, name: name, voice: voice))
            }
        }
        guard written else { return }
        self.draft = nil
        // Une voix qu'on vient d'enregistrer se voit (R1, tour 2, remplace la décision 11) : cachée par les filtres en cours, le
        // filtre de langue passe à la langue ÉCRITE de cette voix (normalisée : jamais vide ; « toutes » si elle a disparu) et celui de
        // genre à « tous ». AVANT de la choisir : chaque `didSet` des filtres lâche une sélection encore cachée par l'autre filtre.
        if !rows.contains(where: { $0.id == .saved(id) }) {
            language = settings.voices.first { $0.id == id }?.voice.normalized.language
            gender = .all
        }
        selection = .saved(id)
    }

    /// La phrase qui refuse ce brouillon, `nil` s'il est acceptable. Ordre : nom, fournisseur, modèle, identifiant, puis les
    /// paramètres (clé vide, clé réservée sans casse, clé en double une fois rognée, trop de paramètres).
    private func refusal(of draft: VoiceDraft) -> String? {
        func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blank(draft.name) { return VoicesText.refusalEmptyName }
        guard let providerID = draft.providerID, speakingProviders.contains(where: { $0.id == providerID }) else {
            return VoicesText.refusalNoProvider
        }
        if blank(draft.model) { return VoicesText.refusalEmptyModel }
        if blank(draft.identifier) { return VoicesText.refusalEmptyIdentifier }
        let keys = draft.parameters.map { $0.key.trimmingCharacters(in: .whitespacesAndNewlines) }
        if keys.contains(where: \.isEmpty) { return VoicesText.refusalEmptyKey }
        if keys.contains(where: { VoiceChoice.reservedExtraKeys.contains($0.lowercased()) }) {
            return VoicesText.refusalReservedKey
        }
        if Set(keys).count != keys.count { return VoicesText.refusalDuplicateKey }
        if keys.count > VoiceChoice.maxExtraEntries { return VoicesText.refusalTooManyParameters }
        return nil
    }

    // MARK: - Écriture

    /// Appelle `update` une fois. Réussi : le message s'efface. Refusé : `SettingsError.sentence(forSaveError:)` (la phrase de la
    /// `SettingsError`, sinon la phrase fixe commune ; jamais le texte de l'erreur). Dans les deux cas, l'affichage est relu.
    @discardableResult
    private func commit(_ change: (inout AppSettings) -> Void) -> Bool {
        do {
            try update(change)
            message = nil
            clearFailedPreview()
            settings = read()
            return true
        } catch {
            message = SettingsError.sentence(forSaveError: error)
            settings = read()
            return false
        }
    }
}
