import Carbon.HIToolbox
import Synchronization
import os

/// Enregistreur de raccourci global par Carbon (`RegisterEventHotKey`). Ne demande aucune
/// permission système, et fonctionne dans une application de politique `.accessory`.
///
/// Un seul gestionnaire d'événements est installé (au premier `register`) pour la vie de l'objet,
/// sur la cible d'événements de l'application ; il reçoit l'appui (`kEventHotKeyPressed`) et le relâchement
/// (`kEventHotKeyReleased`). Il est retiré dans `deinit`.
@MainActor
public final class CarbonHotKeyRegistrar: HotKeyRegistrar {
    private static var nextID: UInt32 = 1

    private let relay: CarbonHotKeyRelay
    private let log = Logger(subsystem: "dev.supervox.app", category: "hotkey")
    private var handlerRef: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    public init() {
        relay = CarbonHotKeyRelay(id: Self.nextID)
        Self.nextID += 1
    }

    isolated deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    public func register(
        _ hotKey: HotKey, onPress: @escaping @MainActor () -> Void, onRelease: (@MainActor () -> Void)?
    ) -> Bool {
        unregister()
        guard installHandlerIfNeeded() else { return false }

        // Les rappels sont posés avant l'enregistrement : un appui ne peut pas arriver sans eux.
        relay.setCallbacks(onPress: onPress, onRelease: onRelease)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: hotKeySignature, id: relay.id)
        let status = RegisterEventHotKey(
            hotKey.keyCode, hotKey.modifiers.rawValue, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            relay.clearCallbacks()
            return false
        }
        hotKeyRef = ref
        log.notice("raccourci Carbon posé ; rappel d'appui : oui ; rappel de relâchement : \(onRelease != nil ? "oui" : "non", privacy: .public)")
        return true
    }

    public func unregister() {
        // Rappels retirés d'abord : un appui ou un relâchement déjà en route ne déclenche plus rien.
        relay.clearCallbacks()
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installHandlerIfNeeded() -> Bool {
        if handlerRef != nil { return true }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var ref: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(), hotKeyHandler, eventTypes.count, &eventTypes,
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
final class CarbonHotKeyRelay: Sendable {
    /// Ce que le système signale d'un raccourci.
    enum Edge: Sendable { case pressed, released }

    let id: UInt32
    private let callbacks = Mutex<(onPress: (@MainActor @Sendable () -> Void)?, onRelease: (@MainActor @Sendable () -> Void)?)>(
        (nil, nil))

    init(id: UInt32) { self.id = id }

    func setCallbacks(onPress: @escaping @MainActor () -> Void, onRelease: (@MainActor () -> Void)?) {
        callbacks.withLock { $0 = (onPress, onRelease) }
    }

    func clearCallbacks() {
        callbacks.withLock { $0 = (nil, nil) }
    }

    /// Sur le fil principal : le rappel courant est lu au moment de la livraison (un événement en route pendant
    /// `unregister()` ne déclenche donc rien).
    @MainActor func deliver(_ edge: Edge) {
        let current = callbacks.withLock { $0 }
        switch edge {
        case .pressed: current.onPress?()
        case .released: current.onRelease?()
        }
    }
}

/// Rappel C : ne capture rien. Il reconnaît ses événements à la signature et à l'identifiant, puis passe sur le fil
/// principal par la file principale de GCD, qui est en ordre d'arrivée : un appui est toujours livré avant son
/// relâchement (deux `Task` indépendantes ne promettraient pas cet ordre).
private let hotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var pressed = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &pressed)
    guard status == noErr, pressed.signature == hotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    // Référence forte prise tout de suite : le pointeur, lui, n'est valable que pendant l'appel.
    let relay = Unmanaged<CarbonHotKeyRelay>.fromOpaque(userData).takeUnretainedValue()
    guard pressed.id == relay.id else { return OSStatus(eventNotHandledErr) }
    let kind: CarbonHotKeyRelay.Edge
    switch GetEventKind(event) {
    case UInt32(kEventHotKeyPressed): kind = .pressed
    case UInt32(kEventHotKeyReleased): kind = .released
    default: return OSStatus(eventNotHandledErr)
    }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { relay.deliver(kind) }
    }
    return noErr
}
