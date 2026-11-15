import CoreGraphics

/// La surveillance du maintien. Le relâchement d'un raccourci (`kEventHotKeyReleased`) peut ne jamais arriver quand
/// l'utilisateur lâche les touches de modification avant la touche principale : en maintien, le contrôleur de dictée
/// regarde donc, à intervalle court, si les touches de modification du raccourci sont encore enfoncées, et traite leur
/// relâchement comme celui du raccourci.
@MainActor
public struct HoldWatch {
    /// Vrai si l'une de ces touches de modification est enfoncée en ce moment.
    public var anyHeld: @MainActor (Modifiers) -> Bool
    /// Attend ce nombre de secondes ; injectée pour qu'aucun test n'attende une durée réelle.
    public var wait: @MainActor (Double) async -> Void
    /// Secondes entre deux sondages. 0,25 s : choix de conception de la correction de la tâche 6 (un relâchement perdu
    /// coûte au plus ce délai de plus), non mesuré.
    public var interval: Double

    public init(
        anyHeld: @escaping @MainActor (Modifiers) -> Bool, wait: @escaping @MainActor (Double) async -> Void,
        interval: Double = 0.25
    ) {
        self.anyHeld = anyHeld
        self.wait = wait
        self.interval = interval
    }

    /// L'état réel des touches de modification du système : lecture seule de `CGEventSource.flagsState`, sans écoute
    /// d'événements et sans autorisation (la même lecture que `SystemKeyPoster.modifiersHeld`).
    public static var system: HoldWatch {
        HoldWatch(
            anyHeld: { modifiers in
                anyHeld(in: CGEventSource.flagsState(.combinedSessionState), of: modifiers)
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
