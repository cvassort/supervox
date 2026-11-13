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
    /// Le système a refusé l'enregistrement (combinaison déjà prise, par exemple).
    case taken
}

/// Tient le raccourci global de l'application : en change sans jamais laisser l'utilisateur
/// sans raccourci si le nouveau est refusé.
@MainActor
public final class HotKeyCenter {
    private let registrar: any HotKeyRegistrar
    private var activeOnPress: (@MainActor () -> Void)?

    /// Le raccourci réellement enregistré auprès du système, ou `nil`.
    public private(set) var active: HotKey?

    public init(registrar: any HotKeyRegistrar) {
        self.registrar = registrar
    }

    /// Enregistre `hotKey` à la place du précédent. Si la combinaison est invalide, le système n'est
    /// pas sollicité. Si le système la refuse, le précédent raccourci est de nouveau enregistré avec
    /// son propre rappel ; `active` ne nomme jamais un raccourci qui n'est pas enregistré.
    public func apply(
        _ hotKey: HotKey, onPress: @escaping @MainActor () -> Void
    ) -> Result<Void, HotKeyError> {
        let validation = hotKey.validate()
        guard validation == .valid else { return .failure(.invalid(validation)) }

        let previous = active
        let previousOnPress = activeOnPress
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
        return .failure(.taken)
    }
}
