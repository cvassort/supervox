import AppKit
import SupervoxApp
import SupervoxEngines

// Application de barre de menus : pas d'icône dans le Dock. Le menu principal n'est posé qu'à l'ouverture des réglages
// (édition dans les champs, Fermer, Quitter).
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
// Avant tout chargement : la bibliothèque audio n'écrit pas le texte transcrit dans les journaux.
EngineLogging.keepTranscriptsOutOfLogs()
// Un seul catalogue de modèles : celui de l'onglet Transcription et celui de la dictée.
let engines = LiveDictationEngines()
let controller = AppController(
    settingsView: SettingsView.provider(
        catalog: engines.catalog, promptTokenLimit: WhisperKitTranscriber.promptTokenLimit),
    dictation: engines.environment,
    // L'insertion du système (presse-papiers général, ⌘V réel) n'est construite que par le programme.
    inserter: .system())
// `NSApplication.delegate` est faible : la constante globale le garde jusqu'à la fin du processus.
let delegate = ApplicationDelegate(controller: controller)
application.delegate = delegate
controller.start()
application.run()
