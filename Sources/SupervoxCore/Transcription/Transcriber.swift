import Foundation

/// Un moteur de transcription en bloc : une phrase entière entre, son texte sort.
///
/// Contrat de mesure : `prepare()` charge le modèle (téléchargement, compilation, premier passage à vide) et n'est
/// jamais chronométré ; seul `transcribe` l'est. `prepare()` peut être appelé plusieurs fois : les appels suivants ne
/// rechargent rien.
public protocol Transcriber: Sendable {
    /// Nom court et unique du moteur dans un passage du banc (`whisperkit`, `parakeet`…).
    var name: String { get }
    /// `true` si le moteur sait tirer parti d'une liste de termes (amorce, contexte). Un moteur qui répond `false`
    /// reçoit quand même le paramètre `vocabulary` mais l'ignore ; le banc ne le mesure alors qu'une fois.
    var acceptsVocabulary: Bool { get }
    func prepare() async throws
    /// `clip` est à 16 kHz mono. `language` est un code ISO 639-1 (`fr`). `vocabulary` est la liste globale du banc,
    /// la même pour toutes les phrases, jamais les termes attendus d'une phrase.
    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String
}

extension Transcriber {
    /// Par défaut un moteur n'annonce pas de vocabulaire : l'annoncer à tort créerait une ligne « +vocab » trompeuse.
    public var acceptsVocabulary: Bool { false }
}

/// Fréquence attendue par tous les moteurs du banc.
public let transcriberSampleRate = 16000.0

/// Signal du passage à vide fait par les moteurs locaux dans `prepare()` : 2 s de bruit faible, toujours le même.
/// Mesuré avec WhisperKit : après un passage à vide sur du silence, la première phrase chronométrée prenait encore
/// ~0,1 s de plus que les suivantes (0,56 s contre 0,45 s) ; avec ce bruit, l'écart disparaît. Le silence fait
/// sortir le décodeur presque tout de suite et laisse froide une partie du chemin.
public func warmUpClip() -> AudioClip {
    var state: UInt64 = 0x5EED
    let samples = (0..<Int(transcriberSampleRate * 2)).map { _ -> Float in
        state = state &* 6364136223846793005 &+ 1442695040888963407   // générateur congruentiel : déterministe
        return Float(Int64(bitPattern: state >> 1) % 2000) / 20000      // amplitude dans ±0,1
    }
    return AudioClip(samples: samples, sampleRate: transcriberSampleRate)
}

public enum TranscriberError: Error, Equatable, CustomStringConvertible {
    /// Le clip n'est pas à 16 kHz : le moteur produirait un texte faux sans le dire.
    case unsupportedSampleRate(Double)
    /// `transcribe` appelé avant un `prepare()` réussi.
    case notPrepared(String)
    /// La locale demandée n'est pas proposée par le moteur.
    case unsupportedLocale(String)
    /// Le moteur ne peut pas prendre en compte le vocabulaire alors qu'il l'annonce (ex. tokenizer absent).
    case vocabularyUnavailable(String)
    /// Toute autre panne propre à un moteur, avec un message lisible.
    case engine(String)

    public var description: String {
        switch self {
        case .unsupportedSampleRate(let rate): "clip à \(Int(rate)) Hz, 16000 Hz attendus"
        case .notPrepared(let name): "moteur \(name) non préparé : prepare() doit réussir avant transcribe()"
        case .unsupportedLocale(let locale): "locale \(locale) non prise en charge par ce moteur"
        case .vocabularyUnavailable(let reason): "vocabulaire inutilisable : \(reason)"
        case .engine(let message): message
        }
    }

    /// Contrôle commun aux moteurs : refuse un clip qui n'est pas à 16 kHz.
    public static func check16kHz(_ clip: AudioClip) throws {
        guard clip.sampleRate == transcriberSampleRate else { throw TranscriberError.unsupportedSampleRate(clip.sampleRate) }
    }
}
