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
    /// Tous les essais lancés : mesurés, sans contenu, en échec et suspects de cache.
    let runs: Int
    let noContent: Int
    let failed: Int
    let suspect: Int
    /// Essais jugés ratés : mesurés au-dessus de la cible, sans contenu ou en échec.
    let missed: Int
    /// Chiffres descriptifs, sur les seuls essais mesurés : ils ne fondent pas le verdict.
    let medianTotal: Double?
    let p90Total: Double?
    /// Médiane de chaque maillon sur les seuls essais complets.
    let medianByLink: [String: Double]
    /// Verdict du test binomial exact (`Reports.binomialVerdict`) sur la part de tours ratés : `true` (tenu), `false`
    /// (non tenu), `nil` (non établi, et toujours quand aucun essai n'est jugé).
    let meetsTarget: Bool?

    /// Essais dont la durée est connue et qui entrent dans les chiffres descriptifs.
    var measured: Int { runs - noContent - failed - suspect }
    /// Essais sans réponse : sans contenu ou en échec. Comptés comme ratés.
    var unanswered: Int { noContent + failed }
    /// Essais jugés : tous sauf les suspects de cache.
    var judged: Int { runs - suspect }
}

/// Réglages d'une mesure de latence, recopiés dans le rapport.
struct LatencySettings {
    /// Étiquette de la configuration de transcription mesurée : `parakeet`, ou `parakeet+vocab` avec un vocabulaire.
    let engine: String
    /// Vocabulaire global donné au moteur (préchauffage et chaque transcription) ; vide sans `--vocabulary`.
    var vocabulary: [String] = []
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
    /// Part de tours ratés tolérée : « le 90e centile du tour est sous la cible » veut dire « au plus 10 % des tours
    /// ratent la cible ».
    static let toleratedMissShare = 0.10
    /// Risque d'erreur unilatéral du verdict (niveau de confiance 95 %).
    static let verdictRisk = 0.05

    /// P(X ≤ x) et P(X ≥ x) pour X ~ Binomiale(n, p), sommes exactes des probabilités ponctuelles calculées en
    /// logarithmes (pas de dépassement de capacité vers zéro pour un grand n).
    static func binomialTails(missed x: Int, judged n: Int, p: Double) -> (atMost: Double, atLeast: Double) {
        guard n > 0 else { return (1, 1) }
        var lnFact = [0.0]   // ln(k!) pour k = 0…n
        for k in 1...n { lnFact.append(lnFact[k - 1] + log(Double(k))) }
        func pmf(_ k: Int) -> Double {
            exp(lnFact[n] - lnFact[k] - lnFact[n - k] + Double(k) * log(p) + Double(n - k) * log(1 - p))
        }
        let atMost = (0...min(x, n)).reduce(0) { $0 + pmf($1) }
        let atLeast = x <= 0 ? 1 : (min(x, n + 1) <= n ? (x...n).reduce(0) { $0 + pmf($1) } : 0)
        return (min(atMost, 1), min(atLeast, 1))
    }

    /// Verdict sur `x` tours ratés parmi `n` jugés, test binomial exact unilatéral : « tenu » si l'on peut affirmer
    /// avec 95 % de confiance que moins de 10 % des tours ratent la cible (P(X ≤ x | n, 0,10) ≤ 0,05), « non tenu »
    /// si l'on peut affirmer que plus de 10 % la ratent (P(X ≥ x | n, 0,10) ≤ 0,05), `nil` sinon et quand n = 0.
    static func binomialVerdict(missed x: Int, judged n: Int) -> Bool? {
        guard n > 0 else { return nil }
        let tails = binomialTails(missed: x, judged: n, p: toleratedMissShare)
        if tails.atMost <= verdictRisk { return true }
        if tails.atLeast <= verdictRisk { return false }
        return nil
    }

    /// Pour `n` essais jugés : le plus grand nombre de ratés qui donne encore « tenu » (nil si même 0 ne suffit pas),
    /// et le plus petit qui donne « non tenu » (nil s'il n'y en a pas).
    static func verdictThresholds(judged n: Int) -> (maxMissedForMet: Int?, minMissedForNotMet: Int?) {
        guard n > 0 else { return (nil, nil) }
        let met = (0...n).last { binomialVerdict(missed: $0, judged: n) == true }
        let notMet = (0...n).first { binomialVerdict(missed: $0, judged: n) == false }
        return (met, notMet)
    }

    /// Plus petit nombre d'essais jugés, tous sans raté, qui permet « tenu ».
    static var minJudgedForMet: Int {
        var n = 1
        while binomialVerdict(missed: 0, judged: n) != true { n += 1 }
        return n
    }

