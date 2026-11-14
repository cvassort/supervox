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

/// La transcription telle que la fenêtre de réglages la montre et la change : moteur, modèle, langue, vocabulaire, et
/// les modèles locaux à télécharger ou supprimer.
///
/// `settings` reflète toujours ce qui est enregistré : il ne change qu'après un `save` réussi ; si `save` lève, la
/// valeur affichée revient à l'ancienne et `message` dit pourquoi. Les états de téléchargement en cours et les échecs
/// vivent ici, par-dessus la liste du catalogue : un `refresh` ne les efface pas.
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
    /// Les modèles du catalogue, avec les téléchargements en cours et les échecs de cette session par-dessus.
    public var models: [LocalModel] {
        listed.map { model in
            var model = model
            if let override = overrides[model.id] { model.state = override }
            return model
        }
    }

    private var listed: [LocalModel] = []
    /// Téléchargement en cours (`downloading`) ou échec (`failed`), par identifiant de modèle.
    private var overrides: [String: LocalModel.State] = [:]
    @ObservationIgnored private var vocabularyGeneration = 0
    @ObservationIgnored private let catalog: any ModelCatalog
    @ObservationIgnored private let promptTokenLimit: Int
    @ObservationIgnored private let save: Save

    /// `promptTokenLimit` : nombre de jetons d'amorce que le moteur garde (`WhisperKitTranscriber.promptTokenLimit`).
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
    }

    /// Lance le téléchargement. Sans effet si ce modèle est déjà en cours de téléchargement.
    public func download(_ id: String) async {
        if case .downloading? = overrides[id] { return }
        overrides[id] = .downloading(0)
        clearMessage()
        do {
            try await catalog.download(id) { [weak self] fraction in
                Task { @MainActor in self?.progress(fraction, of: id) }
            }
            overrides[id] = nil
        } catch {
            overrides[id] = .failed("Le téléchargement a échoué : \(Self.describe(error))")
        }
        await refresh()
    }

    private func progress(_ fraction: Double, of id: String) {
        // Une progression qui arrive après la fin du téléchargement ne le ressuscite pas.
        guard case .downloading? = overrides[id] else { return }
        overrides[id] = .downloading(min(max(fraction, 0), 1))
    }

    /// Supprime le modèle. Permis même s'il est celui du moteur choisi : le message prévient alors que la prochaine
    /// dictée le retéléchargera. Refusé pendant son téléchargement.
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
        overrides[id] = nil
        await refresh()
        if wasReady, isUsedByChosenEngine(id) {
            show(
                "Ce modèle est celui du moteur choisi : la prochaine dictée le téléchargera de nouveau, ce qui peut prendre un moment.",
                .info)
        }
    }

    /// Vrai si le moteur choisi dans les réglages dicte avec ce modèle.
    public func isUsedByChosenEngine(_ id: String) -> Bool {
        switch settings.engine {
        case "parakeet": id == LocalModelID.parakeet
        default: id == LocalModelID.whisper(settings.whisperModel)
        }
    }

    // MARK: - Réglages

    public func setEngine(_ engine: String) {
        guard TranscriptionSettings.knownEngines.contains(engine) else { return }
        change { $0.engine = engine }
    }

    public func setWhisperModel(_ model: String) {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return }
        change { $0.whisperModel = model }
    }

    public func setLanguage(_ language: String) {
        let language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !language.isEmpty else { return }
        change { $0.language = language }
    }

    /// Un terme par ligne ; lignes vides et doublons retirés. Refusé si l'amorce dépasse ce que le moteur garde.
    public func setVocabulary(text: String) async {
        let terms = Self.terms(in: text)
        vocabularyGeneration += 1
        let generation = vocabularyGeneration
        guard terms != settings.vocabulary else { return }

        var warning: String?
        if !terms.isEmpty {
            let count = await catalog.promptTokenCount(terms, whisperModel: settings.whisperModel)
            // Une saisie plus récente a pris la place pendant le comptage.
            guard generation == vocabularyGeneration else { return }
            if let count {
                guard count <= promptTokenLimit else {
                    show(
                        "Vocabulaire trop long : il demande \(count) jetons d'amorce, et le moteur en accepte \(promptTokenLimit) au plus. L'ancien vocabulaire est conservé ; retirez des termes.",
                        .error)
                    return
                }
            } else {
                warning =
                    "Vocabulaire enregistré. Le modèle n'est pas encore sur ce Mac : la limite de longueur sera vérifiée quand il sera là."
            }
        }
        if change({ $0.vocabulary = terms }), let warning { show(warning, .warning) }
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
    private func change(_ edit: (inout TranscriptionSettings) -> Void) -> Bool {
        var updated = settings
        edit(&updated)
        clearMessage()
        do {
            try save(updated)
        } catch {
            show("Réglage non enregistré : \(Self.describe(error))", .error)
            return false
        }
        settings = updated
        return true
    }

    // MARK: - Messages

    private func show(_ text: String, _ kind: TranscriptionMessageKind) {
        message = text
        messageKind = kind
    }

    private func clearMessage() {
        message = nil
        messageKind = .info
    }

    private static func describe(_ error: any Error) -> String {
        let text = error.localizedDescription
        return text.hasSuffix(".") ? text : text + "."
    }
}
