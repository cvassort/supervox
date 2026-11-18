import AVFAudio
import Foundation

/// Le genre d'une voix du système, quand le système le précise (`nil` : non précisé).
public enum SystemVoiceGender: String, Sendable, Equatable {
    case female, male
}

public struct SystemVoiceInfo: Equatable, Sendable {
    public var identifier: String
    public var language: String
    /// Qualité de la voix : 1 défaut, 2 améliorée, 3 premium (valeurs d'`AVSpeechSynthesisVoiceQuality`, code lu).
    public var quality: Int
    /// Le nom que le système donne à la voix ; vide s'il n'est pas connu.
    public var name: String
    public var gender: SystemVoiceGender?

    public init(identifier: String, language: String, quality: Int, name: String = "", gender: SystemVoiceGender? = nil) {
        self.identifier = identifier
        self.language = language
        self.quality = quality
        self.name = name
        self.gender = gender
    }
}

/// Les voix installées sur la machine. `installed` est le seul endroit du dépôt qui demande la liste au système (garde de
/// `SourceScanTests`) ; seul le programme l'appelle, et la voix du système par son constructeur public.
public enum SystemVoices {
    public static let installed: @Sendable () -> [SystemVoiceInfo] = {
        AVSpeechSynthesisVoice.speechVoices().map {
            SystemVoiceInfo(identifier: $0.identifier, language: $0.language, quality: $0.quality.rawValue, name: $0.name,
                            gender: gender($0.gender))
        }
    }

    /// Cas par cas (AVSpeechSynthesis.h : `Unspecified`, `Male`, `Female`) ; non précisé ou inconnu : `nil`.
    static func gender(_ gender: AVSpeechSynthesisVoiceGender) -> SystemVoiceGender? {
        switch gender {
        case .female: .female
        case .male: .male
        case .unspecified: nil
        @unknown default: nil
        }
    }
}

/// Dit une phrase par une voix du système (`AVSpeechSynthesizer.write`), rendue en un seul clip.
///
/// Le choix de la voix et le montage des morceaux se testent avec un `render` double ; le vrai `render`
/// (`AVSpeechBufferSource` sous `SpeechRendering`) appelle le système et n'est exécuté que par l'essai d'intégration
/// `SUPERVOX_SPEECH=1`.
public final class SystemSpeechSynthesizer: SpeechSynthesizer {
    /// Secondes laissées à un `write` avant `SpeechError.timedOut` : 8, choix non mesuré ; premier tampon mesuré jusqu'à 1,6 s sur
    /// une machine (3 passages, une phrase de 3,5 s, flux entier en 33 à 42 ms) ; la durée d'une phrase longue n'est pas mesurée.
    static let renderTimeout: Double = 8

    private let language: String
    /// La voix désignée par l'utilisateur ; `nil`, ou absente de la machine : la meilleure voix de la langue.
    private let identifier: String?
    private let voices: @Sendable () -> [SystemVoiceInfo]
    private let render: @Sendable (_ text: String, _ voiceIdentifier: String) async throws -> [AudioClip]

    public convenience init(language: String, identifier: String? = nil) {
        self.init(
            language: language,
            identifier: identifier,
            voices: SystemVoices.installed,
            render: { text, voice in
                try await Self.renderBySystem(text: text, voiceIdentifier: voice, language: language)
            })
    }

    init(language: String, identifier: String? = nil, voices: @escaping @Sendable () -> [SystemVoiceInfo],
         render: @escaping @Sendable (_ text: String, _ voiceIdentifier: String) async throws -> [AudioClip]) {
        self.language = language
        self.identifier = identifier
        self.voices = voices
        self.render = render
    }

