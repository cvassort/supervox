import AVFAudio
import CoreMedia
import Foundation
import Speech
import SupervoxCore

/// Transcription locale d'Apple : `SpeechAnalyzer` avec le module `SpeechTranscriber` (macOS 26+).
///
/// Vocabulaire : non transmis. La documentation du SDK ne décrit les « contextual strings » d'`AnalysisContext` que
/// pour `DictationTranscriber`, pas pour `SpeechTranscriber` ; le moteur est mesuré une seule fois.
///
/// Un analyseur ne sert qu'à une phrase (il est terminé à la fin de l'entrée) : `transcribe` en crée un neuf, avec
/// un modèle gardé en mémoire pour toute la vie du processus (`modelRetention: .processLifetime`), et le chargement
/// initial est fait dans `prepare()`.
public actor AppleSpeechTranscriber: Transcriber {
    public nonisolated let name = "apple"
    public nonisolated var measurementConditions: String {
        "ressources de la locale installées et modèle gardé en mémoire pour la vie du processus, préchauffé avant "
            + "chaque passe sur 2 s de bruit, hors chrono. Durée mesurée : conversion du tampon au format de "
            + "l'analyseur, création d'un SpeechTranscriber et d'un SpeechAnalyzer neufs, prepareToAnalyze, analyse "
            + "et finalisation de la phrase."
    }
    private let localeIdentifier: String
    private var prepared: (locale: Locale, format: AVAudioFormat)?

    /// `locale` : identifiant de locale, ex. `fr-FR`.
    public init(locale: String) {
        self.localeIdentifier = locale
    }

    public func prepare() async throws {
        if prepared != nil { return }
        guard SpeechTranscriber.isAvailable else {
            throw TranscriberError.engine("SpeechTranscriber indisponible sur cette machine")
        }
        // Correspondance par le framework, pas par `==` : « fr-FR » et « fr_FR » désignent la même locale.
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw TranscriberError.unsupportedLocale(localeIdentifier)
        }
        let module = Self.module(locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError.engine("aucun format audio compatible avec SpeechTranscriber (\(locale.identifier))")
        }
        self.prepared = (locale: locale, format: format)
    }

    public func warmUp(vocabulary: [String]) async throws {
        guard let prepared else { throw TranscriberError.notPrepared(name) }
        _ = try await run(warmUpClip(), prepared)
    }

    public func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        try TranscriberError.check16kHz(clip)
        guard let prepared else { throw TranscriberError.notPrepared(name) }
        return try await run(clip, prepared)
    }

    private static func module(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .transcription)
    }

    private func run(_ clip: AudioClip, _ prepared: (locale: Locale, format: AVAudioFormat)) async throws -> String {
        let buffer = try Self.buffer(clip, in: prepared.format)
        let module = Self.module(prepared.locale)
        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        try await analyzer.prepareToAnalyze(in: prepared.format)

        // Les résultats sont lus pendant l'analyse ; la séquence se termine quand l'analyseur a fini.
        let results = module.results
        let collector = Task {
            var parts: [String] = []
            for try await result in results where result.isFinal {
                parts.append(String(result.text.characters))
            }
            return parts
        }

        let (input, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        do {
            if let end = try await analyzer.analyzeSequence(input) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            await analyzer.cancelAndFinishNow()
            collector.cancel()
            throw error
        }
        let parts = try await collector.value
        return parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Convertit le clip (Float32 mono 16 kHz) dans le format demandé par l'analyseur.
    private static func buffer(_ clip: AudioClip, in format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clip.sampleRate,
                                               channels: 1, interleaved: false),
              let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(clip.samples.count))
        else { throw TranscriberError.engine("tampon audio impossible à créer") }
        source.frameLength = AVAudioFrameCount(clip.samples.count)
        clip.samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
        if format == sourceFormat { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw TranscriberError.engine("conversion vers \(format) impossible")
        }
        let capacity = AVAudioFrameCount(Double(clip.samples.count) * format.sampleRate / clip.sampleRate) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw TranscriberError.engine("tampon audio impossible à créer")
        }
        nonisolated(unsafe) var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered { inputStatus.pointee = .endOfStream; return nil }
            delivered = true
            inputStatus.pointee = .haveData
            return source
        }
        if status == .error || error != nil {
            throw TranscriberError.engine("conversion audio échouée : \(error.map { String(describing: $0) } ?? "statut d'erreur")")
        }
        return output
    }
}
