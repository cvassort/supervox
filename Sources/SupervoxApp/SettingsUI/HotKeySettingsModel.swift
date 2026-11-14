import AppKit
import Carbon.HIToolbox
import Observation

/// Ce que la fenêtre de réglages peut faire du raccourci global (en production : `AppController`).
@MainActor
public struct GlobalHotKeyControl {
    /// Enregistre ce raccourci à la place de l'actif ; en cas de refus, l'ancien reste actif.
    public var apply: @MainActor (HotKey) -> Result<Void, HotKeyError>
    /// Rend au système le raccourci actif et Échap, le temps d'une capture.
    public var suspend: @MainActor () -> Void
    /// Réenregistre ce que `suspend` a rendu ; sans effet s'il n'y a rien de suspendu.
    public var resume: @MainActor () -> Void
    /// Ne laisse aucun raccourci actif.
    public var clear: @MainActor () -> Void

    public init(
        apply: @escaping @MainActor (HotKey) -> Result<Void, HotKeyError>,
        suspend: @escaping @MainActor () -> Void, resume: @escaping @MainActor () -> Void,
        clear: @escaping @MainActor () -> Void
    ) {
        self.apply = apply
        self.suspend = suspend
        self.resume = resume
        self.clear = clear
    }
}

/// Une option du sélecteur « Touche ».
public struct BehaviorOption: Sendable {
    public let behavior: HotKeyBehavior
    public let label: String
    public let isEnabled: Bool
}

/// Le raccourci global tel que la fenêtre de réglages le montre et le change.
///
/// Pendant la capture, le raccourci actif et Échap sont rendus au système : la combinaison tapée arrive à la
/// fenêtre au lieu d'ouvrir le panneau. Une combinaison captée est validée d'après la disposition de clavier,
/// appliquée au système, puis enregistrée. Tout refus laisse l'ancien raccourci actif et dit pourquoi dans
/// `message`. Si l'enregistrement échoue, l'ancien est réappliqué ; s'il ne peut pas l'être, aucun raccourci
/// ne reste actif : jamais un raccourci absent du fichier de réglages.
@MainActor @Observable
public final class HotKeySettingsModel {
    /// Le maintien est montré, désactivé, avec la mention « à venir ».
    public static let behaviorOptions: [BehaviorOption] = [
        BehaviorOption(behavior: .toggle, label: "Appuyer pour ouvrir ou fermer le panneau", isEnabled: true),
        BehaviorOption(behavior: .hold, label: "Maintenir pour dicter (à venir)", isEnabled: false),
    ]

    /// Ce que l'onglet dit toujours : un conflit avec une autre application ne se voit pas.
    public static let conflictHint =
        "macOS ne signale pas les conflits avec une autre application : si le raccourci n'ouvre pas le panneau, choisissez-en un autre."

    public typealias Apply = @MainActor (HotKey) -> Result<Void, HotKeyError>
    public typealias Save = @MainActor (HotKey, HotKeyBehavior) throws -> Void

    /// Le raccourci enregistré dans les réglages.
    public private(set) var hotKey: HotKey
    public private(set) var behavior: HotKeyBehavior
    /// Vrai pendant que la vue capte la prochaine combinaison tapée.
    public private(set) var isRecording = false
    /// Pourquoi la dernière combinaison a été refusée, ou pourquoi le raccourci enregistré ne marche pas.
    public private(set) var message: String?

    @ObservationIgnored private let layout: any KeyboardLayout
    @ObservationIgnored private let systemHotKeys: any SystemHotKeys
    @ObservationIgnored private let control: GlobalHotKeyControl
    @ObservationIgnored private let save: Save

    /// `active` est le raccourci réellement enregistré auprès du système (`HotKeyCenter.active`) : s'il
    /// diffère de `hotKey`, le message le dit.
    public init(
        hotKey: HotKey, active: HotKey?, behavior: HotKeyBehavior, layout: any KeyboardLayout,
        systemHotKeys: any SystemHotKeys, control: GlobalHotKeyControl, save: @escaping Save
    ) {
        self.hotKey = hotKey
        self.behavior = behavior
        self.layout = layout
        self.systemHotKeys = systemHotKeys
        self.control = control
        self.save = save
        let label = hotKey.label(layout: layout)
        if active != hotKey {
            message = "\(label) n'est pas actif : macOS l'a refusé. Choisissez-en un autre."
        } else if systemHotKeys.enabled().contains(hotKey) {
            message = Self.systemConflict(label: label)
        }
    }

