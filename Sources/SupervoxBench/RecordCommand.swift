import ArgumentParser
import Foundation
import SupervoxCore

/// Ce que `RecordSession` demande au micro : démarrer, arrêter en rendant le clip. `AudioCapture` s'y conforme ;
/// les tests y branchent un enregistreur scripté, ce qui évite de dépendre d'un micro pour les règles de la session.
protocol ClipRecorder {
    func start() throws
    func stop() -> AudioClip
    var inputDescription: String { get }
}

extension AudioCapture: ClipRecorder {}

enum RecordError: Error, Equatable, CustomStringConvertible {
    case unsafeID(String)

    var description: String {
        switch self {
        case .unsafeID(let id): "identifiant inutilisable comme nom de fichier : « \(id) »"
        }
    }
}

/// Déroulé de la commande `record`, séparé de la ligne de commande pour être testable : l'entrée (Entrée au clavier),
/// la sortie (messages) et le micro sont injectés.
struct RecordSession {
    struct Summary: Equatable {
        var recorded: [String] = []
        var skipped: [String] = []
        /// `true` si l'entrée standard s'est fermée avant la fin du corpus.
        var interrupted = false
    }

    /// En dessous, on suppose un faux départ (Entrée pressée trop tôt) : la phrase est redemandée.
    static let minimumDuration = 0.5
    static let targetSampleRate = 16000.0
    static let defaultTailDelay = 0.4

    let items: [CorpusItem]
    let outputDirectory: URL
    let overwrite: Bool
    let recorder: any ClipRecorder
    let readLine: () -> String?
    let say: (String) -> Void
    /// Durée pendant laquelle la capture continue après la 2e Entrée, avant `stop()` : le tap livre par fenêtres
    /// (100 ms demandées, jusqu'à 400 ms admises par le SDK) et `stop()` jette la fenêtre en cours ; sans cette
    /// marge, la fin de la phrase lue serait coupée et fausserait la transcription. Injectable : les tests la mettent à 0.
    var tailDelay = RecordSession.defaultTailDelay
    var wait: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }

    func run() throws -> Summary {
        // L'identifiant devient un nom de fichier : on refuse tout le corpus d'emblée plutôt qu'à la 20e phrase.
        for item in items where item.id.contains("/") || item.id.contains("\0") || item.id.hasPrefix(".") {
            throw RecordError.unsafeID(item.id)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var summary = Summary()
        var announcedInput = false
        for (index, item) in items.enumerated() {
            let file = outputDirectory.appendingPathComponent(item.id + ".wav")
            // Contrôle avant d'enregistrer : on ne fait pas dire une phrase pour refuser ensuite d'écrire.
            if FileManager.default.fileExists(atPath: file.path) && !overwrite {
                say("[\(item.id)] ignorée : \(file.lastPathComponent) existe déjà (--overwrite pour le remplacer)")
                summary.skipped.append(item.id)
                continue
            }

            var accepted = false
            while !accepted {
                say("")
                say("[\(item.id)] (\(index + 1)/\(items.count)) \(item.text)")
                say("Entrée pour démarrer l'enregistrement.")
                guard readLine() != nil else { summary.interrupted = true; return summary }

                try recorder.start()
                if !announcedInput { say("Entrée audio : \(recorder.inputDescription)"); announcedInput = true }
                say("Enregistrement… Entrée pour arrêter.")
                guard readLine() != nil else {
                    _ = recorder.stop()   // libère le micro ; la prise inachevée est jetée
                    summary.interrupted = true
                    return summary
                }
                wait(tailDelay)
                let clip = recorder.stop()

                guard clip.duration >= Self.minimumDuration else {
                    say(String(format: "Enregistrement trop court (%.2f s, minimum %.1f s) : on recommence.",
                               clip.duration, Self.minimumDuration))
                    continue
                }
                let mono16k = Resampler.resample(clip, to: Self.targetSampleRate)
                guard mono16k.duration >= Self.minimumDuration else {
                    say("Rééchantillonnage impossible : on recommence.")
                    continue
                }
                try WavFile.write(mono16k, to: file)
                say(String(format: "Enregistré : %@ (%.2f s)", file.lastPathComponent, mono16k.duration))
                summary.recorded.append(item.id)
                accepted = true
            }
        }
        return summary
    }
}

struct RecordCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Enregistre ta voix pour chaque phrase du corpus (WAV 16 kHz mono, un fichier par identifiant)."
    )

    @Option(name: .long, help: "Fichier du corpus (TSV : id, texte, termes).")
    var corpus: String

    @Option(name: .long, help: "Dossier de sortie : <dossier>/<id>.wav.")
    var out: String

    @Flag(name: .long, help: "Remplace les fichiers existants (sinon ils sont ignorés).")
    var overwrite = false

    func run() throws {
        // Avant de lire le corpus et d'ouvrir le micro.
        try OutputGuard.checkIgnoredByGit(URL(fileURLWithPath: out, isDirectory: true),
                                          content: "ces enregistrements contiennent ta voix")
        let items = try Corpus.load(from: URL(fileURLWithPath: corpus))
        let session = RecordSession(
            items: items,
            outputDirectory: URL(fileURLWithPath: out),
            overwrite: overwrite,
            recorder: AudioCapture(),
            readLine: { Swift.readLine() },
            say: { print($0) }
        )
        let summary = try session.run()
        print("")
        print("\(summary.recorded.count) enregistrée(s), \(summary.skipped.count) ignorée(s) sur \(items.count).")
        if summary.interrupted {
            print("Session interrompue : l'entrée standard s'est fermée avant la fin du corpus.")
            throw ExitCode.failure
        }
    }
}
