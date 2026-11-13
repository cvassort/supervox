import AppKit
import Carbon.HIToolbox
import SwiftUI
import os

/// Le panneau flottant : un `NSPanel` non activant, sans barre de titre, translucide, à coins
/// arrondis, présent sur tous les bureaux, centré dans le tiers supérieur de l'écran où se trouve
/// la souris.
///
/// Focus. Le panneau est montré par `orderFrontRegardless()` et n'est jamais rendu clé par le
/// code : l'application de dessous reste au premier plan et son champ de texte garde la frappe.
/// Un clic sur une pastille ou sur le menu ne le rend pas clé non plus (`becomesKeyOnlyIfNeeded`).
///
/// Échap. Tant que le panneau est ouvert, Échap est tenu comme raccourci global (Carbon, sans
/// permission) par un enregistreur à part, et rendu dès la fermeture. Un moniteur d'événements
/// global ne recevrait les touches qu'avec la permission Accessibilité ; un moniteur local, que si
/// le panneau était clé, ce qui détournerait la frappe. Coût : pendant que le panneau est ouvert,
/// Échap n'arrive plus à l'application de dessous.
@MainActor
public final class PanelController {
    private let model: PanelModel
    private let panel: FloatingPanel
    private let escapeRegistrar: any HotKeyRegistrar
    private let log = Logger(subsystem: "dev.supervox.app", category: "panel")

    /// Échap, sans modificateur.
    private static let escape = HotKey(keyCode: UInt32(kVK_Escape), modifiers: [])

    public init<Content: View>(
        model: PanelModel, escapeRegistrar: any HotKeyRegistrar, content: Content
    ) {
        self.model = model
        self.escapeRegistrar = escapeRegistrar
        panel = FloatingPanel(content: content)
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
            show()
        } else {
            escapeRegistrar.unregister()
            panel.orderOut(nil)
            log.notice("panneau fermé")
        }
    }

    private func show() {
        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        if let screen = Self.screenUnderMouse() {
            panel.setFrame(Self.frame(size: size, in: screen.visibleFrame), display: false)
        }
        panel.orderFrontRegardless()
        let escapeHeld = escapeRegistrar.register(Self.escape) { [weak self] in self?.close() }
        log.notice(
            "panneau ouvert ; clé : \(self.panel.isKeyWindow, privacy: .public) ; application active : \(NSApp.isActive, privacy: .public) ; Échap tenu : \(escapeHeld, privacy: .public)"
        )
    }

    private static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
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

/// Le `NSPanel` lui-même. Peut devenir clé (si une vue l'exige), jamais principal.
private final class FloatingPanel: NSPanel {
    private static let cornerRadius: CGFloat = 20

    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 160),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
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

    override var canBecomeKey: Bool { true }
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
