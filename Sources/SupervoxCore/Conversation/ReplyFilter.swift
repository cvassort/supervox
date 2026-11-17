import Foundation

/// Le marqueur que le modèle écrit en tête de sa réponse d'entretien. `ReplyFilter` retire de ce qui est dit et montré le marqueur
/// **tel que la consigne le demande** : le mot en majuscules ou en minuscules, entre crochets, d'un seul tenant. Il ne retire
/// pas ce qu'il ne reconnaît pas (`[ SUITE ]`, `[SUITE` sans crochet fermant, `SUITE:`), qui est alors dit ; et un marqueur
/// précédé d'un caractère invisible (U+200B, U+FEFF…) ou entouré de signes (`**[SUITE]**`) est retiré mais ne fixe pas `signal`
/// (relevé à la revue, non corrigé). Rien ne garantit donc qu'aucun marqueur n'est jamais montré, seulement que celui de la
/// consigne ne l'est pas.
public enum ReplySignal: String, Equatable, Sendable {
    /// `[SUITE]` : la réponse pose une question.
    case `continue` = "SUITE"
    /// `[PROPOSER]` : la réponse demande si l'on peut conclure.
    case propose = "PROPOSER"
    /// `[CONCLURE]` : la personne veut conclure, ou a accepté : la réponse n'est qu'une courte phrase de fin.
    case conclude = "CONCLURE"
}

/// Retire des réponses du modèle le marqueur de conclusion, et en lit le sens.
///
/// `feed` reçoit le texte visible **cumulé** (celui de `Rewriter`/`onText`, bloc de raisonnement déjà retiré) et rend le texte
/// nouveau, sans marqueur ; `finish` rend ce qui était retenu. Tout ce qui est rendu est définitif : un texte rendu n'est jamais
/// repris, un texte qui pourrait devenir un marqueur est retenu. Le résultat ne dépend donc pas de la façon dont le texte est
/// coupé en morceaux.
///
/// Les caractères sont des scalaires Unicode (une marque combinante collée à `]` ne cache pas le marqueur, et les longueurs ne
/// dépendent pas du regroupement en graphèmes).
///
/// - **Tête** : l'espace blanc de début, puis, si le premier caractère est `[`, le texte jusqu'au premier `]` (inclus), au premier
///   saut de ligne (exclu) ou au 12ᵉ caractère. Tant qu'elle n'est pas décidée, rien n'est rendu. Une tête `[MOT]` (lettres seules,
///   casse ignorée) est retirée avec l'espace blanc qui la suit (le texte rendu commence au premier mot) ; `MOT` connu fixe
///   `signal`, inconnu le laisse à `.continue`. Toute autre tête est du texte.
/// - **Ailleurs** : toute occurrence d'un marqueur connu (casse ignorée, crochets compris) est retirée, et le retrait n'en
///   fabrique pas un autre (`[SU[SUITE]ITE]` ne rend rien). Une fin de texte qui peut encore devenir un marqueur connu est
///   retenue jusqu'à ce qu'il le devienne ou ne le puisse plus ; `finish` rend ce qui reste. La retenue n'a pas de borne (hors
///   tête) : c'est ce qui garde le texte rendu indépendant du découpage, y compris pour des marqueurs imbriqués. Coût et retenue
///   non bornés, parqués : le travail est quadratique en la longueur du texte, et une suite de `[` reste retenue jusqu'à `finish`.
/// - **Texte cumulé qui ne prolonge pas le précédent** : seuls les caractères au-delà de la longueur déjà lue sont pris.
///
/// Ce que ce n'est pas : un marqueur mal écrit par le modèle (`[ SUITE ]`, `[SUITE` sans crochet fermant, `SUITE:`) n'est pas
/// reconnu, et est donc rendu ; seule la consigne de l'intervieweur le prévient.
public struct ReplyFilter: Sendable {
    /// Le sens du marqueur de tête ; `.continue` tant qu'il n'y en a pas.
    public private(set) var signal: ReplySignal = .continue

    /// Tout le texte reçu, en scalaires Unicode.
    private var received: [Unicode.Scalar] = []
    /// Ce qui a déjà été rendu, en scalaires.
    private var emitted = 0

    public init() {}

    /// `visible` est le texte visible cumulé jusque-là. Rend le texte nouveau, sans marqueur.
    public mutating func feed(_ visible: String) -> String {
        let scalars = Array(visible.unicodeScalars)
        if scalars.starts(with: received) {
            received = scalars
        } else if scalars.count > received.count {
            received += scalars[received.count...]
        }
        return advance(isComplete: false)
    }

    /// La réponse est finie : rend ce qui était retenu (une tête qui n'a jamais été décidée, un début de marqueur final).
    public mutating func finish() -> String {
        advance(isComplete: true)
    }

    // MARK: - Lecture

