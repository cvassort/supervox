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

// MARK: - Latence

/// Durées d'un tour de parole, en secondes : de la fin de la voix au premier son de la réponse.
struct TurnTiming: Equatable {
    /// Silence de fin de tour : constante ajoutée, pas une détection en direct.
    let silence: Double
    let transcription: Double
    /// De l'envoi au modèle à la première phrase complète ; `nil` si le modèle n'a rendu aucun texte.
    let firstSentence: Double?
    /// Synthèse de la première phrase ; `nil` si elle n'a pas eu lieu.
    let synthesis: Double?

    /// Somme des maillons ; `nil` si une étape n'a rien rendu.
    var total: Double? {
        guard let firstSentence, let synthesis else { return nil }
        return silence + transcription + firstSentence + synthesis
    }

    /// Noms des maillons dans `LatencySummary.medianByLink`, dans l'ordre du tour.
    static let links = ["silence", "transcription", "première phrase", "synthèse"]

    fileprivate var linkValues: [Double?] { [silence, transcription, firstSentence, synthesis] }
}

struct LatencySummary: Equatable {
    /// Essais résumés, sans contenu compris.
    let runs: Int
    let noContent: Int
    let medianTotal: Double?
    let p90Total: Double?
    /// Médiane de chaque maillon sur les seuls essais complets.
    let medianByLink: [String: Double]
    /// Objectif tenu si le 90e centile du total ne le dépasse pas ; `nil` sans aucun essai complet.
    let meetsTarget: Bool?
}

/// Réglages d'une mesure de latence, recopiés dans le rapport.
struct LatencySettings {
    let engine: String
    let chatModel: String
    let ttsModel: String
    let voice: String
    let ttsExtra: [String: String]
    let silenceMs: Int
    let target: Double
    let maxTokens: Int
    let runs: Int
    /// Description du détecteur de voix et de ses réglages.
    let detector: String
    /// Pas du détecteur de voix, en secondes.
    let detectorHop: Double
}

extension Reports {
    /// Les essais sans contenu sont comptés mais n'entrent ni dans les centiles ni dans les médianes par maillon.
    /// Le verdict porte sur le 90e centile du total, pas sur la médiane.
    static func summarizeLatency(_ timings: [TurnTiming], target: Double) -> LatencySummary {
        let complete = timings.filter { $0.total != nil }
        let totals = complete.compactMap(\.total)
        var byLink: [String: Double] = [:]
        for (index, name) in TurnTiming.links.enumerated() {
            if let median = percentile(complete.compactMap { $0.linkValues[index] }, 0.5) { byLink[name] = median }
        }
        let p90 = percentile(totals, 0.9)
        return LatencySummary(runs: timings.count, noContent: timings.count - complete.count,
                              medianTotal: percentile(totals, 0.5), p90Total: p90, medianByLink: byLink,
                              meetsTarget: p90.map { $0 <= target })
    }

    /// Comptes d'une série d'essais par catégorie.
    private struct TrialCounts {
        var measured: [TurnTiming] = []
        var noContent: [TurnTiming] = []
        var suspect = 0
        var failed = 0
        init(_ trials: [LatencyTrial]) {
            for trial in trials {
                switch trial.outcome {
                case .measured(let t): measured.append(t)
                case .noContent(let t, _): noContent.append(t)
                case .suspectCache: suspect += 1
                case .failed: failed += 1
                }
            }
        }
    }

