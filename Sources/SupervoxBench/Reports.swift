import Foundation
import SupervoxCore

/// Résultat d'un moteur sur une phrase.
///
/// - Phrase transcrite : `hypothesis` (éventuellement vide) et `seconds` renseignés, `failure` nil.
/// - Échec (chargement, moteur, audio illisible) : `failure` renseigné, `hypothesis` et `seconds` nil.
/// - Sans voix : `hasSpeech` faux, rien d'autre ; le moteur n'a pas été appelé.
struct ItemResult: Equatable, Codable {
    let id: String
    let hypothesis: String?
    let seconds: Double?
    let failure: String?
    let hasSpeech: Bool
}

/// Synthèse d'un moteur sur le corpus.
struct EngineSummary: Equatable, Codable {
    let engine: String
    /// Taux d'erreur de mots agrégé : (S + D + I) cumulés sur toutes les phrases transcrites / mots de référence
    /// cumulés. `nil` si aucune phrase n'a été transcrite.
    let wer: Double?
    let termsFound: Int
    let termsTotal: Int
    let medianSeconds: Double?
    let p90Seconds: Double?
    /// Phrases parlées sans transcription (moteur en échec, audio illisible, résultat manquant).
    let failures: Int
    /// Phrases sans voix détectée : hors de tout taux.
    let excluded: Int
    /// Premier message d'échec rencontré, pour l'afficher dans le tableau.
    let firstFailure: String?
    /// Remarque libre affichée dans le tableau (ex. moteur mesuré sans vocabulaire).
    var note: String? = nil

    /// Termes trouvés / termes attendus ; `nil` si aucun terme n'était attendu.
    var termRecall: Double? { termsTotal > 0 ? Double(termsFound) / Double(termsTotal) : nil }
}

/// Contenu de `transcription.json` : les synthèses et les résultats bruts de chaque ligne.
struct TranscriptionJSON: Encodable {
    struct Run: Encodable {
        let label: String
        let summary: EngineSummary
        let items: [ItemResult]
    }
    let language: String
    let vocabulary: [String]
    let runs: [Run]

    init(language: String, vocabulary: [String], corpus: [CorpusItem], runs: [EngineRun]) {
        self.language = language
        self.vocabulary = vocabulary
        self.runs = zip(runs, Reports.summaries(corpus: corpus, runs: runs)).map {
            Run(label: $0.label, summary: $1, items: $0.results)
        }
    }
}

enum Reports {
    /// Agrège les résultats d'un moteur. Le corpus fait foi : chaque phrase du corpus est comptée une fois, et une
    /// phrase sans résultat est un échec. Une phrase en échec ou sans voix n'entre ni dans le taux d'erreur, ni dans
    /// le rappel des termes, ni dans les durées.
    static func summarize(engine: String, corpus: [CorpusItem], results: [ItemResult]) -> EngineSummary {
        var byID: [String: ItemResult] = [:]
        for result in results where byID[result.id] == nil { byID[result.id] = result }

        var substitutions = 0, deletions = 0, insertions = 0, referenceWords = 0
        var transcribed = 0, found = 0, total = 0, failures = 0, excluded = 0
        var seconds: [Double] = []
        var firstFailure: String?
        func fail(_ message: String) {
            failures += 1
            if firstFailure == nil { firstFailure = message }
        }

        for item in corpus {
            guard let result = byID[item.id] else { fail("aucun résultat pour « \(item.id) »"); continue }
            if !result.hasSpeech { excluded += 1; continue }
            if let failure = result.failure { fail(failure); continue }
            guard let hypothesis = result.hypothesis else { fail("transcription absente pour « \(item.id) »"); continue }

            let counts = WordErrorRate.compute(reference: item.text, hypothesis: hypothesis)
            substitutions += counts.substitutions
            deletions += counts.deletions
            insertions += counts.insertions
            referenceWords += counts.referenceCount
            let terms = TermRecall.compute(terms: item.terms, hypothesis: hypothesis)
            found += terms.found
            total += terms.total
            if let s = result.seconds { seconds.append(s) }
            transcribed += 1
        }

        let wer = transcribed > 0
            ? ErrorCounts(substitutions: substitutions, deletions: deletions, insertions: insertions,
                          referenceCount: referenceWords).rate
            : nil
        return EngineSummary(engine: engine, wer: wer, termsFound: found, termsTotal: total,
                             medianSeconds: percentile(seconds, 0.5), p90Seconds: percentile(seconds, 0.9),
                             failures: failures, excluded: excluded, firstFailure: firstFailure)
    }

