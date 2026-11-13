import Observation

public enum PermissionState: Equatable, Sendable {
    case granted, denied, notDetermined
}

/// Ce que l'application demande au système sur ses permissions. Lire un état n'affiche jamais
/// d'invite ; seules `requestMicrophone` et `promptAccessibility` en affichent une.
public protocol PermissionsProbe: Sendable {
    func microphone() -> PermissionState
    /// Le système ne distingue pas « jamais demandée » de « refusée » : `.granted` ou `.denied`.
    func accessibility() -> PermissionState
    /// Affiche l'invite du micro si elle n'a jamais eu de réponse ; rend la décision.
    func requestMicrophone() async -> Bool
    /// Affiche l'invite qui envoie l'utilisateur vers les réglages d'Accessibilité.
    func promptAccessibility()
}

/// État des permissions micro et Accessibilité, relu à la demande (`refresh`), jamais supposé.
/// Rien n'est demandé tant que l'utilisateur n'appelle pas `requestNext` depuis le panneau.
@MainActor @Observable
public final class PermissionsModel {
    private let probe: any PermissionsProbe

    public private(set) var microphone: PermissionState
    public private(set) var accessibility: PermissionState

    /// Lit l'état courant, sans rien demander.
    public init(probe: any PermissionsProbe) {
        self.probe = probe
        microphone = probe.microphone()
        accessibility = probe.accessibility()
    }

    public func refresh() {
        microphone = probe.microphone()
        accessibility = probe.accessibility()
    }

    /// Une demande par appel, dans l'ordre du design : le micro tant qu'il n'est pas décidé,
    /// ensuite l'Accessibilité si elle manque. Un micro refusé ne se redemande pas : le système
    /// n'afficherait plus l'invite.
    public func requestNext() async {
        refresh()
        if microphone == .notDetermined {
            _ = await probe.requestMicrophone()
        } else if accessibility != .granted {
            probe.promptAccessibility()
        }
        refresh()
    }

    /// Vrai si `requestNext` a quelque chose à demander.
    public var canRequest: Bool {
        microphone == .notDetermined || accessibility != .granted
    }

    /// `nil` quand tout est accordé ; sinon une phrase qui dit ce qui manque et ce que cela empêche.
    public var summary: String? {
        let microphoneMissing = microphone != .granted
        let accessibilityMissing = accessibility != .granted
        let settingsHint = microphone == .denied ? " Autorisez le micro dans Réglages Système." : ""
        switch (microphoneMissing, accessibilityMissing) {
        case (false, false):
            return nil
        case (true, false):
            return "Micro non autorisé : la dictée est impossible.\(settingsHint)"
        case (false, true):
            return "Accessibilité non accordée : le texte sera copié, pas collé."
        case (true, true):
            return "Micro et Accessibilité manquent : la dictée est impossible, et le texte serait copié, pas collé.\(settingsHint)"
        }
    }
}
