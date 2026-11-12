import Foundation

// MARK: - Durées d'un tour

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

    /// Le même tour avec un autre silence de fin de tour.
    func withSilence(_ silence: Double) -> TurnTiming {
        TurnTiming(silence: silence, transcription: transcription, firstSentence: firstSentence, synthesis: synthesis)
    }

    /// Noms des maillons dans `LatencySummary.medianByLink`, dans l'ordre du tour.
    static let links = ["silence", "transcription", "première phrase", "synthèse"]

    fileprivate var linkValues: [Double?] { [silence, transcription, firstSentence, synthesis] }
}

/// Synthèse d'une série d'essais. Les essais sans contenu, en échec et suspects de cache sont comptés, jamais moyennés.
struct LatencySummary: Equatable {
    /// Tous les essais : mesurés, sans contenu, en échec et suspects de cache.
    let runs: Int
    let noContent: Int
    let failed: Int
    let suspect: Int
    let medianTotal: Double?
    let p90Total: Double?
    /// Médiane de chaque maillon sur les seuls essais complets.
    let medianByLink: [String: Double]
    /// Objectif tenu si le 90e centile du total ne le dépasse pas. `nil` (non établi) sans aucun essai mesuré, ou
    /// quand les essais sans réponse (sans contenu ou en échec) dépassent `Reports.maxUnansweredShare` des essais :
    /// le tour du 90e centile peut alors être « pas de réponse », et les essais écartés sont sans doute les plus lents.
    let meetsTarget: Bool?

    /// Essais dont la durée entre dans les centiles.
    var measured: Int { runs - noContent - failed - suspect }
    /// Essais sans réponse : sans contenu ou en échec.
    var unanswered: Int { noContent + failed }
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

    var silence: Double { Double(silenceMs) / 1000 }

    /// Silence que coûterait en direct, avec le détecteur du banc, l'attente de `silenceMs` : lu dans le code de
    /// FluidAudio (`VadManager+Streaming.swift`), non mesuré. Le silence commence à compter à la fin de la première
    /// tranche jugée silencieuse, et la fin de tour tombe à la première fin de tranche où `silenceMs` est atteint, soit
    /// (1 + ⌈silence / pas⌉) × pas après le début de cette tranche. C'est un plancher : cette tranche est elle-même en
    /// retard sur la vraie fin de la voix (retard mesuré sur voix de synthèse seulement, non ajouté).
    var liveSilence: Double { (1 + (silence / detectorHop).rounded(.up)) * detectorHop }
}

extension Reports {
    /// Au-delà de cette part d'essais sans réponse, le verdict n'est pas établi.
    static let maxUnansweredShare = 0.10

    /// En dessous de ce nombre d'essais mesurés, le verdict est indicatif. Pour n essais, le plus lent dépasse le vrai
    /// 90e centile avec une probabilité 1 − 0,9ⁿ (essais indépendants, loi continue) : 0,65 pour n = 10, 0,9477 pour
    /// n = 28, 0,9529 pour n = 29 ; 29 est le plus petit n qui donne 95 %. Le p90 interpolé est plus bas encore : à
    /// n = 10, il se trouve entre la 9e et la 10e valeur, et la 9e tombe sous le vrai 90e centile avec une
    /// probabilité de 0,9¹⁰ + 10 × 0,9⁹ × 0,1 = 0,736 (la 10e : 0,349) ; il est donc sous le vrai 90e centile dans
    /// 35 à 74 % des séries selon la loi des durées, un biais vers « tenu ».
    static let minMeasuredForFirmVerdict = 29

    /// Les essais sans contenu (`total` nil), `failed` essais en échec et `suspect` essais suspects de cache sont
    /// comptés mais n'entrent ni dans les centiles ni dans les médianes par maillon. Le verdict porte sur le 90e
    /// centile du total, pas sur la médiane ; voir `LatencySummary.meetsTarget` pour le cas « non établi ».
    static func summarizeLatency(_ timings: [TurnTiming], failed: Int = 0, suspect: Int = 0,
                                 target: Double) -> LatencySummary {
        let complete = timings.filter { $0.total != nil }
        let totals = complete.compactMap(\.total)
        var byLink: [String: Double] = [:]
        for (index, name) in TurnTiming.links.enumerated() {
            if let median = percentile(complete.compactMap { $0.linkValues[index] }, 0.5) { byLink[name] = median }
        }
        let runs = timings.count + failed + suspect
        let noContent = timings.count - complete.count
        let p90 = percentile(totals, 0.9)
        let tooManyUnanswered = Double(noContent + failed) > maxUnansweredShare * Double(runs)
        return LatencySummary(runs: runs, noContent: noContent, failed: failed, suspect: suspect,
                              medianTotal: percentile(totals, 0.5), p90Total: p90, medianByLink: byLink,
                              meetsTarget: tooManyUnanswered ? nil : p90.map { $0 <= target })
    }

