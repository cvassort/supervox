import AppKit
import Carbon.HIToolbox
import Observation

/// Ce que l'onglet Modes peut faire des raccourcis des modes (en production : `AppController`).
@MainActor
public struct ModeHotKeyControl {
    /// Donne cette combinaison au mode, ou la lui retire avec `nil` ; en cas de refus, l'ancienne reste active.
    public var apply: @MainActor (HotKey?, String) -> Result<Void, HotKeyError>
    /// Rend au système tous les raccourcis (global, modes) et Échap, le temps d'une capture.
    public var suspend: @MainActor () -> Void
    /// Réenregistre ce que `suspend` a rendu. Rend faux si le système refuse le raccourci général.
    public var resume: @MainActor () -> Bool
    /// Le raccourci général attribué dans les réglages.
    public var global: @MainActor () -> HotKey?

    public init(
        apply: @escaping @MainActor (HotKey?, String) -> Result<Void, HotKeyError>,
        suspend: @escaping @MainActor () -> Void, resume: @escaping @MainActor () -> Bool,
        global: @escaping @MainActor () -> HotKey?
    ) {
        self.apply = apply
        self.suspend = suspend
        self.resume = resume
        self.global = global
    }
}

/// Ce que la feuille d'édition d'un mode montre et propose de changer. Le raccourci n'en fait pas partie : il se règle par sa
/// propre capture (`ModesModel.startRecording(for:)`), `hotKeyLabel` n'est là que pour l'afficher.
public struct ModeDraft: Equatable, Sendable {
    public var id: String
    public var name: String
    /// La consigne qui s'applique (celle du mode, ou son origine pour un mode de base) ; vide pour Dictée brute et Entretien.
    public var instruction: String
    /// Faux pour Dictée brute et Entretien : le texte n'y passe pas par le modèle de langage.
    public var isInstructionEditable: Bool
    /// Vrai si un mode de base porte une consigne qui n'est plus celle d'origine.
    public var isInstructionModified: Bool
    /// `nil` : le modèle fort.
    public var model: ModelChoice?
    /// `nil` : le moteur de l'onglet Transcription.
    public var engine: TranscriptionEngine?
    public var reviews: Bool
    public var hotKeyLabel: String?

    public init(
        id: String, name: String, instruction: String, isInstructionEditable: Bool, isInstructionModified: Bool,
        model: ModelChoice?, engine: TranscriptionEngine?, reviews: Bool, hotKeyLabel: String?
    ) {
        self.id = id
        self.name = name
        self.instruction = instruction
        self.isInstructionEditable = isInstructionEditable
        self.isInstructionModified = isInstructionModified
        self.model = model
        self.engine = engine
        self.reviews = reviews
        self.hotKeyLabel = hotKeyLabel
    }

    /// La consigne d'origine d'un mode de base, `nil` pour un mode qui n'en a pas.
    public var originalInstruction: String? { ModeDefaults.instruction(for: id) }

    /// « Revenir à la consigne d'origine » : ne change que ce brouillon. Rien n'est écrit avant `ModesModel.save`, qui enregistre
    /// `nil` quand la consigne égale l'origine ; abandonner la feuille laisse la consigne des réglages. Sans effet pour un mode
    /// qui n'a pas d'origine.
    public mutating func resetInstructionToOrigin() {
        guard let origin = originalInstruction else { return }
        instruction = origin
        isInstructionModified = false
    }
}

