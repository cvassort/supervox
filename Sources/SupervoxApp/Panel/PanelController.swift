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
    /// La hauteur, en points, que le contenu demande maintenant ; `nil` si la surface ne sait pas la mesurer. Le contrôleur la
    /// compare à celle qu'il a vue pour décider d'un redimensionnement.
    func contentHeight() -> CGFloat?
    /// Donne cette hauteur à la fenêtre : le haut ne bouge pas (la fenêtre grandit et rétrécit vers le bas) sauf pour ne pas
    /// sortir de l'écran.
    func resize(toHeight height: CGFloat)
}

extension PanelSurface {
    public func contentHeight() -> CGFloat? { nil }
    public func resize(toHeight height: CGFloat) {}
}

/// Une surface qui sait dire que son contenu a changé de taille (la vue d'hébergement le sait avant tout autre).
@MainActor
public protocol ContentSizeObserving: AnyObject {
    var onContentSizeChange: (@MainActor () -> Void)? { get set }
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
/// (le clic arrive quand même à cette application), sauf pendant une dictée (`preparing`, `recording`, `finalizing`).
///
/// Dictée. Le panneau ne connaît de la dictée que son état (`PanelModel.dictation`). Sa fermeture est signalée par `onClosed`,
/// et Échap peut être confié à un gestionnaire (`escapeHandler`).
@MainActor
public final class PanelController: PanelOpening {
    private let model: PanelModel
    private let surface: any PanelSurface
    private let escapeRegistrar: any HotKeyRegistrar
    private let clickMonitor: any OutsideClickMonitor
    private let log = Logger(subsystem: "dev.supervox.app", category: "panel")

    /// Échap, sans modificateur.
    static let escape = HotKey(keyCode: UInt32(kVK_Escape), modifiers: [])

    /// La hauteur du contenu telle que la surface l'a donnée à l'ouverture ou au dernier redimensionnement.
    private var shownHeight: CGFloat?

    /// Écart de hauteur, en points, en deçà duquel un contenu est le même (arrondis de mise en page).
    private static let heightTolerance: CGFloat = 0.5

    public init(
        model: PanelModel, escapeRegistrar: any HotKeyRegistrar,
        clickMonitor: any OutsideClickMonitor, surface: any PanelSurface
    ) {
        self.model = model
        self.escapeRegistrar = escapeRegistrar
        self.clickMonitor = clickMonitor
        self.surface = surface
        (surface as? any ContentSizeObserving)?.onContentSizeChange = { [weak self] in self?.contentChanged() }
    }

    /// Le contenu du panneau a changé (l'état de la dictée, un texte, une permission) : si sa hauteur n'est plus celle de la
    /// fenêtre, la surface est redimensionnée. Mesuré tout de suite puis au tour suivant : le contenu ne se met en page
    /// qu'après le changement. Un panneau fermé n'est jamais redimensionné.
    public func contentChanged() {
        refit()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.refit()
        }
    }

    private func refit() {
        guard model.isOpen, let height = surface.contentHeight() else { return }
        if let shownHeight, abs(height - shownHeight) < Self.heightTolerance { return }
        shownHeight = height
        surface.resize(toHeight: height)
    }

    public var isOpen: Bool { model.isOpen }

    /// Appelé chaque fois qu'un panneau ouvert se ferme, par quelque chemin que ce soit (Échap, clic en dehors, menu,
    /// Quitter, Réglages, fin d'une dictée collée) : le contrôleur de dictée y annule la dictée en cours.
    public var onClosed: (@MainActor () -> Void)?
    /// Ce que fait Échap pendant que le panneau est ouvert. Sans gestionnaire, Échap ferme le panneau. Avec un
    /// gestionnaire (la dictée), c'est lui qui décide, et il ferme le panneau lui-même.
    public var escapeHandler: (@MainActor () -> Void)?

    /// Ouvre ou ferme, selon le modèle.
    public func toggle() {
        let wasOpen = model.isOpen
        model.toggle()
        sync()
        if wasOpen { onClosed?() }
    }

    public func open() {
        if !model.isOpen { toggle() }
    }

    /// Seul chemin de fermeture : Échap, le clic en dehors, les actions du menu et la fin d'une dictée collée y passent
    /// tous, pour qu'Échap soit toujours rendu.
    public func close() {
        let wasOpen = model.isOpen
        model.close()
        sync()
        if wasOpen { onClosed?() }
    }

