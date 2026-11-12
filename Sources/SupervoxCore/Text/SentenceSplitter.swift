import Foundation

/// Découpe en phrases un texte qui arrive par morceaux (la réponse d'un modèle en flux), pour envoyer chaque phrase
/// à la synthèse vocale dès qu'elle est complète.
///
/// La règle est volontairement simple et prévisible, et en cas de doute elle ne coupe pas : une coupe manquée donne
/// une phrase plus longue, une coupe à tort se fait entendre au milieu d'une phrase.
///
/// Une phrase se termine :
/// - après `.`, `?` ou `!`, suivis d'un espace ou d'une fin de ligne. Une suite de terminateurs (`?!`, `!!!`) compte
///   pour un seul ; c'est son dernier caractère qui décide : `?` ou `!` termine, `.` seul termine, `..`, `...` et
///   `…` ne terminent jamais (points de suspension) ;
/// - les guillemets et parenthèses fermants collés au terminateur restent dans la phrase (`« Pars ! »`, `(Il part.)`) ;
///   pour `»`, les espaces avant lui sont permis (typographie française) ;
/// - à chaque fin de ligne, même sans terminateur (un retour à la ligne est une pause à l'oral : listes, titres).
///
/// Un `.` ne termine pas une phrase : après une abréviation de la liste `abbreviations` (`M.`, `etc.`, `cf.`…), quand
/// il suit un nombre seul en début de phrase (`1. Ouvrir`, numérotation de liste), ni quand il est collé à ce qui suit
/// (`main.swift`, `v2.1`, `3.5`, `node.js`, une adresse web : seul un espace ou une fin de ligne autorise la coupe).
///
/// Un terminateur tout au bout du texte reçu attend le morceau suivant (le `.` de `3.` peut être celui de `3.5`) :
/// la dernière phrase d'une réponse ne sort que par `flush()`. Le terminateur suivi d'un espace en bout de morceau
/// sort tout de suite.
///
/// Ce que cette règle ne gère pas : les abréviations hors liste ; une phrase qui se termine vraiment par `etc.` (elle
/// est collée à la suivante) ; les guillemets fermants dont l'espace précédent arrive dans un morceau et le `»` dans
/// le suivant (`… ? ` puis `»` : le `»` ouvre alors la phrase suivante) ; un nombre qui termine vraiment une phrase
/// en son début (`2024. Une année`), pris pour une numérotation de liste ; un `?` ou `!` (avec son fermant) suivi
/// d'une suite de la même phrase, sans majuscule, coupe quand même (`« Tu viens ? » demanda-t-il.`) ; le balisage Markdown (`**Fin.**` n'est pas
/// coupé), les blocs de code, les adresses web suivies d'un point collé ; les guillemets non fermés dans une phrase.
///
/// Garde-fou : un texte de plus de `maxPendingLength` caractères sans coupe possible est coupé après la dernière
/// virgule, point-virgule ou deux-points suivi d'un espace parmi ses `maxPendingLength` premiers caractères, pour ne
/// pas faire attendre la voix indéfiniment. Sans une telle ponctuation, il reste en attente jusqu'à `flush()`.
public struct SentenceSplitter {
    /// Longueur (en caractères) au-delà de laquelle le garde-fou coupe à une virgule.
    public static let maxPendingLength = 300

    /// Abréviations, en minuscules et avec leur point final, après lesquelles un point ne termine pas la phrase.
    /// `n°` n'y figure pas : `°` n'est pas un terminateur, `n° 5` n'est jamais coupé.
    static let abbreviations: Set<String> = [
        "m.", "mm.", "mme.", "mlle.", "mr.", "mrs.", "dr.", "pr.", "st.",
        "etc.", "ex.", "cf.", "p.", "pp.", "vs.", "env.", "approx.", "fig.", "i.e.", "e.g.",
    ]

    private static let terminators: Set<Character> = [".", "?", "!", "…"]
    private static let closers: Set<Character> = ["\"", "'", "’", "”", "»", ")", "]", "}"]

    private var pending = ""

    public init() {}

