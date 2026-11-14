import Foundation
import Observation
import SupervoxCore

/// Ton d'un message de l'onglet Transcription.
public enum TranscriptionMessageKind: Equatable, Sendable {
    /// Une information (la suppression d'un modèle utilisé).
    case info
    /// Une saisie acceptée, avec une réserve.
    case warning
    /// Un refus ou un échec : rien n'a changé.
    case error
}

/// Où l'onglet montre le message : à côté du champ de vocabulaire (refus, réserve, échec d'enregistrement du vocabulaire),
/// ou dans le bandeau général en haut.
public enum TranscriptionMessageArea: Equatable, Sendable {
    case general
    case vocabulary
}

/// Ce qu'est devenue une saisie de vocabulaire.
public enum VocabularyOutcome: Equatable, Sendable {
    /// Enregistré (peut-être mis en forme : lignes vides et doublons retirés).
    case saved
    /// Rien à changer : la liste saisie est déjà l'enregistrée.
    case unchanged
    /// Refusé : trop long pour le modèle. L'ancienne liste est gardée.
    case refused
    /// L'enregistrement des réglages a échoué. L'ancienne liste est gardée.
    case notSaved
    /// Une saisie plus récente a pris la place pendant le comptage.
    case superseded
}

/// La transcription telle que la fenêtre de réglages la montre et la change : moteur, modèle, langue, vocabulaire, et
/// les modèles locaux à télécharger ou supprimer.
///
/// `settings` reflète toujours ce qui est enregistré : il ne change qu'après un `save` réussi ; si `save` lève, la
/// valeur affichée revient à l'ancienne et `message` dit pourquoi. Les téléchargements en cours et les échecs de cette
/// session vivent ici, par-dessus la liste du catalogue (qui reflète le disque) : un `refresh` ne les efface pas, mais un
/// modèle que le disque dit prêt n'est jamais montré en échec.
@MainActor @Observable
public final class TranscriptionModel {
    public typealias Save = @MainActor (TranscriptionSettings) throws -> Void

    /// Langues proposées (codes de langue passés au moteur), dans l'ordre d'affichage.
    public static let languages: [(code: String, name: String)] = [
        ("fr", "Français"), ("en", "Anglais"), ("es", "Espagnol"), ("de", "Allemand"), ("it", "Italien"),
        ("pt", "Portugais"), ("nl", "Néerlandais"),
    ]

    public private(set) var settings: TranscriptionSettings
    public private(set) var message: String?
    public private(set) var messageKind: TranscriptionMessageKind = .info
    public private(set) var messageArea: TranscriptionMessageArea = .general
    /// Les modèles du catalogue, avec les téléchargements en cours et les échecs de cette session par-dessus.
    public var models: [LocalModel] {
        listed.map { model in
            var model = model
            if let override = overrides[model.id] {
                model.state = override
            } else if let failure = failures[model.id] {
                model.state = .failed(failure)
            }
            return model
        }
    }

    private var listed: [LocalModel] = []
    /// Téléchargement en cours (`downloading`), par identifiant de modèle.
    private var overrides: [String: LocalModel.State] = [:]
    /// Dernier échec de téléchargement, par identifiant de modèle, jusqu'au prochain essai.
    private var failures: [String: String] = [:]
    @ObservationIgnored private var recheckGeneration = 0
    @ObservationIgnored private var recheckTask: Task<Void, Never>?
    /// Vrai une fois la liste lue au moins une fois (même vide).
    public private(set) var hasListed = false
    @ObservationIgnored private var vocabularyGeneration = 0
    @ObservationIgnored private let catalog: any ModelCatalog
    @ObservationIgnored private let promptTokenLimit: Int
    @ObservationIgnored private let save: Save

    /// `promptTokenLimit` : taille maximale de la liste de vocabulaire que Whisper accepte, dans l'unité de son tokenizer
    /// (`WhisperKitTranscriber.promptTokenLimit`) ; l'interface dit « morceaux de mots ».
    /// `save` enregistre les réglages de transcription complets ; s'il lève, rien ne change en mémoire.
    public init(
        settings: TranscriptionSettings, catalog: any ModelCatalog, promptTokenLimit: Int, save: @escaping Save
    ) {
        self.settings = settings
        self.catalog = catalog
        self.promptTokenLimit = promptTokenLimit
        self.save = save
    }

