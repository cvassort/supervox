import AppKit
import Testing

@testable import SupervoxApp

@Suite("Logo")
@MainActor
struct BrandMarkTests {
    @Test("cinq barres symétriques dont le bas dessine un V")
    func fiveSymmetricBarsWhoseBottomDrawsAV() {
        let bars = BrandMark.bars(in: CGRect(x: 0, y: 0, width: 100, height: 100))

        #expect(bars.count == 5)
        // Même sommet pour toutes : c'est le bas qui dessine le V.
        #expect(Set(bars.map { $0.maxY.rounded() }).count == 1)
        // Hauteurs : courte, moyenne, longue, moyenne, courte.
        let heights = bars.map(\.height)
        #expect(heights[0] < heights[1] && heights[1] < heights[2])
        #expect(abs(heights[0] - heights[4]) < 0.001 && abs(heights[1] - heights[3]) < 0.001)
        // Symétrie autour de l'axe vertical du cadre.
        for (left, right) in zip(bars, bars.reversed()) {
            #expect(abs((left.midX - 50) + (right.midX - 50)) < 0.001)
        }
        // Même largeur, sans chevauchement, de gauche à droite.
        #expect(Set(bars.map { ($0.width * 1000).rounded() }).count == 1)
        for (a, b) in zip(bars, bars.dropFirst()) { #expect(a.maxX < b.minX) }
    }

    @Test("les barres tiennent dans le cadre donné, où qu'il soit", arguments: [
        CGRect(x: 0, y: 0, width: 18, height: 18), CGRect(x: 40, y: -12, width: 512, height: 300),
    ])
    func barsStayInsideTheGivenFrame(frame: CGRect) {
        for bar in BrandMark.bars(in: frame) {
            #expect(frame.contains(bar))
        }
    }

    @Test("l'icône de barre de menus est un gabarit de 18 points que le système recolore")
    func menuBarImageIsAnEighteenPointTemplate() {
        let image = BrandMark.menuBarImage()

        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 18, height: 18))
        #expect(image.accessibilityDescription == "Supervox")
    }

    @Test("l'icône de barre de menus dessine vraiment quelque chose, sans remplir tout le carré")
    func menuBarImageDrawsTheBarsOnly() throws {
        let coverage = try opaqueShare(of: BrandMark.menuBarImage(), pixels: 72)

        #expect(coverage > 0.10)
        #expect(coverage < 0.60)
    }

    @Test("l'icône d'application est carrée, à la taille demandée, et son fond couvre le centre")
    func appIconIsSquareAtTheRequestedSize() throws {
        let rep = BrandMark.appIconBitmap(pixels: 128)

        #expect(rep.pixelsWide == 128 && rep.pixelsHigh == 128)
        // Coin transparent (carré arrondi avec marge), centre opaque.
        #expect((rep.colorAt(x: 1, y: 1)?.alphaComponent ?? 1) < 0.05)
        #expect((rep.colorAt(x: 64, y: 100)?.alphaComponent ?? 0) > 0.95)
    }

    @Test("le jeu d'icônes contient les dix fichiers attendus par iconutil, aux bonnes tailles")
    func iconsetListsTheTenFilesIconutilExpects() {
        let entries = BrandMark.iconsetEntries

        #expect(entries.map(\.name) == [
            "icon_16x16.png", "icon_16x16@2x.png", "icon_32x32.png", "icon_32x32@2x.png", "icon_128x128.png",
            "icon_128x128@2x.png", "icon_256x256.png", "icon_256x256@2x.png", "icon_512x512.png",
            "icon_512x512@2x.png",
        ])
        #expect(entries.map(\.pixels) == [16, 32, 32, 64, 128, 256, 256, 512, 512, 1024])
    }

    @Test("l'icône d'application porte les barres blanches sur le fond indigo")
    func appIconCarriesWhiteBarsOnTheIndigoTile() throws {
        let rep = BrandMark.appIconBitmap(pixels: 256)

        // Barre centrale : au milieu du carré, AppKit compte les lignes du bitmap depuis le haut.
        let bar = try #require(rep.colorAt(x: 128, y: 110)?.usingColorSpace(.sRGB))
        #expect(bar.redComponent > 0.9 && bar.greenComponent > 0.9 && bar.blueComponent > 0.9)
        // Entre deux barres, à la même hauteur : le fond, nettement plus bleu que rouge.
        let tile = try #require(rep.colorAt(x: 128 - 18, y: 110)?.usingColorSpace(.sRGB))
        #expect(tile.blueComponent > tile.redComponent + 0.3)
    }

    @Test("le jeu d'icônes écrit dix PNG lisibles, chacun à sa taille")
    func writeIconsetWritesTenReadablePNGsAtTheirSizes() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("supervox-iconset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        try BrandMark.writeIconset(to: folder)

        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 10)
        for entry in BrandMark.iconsetEntries {
            let data = try Data(contentsOf: folder.appendingPathComponent(entry.name))
            let rep = try #require(NSBitmapImageRep(data: data), "\(entry.name)")
            #expect(rep.pixelsWide == entry.pixels && rep.pixelsHigh == entry.pixels, "\(entry.name)")
        }
    }

    /// Part des pixels non transparents d'une image rendue dans un carré de `pixels` de côté.
    private func opaqueShare(of image: NSImage, pixels: Int) throws -> Double {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        var opaque = 0
        for x in 0..<pixels {
            for y in 0..<pixels where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaque += 1 }
        }
        return Double(opaque) / Double(pixels * pixels)
    }
}
