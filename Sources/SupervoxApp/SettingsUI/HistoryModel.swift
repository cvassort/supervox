import Foundation
import Observation
import SupervoxCore

/// L'onglet Historique : retrouver un entretien gardé, copier son prompt ou sa conversation, le supprimer, régler la durée de
/// conservation.
///
/// Les entretiens vivent sur le disque (`InterviewHistory`) ; le modèle en garde la dernière lecture (`records`), relue par
/// `reload()` (à chaque présentation de la fenêtre et à chaque affichage de l'onglet). La durée vit dans `AppSettings.history` : `read`
/// la donne, `update` l'écrit (en production, `AppController.updateSettings`) ; le modèle n'en garde aucune copie à réécrire.
///
/// Rien de destructif sans confirmation, et la confirmation vit ICI (pas seulement dans un dialogue) : `deleteAll()` ne fait rien
/// si `requestDeleteAll()` ne l'a pas précédé, `confirmRetention()` ne fait rien sans `requestRetention(_:)`. Les comptes annoncés
/// sont ceux de ce qui sera réellement supprimé : pour une durée, la règle d'âge de `InterviewHistory.isExpired` (la même que
/// `purge`) ; pour « Tout supprimer », les fichiers `.json` du dossier, illisibles compris.
///
/// Les phrases sont fixes : jamais le texte d'une erreur (il peut porter un chemin ou une adresse), jamais un texte d'entretien en
/// dehors de la liste et du détail que la personne ouvre elle-même.
@MainActor @Observable
public final class HistoryModel {
    public typealias Update = @MainActor ((inout AppSettings) -> Void) throws -> Void

    // MARK: - Textes

    // Chaque phrase passe par `InterviewText.fr` : espaces insécables du français avant « : ; ? ! » et dans « « » ».

    /// L'en-tête, mot pour mot celui du brief.
    public static let header = InterviewText.fr(
        "Chaque entretien conclu est gardé ici en texte : le prompt rédigé et la conversation. Ils restent sur cet ordinateur, ne sont envoyés nulle part, et l'audio n'est jamais gardé. Un entretien annulé par Échap n'est pas gardé."
    )
    public static let empty = InterviewText.fr("Aucun entretien gardé pour l'instant.")
    public static let noPromptTitle = InterviewText.fr("Conversation sans prompt (la rédaction avait échoué)")
    public static let promptTitle = "Prompt"
    public static let conversationTitle = "Conversation"
    public static let copyPromptTitle = "Copier le prompt"
    public static let copyConversationTitle = "Copier la conversation"
    public static let deleteTitle = "Supprimer"
    public static let deleteAllTitle = "Tout supprimer…"
    public static let retentionTitle = "Garder les entretiens"
    public static let copied = "Copié."
    public static let copyFailure = InterviewText.fr("Le texte n'a pas pu être copié : réessayez.")
    /// Écriture ou suppression refusée par le disque.
    public static let writeFailure = InterviewText.fr(
        "L'historique n'a pas pu être modifié : vérifiez l'espace libre sur le disque, puis réessayez.")
    /// Les réglages n'ont pas pu être écrits APRÈS que la durée a été notée dans le dossier (autre cause qu'une `SettingsError`, dont la
    /// phrase est reprise telle quelle). « La durée reste celle d'avant » serait faux : le dossier a noté la nouvelle (avec « Ne rien
    /// garder », plus rien n'est écrit) ; la purge au lancement, elle, ne partira pas tant que la durée n'est pas confirmée de nouveau.
    public static let retentionNotedButNotSavedFailure = InterviewText.fr(
        "La durée a été notée dans l'historique, les réglages n'ont pas pu être enregistrés : rien ne sera supprimé automatiquement tant que vous ne l'aurez pas confirmée de nouveau."
    )

    /// Une ligne sous l'en-tête quand la durée est « Ne rien garder » : l'en-tête, lui, dit « chaque entretien conclu est gardé ici ».
    public static let keepsNothingNote = InterviewText.fr("Avec « Ne rien garder », aucun entretien n'est gardé.")