    /// Libellé du raccourci enregistré, d'après la disposition de clavier.
    public var label: String { hotKey.label(layout: layout) }

    public func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        control.suspend()
    }

    public func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        control.resume()
    }

    /// Une touche pressée pendant la capture. Échap seul annule ; toute autre combinaison est proposée.
    public func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        guard isRecording else { return }
        let candidate = Self.hotKey(keyCode: keyCode, flags: flags)
        if candidate.keyCode == UInt32(kVK_Escape), candidate.modifiers.isEmpty {
            cancelRecording()
            return
        }
        record(candidate)
    }

    /// Propose `candidate` comme nouveau raccourci et met fin à la capture.
    public func record(_ candidate: HotKey) {
        let wasRecording = isRecording
        isRecording = false
        // Ce qu'une capture a suspendu est rendu à la fin, quel que soit le chemin ; après un `apply`, il n'y
        // a déjà plus rien de suspendu et `resume` ne fait rien.
        defer { if wasRecording { control.resume() } }

        let candidateLabel = candidate.label(layout: layout)
        let validation = candidate.validate(layout: layout)
        guard validation == .valid else {
            message = Self.refusal(validation, label: candidateLabel)
            return
        }
        // macOS accepterait la combinaison sans dire lequel des deux raccourcis l'emporte.
        guard !systemHotKeys.enabled().contains(candidate) else {
            message = Self.systemShortcutRefusal(label: candidateLabel)
            return
        }
        let previous = hotKey
        switch control.apply(candidate) {
        case .failure(.refused):
            message = "\(candidateLabel) a été refusé par macOS : il est sans doute déjà pris par une autre application. Choisissez-en un autre."
        case .failure(.invalid(let validation)):
            message = Self.refusal(validation, label: candidateLabel)
        case .success:
            do {
                try save(candidate, behavior)
                hotKey = candidate
                message = nil
            } catch {
                let reason = "Raccourci non enregistré : \(error.localizedDescription)"
                if case .success = control.apply(previous) {
                    message = reason
                } else {
                    // L'ancien ne peut pas être rétabli : mieux vaut aucun raccourci qu'un raccourci hors du fichier.
                    control.clear()
                    message = "\(reason) Aucun raccourci n'est actif."
                }
            }
        }
    }

    /// Le maintien de la touche n'est pas encore mis en œuvre : seul le basculement est disponible.
    public static func isAvailable(_ behavior: HotKeyBehavior) -> Bool { behavior == .toggle }

    /// Un comportement indisponible est ignoré.
    public func setBehavior(_ newBehavior: HotKeyBehavior) {
        guard Self.isAvailable(newBehavior), newBehavior != behavior else { return }
        do {
            try save(hotKey, newBehavior)
            behavior = newBehavior
        } catch {
            message = "Comportement non enregistré : \(error.localizedDescription)"
        }
    }

    /// Code de touche et modificateurs d'un événement clavier ; seuls ⌃, ⌥, ⇧ et ⌘ comptent (le système
    /// ajoute fn aux flèches et aux touches de fonction, verrouillage majuscule ne change pas la combinaison).
    public static func hotKey(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> HotKey {
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return HotKey(keyCode: UInt32(keyCode), modifiers: modifiers)
    }

    /// Refus d'une combinaison captée.
    static func systemShortcutRefusal(label: String) -> String {
        "\(label) est un raccourci de macOS activé sur ce Mac (Réglages Système, Clavier, Raccourcis clavier) : choisissez-en un autre."
    }

    /// Le raccourci enregistré est aussi un raccourci de macOS activé : il est enregistré, mais rien ne dit lequel des
    /// deux l'emporte.
    static func systemConflict(label: String) -> String {
        "\(label) est aussi un raccourci de macOS activé sur ce Mac : il peut ne pas ouvrir le panneau. Choisissez-en un autre, ou désactivez celui de macOS (Réglages Système, Clavier, Raccourcis clavier)."
    }

    private static func refusal(_ validation: HotKeyValidation, label: String) -> String {
        switch validation {
        case .valid: ""
        case .needsModifier: "Ajoutez ⌃ ou ⌘ : \(label) taperait du texte."
        case .modifierOnly: "Ajoutez une touche aux modificateurs."
        case .reserved(let reserved): "\(reserved) est réservé par le système."
        }
    }
}