    /// Essais d'une série, par catégorie.
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

        func summary(target: Double, silence: Double? = nil) -> LatencySummary {
            let timings = measured + noContent
            return summarizeLatency(silence.map { s in timings.map { $0.withSilence(s) } } ?? timings,
                                    failed: failed, suspect: suspect, target: target)
        }
    }

    /// Le verdict en quelques lignes. Celui de tête compte la détection de fin de tour en direct (plancher calculé) ;
    /// le p90 brut, avec la constante de silence, suit. Le nombre d'essais mesurés est toujours donné, et le verdict
    /// est dit indicatif sous `minMeasuredForFirmVerdict` essais mesurés.
    static func latencyVerdict(settings: LatencySettings, trials: [LatencyTrial]) -> String {
        let counts = TrialCounts(trials)
        let live = counts.summary(target: settings.target, silence: settings.liveSilence)
        let raw = counts.summary(target: settings.target)
        let n = trials.count
        let target = decimal(settings.target, digits: 1)
        func state(_ met: Bool?) -> String {
            switch met {
            case true?: "objectif de \(target) s tenu"
            case false?: "objectif de \(target) s NON tenu"
            case nil: "objectif de \(target) s non établi"
            }
        }
        func figures(_ s: LatencySummary) -> String {
            guard let p90 = s.p90Total, let median = s.medianTotal else { return "aucun essai mesuré" }
            return "p90 \(decimal(p90, digits: 2)) s sur \(s.measured) essai(s) mesuré(s) sur \(n) (médiane "
                + "\(decimal(median, digits: 2)) s)"
        }

        var lines: [String] = []
        lines.append("\(n) essai(s) = \(live.measured) mesuré(s) + \(live.noContent) sans contenu + \(live.failed) en échec + "
                     + "\(live.suspect) suspect(s) de cache")

        var headline = "Verdict, détection de fin de tour en direct comptée (\(decimal(settings.liveSilence, digits: 2)) s "
            + "de silence au lieu de \(decimal(settings.silence, digits: 2)) s) : \(state(live.meetsTarget)) — \(figures(live))."
        if live.meetsTarget == nil, live.measured > 0 {
            headline += " Non établi : \(live.unanswered) essai(s) sur \(n) sans réponse (sans contenu ou en échec), plus "
                + "de \(Int(maxUnansweredShare * 100)) % ; le tour du 90e centile peut être « pas de réponse », et les "
                + "essais écartés sont sans doute les plus lents."
        }
        if live.measured > 0, live.measured < minMeasuredForFirmVerdict {
            headline += " Verdict indicatif : \(live.measured) essai(s) mesuré(s), moins de \(minMeasuredForFirmVerdict). "
                + "Le p90 de peu d'essais tombe le plus souvent sous le vrai 90e centile (à 10 essais, la 9e valeur y "
                + "est sous lui avec une probabilité de 0,74), et il faut \(minMeasuredForFirmVerdict) essais pour que "
                + "le plus lent le dépasse avec 95 % de confiance ; sur ce banc, deux séries de 10 essais aux mêmes "
                + "réglages ont donné deux verdicts opposés."
        }
        lines.append(headline)

        var rawLine = "p90 brut, silence constant de \(settings.silenceMs) ms : \(state(raw.meetsTarget)) — \(figures(raw))."
        if raw.meetsTarget != live.meetsTarget {
            rawLine += " Les deux verdicts diffèrent : seul le premier compte la détection en direct."
        }
        lines.append(rawLine)

        if Double(live.suspect) > maxUnansweredShare * Double(n) {
            lines.append("Attention : \(live.suspect) essai(s) sur \(n) suspect(s) de cache, plus de "
                         + "\(Int(maxUnansweredShare * 100)) % ; écartés, ils ne comptent pas dans la part sans réponse.")
        }
        lines.append(liveDetectionFloor(settings))
        let judged = n - counts.suspect
        let under = counts.measured.filter { $0.withSilence(settings.liveSilence).total! <= settings.target }.count
        lines.append("Essais sous l'objectif, détection en direct comptée, sans contenu et échecs comptés hors objectif, "
                     + "suspects de cache écartés : \(under) sur \(judged).")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Le plancher de détection en direct, en une phrase.
    static func liveDetectionFloor(_ settings: LatencySettings) -> String {
        "Détection en direct : avec ce détecteur (tranches de \(Int((settings.detectorHop * 1000).rounded())) ms ; lu "
            + "dans le code, non mesuré), attendre \(settings.silenceMs) ms de silence décide la fin de tour au plus tôt "
            + "\(decimal(settings.liveSilence, digits: 2)) s après le début de la tranche où il cesse d'entendre la "
            + "voix, soit \(decimal(settings.liveSilence - settings.silence, digits: 2)) s de plus que le silence "
            + "constant ; cette tranche est elle-même en retard sur la vraie fin (0,045 à 0,314 s mesurés sur voix de "
            + "synthèse seulement), retard non ajouté au chiffre."
    }

    /// Rapport `latence.md`.
    static func latencyMarkdown(settings: LatencySettings, recordings: [LatencyRecording], withoutSpeech: [String],
                                trials: [LatencyTrial]) -> String {
        let counts = TrialCounts(trials)
        let raw = counts.summary(target: settings.target)
        let live = counts.summary(target: settings.target, silence: settings.liveSilence)
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
        for name in TurnTiming.links { text += "| \(name) | \(s(raw.medianByLink[name])) |\n" }
        text += "| **total, silence constant** | \(s(raw.medianTotal)) |\n"
        text += "| **total, silence constant, 90e centile** | \(s(raw.p90Total)) |\n"
        text += "| **total, détection en direct comptée** | \(s(live.medianTotal)) |\n"
        text += "| **total, détection en direct comptée, 90e centile** | \(s(live.p90Total)) |\n"
        text += "\nLa somme des médianes par maillon n'est pas la médiane du total.\n"

        text += "\n## Ce qui est mesuré\n\n"
        text += "Pour chaque essai, sur un enregistrement : (1) la fin de la voix est repérée par le détecteur et le "
            + "clip est coupé à cet instant, hors chrono ; (2) **silence** : \(settings.silenceMs) ms ajoutées (le "
            + "verdict de tête les remplace par le plancher de détection en direct, \(s(settings.liveSilence)) s) ; "
            + "(3) **transcription** : durée de la transcription du clip coupé par le moteur local (préchargé et "
            + "préchauffé hors chrono) ; (4) **première phrase** : de l'envoi de la requête au modèle (consigne "
            + "d'intervieweur et transcription) à la première phrase complète rendue par le découpeur en phrases ; "
            + "(5) **synthèse** : durée de l'appel de synthèse de cette phrase, jusqu'au dernier octet de l'audio. "
            + "Les étapes s'enchaînent strictement, l'une après l'autre, et les essais aussi.\n\n"
        text += "Détecteur de voix : \(settings.detector).\n"

        text += "\n## Limites\n\nChaque limite dit dans quel sens la réalité s'écarte du chiffre de tête.\n\n"
        text += "- **Le silence de fin de tour est une constante ajoutée, pas une détection en direct.** Le chiffre de "
            + "tête la remplace par le plancher calculé de ce détecteur ; le retard propre du détecteur sur la vraie "
            + "fin de la voix n'y est pas ajouté (mesuré sur voix de synthèse seulement). Réalité **plus lente**.\n"
        text += "- **La transcription est mesurée en bloc sur la phrase entière, ce qui majore ce que donnera un moteur "
            + "en flux.** Réalité **plus rapide**.\n"
        text += "- Les étapes sont mesurées l'une après l'autre : une conversation réelle pourrait transcrire pendant "
            + "le silence de fin de tour. Réalité **plus rapide**.\n"
        text += "- La synthèse ne part qu'à la première phrase complète (c'est ce qui est mesuré). Le découpeur "
            + "attend le morceau suivant après un terminateur en bout de texte : une réponse d'une seule question est "
            + "chronométrée jusqu'à la fin du flux. Un découpage plus fin rendrait la réalité **plus rapide**.\n"
        text += "- La première phrase est celle que le découpeur rend, quelle qu'elle soit : un accusé de réception "
            + "court (« C'est noté. ») arrive et se synthétise plus vite qu'une question. Le premier son *utile* "
            + "peut donc venir plus tard : réalité **plus lente** pour le contenu. La colonne « Première phrase » du "
            + "détail permet de le voir.\n"
        text += "- La synthèse est attendue en entier (pas de lecture pendant le téléchargement) : une synthèse en "
            + "flux rendrait la réalité **plus rapide**. Le démarrage de la lecture audio n'est pas compté : réalité "
            + "**plus lente**.\n"
        text += "- La capture du micro et le tampon de l'annulation d'écho ne sont pas comptés : l'audio est lu dans "
            + "un fichier. Réalité **plus lente**.\n"
        text += "- Chaque requête de chat est un premier tour, sans historique : dans une vraie conversation, le "
            + "prompt grandit à chaque tour et le modèle met plus longtemps à le lire. Réalité **plus lente**.\n"
        text += "- Le flux de chat est arrêté dès la première phrase : la synthèse tourne seule. En vraie "
            + "conversation, la suite de la réponse continue d'arriver pendant la synthèse et lui dispute le réseau "
            + "et l'endpoint. Réalité **plus lente** (ampleur non mesurée).\n"
        text += "- Le clip est coupé à la fin de voix détectée, en retard sur la vraie fin. Un système en direct "
            + "transcrit lui aussi l'audio jusqu'à sa décision de fin de tour, qui vient encore plus tard : sur ce "
            + "point, la réalité n'est pas plus rapide, plutôt **très légèrement plus lente**.\n"
        text += "- Le premier essai ouvre la connexion à l'endpoint, les suivants la réutilisent, et les essais "
            + "s'enchaînent sans pause ; dans une vraie conversation, après une longue pause, la connexion peut être "
            + "fermée et le service de synthèse refroidi (un premier appel à plus d'1 s a été observé). Réalité "
            + "**plus lente** (non mesuré ici).\n"
        text += "- L'endpoint est partagé et sa charge varie d'une heure à l'autre : **sens inconnu**, les chiffres "
            + "valent pour le moment de la mesure.\n"
        text += "- Un modèle qui réfléchit avant de répondre peut épuiser les \(settings.maxTokens) jetons sans rien "
            + "dire : l'essai est alors « sans contenu », hors des centiles mais compté dans la part sans réponse. "
            + "Si ce plafond coupe des réponses qui seraient arrivées tard, réalité **plus lente**.\n"
        text += "- **Taille de l'échantillon** : le p90 calculé sur peu d'essais tombe le plus souvent sous le vrai 90e "
            + "centile (voir le verdict). Chiffre **optimiste** sous \(minMeasuredForFirmVerdict) essais mesurés.\n"

        text += "\n## Unicité des requêtes\n\n"
        text += "Observé : la passerelle de l'endpoint a rendu une requête de chat identique depuis son cache (toute "
            + "la réponse en un seul morceau, en une fraction du temps). Chaque requête de chat porte donc, à la fin "
            + "du message système, une référence aléatoire propre à l'essai ; une requête de chat identique à une "
            + "précédente arrête la commande.\n\n"
        text += "Synthèse : aucun cache n'a été constaté (un même texte, envoyé trois fois, a pris le même temps et "
            + "rendu des octets différents). Chaque texte envoyé est suivi d'espaces, en nombre choisi pour que la "
            + "requête ne figure pas au registre des requêtes déjà envoyées (empreintes conservées dans le dossier de "
            + "sortie, d'un lancement à l'autre). On ignore si la passerelle retire ces espaces avant de calculer sa "
            + "clé de cache : cette protection n'est donc pas prouvée.\n\n"
        text += "Repérage : un essai est « suspect de cache », compté à part et jamais moyenné, si sa première phrase "
            + "est arrivée entière dans le premier morceau de contenu (forme observée d'une réponse de chat sortie du "
            + "cache), ou si l'audio de sa synthèse est identique octet pour octet à celui d'un essai précédent du "
            + "lancement (deux synthèses du même texte ont toujours différé).\n"

        func section(_ title: String, _ lines: [String]) {
            text += "\n## \(title)\n\n" + (lines.isEmpty ? "Aucun.\n" : lines.joined(separator: "\n") + "\n")
        }
        section("Essais suspects de cache (écartés)", trials.compactMap { trial in
            guard case .suspectCache(let t, let reason) = trial.outcome else { return nil }
            return "- essai \(trial.number) (`\(trial.recording)`) : total \(s(t.total)) s, \(oneLine(reason)) : "
                + "« \(oneLine(trial.sentence ?? "")) »"
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

        text += "\n## Détail des essais\n\nTotaux avec le silence constant.\n\n"
        text += "| Essai | Enregistrement | État | Transcription (s) | Première phrase (s) | Synthèse (s) | Total (s) | "
            + "Morceaux | Transcription | Première phrase |\n|---|---|---|---|---|---|---|---|---|---|\n"
        for trial in trials {
            let state: String
            var timing: TurnTiming?
            switch trial.outcome {
            case .measured(let t): state = "mesuré"; timing = t
            case .noContent(let t, _): state = "sans contenu"; timing = t
            case .suspectCache(let t, _): state = "suspect de cache"; timing = t
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
