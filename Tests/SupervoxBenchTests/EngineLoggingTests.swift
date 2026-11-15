import FluidAudio
import Testing

@testable import SupervoxEngines

/// m6 : la bibliothèque audio n'écrit pas le texte transcrit dans les journaux. Les deux réglages sont ceux de FluidAudio 0.18.3
/// (`AppLogger.minimumLevel`, `AppLogger.mirrorsToConsole`, publics et modifiables) ; ils sont globaux au processus : le test
/// les rétablit.
@Suite(.serialized) struct EngineLoggingTests {
    @Test func theLoggerKeepsOnlyWarningsAndStopsMirroringToTheConsole() {
        let level = AppLogger.minimumLevel
        let mirrors = AppLogger.mirrorsToConsole
        defer { EngineLogging.restore(minimumLevel: level, mirrorsToConsole: mirrors) }

        // Le défaut de la bibliothèque est le contraire (debug, console) : sans l'appel, rien n'est protégé.
        EngineLogging.restore(minimumLevel: .debug, mirrorsToConsole: true)
        #expect(EngineLogging.settings == (false, true))

        EngineLogging.keepTranscriptsOutOfLogs()
        #expect(AppLogger.minimumLevel == .warning)
        #expect(AppLogger.mirrorsToConsole == false)
        #expect(EngineLogging.settings == (true, false))
    }
}