    /// Les essais sans contenu (`total` nil) et `failed` essais en échec comptent comme ratés ; les `suspect` essais
    /// suspects de cache ne sont ni jugés ni ratés. Un essai mesuré est raté si son total dépasse `target`. Médianes et
    /// 90e centile sont descriptifs, sur les essais mesurés seulement.
    static func summarizeLatency(_ timings: [TurnTiming], failed: Int = 0, suspect: Int = 0,
                                 target: Double) -> LatencySummary {
        let complete = timings.filter { $0.total != nil }
        let totals = complete.compactMap(\.total)
        var byLink: [String: Double] = [:]
        for (index, name) in TurnTiming.links.enumerated() {
            if let median = percentile(complete.compactMap { $0.linkValues[index] }, 0.5) { byLink[name] = median }
        }
        let noContent = timings.count - complete.count
        let missed = totals.filter { $0 > target }.count + noContent + failed
        let judged = timings.count + failed
        return LatencySummary(runs: judged + suspect, noContent: noContent, failed: failed, suspect: suspect,
                              missed: missed, medianTotal: percentile(totals, 0.5), p90Total: percentile(totals, 0.9),
                              medianByLink: byLink, meetsTarget: binomialVerdict(missed: missed, judged: judged))
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
    /// le verdict brut, avec la constante de silence, suit, et la ligne dit quand les deux diffèrent. Chaque verdict
    /// donne les nombres qui le fondent ; un verdict non établi dit combien de ratés permettraient de conclure.
    static func latencyVerdict(settings: LatencySettings, trials: [LatencyTrial]) -> String {
        let counts = TrialCounts(trials)
        let live = counts.summary(target: settings.target, silence: settings.liveSilence)
        let raw = counts.summary(target: settings.target)
        let target = decimal(settings.target, digits: 1)
        let share = Int(toleratedMissShare * 100)
        func verdict(_ s: LatencySummary) -> String {
            let basis = "\(s.missed) essai(s) au-dessus de la cible ou sans réponse sur \(s.judged) jugé(s)"
            switch s.meetsTarget {
            case true?:
                return "objectif de \(target) s tenu — \(basis) ; à 95 %, si les essais étaient indépendants, moins de \(share) % des tours ratent la cible."
            case false?:
                return "objectif de \(target) s NON tenu — \(basis) ; à 95 %, si les essais étaient indépendants, plus de \(share) % des tours ratent la cible."
            case nil:
                guard s.judged > 0 else { return "objectif de \(target) s non établi — aucun essai jugé." }
                let limits = verdictThresholds(judged: s.judged)
                let met = limits.maxMissedForMet.map { "« tenu » exige au plus \($0) raté(s)" }
                    ?? "« tenu » est impossible, même sans raté (il faut au moins \(minJudgedForMet) essais jugés)"
                let notMet = limits.minMissedForNotMet.map { "« non tenu » au moins \($0) raté(s)" }
                    ?? "« non tenu » est impossible"
                return "objectif de \(target) s non établi — \(basis) ; ni l'un ni l'autre ne peut être affirmé à 95 % : "
                    + "avec \(s.judged) essai(s) jugé(s), \(met), \(notMet)."
            }
        }
        func figures(_ s: LatencySummary) -> String {
            guard let p90 = s.p90Total, let median = s.medianTotal else { return "—" }
            return "médiane \(decimal(median, digits: 2)) s, 90e centile \(decimal(p90, digits: 2)) s"
        }

        var lines: [String] = []
        lines.append("\(live.runs) essai(s) = \(live.measured) mesuré(s) + \(live.noContent) sans contenu + "
                     + "\(live.failed) en échec + \(live.suspect) suspect(s) de cache")
        lines.append("Verdict, détection de fin de tour en direct comptée (\(decimal(settings.liveSilence, digits: 2)) s "
                     + "de silence au lieu de \(decimal(settings.silence, digits: 2)) s) : \(verdict(live))")
        var rawLine = "Verdict brut, silence constant de \(settings.silenceMs) ms : \(verdict(raw))"
        if raw.meetsTarget != live.meetsTarget {
            rawLine += " Les deux verdicts diffèrent : seul le premier compte la détection en direct."
        }
        lines.append(rawLine)
        lines.append("Règle : test binomial exact unilatéral à 95 % sur la part de tours ratés (total au-dessus de la "
                     + "cible, sans contenu ou en échec), tolérance \(share) % ; les suspects de cache ne sont pas jugés. "
                     + "Le niveau de 95 % suppose des essais indépendants : ici ils s'enchaînent, à tour de rôle sur "
                     + "quelques enregistrements, contre un endpoint dont la charge varie, et cette hypothèse est "
                     + "probablement violée ; le niveau réel est inconnu.")
        if live.unanswered > 0 {
            lines.append("\(live.unanswered) essai(s) sans réponse (\(live.noContent) sans contenu, \(live.failed) en "
                         + "échec), comptés comme ratés dans le verdict.")
        }
        if Double(live.suspect) > toleratedMissShare * Double(live.runs) {
            lines.append("Attention : \(live.suspect) essai(s) sur \(live.runs) suspect(s) de cache, plus de \(share) % ; "
                         + "écartés, ils ne sont ni jugés ni comptés comme ratés.")
        }
        lines.append("Chiffres descriptifs sur les \(live.measured) essai(s) mesuré(s), qui ne fondent pas le verdict : "
                     + "détection en direct comptée, \(figures(live)) ; silence constant, \(figures(raw)).")
        lines.append(liveDetectionFloor(settings))
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
                                trials: [LatencyTrial], stopReason: String? = nil) -> String {
        let counts = TrialCounts(trials)
        let raw = counts.summary(target: settings.target)
        let live = counts.summary(target: settings.target, silence: settings.liveSilence)
        func s(_ value: Double?) -> String { value.map { decimal($0, digits: 2) } ?? "—" }

        var text = "# Latence de bout en bout\n\n"
        text += "Délai entre la fin de la parole et le premier son de la réponse. Moteur de transcription local "
            + "`\(settings.engine)`"
        text += settings.vocabulary.isEmpty ? " (sans vocabulaire)"
            : " (vocabulaire global de \(settings.vocabulary.count) terme(s), au préchauffage et à chaque transcription : "
                + "\(settings.vocabulary.joined(separator: ", ")))"
        text += " ; modèle de chat `\(settings.chatModel)` (au plus \(settings.maxTokens) jetons) ; "
            + "synthèse `\(settings.ttsModel)`, voix `\(settings.voice)`"
        let extras = settings.ttsExtra.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        text += extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))"
        text += " ; silence de fin de tour \(settings.silenceMs) ms ; objectif : au plus un tour sur dix au-dessus de "
            + "\(decimal(settings.target, digits: 1)) s (test binomial, voir le verdict). \(settings.runs) essai(s) à tour de rôle sur \(recordings.count) enregistrement(s) avec voix.\n\n"

