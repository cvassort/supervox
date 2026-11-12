import Foundation
import Testing
@testable import SupervoxBench

// MARK: - Comportement de référence

@Test func parsesItemsAndSkipsComments() throws {
    let items = try Corpus.parse("# corpus\np01\tLe worker Celery plante.\tworker Celery\n\np02\tBonjour.\t\n")
    #expect(items == [CorpusItem(id: "p01", text: "Le worker Celery plante.", terms: ["worker Celery"]),
                      CorpusItem(id: "p02", text: "Bonjour.", terms: [])])
}
@Test func reportsLineNumberOfMalformedLine() {
    #expect(throws: CorpusError.malformedLine(2)) { try Corpus.parse("p01\tA.\t\nligne sans tabulation\n") }
}
@Test func rejectsDuplicateIDsAndEmptyCorpus() {
    #expect(throws: CorpusError.duplicateID("p01", line: 2)) { try Corpus.parse("p01\tA.\t\np01\tB.\t\n") }
    #expect(throws: CorpusError.empty) { try Corpus.parse("# rien\n") }
}

// MARK: - Fins de ligne et numérotation

/// En Swift, "\r\n" est un seul Character : un `split(separator: "\n")` naïf ne couperait pas
/// un fichier CRLF. On vérifie que les lignes sont bien séparées, qu'aucun "\r" ne reste collé
/// au dernier champ, et que la numérotation compte les lignes de commentaire et les lignes vides.
@Test func handlesWindowsLineEndings() throws {
    let items = try Corpus.parse("# c\r\np01\tA.\tx|y\r\n\r\np02\tB.\t\r\n")
    #expect(items == [CorpusItem(id: "p01", text: "A.", terms: ["x", "y"]),
                      CorpusItem(id: "p02", text: "B.", terms: [])])
    // Ligne fautive = 4e ligne physique (commentaire + vide comptés), pas le 2e item.
    #expect(throws: CorpusError.malformedLine(4)) {
        try Corpus.parse("# c\r\np01\tA.\t\r\n\r\nsans tabulation\r\n")
    }
}

@Test func lineNumbersCountCommentsAndBlankLines() {
    #expect(throws: CorpusError.malformedLine(4)) {
        try Corpus.parse("# a\n\np01\tA.\t\nmauvaise\n")
    }
    #expect(throws: CorpusError.duplicateID("p01", line: 5)) {
        try Corpus.parse("# a\np01\tA.\t\n\n# b\np01\tB.\t\n")
    }
}

@Test func lastLineWithoutTrailingNewlineIsKept() throws {
    let items = try Corpus.parse("p01\tA.\t\np02\tB.\tt")
    #expect(items.map(\.id) == ["p01", "p02"])
    #expect(items[1].terms == ["t"])
}

@Test func stripsLeadingByteOrderMark() throws {
    // Un export tableur en UTF-8 avec BOM ne doit pas coller U+FEFF à l'identifiant ni masquer un commentaire.
    let items = try Corpus.parse("\u{FEFF}p01\tA.\t\n")
    #expect(items.first?.id == "p01")
    #expect(try Corpus.parse("\u{FEFF}# c\np01\tA.\t\n").count == 1)
}

// MARK: - Colonnes

@Test func acceptsMissingThirdColumnButRejectsExtraColumns() throws {
    // Beaucoup d'éditeurs retirent la tabulation finale : « id<TAB>texte » équivaut à « id<TAB>texte<TAB> ».
    #expect(try Corpus.parse("p01\tA.\n") == [CorpusItem(id: "p01", text: "A.", terms: [])])
    // Une tabulation dans le texte décalerait silencieusement les termes : on refuse, avec le numéro de ligne.
    #expect(throws: CorpusError.malformedLine(1)) { try Corpus.parse("p01\tA\tB.\tterme\n") }
    #expect(throws: CorpusError.malformedLine(2)) { try Corpus.parse("p01\tA.\t\np02\tB.\tt\t\n") }
}

@Test func rejectsEmptyIDOrEmptyText() {
    #expect(throws: CorpusError.malformedLine(1)) { try Corpus.parse("\tA.\tx\n") }
    #expect(throws: CorpusError.malformedLine(1)) { try Corpus.parse("   \tA.\tx\n") }
    #expect(throws: CorpusError.malformedLine(2)) { try Corpus.parse("p01\tA.\t\np02\t\tx\n") }
    #expect(throws: CorpusError.malformedLine(1)) { try Corpus.parse("p01\t   \tx\n") }
}

@Test func leadingTabIsNotSilentlyTrimmedAwayBeforeSplitting() {
    // « \tA.\tx » : id vide. Si on rognait la ligne entière avant de la découper, « A. » deviendrait l'id.
    #expect(throws: CorpusError.malformedLine(1)) { try Corpus.parse("\tA.\tx\n") }
}

@Test func trimsSpacesAroundFieldsAndTerms() throws {
    let items = try Corpus.parse("  p01 \t  Le worker plante.  \t worker Celery | pull request ||  | FastAPI \n")
    #expect(items == [CorpusItem(id: "p01", text: "Le worker plante.",
                                 terms: ["worker Celery", "pull request", "FastAPI"])])
}

@Test func whitespaceOnlyLinesAndIndentedCommentsAreIgnored() throws {
    let items = try Corpus.parse("   \n\t\t\n  # commentaire indenté\np01\tA.\t\n")
    #expect(items.map(\.id) == ["p01"])
}

@Test func duplicateIDsAreDetectedAfterTrimming() {
    #expect(throws: CorpusError.duplicateID("p01", line: 2)) { try Corpus.parse("p01\tA.\t\n p01 \tB.\t\n") }
}

@Test func preservesInputOrder() throws {
    let items = try Corpus.parse("p03\tC.\t\np01\tA.\t\np02\tB.\t\n")
    #expect(items.map(\.id) == ["p03", "p01", "p02"])
}

// MARK: - Chargement depuis un fichier

@Test func loadReadsUTF8FileWithAccents() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("corpus-\(UUID().uuidString).tsv")
    defer { try? FileManager.default.removeItem(at: url) }
    try "p01\tL'équipe déploie la mise à jour.\tmise à jour\n".write(to: url, atomically: true, encoding: .utf8)
    #expect(try Corpus.load(from: url)
        == [CorpusItem(id: "p01", text: "L'équipe déploie la mise à jour.", terms: ["mise à jour"])])
}

@Test func loadThrowsWhenFileIsMissing() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString).tsv")
    #expect(throws: (any Error).self) { try Corpus.load(from: url) }
}

@Test func committedExampleCorpusIsValid() throws {
    // #filePath : Tests/SupervoxBenchTests/CorpusTests.swift → racine du dépôt → Bench/corpus.example.tsv
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let items = try Corpus.load(from: root.appendingPathComponent("Bench/corpus.example.tsv"))
    #expect(items.count == 3)
    #expect(items.allSatisfy { !$0.text.isEmpty })
    #expect(items.contains { !$0.terms.isEmpty })
    // Chaque terme déclaré doit réellement figurer dans sa phrase, sinon le rappel de termes serait faussé d'office.
    for item in items {
        for term in item.terms {
            #expect(item.text.localizedCaseInsensitiveContains(term), "terme « \(term) » absent de \(item.id)")
        }
    }
}