    private mutating func advance(isComplete: Bool) -> String {
        let rendered = Self.render(received, isComplete: isComplete)
        if let head = rendered.signal { signal = head }
        guard rendered.text.count > emitted else { return "" }
        defer { emitted = rendered.text.count }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: rendered.text[emitted...])
        return String(out)
    }

    private static let markers: [(word: String, signal: ReplySignal)] = [.continue, .propose, .conclude].map { ($0.rawValue.lowercased(), $0) }
    /// Les marqueurs en minuscules, crochets compris.
    private static let bracketed = markers.map { "[\($0.word)]" }
    /// La longueur d'une tête, au plus (le plus long marqueur en fait 10 : choix non mesuré, de la marge).
    private static let maxHeadLength = 12

    /// Le texte à rendre pour tout ce qui a été reçu, et le sens du marqueur de tête s'il est décidé. Fonction pure du texte
    /// reçu : ce qui est rendu pour un texte l'est aussi, en début, pour tout texte qui le prolonge.
    private static func render(_ received: [Unicode.Scalar], isComplete: Bool) -> (text: [Unicode.Scalar], signal: ReplySignal?) {
        let start = received.firstIndex { !$0.properties.isWhitespace } ?? received.endIndex
        let rest = received[start...]
        guard let first = rest.first else {
            return (isComplete ? received : [], nil)   // rien que de l'espace blanc : la tête n'est pas décidée
        }
        guard first == "[" else {
            return (strip(received, droppingLeadingWhitespace: false, isComplete: isComplete), nil)
        }
        let window = rest.prefix(maxHeadLength)
        let close = window.firstIndex { $0 == "]" || isLineBreak($0) }
        guard let close else {
            if rest.count < maxHeadLength, !isComplete { return ([], nil) }   // la tête peut encore s'allonger
            return (strip(received, droppingLeadingWhitespace: false, isComplete: isComplete), nil)
        }
        let word = rest[rest.index(after: rest.startIndex)..<close]
        guard rest[close] == "]", !word.isEmpty, word.allSatisfy({ $0.properties.isAlphabetic }) else {
            return (strip(received, droppingLeadingWhitespace: false, isComplete: isComplete), nil)
        }
        let known = markers.first { $0.word == String(String.UnicodeScalarView(word)).lowercased() }?.signal
        let after = Array(received[rest.index(after: close)...])
        return (strip(after, droppingLeadingWhitespace: true, isComplete: isComplete), known)
    }

    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.newlines.contains(scalar)
    }

    /// Retire de `text` tout marqueur connu et rend ce qui peut être dit : sans, si la réponse n'est pas finie, la fin qui peut
    /// encore devenir un marqueur. `droppingLeadingWhitespace` : l'espace blanc qui suit un marqueur de tête est retiré, jusqu'au
    /// premier mot.
    ///
    /// Le texte est lu de gauche à droite en gardant ce qui est retenu : dès qu'un `]` arrive, si la fin de ce qui est gardé
    /// est un marqueur, on la retire. Le retrait ne laisse donc jamais un marqueur formé par les morceaux qui l'entouraient.
    private static func strip(_ text: [Unicode.Scalar], droppingLeadingWhitespace: Bool, isComplete: Bool) -> [Unicode.Scalar] {
        var kept: [Unicode.Scalar] = []
        for scalar in text {
            if droppingLeadingWhitespace, kept.isEmpty, scalar.properties.isWhitespace { continue }
            kept.append(scalar)
            if scalar == "]", let length = markerLength(endingAt: kept) { kept.removeLast(length) }
        }
        guard !isComplete else { return kept }
        return Array(kept[..<(kept.count - heldLength(kept))])
    }

    /// La longueur du marqueur connu qui termine `kept` (celui qui commence au dernier `[`), `nil` s'il n'y en a pas.
    private static func markerLength(endingAt kept: [Unicode.Scalar]) -> Int? {
        guard let open = kept.lastIndex(of: "["), kept.count - open <= maxHeadLength else { return nil }
        let candidate = String(String.UnicodeScalarView(kept[open...])).lowercased()
        return bracketed.contains(candidate) ? kept.count - open : nil
    }

    /// La longueur de la fin de `kept` à retenir : la suite de segments `[lettres` collés qui terminent le texte, chacun début d'un
    /// marqueur connu. Un seul ne suffit pas : `[SU[SUITE]ITE]` laisse `[SU` derrière le marqueur du milieu, qui retiré fait de
    /// `[SU` + `ITE]` un marqueur.
    private static func heldLength(_ kept: [Unicode.Scalar]) -> Int {
        var segmentEnd = kept.count
        while let open = kept[..<segmentEnd].lastIndex(of: "[") {
            let segment = String(String.UnicodeScalarView(kept[open..<segmentEnd])).lowercased()
            guard bracketed.contains(where: { $0.hasPrefix(segment) && $0 != segment }) else { break }
            segmentEnd = open
        }
        return kept.count - segmentEnd
    }
}
