import AppKit
import SupervoxApp

// Application de barre de menus : pas d'icône dans le Dock. Le menu principal n'est posé qu'à l'ouverture des réglages
// (édition dans les champs, Fermer, Quitter).
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = AppController()
// `NSApplication.delegate` est faible : la constante globale le garde jusqu'à la fin du processus.
let delegate = ApplicationDelegate(controller: controller)
application.delegate = delegate
controller.start()
application.run()
