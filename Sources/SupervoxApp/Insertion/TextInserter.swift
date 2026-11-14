import Carbon.HIToolbox
import Foundation

/// Le contenu du presse-papiers, sans perte : pour chaque élément, ses types (identifiants UTI) et leurs données.
/// Un presse-papiers vide est une liste vide d'éléments.
public struct PasteboardContents: Equatable, Sendable {
    public var items: [[String: Data]]

    public init(items: [[String: Data]]) { self.items = items }
}

/// Le presse-papiers, vu par l'insertion. La réalisation système est `SystemPasteboard` ; les tests injectent un double.
@MainActor public protocol PasteboardAccess: AnyObject {
    /// Compteur du système, qui monte à chaque écriture, par n'importe quelle application.
    var changeCount: Int { get }
    /// Tout le contenu, tous types et tous éléments.
    func read() -> PasteboardContents
    /// Remplace tout le contenu (un contenu sans élément vide le presse-papiers).
    func write(_ contents: PasteboardContents)
    /// Remplace tout le contenu par ce texte. `transient` y ajoute les marques que les gestionnaires de
    /// presse-papiers respectent pour ne pas archiver une copie.
    func writeText(_ text: String, transient: Bool)
}

/// L'envoi des touches, vu par l'insertion. La réalisation système est `SystemKeyPoster`.
@MainActor public protocol KeyPoster: AnyObject {
    /// Vrai si une touche ⌘, ⌥, ⌃ ou ⇧ est tenue en ce moment.
    func modifiersHeld() -> Bool
    /// Poste ⌘ + la touche de ce code (appui puis relâchement). Faux si l'événement n'a pas pu être fabriqué.
    func postPaste(keyCode: UInt16) -> Bool
}

/// Ce qu'est devenu le texte dicté.
public enum InsertionOutcome: Equatable, Sendable {
    /// Collé dans l'application au premier plan ; le presse-papiers d'origine est rendu.
    case pasted
    /// Laissé dans le presse-papiers sans être collé. `reason` est une phrase complète, à montrer à l'utilisateur.
    case copied(reason: String)
    /// Rien à insérer (texte vide ou d'espaces).
    case nothing
}

/// Insère un texte dicté dans l'application au premier plan par un ⌘V simulé : le presse-papiers est sauvegardé,
/// le texte y est écrit, collé, puis le contenu d'origine est rendu, sauf si une autre application y a écrit entre-temps.
///
/// Le texte dicté est une donnée privée : il n'apparaît dans aucun journal ni message, y compris dans les
/// raisons des résultats `.copied`.
@MainActor public final class TextInserter {
    /// Intervalle de sondage des modificateurs. Choix de conception du plan de l'étape « dictée » (non mesuré).
    private static let modifierPollInterval = 0.05

    private let pasteboard: any PasteboardAccess
    private let keys: any KeyPoster
    private let layout: any KeyboardLayout
    private let isTrusted: @MainActor () -> Bool
    private let wait: @MainActor (Double) async -> Void
    private let restoreDelay: Double
    private let modifierPatience: Double

    /// - Parameters:
    ///   - isTrusted: vrai si l'application a le droit d'Accessibilité (poster des touches).
    ///   - wait: attend ce nombre de secondes ; injectée pour qu'aucun test n'attende une durée réelle.
    ///   - restoreDelay: durée entre ⌘V et la restauration, pour que l'application cible ait lu le presse-papiers.
    ///     0,4 s : choix de conception du plan de l'étape « dictée », non mesuré.
    ///   - modifierPatience: durée maximale d'attente du relâchement des modificateurs. 1 s : choix de conception du
    ///     plan de l'étape « dictée », non mesuré.
    public init(
        pasteboard: any PasteboardAccess, keys: any KeyPoster, layout: any KeyboardLayout,
        isTrusted: @escaping @MainActor () -> Bool, wait: @escaping @MainActor (Double) async -> Void,
        restoreDelay: Double = 0.4, modifierPatience: Double = 1.0
    ) {
        self.pasteboard = pasteboard
        self.keys = keys
        self.layout = layout
        self.isTrusted = isTrusted
        self.wait = wait
        self.restoreDelay = restoreDelay
        self.modifierPatience = modifierPatience
    }

