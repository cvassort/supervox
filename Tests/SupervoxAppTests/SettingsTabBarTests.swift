import AppKit
import SwiftUI
import Testing

@testable import SupervoxApp

/// La barre d'onglets de la fenêtre des réglages, mesurée hors écran, dans une fenêtre CRÉÉE et JAMAIS AFFICHÉE (patron de
/// `HistoryPaneBehaviorTests`). Dans une fenêtre, le `TabView` de SwiftUI ne pose pas de `NSTabView` : la barre est un élément de
/// barre d'outils dont la vue porte un contrôle segmenté (sonde de la tâche 4, mesuré). Ce test mesure la largeur dont ce contrôle a
/// besoin, pas ce qu'une fenêtre AFFICHÉE en fait : « mesurée hors écran (fenêtre jamais affichée), non vue affichée ».
@MainActor @Suite(.timeLimit(.minutes(1))) struct SettingsTabBarTests {
    /// La marge laissée de chaque côté de la barre dans la fenêtre : 20 points (choix non mesuré, décision du contrôleur).
    nonisolated static let margin: CGFloat = 20

    struct Measure: CustomStringConvertible {
        /// Les titres du contrôle, dans l'ordre.
        var labels: [String]
        /// Le cadre du contrôle posé par AppKit, et sa taille propre.
        var frameWidth: CGFloat
        var intrinsicWidth: CGFloat
        /// La taille propre de la vue de l'élément de barre d'outils qui porte le contrôle.
        var itemIntrinsicWidth: CGFloat
        /// L'élément est-il parmi les éléments montrés de la barre d'outils (fenêtre jamais affichée) ?
        var itemVisible: Bool
        /// La répartition des segments (`NSSegmentedControl.Distribution` : 2 = parts égales), pour le rapport.
        var detail: String

        /// La largeur dont la barre a besoin : la taille propre du contrôle, la même à toute largeur de fenêtre (mesuré : 804 points
        /// pour les huit onglets de 600 à 900 points de fenêtre). Le cadre posé n'en est pas une : AppKit le comprime quand la
        /// fenêtre est étroite (mesuré, fenêtre jamais affichée : 611 de 600 à 780 points de fenêtre, 647 à 800, 772 à partir de 820).
        var need: CGFloat { intrinsicWidth }

        func fits(windowWidth: CGFloat) -> Bool { need + 2 * SettingsTabBarTests.margin <= windowWidth }

        var description: String {
            "titres \(labels.count), cadre \(frameWidth), taille propre \(intrinsicWidth), besoin \(need), élément \(itemIntrinsicWidth), "
                + "élément montré \(itemVisible), \(detail)"
        }
    }

    enum MeasureError: Error, CustomStringConvertible {
        case noControl(String)
        var description: String {
            switch self { case .noControl(let where_): "aucun contrôle segmenté trouvé dans la barre d'outils (\(where_))" }
        }
    }

    static func segmented(in view: NSView) -> NSSegmentedControl? {
        if let control = view as? NSSegmentedControl { return control }
        for subview in view.subviews { if let control = segmented(in: subview) { return control } }
        return nil
    }

    /// Pose la vue dans une fenêtre de cette largeur, jamais affichée, laisse AppKit poser la barre d'outils (passages bornés), et
    /// mesure le contrôle de la barre. Lève si le contrôle n'est pas trouvé : un instrument aveugle fait échouer le test.
    static func measure(_ view: some View, width: CGFloat, name: String) throws -> Measure {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: width, height: SettingsView.windowSize.height)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = host
        defer { withExtendedLifetime(window) {} }
        var found: (item: NSToolbarItem, control: NSSegmentedControl)?
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            RunLoop.main.run(mode: .default, before: Date())
            found = window.toolbar?.items.lazy.compactMap { item in item.view.flatMap(segmented(in:)).map { (item, $0) } }.first
            if let found, found.control.segmentCount > 0, found.control.frame.width > 0 { break }
        }
        guard let found, found.control.segmentCount > 0 else { throw MeasureError.noControl(name) }
        let control = found.control
        return Measure(
            labels: (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "?" },
            frameWidth: control.frame.width, intrinsicWidth: control.intrinsicContentSize.width,
            itemIntrinsicWidth: found.item.view?.intrinsicContentSize.width ?? 0,
            itemVisible: window.toolbar?.visibleItems?.contains { $0 === found.item } ?? false,
            detail: "répartition des segments \(control.segmentDistribution.rawValue)")
    }

    /// Une barre témoin construite comme celle de `SettingsView` (un `TabView` de `Tab` à image), de ces titres.
    struct Witness: View {
        let titles: [String]
        @State var selection = 0
        var body: some View {
            TabView(selection: $selection) {
                ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                    Tab(title, systemImage: "speaker.wave.2", value: index) { Color.clear }
                }
            }
            .frame(width: SettingsView.windowSize.width, height: SettingsView.windowSize.height)
        }
    }

    /// La vraie vue des réglages, huit onglets (historique branché) : la barre a besoin d'au plus la largeur de la fenêtre moins 20
    /// points de chaque côté. Témoin dans le même test : douze titres, même instrument, même largeur : « ne tient pas ».
    @Test func theEightTabsFitTheWindowWidthWithAMargin() throws {
        let rig = try AppControllerHistoryTests()
        try rig.saveSettings(retention: 30)
        defer { try? FileManager.default.removeItem(at: rig.directory) }
        let controller = rig.makeController(historyRoot: rig.root)
        let content = SettingsView.provider(catalog: rig.catalog, promptTokenLimit: 111)(controller)
        let titles = content.tabs.map(\.title)
        #expect(titles.count == 8)
        let width = SettingsView.windowSize.width

        let real = try Self.measure(content.view, width: width, name: "vraie vue")
        let crowded = try Self.measure(
            Witness(titles: (1...12).map { "Titre d'exemple \($0)" }), width: width, name: "témoin à douze titres")
        print("BARRE fenêtre \(width) : vraie vue \(real)")
        print("BARRE fenêtre \(width) : témoin \(crowded)")

        #expect(real.labels == titles, "les huit titres, dans l'ordre")
        #expect(!crowded.fits(windowWidth: width), "témoin : l'instrument sait dire « ne tient pas » (\(crowded))")
        #expect(crowded.need > real.need, "témoin : douze titres demandent plus que huit")
        #expect(
            real.fits(windowWidth: width),
            "la barre de huit onglets demande \(real.need) points, plus \(2 * Self.margin) de marge, pour une fenêtre de \(width)")
    }
}