    private func escapePressed() {
        if let escapeHandler { escapeHandler() } else { close() }
    }

    /// Un clic dans une autre application ferme le panneau, sauf pendant une dictée : le clic qui sert à passer à la fenêtre
    /// où le texte doit aller ne doit pas annuler ce qu'on dit.
    private func outsideClick() {
        guard !model.dictation.stage.isActive else { return }
        close()
    }

    private func sync() {
        if model.isOpen {
            let escapeHeld = escapeRegistrar.register(Self.escape) { [weak self] in self?.escapePressed() }
            model.setNotice(escapeHeld ? nil : Self.escapeRefusedNotice, for: .escape)
            clickMonitor.start { [weak self] in self?.outsideClick() }
            surface.show()
            shownHeight = surface.contentHeight()
            log.notice("panneau ouvert ; Échap tenu : \(escapeHeld, privacy: .public)")
        } else {
            escapeRegistrar.unregister()
            clickMonitor.stop()
            surface.hide()
            log.notice("panneau fermé")
        }
    }

    /// Le raccourci lance une dictée (il ne ferme plus le panneau) et le clic en dehors est ignoré pendant une dictée :
    /// seul le menu de l'icône ferme toujours.
    private static let escapeRefusedNotice =
        "Échap n'a pas pu être réservé : refermez le panneau par le menu de l'icône de Supervox, dans la barre de menus, ou d'un clic en dehors quand aucune dictée n'est en cours."

    /// Le cadre de la fenêtre pour une nouvelle hauteur : le haut ne bouge pas, la fenêtre grandit et rétrécit vers le bas.
    /// Si le bas sortirait de la zone utile de l'écran, la fenêtre remonte ; plus haute que la zone utile, elle est bornée à
    /// celle-ci. Sans écran connu, seul le haut est conservé.
    nonisolated static func resizedFrame(_ frame: CGRect, height: CGFloat, in visibleFrame: CGRect?) -> CGRect {
        var height = height
        var y = frame.maxY - height
        if let visibleFrame {
            height = min(height, visibleFrame.height)
            y = frame.maxY - height
            if y < visibleFrame.minY { y = visibleFrame.minY }
            if y + height > visibleFrame.maxY { y = visibleFrame.maxY - height }
        }
        return CGRect(x: frame.minX, y: y, width: frame.width, height: height)
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
public final class FloatingPanelSurface: PanelSurface, ContentSizeObserving {
    /// La fenêtre (visible des tests d'intégration, qui la placent hors écran).
    let panel: FloatingPanel
    private let log = Logger(subsystem: "dev.supervox.app", category: "panel")

    /// Appelé quand le contenu de la vue change de taille (voir `PanelController.contentChanged`).
    public var onContentSizeChange: (@MainActor () -> Void)? {
        get { panel.hosting.onSizeChange }
        set { panel.hosting.onSizeChange = newValue }
    }

    public init<Content: View>(content: Content) {
        panel = FloatingPanel(content: content)
    }

    public func contentHeight() -> CGFloat? {
        panel.contentView?.layoutSubtreeIfNeeded()
        return panel.hosting.fittingSize.height
    }

    public func resize(toHeight height: CGFloat) {
        let screen = panel.screen ?? Self.screenUnderMouse()
        let next = PanelController.resizedFrame(panel.frame, height: height, in: screen?.visibleFrame)
        panel.setFrame(next, display: true, animate: false)
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

    /// La vue d'hébergement du contenu : elle seule sait quand sa taille change.
    let hosting: FirstClickHostingView

    init<Content: View>(content: Content) {
        let hosting = FirstClickHostingView(rootView: AnyView(content))
        self.hosting = hosting
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
final class FirstClickHostingView: NSHostingView<AnyView> {
    /// Appelé, au tour suivant, quand la taille que le contenu demande change.
    var onSizeChange: (@MainActor () -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// La dernière hauteur vue à la mise en page : un contenu qui change de taille remet la vue en page, c'est là qu'on le voit.
    private var lastHeight: CGFloat?

    override func layout() {
        super.layout()
        let height = intrinsicContentSize.height
        guard height != lastHeight else { return }
        lastHeight = height
        // Au tour suivant de la boucle principale, pas pendant la mise en page : la fenêtre ne se redimensionne pas en plein
        // calcul de sa propre disposition.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onSizeChange?() } }
    }
}
