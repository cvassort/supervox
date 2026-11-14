/// Ce que `HotKeyCenter` demande à l'enregistreur de raccourci système.
///
/// Contrat : un seul emplacement. `register` remplace ce qui s'y trouve ; si le système refuse,
/// le résultat est `false` et plus aucun raccourci n'est enregistré (l'ancien n'est pas conservé).
/// `unregister` retire le raccourci enregistré, et ne fait rien s'il n'y en a pas.
/// `onPress` est appelé sur le fil principal.
///
/// Le protocole est isolé au fil principal, comme `HotKeyCenter` et les rappels.
@MainActor
public protocol HotKeyRegistrar {
    func register(_ hotKey: HotKey, onPress: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

public enum HotKeyError: Error, Equatable, Sendable {
    /// La combinaison n'a même pas été proposée au système.
    case invalid(HotKeyValidation)
    /// Le système a refusé l'enregistrement. macOS ne dit pas pourquoi : en pratique, une autre application tient
    /// déjà la combinaison. Il ne refuse pas une combinaison prise par l'un de ses propres raccourcis
    /// (voir `SystemHotKeys`).
    case refused
}

/// Tient le raccourci global de l'application : en change sans jamais laisser l'utilisateur
/// sans raccourci si le nouveau est refusé.
@MainActor
public final class HotKeyCenter {
    private let registrar: any HotKeyRegistrar
    private let layout: any KeyboardLayout
    private var activeOnPress: (@MainActor () -> Void)?

    /// Vrai entre `suspend` et `resume` (ou le prochain `apply`) : `active` est gardé mais pas enregistré.
    public private(set) var isSuspended = false

    /// Rend la combinaison au système le temps d'une capture, sans oublier le raccourci actif.
    public func suspend() {
        guard active != nil, !isSuspended else { return }
        registrar.unregister()
        isSuspended = true
    }

    /// Réenregistre le raccourci suspendu avec son rappel. Rend faux si le système le refuse : il n'y a
    /// alors plus de raccourci actif. Sans suspension en cours, ne fait rien.
    @discardableResult
    public func resume() -> Bool {
        guard isSuspended else { return true }
        isSuspended = false
        guard let active, let activeOnPress, registrar.register(active, onPress: activeOnPress) else {
            self.active = nil
            activeOnPress = nil
            return false
        }
        return true
    }

    /// Retire tout raccourci : plus rien n'est enregistré ni actif.
    public func clear() {
        registrar.unregister()
        active = nil
        activeOnPress = nil
        isSuspended = false
    }

    /// Le raccourci réellement enregistré auprès du système, ou `nil` ; pendant une suspension, celui qui
    /// sera réenregistré.
    public private(set) var active: HotKey?

    /// `layout` sert à reconnaître les combinaisons réservées par caractère (⌘Q, ⌘W, ⌘H, ⌘M).
    public init(registrar: any HotKeyRegistrar, layout: any KeyboardLayout) {
        self.registrar = registrar
        self.layout = layout
    }

    /// Enregistre `hotKey` à la place du précédent. Si la combinaison est invalide, le système n'est
    /// pas sollicité. Si le système la refuse, le précédent raccourci est de nouveau enregistré avec
    /// son propre rappel ; hors suspension, `active` ne nomme jamais un raccourci qui n'est pas enregistré.
    public func apply(
        _ hotKey: HotKey, onPress: @escaping @MainActor () -> Void
    ) -> Result<Void, HotKeyError> {
        let validation = hotKey.validate(layout: layout)
        guard validation == .valid else { return .failure(.invalid(validation)) }

        let previous = active
        let previousOnPress = activeOnPress
        // Un essai met fin à une suspension : en cas de refus, le précédent est réenregistré ci-dessous.
        isSuspended = false
        // Retiré pour l'essai : le système refuserait une combinaison déjà tenue par l'ancienne.
        registrar.unregister()
        if registrar.register(hotKey, onPress: onPress) {
            active = hotKey
            activeOnPress = onPress
            return .success(())
        }

        if let previous, let previousOnPress, registrar.register(previous, onPress: previousOnPress) {
            active = previous
            activeOnPress = previousOnPress
        } else {
            active = nil
            activeOnPress = nil
        }
        return .failure(.refused)
    }
}
