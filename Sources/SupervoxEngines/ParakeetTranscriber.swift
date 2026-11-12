import FluidAudio
import Foundation
import SupervoxCore

/// Parakeet TDT 0.6B v3 (multilingue) par `AsrManager` de FluidAudio, entièrement local.
///
/// Vocabulaire : recalage de FluidAudio (`VocabularyBoostingSession`). Un second modèle, CTC 110M, passe sur le même
/// audio, repère les termes de la liste et remplace un mot de la transcription quand l'indice acoustique du terme est
/// plus fort que celui du mot. Réglages par défaut de la bibliothèque, sauf les deux seuils de similarité du passage
/// de « sauvetage » (`spotterRescueMinSimilarity` 0,30, `spotterRescueMultiWordMinSimilarity` 0,50), que la
/// documentation de FluidAudio recommande quand une grande partie de l'audio ne contient pas les termes, ce qui est
/// le cas d'une liste globale. Mesuré sans eux, avec 4 termes : « Le serveur web redémarre tous les matins. »
/// devenait « PostgreSQL Kubernetes. ».
///
/// Deux régimes selon la taille de la liste (FluidAudio 0.18.3, `largeVocabThreshold` = 10) : jusqu'à 10 termes, la
/// passe de sauvetage tourne avec ces seuils ; au-delà, elle ne tourne pas du tout (ces seuils sont alors sans effet)
/// et la similarité minimale passe de 0,50 à 0,55. La bibliothèque ignore aussi les termes de moins de 3 caractères
/// et ceux qui ne donnent aucun jeton CTC ; WhisperKit, lui, les reçoit dans son amorce.
///
/// Langue : aucune indication n'est passée au décodeur (`language: nil`, le défaut de la bibliothèque), quel que soit
/// le paramètre `language`. L'indication `Language.french` active dans FluidAudio une liste noire de pièces
/// SentencePiece anglaises (« so », « not », « her », « my », « we »…) qui sont aussi des débuts de mots français :
/// mesuré, « Ce soir, nous verrons notamment la soirée. » devenait « Ce joir, nous verrons notreamment la joirée. ».
public actor ParakeetTranscriber: Transcriber {
    public nonisolated let name = "parakeet"
    public nonisolated var acceptsVocabulary: Bool { true }
    public var measurementConditions: String {
        var text = "modèle TDT 0.6B v3 chargé, et préchauffé avant chaque passe sur 2 s de bruit, hors chrono ; aucune "
            + "indication de langue. Durée mesurée : état de décodeur neuf et transcription TDT de la phrase. Passe "
            + "+vocab : le modèle CTC 110M et la session de vocabulaire sont préparés et préchauffés hors chrono ; la "
            + "durée comprend en plus le passage du modèle CTC sur l'audio et le recalage du texte. Recalage : réglages "
            + "FluidAudio par défaut ; jusqu'à \(ContextBiasingConstants.largeVocabThreshold) termes, passe de "
            + "« sauvetage » active avec des seuils de similarité relevés à 0,30 et 0,50 ; au-delà, pas de passe de "
            + "sauvetage et similarité minimale de 0,55 (0,60 au-delà de \(ContextBiasingConstants.extraLargeVocabThreshold) "
            + "termes). Les termes de moins de 3 caractères et ceux sans jeton CTC sont ignorés par le recalage "
            + "(WhisperKit les reçoit) : les deux lignes +vocab ne voient pas forcément la même liste."
        if let boosting {
            // Le régime dépend de la liste gardée par la session (termes sans jeton CTC retirés), pas de la liste reçue.
            let regime = boosting.retained <= ContextBiasingConstants.largeVocabThreshold
                ? "passe de sauvetage active" : "sans passe de sauvetage"
            text += " Ce passage : \(boosting.retained) termes retenus sur \(boosting.terms.count), \(regime) ; "
            text += boosting.ignored.isEmpty
                ? "aucun terme ignoré."
                : "termes ignorés par le recalage : \(boosting.ignored.joined(separator: ", "))."
        }
        return text
    }
    private var manager: AsrManager?
    private var ctcModels: CtcModels?
    private var boosting: (terms: [String], session: VocabularyBoostingSession, retained: Int, ignored: [String])?

    public init() {}

    public func prepare() async throws {
        if manager != nil { return }
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
    }

    public func warmUp(vocabulary: [String]) async throws {
        guard let manager else { throw TranscriberError.notPrepared(name) }
        let session = vocabulary.isEmpty ? nil : try await session(for: vocabulary)
        _ = try await run(manager, samples: warmUpClip().samples, session: session)
    }

    public func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        try TranscriberError.check16kHz(clip)
        guard let manager else { throw TranscriberError.notPrepared(name) }
        let session = vocabulary.isEmpty ? nil : try await session(for: vocabulary)
        return try await run(manager, samples: clip.samples, session: session)
    }

    /// Session de recalage pour cette liste, construite une fois (au préchauffage) et réutilisée tant que la liste
    /// ne change pas.
    private func session(for vocabulary: [String]) async throws -> VocabularyBoostingSession {
        if let boosting, boosting.terms == vocabulary { return boosting.session }
        let models: CtcModels
        if let ctcModels { models = ctcModels } else {
            models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            ctcModels = models
        }
        let context = CustomVocabularyContext(terms: vocabulary.map { CustomVocabularyTerm(text: $0) })
        let config = VocabularyRescorer.Config(spotterRescueMinSimilarity: 0.30, spotterRescueMultiWordMinSimilarity: 0.50)
        let session = try await VocabularyBoostingSession(vocabulary: context, ctcModels: models, config: config)
        // Termes que le recalage ne verra pas : retirés à la tokenisation (aucun jeton CTC), ou trop courts pour le
        // repérage (`minTermLength`).
        let kept = Set(session.vocabulary.terms.map(\.text))
        let ignored = vocabulary.filter { !kept.contains($0) || $0.count < session.vocabulary.minTermLength }
        boosting = (vocabulary, session, session.vocabulary.terms.count, ignored)
        return session
    }

    /// Un état de décodeur neuf par phrase : réutilisé, il porterait le dernier jeton de la phrase précédente.
    private func run(_ manager: AsrManager, samples: [Float], session: VocabularyBoostingSession?) async throws -> String {
        var state = try TdtDecoderState(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        var text = result.text
        if let session {
            // Le recalage a besoin de l'horodatage par jeton : sans lui il ne ferait rien, en silence, et la ligne
            // « +vocab » ressemblerait à une absence de gain.
            let timings = result.tokenTimings ?? []
            if timings.isEmpty && !text.isEmpty {
                throw TranscriberError.vocabularyUnavailable("Parakeet n'a pas rendu d'horodatage par jeton")
            }
            if let output = await session.rescore(text: text, tokenTimings: timings, audioSamples: samples) {
                text = output.text
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
