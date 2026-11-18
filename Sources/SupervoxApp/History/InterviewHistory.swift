import Foundation

/// L'historique local des entretiens conclus : UN fichier JSON par entretien, dans un dossier privé de l'utilisateur.
///
/// Le texte seulement : le prompt rédigé et la conversation. Jamais d'audio, jamais envoyé nulle part.
///
/// Le fichier (`aaaa-mm-jj-hhmmss-<uuid>.json`, date en UTC) contient `{"version": 1, "record": {…}}`, la date en ISO 8601 (à la
/// seconde : la fraction est perdue à l'écriture). Une version plus récente est lue si son contenu a la forme connue, jamais
/// réécrite ni remplacée par `save`.
///
/// Droits : le dossier est créé en 0700 (un dossier déjà là plus ouvert est resserré), chaque fichier en 0600. L'écriture est
/// atomique : un fichier temporaire (créé en 0600, `O_EXCL`, nom en `.tmp` que `list` ne voit pas) est écrit puis renommé ; une
/// écriture interrompue ne laisse donc jamais un fichier d'entretien partiel. La racine n'est jamais suivie si c'est un lien
/// symbolique, ni utilisée si ce n'est pas un dossier : `save` lève, le reste ne fait rien.
///
/// Ce qu'une erreur dit : sa nature seulement (`Failure`). Aucune erreur, aucun nom de fichier, aucun journal ne porte un chemin ni
/// un texte d'entretien.
public actor InterviewHistory: InterviewHistoryStoring {
    /// La version du format écrit.
    public static let formatVersion = 1

    /// Ce qui peut échouer, sans chemin ni texte.
    public enum Failure: Error, Equatable, Sendable {
        /// La racine existe et n'est pas un dossier (fichier, lien symbolique), ou ses droits ne peuvent pas être posés.
        case rootRefused
        /// Un fichier d'une version plus récente porte déjà le nom visé : il n'est pas remplacé.
        case newerFileInTheWay
        /// Écriture, renommage ou suppression refusés par le disque.
        case writeFailed
    }

    private let root: URL
    private let retentionDays: @Sendable () async -> Int
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - root: le dossier de l'historique.
    ///   - retentionDays: la durée de conservation en jours, relue à CHAQUE appel de `save` et de `purge` (un changement de réglage
    ///     s'applique sans relancer). Bornée ici comme dans les réglages (`HistorySettings.normalized`) : une valeur négative vaut
    ///     le défaut, jamais 0 (qui effacerait tout).
    ///   - now: l'horloge (injectée par les tests).
    public init(
        root: URL, retentionDays: @escaping @Sendable () async -> Int, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.root = root
        self.retentionDays = retentionDays
        self.now = now
    }

    // MARK: - Règles pures

    /// La durée telle que les réglages la bornent.
    static func normalized(_ days: Int) -> Int { HistorySettings(retentionDays: days).normalized.retentionDays }

    /// La SEULE règle d'âge : `purge` et le compte annoncé avant une suppression passent par elle. Un entretien est échu quand il a
    /// plus de `retentionDays` jours de 86 400 s (calcul en secondes, pas au calendrier : ni fuseau ni heure d'été) ; pile 30 jours
    /// n'est pas échu. Durée 0 : tout est échu. Une date future n'est pas échue.
    public static func isExpired(_ date: Date, now: Date, retentionDays: Int) -> Bool {
        let days = normalized(retentionDays)
        if days == 0 { return true }
        return now.timeIntervalSince(date) > Double(days) * 86_400
    }

    /// `aaaa-mm-jj-hhmmss-<uuid>.json`, la date en UTC, le calendrier grégorien : ni le fuseau ni la langue de la machine ne
    /// changent le nom. Rien d'autre que la date, l'heure et l'identifiant.
    public static func fileName(for record: InterviewRecord) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: record.date)
        let stamp = String(
            format: "%04d-%02d-%02d-%02d%02d%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
            parts.minute ?? 0, parts.second ?? 0)
        return stamp + "-" + record.id.uuidString.lowercased() + ".json"
    }

    // MARK: - Écriture

    /// Enregistre un entretien. Ne fait rien (pas même créer le dossier) si la durée vaut 0. Lève si la racine est refusée, si un
    /// fichier d'une version plus récente porte déjà ce nom, ou si le disque refuse.
    public func save(_ entry: InterviewRecord) async throws {
        guard Self.normalized(await retentionDays()) > 0 else { return }
        try prepareRoot()
        let data: Data
        do { data = try Self.encode(entry) } catch { throw Failure.writeFailed }
        let destination = root.appendingPathComponent(Self.fileName(for: entry))
        if let version = Self.version(ofFileAt: destination.path), version > Self.formatVersion {
            throw Failure.newerFileInTheWay
        }
        let temporary = root.appendingPathComponent(Self.temporaryPrefix + UUID().uuidString + Self.temporarySuffix)
        try Self.writeNewFile(data, atPath: temporary.path)
        if rename(temporary.path, destination.path) != 0 {
            unlink(temporary.path)
            throw Failure.writeFailed
        }
    }

    // MARK: - Lecture

    /// Les entretiens lisibles, du plus récent au plus ancien (à date égale : identifiant décroissant, un ordre stable). Un fichier
    /// illisible (abîmé, sans version, d'une version à la forme inconnue) est ignoré, jamais supprimé ; un lien symbolique n'est
    /// pas suivi.
    public func list() async -> [InterviewRecord] {
        readAll().map(\.record)
    }

    /// Les entretiens lisibles ET le nombre de fichiers, lus ensemble (un seul saut d'acteur : un entretien enregistré entre les deux
    /// lectures ne fait plus compter un fichier « illisible » en trop).
    public struct Snapshot: Sendable {
        public var records: [InterviewRecord]
        public var fileCount: Int
    }

    public func snapshot() async -> Snapshot {
        guard rootState() == .directory else { return Snapshot(records: [], fileCount: 0) }
        return Snapshot(records: readAll().map(\.record), fileCount: historyFileNames().count)
    }

    /// Le nombre de fichiers `.json` du dossier, illisibles compris : exactement ce que `deleteAll` supprimera.
    public func fileCount() async -> Int {
        guard rootState() == .directory else { return 0 }
        return historyFileNames().count
    }

    // MARK: - Suppression

    /// Supprime le fichier de cet entretien (jamais un autre). Un identifiant inconnu n'est pas une erreur.
    public func delete(_ id: UUID) async throws {
        guard rootState() == .directory else { return }
        let suffix = "-" + id.uuidString.lowercased() + ".json"
        var failed = false
        for name in historyFileNames() where name.lowercased().hasSuffix(suffix) {
            if unlink(path(name)) != 0 { failed = true }
        }
        if failed { throw Failure.writeFailed }
    }

    /// Supprime tous les fichiers `.json` du dossier, illisibles compris, et les restes d'écriture ; rien d'autre (un autre fichier,
    /// un sous-dossier ne sont pas touchés). Tout est essayé : si un fichier résiste, la fonction lève à la fin.
    public func deleteAll() async throws {
        guard rootState() == .directory else { return }
        var failed = false
        for name in historyFileNames() where unlink(path(name)) != 0 { failed = true }
        removeLeftovers()
        if failed { throw Failure.writeFailed }
    }

    /// Supprime les entretiens échus (`isExpired`, durée relue maintenant) et rend leur nombre. S'applique à tout entretien
    /// LISIBLE, d'une version plus récente comprise ; un fichier illisible n'est jamais supprimé ici (il ne part que par
    /// `deleteAll`). Retire aussi les restes d'une écriture interrompue, sans les compter.
    public func purge() async -> Int {
        let days = Self.normalized(await retentionDays())
        guard rootState() == .directory else { return 0 }
        removeLeftovers()
        let moment = now()
        var removed = 0
        for entry in readAll() where Self.isExpired(entry.record.date, now: moment, retentionDays: days) {
            if unlink(path(entry.name)) == 0 { removed += 1 }
        }
        return removed
    }

    // MARK: - Dossier

    private enum RootState { case missing, directory, refused }

    /// La racine, examinée SANS suivre de lien : un lien symbolique ou un fichier est refusé.
    private func rootState() -> RootState {
        var info = stat()
        if lstat(root.path, &info) != 0 { return errno == ENOENT ? .missing : .refused }
        return info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) ? .directory : .refused
    }

    /// Crée le dossier en 0700 s'il manque, ou resserre un dossier déjà là. Lève si la racine est refusée ou si les droits ne
    /// peuvent pas être posés.
    private func prepareRoot() throws {
        switch rootState() {
        case .refused: throw Failure.rootRefused
        case .directory: break
        case .missing:
            do {
                try FileManager.default.createDirectory(
                    at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            } catch {
                throw Failure.writeFailed
            }
        }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw Failure.rootRefused
        }
        if info.st_mode & 0o7777 != 0o700, chmod(root.path, 0o700) != 0 { throw Failure.rootRefused }
    }

    private func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    private static let temporaryPrefix = ".ecriture-"
    private static let temporarySuffix = ".tmp"

    /// Les fichiers d'historique : les noms en `.json` qui ne sont pas des dossiers (un lien symbolique en est un : il est compté
    /// et supprimé comme tel, jamais suivi).
    private func historyFileNames() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { name in
            guard name.hasSuffix(".json") else { return false }
            var info = stat()
            guard lstat(path(name), &info) == 0 else { return false }
            return info.st_mode & mode_t(S_IFMT) != mode_t(S_IFDIR)
        }
    }

    /// Les restes d'une écriture interrompue par un plantage. L'acteur n'écrit qu'un fichier à la fois : tout fichier temporaire
    /// présent ici est un reste.
    private func removeLeftovers() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where name.hasPrefix(Self.temporaryPrefix) && name.hasSuffix(Self.temporarySuffix) {
            unlink(path(name))
        }
    }

    // MARK: - Fichiers

    private struct Envelope: Codable {
        var version: Int
        var record: InterviewRecord
    }

    private struct VersionOnly: Decodable { var version: Int }

    private static func encode(_ record: InterviewRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Envelope(version: formatVersion, record: record))
    }

    /// Le contenu d'un fichier ordinaire (jamais celui d'un lien symbolique), `nil` sinon.
    private static func regularFileData(atPath path: String) -> Data? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// La version écrite dans le fichier, `nil` s'il n'existe pas ou ne la porte pas.
    private static func version(ofFileAt path: String) -> Int? {
        regularFileData(atPath: path).flatMap { try? JSONDecoder().decode(VersionOnly.self, from: $0).version }
    }

    private func readAll() -> [(name: String, record: InterviewRecord)] {
        guard rootState() == .directory else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [(name: String, record: InterviewRecord)] = []
        for name in historyFileNames() {
            guard let data = Self.regularFileData(atPath: path(name)),
                let envelope = try? decoder.decode(Envelope.self, from: data), envelope.version >= Self.formatVersion
            else { continue }
            entries.append((name, envelope.record))
        }
        return entries.sorted {
            $0.record.date != $1.record.date
                ? $0.record.date > $1.record.date : $0.record.id.uuidString > $1.record.id.uuidString
        }
    }

    /// Crée un fichier NEUF en 0600 (`O_EXCL`, sans suivre de lien), y écrit tout, force l'écriture sur le disque. Un échec retire le
    /// fichier et lève.
    private static func writeNewFile(_ data: Data, atPath path: String) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.writeFailed }
        var succeeded = fchmod(descriptor, 0o600) == 0
        if succeeded {
            succeeded = data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        return false
                    }
                    offset += written
                }
                return true
            }
        }
        if succeeded { succeeded = fsync(descriptor) == 0 }
        close(descriptor)
        if !succeeded {
            unlink(path)
            throw Failure.writeFailed
        }
    }
}
