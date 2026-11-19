import Foundation

/// LA clé de langue de Supervox, écrite une seule fois (revue finale de l'étape « réglage des voix », A-M5) : la ligne
/// « Automatique » de la voix en vigueur (`VoiceChoice.isSameVoice(as:)`), les lignes et filtres de l'onglet Voix (`VoicesModel`)
/// et le choix d'une voix du système (`SystemSpeechSynthesizer.pickVoice`) passent tous par elle.
public enum SpeechLanguage {
    /// Sans casse, `_` et `-` confondus : `fr_FR`, `FR-fr` et `fr-FR` ont la même clé (`fr-fr`). Rien d'autre n'est touché (pas de
    /// rognage).
    public static func key(_ language: String) -> String {
        language.lowercased().replacingOccurrences(of: "_", with: "-")
    }

    /// La langue primaire : la clé jusqu'au premier `-` (`fr` pour `fr-CA` comme pour `fr`) ; vide pour une langue vide.
    public static func primary(_ language: String) -> Substring {
        key(language).split(separator: "-", maxSplits: 1).first ?? ""
    }
}