    public func synthesize(_ text: String) async throws -> Speech {
        try Task.checkCancellation()
        guard let voice = Self.pickVoice(language: language, identifier: identifier, among: voices()) else {
            throw SpeechError.noVoice(language: language)
        }
        guard !text.isBlankForSpeech else { throw SpeechError.empty }
        let chunks: [AudioClip]
        do {
            chunks = try await render(text, voice.identifier)
        } catch {
            // Une panne levée parce qu'on annule reste une annulation, quelle que soit sa forme.
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        // Un `render` qui n'écoute pas l'annulation et rend quand même ses morceaux : la parole n'est pas livrée.
        try Task.checkCancellation()
        return Speech(clip: try Self.joined(chunks))
    }

    /// La voix désignée si elle est installée, quelle que soit sa langue ; sinon (identifiant `nil` ou absent de la liste) la
    /// meilleure voix de la langue, par `pickVoice(language:among:)`.
    static func pickVoice(language: String, identifier: String?, among voices: [SystemVoiceInfo]) -> SystemVoiceInfo? {
        if let identifier, let designated = voices.first(where: { $0.identifier == identifier }) { return designated }
        return pickVoice(language: language, among: voices)
    }

    /// La voix de la langue exacte d'abord (`fr-FR`), puis toute voix de la même langue (`fr-…`) ; à égalité, la meilleure
    /// qualité, et à qualité égale la première de la liste. `nil` s'il n'y en a aucune.
    static func pickVoice(language: String, among voices: [SystemVoiceInfo]) -> SystemVoiceInfo? {
        func tag(_ language: String) -> String { language.replacingOccurrences(of: "_", with: "-").lowercased() }
        func primary(_ language: String) -> Substring { tag(language).split(separator: "-", maxSplits: 1).first ?? "" }
        func best(_ candidates: [SystemVoiceInfo]) -> SystemVoiceInfo? {
            candidates.reduce(nil) { best, voice in
                guard let best else { return voice }
                return voice.quality > best.quality ? voice : best
            }
        }
        let wanted = tag(language)
        if let exact = best(voices.filter { tag($0.language) == wanted }) { return exact }
        let wantedPrimary = primary(language)
        guard !wantedPrimary.isEmpty else { return nil }
        return best(voices.filter { primary($0.language) == wantedPrimary })
    }

    /// Le premier canal d'un tampon, en flottants dans [-1, 1] (les flottants hors plage sont écrêtés, NaN devient du silence ;
    /// l'entier 16 bits est divisé par 32 768), à la fréquence du tampon. `nil` pour un tampon de longueur nulle, sans données
    /// lisibles (ni flottantes ni entières 16 bits) ou de fréquence nulle. Le format n'est pas supposé : on lit celui du tampon.
    static func clip(from buffer: AVAudioPCMBuffer) -> AudioClip? {
        let frames = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        guard frames > 0, rate > 0 else { return nil }
        let stride = buffer.stride   // 1 non entrelacé ; le nombre de canaux, entrelacé
        if let channels = buffer.floatChannelData {
            let first = channels[0]
            return AudioClip(samples: (0..<frames).map { i in
                let v = first[i * stride]
                return v.isNaN ? 0 : max(-1, min(1, v))
            }, sampleRate: rate)
        }
        if let channels = buffer.int16ChannelData {
            let first = channels[0]
            return AudioClip(samples: (0..<frames).map { Float(first[$0 * stride]) / 32768 }, sampleRate: rate)
        }
        return nil
    }

    /// Un seul clip, dans l'ordre, à la fréquence du premier morceau lisible. Aucun échantillon : `.empty`. Un morceau que le
    /// rééchantillonnage ne sait pas convertir (il rend alors du vide) fait aussi échouer : on ne livre pas une parole trouée.
    static func joined(_ chunks: [AudioClip]) throws -> AudioClip {
        let usable = chunks.filter { !$0.samples.isEmpty && $0.sampleRate > 0 }
        guard let first = usable.first else { throw SpeechError.empty }
        var samples = first.samples
        for chunk in usable.dropFirst() {
            let piece = chunk.sampleRate == first.sampleRate ? chunk : Resampler.resample(chunk, to: first.sampleRate)
            guard !piece.samples.isEmpty else { throw SpeechError.empty }
            samples += piece.samples
        }
        return AudioClip(samples: samples, sampleRate: first.sampleRate)
    }

    /// Le vrai `render` : le synthétiseur du système, confiné au fil principal, gardé vivant jusqu'à la fin.
    @MainActor
    private static func renderBySystem(text: String, voiceIdentifier: String, language: String) async throws -> [AudioClip] {
        let source = AVSpeechBufferSource(language: language)
        defer { withExtendedLifetime(source) {} }   // vivante jusqu'au retour, quoi que l'optimiseur pense de ses usages
        return try await SpeechRendering.render(text: text, voiceIdentifier: voiceIdentifier, source: source, timeout: renderTimeout,
                                                sleep: { try await Task.sleep(for: .seconds($0)) })
    }
}
