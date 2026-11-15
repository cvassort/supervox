import FluidAudio

/// Réglages du journal de la bibliothèque audio (FluidAudio), à poser au démarrage de l'application, avant tout chargement.
///
/// Par défaut la bibliothèque écrit au niveau « debug » des lignes qui contiennent le texte transcrit, vers le journal unifié
/// et, en construction de débogage, sur la sortie d'erreur (`AppLogger.swift:32-60` de FluidAudio 0.18.3 : « ASR debug lines
/// that contain transcript text »). Le texte dicté est une donnée privée : le niveau minimal passe à « avertissement » et la
/// copie vers la console est coupée (reste le journal unifié, dont les messages sont privés par défaut).
public enum EngineLogging {
    public static func keepTranscriptsOutOfLogs() {
        AppLogger.minimumLevel = .warning
        AppLogger.mirrorsToConsole = false
    }

    /// Pour les tests : les réglages en vigueur.
    static var settings: (minimumLevelIsWarning: Bool, mirrorsToConsole: Bool) {
        (AppLogger.minimumLevel == .warning, AppLogger.mirrorsToConsole)
    }

    /// Pour les tests : rétablit des réglages lus avant.
    static func restore(minimumLevel: AppLogger.Level, mirrorsToConsole: Bool) {
        AppLogger.minimumLevel = minimumLevel
        AppLogger.mirrorsToConsole = mirrorsToConsole
    }
}

/// Le réseau de FluidAudio (Parakeet, détecteur de voix), coupé le temps du préchargement du lancement.
///
/// `ModelHub.offlineMode` (FluidAudio 0.18.3, `Shared/Download/ModelHub.swift:31-33`, public, global au processus) fait lever
/// `modelMissing`/`networkDisabled` à la place de tout accès au réseau : `loadModelsOnce` (`:364-369`, fichiers requis absents ou
/// incomplets), le rattrapage de `loadModels` qui supprimerait puis retéléchargerait un bundle qui ne se charge pas (`:103-108`,
/// relancé avant `purgeCorruptedFiles`, `:137`), `fetchWithAuth` (`:36-40`), le listage (`HFTreeLister.swift:43`) et les fichiers
/// (`FileDownloader.swift:149`).
public enum EngineNetwork {
    public static func setOffline(_ offline: Bool) {
        ModelHub.offlineMode = offline
    }
}
