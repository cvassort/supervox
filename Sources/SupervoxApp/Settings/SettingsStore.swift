import Foundation

/// Résultat d'une lecture des réglages : les réglages à utiliser, et un message à montrer
/// à l'utilisateur si le fichier existant n'a pas pu être repris.
public struct SettingsLoad: Equatable {
    public var settings: AppSettings
    public var notice: String?

    public init(settings: AppSettings, notice: String?) {
        self.settings = settings
        self.notice = notice
    }
}

/// Lit et écrit le fichier de réglages. Un fichier illisible ou d'une version inconnue
/// n'est jamais écrasé : il est déplacé à côté, puis les réglages par défaut s'appliquent.
public struct SettingsStore: Sendable {
    public let file: URL
    private let now: @Sendable () -> Date

    /// `now` sert à horodater le fichier mis de côté ; les tests y injectent une horloge fixe.
    public init(file: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.now = now
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
                return SettingsLoad(settings: .defaults, notice: nil)
            }
            return setAside(reason: "Le fichier de réglages n'a pas pu être lu")
        }

        struct VersionProbe: Decodable { var version: Int }
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else {
            return setAside(reason: "Le fichier de réglages est illisible")
        }
        guard probe.version == AppSettings.current else {
            return setAside(
                reason: "Le fichier de réglages a une version inconnue (\(probe.version)), cette application lit la version \(AppSettings.current)")
        }
        guard let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return setAside(reason: "Le fichier de réglages est illisible")
        }
        return SettingsLoad(settings: settings, notice: nil)
    }

    public func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: file, options: .atomic)
    }

    // MARK: - Mise de côté

    private func setAside(reason: String) -> SettingsLoad {
        let defaults = SettingsLoad(settings: .defaults, notice: nil)
        let destination = uniqueAsideURL()
        do {
            try FileManager.default.moveItem(at: file, to: destination)
        } catch {
            return SettingsLoad(
                settings: defaults.settings,
                notice: "\(reason) et n'a pas pu être mis de côté ; les réglages par défaut sont utilisés.")
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
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }
}
