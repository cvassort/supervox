import AppKit
import SupervoxApp
import SwiftUI

// supervox-snapshots <dossier> : rend chaque écran de l'application en PNG, en clair et en sombre.
//
// Données d'exemple seulement (adresses `example.com`), doubles partout : aucun accès au trousseau, au réseau, aux
// réglages réels, au clavier ni aux permissions du système. Chaque vue est posée dans une fenêtre placée hors de
// l'écran, puis la vue cadre de la fenêtre est copiée par `cacheDisplay` ; le fond est peint explicitement, sans quoi
// il serait transparent.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage : supervox-snapshots <dossier de sortie>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// MARK: - Doubles

/// Disposition ANSI fixe : les libellés ne dépendent pas de la machine.
struct ExampleLayout: KeyboardLayout {
    private static let letters: [UInt32: String] = [0x00: "a", 0x0B: "b", 0x0C: "q", 0x0D: "w"]
    func character(forKeyCode keyCode: UInt32) -> String? { Self.letters[keyCode] }
}

struct ExamplePermissions: PermissionsProbe {
    let microphoneState: PermissionState
    let accessibilityState: PermissionState
    func microphone() -> PermissionState { microphoneState }
    func accessibility() -> PermissionState { accessibilityState }
    func requestMicrophone() async -> Bool { false }
    func promptAccessibility() {}
}

@MainActor final class NoSystemHotKeys: SystemHotKeys {
    func enabled() -> [HotKey] { [] }
}

@MainActor final class NoKeyMonitor: KeyEventMonitor {
    func start(_ handler: @escaping @MainActor (UInt16, NSEvent.ModifierFlags) -> Void) {}
    func stop() {}
}

let layout = ExampleLayout()
let granted = ExamplePermissions(microphoneState: .granted, accessibilityState: .granted)
let missing = ExamplePermissions(microphoneState: .notDetermined, accessibilityState: .denied)
let denied = ExamplePermissions(microphoneState: .denied, accessibilityState: .denied)
let standardLabel = HotKey.standard.label(layout: layout)
let keyB = HotKey(keyCode: 0x0B, modifiers: [.control, .option])

let firstProvider = Provider(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Serveur d'exemple",
    baseURL: "https://api.example.com/v1", kind: .openAICompatible,
    models: ["exemple-petit", "exemple-moyen", "exemple-grand"])
let secondProvider = Provider(
    id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Second exemple",
    baseURL: "https://llm.example.org", kind: .anthropic, models: [])

@MainActor func providersModel(_ providers: [Provider]) async -> ProvidersModel {
    // Clé fictive pour le premier seulement : l'état « Enregistrée » et « Aucune » sont visibles tous les deux.
    let secrets = InMemorySecretStore(secrets: [firstProvider.id.uuidString: "exemple"])
    let model = ProvidersModel(
        providers: providers, secrets: secrets, listModels: { _, _ in [] }, save: { _ in })
    await model.checkKeys()
    return model
}

/// `refusing` : la prochaine combinaison proposée est refusée par le « système », pour montrer le message.
@MainActor func hotKeyModel(refusing: Bool = false) -> HotKeySettingsModel {
    let model = HotKeySettingsModel(
        hotKey: .standard, active: .standard, behavior: .toggle, layout: layout, systemHotKeys: NoSystemHotKeys(),
        keyMonitor: NoKeyMonitor(),
        control: GlobalHotKeyControl(
            apply: { _ in refusing ? .failure(.refused) : .success(()) }, suspend: {}, resume: { true }, clear: {}),
        save: { _, _ in })
    if refusing { model.record(keyB) }
    return model
}

@MainActor func panelModel(mode: String) -> PanelModel {
    let model = PanelModel(lastModeID: mode)
    model.hotKeyLabel = standardLabel
    return model
}

// MARK: - Rendu

