import AppKit
import SupervoxApp
import SupervoxCore
import SupervoxEngines

// Application de barre de menus : pas d'icône dans le Dock. Le menu principal n'est posé qu'à l'ouverture des réglages
// (édition dans les champs, Fermer, Quitter).
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
// Avant tout chargement : la bibliothèque audio n'écrit pas le texte transcrit dans les journaux.
EngineLogging.keepTranscriptsOutOfLogs()
// Un seul catalogue de modèles : celui de l'onglet Transcription et celui de la dictée.
let engines = LiveDictationEngines()
// Le son réel et la voix du système ne sont construits qu'ici : tests, outil de rendu et constructeurs par défaut n'ont pas
// d'entretien (`InterviewEnvironment.unavailable`).
let interview = LiveInterview(
    engines: engines, makeAudio: { LiveAudioIO() }, makeSystemVoice: { SystemSpeechSynthesizer(language: $0, identifier: $1) },
    makeProviderVoice: LiveInterview.providerVoice, assemble: LiveInterview.session)
let controller = AppController(
    settingsView: SettingsView.provider(
        catalog: engines.catalog, promptTokenLimit: WhisperKitTranscriber.promptTokenLimit),
    dictation: engines.environment,
    interview: interview.environment,
    // L'historique des entretiens : le seul endroit qui nomme le vrai dossier, à côté de `settings.json`. Sans cette racine
    // (tests, outil de rendu), l'application n'a pas d'historique et n'en touche aucun.
    historyRoot: URL.applicationSupportDirectory.appending(path: "Supervox/Historique", directoryHint: .isDirectory),
    // L'insertion du système (presse-papiers général, ⌘V réel) n'est construite que par le programme.
    inserter: .system())
// `NSApplication.delegate` est faible : la constante globale le garde jusqu'à la fin du processus.
let delegate = ApplicationDelegate(controller: controller)
application.delegate = delegate
controller.start()
application.run()