    /// Centile `p` (0…1) par interpolation linéaire entre les rangs voisins : position p × (n − 1) dans les valeurs
    /// triées. La médiane de [1, 3] vaut 2. `nil` pour une liste vide.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let position = min(max(p, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// Tableau Markdown, une ligne par moteur dans l'ordre donné. Les termes s'affichent en « trouvés/total ».
    /// Un moteur sans aucune phrase transcrite à cause d'échecs affiche « échec » et le premier message d'erreur.
    static func markdownTable(_ rows: [EngineSummary]) -> String {
        var lines = [
            "| Moteur | Taux d'erreur (WER) | Termes trouvés | Médiane (s) | p90 (s) | Échecs | Sans voix | Remarque |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for row in rows {
            let wer: String
            if let value = row.wer { wer = decimal(value * 100, digits: 1) + " %" }
            else if row.failures > 0 { wer = "échec" }
            else { wer = "—" }
            let terms = row.termsTotal > 0 ? "\(row.termsFound)/\(row.termsTotal)" : "—"
            var remarks: [String] = []
            if let failure = row.firstFailure { remarks.append("échec : " + failure) }
            if let note = row.note { remarks.append(note) }
            let cells = [row.engine, wer, terms,
                         row.medianSeconds.map { decimal($0, digits: 2) } ?? "—",
                         row.p90Seconds.map { decimal($0, digits: 2) } ?? "—",
                         "\(row.failures)", "\(row.excluded)", remarks.joined(separator: " ; ")]
            lines.append("| " + cells.map(cell).joined(separator: " | ") + " |")
        }
        if rows.contains(where: { $0.failures > 0 }) {
            lines.append("")
            lines.append("Attention : un moteur avec des échecs a ses taux calculés sur moins de phrases que les autres ; "
                         + "la comparaison n'est exacte qu'entre moteurs sans échec.")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Rapport complet : le tableau, puis pour chaque ligne la liste des phrases fautives (référence et transcription),
    /// des échecs et des phrases exclues.
    static func markdownReport(corpus: [CorpusItem], runs: [EngineRun], vocabulary: [String]) -> String {
        var text = "# Transcription\n\n"
        text += "\(corpus.count) phrase(s). "
        text += vocabulary.isEmpty
            ? "Sans vocabulaire global.\n\n"
            : "Vocabulaire global (\(vocabulary.count) terme(s)) : \(vocabulary.joined(separator: ", ")).\n\n"
        text += markdownTable(summaries(corpus: corpus, runs: runs))
        text += "\nTaux d'erreur agrégé sur tous les mots du corpus ; phrases en échec ou sans voix hors de tout taux.\n"

        // Conditions de mesure, une fois par moteur, telles que chaque moteur les décrit.
        text += "\n## Conditions de mesure\n\n"
        text += "Chaque moteur est mesuré seul, phrase après phrase ; ses passes (sans puis avec vocabulaire) s'enchaînent "
        text += "avant le moteur suivant. Seul l'appel de transcription est chronométré.\n"
        var described: Set<String> = []
        for run in runs where described.insert(run.engine).inserted {
            text += "\n- **\(run.engine)** : \(oneLine(run.conditions))\n"
        }

        for run in runs {
            text += "\n## \(run.label)\n\n"
            var byID: [String: ItemResult] = [:]
            for result in run.results where byID[result.id] == nil { byID[result.id] = result }
            var lines: [String] = []
            for item in corpus {
                guard let result = byID[item.id] else { lines.append("- `\(item.id)` — aucun résultat"); continue }
                if !result.hasSpeech { lines.append("- `\(item.id)` — sans voix détectée, exclue"); continue }
                if let failure = result.failure { lines.append("- `\(item.id)` — échec : \(oneLine(failure))"); continue }
                let hypothesis = result.hypothesis ?? ""
                let counts = WordErrorRate.compute(reference: item.text, hypothesis: hypothesis)
                let missed = item.terms.filter { TermRecall.compute(terms: [$0], hypothesis: hypothesis).found == 0 }
                let errors = counts.substitutions + counts.deletions + counts.insertions
                guard errors > 0 || !missed.isEmpty else { continue }
                var line = "- `\(item.id)` — \(errors) erreur(s) sur \(counts.referenceCount) mot(s)"
                if !missed.isEmpty { line += ", terme(s) manqué(s) : \(missed.joined(separator: ", "))" }
                line += "\n  - référence : \(oneLine(item.text))\n  - transcription : \(oneLine(hypothesis))"
                lines.append(line)
            }
            text += lines.isEmpty ? "Aucune phrase fautive.\n" : lines.joined(separator: "\n") + "\n"
        }
        return text
    }

    /// Une synthèse par ligne de passage, remarque comprise.
    static func summaries(corpus: [CorpusItem], runs: [EngineRun]) -> [EngineSummary] {
        runs.map { run in
            var summary = summarize(engine: run.label, corpus: corpus, results: run.results)
            summary.note = run.note
            return summary
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private static func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }

    /// Une cellule de tableau Markdown tient sur une ligne et ne contient pas de « | » nu.
    private static func cell(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        let escaped = flat.replacingOccurrences(of: "|", with: "\\|")
        return escaped.count > 300 ? String(escaped.prefix(300)) + "…" : escaped
    }
}
