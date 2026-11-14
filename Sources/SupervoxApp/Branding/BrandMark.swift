import AppKit

/// Le logo de Supervox, dessiné par le code : cinq barres d'onde alignées en haut, dont le bas dessine un « V ».
/// Une seule géométrie sert à l'icône de la barre de menus et à l'icône de l'application : aucun fichier d'image
/// n'est suivi dans le dépôt.
@MainActor
public enum BrandMark {
    /// Hauteur de chaque barre, en part de la hauteur de la zone des barres.
    private static let heights: [CGFloat] = [0.42, 0.72, 1.0, 0.72, 0.42]
    /// Largeur d'une barre en part de la largeur du cadre ; l'intervalle entre deux barres vaut `gap`.
    private static let barWidth: CGFloat = 0.11
    private static let gap: CGFloat = 0.065
    /// Marge verticale du dessin dans son cadre, de chaque côté.
    private static let verticalInset: CGFloat = 0.16

    /// Les cinq barres, de gauche à droite, dans un cadre en coordonnées AppKit (origine en bas à gauche).
    public static func bars(in frame: CGRect) -> [CGRect] {
        let width = barWidth * frame.width
        let step = (barWidth + gap) * frame.width
        let total = width + step * CGFloat(heights.count - 1)
        let left = frame.midX - total / 2
        let top = frame.maxY - verticalInset * frame.height
        let area = frame.height * (1 - 2 * verticalInset)
        return heights.enumerated().map { index, share in
            CGRect(x: left + step * CGFloat(index), y: top - area * share, width: width, height: area * share)
        }
    }

    private static func fillBars(in frame: CGRect) {
        for bar in bars(in: frame) {
            NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
        }
    }

    /// Icône de la barre de menus : un gabarit noir que le système recolore selon le thème.
    public static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            fillBars(in: rect)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Supervox"
        return image
    }

    /// Icône de l'application, carrée, de `pixels` de côté : carré arrondi indigo, barres blanches.
    public static func appIconBitmap(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        defer { NSGraphicsContext.restoreGraphicsState() }

        let side = CGFloat(pixels)
        // Proportions de la grille d'icône de macOS : carré de 824 sur 1024, rayon de 186.
        let tile = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: side * 100 / 1024, dy: side * 100 / 1024)
        let shape = NSBezierPath(roundedRect: tile, xRadius: side * 186 / 1024, yRadius: side * 186 / 1024)
        let background = NSGradient(colors: [
            NSColor(srgbRed: 0.43, green: 0.36, blue: 1.0, alpha: 1),
            NSColor(srgbRed: 0.23, green: 0.18, blue: 0.84, alpha: 1),
            NSColor(srgbRed: 0.10, green: 0.08, blue: 0.40, alpha: 1),
        ])
        background?.draw(in: shape, angle: -70)
        // Reflet doux en haut.
        NSGraphicsContext.current?.saveGraphicsState()
        shape.addClip()
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.26), NSColor.white.withAlphaComponent(0)])?
            .draw(
                fromCenter: NSPoint(x: tile.midX, y: tile.maxY - tile.height * 0.2), radius: 0,
                toCenter: NSPoint(x: tile.midX, y: tile.maxY - tile.height * 0.2), radius: tile.width * 0.75,
                options: [])
        NSGraphicsContext.current?.restoreGraphicsState()

        let shadow = NSShadow()
        shadow.shadowColor = NSColor(srgbRed: 0.04, green: 0.03, blue: 0.25, alpha: 0.45)
        shadow.shadowOffset = NSSize(width: 0, height: -side * 0.014)
        shadow.shadowBlurRadius = side * 0.03
        shadow.set()
        NSColor.white.setFill()
        fillBars(in: tile.insetBy(dx: tile.width * 0.12, dy: tile.height * 0.12))
        return rep
    }

    /// Les fichiers d'un dossier `.iconset`, tels qu'`iconutil` les attend, avec leur côté en pixels.
    public static let iconsetEntries: [(name: String, pixels: Int)] = [16, 32, 128, 256, 512].flatMap { points in
        [("icon_\(points)x\(points).png", points), ("icon_\(points)x\(points)@2x.png", points * 2)]
    }

    /// Écrit le jeu d'icônes dans `directory` (créé au besoin) ; `iconutil -c icns` en fait un `.icns`.
    public static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in iconsetEntries {
            guard let png = appIconBitmap(pixels: entry.pixels).representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try png.write(to: directory.appendingPathComponent(entry.name))
        }
    }
}
