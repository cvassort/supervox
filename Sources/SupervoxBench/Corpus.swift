import Foundation
import SupervoxCore

/// Une phrase du corpus : l'identifiant, le texte de référence et les termes techniques
/// dont on mesure le rappel dans la transcription.
struct CorpusItem: Equatable {
    let id: String
    let text: String
    let terms: [String]
}

/// Les numéros de ligne sont 1-based et comptent les lignes de commentaire et les lignes vides.
enum CorpusError: Error, Equatable, CustomStringConvertible {
    case malformedLine(Int)
    case duplicateID(String, line: Int)
    case empty
    /// La suite de mots normalisés du terme n'apparaît pas dans sa propre phrase normalisée : même une transcription
    /// parfaite ne le trouverait pas.
    case termNotInText(String, line: Int)
    /// Le terme normalisé n'a aucun mot, ou un seul mot d'une seule lettre (« C++ » et « C# » deviennent « c ») : il
    /// serait trouvé dans toute phrase qui contient ce mot (« c'est » donne « c », « est »).
    case termTooShort(String, line: Int)

    var description: String {
        switch self {
        case .malformedLine(let line): "corpus, ligne \(line) : attendu id<TAB>texte<TAB>termes (3e colonne facultative)"
        case .duplicateID(let id, let line): "corpus, ligne \(line) : identifiant « \(id) » déjà utilisé"
        case .empty: "corpus vide"
        case .termNotInText(let term, let line):
            "corpus, ligne \(line) : le terme « \(term) » ne figure pas dans sa phrase une fois normalisé (casse, "
                + "ponctuation, apostrophes et traits d'union pliés) ; il ne pourrait jamais être trouvé"
        case .termTooShort(let term, let line):
            "corpus, ligne \(line) : le terme « \(term) » se réduit, une fois normalisé, à une seule lettre ou à rien ; "
                + "il serait trouvé dans des mots sans rapport (« c'est » contient « c »)"
        }
    }
}

/// Format : une phrase par ligne, `id<TAB>texte<TAB>terme1|terme2`.
///
/// - Lignes vides (ou blanches) et lignes dont le premier caractère non blanc est `#` : ignorées.
/// - La 3e colonne (termes) peut être vide, ou absente (tabulation finale retirée par un éditeur).
/// - Plus de 3 colonnes : refusé (une tabulation dans le texte décalerait les termes en silence).
/// - Identifiant et texte sont rognés puis doivent être non vides ; les termes sont rognés, les vides écartés.
/// - Fins de ligne `\n` ou `\r\n` ; un BOM UTF-8 initial est ignoré.
/// - Chaque terme doit pouvoir être trouvé par une transcription parfaite de sa phrase, avec la règle du rappel des
///   termes (`TermRecall`, mots normalisés contigus) ; un terme qui se réduit à une lettre ou à rien est refusé.
enum Corpus {
    static func parse(_ contents: String) throws -> [CorpusItem] {
        var items: [CorpusItem] = []
        var seen: Set<String> = []

        // `\r\n` est un seul Character en Swift : on le teste explicitement, `split(separator: "\n")` ne le couperait pas.
        // On ne s'appuie pas sur `isNewline` : il couperait aussi sur U+2028, U+0085, etc. qui peuvent figurer dans un texte.
        let lines = contents.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }

        for (offset, rawLine) in lines.enumerated() {
            let number = offset + 1
            var line = Substring(rawLine)
            if number == 1, line.first == "\u{FEFF}" { line = line.dropFirst() }

            // Le test blanc/commentaire se fait sur une copie rognée ; le découpage en colonnes, sur la ligne brute,
            // sinon une tabulation initiale (id vide) serait avalée et décalerait toutes les colonnes.
            let probe = line.trimmingCharacters(in: .whitespaces)
            if probe.isEmpty || probe.hasPrefix("#") { continue }

            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 2 || columns.count == 3 else { throw CorpusError.malformedLine(number) }

            let id = columns[0].trimmingCharacters(in: .whitespaces)
            let text = columns[1].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !text.isEmpty else { throw CorpusError.malformedLine(number) }
            guard seen.insert(id).inserted else { throw CorpusError.duplicateID(id, line: number) }

            let terms = columns.count == 3
                ? columns[2].split(separator: "|", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                : []
            for term in terms {
                let words = TextNormalizer.words(term)
                if words.isEmpty || (words.count == 1 && words[0].count == 1) {
                    throw CorpusError.termTooShort(term, line: number)
                }
                guard TermRecall.compute(terms: [term], hypothesis: text).found == 1 else {
                    throw CorpusError.termNotInText(term, line: number)
                }
            }
            items.append(CorpusItem(id: id, text: text, terms: terms))
        }

        guard !items.isEmpty else { throw CorpusError.empty }
        return items
    }

    static func load(from url: URL) throws -> [CorpusItem] {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}
