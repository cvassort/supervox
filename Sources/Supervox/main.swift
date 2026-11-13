import AppKit
import SupervoxApp

// Application de barre de menus : pas d'icône dans le Dock, pas de menu principal.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let controller = AppController()
controller.start()
application.run()