    /// Le vocabulaire enregistré, un terme par ligne : ce que le champ de saisie montre.
    public var vocabularyText: String { settings.vocabulary.joined(separator: "\n") }

    // MARK: - Modèles locaux

    public func refresh() async {
        listed = await catalog.models()
        hasListed = true
        // Un modèle que le disque dit prêt n'est plus en échec (le moteur l'a peut-être téléchargé entre-temps).
        for model in listed where model.state == .ready { failures[model.id] = nil }
    }

    /// Les variantes WhisperKit de la liste, dans l'ordre du catalogue.
    public var whisperModels: [LocalModel] { models.filter { Self.whisperVariant(of: $0) != nil } }

    /// Le nom de variante WhisperKit d'une ligne de la liste, `nil` pour les autres modèles.
    public static func whisperVariant(of model: LocalModel) -> String? { LocalModelID.whisperVariant(of: model.id) }

    /// Un bouton d'une ligne de la liste.
    public struct RowAction: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case download, delete }
        public let kind: Kind
        public let label: String
    }

    /// Les boutons que l'état permet : télécharger, supprimer, les deux pour un modèle incomplet, réessayer (et supprimer
    /// ce qui reste) après un échec, aucun pendant un téléchargement.
    public static func actions(for state: LocalModel.State) -> [RowAction] {
        let download = RowAction(kind: .download, label: "Télécharger")
        let delete = RowAction(kind: .delete, label: "Supprimer…")
        switch state {
        case .absent: return [download]
        case .incomplete: return [delete, download]
        case .ready: return [delete]
        case .failed: return [RowAction(kind: .download, label: "Réessayer"), delete]
        case .downloading: return []
        }
    }

    public static func stateLabel(_ state: LocalModel.State) -> String {
        switch state {
        case .absent: "Non téléchargé"
        case .incomplete: "Incomplet : des fichiers manquent"
        case .ready: "Prêt"
        case .downloading(let fraction?): "Téléchargement : \(Int((min(max(fraction, 0), 1) * 100).rounded())) %"
        case .downloading(nil): "Téléchargement en cours…"
        case .failed(let reason): reason
        }
    }

    /// Lance le téléchargement. Sans effet si ce modèle est déjà en cours de téléchargement. Une fois le modèle Whisper
    /// choisi téléchargé, le vocabulaire est recompté (il a pu être accepté sans pouvoir l'être).
    public func download(_ id: String) async {
        if case .downloading? = overrides[id] { return }
        overrides[id] = .downloading(nil)
        failures[id] = nil
        clearMessage()
        var succeeded = false
        do {
            try await catalog.download(id) { [weak self] fraction in
                Task { @MainActor in self?.progress(fraction, of: id) }
            }
            succeeded = true
        } catch {
            failures[id] = "Le téléchargement a échoué : \(Self.describe(error))"
        }
        // La liste est relue avant de lâcher l'état « en cours » : la ligne ne passe jamais par un état périmé.
        await refresh()
        overrides[id] = nil
        if succeeded, id == LocalModelID.whisper(settings.whisperModel) { await recheckVocabulary() }
    }

    /// Une fraction donnée par la bibliothèque. Elle ne recule jamais (les rapports peuvent arriver dans le désordre) et
    /// un rapport tardif ne ressuscite pas un téléchargement fini.
    private func progress(_ fraction: Double, of id: String) {
        guard case .downloading(let current)? = overrides[id] else { return }
        let fraction = min(max(fraction, 0), 1)
        if let current, fraction < current { return }
        overrides[id] = .downloading(fraction)
    }

    /// Supprime le modèle (même incomplet). Permis même si la dictée l'utilise : le message prévient alors que la prochaine
    /// dictée le téléchargera de nouveau. Refusé pendant son téléchargement.
    public func delete(_ id: String) async {
        if case .downloading? = overrides[id] { return }
        clearMessage()
        let wasReady = models.first { $0.id == id }?.state == .ready
        do {
            try await catalog.delete(id)
        } catch {
            show("La suppression a échoué : \(Self.describe(error))", .error)
            return
        }
        failures[id] = nil
        await refresh()
        if wasReady, isUsedByDictation(id) { show(Self.redownloadWarning(for: id), .info) }
    }

    /// Vrai si le moteur choisi dans les réglages dicte avec ce modèle.
    public func isUsedByChosenEngine(_ id: String) -> Bool {
        switch settings.engine {
        case "parakeet": id == LocalModelID.parakeet
        default: id == LocalModelID.whisper(settings.whisperModel)
        }
    }

    /// Vrai si une dictée a besoin de ce modèle : Parakeet (l'aperçu en direct, quel que soit le moteur final) et le
    /// détecteur de voix toujours, une variante Whisper seulement si c'est celle du moteur choisi.
    public func isUsedByDictation(_ id: String) -> Bool {
        switch id {
        case LocalModelID.parakeet, LocalModelID.voiceDetector: true
        default: id == LocalModelID.whisper(settings.whisperModel)
        }
    }

    /// Parakeet et le détecteur de voix vivent dans le dossier de FluidAudio, partagé avec les autres applications qui
    /// utilisent cette bibliothèque (`MLModelConfigurationUtils.defaultModelsDirectory`, Application Support/FluidAudio).
    private static func isInSharedFolder(_ id: String) -> Bool {
        id == LocalModelID.parakeet || id == LocalModelID.voiceDetector
    }

    private static func redownloadWarning(for id: String) -> String {
        let consequence = "la prochaine dictée le téléchargera de nouveau, ce qui peut prendre un moment."
        switch id {
        case LocalModelID.parakeet: return "Parakeet sert à l'aperçu du texte pendant que vous parlez : \(consequence)"
        case LocalModelID.voiceDetector: return "Le détecteur de voix sert à chaque dictée : \(consequence)"
        default: return "Ce modèle est celui du moteur choisi : \(consequence)"
        }
    }

    /// Le texte de la confirmation de suppression : il dit quand les fichiers sont partagés avec d'autres applications, et ce
    /// que la prochaine dictée fera.
    public func deletionConfirmation(for model: LocalModel) -> String {
        var sentences: [String] = []
        if Self.isInSharedFolder(model.id) {
            sentences.append(
                "Ces fichiers sont rangés dans le dossier de FluidAudio, la bibliothèque audio qu'utilise Supervox : ce dossier est partagé avec les autres applications qui l'utilisent sur ce Mac, et elles devront aussi les télécharger de nouveau.")
        }
        if isUsedByDictation(model.id) {
            sentences.append(
                Self.isInSharedFolder(model.id)
                    ? "Supervox les téléchargera de nouveau à la prochaine dictée."
                    : "C'est le modèle du moteur choisi : la prochaine dictée devra le télécharger de nouveau.")
        } else {
            sentences.append("Vous pourrez le télécharger de nouveau plus tard.")
        }
        return sentences.joined(separator: " ")
    }

    // MARK: - Réglages

    public func setEngine(_ engine: String) {
        guard TranscriptionSettings.knownEngines.contains(engine) else { return }
        let changedToWhisperKit = engine == "whisperkit" && settings.engine != "whisperkit"
        // Seul WhisperKit a une limite de longueur : le passage à ce moteur recompte la liste.
        if change({ $0.engine = engine }), changedToWhisperKit { scheduleRecheck() }
    }

    public func setWhisperModel(_ model: String) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        if change({ $0.whisperModel = model }) { scheduleRecheck() }
    }

    public func setLanguage(_ language: String) {
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty else { return }
        change { $0.language = language }
    }

    /// Un terme par ligne ; lignes vides et doublons retirés. Refusé si la liste est trop longue pour Whisper : l'ancienne
    /// liste est gardée et le résultat le dit, pour que la vue garde ce que l'utilisateur a tapé.
    @discardableResult
    public func setVocabulary(text: String) async -> VocabularyOutcome {
        let terms = Self.terms(in: text)
        vocabularyGeneration += 1
        let generation = vocabularyGeneration
        guard terms != settings.vocabulary else { return .unchanged }

        var warning: String?
        if !terms.isEmpty {
            let count = await catalog.promptTokenCount(terms, whisperModel: settings.whisperModel)
            // Une saisie plus récente a pris la place pendant le comptage.
            guard generation == vocabularyGeneration else { return .superseded }
            if let count {
                guard count <= promptTokenLimit else {
                    show(tooLongMessage(count: count, ending: "L'ancien vocabulaire est conservé : retirez des termes ou raccourcissez-les."), .error, in: .vocabulary)
                    return .refused
                }
            } else if settings.engine == "whisperkit" {
                warning = Self.modelAbsentWarning
            }
        }
        guard change({ $0.vocabulary = terms }, in: .vocabulary) else { return .notSaved }
        if let warning { show(warning, .warning, in: .vocabulary) }
        return .saved
    }

    private static let modelAbsentWarning =
        "Vocabulaire enregistré. Le modèle Whisper n'est pas encore sur ce Mac : la limite de longueur de la liste sera vérifiée dès qu'il sera téléchargé."

    /// Le refus pour une liste trop longue. L'unité est celle du tokenizer de Whisper (`promptTokenLimit`) : l'interface dit
    /// « morceaux de mots », sans jargon et sans la confondre avec des mots entiers.
    private func tooLongMessage(count: Int, ending: String) -> String {
        let whisper = "Vocabulaire trop long pour Whisper : votre liste équivaut à \(count) morceaux de mots et le modèle en accepte \(promptTokenLimit) au plus (un terme long ou rare en compte plusieurs)."
        if settings.engine == "parakeet" {
            return "Vocabulaire trop long pour WhisperKit : votre liste équivaut à \(count) morceaux de mots et Whisper en accepte \(promptTokenLimit) au plus. Parakeet n'a pas cette limite, mais la liste est la même pour les deux moteurs. \(ending)"
        }
        return "\(whisper) \(ending)"
    }

    // MARK: - Recomptage du vocabulaire

    private func scheduleRecheck() {
        recheckTask = Task { await self.recheckVocabulary() }
    }

    /// Les tests attendent ici le recomptage lancé par un changement de moteur ou de modèle.
    func waitForRecheck() async { await recheckTask?.value }

    /// Recompte le vocabulaire enregistré avec le modèle Whisper choisi : après le téléchargement de ce modèle, un changement
    /// de modèle ou le passage à WhisperKit. Une liste devenue trop longue est signalée, jamais effacée. Sans effet si la liste
    /// est vide.
    private func recheckVocabulary() async {
        guard !settings.vocabulary.isEmpty else { return }
        recheckGeneration += 1
        let generation = recheckGeneration
        let terms = settings.vocabulary
        let model = settings.whisperModel
        let count = await catalog.promptTokenCount(terms, whisperModel: model)
        guard generation == recheckGeneration, terms == settings.vocabulary, model == settings.whisperModel else { return }
        if let count, count > promptTokenLimit {
            show(
                tooLongMessage(
                    count: count,
                    ending: "Votre vocabulaire est conservé tel quel, mais WhisperKit ne pourra pas l'utiliser tant que la liste n'est pas raccourcie."),
                .error, in: .vocabulary)
        } else if count == nil, settings.engine == "whisperkit" {
            show(Self.modelAbsentWarning, .warning, in: .vocabulary)
        }
    }

    /// Ce que le champ de vocabulaire montre après une saisie : la liste enregistrée (mise en forme) si elle a été enregistrée
    /// ou n'avait pas à changer et que l'utilisateur n'a rien tapé depuis ; sinon son propre texte, jamais effacé.
    public static func fieldText(
        afterSubmitting submitted: String, outcome: VocabularyOutcome, current: String, saved: String
    ) -> String {
        switch outcome {
        case .saved, .unchanged: current == submitted ? saved : current
        case .refused, .notSaved, .superseded: current
        }
    }

    /// Les termes d'un texte saisi : un par ligne, sans espaces autour, sans lignes vides ni doublons (le premier reste).
    static func terms(in text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Enregistre les réglages modifiés ; rend faux (et dit pourquoi) si l'enregistrement échoue.
    @discardableResult
    private func change(_ edit: (inout TranscriptionSettings) -> Void, in area: TranscriptionMessageArea = .general) -> Bool {
        var updated = settings
        edit(&updated)
        clearMessage()
        do {
            try save(updated)
        } catch {
            show("Réglage non enregistré : \(Self.describe(error))", .error, in: area)
            return false
        }
        settings = updated
        return true
    }

    // MARK: - Messages

    private func show(_ text: String, _ kind: TranscriptionMessageKind, in area: TranscriptionMessageArea = .general) {
        message = text
        messageKind = kind
        messageArea = area
    }

    private func clearMessage() {
        message = nil
        messageKind = .info
        messageArea = .general
    }

    private static func describe(_ error: any Error) -> String {
        let text = error.localizedDescription
        return text.hasSuffix(".") ? text : text + "."
    }
}