    /// Annulation de la tâche appelante : avant le ⌘V, rien n'est collé, le presse-papiers est rendu (sauf si une autre
    /// application y a écrit) et le résultat est `.nothing` ; après le ⌘V, la restauration a lieu quand même au délai
    /// prévu. Dans les deux replis `.copied` (modificateurs tenus, ⌘V non posté), le contenu d'origine n'est pas rendu :
    /// le texte dicté reste dans le presse-papiers pour que l'utilisateur le colle.
    public func insert(_ text: String) async -> InsertionOutcome {
        // Annulée avant d'avoir commencé (Échap, fermeture du panneau) : rien n'est écrit, rien n'est collé.
        guard !Task.isCancelled else { return .nothing }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .nothing }

        guard isTrusted() else {
            pasteboard.writeText(text, transient: true)
            return .copied(reason: Self.accessibilityReason)
        }

        let original = pasteboard.read()
        pasteboard.writeText(text, transient: true)
        let changeCountAfterWrite = pasteboard.changeCount

        // Annulée avant le collage : rien n'est collé, et le presse-papiers est rendu (le texte dicté n'y reste pas).
        func restoreIfUnchanged() {
            if pasteboard.changeCount == changeCountAfterWrite { pasteboard.write(original) }
        }

        guard await modifiersReleased() else {
            if Task.isCancelled {
                restoreIfUnchanged()
                return .nothing
            }
            return .copied(reason: Self.modifiersReason)
        }
        if Task.isCancelled {
            restoreIfUnchanged()
            return .nothing
        }
        guard keys.postPaste(keyCode: Self.pasteKeyCode(layout: layout)) else {
            return .copied(reason: Self.postFailureReason)
        }

        // Dans une tâche non structurée, qui n'hérite pas de l'annulation : une annulation pendant cette attente
        // (`Task.sleep` rend aussitôt la main) restaurerait avant que l'application cible ait lu ⌘V, et elle
        // collerait l'ancien contenu. La restauration a toujours lieu au délai prévu.
        let wait = self.wait
        let restoreDelay = self.restoreDelay
        await Task { @MainActor in await wait(restoreDelay) }.value
        // Une autre application a écrit entre-temps : son contenu est plus récent que la sauvegarde, on n'y touche pas.
        restoreIfUnchanged()
        return .pasted
    }

    /// Le code de la touche dont le caractère est « v » dans la disposition donnée : celui de V en ANSI s'il y
    /// produit « v », sinon le premier code qui le produit, sinon celui de V.
    public static func pasteKeyCode(layout: any KeyboardLayout) -> UInt16 {
        let ansiV = UInt16(kVK_ANSI_V)
        func producesV(_ code: UInt16) -> Bool { layout.character(forKeyCode: UInt32(code))?.lowercased() == "v" }
        if producesV(ansiV) { return ansiV }
        // Les codes de touche virtuels tiennent sur 7 bits (0x00...0x7F).
        return (0..<128).map(UInt16.init).first(where: producesV) ?? ansiV
    }

    /// Sonde les modificateurs jusqu'à ce qu'ils soient relâchés ; faux si la patience est épuisée ou si la tâche est annulée. Les sondages sont
    /// comptés en entiers : sommer des 0,05 en virgule flottante ferait dériver le total.
    private func modifiersReleased() async -> Bool {
        // Une patience négative, infinie ou NaN n'a pas de sens : zéro attente (et `Int(_:)` planterait sur NaN
        // et l'infini).
        let polls = modifierPatience.isFinite ? max(0, Int((modifierPatience / Self.modifierPollInterval).rounded())) : 0
        var remaining = polls
        while keys.modifiersHeld() {
            if remaining == 0 { return false }
            remaining -= 1
            await wait(Self.modifierPollInterval)
            // Une attente annulée rend la main aussitôt : sans cette sortie, les sondages défileraient sans attendre.
            if Task.isCancelled { return false }
        }
        return true
    }

    private static let accessibilityReason =
        "Le texte dicté est copié dans le presse-papiers, mais Supervox n'a pas l'autorisation de le coller à votre place : faites ⌘V pour le coller, et accordez l'Accessibilité à Supervox dans Réglages Système, Confidentialité et sécurité, Accessibilité, pour que le collage soit automatique."

    private static let modifiersReason =
        "Le texte dicté est copié dans le presse-papiers, mais des touches de modification (⌃, ⌥, ⇧ ou ⌘) sont restées enfoncées et auraient faussé le collage : relâchez-les, puis faites ⌘V pour coller le texte."

    private static let postFailureReason =
        "Le texte dicté est copié dans le presse-papiers, mais Supervox n'a pas pu envoyer le raccourci de collage : faites ⌘V pour le coller."
}