        if let stopReason {
            text += "**Lancement arrêté avant la fin** : \(trials.count) essai(s) faits sur \(settings.runs) prévus. "
                + "Cause : \(oneLine(stopReason)). Le verdict ne porte que sur les essais faits.\n\n"
        }
        text += "## Verdict\n\n" + latencyVerdict(settings: settings, trials: trials)

        text += "\n## Médianes par maillon (essais mesurés)\n\n| Maillon | Médiane (s) |\n|---|---|\n"
        for name in TurnTiming.links { text += "| \(name) | \(s(raw.medianByLink[name])) |\n" }
        text += "| **total, silence constant** | \(s(raw.medianTotal)) |\n"
        text += "| **total, silence constant, 90e centile (descriptif, pas le verdict)** | \(s(raw.p90Total)) |\n"
        text += "| **total, détection en direct comptée** | \(s(live.medianTotal)) |\n"
        text += "| **total, détection en direct comptée, 90e centile (descriptif, pas le verdict)** | \(s(live.p90Total)) |\n"
        text += "\nChiffres descriptifs : le verdict ne porte pas sur ce 90e centile mais sur le nombre de tours ratés. "
            + "La somme des médianes par maillon n'est pas la médiane du total.\n"

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
            + "dire : l'essai est alors « sans contenu », hors des centiles mais compté comme raté. "
            + "Si ce plafond coupe des réponses qui seraient arrivées tard, réalité **plus lente**.\n"
        text += "- **Taille de l'échantillon et règle du verdict** : le verdict est un test binomial exact unilatéral "
            + "à 95 % sur la part de tours ratés (au-dessus de la cible, sans contenu ou en échec), tolérance "
            + "\(Int(toleratedMissShare * 100)) %. Avec peu d'essais, il reste « non établi » : « tenu » demande au "
            + "moins \(minJudgedForMet) essais jugés, tous sans raté. Le test suppose des essais indépendants et de même "
            + "loi ; la charge de l'endpoint varie dans le temps : **sens inconnu**.\n"

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
