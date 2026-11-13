import AppKit
import Carbon.HIToolbox
import Observation

/// Le raccourci global tel que la fenêtre de réglages le montre et le change.
///
/// Une combinaison captée est d'abord validée d'après la disposition de clavier, puis appliquée au
/// système (`apply`), puis enregistrée (`save`). Tout refus laisse l'ancien raccourci actif et dit pourquoi
/// dans `message` ; si l'enregistrement échoue, l'ancien est réappliqué : le raccourci actif est toujours
/// celui du fichier de réglages.
@MainActor @Observable
public final class HotKeySettingsModel {
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
    @ObservationIgnored private let apply: Apply
    @ObservationIgnored private let save: Save

    /// `active` est le raccourci réellement enregistré auprès du système (`HotKeyCenter.active`) : s'il
    /// diffère de `hotKey`, le message le dit.
    public init(
        hotKey: HotKey, active: HotKey?, behavior: HotKeyBehavior, layout: any KeyboardLayout,
        apply: @escaping Apply, save: @escaping Save
    ) {
        self.hotKey = hotKey
        self.behavior = behavior
        self.layout = layout
        self.apply = apply
        self.save = save
        if active != hotKey {
            message = "\(hotKey.label(layout: layout)) n'est pas actif : il est déjà pris ou refusé. Choisissez-en un autre."
        }
    }

    /// Libellé du raccourci enregistré, d'après la disposition de clavier.
    public var label: String { hotKey.label(layout: layout) }

    public func startRecording() { isRecording = true }

    public func cancelRecording() { isRecording = false }

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
        isRecording = false
        let candidateLabel = candidate.label(layout: layout)
        let validation = candidate.validate(layout: layout)
        guard validation == .valid else {
            message = Self.refusal(validation, label: candidateLabel)
            return
        }
        let previous = hotKey
        switch apply(candidate) {
        case .failure(.taken):
            message = "\(candidateLabel) est déjà pris par une autre application."
        case .failure(.invalid(let validation)):
            message = Self.refusal(validation, label: candidateLabel)
        case .success:
            do {
                try save(candidate, behavior)
                hotKey = candidate
                message = nil
            } catch {
                _ = apply(previous)
                message = "Raccourci non enregistré : \(error.localizedDescription)"
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

    private static func refusal(_ validation: HotKeyValidation, label: String) -> String {
        switch validation {
        case .valid: ""
        case .needsModifier: "Ajoutez ⌃ ou ⌘ : \(label) taperait du texte."
        case .modifierOnly: "Ajoutez une touche aux modificateurs."
        case .reserved(let reserved): "\(reserved) est réservé par le système."
        }
    }
}
