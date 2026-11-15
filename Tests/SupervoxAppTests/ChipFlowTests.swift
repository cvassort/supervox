import AppKit
import SwiftUI
import Testing

@testable import SupervoxApp

/// Le retour à la ligne des pastilles du panneau : le calcul des lignes (`ChipFlow.rows`), puis la vue qui s'en sert.
@MainActor @Suite struct ChipFlowTests {
    @Test func everythingThatFitsIsOneRow() {
        #expect(ChipFlow.rows(widths: [100, 100, 100], available: 320, spacing: 10) == [0..<3])
        // Exactement la place : 100 + 10 + 100 = 210.
        #expect(ChipFlow.rows(widths: [100, 100], available: 210, spacing: 10) == [0..<2])
    }

    @Test func aChipThatDoesNotFitStartsTheNextRow() {
        // 100 + 10 + 100 = 210 tient dans 215 ; une troisième ferait 320.
        #expect(ChipFlow.rows(widths: [100, 100, 100], available: 215, spacing: 10) == [0..<2, 2..<3])
        // Un point de moins que la place exacte : la seconde passe à la ligne.
        #expect(ChipFlow.rows(widths: [100, 100], available: 209, spacing: 10) == [0..<1, 1..<2])
    }

    @Test func aChipWiderThanTheRoomIsAloneOnItsRow() {
        #expect(
            ChipFlow.rows(widths: [50, 400, 50, 50], available: 300, spacing: 10) == [0..<1, 1..<2, 2..<4])
        // Même en première position, et même seule.
        #expect(ChipFlow.rows(widths: [400], available: 300, spacing: 10) == [0..<1])
    }

    @Test func noRowIsEmptyAndTheOrderIsKept() {
        #expect(ChipFlow.rows(widths: [], available: 300, spacing: 10).isEmpty)
        let widths: [CGFloat] = [120, 80, 200, 40, 40, 40, 300, 10, 90, 90, 90]
        let rows = ChipFlow.rows(widths: widths, available: 250, spacing: 6)
        #expect(rows.allSatisfy { !$0.isEmpty })
        // Les lignes se suivent sans trou ni recouvrement : chaque pastille, une fois, dans l'ordre.
        #expect(rows.first?.lowerBound == 0)
        #expect(rows.last?.upperBound == widths.count)
        for (before, after) in zip(rows, rows.dropFirst()) { #expect(before.upperBound == after.lowerBound) }
        // Aucune ligne n'est plus large que la place, sauf une pastille seule.
        for row in rows where row.count > 1 {
            let used = widths[row].reduce(0, +) + 6 * CGFloat(row.count - 1)
            #expect(used <= 250)
        }
    }

    @Test func anInfiniteRoomKeepsOneRow() {
        #expect(ChipFlow.rows(widths: [500, 500, 500], available: .infinity, spacing: 6) == [0..<3])
    }

    // MARK: - La vue

    private static func panelHeight(modes: [ModeChip]) -> CGFloat {
        let model = PanelModel(lastModeID: ModeChip.rawID, modes: modes)
        let host = NSHostingView(
            rootView: PanelView(
                model: model, permissions: PermissionsModel(probe: ChipFlowProbe()), openSettings: {}, quit: {}))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    private static func named(_ count: Int) -> [ModeChip] {
        (0..<count).map { ModeChip(id: "mode-\($0)", title: "Un mode au nom assez long numéro \($0)") }
    }

    @Test func thePanelGrowsWhenTheChipsWrap() {
        let few = Self.panelHeight(modes: Self.named(2))
        let many = Self.panelHeight(modes: Self.named(12))
        #expect(many > few + 40, "douze pastilles à noms longs doivent tenir sur plusieurs lignes : \(few) contre \(many)")
    }

    /// La disposition elle-même, sur des enfants de taille fixe : cinq pastilles de 100 sur 250 de large font trois lignes
    /// (deux, deux, une), l'espace entre lignes compris. Une seule rangée, même contrainte, ferait 20.
    @Test func theLayoutStacksTheRowsItComputes() {
        let host = NSHostingView(
            rootView: ChipFlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(0..<5, id: \.self) { _ in Color.clear.frame(width: 100, height: 20) }
            }
            .frame(width: 250))
        host.layoutSubtreeIfNeeded()
        #expect(abs(host.fittingSize.height - CGFloat(3 * 20 + 2 * 6)) < 0.5, "\(host.fittingSize.height)")
        // La place suffit : une seule ligne.
        let wide = NSHostingView(
            rootView: ChipFlowLayout(spacing: 6, rowSpacing: 6) {
                ForEach(0..<5, id: \.self) { _ in Color.clear.frame(width: 100, height: 20) }
            }
            .frame(width: 600))
        wide.layoutSubtreeIfNeeded()
        #expect(abs(wide.fittingSize.height - 20) < 0.5, "\(wide.fittingSize.height)")
    }

    /// Un nom plus large que le panneau reste lisible en entier : sa pastille passe sur plusieurs lignes au lieu d'être coupée.
    @Test func aNameWiderThanThePanelWrapsInsteadOfBeingCut() {
        let one = Self.panelHeight(modes: [ModeChip(id: "a", title: "Court")])
        let long = Self.panelHeight(modes: [ModeChip(id: "a", title: String(repeating: "Un nom très long ", count: 12))])
        #expect(long > one + 20)
    }

    /// Dans le panneau : deux pastilles trop larges pour tenir ensemble font deux lignes d'une pastille chacune, sans que leur
    /// texte passe à la ligne (ce que ferait une rangée unique serrée dans la largeur du panneau).
    @Test func twoChipsTooWideForOneRowMakeTwoSingleLineRows() {
        let wide = String(repeating: "W", count: 24)
        let none = Self.panelHeight(modes: [])
        let one = Self.panelHeight(modes: [ModeChip(id: "a", title: wide)])
        let two = Self.panelHeight(modes: [ModeChip(id: "a", title: wide), ModeChip(id: "b", title: wide)])
        let chipHeight = one - none
        #expect(chipHeight > 15 && chipHeight < 40, "\(none) \(one)")
        #expect(abs(two - (one + chipHeight + 6)) < 0.5, "\(none) \(one) \(two)")
    }

    @Test func fourShortChipsStayOnOneRow() {
        let four = Self.panelHeight(modes: ModeChip.fixed)
        let one = Self.panelHeight(modes: [ModeChip.fixed[0]])
        #expect(four == one)
    }
}

private struct ChipFlowProbe: PermissionsProbe {
    func microphone() -> PermissionState { .granted }
    func accessibility() -> PermissionState { .granted }
    func requestMicrophone() async -> Bool { true }
    func promptAccessibility() {}
}
