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
