import Foundation
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Le modèle de l'onglet Historique, sur un VRAI `InterviewHistory` dans un dossier temporaire propre à chaque test. Les réglages
/// sont en mémoire (`update` peut lever sur ordre), la copie passe par un double (jamais le presse-papiers général), l'horloge est
/// injectée. La durée que lit le magasin est celle des réglages du banc, relue à chaque appel : comme `AppController`.
@MainActor @Suite(.timeLimit(.minutes(1))) struct HistoryModelTests {
    nonisolated static let now = InterviewHistoryTests.now

    /// Une erreur d'ailleurs, dont le texte porte une adresse et un chemin : il ne doit jamais arriver à l'écran.
    struct ForeignError: LocalizedError {
        var errorDescription: String? { "échec : https://api.example.com/v1 dans /tmp/secret-exemple" }
    }

    @MainActor final class Rig {
        let directory: URL
        var settings: AppSettings
        var updates = 0
        var failure: (any Error)?
        var copied: [String] = []
        var copyAccepts = true

        init(retention: Int = 30) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("supervox-history-model-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var settings = AppSettings.defaults
            settings.history.retentionDays = retention
            self.settings = settings
        }

        var root: URL { directory.appendingPathComponent("Historique", isDirectory: true) }

        /// La durée en vigueur, lue par le magasin à chaque appel (comme la fermeture de `AppController`). Les fermetures du banc
        /// tiennent le banc fortement (un cycle, voulu : une tâche d'un volet affiché peut relire après la fin du test).
        func retention() -> Int { settings.history.retentionDays }

        lazy var history = InterviewHistory(
            root: root, retentionDays: { await self.retention() }, now: { HistoryModelTests.now })

        func makeModel(locale: Locale = Locale(identifier: "fr_FR"), timeZone: TimeZone = .gmt) -> HistoryModel {
            HistoryModel(
                history: history, read: { self.settings },
                update: { change in
                    self.updates += 1
                    if let failure = self.failure { throw failure }
                    change(&self.settings)
                },
                copy: { text in
                    self.copied.append(text)
                    return self.copyAccepts
                },
                now: { HistoryModelTests.now }, locale: locale, timeZone: timeZone)
        }

        func seed(_ records: [InterviewRecord]) async throws {
            for record in records { try await history.save(record) }
        }

        func names() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        }

        func cleanUp() {
            chmod(root.path, 0o700)
            try? FileManager.default.removeItem(at: directory)
        }
    }

    static func record(_ n: Int, daysAgo: Double = 0, prompt: String? = "Écris un outil d'exemple.") -> InterviewRecord {
        InterviewHistoryTests.record(n, daysAgo: daysAgo, prompt: prompt)
    }

    /// Une tâche attendue au plus le temps de `until` : le test échoue au lieu de rester suspendu.
    func finish(_ task: Task<Void, Never>?, _ label: String = "") async throws {
        let task = try #require(task, "aucune tâche à attendre \(label)")
        #expect(await bounded(task) != nil, "la tâche ne finit pas \(label)")
    }

    // MARK: - Les lignes

    @Test("la liste va du plus récent au plus ancien ; l'état « chargé » n'est vrai qu'après la lecture")
    func theRowsAreNewestFirstAndLoadingIsReported() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(2, daysAgo: 5), Self.record(1, daysAgo: 1), Self.record(3, daysAgo: 9)])
        let model = rig.makeModel()
        #expect(!model.isLoaded)
        #expect(model.rows.isEmpty)

        await model.reload()

        #expect(model.isLoaded)
        #expect(model.rows.map(\.id) == [InterviewHistoryTests.id(1), InterviewHistoryTests.id(2), InterviewHistoryTests.id(3)])
        #expect(model.fileCount == 3)
    }

    @Test("une ligne porte la première ligne non vide du prompt ; sans prompt (ou prompt blanc), la phrase du brief")
    func aRowShowsTheFirstLineOfThePromptOrTheFixedSentence() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([
            Self.record(1, daysAgo: 1, prompt: "\n  \nRésume les courriels d'exemple en trois points.\nPuis ajoute une conclusion."),
            Self.record(2, daysAgo: 2, prompt: nil),
            Self.record(3, daysAgo: 3, prompt: "  \n \n"),
        ])
        let model = rig.makeModel()

        await model.reload()

        #expect(model.rows.map(\.title) == [
            "Résume les courriels d'exemple en trois points.",
            "Conversation sans prompt (la rédaction avait échoué)",
            "Conversation sans prompt (la rédaction avait échoué)",
        ])
    }

    @Test("la date d'une ligne est celle de l'entretien, dans le fuseau et la langue donnés (format court : jour numérique et heure)")
    func theRowDateFollowsTheTimeZoneAndTheLocale() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1), Self.record(2, daysAgo: 1)])

        // 12:00 UTC, en Inde (UTC+5:30) : 17:30. Un fuseau ignoré donnerait 12:00.
        let india = rig.makeModel(timeZone: TimeZone(identifier: "Asia/Kolkata")!)
        await india.reload()
        let today = try #require(india.rows.first).dateText
        #expect(today.contains("17:30"), "\(today)")
        #expect(today.contains("17/11/2026"), "\(today)")
        let utc = rig.makeModel()
        await utc.reload()
        #expect(try #require(utc.rows.first).dateText.contains("12:00"))
        #expect(try #require(utc.rows.last).dateText.contains("16/11/2026"), "la veille")
    }

    // MARK: - Sélection

    @Test("à la lecture, le plus récent est choisi ; une sélection disparue retombe sur le plus récent ; sans entretien, aucune")
    func theSelectionFollowsTheList() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let model = rig.makeModel()
        await model.reload()
        #expect(model.selection == nil)
        #expect(model.selectedRecord == nil)

        try await rig.seed([Self.record(1, daysAgo: 1), Self.record(2, daysAgo: 2)])
        await model.reload()
        #expect(model.selection == InterviewHistoryTests.id(1))
        #expect(model.selectedRow?.id == InterviewHistoryTests.id(1))
        #expect(model.selectedRow?.title == "Écris un outil d'exemple.")

        model.selection = InterviewHistoryTests.id(2)
        await model.reload()
        #expect(model.selection == InterviewHistoryTests.id(2), "une sélection valide reste")

        model.selection = InterviewHistoryTests.id(99)
        await model.reload()
        #expect(model.selection == InterviewHistoryTests.id(1), "une sélection disparue retombe sur le plus récent")
    }

    // MARK: - Copie (règle 4)

    @Test("règle 4 : Copier le prompt passe par le double avec le prompt exact ; « Copié. » n'est pas un échec")
    func copyingThePromptGoesThroughTheRelay() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1, prompt: "Le prompt d'exemple, sur\ndeux lignes.")])
        let model = rig.makeModel()
        await model.reload()

        model.copyPrompt()

        #expect(rig.copied == ["Le prompt d'exemple, sur\ndeux lignes."])
        #expect(model.message == "Copié.")
        #expect(!model.messageIsFailure)
    }

    @Test("règle 4 : Copier la conversation envoie la transcription (« Vous : » et « Supervox : », ligne vide entre les tours)")
    func copyingTheConversationSendsTheTranscript() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1)])
        let model = rig.makeModel()
        await model.reload()

        model.copyConversation()

        #expect(rig.copied == ["Supervox : Que voulez-vous construire ?\n\nVous : Un outil d'exemple."])
        #expect(model.conversationText == rig.copied.first)
        #expect(model.message == "Copié.")
    }

    @Test("règle 4 : une copie refusée par le système le dit par la phrase fixe, en échec")
    func aRefusedCopyIsSaid() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1)])
        rig.copyAccepts = false
        let model = rig.makeModel()
        await model.reload()

        model.copyPrompt()

        #expect(model.message == "Le texte n'a pas pu être copié\u{00A0}: réessayez.")
        #expect(model.messageIsFailure)
    }

    @Test("sans prompt (absent ou blanc), Copier le prompt est indisponible et ne copie rien ; la conversation reste copiable")
    func withoutAPromptThereIsNothingToCopy() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1, daysAgo: 1, prompt: nil), Self.record(2, daysAgo: 2, prompt: " \n ")])
        let model = rig.makeModel()
        await model.reload()

        for id in [InterviewHistoryTests.id(1), InterviewHistoryTests.id(2)] {
            model.selection = id
            #expect(!model.canCopyPrompt)
            #expect(model.promptText == nil)
            model.copyPrompt()
        }
        #expect(rig.copied.isEmpty)
        model.copyConversation()
        #expect(rig.copied.count == 1)
    }

    @Test("changer de sélection efface le message précédent ; clearMessage aussi")
    func aMessageDoesNotOutliveTheSelection() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1, daysAgo: 1), Self.record(2, daysAgo: 2)])
        let model = rig.makeModel()
        await model.reload()
        model.copyPrompt()
        #expect(model.message != nil)

        model.selection = InterviewHistoryTests.id(2)
        #expect(model.message == nil)

        model.copyPrompt()
        model.clearMessage()
        #expect(model.message == nil)
        #expect(!model.messageIsFailure)
    }

    // MARK: - Supprimer (règle 4)

    @Test("règle 4 : Supprimer retire le fichier et la ligne, et choisit le voisin ; les autres entretiens restent")
    func deletingTheSelectionRemovesTheFileAndTheRow() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let (first, second, third) = (Self.record(1, daysAgo: 1), Self.record(2, daysAgo: 2), Self.record(3, daysAgo: 3))
        try await rig.seed([first, second, third])
        let model = rig.makeModel()
        await model.reload()
        model.selection = second.id

        await model.deleteSelected()

        #expect(model.records.map(\.id) == [first.id, third.id])
        #expect(try rig.names() == [InterviewHistory.fileName(for: first), InterviewHistory.fileName(for: third)].sorted())
        #expect(model.selection == third.id, "le voisin suivant")

        model.selection = third.id
        await model.deleteSelected()
        #expect(model.selection == first.id, "le dernier supprimé : le précédent")
        await model.deleteSelected()
        #expect(model.records.isEmpty)
        #expect(model.selection == nil)
        #expect(try rig.names().isEmpty)
    }

    @Test("une suppression refusée par le disque le dit par la phrase fixe (sans chemin) et la ligne reste")
    func aRefusedDeletionIsSaidAndKeepsTheRow() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1)])
        let model = rig.makeModel()
        await model.reload()
        #expect(chmod(rig.root.path, 0o500) == 0)

        await model.deleteSelected()

        #expect(model.message == "L'historique n'a pas pu être modifié\u{00A0}: vérifiez l'espace libre sur le disque, puis réessayez.")
        #expect(model.messageIsFailure)
        #expect(model.records.count == 1, "l'entretien est toujours là")
        #expect(model.selection == InterviewHistoryTests.id(1))
    }

    // MARK: - Tout supprimer (règle 4)

    @Test("règle 4 : « Tout supprimer… » ne supprime rien sans confirmation : ni la demande, ni son annulation, ni deleteAll() seul")
    func deleteAllNeedsAConfirmation() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1), Self.record(2, daysAgo: 2)])
        let model = rig.makeModel()
        await model.reload()

        await model.deleteAll()
        #expect(try rig.names().count == 2, "deleteAll() sans demande ne fait rien")

        await model.requestDeleteAll()
        #expect(model.pendingDeleteAll)
        #expect(try rig.names().count == 2, "la demande ne supprime pas")

        model.cancelDeleteAll()
        #expect(!model.pendingDeleteAll)
        await model.deleteAll()
        #expect(try rig.names().count == 2, "après annulation, deleteAll() ne fait rien")

        await model.requestDeleteAll()
        await model.deleteAll()
        #expect(try rig.names().isEmpty)
        #expect(model.records.isEmpty)
        #expect(!model.pendingDeleteAll)
        #expect(model.message == nil)
    }

    @Test("la confirmation compte les fichiers réellement supprimés, illisibles compris ; singulier pour un seul")
    func theConfirmationCountsWhatWillReallyBeDeleted() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1), Self.record(2, daysAgo: 2)])
        try Data("pas du json".utf8).write(to: rig.root.appendingPathComponent("abîmé.json"))
        let model = rig.makeModel()
        await model.reload()
        #expect(model.records.count == 2)

        await model.requestDeleteAll()
        #expect(model.deleteAllConfirmation == "Supprimer les 3 entretiens gardés\u{00A0}? C'est définitif.")
        #expect(model.unreadableNote
            == "1 fichier de l'historique n'a pas pu être lu\u{00A0}: il n'apparaît pas dans la liste, et «\u{00A0}Tout supprimer…\u{00A0}» le supprime aussi.")
        await model.deleteAll()
        #expect(try rig.names().isEmpty, "l'illisible part aussi, comme annoncé")

        try await rig.seed([Self.record(5)])
        await model.reload()
        await model.requestDeleteAll()
        #expect(model.deleteAllConfirmation == "Supprimer l'entretien gardé\u{00A0}? C'est définitif.")
        #expect(model.unreadableNote == nil)
    }

    @Test("le pluriel de la note des fichiers illisibles")
    func theUnreadableNoteIsPlural() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try FileManager.default.createDirectory(at: rig.root, withIntermediateDirectories: true)
        for name in ["a.json", "b.json"] { try Data("x".utf8).write(to: rig.root.appendingPathComponent(name)) }
        let model = rig.makeModel()
        await model.reload()
        #expect(model.records.isEmpty)
        #expect(model.unreadableNote
            == "2 fichiers de l'historique n'ont pas pu être lus\u{00A0}: ils n'apparaissent pas dans la liste, et «\u{00A0}Tout supprimer…\u{00A0}» les supprime aussi.")
    }

    @Test("Tout supprimer sans aucun fichier ne demande rien")
    func deleteAllWithNothingToDeleteDoesNotAsk() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let model = rig.makeModel()
        await model.reload()
        await model.requestDeleteAll()
        #expect(!model.pendingDeleteAll)
        #expect(model.deleteAllConfirmation == nil)
    }

    @Test("un échec de « Tout supprimer » le dit par la phrase fixe")
    func aFailedDeleteAllIsSaid() async throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1)])
        let model = rig.makeModel()
        await model.reload()
        await model.requestDeleteAll()
        #expect(chmod(rig.root.path, 0o500) == 0)

        await model.deleteAll()

        #expect(model.message == HistoryModel.writeFailure)
        #expect(model.messageIsFailure)
        #expect(!model.pendingDeleteAll)
        #expect(model.records.count == 1)
    }

    // MARK: - Durée de conservation (règle 3)

    @Test("« Garder les entretiens » : les cinq choix du brief, dans l'ordre, et la durée courante")
    func theRetentionChoicesAreTheBriefsFive() throws {
        let rig = try Rig(retention: 30)
        defer { rig.cleanUp() }
        let model = rig.makeModel()

        #expect(model.retentionChoices.map(\.days) == HistorySettings.choices)
        #expect(model.retentionChoices.map(\.label) == ["Ne rien garder", "7 jours", "30 jours", "90 jours", "1 an"])
        #expect(model.retentionDays == 30)
    }

    @Test("une durée écrite à la main hors des choix est ajoutée à la liste, pour que la sélection s'affiche")
    func anUnusualRetentionIsListedToo() throws {
        let rig = try Rig(retention: 14)
        defer { rig.cleanUp() }
        let model = rig.makeModel()
        #expect(model.retentionChoices.map(\.days) == [0, 7, 14, 30, 90, 365])
        #expect(model.retentionChoices.first { $0.days == 14 }?.label == "14 jours")
    }

    @Test("règle 3 : une durée plus courte qui supprime demande confirmation, annonce le compte ; annuler ne change ni le réglage ni les fichiers")
    func aShorterRetentionAsksAndCancelChangesNothing() async throws {
        let rig = try Rig(retention: 365)
        defer { rig.cleanUp() }
        try await rig.seed([5, 20, 40, 100, 200].enumerated().map { Self.record($0.offset + 1, daysAgo: Double($0.element)) })
        let model = rig.makeModel()
        await model.reload()

        let task = model.requestRetention(30)

        #expect(task == nil, "rien n'est fait avant la confirmation")
        #expect(model.pendingRetention == 30)
        #expect(model.pendingRetentionCount == 3, "40, 100 et 200 jours dépassent 30 jours")
        #expect(model.retentionConfirmation == "3 entretiens plus anciens seront supprimés maintenant.")
        #expect(rig.updates == 0)

        model.cancelRetention()

        #expect(model.pendingRetention == nil)
        #expect(model.retentionDays == 365)
        #expect(rig.settings.history.retentionDays == 365)
        #expect(try rig.names().count == 5)
        #expect(rig.updates == 0)
    }

    @Test("règle 3 : confirmer écrit la durée PUIS purge : le nombre annoncé est le nombre supprimé, les récents restent")
    func confirmingWritesTheSettingThenPurgesExactlyWhatWasAnnounced() async throws {
        let rig = try Rig(retention: 365)
        defer { rig.cleanUp() }
        try await rig.seed([5, 20, 40, 100, 200].enumerated().map { Self.record($0.offset + 1, daysAgo: Double($0.element)) })
        let model = rig.makeModel()
        await model.reload()
        model.requestRetention(30)
        let announced = model.pendingRetentionCount
        let before = try rig.names().count

        try await finish(model.confirmRetention(), "de la confirmation")

        #expect(rig.settings.history.retentionDays == 30)
        #expect(model.retentionDays == 30)
        #expect(model.pendingRetention == nil)
        #expect(before - (try rig.names().count) == announced, "annoncé = supprimé")
        #expect(model.records.map(\.id) == [InterviewHistoryTests.id(1), InterviewHistoryTests.id(2)], "la liste est relue")
    }

    @Test("le singulier : « 1 entretien plus ancien sera supprimé maintenant. »")
    func theConfirmationIsSingularForOne() async throws {
        let rig = try Rig(retention: 365)
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1, daysAgo: 5), Self.record(2, daysAgo: 40)])
        let model = rig.makeModel()
        await model.reload()

        model.requestRetention(30)

        #expect(model.retentionConfirmation == "1 entretien plus ancien sera supprimé maintenant.")
    }

    @Test("« Ne rien garder » avec des entretiens : la confirmation dit qu'ils seront tous supprimés ; confirmer les supprime")
    func keepingNothingAsksAndDeletesEverything() async throws {
        let rig = try Rig(retention: 30)
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1, daysAgo: 1), Self.record(2, daysAgo: 2)])
        let model = rig.makeModel()
        await model.reload()

        model.requestRetention(0)
        #expect(model.retentionConfirmation == "Les 2 entretiens gardés seront supprimés maintenant.")
        try await finish(model.confirmRetention())

        #expect(rig.settings.history.retentionDays == 0)
        #expect(try rig.names().isEmpty)

        // Un seul entretien : le singulier.
        let single = try Rig(retention: 30)
        defer { single.cleanUp() }
        try await single.seed([Self.record(1)])
        let one = single.makeModel()
        await one.reload()
        one.requestRetention(0)
        #expect(one.retentionConfirmation == "L'entretien gardé sera supprimé maintenant.")
    }

    @Test("règle 3 : une durée plus longue ne demande rien : écrite tout de suite, rien n'est supprimé")
    func aLongerRetentionAsksNothing() async throws {
        let rig = try Rig(retention: 30)
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1, daysAgo: 5), Self.record(2, daysAgo: 20)])
        let model = rig.makeModel()
        await model.reload()

        try await finish(model.requestRetention(90), "du changement")

        #expect(model.pendingRetention == nil)
        #expect(rig.settings.history.retentionDays == 90)
        #expect(try rig.names().count == 2)
    }

    @Test("une durée plus courte qui ne supprime rien ne demande rien non plus")
    func aShorterRetentionThatDeletesNothingAsksNothing() async throws {
        let rig = try Rig(retention: 90)
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1, daysAgo: 2)])
        let model = rig.makeModel()
        await model.reload()

        try await finish(model.requestRetention(30))

        #expect(model.pendingRetention == nil)
        #expect(rig.settings.history.retentionDays == 30)
        #expect(try rig.names().count == 1)
    }

    @Test("choisir la durée déjà en vigueur ne fait rien ; confirmRetention() sans demande ne fait rien")
    func nothingHappensWithoutARealRequest() async throws {
        let rig = try Rig(retention: 30)
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1, daysAgo: 100)])
        let model = rig.makeModel()
        await model.reload()

        #expect(model.requestRetention(30) == nil)
        #expect(model.confirmRetention() == nil)

        #expect(rig.updates == 0)
        #expect(model.pendingRetention == nil)
        #expect(try rig.names().count == 1, "l'entretien de 100 jours n'est pas purgé par ces gestes")
    }

    @Test("règle 3 : un enregistrement de la durée refusé : phrase fixe, durée inchangée, AUCUNE purge")
    func aRefusedRetentionSaveDoesNotPurge() async throws {
        let rig = try Rig(retention: 365)
        defer { rig.cleanUp() }
        try await rig.seed([Self.record(1, daysAgo: 5), Self.record(2, daysAgo: 100)])
        let model = rig.makeModel()
        await model.reload()
        model.requestRetention(30)
        rig.failure = ForeignError()

        let task = model.confirmRetention()

        #expect(task == nil, "pas de purge")
        #expect(rig.updates == 1)
        #expect(model.message == HistoryModel.retentionSaveFailure)
        #expect(model.messageIsFailure)
        #expect(model.retentionDays == 365)
        #expect(model.pendingRetention == nil)
        #expect(try rig.names().count == 2, "rien n'est supprimé")
        #expect(!(model.message ?? "").contains("example.com"), "le texte d'une erreur d'ailleurs n'arrive jamais à l'écran")
        #expect(!(model.message ?? "").contains("/tmp"))
    }

    @Test("un refus de réglages connu (SettingsError) est dit avec sa phrase, jamais le texte d'une erreur inconnue")
    func aKnownSettingsRefusalKeepsItsSentence() async throws {
        let rig = try Rig(retention: 30)
        defer { rig.cleanUp() }
        let model = rig.makeModel()
        await model.reload()
        rig.failure = SettingsError.unreadableFileKept(fileName: "settings.json")

        model.requestRetention(90)

        #expect(model.message?.contains("settings.json") == true)
        #expect(model.retentionDays == 30)
    }

    // MARK: - Relecture

    @Test("reload relit les réglages et le disque : une durée changée ailleurs et un entretien ajouté ailleurs s'y voient")
    func reloadSeesChangesMadeElsewhere() async throws {
        let rig = try Rig(retention: 30)
        defer { rig.cleanUp() }
        let model = rig.makeModel()
        await model.reload()
        #expect(model.retentionDays == 30)
        #expect(model.records.isEmpty)

        rig.settings.history.retentionDays = 90
        try await rig.seed([Self.record(1)])
        await model.reload()

        #expect(model.retentionDays == 90)
        #expect(model.records.count == 1)
    }

    // MARK: - Typographie

    @Test("typographie : les phrases ont les espaces insécables du français, oracles écrits en clair")
    func theSentencesFollowTheHouseTypography() throws {
        #expect(
            HistoryModel.header
                == "Chaque entretien conclu est gardé ici en texte\u{00A0}: le prompt rédigé et la conversation. Ils restent sur cet ordinateur, ne sont envoyés nulle part, et l'audio n'est jamais gardé. Un entretien annulé par Échap n'est pas gardé."
        )
        #expect(HistoryModel.empty == "Aucun entretien gardé pour l'instant.")
        #expect(HistoryModel.copied == "Copié.")
        #expect(HistoryModel.copyFailure == "Le texte n'a pas pu être copié\u{00A0}: réessayez.")
        #expect(
            HistoryModel.writeFailure
                == "L'historique n'a pas pu être modifié\u{00A0}: vérifiez l'espace libre sur le disque, puis réessayez.")
        #expect(HistoryModel.noPromptTitle == "Conversation sans prompt (la rédaction avait échoué)")
        let titles = [
            HistoryModel.promptTitle, HistoryModel.conversationTitle, HistoryModel.copyPromptTitle,
            HistoryModel.copyConversationTitle, HistoryModel.deleteTitle, HistoryModel.deleteAllTitle,
            HistoryModel.retentionTitle,
        ]
        #expect(titles == ["Prompt", "Conversation", "Copier le prompt", "Copier la conversation", "Supprimer", "Tout supprimer…", "Garder les entretiens"])
        // Contrôle générique : aucune ponctuation double précédée d'une espace ordinaire.
        let sentences = [
            HistoryModel.header, HistoryModel.empty, HistoryModel.copyFailure, HistoryModel.writeFailure,
            HistoryModel.retentionSaveFailure,
        ]
        for sentence in sentences {
            for mark in [" :", " ;", " ?", " !", "« ", " »"] { #expect(!sentence.contains(mark), "« \(mark) » ordinaire dans : \(sentence)") }
        }
    }
}
