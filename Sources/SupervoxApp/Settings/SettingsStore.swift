import Foundation

public enum SettingsError: Error, Equatable, LocalizedError {
    /// Le fichier de réglages existe mais est illisible ou d'une version inconnue : on ne l'écrase pas.
    case unreadableFileKept(fileName: String)
    /// Le fichier de réglages vient d'une version plus récente de l'application : on ne l'écrase pas.
    case newerVersionKept(fileName: String, version: Int)

    public var errorDescription: String? {
        switch self {
        case .unreadableFileKept(let fileName):
            return "Le fichier « \(fileName) » est illisible ou d'une version inconnue ; il est conservé tel quel et les réglages n'ont pas été enregistrés."
        case .newerVersionKept(let fileName, let version):
            return "Le fichier « \(fileName) » vient d'une version plus récente de Supervox (version \(version)) ; il est conservé tel quel et les réglages n'ont pas été enregistrés."
        }
    }
}

/// Résultat d'une lecture des réglages : les réglages à utiliser, et un message à montrer
/// à l'utilisateur si le fichier existant n'a pas pu être repris.
public struct SettingsLoad: Equatable {
    public var settings: AppSettings
    public var notice: String?
    /// Vrai seulement si le fichier n'existe pas : rien n'a encore été enregistré sur ce Mac.
    public var isFirstLaunch: Bool

    public init(settings: AppSettings, notice: String?, isFirstLaunch: Bool = false) {
        self.settings = settings
        self.notice = notice
        self.isFirstLaunch = isFirstLaunch
    }
}

/// Lit et écrit le fichier de réglages. Aucun fichier existant n'est jamais écrasé s'il n'est pas lisible à la
/// version courante :
/// - fichier abîmé (pas du JSON, sans `version`, version nulle ou négative, champ d'une autre forme) : déplacé à
///   côté, puis les réglages par défaut s'appliquent ;
/// - fichier d'une version plus récente : laissé en place ; ce que cette version sait en lire s'applique, et rien
///   n'y est écrit ;
/// - fichier présent mais impossible à lire (droits, erreur passagère) : laissé en place, les réglages par défaut
///   s'appliquent en mémoire, et rien n'y est écrit.
public struct SettingsStore: Sendable {
    public let file: URL
    private let now: @Sendable () -> Date
    private let moveItem: @Sendable (URL, URL) throws -> Void

    /// `now` sert à horodater le fichier mis de côté, `moveItem` à le déplacer : les tests y injectent
    /// une horloge fixe et un déplacement qui échoue.
    public init(
        file: URL,
        now: @escaping @Sendable () -> Date = { Date() },
        moveItem: @escaping @Sendable (URL, URL) throws -> Void = {
            try FileManager.default.moveItem(at: $0, to: $1)
        }
    ) {
        self.file = file
        self.now = now
        self.moveItem = moveItem
    }

    /// `Application Support/Supervox/settings.json` de l'utilisateur. Ne crée rien.
    public static func defaultFile() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Supervox", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public func load() -> SettingsLoad {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            if !FileManager.default.fileExists(atPath: file.path) {
                return SettingsLoad(settings: .defaults, notice: nil, isFirstLaunch: true)
            }
            // Une erreur de lecture ne dit rien du contenu : le fichier peut être valide. Il reste à sa place.
            return SettingsLoad(
                settings: .defaults,
                notice: "Le fichier de réglages « \(file.lastPathComponent) » n'a pas pu être lu : il reste en place, intact, et rien n'y sera écrit ; les réglages par défaut sont utilisés jusqu'au prochain lancement.")
        }
        switch Self.decode(data) {
        case .success(.current(let settings)):
            return SettingsLoad(settings: settings, notice: nil)
        case .success(.newer(let settings, let version)):
            let use = settings == nil ? "les réglages par défaut sont utilisés" : "les réglages que cette version sait lire sont utilisés"
            var inMemory = settings ?? .defaults
            inMemory.version = AppSettings.current
            return SettingsLoad(
                settings: inMemory,
                notice: "Le fichier de réglages vient d'une version plus récente de Supervox (version \(version)) : il est gardé tel quel et rien n'y sera écrit ; \(use), et les modifications ne seront pas enregistrées.")
        case .failure(let problem):
            return setAside(reason: problem.description)
        }
    }

    /// Refuse d'écrire par-dessus un fichier existant qui n'est pas lisible à la version courante : il a été mis de
    /// côté, ou aurait dû l'être (déplacement en échec), ou il appartient à une version plus récente, ou il n'a pas
    /// pu être lu. Il ne doit jamais être perdu.
    public func save(_ settings: AppSettings) throws {
        if FileManager.default.fileExists(atPath: file.path) {
            guard let existing = try? Data(contentsOf: file) else {
                throw SettingsError.unreadableFileKept(fileName: file.lastPathComponent)
            }
            switch Self.decode(existing) {
            case .success(.current): break
            case .success(.newer(_, let version)):
                throw SettingsError.newerVersionKept(fileName: file.lastPathComponent, version: version)
            case .failure:
                throw SettingsError.unreadableFileKept(fileName: file.lastPathComponent)
            }
        }
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: file, options: .atomic)
    }

    // MARK: - Décodage

    private struct Problem: Error, CustomStringConvertible {
        var description: String
    }

    private enum Decoded {
        /// Fichier de la version courante (ou d'une version antérieure connue, quand il y en aura).
        case current(AppSettings)
        /// Fichier d'une version plus récente : ce qui a pu en être lu, ou `nil`.
        case newer(AppSettings?, version: Int)
    }

    /// Lit d'abord `version` seule. Une version nulle ou négative est inconnue. Une version plus récente est lue
    /// autant que possible (décodage tolérant), sans échec. La version courante doit se décoder.
    private static func decode(_ data: Data) -> Result<Decoded, Problem> {
        struct VersionProbe: Decodable { var version: Int }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return .failure(Problem(description: "Le fichier de réglages est illisible"))
        }
        guard probe.version >= 1 else {
            return .failure(Problem(description:
                "Le fichier de réglages a une version inconnue (\(probe.version)), cette application lit la version \(AppSettings.current)"))
        }
        let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        if probe.version > AppSettings.current { return .success(.newer(settings, version: probe.version)) }
        guard let settings else { return .failure(Problem(description: "Le fichier de réglages est illisible")) }
        return .success(.current(settings))
    }

    // MARK: - Mise de côté

    private func setAside(reason: String) -> SettingsLoad {
        let defaults = SettingsLoad(settings: .defaults, notice: nil)
        let destination = uniqueAsideURL()
        do {
            try moveItem(file, destination)
        } catch {
            return SettingsLoad(
                settings: defaults.settings,
                notice: "\(reason) et n'a pas pu être mis de côté : « \(file.lastPathComponent) » reste en place, intact, et ne sera pas écrasé ; les réglages par défaut sont utilisés.")
        }
        return SettingsLoad(
            settings: defaults.settings,
            notice: "\(reason) ; il a été mis de côté sous « \(destination.lastPathComponent) » et les réglages par défaut sont utilisés.")
    }

    /// `settings.json.illisible-<AAAAMMJJ>T<HHMMSS>Z` (UTC), suivi de `-2`, `-3`… si ce nom est déjà pris.
    private func uniqueAsideURL() -> URL {
        let base = "\(file.lastPathComponent).illisible-\(Self.timestamp(now()))"
        let folder = file.deletingLastPathComponent()
        var candidate = folder.appendingPathComponent(base)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(counter)")
            counter += 1
        }
        return candidate
    }

    private static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04ld%02ld%02ldT%02ld%02ld%02ldZ",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}
