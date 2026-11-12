import Foundation
import SupervoxCore

/// Transcription par un endpoint HTTP compatible OpenAI. Le modèle est un argument : aucun nom en dur.
///
/// Vocabulaire : les termes, joints par des virgules, partent dans le champ `prompt` de la requête.
/// La durée mesurée inclut l'encodage WAV et l'aller-retour réseau.
public struct EndpointTranscriber: Transcriber {
    public let name = "endpoint"
    public var acceptsVocabulary: Bool { true }
    public var measurementConditions: String {
        "aucun préchauffage. Durée mesurée : écriture et relecture d'un WAV temporaire, requête HTTP multipart et "
            + "réponse (réseau, file d'attente du serveur). Une "
            + "requête identique déjà envoyée peut être servie par un cache : ne pas comparer ces durées d'une "
            + "relance à l'autre. Requête abandonnée après \(Int(client.requestTimeout.rounded())) s sans aucune "
            + "donnée reçue (délai d'inactivité, pas une durée totale) : la phrase est alors en échec ; après "
            + "3 échecs de transport consécutifs, le moteur est arrêté."
    }
    private let client: OpenAICompatibleClient
    private let model: String

    public init(client: OpenAICompatibleClient, model: String) {
        self.client = client
        self.model = model
    }

    /// Rien à charger. On refuse seulement un identifiant de modèle vide, qui ferait échouer chaque requête.
    public func prepare() async throws {
        guard !model.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw TranscriberError.engine("identifiant de modèle de l'endpoint vide")
        }
    }

    public func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        try TranscriberError.check16kHz(clip)
        let prompt = vocabulary.isEmpty ? nil : vocabulary.joined(separator: ", ")
        return try await client.transcribe(wav: try Self.wavData(clip), model: model, language: language, prompt: prompt)
    }

    /// `WavFile` n'écrit que dans un fichier : on passe par un fichier temporaire, retiré aussitôt.
    private static func wavData(_ clip: AudioClip) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("supervox-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try WavFile.write(clip, to: url)
        return try Data(contentsOf: url)
    }
}
