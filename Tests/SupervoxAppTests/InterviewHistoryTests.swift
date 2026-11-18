import Foundation
import SupervoxCore
import Synchronization
import Testing

@testable import SupervoxApp

/// Le stockage de l'historique des entretiens, sur un VRAI disque mais dans un dossier temporaire propre à chaque test, supprimé à
/// la fin. Horloge et durée de conservation injectées : aucune attente, aucun fuseau, aucun vrai dossier de l'application.
@Suite(.timeLimit(.minutes(1))) struct InterviewHistoryTests {
    /// Une valeur que la fermeture de durée relit à chaque appel (le test la change entre deux appels).
    final class Retention: Sendable {
        private let state: Mutex<Int>
        init(_ days: Int) { state = Mutex(days) }
        var days: Int {
            get { state.withLock { $0 } }
            set { state.withLock { $0 = newValue } }
        }
    }

    /// 2026-11-17 12:00:00 UTC, fixe : jamais « maintenant ».
    static let now = Date(timeIntervalSince1970: 1_794_916_800)

    /// Le dossier PARENT temporaire ; la racine de l'historique est `Historique` dedans (elle n'existe pas encore).
    let directory: URL
    let retention = Retention(30)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-history-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var root: URL { directory.appendingPathComponent("entretiens-temporaires", isDirectory: true) }

    /// Rend les droits d'écriture avant de supprimer (un test peut avoir retiré ceux d'un dossier).
    func cleanUp() {
        chflags(root.path, 0)
        for url in [root, directory] { chmod(url.path, 0o700) }
        try? FileManager.default.removeItem(at: directory)
    }

    func makeHistory(root custom: URL? = nil) -> InterviewHistory {
        let retention = retention
        return InterviewHistory(root: custom ?? root, retentionDays: { retention.days }, now: { Self.now })
    }

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
    }

    static func record(_ n: Int, daysAgo: Double = 0, prompt: String? = "Écris un outil d'exemple.") -> InterviewRecord {
        InterviewRecord(
            id: id(n), date: now.addingTimeInterval(-daysAgo * 86_400), prompt: prompt,
            conversation: InterviewRecordTests.shortConversation())
    }

    func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
    }

    func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    func url(of record: InterviewRecord) -> URL {
        root.appendingPathComponent(InterviewHistory.fileName(for: record))
    }

    /// Un fichier d'entretien écrit à la main (au format de la version donnée), pour ce que `save` ne produit pas.
    @discardableResult
    func plant(_ record: InterviewRecord, version: Int = 1, as name: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(record)
        var data = Data(#"{"version": \#(version), "record": "#.utf8)
        data.append(body)
        data.append(Data("}".utf8))
        let file = root.appendingPathComponent(name ?? InterviewHistory.fileName(for: record))
        try data.write(to: file)
        return file
    }

    // MARK: - Règle 1 : droits et écriture atomique

    @Test("règle 1 : le dossier est créé en 0700 et le fichier en 0600, lus par FileManager ; aucun fichier temporaire ne reste")
    func theFolderIsPrivateAndTheFileIsOwnerOnly() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let record = Self.record(1)

        try await history.save(record)

        #expect(try permissions(root) == 0o700)
        #expect(try permissions(url(of: record)) == 0o600)
        #expect(try names() == [InterviewHistory.fileName(for: record)], "le seul fichier est l'entretien, pas de reste d'écriture")
    }

    @Test("règle 1 : un dossier déjà là en 0755 est resserré à 0700 par l'enregistrement")
    func anExistingOpenFolderIsTightened() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o755) == 0)
        #expect(try permissions(root) == 0o755)

        try await makeHistory().save(Self.record(1))

        #expect(try permissions(root) == 0o700)
    }

    @Test("règle 1 : une écriture qui échoue (dossier immuable) lève, ne laisse aucun fichier partiel et garde l'ancien")
    func aFailedWriteLeavesNoPartialFileAndKeepsTheOldOne() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let old = Self.record(1, daysAgo: 1)
        try await history.save(old)
        let before = try Data(contentsOf: url(of: old))
        // Dossier immuable : déjà en 0700, il n'y a rien à resserrer, mais plus rien ne peut y être créé.
        #expect(chflags(root.path, UInt32(UF_IMMUTABLE)) == 0)

        await #expect(throws: InterviewHistory.Failure.writeFailed) { try await history.save(Self.record(2)) }

        #expect(chflags(root.path, 0) == 0)
        #expect(try names() == [InterviewHistory.fileName(for: old)], "ni fichier partiel ni fichier temporaire")
        #expect(try Data(contentsOf: url(of: old)) == before)
    }

    @Test("règle 1 : un renommage refusé (le nom visé est un dossier) lève et ne laisse pas le fichier temporaire")
    func aRefusedRenameRemovesTheTemporaryFile() async throws {
        defer { cleanUp() }
        let record = Self.record(1)
        try FileManager.default.createDirectory(at: url(of: record), withIntermediateDirectories: true)

        await #expect(throws: InterviewHistory.Failure.writeFailed) { try await makeHistory().save(record) }

        #expect(try names() == [InterviewHistory.fileName(for: record)], "seul le dossier posé par le test reste")
    }

    @Test("règle 1 : des droits qui ne peuvent pas être posés (dossier en 0755 rendu immuable) : save lève et n'écrit rien")
    func permissionsThatCannotBeSetRefuseTheSave() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o755) == 0)
        #expect(chflags(root.path, UInt32(UF_IMMUTABLE)) == 0)

        await #expect(throws: InterviewHistory.Failure.rootRefused) { try await makeHistory().save(Self.record(1)) }

        #expect(chflags(root.path, 0) == 0)
        #expect(try names().isEmpty)
        #expect(try permissions(root) == 0o755, "le dossier n'a pas été touché")
    }

    @Test("règle 1 : enregistrer deux fois le même entretien laisse un seul fichier complet et lisible")
    func savingTwiceKeepsOneCompleteFile() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let record = Self.record(1)

        try await history.save(record)
        try await history.save(record)

        #expect(try names().count == 1)
        #expect(await history.list() == [record])
    }

    @Test("règle 1 : un fichier d'une version plus récente, au nom visé, n'est jamais remplacé : l'enregistrement lève")
    func aNewerVersionFileIsNeverOverwrittenBySave() async throws {
        defer { cleanUp() }
        let record = Self.record(1)
        let planted = try plant(record, version: 2)
        let before = try Data(contentsOf: planted)

        await #expect(throws: InterviewHistory.Failure.newerFileInTheWay) { try await makeHistory().save(record) }

        #expect(try Data(contentsOf: planted) == before)
        #expect(try names() == [InterviewHistory.fileName(for: record)])
    }

    // MARK: - Format du fichier

    static let withPromptJSON = """
        {"version": 1, "record": {"id": "00000000-0000-4000-8000-000000000001", "date": "2026-11-17T12:00:00Z",
         "prompt": "Écris un outil d'exemple.",
         "conversation": {"turns": [
           {"speaker": "interviewer", "text": "Que voulez-vous construire ?"},
           {"speaker": "user", "text": "Un outil d'exemple."}]}}}
        """
    static let withoutPromptJSON = """
        {"version": 1, "record": {"id": "00000000-0000-4000-8000-000000000001", "date": "2026-11-17T12:00:00Z",
         "conversation": {"turns": [
           {"speaker": "interviewer", "text": "Que voulez-vous construire ?"},
           {"speaker": "user", "text": "Un outil d'exemple."}]}}}
        """

    private func object(_ data: Data) throws -> NSDictionary {
        try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    @Test("format : le fichier écrit est exactement {\"version\": 1, \"record\": {…}} avec toutes les clés, prompt présent ou absent")
    func theFileHoldsTheDocumentedJSON() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let with = Self.record(1)
        var without = Self.record(1, prompt: nil)
        without.id = Self.id(2)

        try await history.save(with)
        try await history.save(without)

        #expect(try object(Data(contentsOf: url(of: with))) == (try object(Data(Self.withPromptJSON.utf8))))
        let expectedWithout = Self.withoutPromptJSON.replacingOccurrences(of: "000000000001", with: "000000000002")
        #expect(try object(Data(contentsOf: url(of: without))) == (try object(Data(expectedWithout.utf8))))
    }

    @Test("format : le nom du fichier est aaaa-mm-jj-hhmmss-<uuid>.json, en UTC")
    func theFileNameIsTheUTCDateAndTheIdentifier() {
        #expect(
            InterviewHistory.fileName(for: Self.record(1))
                == "2026-11-17-120000-00000000-0000-4000-8000-000000000001.json")
        // 23:59:59 UTC le 31 décembre : le nom ne dépend ni du fuseau de la machine ni du calendrier de la personne.
        let late = InterviewRecord(
            id: Self.id(7), date: Date(timeIntervalSince1970: 1_798_761_599), prompt: nil, conversation: Conversation())
        #expect(InterviewHistory.fileName(for: late) == "2026-12-31-235959-00000000-0000-4000-8000-000000000007.json")
    }

    @Test("format : le nom ne contient ni texte d'entretien ni chemin")
    func theFileNameCarriesNoInterviewText() {
        var record = Self.record(1, prompt: "Un secret d'exemple dans le prompt.")
        record.conversation = {
            var conversation = Conversation()
            conversation.appendUser("Un autre secret d'exemple dit à voix haute.")
            return conversation
        }()
        let name = InterviewHistory.fileName(for: record)
        #expect(!name.contains("secret"))
        #expect(!name.contains("/"))
        let allowed = Set("0123456789abcdefABCDEF-.json")
        #expect(name.allSatisfy { allowed.contains($0) }, "\(name)")
    }

    // MARK: - Règle 2 : aller-retour, ordre, fichiers illisibles

    @Test("règle 2 : save puis list rend le même entretien, avec ou sans prompt")
    func saveThenListGivesTheSameRecord() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let with = Self.record(1, daysAgo: 2, prompt: "Écris un outil d'exemple, avec des accents : é, à, ç.")
        let without = Self.record(2, daysAgo: 1, prompt: nil)

        try await history.save(with)
        try await history.save(without)

        #expect(await history.list() == [without, with])
    }

    @Test("règle 2 : une date à fraction de seconde est gardée à la seconde près (ISO 8601) ; le reste de l'entretien est identique")
    func aFractionalDateIsKeptToTheSecond() async throws {
        defer { cleanUp() }
        var record = Self.record(1)
        record.date = Self.now.addingTimeInterval(0.75)
        try await makeHistory().save(record)

        let read = try #require(await makeHistory().list().first)

        #expect(read.date == Self.now, "la fraction est perdue : documenté")
        #expect(read.id == record.id && read.prompt == record.prompt && read.conversation == record.conversation)
    }

    @Test("règle 2 : trois entretiens enregistrés dans le désordre sortent du plus récent au plus ancien")
    func theListIsNewestFirst() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let middle = Self.record(2, daysAgo: 5)
        let oldest = Self.record(3, daysAgo: 20)
        let newest = Self.record(1, daysAgo: 1)

        for record in [middle, newest, oldest] { try await history.save(record) }

        #expect(await history.list().map(\.id) == [newest.id, middle.id, oldest.id])
    }

    @Test("règle 2 : à date égale, l'ordre est stable (identifiant décroissant)")
    func equalDatesAreOrderedStably() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let same = (1...4).map { Self.record($0, daysAgo: 3) }

        for record in same.shuffled() { try await history.save(record) }

        let expected = same.map(\.id).sorted { $0.uuidString > $1.uuidString }
        #expect(await history.list().map(\.id) == expected)
        #expect(await history.list().map(\.id) == expected, "deux lectures, même ordre")
    }

    @Test("règle 2 : un fichier abîmé ou d'une version inconnue est ignoré par list et reste sur le disque, octet pour octet")
    func unreadableFilesAreIgnoredAndKept() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let good = Self.record(1)
        try await history.save(good)
        let broken = root.appendingPathComponent("2026-01-01-000000-abîmé.json")
        try Data("{ pas du json".utf8).write(to: broken)
        let noVersion = root.appendingPathComponent("2026-01-02-000000-sans-version.json")
        try Data(Self.withPromptJSON.replacingOccurrences(of: #""version": 1, "#, with: "").utf8).write(to: noVersion)
        let versionZero = root.appendingPathComponent("2026-01-03-000000-version-zero.json")
        try Data(Self.withPromptJSON.replacingOccurrences(of: #""version": 1"#, with: #""version": 0"#).utf8).write(to: versionZero)
        let futureShape = root.appendingPathComponent("2026-01-04-000000-forme-future.json")
        try Data(#"{"version": 2, "record": {"identifiant": "x", "contenu": []}}"#.utf8).write(to: futureShape)
        let bytes = try [broken, noVersion, versionZero, futureShape].map { try Data(contentsOf: $0) }

        let listed = await history.list()
        _ = await history.purge()
        try await history.save(Self.record(2, daysAgo: 1))

        #expect(listed == [good])
        #expect(try [broken, noVersion, versionZero, futureShape].map { try Data(contentsOf: $0) } == bytes)
    }

    @Test("règle 2 : un fichier d'une version plus récente est lu si son contenu a la forme connue, et jamais réécrit")
    func aNewerVersionIsReadWhenPossibleAndNeverRewritten() async throws {
        defer { cleanUp() }
        let future = Self.record(1, daysAgo: 1)
        let planted = try plant(future, version: 2)
        let before = try Data(contentsOf: planted)
        let history = makeHistory()

        let listed = await history.list()
        try await history.save(Self.record(2, daysAgo: 2))
        _ = await history.purge()
        let again = await history.list()

        #expect(listed == [future])
        #expect(again.map(\.id) == [future.id, Self.id(2)])
        #expect(try Data(contentsOf: planted) == before, "octet pour octet")
    }

    @Test("règle 2 : un lien symbolique nommé .json n'est ni suivi ni lu ; un fichier d'un autre nom n'est pas touché")
    func symbolicLinksAndOtherFilesAreNotRead() async throws {
        defer { cleanUp() }
        let outside = directory.appendingPathComponent("ailleurs.json")
        let outsideRecord = Self.record(9)
        try plant(outsideRecord, as: "x.json")  // fabrique un contenu valide dans la racine…
        try FileManager.default.moveItem(at: root.appendingPathComponent("x.json"), to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("2026-01-01-000000-lien.json"), withDestinationURL: outside)
        let note = root.appendingPathComponent("notes.txt")
        try Data("une note de la personne".utf8).write(to: note)

        let history = makeHistory()
        #expect(await history.list().isEmpty, "le lien n'est pas suivi")
        _ = await history.purge()
        try await history.deleteAll()

        #expect(FileManager.default.fileExists(atPath: outside.path), "la cible du lien n'est jamais supprimée")
        #expect(try Data(contentsOf: note) == Data("une note de la personne".utf8), "un autre fichier n'est jamais touché")
        #expect(try names() == ["notes.txt"], "le lien lui-même est retiré par « Tout supprimer »")
    }

    // MARK: - Règle 3 : conservation

    @Test("règle 3 : 30 jours : un entretien de 31 jours est supprimé par purge, ceux de 29 et de 30 jours restent ; purge rend le nombre")
    func purgeDeletesOnlyWhatIsOlderThanTheRetention() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let old = Self.record(1, daysAgo: 31)
        let recent = Self.record(2, daysAgo: 29)
        let edge = Self.record(3, daysAgo: 30)
        for record in [old, recent, edge] { try await history.save(record) }

        let removed = await history.purge()

        #expect(removed == 1)
        #expect(await history.list().map(\.id) == [recent.id, edge.id])
        #expect(!FileManager.default.fileExists(atPath: url(of: old).path))
    }

    @Test("règle 3 : la limite d'âge est une seule fonction, en secondes : 30 jours pile ne sont pas échus, une seconde de plus l'est")
    func theAgeLimitIsExactToTheSecond() {
        let limit = Self.now.addingTimeInterval(-30 * 86_400)
        #expect(!InterviewHistory.isExpired(limit, now: Self.now, retentionDays: 30))
        #expect(InterviewHistory.isExpired(limit.addingTimeInterval(-1), now: Self.now, retentionDays: 30))
        #expect(!InterviewHistory.isExpired(limit.addingTimeInterval(1), now: Self.now, retentionDays: 30))
        #expect(InterviewHistory.isExpired(Self.now, now: Self.now, retentionDays: 0), "0 : tout est échu, même maintenant")
        #expect(!InterviewHistory.isExpired(Self.now.addingTimeInterval(3600), now: Self.now, retentionDays: 30), "une date future n'est pas échue")
    }

    @Test("règle 3 : durée 0 : save n'écrit rien (pas même le dossier) ; purge supprime tous les entretiens lisibles")
    func zeroKeepsNothing() async throws {
        defer { cleanUp() }
        retention.days = 0
        let history = makeHistory()

        try await history.save(Self.record(1))
        #expect(!FileManager.default.fileExists(atPath: root.path), "rien n'est écrit : le dossier n'est pas créé")

        // Des entretiens gardés auparavant, puis la durée passe à 0.
        retention.days = 30
        try await history.save(Self.record(1))
        try await history.save(Self.record(2, daysAgo: 3))
        retention.days = 0
        #expect(await history.purge() == 2)
        #expect(await history.list().isEmpty)
    }

    @Test("règle 3 : la durée est relue à chaque appel : la passer de 30 à 90 jours garde un entretien de 40 jours que 30 aurait supprimé")
    func theRetentionIsReadOnEveryCall() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let forty = Self.record(1, daysAgo: 40)
        retention.days = 90
        try await history.save(forty)
        #expect(await history.purge() == 0)
        retention.days = 30
        #expect(await history.purge() == 1)
    }

    @Test("règle 3 : une durée négative n'est jamais prise pour 0 (purge n'efface pas tout) : elle vaut la durée par défaut")
    func aNegativeRetentionFallsBackToTheDefaultNotToZero() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let recent = Self.record(1, daysAgo: 10)
        let old = Self.record(2, daysAgo: Double(HistorySettings.defaults.retentionDays + 10))
        retention.days = HistorySettings.defaults.retentionDays + 100
        for record in [recent, old] { try await history.save(record) }
        retention.days = -5

        #expect(await history.purge() == 1)
        #expect(await history.list().map(\.id) == [recent.id])
    }

    @Test("règle 3 : un nombre de jours énorme ne fait pas déborder le calcul : il est borné au plafond des réglages")
    func anHugeRetentionIsCapped() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        retention.days = Int.max
        let ancient = Self.record(1, daysAgo: Double(HistorySettings.maxRetentionDays) + 5)
        let kept = Self.record(2, daysAgo: 100)
        // Écrits à la main : `save` aussi lit la durée, ici énorme.
        try plant(ancient)
        try plant(kept)

        #expect(await history.purge() == 1, "au-delà du plafond, l'entretien est échu")
        #expect(await history.list().map(\.id) == [kept.id])
    }

    @Test("règle 3 : purge supprime un entretien lisible d'une version plus récente s'il est échu, jamais un fichier illisible")
    func purgeAppliesToEveryReadableFileButNeverToUnreadableOnes() async throws {
        defer { cleanUp() }
        let futureOld = Self.record(1, daysAgo: 60)
        let plantedFuture = try plant(futureOld, version: 2)
        let broken = root.appendingPathComponent("2020-01-01-000000-abîmé.json")
        try Data("pas du json".utf8).write(to: broken)

        #expect(await makeHistory().purge() == 1)

        #expect(!FileManager.default.fileExists(atPath: plantedFuture.path))
        #expect(FileManager.default.fileExists(atPath: broken.path), "un illisible ne part que par « Tout supprimer »")
    }

    @Test("règle 3 : purge retire aussi les restes d'une écriture interrompue (fichier temporaire d'un plantage), sans les compter")
    func purgeRemovesLeftoverTemporaryFiles() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        try await history.save(Self.record(1))
        let leftover = root.appendingPathComponent(".ecriture-\(UUID().uuidString).tmp")
        try Data("reste d'un plantage".utf8).write(to: leftover)

        #expect(await history.purge() == 0, "le reste n'est pas un entretien : il n'est pas compté")

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(await history.list().count == 1)
    }

    // MARK: - Suppression

    @Test("delete retire le fichier de cet entretien et d'aucun autre ; un identifiant inconnu ne lève pas")
    func deleteRemovesOnlyThatRecord() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let first = Self.record(1, daysAgo: 1)
        let second = Self.record(2, daysAgo: 2)
        try await history.save(first)
        try await history.save(second)

        try await history.delete(first.id)
        try await history.delete(Self.id(99))

        #expect(await history.list().map(\.id) == [second.id])
        #expect(!FileManager.default.fileExists(atPath: url(of: first).path))
    }

    @Test("m4 : delete vise le fichier LU : un entretien dont le fichier a été renommé à la main est supprimé pour de bon")
    func deleteTargetsTheFileThatWasRead() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let record = Self.record(1)
        try await history.save(record)
        let renamed = root.appendingPathComponent("copie-manuelle.json")
        try FileManager.default.moveItem(at: url(of: record), to: renamed)
        #expect(await history.list() == [record], "l'entretien est lu malgré son nouveau nom")

        try await history.delete(record.id)

        #expect(!FileManager.default.fileExists(atPath: renamed.path), "le fichier renommé est supprimé, pas seulement annoncé")
        #expect(await history.list().isEmpty)
    }

    @Test("m4 : un fichier dont le NOM porte l'identifiant d'un autre entretien n'est pas supprimé à sa place")
    func deleteIgnoresAFileThatOnlyCarriesTheIdentifierInItsName() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let wanted = Self.record(1, daysAgo: 1)
        let other = Self.record(2, daysAgo: 2)
        try await history.save(wanted)
        try await history.save(other)
        // Le fichier de `other` est nommé comme celui de `wanted`, et inversement.
        let swapped = root.appendingPathComponent("tmp-echange.json")
        try FileManager.default.moveItem(at: url(of: wanted), to: swapped)
        try FileManager.default.moveItem(at: url(of: other), to: url(of: wanted))
        try FileManager.default.moveItem(at: swapped, to: url(of: other))

        try await history.delete(wanted.id)

        #expect(await history.list().map(\.id) == [other.id], "c'est l'entretien demandé qui est parti, selon son contenu")
    }

    @Test("delete sur un dossier d'historique qui n'existe pas ne lève pas et ne le crée pas")
    func deleteWithoutAFolderDoesNothing() async throws {
        defer { cleanUp() }
        try await makeHistory().delete(Self.id(1))
        try await makeHistory().deleteAll()
        #expect(await makeHistory().purge() == 0)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("delete lève quand le fichier ne peut pas être retiré, et l'entretien reste dans la liste")
    func aRefusedDeleteThrowsAndKeepsTheRecord() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let record = Self.record(1)
        try await history.save(record)
        #expect(chmod(root.path, 0o500) == 0)

        await #expect(throws: InterviewHistory.Failure.writeFailed) { try await history.delete(record.id) }

        #expect(chmod(root.path, 0o700) == 0)
        #expect(await history.list() == [record])
    }

    @Test("deleteAll vide les fichiers .json de l'historique, illisibles compris, et seulement eux ; fileCount les compte d'avance")
    func deleteAllRemovesEveryJSONFileOfTheFolder() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        try await history.save(Self.record(1))
        try await history.save(Self.record(2, daysAgo: 2))
        try plant(Self.record(3), version: 2)
        try Data("pas du json".utf8).write(to: root.appendingPathComponent("abîmé.json"))
        try Data("note".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("dossier.json", isDirectory: true), withIntermediateDirectories: false)
        try Data("reste".utf8).write(to: root.appendingPathComponent(".ecriture-x.tmp"))

        #expect(await history.fileCount() == 4, "deux entretiens, un d'une version future, un illisible : ce que deleteAll supprimera")
        try await history.deleteAll()

        #expect(try names() == ["dossier.json", "notes.txt"], "le dossier nommé .json et la note ne sont pas des fichiers d'historique")
        #expect(await history.fileCount() == 0)
    }

    // MARK: - Racine invalide

    @Test("racine qui existe et n'est pas un dossier : save lève, list rend [], purge 0, deleteAll ne casse rien ; le fichier est intact")
    func aRootThatIsAFileIsRefusedWithoutHarm() async throws {
        defer { cleanUp() }
        try Data("pas un dossier".utf8).write(to: root)
        let history = makeHistory()

        await #expect(throws: InterviewHistory.Failure.rootRefused) { try await history.save(Self.record(1)) }
        #expect(await history.list().isEmpty)
        #expect(await history.purge() == 0)
        #expect(await history.fileCount() == 0)
        try await history.deleteAll()
        try await history.delete(Self.id(1))

        #expect(try Data(contentsOf: root) == Data("pas un dossier".utf8))
    }

    @Test("racine qui est un lien symbolique : save lève, rien n'est écrit dans la cible, et la cible n'est ni lue ni purgée")
    func aSymbolicLinkRootIsRefused() async throws {
        defer { cleanUp() }
        let target = directory.appendingPathComponent("cible", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let inside = target.appendingPathComponent(InterviewHistory.fileName(for: Self.record(5, daysAgo: 90)))
        let insideRecord = Self.record(5, daysAgo: 90)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = Data(#"{"version": 1, "record": "#.utf8)
        data.append(try encoder.encode(insideRecord))
        data.append(Data("}".utf8))
        try data.write(to: inside)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: target)
        let history = makeHistory()

        await #expect(throws: InterviewHistory.Failure.rootRefused) { try await history.save(Self.record(1)) }
        #expect(await history.list().isEmpty, "la cible n'est pas lue")
        #expect(await history.purge() == 0, "la cible n'est pas purgée")
        try await history.deleteAll()

        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path) == [inside.lastPathComponent])
    }

    @Test("racine impossible à créer (parent sans droit d'écriture) : save lève, sans plantage, et list rend []")
    func anUncreatableRootThrows() async throws {
        defer { cleanUp() }
        #expect(chmod(directory.path, 0o500) == 0)
        let history = makeHistory()

        await #expect(throws: InterviewHistory.Failure.writeFailed) { try await history.save(Self.record(1)) }

        #expect(chmod(directory.path, 0o700) == 0)
        #expect(await history.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    // MARK: - C-1 : la durée confirmée du dossier

    var confirmationFile: URL { root.appendingPathComponent("conservation") }

    @Test("C-1 : sans fichier, la durée confirmée est absente ; confirmée, elle est écrite en 0600 sous le nom « conservation », JSON documenté")
    func theConfirmedRetentionIsWrittenPrivately() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        #expect(await history.confirmedRetention() == .absent)
        #expect(await history.snapshot().confirmedRetention == .absent)

        try await history.confirmRetention(90)

        #expect(await history.confirmedRetention() == .days(90))
        #expect(await history.snapshot().confirmedRetention == .days(90))
        #expect(try permissions(confirmationFile) == 0o600)
        #expect(try permissions(root) == 0o700)
        let written = try object(Data(contentsOf: confirmationFile))
        #expect(written == (try object(Data(#"{"version": 1, "retentionDays": 90}"#.utf8))), "\(written)")
        #expect(InterviewHistory.retentionFileName == "conservation")
        #expect(!InterviewHistory.retentionFileName.hasSuffix(".json"), "jamais l'extension d'un entretien")
        #expect(try names() == ["conservation"], "aucun reste d'écriture")
    }

    @Test("C-1 : 0 (« Ne rien garder ») se confirme comme les autres ; une nouvelle valeur remplace l'ancienne ; bornée comme les réglages")
    func theConfirmedRetentionCanBeZeroReplacedAndIsBounded() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        try await history.confirmRetention(0)
        #expect(await history.confirmedRetention() == .days(0))
        try await history.confirmRetention(365)
        #expect(await history.confirmedRetention() == .days(365))
        try await history.confirmRetention(Int.max)
        #expect(await history.confirmedRetention() == .days(HistorySettings.maxRetentionDays))
        try await history.confirmRetention(-5)
        #expect(await history.confirmedRetention() == .days(HistorySettings.defaults.retentionDays), "négatif : le défaut, jamais 0")
    }

    @Test("C-1 : un fichier de durée illisible (abîmé, mauvais type, négatif, sans version, dossier, lien) se lit « illisible », sans rien suivre")
    func anUnreadableConfirmationIsReportedAsSuch() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let history = makeHistory()
        for content in [
            "pas du json", #"{"version": 1, "retentionDays": "365"}"#, #"{"version": 1, "retentionDays": -3}"#,
            #"{"retentionDays": 90}"#, #"{"version": 0, "retentionDays": 90}"#, #"{"version": 1}"#,
        ] {
            try Data(content.utf8).write(to: confirmationFile)
            #expect(await history.confirmedRetention() == .unreadable, "\(content)")
        }
        // Une version plus récente de forme connue est lue.
        try Data(#"{"version": 2, "retentionDays": 90}"#.utf8).write(to: confirmationFile)
        #expect(await history.confirmedRetention() == .days(90))

        try FileManager.default.removeItem(at: confirmationFile)
        try FileManager.default.createDirectory(at: confirmationFile, withIntermediateDirectories: false)
        #expect(await history.confirmedRetention() == .unreadable, "un dossier n'est pas un fichier de durée")
        try FileManager.default.removeItem(at: confirmationFile)

        let outside = directory.appendingPathComponent("ailleurs")
        try Data(#"{"version": 1, "retentionDays": 90}"#.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: confirmationFile, withDestinationURL: outside)
        #expect(await history.confirmedRetention() == .unreadable, "un lien symbolique n'est pas suivi")
    }

    @Test("C-1 : sur une racine refusée (fichier, lien), la durée confirmée est absente et l'écrire lève sans rien toucher")
    func theConfirmationFollowsTheRootRules() async throws {
        defer { cleanUp() }
        try Data("pas un dossier".utf8).write(to: root)
        let history = makeHistory()
        #expect(await history.confirmedRetention() == .absent)
        await #expect(throws: InterviewHistory.Failure.rootRefused) { try await history.confirmRetention(90) }
        #expect(try Data(contentsOf: root) == Data("pas un dossier".utf8))
    }

    @Test("C-1 : un dossier qui refuse l'écriture (immuable) : écrire la durée lève writeFailed, rien ne reste")
    func aRefusedConfirmationWriteThrows() async throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        #expect(chmod(root.path, 0o700) == 0)
        #expect(chflags(root.path, UInt32(UF_IMMUTABLE)) == 0)

        await #expect(throws: InterviewHistory.Failure.writeFailed) { try await makeHistory().confirmRetention(90) }

        #expect(chflags(root.path, 0) == 0)
        #expect(try names().isEmpty)
    }

    // Les parcours du dossier : le fichier de durée n'est JAMAIS compté ni supprimé comme un entretien.

    @Test("C-1 : le fichier de durée n'est compté nulle part : ni `fileCount`, ni `snapshot`, ni les « illisibles », ni `list`")
    func theConfirmationFileIsNeverCounted() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        try await history.save(Self.record(1))
        try await history.confirmRetention(90)

        let snapshot = await history.snapshot()
        #expect(snapshot.fileCount == 1, "un entretien, pas deux fichiers")
        #expect(snapshot.records.count == 1)
        #expect(await history.fileCount() == 1)
        #expect(await history.list().count == 1)
    }

    @Test("C-1 : « Tout supprimer » (deleteAll) laisse la durée confirmée, octet pour octet")
    func deleteAllKeepsTheConfirmation() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        try await history.save(Self.record(1))
        try await history.confirmRetention(90)
        let before = try Data(contentsOf: confirmationFile)

        try await history.deleteAll()

        #expect(try Data(contentsOf: confirmationFile) == before)
        #expect(await history.confirmedRetention() == .days(90))
        #expect(try names() == ["conservation"])
    }

    @Test("C-1 : la purge laisse la durée confirmée, même avec « Ne rien garder » et des entretiens échus, et ne la compte pas")
    func purgeKeepsTheConfirmation() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        try await history.save(Self.record(1, daysAgo: 40))
        try await history.confirmRetention(0)
        retention.days = 0
        let before = try Data(contentsOf: confirmationFile)

        #expect(await history.purge() == 1, "l'entretien seul est compté")

        #expect(try Data(contentsOf: confirmationFile) == before)
        #expect(try names() == ["conservation"])
    }

    @Test("C-1 : `delete` d'un entretien et le retrait des restes d'écriture ne touchent pas la durée confirmée")
    func deleteAndLeftoverRemovalKeepTheConfirmation() async throws {
        defer { cleanUp() }
        let history = makeHistory()
        let record = Self.record(1)
        try await history.save(record)
        try await history.confirmRetention(90)
        try Data("reste".utf8).write(to: root.appendingPathComponent(".ecriture-\(UUID().uuidString).tmp"))

        try await history.delete(record.id)
        _ = await history.purge()
        try await history.deleteAll()

        #expect(try names() == ["conservation"], "les restes sont retirés, la durée reste")
    }
}
