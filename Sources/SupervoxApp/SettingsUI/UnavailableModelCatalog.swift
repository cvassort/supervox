import SupervoxCore

/// Catalogue vide : l'entrée par défaut de la fenêtre de réglages, tant que `SupervoxApp` n'a pas reçu de vrai catalogue
/// (`SettingsView.provider(catalog:promptTokenLimit:)`). Il ne liste rien, ne télécharge rien.
public struct UnavailableModelCatalog: ModelCatalog {
    public init() {}

    public func models() async -> [LocalModel] { [] }
    public func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {}
    public func delete(_ id: String) async throws {}
    public func promptTokenCount(_ vocabulary: [String], whisperModel: String) async -> Int? { nil }
}
