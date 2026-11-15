import Foundation
import SupervoxCore

/// Les textes de la vue de dictée : tout ce qui se décide sans dessiner.
public enum DictationText {
    /// Texte en direct : quatre lignes au plus à la largeur du panneau (une ligne tient environ 78 caractères en
    /// `callout`, relevé sur les images), avec la marge d'une coupe à une limite de mot. Choix de mise en page.
    public static let liveTextLimit = 260
    /// Dernier texte récupérable : trois lignes. Même nature.
    public static let transcriptLimit = 170
    /// Message sous le titre (raison d'un échec, d'une copie) : quatre lignes en `caption`.
    public static let detailLimit = 320

    private static let ellipsis = "…"

    /// `0:07`, `1:05` : minutes, puis secondes sur deux chiffres. Les secondes sont tronquées, pas arrondies ; une valeur
    /// négative ou non numérique donne `0:00`.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let whole = Int(seconds)
        return "\(whole / 60):" + String(format: "%02d", whole % 60)
    }

    /// La fin de `text`, au plus `maxCharacters` caractères préfixe compris, coupée à une limite de mot : « … » puis des
    /// mots entiers. Un texte qui tient est rendu tel quel. Sans aucune espace dans ce qui reste, la coupe est franche
    /// (« … » collé au texte) plutôt qu'un effacement.
    public static func tail(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        guard maxCharacters > ellipsis.count + 1 else { return ellipsis }
        let budget = maxCharacters - (ellipsis.count + 1)
        let kept = String(text.suffix(budget))
        // Le caractère juste avant la coupe : une espace veut dire que le premier mot gardé est entier.
        let before = text[text.index(text.endIndex, offsetBy: -budget - 1)]
        var words = Substring(kept)
        if !before.isWhitespace, let space = words.firstIndex(where: \.isWhitespace) {
            words = words[space...]
        } else if !before.isWhitespace {
            words = ""
        }
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ellipsis + String(text.suffix(maxCharacters - ellipsis.count)) }
        return ellipsis + " " + trimmed
    }

    /// Le début de `text`, au plus `maxCharacters` caractères suffixe compris, coupé à une limite de mot : des mots
    /// entiers puis « … ». Pour un message dont le début compte (la raison d'un échec).
    public static func head(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters else { return text }
        guard maxCharacters > ellipsis.count + 1 else { return ellipsis }
        let budget = maxCharacters - (ellipsis.count + 1)
        let kept = String(text.prefix(budget))
        let after = text[text.index(text.startIndex, offsetBy: budget)]
        var words = Substring(kept)
        if !after.isWhitespace, let space = words.lastIndex(where: \.isWhitespace) {
            words = words[..<space]
        } else if !after.isWhitespace {
            words = ""
        }
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(text.prefix(maxCharacters - ellipsis.count)) + ellipsis }
        return trimmed + " " + ellipsis
    }

    /// Le texte du bouton « Copier » ; un échec laisse « Copier » (on peut réessayer) et s'écrit à côté (`copyFailure`).
    public static func copyLabel(for state: CopyState) -> String {
        state == .copied ? "Copié" : "Copier"
    }

    /// Ce que le panneau dit quand le presse-papiers n'a pas accepté le texte.
    public static let copyFailure = "Copie impossible"

    /// Le libellé d'une phase, en mots simples. Il ne porte jamais le texte dicté.
    public static func status(for phase: DictationPhase) -> String {
        switch phase {
        case .idle: "Prêt"
        case .preparing: "Préparation…"
        case .recording: "Enregistrement"
        case .finalizing: "Transcription…"
        case .finished: "Texte copié"
        case .cancelled: "Dictée interrompue"
        case .failed(.noSpeech): "Rien à transcrire"
        case .failed(.microphone): "Micro indisponible"
        case .failed(.engine): "Transcription impossible"
        }
    }

    /// Les barres de la forme d'onde : toujours `count`, la plus ancienne à gauche, complétées de silence à gauche quand
    /// il y a moins de niveaux, les niveaux bornés à 0…1 (un niveau non numérique vaut 0).
    public static func bars(_ levels: [Float], count: Int = DictationViewState.levelCount) -> [Float] {
        let recent = levels.suffix(count).map { level -> Float in
            level.isNaN ? 0 : min(max(level, 0), 1)
        }
        return Array(repeating: 0, count: count - recent.count) + recent
    }
}

