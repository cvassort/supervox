import Foundation

/// Une phrase du corpus : l'identifiant, le texte de référence et les termes techniques
/// dont on mesure le rappel dans la transcription.
struct CorpusItem: Equatable {
    let id: String
    let text: String
    let terms: [String]
}

/// Les numéros de ligne sont 1-based et comptent les lignes de commentaire et les lignes vides.
enum CorpusError: Error, Equatable {
    case malformedLine(Int)
    case duplicateID(String, line: Int)
    case empty
}

/// Format : une phrase par ligne, `id<TAB>texte<TAB>terme1|terme2`.
///
/// - Lignes vides (ou blanches) et lignes dont le premier caractère non blanc est `#` : ignorées.
/// - La 3e colonne (termes) peut être vide, ou absente (tabulation finale retirée par un éditeur).
/// - Plus de 3 colonnes : refusé (une tabulation dans le texte décalerait les termes en silence).
/// - Identifiant et texte sont rognés puis doivent être non vides ; les termes sont rognés, les vides écartés.
/// - Fins de ligne `\n` ou `\r\n` ; un BOM UTF-8 initial est ignoré.
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
            items.append(CorpusItem(id: id, text: text, terms: terms))
        }

        guard !items.isEmpty else { throw CorpusError.empty }
        return items
    }

    static func load(from url: URL) throws -> [CorpusItem] {
        try parse(String(contentsOf: url, encoding: .utf8))
    }
}
