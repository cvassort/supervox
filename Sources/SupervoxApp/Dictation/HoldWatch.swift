import Carbon.HIToolbox
import CoreGraphics

/// La surveillance du maintien. Le relâchement d'un raccourci (`kEventHotKeyReleased`) peut ne jamais arriver quand
/// l'utilisateur lâche les touches de modification avant la touche principale : en maintien, le contrôleur de dictée
/// regarde donc, à intervalle court, si les touches de modification du raccourci sont encore enfoncées, et traite leur
/// relâchement comme celui du raccourci.
///
/// Elle lit aussi la touche Échap : Échap est réservé sans touche de modification, donc, avec ⌃⌥ encore tenus, l'événement
/// est ⌃⌥Échap, qui part à l'application de dessous ; sans cette lecture, annuler une dictée en maintien obligerait à lâcher
/// ⌃⌥ d'abord, ce qui termine et colle la dictée.
@MainActor
public struct HoldWatch {
    /// Vrai si l'une de ces touches de modification est enfoncée en ce moment.
    public var anyHeld: @MainActor (Modifiers) -> Bool
    /// Vrai si la touche Échap est enfoncée en ce moment.
    public var escapeHeld: @MainActor () -> Bool
    /// Attend ce nombre de secondes ; injectée pour qu'aucun test n'attende une durée réelle.
    public var wait: @MainActor (Double) async -> Void
    /// Secondes entre deux sondages. 0,05 s : l'état d'une touche est une lecture instantanée, et un appui franc sur Échap
    /// dure de l'ordre d'un dixième de seconde (impression, non mesurée) ; à 0,25 s, la plupart des appuis passeraient
    /// entre deux lectures. Un relâchement perdu coûte au plus ce délai de plus. Choix de conception, non mesuré ; la
    /// lecture ne coûte presque rien et ne tourne que pendant une dictée en maintien.
    public var interval: Double

    public init(
        anyHeld: @escaping @MainActor (Modifiers) -> Bool,
        escapeHeld: @escaping @MainActor () -> Bool = { false },
        wait: @escaping @MainActor (Double) async -> Void,
        interval: Double = 0.05
    ) {
        self.anyHeld = anyHeld
        self.escapeHeld = escapeHeld
        self.wait = wait
        self.interval = interval
    }

    /// L'état réel des touches de modification et d'Échap du système : lecture seule de `CGEventSource.flagsState` et de
    /// `keyState`, sans écoute d'événements et sans autorisation (la même lecture que `SystemKeyPoster.modifiersHeld`).
    public static var system: HoldWatch {
        HoldWatch(
            anyHeld: { modifiers in
                anyHeld(in: CGEventSource.flagsState(.combinedSessionState), of: modifiers)
            },
            escapeHeld: {
                // Lecture seule de l'état du clavier, comme `flagsState` : aucune autorisation.
                CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Escape))
            },
            wait: { try? await Task.sleep(for: .seconds($0)) })
    }

    /// Les drapeaux d'événement qui correspondent aux modificateurs d'un raccourci.
    nonisolated static func flags(for modifiers: Modifiers) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        return flags
    }

    /// Vrai si au moins un des modificateurs du raccourci est enfoncé dans `current`. Les autres bits (majuscules
    /// verrouillées, fn, pavé numérique) ne comptent pas.
    nonisolated static func anyHeld(in current: CGEventFlags, of modifiers: Modifiers) -> Bool {
        !current.intersection(flags(for: modifiers)).isEmpty
    }
}
