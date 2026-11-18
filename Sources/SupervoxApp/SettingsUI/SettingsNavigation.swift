import Observation

/// L'onglet que la fenêtre de réglages montre, partagé entre la fenêtre et le contrôleur : `AppController.openSettings(tab:)` le
/// change pour ouvrir (ou ramener) la fenêtre sur un onglet donné ; un clic de la personne sur un onglet le change aussi, de sorte
/// qu'un `openSettings()` sans onglet rouvre là où elle s'était arrêtée. La fenêtre gardée d'une ouverture à l'autre garde son état :
/// c'est ici, et non dans la vue, que l'onglet courant vit.
@MainActor @Observable
public final class SettingsNavigation {
    public var tab: SettingsTab

    public init(tab: SettingsTab = .providers) {
        self.tab = tab
    }
}