    /// Le verdict en quelques lignes, avec le décompte des essais : un verdict tenu sur une partie seulement des essais
    /// ne doit pas se lire comme un verdict sur tous.
    static func latencyVerdict(settings: LatencySettings, trials: [LatencyTrial]) -> String {
        let counts = TrialCounts(trials)
        let summary = summarizeLatency(counts.measured + counts.noContent, target: settings.target)
        let measured = counts.measured.count
        var lines: [String] = []
        lines.append("\(trials.count) essai(s) = \(measured) mesuré(s) + \(counts.noContent.count) sans contenu + "
                     + "\(counts.failed) en échec + \(counts.suspect) suspect(s) de cache")
        let target = decimal(settings.target, digits: 1)
        switch summary.meetsTarget {
        case nil:
            lines.append("Verdict : non établi, aucun essai mesuré.")
        case let met?:
            lines.append("Verdict : objectif de \(target) s \(met ? "tenu" : "NON tenu") — p90 sur \(measured) essai(s) "
                         + "mesuré(s) sur \(trials.count) : \(decimal(summary.p90Total!, digits: 2)) s (médiane "
                         + "\(decimal(summary.medianTotal!, digits: 2)) s).")
        }
        if measured < trials.count {
            lines.append("Attention : \(trials.count - measured) essai(s) sur \(trials.count) sans durée retenue. Un tour "
                         + "sans réponse est un échec de la conversation : le verdict ne porte que sur les essais mesurés.")
        }
        lines.append(liveDetectionFloor(settings))
        // Lecture prudente : sans contenu et échecs comptés hors objectif ; suspects de cache hors du compte.
        let judged = trials.count - counts.suspect
        let under = counts.measured.filter { $0.total! <= settings.target }.count
        lines.append("Essais sous l'objectif, sans contenu et échecs comptés hors objectif, suspects de cache écartés : "
                     + "\(under) sur \(judged).")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Ce que coûterait en direct, avec le détecteur du banc, l'attente du silence de fin de tour. Lu dans le code de
    /// FluidAudio (`VadManager+Streaming.swift`), non mesuré : le silence commence à compter à la fin de la première
    /// tranche jugée silencieuse, et la fin de tour tombe à la première fin de tranche où `silenceMs` est atteint, soit
    /// (1 + ⌈silence / pas⌉) × pas après le début de cette tranche, qui est elle-même après la vraie fin de la voix.
    static func liveDetectionFloor(_ settings: LatencySettings) -> String {
        let silence = Double(settings.silenceMs) / 1000
        let hop = settings.detectorHop
        let floor = (1 + (silence / hop).rounded(.up)) * hop
        return "Avec ce détecteur en direct (tranches de \(Int((hop * 1000).rounded())) ms ; lu dans le code, non "
            + "mesuré), attendre \(settings.silenceMs) ms de silence décide la fin de tour au plus tôt "
            + "\(decimal(floor, digits: 2)) s après le début de la tranche où il cesse d'entendre la voix, tranche "
            + "elle-même en retard sur la vraie fin : au moins \(decimal(floor - silence, digits: 2)) s de plus que "
            + "le silence compté ici."
    }

    /// Rapport `latence.md`.
    static func latencyMarkdown(settings: LatencySettings, recordings: [LatencyRecording], withoutSpeech: [String],
                                trials: [LatencyTrial]) -> String {
        let counts = TrialCounts(trials)
        let summary = summarizeLatency(counts.measured + counts.noContent, target: settings.target)
        func s(_ value: Double?) -> String { value.map { decimal($0, digits: 2) } ?? "—" }

        var text = "# Latence de bout en bout\n\n"
        text += "Délai entre la fin de la parole et le premier son de la réponse. Moteur de transcription local "
            + "`\(settings.engine)` ; modèle de chat `\(settings.chatModel)` (au plus \(settings.maxTokens) jetons) ; "
            + "synthèse `\(settings.ttsModel)`, voix `\(settings.voice)`"
        let extras = settings.ttsExtra.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        text += extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))"
        text += " ; silence de fin de tour \(settings.silenceMs) ms ; objectif \(decimal(settings.target, digits: 1)) s "
            + "au 90e centile. \(settings.runs) essai(s) à tour de rôle sur \(recordings.count) enregistrement(s) avec voix.\n\n"

        text += "## Verdict\n\n" + latencyVerdict(settings: settings, trials: trials)

        text += "\n## Médianes par maillon (essais mesurés)\n\n| Maillon | Médiane (s) |\n|---|---|\n"
        for name in TurnTiming.links { text += "| \(name) | \(s(summary.medianByLink[name])) |\n" }
        text += "| **total** | \(s(summary.medianTotal)) |\n| **total, 90e centile** | \(s(summary.p90Total)) |\n"
        text += "\nLa somme des médianes par maillon n'est pas la médiane du total.\n"

        text += "\n## Ce qui est mesuré\n\n"
        text += "Pour chaque essai, sur un enregistrement : (1) la fin de la voix est repérée par le détecteur et le "
            + "clip est coupé à cet instant, hors chrono ; (2) **silence** : \(settings.silenceMs) ms ajoutées ; "
            + "(3) **transcription** : durée de la transcription du clip coupé par le moteur local (préchargé et "
            + "préchauffé hors chrono) ; (4) **première phrase** : de l'envoi de la requête au modèle (consigne "
            + "d'intervieweur et transcription) à la première phrase complète rendue par le découpeur en phrases ; "
            + "(5) **synthèse** : durée de l'appel de synthèse de cette phrase, jusqu'au dernier octet de l'audio. "
            + "Les étapes s'enchaînent strictement, l'une après l'autre, et les essais aussi.\n\n"
        text += "Détecteur de voix : \(settings.detector).\n"

