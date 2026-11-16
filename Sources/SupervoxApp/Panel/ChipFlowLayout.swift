import SwiftUI

/// Le retour à la ligne des pastilles : à partir des largeurs de chacune, les lignes qu'elles forment, dans l'ordre.
public enum ChipFlow {
    /// Remplit chaque ligne tant que la pastille suivante tient, `spacing` compris ; sinon elle ouvre la ligne suivante. Une
    /// pastille plus large que la place est seule sur sa ligne. Aucune ligne n'est vide ; l'ordre est celui de `widths`.
    public static func rows(widths: [CGFloat], available: CGFloat, spacing: CGFloat) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if index == start {
                used = width
            } else if used + spacing + width <= available {
                used += spacing + width
            } else {
                rows.append(start..<index)
                start = index
                used = width
            }
        }
        if start < widths.count { rows.append(start..<widths.count) }
        return rows
    }

    /// La largeur proposée à chaque pastille : la sienne, sans dépasser la place, et jamais négative (une place nulle, négative
    /// ou indéfinie ne donne rien de plus que zéro).
    public static func fitted(ideals: [CGFloat], available: CGFloat) -> [CGFloat] {
        ideals.map { min($0, max(0, available)) }
    }
}

/// Dispose ses enfants en lignes qui suivent `ChipFlow.rows` : sans largeur proposée (ou infinie), une seule ligne ; sinon, à la
/// ligne dès que la pastille suivante ne tient plus. Une pastille plus large que la place reçoit la place entière : son texte
/// passe sur plusieurs lignes plutôt que d'être coupé.
struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6
    var rowSpacing: CGFloat = 6

    /// Ce que la disposition mesure à chaque passage : la taille de chaque pastille, et les lignes qu'elles forment.
    struct Measure {
        var sizes: [CGSize]
        var rows: [Range<Int>]
    }

    private func measure(_ subviews: Subviews, available: CGFloat) -> Measure {
        let ideals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let widths = ChipFlow.fitted(ideals: ideals, available: available)
        let sizes = zip(subviews, widths).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        return Measure(
            sizes: sizes.enumerated().map { CGSize(width: widths[$0.offset], height: $0.element.height) },
            rows: ChipFlow.rows(widths: widths, available: available, spacing: spacing))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? .infinity
        let measure = measure(subviews, available: available)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for row in measure.rows {
            let rowWidth = row.map { measure.sizes[$0].width }.reduce(0, +) + spacing * CGFloat(row.count - 1)
            width = max(width, rowWidth)
            height += row.map { measure.sizes[$0].height }.max() ?? 0
        }
        if measure.rows.count > 1 { height += rowSpacing * CGFloat(measure.rows.count - 1) }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let measure = measure(subviews, available: bounds.width)
        var y = bounds.minY
        for row in measure.rows {
            var x = bounds.minX
            let rowHeight = row.map { measure.sizes[$0].height }.max() ?? 0
            for index in row {
                let size = measure.sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += rowHeight + rowSpacing
        }
    }
}