/// La vue seule, posée dans une fenêtre hors écran, à la taille donnée ou à sa taille idéale.
///
/// Pour les réglages, c'est le contenu de l'onglet sans la barre d'onglets : copiée par `cacheDisplay` avec la vue
/// cadre de la fenêtre, la barre d'onglets (matériau du système) sort blanche, sans texte, surtout en sombre. Elle
/// n'est donc pas rendue, plutôt que rendue fausse.
@MainActor func render(_ view: some View, name: String, dark: Bool, background: NSColor, size: NSSize? = nil) throws {
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(
        rootView: AnyView(view.background(Color(nsColor: background)).environment(\.colorScheme, dark ? .dark : .light)))
    host.appearance = appearance
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size ?? host.fittingSize),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = appearance
    window.backgroundColor = background
    window.contentView = host
    window.orderFrontRegardless()
    let target: NSView = host
    target.layoutSubtreeIfNeeded()
    // Laisse SwiftUI terminer sa mise en page et ses tâches (`checkKeys` est déjà fait).
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    guard let bitmap = target.bitmapImageRepForCachingDisplay(in: target.bounds) else {
        throw CocoaError(.fileWriteUnknown)
    }
    target.cacheDisplay(in: target.bounds, to: bitmap)
    let file = output.appendingPathComponent("\(name)-\(dark ? "sombre" : "clair").png")
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    try png.write(to: file)
    print("\(file.lastPathComponent) \(Int(target.bounds.width))×\(Int(target.bounds.height))")
    window.orderOut(nil)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

/// La taille de la vraie fenêtre (`SettingsView`).
let settingsSize = NSSize(width: 600, height: 460)
for dark in [false, true] {
    let panelBackground = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    let window = NSColor.windowBackgroundColor

    // Panneau prêt.
    try render(
        PanelView(model: panelModel(mode: "dictee-brute"), permissions: PermissionsModel(probe: granted),
                  openSettings: {}, quit: {}),
        name: "panneau-pret", dark: dark, background: panelBackground)

    // Panneau du premier lancement : accueil et permissions manquantes.
    let first = panelModel(mode: "dictee-brute")
    first.welcome = AppController.welcome(hotKeyLabel: standardLabel)
    try render(
        PanelView(model: first, permissions: PermissionsModel(probe: missing), openSettings: {}, quit: {}),
        name: "panneau-premier-lancement", dark: dark, background: panelBackground)

    // Panneau avec avis et permissions manquantes.
    let noticed = PanelModel(lastModeID: "prompt")
    noticed.setNotice(
        "Le raccourci \(standardLabel) a été refusé par macOS : ouvrez le panneau depuis la barre de menus, puis choisissez-en un autre dans Réglages.",
        for: .hotKey)
    noticed.setNotice(SettingsError.unreadableFileKept(fileName: "settings.json").localizedDescription, for: .save)
    try render(
        PanelView(model: noticed, permissions: PermissionsModel(probe: missing), openSettings: {}, quit: {}),
        name: "panneau-avis", dark: dark, background: panelBackground)

    // Réglages : vides, puis deux fournisseurs.
    for (name, list) in [("reglages-vide", [Provider]()), ("reglages-fournisseurs", [firstProvider, secondProvider])] {
        try render(
            SettingsView(
                providers: await providersModel(list), hotKey: hotKeyModel(),
                permissions: PermissionsModel(probe: granted), openSystemSettings: { _ in }),
            name: name, dark: dark, background: window, size: settingsSize)
    }

    // Onglet Raccourci : normal, puis avec le message d'un refus.
    for (name, refusing) in [("raccourci", false), ("raccourci-erreur", true)] {
        try render(
            SettingsView(
                providers: await providersModel([]), hotKey: hotKeyModel(refusing: refusing),
                permissions: PermissionsModel(probe: granted), openSystemSettings: { _ in }, initialTab: .hotKey),
            name: name, dark: dark, background: window, size: settingsSize)
    }

    // Onglet Permissions : accordées, puis refusées.
    for (name, probe) in [("permissions-accordees", granted), ("permissions-refusees", denied)] {
        try render(
            SettingsView(
                providers: await providersModel([]), hotKey: hotKeyModel(),
                permissions: PermissionsModel(probe: probe), openSystemSettings: { _ in }, initialTab: .permissions),
            name: name, dark: dark, background: window, size: settingsSize)
    }

    // Feuille d'édition : ajout vide, puis fournisseur existant avec une erreur.
    try render(
        ProviderEditor(model: await providersModel([]), existing: nil),
        name: "fournisseur-ajout", dark: dark, background: window)
    try render(
        ProviderEditor(
            model: await providersModel([firstProvider]), existing: firstProvider,
            initialFailure: ProvidersModel.message(for: ProvidersError.keyNotSaved("le trousseau a refusé l'accès."))),
        name: "fournisseur-erreur", dark: dark, background: window)
}
