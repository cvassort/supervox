import AppKit
import Carbon.HIToolbox
import SwiftUI
import os

/// Ce qui montre et cache le panneau à l'écran. Double dans les tests : rien ne s'affiche.
@MainActor
public protocol PanelSurface: AnyObject {
    /// Place le panneau et le montre, sans le rendre clé ni activer l'application.
    func show()
    func hide()
}

/// Surveille les clics de souris adressés à d'autres applications, le temps que le panneau est ouvert.
@MainActor
public protocol OutsideClickMonitor: AnyObject {
    /// Remplace une surveillance en cours. `onClick` est appelé sur le fil principal.
    func start(_ onClick: @escaping @MainActor () -> Void)
    /// Ne fait rien s'il n'y a pas de surveillance en cours.
    func stop()
}

/// Le panneau flottant : un `NSPanel` non activant, sans barre de titre, translucide, à coins
/// arrondis, présent sur tous les bureaux, centré dans le tiers supérieur de l'écran où se trouve
/// la souris. Ce contrôleur décide quand il s'ouvre et se ferme ; la surface l'affiche.
///
/// Focus. Le panneau est montré par `orderFrontRegardless()` et ne peut pas devenir clé
/// (`canBecomeKey` faux) : l'application de dessous reste au premier plan et son champ de texte
/// garde la frappe, même après un clic dans le panneau.
///
/// Échap. Tant que le panneau est ouvert, Échap est tenu comme raccourci global (Carbon, sans
/// permission) par un enregistreur à part, et rendu dès la fermeture. Un moniteur d'événements
/// global ne recevrait les touches qu'avec la permission Accessibilité ; un moniteur local, que si
/// le panneau était clé, ce qui détournerait la frappe. Coût : pendant que le panneau est ouvert,
/// Échap n'arrive plus à l'application de dessous. Si Échap ne peut pas être réservé, un avis le dit.
///
/// Clic en dehors. Tant que le panneau est ouvert, un clic dans une autre application le ferme
/// (le clic arrive quand même à cette application).
@MainActor
public final class PanelController {
    private let model: PanelModel
    private let surface: any PanelSurface
    private let escapeRegistrar: any HotKeyRegistrar
    private let clickMonitor: any OutsideClickMonitor
    private let log = Logger(subsystem: "dev.supervox.app", category: "panel")

    /// Échap, sans modificateur.
    static let escape = HotKey(keyCode: UInt32(kVK_Escape), modifiers: [])

    public init(
        model: PanelModel, escapeRegistrar: any HotKeyRegistrar,
        clickMonitor: any OutsideClickMonitor, surface: any PanelSurface
    ) {
        self.model = model
        self.escapeRegistrar = escapeRegistrar
        self.clickMonitor = clickMonitor
        self.surface = surface
    }

    /// Ouvre ou ferme, selon le modèle.
    public func toggle() {
        model.toggle()
        sync()
    }

    public func open() {
        if !model.isOpen { toggle() }
    }

    /// Seul chemin de fermeture : Échap, le raccourci, les actions du menu y passent tous, pour
    /// qu'Échap soit toujours rendu.
    public func close() {
        model.close()
        sync()
    }

    private func sync() {
        if model.isOpen {
            let escapeHeld = escapeRegistrar.register(Self.escape) { [weak self] in self?.close() }
            model.setNotice(escapeHeld ? nil : Self.escapeRefusedNotice(hotKeyLabel: model.hotKeyLabel), for: .escape)
            clickMonitor.start { [weak self] in self?.close() }
            surface.show()
            log.notice("panneau ouvert ; Échap tenu : \(escapeHeld, privacy: .public)")
        } else {
            escapeRegistrar.unregister()
            clickMonitor.stop()
            surface.hide()
            log.notice("panneau fermé")
        }
    }

    private static func escapeRefusedNotice(hotKeyLabel: String?) -> String {
        let ways = hotKeyLabel.map { "avec \($0) ou d'un clic en dehors" } ?? "d'un clic en dehors"
        return "Échap n'a pas pu être réservé : refermez le panneau \(ways)."
    }

    /// Cadre du panneau : centré horizontalement, son centre au milieu du tiers supérieur de la zone
    /// utile ; ramené contre le haut s'il dépasserait.
    nonisolated static func frame(size: CGSize, in visibleFrame: CGRect) -> CGRect {
        let centerY = visibleFrame.maxY - visibleFrame.height / 6
        let top = min(centerY + size.height / 2, visibleFrame.maxY)
        return CGRect(
            x: visibleFrame.midX - size.width / 2, y: top - size.height,
            width: size.width, height: size.height)
    }
}

/// La surface réelle : un `FloatingPanel`, placé sur l'écran de la souris.
@MainActor
public final class FloatingPanelSurface: PanelSurface {
    private let panel: FloatingPanel
    private let log = Logger(subsystem: "dev.supervox.app", category: "panel")

    public init<Content: View>(content: Content) {
        panel = FloatingPanel(content: content)
    }

    public func show() {
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        if let screen = Self.screenUnderMouse() {
            panel.setFrame(PanelController.frame(size: size, in: screen.visibleFrame), display: false)
        }
        panel.orderFrontRegardless()
        log.notice(
            "panneau affiché ; clé : \(self.panel.isKeyWindow, privacy: .public) ; application active : \(NSApp.isActive, privacy: .public)"
        )
    }

    public func hide() {
        panel.orderOut(nil)
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }
}

/// Le vrai moniteur : `NSEvent.addGlobalMonitorForEvents`, qui ne voit que les clics adressés aux
/// autres applications (pas ceux du panneau ni de la barre de menus de Supervox), et n'exige aucune
/// permission pour les événements de souris.
@MainActor
public final class GlobalClickMonitor: OutsideClickMonitor {
    private var token: Any?

    public init() {}

    public func start(_ onClick: @escaping @MainActor () -> Void) {
        stop()
        token = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            // Le gestionnaire d'un moniteur global est appelé sur le fil principal.
            MainActor.assumeIsolated { onClick() }
        }
    }

    public func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

/// Le `NSPanel` lui-même. Ne devient jamais clé ni principal : il ne prend jamais la frappe.
final class FloatingPanel: NSPanel {
    private static let cornerRadius: CGFloat = 20

    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 160),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.roundedMask(radius: Self.cornerRadius)

        let hosting = FirstClickHostingView(rootView: content)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: background.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        contentView = background
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Image étirable aux coins arrondis : seule façon fiable d'arrondir le flou « derrière la
    /// fenêtre » d'un `NSVisualEffectView`.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Le premier clic dans le panneau (qui n'est pas clé) agit tout de suite au lieu d'être consommé.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