        text += "\n## Limites\n\n"
        text += "- **Le silence de fin de tour est une constante ajoutée, pas une détection en direct.** "
            + liveDetectionFloor(settings) + " Rend la réalité **plus lente** que ce chiffre.\n"
        text += "- **La transcription est mesurée en bloc sur la phrase entière, ce qui majore ce que donnera un moteur "
            + "en flux.** Rend la réalité **plus rapide**.\n"
        text += "- Les étapes sont mesurées l'une après l'autre : une conversation réelle pourrait transcrire pendant "
            + "le silence de fin de tour. Réalité **plus rapide**.\n"
        text += "- La synthèse ne part qu'à la première phrase complète (c'est ce qui est mesuré). Le découpeur "
            + "attend le morceau suivant après un terminateur en bout de texte : une réponse d'une seule question est "
            + "chronométrée jusqu'à la fin du flux. Un découpage plus fin rendrait la réalité **plus rapide**.\n"
        text += "- La première phrase est celle que le découpeur rend, quelle qu'elle soit : un accusé de réception "
            + "court (« C'est noté. ») arrive et se synthétise plus vite qu'une question. Le premier son *utile* "
            + "peut donc venir plus tard que ce chiffre : réalité **plus lente** pour le contenu. La colonne « Première "
            + "phrase » du détail permet de le voir.\n"
        text += "- La synthèse est attendue en entier (pas de lecture pendant le téléchargement) : une synthèse en "
            + "flux rendrait la réalité **plus rapide**. Le démarrage de la lecture audio n'est pas compté : réalité "
            + "**plus lente**.\n"
        text += "- Le clip est coupé à la fin de voix détectée, toujours en retard sur la vraie fin (jusqu'à 0,31 s "
            + "mesurés sur voix de synthèse) : la transcription porte sur un peu de silence en plus. Réalité très "
            + "légèrement **plus rapide**.\n"
        text += "- Le premier essai ouvre la connexion à l'endpoint, les suivants la réutilisent ; dans une vraie "
            + "conversation, après une longue pause, elle peut être fermée. Réalité possiblement **plus lente** "
            + "(non mesuré).\n"
        text += "- L'endpoint est partagé : sa charge varie d'une heure à l'autre. Les chiffres valent pour le moment "
            + "de la mesure.\n"
        text += "- Un modèle qui réfléchit avant de répondre peut épuiser les \(settings.maxTokens) jetons sans "
            + "rien dire : l'essai est alors « sans contenu ».\n"

        text += "\n## Unicité des requêtes\n\n"
        text += "La passerelle de l'endpoint rend une requête identique depuis son cache (observé : toute la réponse "
            + "en un seul morceau, en une fraction du temps). Chaque requête de chat porte, à la fin du message "
            + "système, une référence aléatoire propre à l'essai ; chaque texte envoyé à la synthèse est suivi d'un "
            + "nombre d'espaces propre à l'essai (décalage aléatoire par lancement + numéro de l'essai), ce qui ne "
            + "change pas ce qui est dit. Une requête identique à une précédente arrête la commande. Un essai dont la "
            + "première phrase est arrivée entière dans le premier morceau de contenu a la forme d'une réponse sortie "
            + "du cache : il est compté à part, jamais moyenné.\n"

        func section(_ title: String, _ lines: [String]) {
            text += "\n## \(title)\n\n" + (lines.isEmpty ? "Aucun.\n" : lines.joined(separator: "\n") + "\n")
        }
        section("Essais suspects de cache (écartés)", trials.compactMap { trial in
            guard case .suspectCache(let t) = trial.outcome else { return nil }
            return "- essai \(trial.number) (`\(trial.recording)`) : total \(s(t.total)) s, première phrase "
                + "\(s(t.firstSentence)) s en un seul morceau : « \(oneLine(trial.sentence ?? "")) »"
        })
        section("Essais sans contenu", trials.compactMap { trial in
            guard case .noContent(_, let reason) = trial.outcome else { return nil }
            return "- essai \(trial.number) (`\(trial.recording)`) : \(oneLine(reason))"
        })
        section("Essais en échec", trials.compactMap { trial in
            guard case .failed(let stage, let message) = trial.outcome else { return nil }
            return "- essai \(trial.number) (`\(trial.recording)`), étape \(stage.rawValue) : \(oneLine(message))"
        })

        text += "\n## Enregistrements\n\n| Enregistrement | Durée (s) | Fin de voix détectée (s) |\n|---|---|---|\n"
        for recording in recordings {
            text += "| \(cell(recording.id)) | \(s(recording.duration)) | \(s(recording.speechEnd)) |\n"
        }
        if !withoutSpeech.isEmpty {
            text += "\nSans voix détectée, non mesurés : \(withoutSpeech.map { "`\($0)`" }.joined(separator: ", ")).\n"
        }

        text += "\n## Détail des essais\n\n"
        text += "| Essai | Enregistrement | État | Transcription (s) | Première phrase (s) | Synthèse (s) | Total (s) | "
            + "Morceaux | Transcription | Première phrase |\n|---|---|---|---|---|---|---|---|---|---|\n"
        for trial in trials {
            let state: String
            var timing: TurnTiming?
            switch trial.outcome {
            case .measured(let t): state = "mesuré"; timing = t
            case .noContent(let t, _): state = "sans contenu"; timing = t
            case .suspectCache(let t): state = "suspect de cache"; timing = t
            case .failed(let stage, _): state = "échec (\(stage.rawValue))"
            }
            let cells = ["\(trial.number)", trial.recording, state, s(timing?.transcription), s(timing?.firstSentence),
                         s(timing?.synthesis), s(timing?.total), trial.contentChunks.map(String.init) ?? "—",
                         trial.transcript ?? "—", trial.sentence ?? "—"]
            text += "| " + cells.map(cell).joined(separator: " | ") + " |\n"
        }
        return text
    }
}