/// Ce que la vue de dictée montre pour un état et un dernier texte : décidé ici, dessiné par `DictationView`.
public struct DictationDisplay: Equatable, Sendable {
    /// Le ton du titre : choisit l'icône et la couleur.
    public enum Mood: Equatable, Sendable {
        case ready, info, working, recording, success, failure
    }

    /// Le dernier texte dicté, que l'on peut copier.
    public struct Transcript: Equatable, Sendable {
        /// « Dernière dictée » quand ce texte n'est pas celui de la dictée que le titre décrit ; `nil` sinon.
        public var label: String?
        /// La fin du texte, coupée pour tenir dans la carte ; le bouton « Copier » copie le texte entier.
        public var text: String
        /// Ce qu'a donné le dernier clic sur « Copier ».
        public var copy: CopyState
    }

    public var mood: Mood
    public var headline: String
    /// `0:07`, pendant l'enregistrement et la transcription.
    public var duration: String?
    /// Les barres de la forme d'onde, pendant l'enregistrement seulement.
    public var bars: [Float]?
    /// La fin du texte en direct, quand il y en a un.
    public var liveText: String?
    /// Le message sous le titre : téléchargement, vocabulaire, raison d'un échec ou d'une copie.
    public var detail: String?
    /// Le raccourci s'affiche sous « Prêt ».
    public var showsHotKey: Bool
    public var transcript: Transcript?

    /// - Parameters:
    ///   - transcript: le texte de la dernière dictée réussie (`DictationController.lastTranscript`).
    ///   - copy: ce qu'a donné le dernier clic sur « Copier » (`PanelModel.copyState`).
    public init(state: DictationViewState, transcript: String?, copy: CopyState = .idle) {
        let notice = state.notice.map { DictationText.head($0, maxCharacters: DictationText.detailLimit) }
        let phase = state.phase
        headline = DictationText.status(for: phase)
        duration = nil
        bars = nil
        liveText = nil
        detail = notice
        showsHotKey = false
        let live = Self.nonBlank(state.liveText).map {
            DictationText.tail($0, maxCharacters: DictationText.liveTextLimit)
        }

        switch phase {
        case .idle:
            if let notice {
                mood = .info
                headline = notice
                detail = nil
            } else {
                mood = .ready
                showsHotKey = true
            }
        case .preparing:
            mood = .working
        case .recording:
            mood = .recording
            duration = DictationText.duration(state.elapsed)
            bars = DictationText.bars(state.levels)
            liveText = live
        case .finalizing:
            mood = .working
            duration = DictationText.duration(state.elapsed)
            liveText = live
        case .finished:
            mood = .success
        case .cancelled:
            mood = .info
        case .failed:
            mood = .failure
        }

        // Le texte récupérable : jamais pendant une dictée. Après une copie, c'est le texte de cette dictée, sans étiquette.
        var phaseText: String?
        if case .finished(let text) = phase { phaseText = text }
        if !phase.isActive, let text = Self.nonBlank(transcript) ?? Self.nonBlank(phaseText) {
            let isThisDictation: Bool
            if case .finished = phase { isThisDictation = true } else { isThisDictation = false }
            self.transcript = Transcript(
                label: isThisDictation ? nil : "Dernière dictée",
                text: DictationText.tail(text, maxCharacters: DictationText.transcriptLimit), copy: copy)
        } else {
            self.transcript = nil
        }
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