    /// Le nom d'une durée : « Ne rien garder », « 1 jour », « 7 jours », « 1 an », « 2 ans ». Les cinq choix du brief s'écrivent
    /// « Ne rien garder », « 7 jours », « 30 jours », « 90 jours » et « 1 an ».
    static func label(forDays days: Int) -> String {
        if days == 0 { return "Ne rien garder" }
        if days % 365 == 0 { return days == 365 ? "1 an" : "\(days / 365) ans" }
        return days == 1 ? "1 jour" : "\(days) jours"
    }

    // MARK: - Lignes

    /// Une ligne de la liste : la date et l'heure (format court, langue du système) puis la première ligne du prompt.
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: UUID
        public var dateText: String
        public var title: String
    }

    // MARK: - État

    /// La dernière lecture du disque, du plus récent au plus ancien.
    public private(set) var records: [InterviewRecord] = []
    /// Le nombre de fichiers `.json` du dossier à la dernière lecture : ce que « Tout supprimer… » supprimera (illisibles compris).
    public private(set) var fileCount = 0
    /// La première lecture a eu lieu : avant elle, la liste vide ne veut pas dire « aucun entretien ».
    public private(set) var isLoaded = false
    /// L'entretien dont le détail est montré. Changer de sélection efface le message.
    public var selection: UUID? {
        didSet {
            guard selection != oldValue else { return }
            clearMessage()
            // Une demande de suppression ne survit pas à un changement de sélection : elle viserait un autre entretien.
            if pendingDelete != nil, pendingDelete != selection { pendingDelete = nil }
        }
    }
    public private(set) var message: String?
    /// Le message est un échec (icône d'erreur) ; faux pour « Copié. ».
    public private(set) var messageIsFailure = false
    /// La durée demandée qui attend la confirmation de la personne (elle supprimerait des entretiens), `nil` sinon.
    public private(set) var pendingRetention: Int?
    /// « Tout supprimer… » attend la confirmation de la personne.
    public private(set) var pendingDeleteAll = false
    /// L'entretien dont la suppression attend la confirmation de la personne (visé au moment de la demande), `nil` sinon.
    public private(set) var pendingDelete: UUID?

    /// Les réglages tels que `read` les a donnés la dernière fois.
    private var settings: AppSettings

    @ObservationIgnored private var reloadOrder = ReloadOrder()
    @ObservationIgnored private let history: InterviewHistory
    @ObservationIgnored private let read: @MainActor () -> AppSettings
    @ObservationIgnored private let update: Update
    @ObservationIgnored private let copy: @MainActor (String) -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let timeZone: TimeZone

    /// - Parameters:
    ///   - copy: met un texte dans le presse-papiers et dit si le système l'a accepté (en production, le relais `onCopy` du
    ///     panneau : l'insertion tient le presse-papiers).
    ///   - now: l'horloge du compte annoncé avant une suppression par la durée.
    ///   - locale: la langue du format de la date d'une ligne ; `timeZone` : son fuseau.
    public init(
        history: InterviewHistory, read: @escaping @MainActor () -> AppSettings, update: @escaping Update,
        copy: @escaping @MainActor (String) -> Bool, now: @escaping @Sendable () -> Date = Date.init,
        locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent
    ) {
        self.history = history
        self.read = read
        self.update = update
        self.copy = copy
        self.now = now
        self.locale = locale
        self.timeZone = timeZone
        settings = read()
    }

    // MARK: - Lecture

    /// Relit le disque et les réglages. Le message reste (il dit ce qui vient de se passer) ; `clearMessage()` l'efface. La
    /// sélection reste si l'entretien existe encore, sinon le plus récent est choisi (aucun s'il n'y en a pas).
    public func reload() async {
        let ticket = reloadOrder.begin()
        let snapshot = await history.snapshot()
        // Une relecture plus récente a déjà rendu son résultat : celui-ci est périmé.
        guard reloadOrder.accept(ticket) else { return }
        let firstLoad = !isLoaded
        settings = read()
        records = snapshot.records
        fileCount = snapshot.fileCount
        confirmedRetention = snapshot.confirmedRetention
        isLoaded = true
        if let selection, snapshot.records.contains(where: { $0.id == selection }) { return }
        // Le plus récent n'est choisi d'office qu'à la première lecture. Après, une sélection disparue (supprimée, purgée) ne devient
        // PAS un autre entretien : un clic de plus sur « Supprimer » ne doit jamais viser celui qui prend sa place.
        selection = firstLoad ? snapshot.records.first?.id : nil
    }

    public func clearMessage() {
        message = nil
        messageIsFailure = false
    }

    private func say(_ text: String, failure: Bool) {
        message = text
        messageIsFailure = failure
    }

    // MARK: - Ce que l'onglet montre

    public var rows: [Row] {
        let style = Date.FormatStyle(date: .numeric, time: .shortened, locale: locale, timeZone: timeZone)
        return records.map { Row(id: $0.id, dateText: $0.date.formatted(style), title: Self.title(of: $0)) }
    }

    /// La première ligne non vide du prompt, ou la phrase des entretiens sans prompt.
    static func title(of record: InterviewRecord) -> String {
        guard let prompt = Self.nonBlank(record.prompt),
            let first = prompt.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return noPromptTitle }
        return first.trimmingCharacters(in: .whitespaces)
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    /// La ligne de l'entretien choisi (sa date, son titre), `nil` sans sélection.
    public var selectedRow: Row? {
        guard let selection else { return nil }
        return rows.first { $0.id == selection }
    }

    public var selectedRecord: InterviewRecord? {
        guard let selection else { return nil }
        return records.first { $0.id == selection }
    }

    /// Le prompt de l'entretien choisi ; `nil` sans prompt (absent ou blanc).
    public var promptText: String? { Self.nonBlank(selectedRecord?.prompt) }

    /// La conversation de l'entretien choisi, comme la relecture la montre (« Vous : », « Supervox : »).
    public var conversationText: String { selectedRecord?.conversation.transcript ?? "" }

    public var canCopyPrompt: Bool { promptText != nil }

    public var canCopyConversation: Bool { Self.nonBlank(conversationText) != nil }

    /// La ligne de durée (dans le pied, au-dessus du sélecteur, avec son bouton) quand la durée confirmée du dossier n'est plus celle des réglages : les réglages ont changé hors de
    /// l'onglet (remis à zéro, fichier mis de côté, édité à la main), et la purge au lancement ne supprime rien tant que la personne
    /// n'a pas choisi la durée de nouveau.
    public static let retentionChangedNote = InterviewText.fr(
        "La durée de conservation a changé hors de cet onglet : rien ne sera supprimé automatiquement tant que vous ne l'aurez pas choisie de nouveau ci-dessous."
    )

    /// La ligne quand « Ne rien garder » a été confirmé dans l'onglet mais que les réglages disent autre chose (remis à zéro, fichier mis de
    /// côté, édité à la main) : `save` n'écrit rien tant que le dossier garde ce choix, la personne doit le savoir.
    public static let keptNothingAfterResetNote = InterviewText.fr(
        "Vous aviez choisi « Ne rien garder » : rien n'est gardé tant que vous n'aurez pas choisi une durée de nouveau ci-dessous.")

    /// Garde-t-on quelque chose ? La même réponse que `save` (`InterviewHistory.keepsNothing`).
    public var keepsNothing: Bool { InterviewHistory.keepsNothing(settingsDays: retentionDays, confirmed: confirmedRetention) }

    /// Le libellé du bouton, à côté de la ligne de durée : « Confirmer « 30 jours » » (il nomme la durée des RÉGLAGES ; pendant
    /// l'application d'une durée, le sélecteur montre la durée demandée, mais la ligne et le bouton n'existent alors pas). `nil` sans
    /// ligne de durée. Ne pas compter sur le sélecteur pour rechoisir la valeur déjà affichée : on ne sait
    /// pas si SwiftUI appelle alors son setter ; ce bouton passe par le même chemin, sans dépendre de lui.
    public var confirmRetentionButtonTitle: String? {
        retentionNote == nil ? nil : InterviewText.fr("Confirmer « \(Self.label(forDays: retentionDays)) »")
    }

    /// Confirme la durée des réglages par le MÊME chemin que le sélecteur (`requestRetention`) : la feuille de confirmation s'il y a des
    /// entretiens échus, sinon l'écriture de la durée confirmée.
    @discardableResult
    public func confirmShownRetention() async -> Task<Void, Never>? {
        await requestRetention(retentionDays)
    }

    /// La durée confirmée du dossier à la dernière lecture.
    public private(set) var confirmedRetention: InterviewHistory.ConfirmedRetention = .absent

    /// `retentionChangedNote` quand la durée confirmée existe et diffère de celle des réglages, ou ne se lit pas ; `nil` sinon
    /// (aucune durée confirmée : la durée des réglages est celle par défaut annoncée ; ou accord).
    public var retentionNote: String? {
        switch confirmedRetention {
        case .absent: nil
        case .unreadable: Self.retentionChangedNote
        case .days(0) where retentionDays != 0: Self.keptNothingAfterResetNote
        case .days(let days): days == retentionDays ? nil : Self.retentionChangedNote
        }
    }

    /// La ligne qui corrige l'en-tête quand la durée est « Ne rien garder » ; `nil` sinon.
    public var headerNote: String? {
        keepsNothing && retentionNote != Self.keptNothingAfterResetNote ? Self.keepsNothingNote : nil
    }

    /// Les fichiers que la liste ne montre pas (abîmés, d'une forme inconnue) : dits, pour qu'aucune donnée ne reste cachée.
    public var unreadableCount: Int { max(0, fileCount - records.count) }

    public var unreadableNote: String? {
        let count = unreadableCount
        guard count > 0 else { return nil }
        return InterviewText.fr(
            count == 1
                ? "1 fichier de l'historique n'a pas pu être lu : il n'apparaît pas dans la liste, et « Tout supprimer… » le supprime aussi."
                : "\(count) fichiers de l'historique n'ont pas pu être lus : ils n'apparaissent pas dans la liste, et « Tout supprimer… » les supprime aussi."
        )
    }

    // MARK: - Copier

    /// Copie le prompt de l'entretien choisi. Sans prompt, ne fait rien.
    public func copyPrompt() {
        guard let prompt = promptText else { return }
        copyText(prompt)
    }

    /// Copie la conversation de l'entretien choisi.
    public func copyConversation() {
        guard canCopyConversation else { return }
        copyText(conversationText)
    }

    private func copyText(_ text: String) {
        if copy(text) {
            say(Self.copied, failure: false)
        } else {
            say(Self.copyFailure, failure: true)
        }
    }

    // MARK: - Supprimer

    /// La personne demande la suppression de l'entretien choisi : rien n'est supprimé, la confirmation attend. Sans entretien choisi,
    /// ne demande rien. Deux demandes de suite visent le même entretien, et une suppression faite ne laisse aucune sélection : un
    /// double clic ne peut jamais supprimer deux entretiens.
    public func requestDeleteSelected() {
        // Une seule confirmation à la fois : celle qui attend déjà garde la main (sa phrase ne change pas sous le pointeur).
        guard confirmation == nil || confirmation == .deleteSelected else { return }
        guard let id = selection, records.contains(where: { $0.id == id }) else { return }
        pendingDelete = id
    }

    public func cancelDelete() {
        pendingDelete = nil
    }

    /// « Supprimer cet entretien ? C'est définitif. »
    public var deleteSelectedConfirmation: String? {
        pendingDelete == nil ? nil : InterviewText.fr("Supprimer cet entretien ? C'est définitif.")
    }

    /// Supprime l'entretien visé par la demande, seulement après `requestDeleteSelected()`. Aucun entretien n'est ensuite choisi.
    /// Refusé par le disque : la phrase fixe, l'entretien reste, et reste choisi.
    public func deleteSelected() async {
        guard let id = pendingDelete else { return }
        pendingDelete = nil
        var deleted = false
        var failed = false
        do {
            try await history.delete(id)
            clearMessage()
            deleted = true
        } catch {
            failed = true
        }
        await reload()
        if deleted { selection = nil }
        if failed { say(Self.writeFailure, failure: true) }
    }

    /// « Tout supprimer… » : relit le disque pour compter ce qui sera réellement supprimé, puis attend la confirmation. Sans aucun
    /// fichier, ne demande rien.
    public func requestDeleteAll() async {
        await reload()
        // Une confirmation arrivée pendant la relecture garde la main.
        guard confirmation == nil || confirmation == .deleteAll else { return }
        pendingDeleteAll = fileCount > 0
    }

    public func cancelDeleteAll() {
        pendingDeleteAll = false
    }

    /// La confirmation de « Tout supprimer… » : « Supprimer les n entretiens gardés ? C'est définitif. »
    public var deleteAllConfirmation: String? {
        guard pendingDeleteAll else { return nil }
        return InterviewText.fr(
            fileCount == 1
                ? "Supprimer l'entretien gardé ? C'est définitif." : "Supprimer les \(fileCount) entretiens gardés ? C'est définitif.")
    }

    /// Supprime tout, seulement après `requestDeleteAll()`. Sans demande (ou après annulation), ne fait rien.
    public func deleteAll() async {
        guard pendingDeleteAll else { return }
        pendingDeleteAll = false
        var failed = false
        do {
            try await history.deleteAll()
            clearMessage()
        } catch {
            failed = true
        }
        await reload()
        // Après la relecture : un échec partiel fait partir l'entretien choisi, la sélection change, et ce changement efface le message.
        if failed { say(Self.writeFailure, failure: true) }
    }

    // MARK: - Une seule confirmation à la fois

    /// Laquelle des trois confirmations attend la personne (une seule feuille les montre).
    public enum Confirmation: Equatable, Sendable { case retention, deleteSelected, deleteAll }

    public var confirmation: Confirmation? {
        if pendingRetention != nil { return .retention }
        if pendingDelete != nil { return .deleteSelected }
        if pendingDeleteAll { return .deleteAll }
        return nil
    }

    /// La phrase de la confirmation en attente.
    public var confirmationText: String? {
        switch confirmation {
        case .retention: retentionConfirmation
        case .deleteSelected: deleteSelectedConfirmation
        case .deleteAll: deleteAllConfirmation
        case nil: nil
        }
    }

    /// Le bouton qui confirme : « Supprimer », ou « Tout supprimer ».
    public var confirmationButtonTitle: String? {
        switch confirmation {
        case .retention, .deleteSelected: Self.deleteTitle
        case .deleteAll: "Tout supprimer"
        case nil: nil
        }
    }

    public func cancelConfirmation() {
        clearPendingRetention()
        pendingDelete = nil
        pendingDeleteAll = false
    }

    /// Exécute la confirmation en attente ; sans elle, ne fait rien.
    public func confirm() async {
        switch confirmation {
        case .retention: _ = confirmRetention()
        case .deleteSelected: await deleteSelected()
        case .deleteAll: await deleteAll()
        case nil: break
        }
    }

    // MARK: - Durée de conservation

    /// La durée en vigueur, en jours, telle que les réglages la bornent.
    public var retentionDays: Int { settings.history.normalized.retentionDays }

    /// La durée que le sélecteur montre : celle que la personne vient de demander, DÈS la demande (avant la relecture du disque), puis
    /// pendant la feuille de confirmation, l'écriture de la durée confirmée, celle des réglages et la purge : le sélecteur ne clignote
    /// pas. Sinon, celle des réglages. Elle y revient quand la demande finit sans écriture (même durée, feuille annulée, autre
    /// confirmation en cours, échec).
    public var shownRetention: Int { inFlightRetention ?? retentionDays }

    /// La durée demandée, montrée par le sélecteur (`nil` : celle des réglages). Un seul champ pour la demande en cours de relecture,
    /// la feuille ouverte et l'application.
    private var inFlightRetention: Int?
    /// Combien d'applications (`applyRetention`) sont en cours : un retour à l'ancienne durée demandé pendant l'une d'elles n'est pas
    /// abandonné parce que le disque dit encore l'ancienne.
    private var applyingCount = 0

    /// La demande de `days` finit sans écriture : le sélecteur ne la montre plus (sauf si une autre demande l'a remplacée).
    private func dropShown(_ days: Int) {
        if inFlightRetention == days { inFlightRetention = nil }
    }

    /// Les durées proposées, dans l'ordre : celles du brief, plus la durée en vigueur si elle n'en fait pas partie (un réglage écrit à
    /// la main), pour que la sélection s'affiche.
    public var retentionChoices: [(days: Int, label: String)] {
        let days = Set(HistorySettings.choices + [shownRetention]).sorted()
        return days.map { (days: $0, label: Self.label(forDays: $0)) }
    }

    /// Les entretiens que la durée demandée supprimerait maintenant, selon la dernière lecture et la règle d'âge de `purge`.
    public var pendingRetentionCount: Int {
        guard let pendingRetention else { return 0 }
        return expiredCount(under: pendingRetention)
    }

    private func expiredCount(under days: Int) -> Int {
        let moment = now()
        return records.filter { InterviewHistory.isExpired($0.date, now: moment, retentionDays: days) }.count
    }

    /// La confirmation d'une durée plus courte qui supprime : « n entretiens plus anciens seront supprimés maintenant. » (au
    /// singulier : « 1 entretien plus ancien sera supprimé maintenant. »). « Ne rien garder » supprime tous les entretiens : la
    /// phrase le dit (« plus anciens » serait faux).
    public var retentionConfirmation: String? {
        guard let pendingRetention else { return nil }
        let count = pendingRetentionCount
        if pendingRetention == 0 {
            return InterviewText.fr(
                count == 1 ? "L'entretien gardé sera supprimé maintenant." : "Les \(count) entretiens gardés seront supprimés maintenant.")
        }
        return InterviewText.fr(
            count == 1
                ? "1 entretien plus ancien sera supprimé maintenant." : "\(count) entretiens plus anciens seront supprimés maintenant.")
    }

    /// La personne choisit une durée. Le disque est RELU d'abord (comme pour « Tout supprimer… ») : le compte est celui du disque à cet
    /// instant, jamais celui d'un instantané vide ou périmé. La même durée que l'actuelle : rien. Une durée qui supprimerait au moins
    /// un entretien : elle attend la confirmation (`pendingRetention`) et rien n'est fait, sur un modèle neuf comme sur un instantané
    /// ancien. Sinon (durée plus longue, ou qui ne supprime rien) : écrite tout de suite. Rend la tâche de purge qui suit une écriture
    /// réussie (les tests l'attendent), `nil` sinon.
    @discardableResult
    public func requestRetention(_ days: Int) async -> Task<Void, Never>? {
        let wanted = HistorySettings(retentionDays: days).normalized.retentionDays
        clearPendingRetention()
        // Le sélecteur montre la durée demandée tout de suite, pas après la relecture.
        inFlightRetention = wanted
        await reload()
        // Une autre confirmation (un entretien, tout) arrivée pendant la relecture garde la main : une seule feuille à la fois.
        guard confirmation == nil else {
            dropShown(wanted)
            return nil
        }
        // La même durée que celle des réglages ET déjà confirmée : rien à faire. Confirmée autrement (ou jamais) : le choix passe par
        // le chemin habituel, qui écrit la durée confirmée. Pendant qu'une application est en cours, le disque peut encore dire
        // l'ancienne durée : un retour à elle (7 puis 30) n'est pas abandonné pour autant.
        guard applyingCount > 0 || wanted != retentionDays || confirmedRetention != .days(wanted) else {
            dropShown(wanted)
            return nil
        }
        if expiredCount(under: wanted) > 0 {
            pendingRetention = wanted  // la durée demandée reste montrée tant que la feuille est ouverte
            return nil
        }
        return applyRetention(wanted)
    }

    public func cancelRetention() {
        clearPendingRetention()
    }

    /// Abandonne la demande de durée qui attend sa feuille : le sélecteur revient à la durée des réglages.
    private func clearPendingRetention() {
        guard let pending = pendingRetention else { return }
        pendingRetention = nil
        dropShown(pending)
    }

    /// Confirme la durée en attente : la durée confirmée du dossier d'abord, puis les réglages, puis la purge (voir `applyRetention`).
    /// Sans demande en attente, ne fait rien.
    @discardableResult
    public func confirmRetention() -> Task<Void, Never>? {
        guard let days = pendingRetention else { return nil }
        pendingRetention = nil
        return applyRetention(days)
    }

    /// Applique une durée, dans la tâche rendue, en TROIS écritures dans cet ordre :
    /// 1. la durée CONFIRMÉE du dossier (`conservation`) ;
    /// 2. les réglages (sauf s'ils disent déjà cette durée) ;
    /// 3. la purge, qui lit la durée des réglages à l'instant où elle s'exécute : celle qui vient d'être écrite.
    ///
    /// Pourquoi cet ordre : la purge du lancement ne part que si le dossier ne contredit pas les réglages. Écrire les réglages d'abord
    /// laissait, si le fichier n'était pas écrit (échec, arrêt entre les deux), des réglages à 365 jours SANS la durée confirmée : une
    /// remise à zéro des réglages faisait ensuite purger à 30 jours, sans que le dossier s'y oppose. Dans l'ordre retenu :
    /// - (1) échoue : la phrase d'échec d'écriture ; les réglages ne sont PAS touchés, rien n'est purgé ; rien n'a changé ;
    /// - (2) échoue après (1) : la phrase de l'échec des réglages, rien n'est purgé. Le dossier est EN AVANCE sur les réglages : les
    ///   lancements suivants ne purgent pas (la durée confirmée diffère de celle des réglages) et la ligne « a changé hors de cet
    ///   onglet » s'affiche. C'est l'état prudent voulu ; son coût : jusqu'à ce que la personne choisisse la durée de nouveau, plus
    ///   aucune purge automatique, même à la durée qu'elle veut ;
    /// - un arrêt de l'application entre (1) et (2) donne le même état, sans message.
    ///
    /// Le fichier absent (jamais confirmé) fait purger à la durée des réglages au lancement : c'est la durée par défaut annoncée.
    @discardableResult
    private func applyRetention(_ days: Int) -> Task<Void, Never> {
        inFlightRetention = days
        applyingCount += 1
        let history = history
        // La tâche tient le modèle (fini : elle ne dure que le temps des écritures) : fermer la fenêtre en pleine écriture n'abandonne pas
        // les trois étapes à mi-chemin.
        return Task {
            // (1) La durée confirmée du dossier.
            do {
                try await history.confirmRetention(days)
            } catch {
                await abandonRetention(days, saying: Self.writeFailure)
                return
            }
            // (2) Les réglages, sauf s'ils disent déjà cette durée.
            if read().history.normalized.retentionDays != days {
                do {
                    try update { $0.history.retentionDays = days }
                } catch {
                    // Le dossier a déjà noté `days` : la phrase ne dit pas que la durée reste celle d'avant.
                    await abandonRetention(
                        days, saying: (error as? SettingsError)?.errorDescription ?? Self.retentionNotedButNotSavedFailure)
                    return
                }
            }
            clearMessage()
            settings = read()
            // Le modèle vient d'écrire la durée confirmée ET les réglages : il sait ce que le dossier dit, sans attendre la relecture.
            // Pendant la purge et l'instantané, la ligne « a changé hors de cet onglet » et son bouton seraient faux (le changement vient
            // de l'onglet), et « Ne rien garder » (0 → 30) contredirait `save`.
            confirmedRetention = .days(days)
            endApplying(days)
            // (3) La purge lit la durée des réglages à l'instant où elle s'exécute.
            _ = await history.purge()
            await reload()
        }
    }

    /// Fin de l'application de `days` : le sélecteur ne la montre plus, sauf si une autre demande l'a remplacée entre-temps.
    private func endApplying(_ days: Int) {
        applyingCount -= 1
        dropShown(days)
    }

    /// Une écriture de la durée a échoué : la durée affichée redevient celle des réglages, le disque est relu, PUIS la phrase est posée
    /// (la relecture peut changer la sélection, ce qui efface un message posé avant).
    private func abandonRetention(_ days: Int, saying sentence: String) async {
        endApplying(days)
        settings = read()
        await reload()
        say(sentence, failure: true)
    }
}

/// L'ordre des relectures du disque : une relecture lente ne doit pas écraser le résultat d'une plus récente (celle d'avant une
/// suppression, arrivée après elle, ferait réapparaître la ligne). Chaque relecture prend un numéro en partant ; son résultat n'est
/// appliqué que si aucun résultat plus récent ne l'a été avant. Un résultat plus ancien arrivé en premier est appliqué (il est
/// ensuite remplacé par le suivant) : la relecture qu'un geste attend ne reste jamais sans effet.
struct ReloadOrder {
    private var started = 0
    private var applied = 0

    mutating func begin() -> Int {
        started += 1
        return started
    }

    mutating func accept(_ ticket: Int) -> Bool {
        guard ticket > applied else { return false }
        applied = ticket
        return true
    }
}
