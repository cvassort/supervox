import Carbon.HIToolbox
import Synchronization

/// Enregistreur de raccourci global par Carbon (`RegisterEventHotKey`). Ne demande aucune
/// permission système, et fonctionne dans une application de politique `.accessory`.
///
/// Un seul gestionnaire d'événements est installé (au premier `register`) pour la vie de l'objet,
/// sur la cible d'événements de l'application ; il est retiré dans `deinit`.
@MainActor
public final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    private static var nextID: UInt32 = 1

    private let relay: HotKeyRelay
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    public init() {
        relay = HotKeyRelay(id: Self.nextID)
        Self.nextID += 1
    }

    isolated deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    public func register(_ hotKey: HotKey, onPress: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        guard installHandlerIfNeeded() else { return false }

        // Le rappel est posé avant l'enregistrement : un appui ne peut pas arriver sans lui.
        relay.onPress.withLock { $0 = onPress }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: hotKeySignature, id: relay.id)
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers.rawValue, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            relay.onPress.withLock { $0 = nil }
            return false
        }
        hotKeyRef = ref
        return true
    }

    public func unregister() {
        // Rappel retiré d'abord : un appui déjà en route ne déclenche plus rien.
        relay.onPress.withLock { $0 = nil }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyPressedHandler, 1, &eventType,
            Unmanaged.passUnretained(relay).toOpaque(), &ref)
        guard status == noErr, let ref else { return false }
        handlerRef = ref
        return true
    }
}

/// Signature des raccourcis de ce type (« SPVX »), pour ignorer ceux d'un autre enregistreur.
private let hotKeySignature: OSType = 0x5350_5658

/// Ce que le rappel C lit. Possédé par l'enregistreur ; le gestionnaire C en tient un pointeur
/// non retenu, valable tant que le gestionnaire est installé, c'est-à-dire jusqu'à `deinit`.
private final class HotKeyRelay: Sendable {
    let id: UInt32
    let onPress = Mutex<(@MainActor @Sendable () -> Void)?>(nil)
    init(id: UInt32) { self.id = id }
}

/// Rappel C : ne capture rien. Il reconnaît ses événements à la signature et à l'identifiant,
/// puis passe sur le fil principal, où le rappel courant est lu au moment de la livraison
/// (un appui en route pendant `unregister()` ne déclenche donc rien).
private let hotKeyPressedHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var pressed = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &pressed)
    guard status == noErr, pressed.signature == hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    // Référence forte prise tout de suite : le pointeur, lui, n'est valable que pendant l'appel.
    let relay = Unmanaged<HotKeyRelay>.fromOpaque(userData).takeUnretainedValue()
    guard pressed.id == relay.id else { return OSStatus(eventNotHandledErr) }
    Task { @MainActor in
        relay.onPress.withLock { $0 }?()
    }
    return noErr
}
