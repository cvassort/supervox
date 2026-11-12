import Foundation

enum OutputError: Error, Equatable, CustomStringConvertible {
    case reportExists(String)
    case trackedByGit(directory: String, repository: String, content: String)
    case gitCheckFailed(String)

    var description: String {
        switch self {
        case .reportExists(let path):
            "le rapport \(path) existe déjà : --overwrite pour le remplacer (une mesure ne se refait pas à l'identique)"
        case .trackedByGit(let directory, let repository, let content):
            "le dossier de sortie \(directory) est dans le dépôt git \(repository) et n'y est pas ignoré : \(content). "
                + "Choisir un dossier ignoré par git (par exemple sous bench-data/) ou hors de tout dépôt."
        case .gitCheckFailed(let message): "impossible de vérifier si le dossier de sortie est ignoré par git : \(message)"
        }
    }
}

/// Contrôles du dossier de sortie, faits avant tout chargement de modèle et tout appel réseau.
enum OutputGuard {
    /// Refuse un dossier situé dans un dépôt git qui ne l'ignore pas (`git check-ignore`) : ces fichiers contiennent
    /// ce que l'utilisateur a dit, et un `git add` les publierait. Sans `git`, ou hors de tout dépôt, rien n'est
    /// refusé. Le dossier peut ne pas encore exister : git est lancé depuis son plus proche parent existant.
    /// `content` dit ce que contiennent les fichiers, pour le message.
    static func checkIgnoredByGit(_ directory: URL, content: String, git: [String] = ["/usr/bin/env", "git"]) throws {
        var existing = directory.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        guard let real = realPath(existing.path) else { return }
        guard let top = run(git + ["-C", real, "rev-parse", "--show-toplevel"]), top.status == 0,
              let root = realPath(top.output.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return }   // pas de git, ou hors de tout dépôt
        let full = ([real] + missing).joined(separator: "/")
        let shown = directory.standardizedFileURL.path
        if full == root { throw OutputError.trackedByGit(directory: shown, repository: root, content: content) }
        guard full.hasPrefix(root + "/") else {
            throw OutputError.gitCheckFailed("\(full) n'est pas sous la racine du dépôt \(root)")
        }
        // Barre finale : un motif de dossier (« bench-data/ ») s'applique alors même si le dossier n'existe pas encore.
        let relative = String(full.dropFirst(root.count + 1)) + "/"
        guard let ignored = run(git + ["-C", root, "check-ignore", "-q", "--", relative]) else {
            throw OutputError.gitCheckFailed("git ne s'est pas lancé")
        }
        switch ignored.status {
        case 0: return
        case 1: throw OutputError.trackedByGit(directory: shown, repository: root, content: content)
        default: throw OutputError.gitCheckFailed(ignored.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Refuse d'écrire sur un rapport existant sans `overwrite` ; le message nomme le fichier.
    static func checkNotExisting(_ files: [URL], overwrite: Bool) throws {
        guard !overwrite else { return }
        if let file = files.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            throw OutputError.reportExists(file.path)
        }
    }

    /// Chemin sans lien symbolique (`/var` devient `/private/var`, comme dans la réponse de git).
    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Statut et sorties (standard et erreur) ; `nil` si le programme ne se lance pas.
    private static func run(_ command: [String]) -> (status: Int32, output: String)? {
        guard let executable = command.first else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(command.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