    /// Ajoute un morceau de texte et rend les phrases désormais complètes, dans l'ordre, sans espaces autour.
    public mutating func feed(_ fragment: String) -> [String] {
        pending += fragment
        let chars = Array(pending)
        var sentences: [String] = []
        var start = 0
        var i = 0

        func emit(_ end: Int) {
            if let sentence = Self.sentence(chars[start..<end]) { sentences.append(sentence) }
        }
        func skipSpaces(after index: Int) {
            start = index
            while start < chars.count, chars[start].isWhitespace { start += 1 }
        }

        scan: while i < chars.count {
            let c = chars[i]
            if c.isNewline {
                emit(i)
                skipSpaces(after: i + 1)
                i = start
            } else if Self.terminators.contains(c) {
                switch Self.verdict(chars, runStart: i, segmentStart: start) {
                case .cut(let end):
                    emit(end)
                    skipSpaces(after: end)
                    i = start
                case .skip(let next):
                    i = next
                case .needMoreText:
                    break scan
                }
            } else {
                i += 1
            }
        }

        // Garde-fou : trop de texte sans coupe, on coupe à la dernière virgule.
        while chars.count - start > Self.maxPendingLength, let comma = Self.lastClauseBreak(chars, from: start) {
            emit(comma + 1)
            skipSpaces(after: comma + 1)
        }

        pending = String(chars[start...])
        return sentences
    }

    /// Rend le texte en attente (la fin de la réponse) et vide le découpeur. Nil s'il n'y a rien à dire.
    public mutating func flush() -> String? {
        defer { pending = "" }
        return Self.sentence(Array(pending)[...])
    }

    // MARK: - Règles

    private enum Verdict {
        /// Coupe : la phrase s'arrête à cet index (exclu).
        case cut(Int)
        /// Pas de coupe ici : on reprend la lecture à cet index.
        case skip(Int)
        /// Le texte reçu s'arrête trop tôt pour décider.
        case needMoreText
    }

    private static func verdict(_ chars: [Character], runStart: Int, segmentStart: Int) -> Verdict {
        var runEnd = runStart
        while runEnd < chars.count, terminators.contains(chars[runEnd]) { runEnd += 1 }

        // Fermants collés au terminateur, avec les espaces permis avant `»`.
        var end = runEnd
        while true {
            while end < chars.count, closers.contains(chars[end]) { end += 1 }
            var k = end
            while k < chars.count, chars[k].isWhitespace, !chars[k].isNewline { k += 1 }
            if k > end, k < chars.count, chars[k] == "»" { end = k + 1 } else { break }
        }
        guard end < chars.count else { return .needMoreText }
        guard chars[end].isWhitespace else { return .skip(end) }   // `main.swift`, `3.5`, `https://…` : collé à la suite
        return endsSentence(chars, runStart: runStart, runEnd: runEnd, segmentStart: segmentStart) ? .cut(end) : .skip(end)
    }

    private static func endsSentence(_ chars: [Character], runStart: Int, runEnd: Int, segmentStart: Int) -> Bool {
        switch chars[runEnd - 1] {
        case "?", "!":
            return true
        case "." where runEnd - runStart == 1:
            let before = chars[segmentStart..<runStart]
            let token = String(before.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "." }.reversed())
            if abbreviations.contains(token.lowercased() + ".") { return false }
            // Un nombre seul en début de phrase est une numérotation de liste : `1. Ouvrir le fichier`.
            let sentenceSoFar = before.drop { $0.isWhitespace }
            if !sentenceSoFar.isEmpty, sentenceSoFar.allSatisfy({ $0.isWholeNumber }) { return false }
            return true
        default:
            return false   // `..`, `...`, `…`
        }
    }

    /// La dernière virgule, point-virgule ou deux-points suivi d'un espace, parmi les `maxPendingLength` premiers
    /// caractères à partir de `start` : la phrase coupée ne dépasse jamais la limite, même reçue d'un seul bloc.
    private static func lastClauseBreak(_ chars: [Character], from start: Int) -> Int? {
        var i = min(chars.count - 2, start + maxPendingLength - 1)
        while i > start {
            if ",;:".contains(chars[i]), chars[i + 1].isWhitespace { return i }
            i -= 1
        }
        return nil
    }

    /// La phrase sans espaces autour, ou nil si elle ne contient ni lettre ni chiffre (`—`, `…` seuls : rien à dire).
    private static func sentence(_ chars: ArraySlice<Character>) -> String? {
        let text = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains { $0.isLetter || $0.isNumber } ? text : nil
    }
}
