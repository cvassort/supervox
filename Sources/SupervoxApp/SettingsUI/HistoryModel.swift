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
    /// La durée n'a pas pu être enregistrée pour une autre raison qu'une `SettingsError` (dont la phrase est reprise telle quelle).
    public static let retentionSaveFailure = InterviewText.fr(
        "Ce changement n'a pas pu être enregistré : la durée de conservation reste celle d'avant.")

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
        didSet { if selection != oldValue { clearMessage() } }
    }
    public private(set) var message: String?
    /// Le message est un échec (icône d'erreur) ; faux pour « Copié. ».
    public private(set) var messageIsFailure = false
    /// La durée demandée qui attend la confirmation de la personne (elle supprimerait des entretiens), `nil` sinon.
    public private(set) var pendingRetention: Int?
    /// « Tout supprimer… » attend la confirmation de la personne.
    public private(set) var pendingDeleteAll = false

    /// Les réglages tels que `read` les a donnés la dernière fois.
    private var settings: AppSettings

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
        let listed = await history.list()
        let count = await history.fileCount()
        settings = read()
        records = listed
        fileCount = count
        isLoaded = true
        if let selection, listed.contains(where: { $0.id == selection }) { return }
        selection = listed.first?.id
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

    /// Supprime l'entretien choisi, sans confirmation : c'est un geste sur UNE ligne, que la personne vient de choisir. Le voisin
    /// est ensuite choisi. Refusé par le disque : la phrase fixe, et l'entretien reste.
    public func deleteSelected() async {
        guard let id = selection, let index = records.firstIndex(where: { $0.id == id }) else { return }
        var deleted = false
        do {
            try await history.delete(id)
            clearMessage()
            deleted = true
        } catch {
            say(Self.writeFailure, failure: true)
        }
        await reload()
        if deleted, !records.isEmpty { selection = records[min(index, records.count - 1)].id }
    }

    /// « Tout supprimer… » : relit le disque pour compter ce qui sera réellement supprimé, puis attend la confirmation. Sans aucun
    /// fichier, ne demande rien.
    public func requestDeleteAll() async {
        await reload()
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
        do {
            try await history.deleteAll()
            clearMessage()
        } catch {
            say(Self.writeFailure, failure: true)
        }
        await reload()
    }

    // MARK: - Durée de conservation

    /// La durée en vigueur, en jours, telle que les réglages la bornent.
    public var retentionDays: Int { settings.history.normalized.retentionDays }

    /// Les durées proposées, dans l'ordre : celles du brief, plus la durée en vigueur si elle n'en fait pas partie (un réglage écrit à
    /// la main), pour que la sélection s'affiche.
    public var retentionChoices: [(days: Int, label: String)] {
        let days = Set(HistorySettings.choices + [retentionDays]).sorted()
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

    /// La personne choisit une durée. La même que l'actuelle : rien. Une durée qui supprimerait des entretiens : elle attend la
    /// confirmation (`pendingRetention`) et rien n'est fait. Sinon (durée plus longue, ou qui ne supprime rien) : écrite tout de
    /// suite. Rend la tâche de purge qui suit une écriture réussie (les tests l'attendent), `nil` sinon.
    @discardableResult
    public func requestRetention(_ days: Int) -> Task<Void, Never>? {
        let wanted = HistorySettings(retentionDays: days).normalized.retentionDays
        pendingRetention = nil
        guard wanted != retentionDays else { return nil }
        if expiredCount(under: wanted) > 0 {
            pendingRetention = wanted
            return nil
        }
        return applyRetention(wanted)
    }

    public func cancelRetention() {
        pendingRetention = nil
    }

    /// Confirme la durée en attente : écrit le réglage D'ABORD (refusé : la phrase, aucune purge), puis supprime ce qui est échu.
    /// Sans demande en attente, ne fait rien.
    @discardableResult
    public func confirmRetention() -> Task<Void, Never>? {
        guard let days = pendingRetention else { return nil }
        pendingRetention = nil
        return applyRetention(days)
    }

    private func applyRetention(_ days: Int) -> Task<Void, Never>? {
        do {
            try update { $0.history.retentionDays = days }
            clearMessage()
            settings = read()
        } catch {
            say((error as? SettingsError)?.errorDescription ?? Self.retentionSaveFailure, failure: true)
            settings = read()
            return nil
        }
        // La purge lit la durée en vigueur à l'instant où elle s'exécute : celle qui vient d'être écrite.
        let history = history
        return Task { [weak self] in
            _ = await history.purge()
            await self?.reload()
        }
    }
}
