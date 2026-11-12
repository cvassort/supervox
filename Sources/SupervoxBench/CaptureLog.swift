import Foundation

/// Ce que `record` sait d'une prise gardée : le périphérique d'entrée (nom, canaux, fréquence, tel que la capture le
/// décrit), sa fréquence native avant rééchantillonnage, et la date.
struct CaptureTake: Codable, Equatable {
    let input: String
    let nativeSampleRate: Double
    let date: Date
}

/// `capture.json`, à côté des enregistrements : une entrée par identifiant, complétée à chaque prise gardée. Une
/// entrée par prise plutôt qu'une par session : une session suivante, sur un autre micro, ne doit pas réécrire ce qui
/// est connu des prises précédentes.
enum CaptureLog {
    static let fileName = "capture.json"

    /// Les prises décrites ; vide si le fichier n'existe pas.
    static func read(_ directory: URL) throws -> [String: CaptureTake] {
        let file = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: CaptureTake].self, from: Data(contentsOf: file))
    }

    /// Ajoute ou remplace la prise `id`, sans toucher aux autres.
    static func record(_ take: CaptureTake, id: String, in directory: URL) throws {
        var takes = try read(directory)
        takes[id] = take
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(takes).write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    /// `summary` du fichier de `directory` ; un fichier illisible est dit, sans arrêter la commande.
    static func summary(of directory: URL, ids: [String]) -> String {
        do { return summary(try read(directory), ids: ids) } catch {
            return "Capture : \(fileName) illisible (\(describe(error)))."
        }
    }

    /// Une phrase pour les rapports, sur les seuls enregistrements `ids` : périphériques (avec le nombre de prises),
    /// fréquences natives, dates des prises, et les enregistrements sans information.
    static func summary(_ takes: [String: CaptureTake], ids: [String]) -> String {
        let known = ids.compactMap { takes[$0] }
        guard !known.isEmpty else {
            return "Capture : non renseignée (pas de \(fileName) de `record` à côté des enregistrements)."
        }
        var devices: [String] = []
        var counts: [String: Int] = [:]
        for take in known {
            if counts[take.input] == nil { devices.append(take.input) }
            counts[take.input, default: 0] += 1
        }
        let rates = Set(known.map { Int($0.nativeSampleRate.rounded()) }).sorted().map { "\($0) Hz" }
        let dates = known.map(\.date)
        let day = ISO8601DateFormatter()
        day.formatOptions = [.withFullDate]
        day.timeZone = .current
        let first = day.string(from: dates.min()!), last = day.string(from: dates.max()!)
        var text = "Capture (\(fileName) de `record`) : "
            + devices.map { "\($0) (\(counts[$0]!) prise(s))" }.joined(separator: " ; ")
            + " ; fréquence native \(rates.joined(separator: ", "))"
            + " ; prises " + (first == last ? "du \(first)" : "du \(first) au \(last)")
        let missing = ids.filter { takes[$0] == nil }
        if !missing.isEmpty { text += " ; sans information de capture : \(missing.joined(separator: ", "))" }
        return text + "."
    }
}
