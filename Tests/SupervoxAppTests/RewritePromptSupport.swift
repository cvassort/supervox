import Foundation
import Testing
import SupervoxCore

/// Une source de hasard qui rend toujours la même valeur : de quoi refaire, dans un test, la requête que l'application a composée
/// avec un suffixe tiré au hasard, une fois ce suffixe lu dans la requête envoyée.
struct ReplayedBits: RandomNumberGenerator {
    let value: UInt64
    mutating func next() -> UInt64 { value }
}

/// La requête que `RewritePrompt` compose pour les mêmes données, au suffixe de la requête réellement envoyée (`sentInput`).
enum ExpectedPrompt {
    /// Le suffixe des balises `<nom-…>` en tête de `sentInput` : seize chiffres hexadécimaux minuscules, sinon le test échoue.
    static func suffixValue(of sentInput: String, tag: String) -> UInt64? {
        let opening = "<\(tag)-"
        guard sentInput.hasPrefix(opening), let end = sentInput.firstIndex(of: ">") else {
            Issue.record("la requête envoyée ne commence pas par <\(tag)-…> : \(sentInput.prefix(40))")
            return nil
        }
        let digits = String(sentInput[sentInput.index(sentInput.startIndex, offsetBy: opening.count)..<end])
        guard digits.count == 16, digits.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), let value = UInt64(digits, radix: 16) else {
            Issue.record("suffixe de balise inattendu : \(digits)")
            return nil
        }
        return value
    }

    static func format(sentInput: String, instruction: String, text: String, vocabulary: [String]) -> (instruction: String, input: String) {
        guard let value = suffixValue(of: sentInput, tag: "dictee") else { return ("", "") }
        var source = ReplayedBits(value: value)
        return RewritePrompt.format(instruction: instruction, text: text, vocabulary: vocabulary, using: &source)
    }

    static func correction(sentInput: String, text: String, change: String, vocabulary: [String]) -> (instruction: String, input: String) {
        guard let value = suffixValue(of: sentInput, tag: "texte") else { return ("", "") }
        var source = ReplayedBits(value: value)
        return RewritePrompt.correction(text: text, change: change, vocabulary: vocabulary, using: &source)
    }
}