/// L'onglet Modes : la liste des modes (créer, modifier, dupliquer, déplacer, supprimer), leur consigne, leur modèle, leur
/// raccourci, et les modèles fort et rapide.
///
/// Les modes vivent dans les réglages : le modèle ne garde aucune copie à écrire. `read` donne les réglages en vigueur, `update`
/// les modifie et les enregistre (en production, `AppController.updateSettings`). Chaque geste décide d'après `read` (le mode
/// existe-t-il encore, le nom est-il libre…), puis appelle `update` une fois, avec un changement qui retrouve le mode par son
/// identifiant dans les réglages en vigueur et ne touche que ce que le geste touche : une écriture faite ailleurs entre deux
/// gestes (le panneau change de mode, un autre onglet ajoute un fournisseur) reste. Après chaque geste, réussi ou non,
/// l'affichage est ce que `read` donne ; un enregistrement refusé le dit dans `message`, par la phrase de `SettingsError` ou par
/// une phrase fixe, jamais par le texte de l'erreur.
@MainActor @Observable
public final class ModesModel {
    /// Une ligne de l'onglet.
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        /// Modèle, moteur de dictée et raccourci du mode, en une ligne.
        public let summary: String
        /// Vrai si le texte de ce mode passe par la relecture.
        public let reviews: Bool
        /// Vrai si le choix de relecture n'est pas à l'utilisateur (Entretien).
        public let isReviewLocked: Bool
        /// Faux pour Dictée brute et Entretien.
        public let canDelete: Bool
        /// Ce que la ligne dit en plus, ou `nil`.
        public let note: String?
    }

    /// Un fournisseur et les modèles de sa dernière liste.
    public struct ModelOption: Equatable, Identifiable, Sendable {
        public let providerID: UUID
        public let providerName: String
        public let models: [String]
        public var id: UUID { providerID }

        public init(providerID: UUID, providerName: String, models: [String]) {
            self.providerID = providerID
            self.providerName = providerName
            self.models = models
        }
    }

    public typealias Update = @MainActor ((inout AppSettings) -> Void) throws -> Void

    // MARK: - Textes

    /// La phrase d'en-tête de l'onglet.
    public static let header =
        "Un mode dit ce que devient le texte dicté. Sans consigne, il est collé tel quel. Avec une consigne, le texte (jamais l'audio) est envoyé au fournisseur choisi pour être mis en forme ; l'audio ne quitte jamais cet ordinateur."
    public static let strongTitle = "Modèle fort"
    public static let strongNote =
        "Réécrit le texte quand vous le corrigez à la voix, et sert aux modes qui n'ont pas de modèle propre."
    public static let fastTitle = "Modèle rapide"
    public static let fastNote = "Servira à l'entretien vocal, à une étape suivante."
    public static let toggleTitle = "Relire avant de coller"
    public static let alwaysReviewedNote = "Toujours relu : l'entretien passe toujours par la relecture."
    public static let laterModeNote = "Ce mode arrive à une étape suivante."
    /// Le choix « pas de modèle propre » d'un mode.
    public static let defaultModelTitle = "Modèle fort (par défaut)"
    /// Le choix « aucun » des modèles fort et rapide.
    public static let noModelTitle = "Aucun"
    public static let absentFromListMarker = "absent de la dernière liste"
    public static let removedProviderMarker = "fournisseur supprimé"
    public static let removedProviderNote = "Fournisseur supprimé : choisissez un autre modèle."
    public static let noStrongModelNote =
        "Aucun modèle fort n'est choisi : le texte de ce mode ne pourra pas être mis en forme. Choisissez-en un en tête de l'onglet Modes, dans « Modèles », ou choisissez un modèle propre à ce mode."
    /// Sur la ligne d'un mode qui dépend du modèle fort, tant qu'aucun n'est choisi. La section « Modèles » est en tête de l'onglet.
    public static let noStrongModelRowNote = "Aucun modèle fort n'est choisi : choisissez-en un ci-dessus, dans « Modèles »."
    public static let noProviderNote = "Aucun fournisseur n'est enregistré : ajoutez-en un dans l'onglet Fournisseurs."
    public static let noTranscriptionEngineTitle = "Moteur de l'onglet Transcription"
    public static let pastedAsIsSummary = "Texte collé tel quel"
    /// Ce que l'onglet dit quand l'enregistrement échoue pour une autre raison qu'une `SettingsError`. Le texte de l'erreur n'y
    /// est jamais repris : une erreur d'ailleurs peut porter une adresse.
    public static let saveFailure = "Ce changement n'a pas pu être enregistré : les modes gardent leur état précédent."
    public static let unknownModeMessage = "Ce mode n'existe plus : la liste vient d'être relue."
    public static let blankNameMessage = "Donnez un nom au mode."
    /// Le plus long nom qu'un mode peut porter (en caractères, blancs de bord retirés).
    public static let nameLimit = 60
    public static let nameTooLongMessage = "Le nom d'un mode ne peut pas dépasser 60 caractères."
    public static let nameTakenMessage = "Un autre mode porte déjà ce nom : choisissez-en un autre."
    public static let noActiveHotKeyNote = "Aucun raccourci n'est actif pour ce mode."

    /// La note de vie privée de la feuille d'un mode, sous le modèle. Le nom du fournisseur est rogné (`Provider.shortName`).
    public static func privacyNote(providerName: String) -> String {
        "Ce mode envoie le texte dicté à « \(Provider.shortName(providerName)) ». L'audio reste sur cet ordinateur."
    }

    /// Un fournisseur dont la dernière liste est vide renvoie à l'onglet Fournisseurs.
    public static func unlistedNote(providerName: String) -> String {
        "« \(Provider.shortName(providerName)) » n'a aucun modèle listé : ouvrez l'onglet Fournisseurs, puis choisissez « Lister les modèles »."
    }

    /// Le raccourci général n'a pas pu être rétabli à la fin d'une capture.
    public static func resumeFailure(label: String) -> String {
        "Le raccourci général \(label) n'a pas pu être rétabli après la capture : macOS l'a refusé. Choisissez-en un autre dans l'onglet Raccourci."
    }

    // MARK: - État

    /// Les réglages tels que `read` les a donnés la dernière fois : tout ce que l'onglet montre en est dérivé.
    private var settings: AppSettings
    public private(set) var message: String?
    /// Avance d'un cran à chaque enregistrement refusé. La vue s'en sert pour recréer les contrôles : sans cela, rien ne les
    /// ramène à la valeur enregistrée (le modèle n'a pas changé, donc SwiftUI n'a aucune raison de redessiner le contrôle que
    /// l'utilisateur vient de basculer).
    public private(set) var revision = 0
    /// Le mode dont la capture de raccourci est en cours.
    public private(set) var recordingModeID: String?

    @ObservationIgnored private let read: @MainActor () -> AppSettings
    @ObservationIgnored private let update: Update
    @ObservationIgnored private let hotKeys: ModeHotKeyControl
    @ObservationIgnored private let layout: any KeyboardLayout
    @ObservationIgnored private let systemHotKeys: any SystemHotKeys
    @ObservationIgnored private let keyMonitor: any KeyEventMonitor

    public init(
        read: @escaping @MainActor () -> AppSettings, update: @escaping Update, hotKeys: ModeHotKeyControl,
        layout: any KeyboardLayout, systemHotKeys: any SystemHotKeys, keyMonitor: any KeyEventMonitor
    ) {
        self.read = read
        self.update = update
        self.hotKeys = hotKeys
        self.layout = layout
        self.systemHotKeys = systemHotKeys
        self.keyMonitor = keyMonitor
        settings = read()
    }

    /// Relit les réglages : à chaque présentation de la fenêtre et à chaque affichage de l'onglet, une écriture faite ailleurs s'y
    /// voit. Le message, lui, reste : il dit ce qui vient de se passer, et `clearMessage()` l'efface.
    public func reload() {
        settings = read()
    }

    /// Efface le message (le refus d'un geste dont l'écran n'est plus ouvert, un message d'avant la présentation de la fenêtre).
    public func clearMessage() {
        message = nil
    }

    // MARK: - Ce que l'onglet montre

    /// Une ligne par mode, dans l'ordre des pastilles du panneau.
    public var rows: [Row] { settings.modes.map(row) }

    /// Les fournisseurs, chacun avec les modèles de sa dernière liste.
    public var modelOptions: [ModelOption] {
        settings.providers.map { ModelOption(providerID: $0.id, providerName: $0.name, models: $0.models) }
    }

    public var strongModel: ModelChoice? { settings.strongModel }
    public var fastModel: ModelChoice? { settings.fastModel }

    /// Dictée nettoyée et Prompt, quand ils ont été supprimés : `addBase` les remet.
    public var missingBaseModes: [ModeChip] {
        Mode.base.filter { base in base.canDelete && settings.mode(base.id) == nil }.map(\.chip)
    }

    /// Le libellé du raccourci d'un mode, `nil` s'il n'en a pas.
    public func hotKeyLabel(for id: String) -> String? { settings.mode(id)?.hotKey?.label(layout: layout) }

    /// Le mode de cet identifiant existe dans les réglages montrés.
    public func contains(_ id: String) -> Bool { settings.mode(id) != nil }

    private func row(_ mode: Mode) -> Row {
        var notes: [String] = []
        if mode.id == ModeChip.interviewID { notes += [Self.alwaysReviewedNote, Self.laterModeNote] }
        if mode.usesModel {
            // Le modèle qui recevra le texte : le sien, sinon le modèle fort. Sans lui, la ligne ne doit pas laisser croire que
            // le mode marche.
            if let choice = mode.model ?? settings.strongModel {
                if provider(choice) == nil { notes.append(Self.removedProviderNote) }
            } else {
                notes.append(Self.noStrongModelRowNote)
            }
        }
        return Row(
            id: mode.id, title: mode.name, summary: summary(mode), reviews: settings.reviewsBeforePaste(mode.id),
            isReviewLocked: AppSettings.alwaysReviewed.contains(mode.id), canDelete: mode.canDelete,
            note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    /// Modèle (ou « Modèle fort »), moteur (ou « Moteur de l'onglet Transcription »), raccourci s'il y en a. Un mode qui ne
    /// passe pas par le modèle de langage (sans consigne) n'en nomme pas : Dictée brute dit que son texte est collé tel quel ;
    /// Entretien, qui n'est pas encore là, n'en dit rien.
    private func summary(_ mode: Mode) -> String {
        var parts: [String] = []
        if mode.usesModel {
            parts.append(modelTitle(mode.model))
        } else if mode.id != ModeChip.interviewID {
            parts.append(Self.pastedAsIsSummary)
        }
        parts.append(mode.engine?.title ?? Self.noTranscriptionEngineTitle)
        if let hotKey = mode.hotKey { parts.append(hotKey.label(layout: layout)) }
        return parts.joined(separator: " · ")
    }

    private func modelTitle(_ choice: ModelChoice?) -> String {
        guard let choice else { return Self.strongTitle }
        guard let provider = provider(choice) else { return "\(choice.model) (\(Self.removedProviderMarker))" }
        return "\(choice.model) (\(provider.shortName))"
    }

    private func provider(_ choice: ModelChoice) -> Provider? { settings.providers.first { $0.id == choice.providerID } }

    // MARK: - La feuille d'un mode

    /// Ce que la feuille d'édition montre pour ce mode. Un identifiant inconnu rend un brouillon vide : la vue vérifie
    /// `contains(_:)` avant d'ouvrir.
    public func draft(for id: String) -> ModeDraft {
        guard let mode = settings.mode(id) else {
            return ModeDraft(
                id: id, name: "", instruction: "", isInstructionEditable: false, isInstructionModified: false,
                model: nil, engine: nil, reviews: false, hotKeyLabel: nil)
        }
        let origin = ModeDefaults.instruction(for: id)
        return ModeDraft(
            id: id, name: mode.name, instruction: mode.effectiveInstruction, isInstructionEditable: mode.instructionIsEditable,
            isInstructionModified: origin != nil && mode.instruction != nil && mode.instruction != origin, model: mode.model,
            engine: mode.engine, reviews: settings.reviewsBeforePaste(id), hotKeyLabel: mode.hotKey?.label(layout: layout))
    }

    /// Ce que le mode choisi dans la feuille envoie, et à qui : `nil` s'il n'envoie rien (pas de consigne) ou si personne ne
    /// reçoit le texte (aucun fournisseur à nommer).
    public func privacyNote(for draft: ModeDraft) -> String? {
        guard sendsText(draft), let choice = draft.model ?? settings.strongModel, let provider = provider(choice) else {
            return nil
        }
        return Self.privacyNote(providerName: provider.name)
    }

    /// Ce que la feuille dit du modèle quand il manque quelque chose : le fournisseur choisi est supprimé, ou aucun modèle fort
    /// n'est choisi pour un mode qui en a besoin.
    public func modelNote(for draft: ModeDraft) -> String? {
        guard sendsText(draft) else { return nil }
        // Sans aucun fournisseur, l'explication du sélecteur suffit : ne pas renvoyer à des choix qui n'existent pas encore.
        guard let choice = draft.model ?? settings.strongModel else {
            return settings.providers.isEmpty ? nil : Self.noStrongModelNote
        }
        return provider(choice) == nil ? Self.removedProviderNote : nil
    }

    private func sendsText(_ draft: ModeDraft) -> Bool {
        draft.isInstructionEditable && !draft.instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Les choix du sélecteur de modèle, par fournisseur. Un modèle déjà choisi qui n'est plus dans la dernière liste reste
    /// proposé, marqué ; un fournisseur supprimé laisse le choix affiché, marqué lui aussi, jamais effacé.
    public func pickerContent(selected: ModelChoice?) -> ModelPickerContent {
        let groups = settings.providers.map { provider in
            var items = provider.models.map { ModelPickerContent.Item(choice: ModelChoice(providerID: provider.id, model: $0), label: $0) }
            if let selected, selected.providerID == provider.id, !provider.models.contains(selected.model) {
                items.append(
                    ModelPickerContent.Item(choice: selected, label: "\(selected.model) (\(Self.absentFromListMarker))"))
            }
            return ModelPickerContent.Group(
                providerID: provider.id, title: provider.shortName, items: items,
                emptyNote: provider.models.isEmpty ? Self.unlistedNote(providerName: provider.name) : nil)
        }
        var removed: ModelPickerContent.Item?
        if let selected, provider(selected) == nil {
            removed = ModelPickerContent.Item(choice: selected, label: "\(selected.model) (\(Self.removedProviderMarker))")
        }
        return ModelPickerContent(
            groups: groups, removedProviderChoice: removed, emptyNote: groups.isEmpty ? Self.noProviderNote : nil)
    }

    // MARK: - Gestes

    /// Appelle `update` une fois. Réussi : le message s'efface. Refusé : le message le dit, la ligne revient à ce que `read`
    /// donne et la révision avance. L'affichage est relu dans les deux cas.
    @discardableResult
    private func commit(_ change: (inout AppSettings) -> Void) -> Bool {
        do {
            try update(change)
            message = nil
            settings = read()
            return true
        } catch {
            message = (error as? SettingsError)?.errorDescription ?? Self.saveFailure
            settings = read()
            revision += 1
            return false
        }
    }

    /// Les réglages en vigueur, et le mode de cet identifiant ; sans lui, le message le dit et rien n'est écrit.
    private func current(_ id: String) -> Mode? {
        settings = read()
        guard let mode = settings.mode(id) else {
            message = Self.unknownModeMessage
            return nil
        }
        return mode
    }

    /// Change le choix de relecture d'un mode. Sans effet pour un mode toujours relu, un mode inconnu, ou une valeur déjà montrée.
    public func setReview(_ on: Bool, for id: String) {
        settings = read()
        guard settings.mode(id) != nil, !AppSettings.alwaysReviewed.contains(id), settings.reviewsBeforePaste(id) != on else {
            return
        }
        commit { settings in
            guard let index = settings.modes.firstIndex(where: { $0.id == id }) else { return }
            settings.modes[index].reviewBeforePaste = on
        }
    }

    /// Ajoute « Nouveau mode » (puis « Nouveau mode 2 »…) en fin de liste, sans consigne, relecture activée. Rend son identifiant
    /// (la vue ouvre sa feuille si `contains(_:)`, l'enregistrement pouvant être refusé).
    @discardableResult
    public func add() -> String {
        settings = read()
        let mode = Mode(
            id: Mode.newID(), name: freeName("Nouveau mode", numbered: { " \($0)" }), instruction: "", reviewBeforePaste: true)
        commit { $0.modes.append(mode) }
        return mode.id
    }

    /// Place « Nom (copie) » juste après l'original, avec tous ses réglages sauf le raccourci. La consigne qui s'appliquait est
    /// recopiée en clair (un mode de base dupliqué devient personnel), le choix de relecture aussi (le défaut d'un mode tient à
    /// son identifiant, que la copie n'a pas).
    @discardableResult
    public func duplicate(_ id: String) -> String {
        guard let original = current(id) else { return Mode.newID() }
        var copy = original
        copy.id = Mode.newID()
        copy.name = freeName(Self.strippedOfCopyMark(original.name), first: " (copie)", numbered: { " (copie \($0))" })
        copy.instruction = original.effectiveInstruction
        copy.hotKey = nil
        copy.reviewBeforePaste = settings.reviewsBeforePaste(id)
        let placed = copy
        commit { settings in
            guard let index = settings.modes.firstIndex(where: { $0.id == id }) else { return }
            settings.modes.insert(placed, at: index + 1)
        }
        return placed.id
    }

    /// Remet Dictée nettoyée ou Prompt à la fin de la liste, avec sa consigne d'origine. Sans effet pour un autre identifiant ou
    /// un mode déjà là.
    public func addBase(_ id: String) {
        settings = read()
        guard let base = Mode.base.first(where: { $0.id == id && $0.canDelete }), settings.mode(id) == nil else { return }
        var mode = base
        mode.name = freeName(base.name, numbered: { " \($0)" })
        let restored = mode
        commit { settings in
            guard !settings.modes.contains(where: { $0.id == restored.id }) else { return }
            settings.modes.append(restored)
        }
    }

    /// Supprime le mode, avec son raccourci. Sans effet pour Dictée brute et Entretien. Si le mode était choisi dans le panneau,
    /// le panneau revient à Dictée brute dans la même écriture.
    public func delete(_ id: String) {
        guard let mode = current(id), mode.canDelete else { return }
        if recordingModeID == id { cancelRecording() }
        commit { settings in
            settings.modes.removeAll { $0.id == id }
            if settings.lastModeID == id { settings.lastModeID = ModeChip.fallbackID }
        }
    }

    /// Déplace le mode de `offset` crans (jamais au-delà des bornes de la liste) ; sans effet s'il ne bouge pas.
    public func move(_ id: String, by offset: Int) {
        settings = read()
        guard let from = settings.modes.firstIndex(where: { $0.id == id }), offset != 0 else { return }
        guard clamp(from + offset, count: settings.modes.count) != from else { return }
        commit { settings in
            guard let from = settings.modes.firstIndex(where: { $0.id == id }) else { return }
            let to = self.clamp(from + offset, count: settings.modes.count)
            guard to != from else { return }
            settings.modes.insert(settings.modes.remove(at: from), at: to)
        }
    }

    private func clamp(_ index: Int, count: Int) -> Int { min(max(index, 0), count - 1) }

    /// Enregistre ce que la feuille propose : le nom, la consigne, le modèle, le moteur, le choix de relecture. Refuse un nom
    /// blanc ou déjà pris (sans tenir compte de la casse), avec une phrase et sans rien écrire. Le raccourci n'est pas touché.
    /// Rend vrai si le mode est enregistré.
    @discardableResult
    public func save(_ draft: ModeDraft) -> Bool {
        guard current(draft.id) != nil else { return false }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            message = Self.blankNameMessage
            return false
        }
        // Un nom déjà plus long (fichier écrit à la main) reste enregistrable tant qu'on ne le change pas.
        guard name.count <= Self.nameLimit || name == settings.mode(draft.id)?.name else {
            message = Self.nameTooLongMessage
            return false
        }
        guard !settings.modes.contains(where: { $0.id != draft.id && Self.sameName($0.name, name) }) else {
            message = Self.nameTakenMessage
            return false
        }
        return commit { settings in
            guard let index = settings.modes.firstIndex(where: { $0.id == draft.id }) else { return }
            settings.modes[index].name = name
            if settings.modes[index].instructionIsEditable {
                // Une consigne de base égale à l'origine s'enregistre `nil` : l'origine, pas une copie qui la figerait.
                let origin = ModeDefaults.instruction(for: draft.id)
                settings.modes[index].instruction = draft.instruction == origin ? nil : draft.instruction
            }
            settings.modes[index].model = draft.model
            settings.modes[index].engine = draft.engine
            if !AppSettings.alwaysReviewed.contains(draft.id), draft.reviews != settings.reviewsBeforePaste(draft.id) {
                settings.modes[index].reviewBeforePaste = draft.reviews
            }
        }
    }

    /// Remet tout de suite la consigne d'origine d'un mode de base dans les réglages. Sans effet pour un mode qui n'en a pas ou qui
    /// l'a déjà. La feuille d'édition ne s'en sert pas : elle passe par le brouillon (`ModeDraft.resetInstructionToOrigin`).
    public func resetInstruction(_ id: String) {
        guard let mode = current(id), ModeDefaults.instruction(for: id) != nil, mode.instruction != nil else { return }
        commit { settings in
            guard let index = settings.modes.firstIndex(where: { $0.id == id }) else { return }
            settings.modes[index].instruction = nil
        }
    }

    public func setStrongModel(_ choice: ModelChoice?) {
        settings = read()
        guard settings.strongModel != choice else { return }
        commit { $0.strongModel = choice }
    }

    public func setFastModel(_ choice: ModelChoice?) {
        settings = read()
        guard settings.fastModel != choice else { return }
        commit { $0.fastModel = choice }
    }

    /// Le premier nom libre construit sur `stem` : `stem + first`, puis `stem + numbered(2)`, `stem + numbered(3)`… (sans tenir
    /// compte de la casse). Chaque nom reste dans la limite de `nameLimit` caractères : c'est le début de `stem` qui est rogné, pas
    /// la fin (« (copie 2) »).
    private func freeName(_ stem: String, first: String = "", numbered: (Int) -> String) -> String {
        func taken(_ name: String) -> Bool { settings.modes.contains { Self.sameName($0.name, name) } }
        func candidate(_ tail: String) -> String {
            String(stem.prefix(max(1, Self.nameLimit - tail.count))) + tail
        }
        if !taken(candidate(first)) { return candidate(first) }
        var number = 2
        while taken(candidate(numbered(number))) { number += 1 }
        return candidate(numbered(number))
    }

    /// Le nom d'une copie sans sa marque « (copie) » ou « (copie 2) » : la copie d'une copie ne les empile pas.
    private static func strippedOfCopyMark(_ name: String) -> String {
        guard let range = name.range(of: #"\s\(copie( \d+)?\)$"#, options: .regularExpression) else { return name }
        return String(name[..<range.lowerBound])
    }

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).compare(
            rhs.trimmingCharacters(in: .whitespacesAndNewlines), options: [.caseInsensitive]) == .orderedSame
    }

    // MARK: - Raccourci d'un mode

    /// Rend les raccourcis au système et pose le moniteur de touches ; la prochaine combinaison tapée devient le raccourci de
    /// ce mode. Une capture déjà en cours passe à ce mode, sans rendre les raccourcis entre-temps.
    public func startRecording(for id: String) {
        guard current(id) != nil, recordingModeID != id else { return }
        let wasRecording = recordingModeID != nil
        recordingModeID = id
        guard !wasRecording else { return }
        hotKeys.suspend()
        keyMonitor.start { [weak self] keyCode, flags in self?.keyDown(keyCode: keyCode, flags: flags) }
    }

    /// Fin de capture sans nouveau raccourci (Échap, onglet changé, fenêtre quittée, feuille fermée) : le moniteur est retiré et
    /// les raccourcis reviennent.
    public func cancelRecording() {
        guard recordingModeID != nil else { return }
        endRecording()
        resumeAfterCapture()
    }

    private func endRecording() {
        recordingModeID = nil
        keyMonitor.stop()
    }

    /// Si le système refuse de rétablir le raccourci général, plus rien ne l'ouvre : il faut le dire. Un mode que le système
    /// refuse à son tour le dit dans le panneau (le contrôleur s'en charge).
    private func resumeAfterCapture() {
        guard !hotKeys.resume() else { return }
        message = Self.resumeFailure(label: hotKeys.global().map { $0.label(layout: layout) } ?? "")
    }

    /// Une touche pressée pendant la capture. Échap seul annule ; toute autre combinaison est proposée au mode capté.
    public func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard let id = recordingModeID else { return }
        let candidate = HotKeySettingsModel.hotKey(keyCode: keyCode, flags: flags)
        if candidate.keyCode == UInt32(kVK_Escape), candidate.modifiers.isEmpty {
            cancelRecording()
            return
        }
        record(candidate, for: id)
    }

    /// Propose `candidate` comme raccourci du mode et met fin à la capture. Dans l'ordre : la phrase de refus commune
    /// (`HotKeyConflicts`) avant le système ; le système ; l'enregistrement. Tout refus laisse l'ancien raccourci actif et dit
    /// pourquoi dans `message` ; si l'enregistrement est refusé, l'ancien est réappliqué, et s'il ne peut pas l'être, aucun
    /// raccourci ne reste actif plutôt qu'un raccourci absent du fichier.
    public func record(_ candidate: HotKey, for id: String) {
        let wasRecording = recordingModeID != nil
        if wasRecording { endRecording() }
        // Ce qu'une capture a suspendu est rendu à la fin, quel que soit le chemin.
        defer { if wasRecording { resumeAfterCapture() } }

        guard let mode = current(id) else { return }
        let label = candidate.label(layout: layout)
        var bindings: [String: HotKey] = [:]
        var names: [String: String] = [:]
        for other in settings.modes {
            names[other.id] = other.name
            if let hotKey = other.hotKey { bindings[other.id] = hotKey }
        }
        if let refusal = HotKeyConflicts.refusal(
            for: candidate, owner: .mode(id), global: hotKeys.global(), modes: bindings, names: names,
            systemEnabled: systemHotKeys.enabled(), layout: layout)
        {
            message = refusal
            return
        }
        switch hotKeys.apply(candidate, id) {
        case .failure(.refused):
            message = HotKeyConflicts.refusedBySystem(label: label)
        case .failure(.invalid(let validation)):
            message = HotKeyConflicts.refusal(validation, label: label)
        case .success:
            let previous = mode.hotKey
            if !commit({ settings in
                guard let index = settings.modes.firstIndex(where: { $0.id == id }) else { return }
                settings.modes[index].hotKey = candidate
            }) {
                restore(previous, for: id)
            }
        }
    }

    /// Retire le raccourci du mode, du système puis des réglages. Si l'enregistrement est refusé, le raccourci est remis.
    public func clearHotKey(for id: String) {
        guard let mode = current(id), let previous = mode.hotKey else { return }
        if case .failure = hotKeys.apply(nil, id) {
            message = Self.saveFailure
            return
        }
        let saved = commit { settings in
            guard let index = settings.modes.firstIndex(where: { $0.id == id }) else { return }
            settings.modes[index].hotKey = nil
        }
        if !saved { restore(previous, for: id) }
    }

    /// Après un enregistrement refusé : le système retrouve ce que les réglages portent encore. S'il ne le peut pas, il ne garde
    /// rien pour ce mode, et le message le dit.
    private func restore(_ previous: HotKey?, for id: String) {
        let reason = message ?? Self.saveFailure
        if case .failure = hotKeys.apply(previous, id) {
            _ = hotKeys.apply(nil, id)
            message = "\(reason) \(Self.noActiveHotKeyNote)"
        }
    }
}
