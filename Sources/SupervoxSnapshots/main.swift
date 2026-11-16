import AppKit
import SupervoxApp
import SupervoxCore
import SwiftUI

// supervox-snapshots <dossier> : rend chaque écran de l'application en PNG, en clair et en sombre.
//
// Données d'exemple seulement (adresses `example.com`), doubles partout : aucun accès au trousseau, au réseau, aux
// réglages réels, au clavier ni aux permissions du système. Chaque vue est posée dans une fenêtre placée hors de
// l'écran, puis la vue d'hébergement SwiftUI (le contenu de la fenêtre, sans cadre, barre de titre ni barre d'onglets)
// est copiée par `cacheDisplay` ; le fond est peint explicitement, sans quoi il serait transparent. Voir `render`.

// supervox-snapshots --iconset <dossier.iconset> : écrit le jeu d'icônes de l'application, pour `iconutil`.
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--iconset" {
    try BrandMark.writeIconset(to: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    print("jeu d'icônes écrit : \(CommandLine.arguments[2])")
    exit(0)
}
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(
        Data("usage : supervox-snapshots <dossier de sortie>\n        supervox-snapshots --iconset <dossier.iconset>\n".utf8))
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

/// Presse-papiers en mémoire : le seul que l'outil de rendu touche. `insert` y écrit sans rien envoyer à personne.
@MainActor final class MemoryPasteboard: PasteboardAccess {
    private(set) var changeCount = 0
    private var contents = PasteboardContents(items: [])
    func read() -> PasteboardContents { contents }
    func write(_ contents: PasteboardContents) -> Bool {
        self.contents = contents
        changeCount += 1
        return true
    }
    func writeText(_ text: String, transient: Bool) -> Bool {
        changeCount += 1
        return true
    }
}

@MainActor final class NoKeyPoster: KeyPoster {
    func modifiersHeld() -> Bool { false }
    func postPaste(keyCode: UInt16) -> Bool { false }
}

/// Catalogue d'exemple : une liste figée (un modèle par état) et un nombre de jetons d'amorce donné.
struct ExampleDownloadFailure: LocalizedError {
    var errorDescription: String? { "la connexion Internet semble interrompue" }
}

actor ExampleCatalog: ModelCatalog {
    private var listed: [LocalModel]
    private let tokenCount: Int?
    init(listed: [LocalModel], tokenCount: Int? = nil) {
        self.listed = listed
        self.tokenCount = tokenCount
    }
    func models() async -> [LocalModel] { listed }
    func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        throw ExampleDownloadFailure()
    }
    func delete(_ id: String) async throws {
        if let index = listed.firstIndex(where: { $0.id == id }) { listed[index].state = .absent }
    }
    func promptTokenCount(_ vocabulary: [String], whisperModel: String) async -> Int? { tokenCount }
}

let turboID = LocalModelID.whisper("large-v3-v20240930_turbo")
func exampleModels(
    parakeet: LocalModel.State, turbo: LocalModel.State, small: LocalModel.State, base: LocalModel.State,
    voice: LocalModel.State
) -> [LocalModel] {
    [
        LocalModel(
            id: LocalModelID.parakeet, title: "Parakeet",
            detail:
                "Aperçu du texte en direct pendant que vous parlez, et moteur de dictée possible, très rapide. Comprend le petit modèle qui sert à reconnaître votre vocabulaire.",
            state: parakeet),
        LocalModel(
            id: turboID, title: "Whisper large-v3 turbo",
            detail:
                "Le modèle par défaut, celui des mesures de précision du projet. C'est le plus gros des trois : il demande le plus de temps de téléchargement, d'espace disque et de mémoire.",
            state: turbo),
        LocalModel(
            id: LocalModelID.whisper("small"), title: "Whisper small",
            detail:
                "Plus petit et plus rapide à charger que le modèle par défaut. Sa précision n'a pas été mesurée pour ce projet, et elle est en général moins bonne.",
            state: small),
        LocalModel(
            id: LocalModelID.whisper("base"), title: "Whisper base",
            detail:
                "Le plus léger des trois, pour un Mac peu puissant ou un essai rapide. Sa précision n'a pas été mesurée pour ce projet, et elle est en général plus faible.",
            state: base),
        LocalModel(
            id: LocalModelID.voiceDetector, title: "Détecteur de voix",
            detail: "Repère quand vous parlez, pour ne pas transcrire les silences.", state: voice),
    ]
}

/// Un modèle d'onglet Transcription préparé : liste lue, puis `act` (une saisie refusée, une suppression…).
@MainActor func transcriptionModel(
    _ catalog: any ModelCatalog, settings: TranscriptionSettings = .defaults,
    act: (TranscriptionModel) async -> Void = { _ in }
) async -> TranscriptionModel {
    let model = TranscriptionModel(settings: settings, catalog: catalog, promptTokenLimit: 111, save: { _ in })
    await model.refresh()
    await act(model)
    return model
}

/// 40 termes d'exemple sans rapport avec un métier (des plantes et des villes) : une liste assez longue pour que le refus du
/// vocabulaire soit crédible (voir `transcription-vocabulaire-refuse`).
let exampleTerms = [
    "Lavande", "Romarin", "Thym", "Basilic", "Menthe", "Sauge", "Fougère", "Bruyère", "Glycine", "Jasmin", "Pivoine",
    "Tulipe", "Camélia", "Hortensia", "Magnolia", "Érable", "Tilleul", "Bouleau", "Cyprès", "Olivier", "Lyon",
    "Bordeaux", "Nantes", "Rennes", "Toulouse", "Lille", "Dijon", "Annecy", "Tours", "Angers", "Nice", "Metz", "Albi",
    "Arles", "Nîmes", "Brest", "Reims", "Rouen", "Troyes", "Vichy",
]


/// Une fenêtre qui se dit clé et principale, pour les images d'une fenêtre qui a la frappe (réglages, feuilles). Une fenêtre hors
/// écran n'est jamais clé (l'outil ne peut pas activer l'application) ; sans cela, et sans `ActiveApplication`, AppKit dessine les
/// contrôles AppKit (interrupteurs, menus) dans leur style inactif : un interrupteur activé paraît éteint (piste grise).
final class ActiveLookingWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// L'outil tourne sans pouvoir activer l'application (aucune session active : `NSApp.isActive` reste faux). Or AppKit dessine un
/// interrupteur activé en gris tant que l'application n'est pas active, même dans une fenêtre clé : cause des interrupteurs
/// « éteints » des premières images. Une fenêtre qui n'est pas clé (`keyWindow: false`) garde son style inactif.
final class ActiveApplication: NSApplication {
    override var isActive: Bool { true }
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
            apply: { _ in refusing ? .failure(.refused) : .success(()) }, suspend: {}, resume: { true }, clear: {}, taken: { _ in nil }),
        save: { _, _ in })
    if refusing { model.record(keyB) }
    return model
}

/// Un fournisseur d'exemple pour l'onglet Modes : deux modèles listés, adresse `example.com`.
let modesProvider = Provider(
    id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!, name: "Fournisseur d'exemple",
    baseURL: "https://example.com/v1", kind: .openAICompatible, models: ["modele-exemple-fort", "modele-exemple-rapide"])
let modesStrong = ModelChoice(providerID: modesProvider.id, model: "modele-exemple-fort")
let modesFast = ModelChoice(providerID: modesProvider.id, model: "modele-exemple-rapide")

/// Les réglages en mémoire de l'onglet Modes : `read` les donne, `update` les modifie, ou lève si `failure` est posé. Aucun
/// fichier, aucun raccourci du système : l'application réelle est remplacée par des doubles.
@MainActor final class ExampleModes {
    var settings: AppSettings
    var failure: (any Error)?

    /// Par défaut : les quatre modes de base, un fournisseur d'exemple, les modèles fort et rapide choisis.
    init(_ settings: AppSettings? = nil) {
        if let settings {
            self.settings = settings
        } else {
            var initial = AppSettings.defaults
            initial.providers = [modesProvider]
            initial.strongModel = modesStrong
            initial.fastModel = modesFast
            self.settings = initial
        }
    }

    func makeModel() -> ModesModel {
        ModesModel(
            read: { self.settings },
            update: { change in
                if let failure = self.failure { throw failure }
                change(&self.settings)
            },
            hotKeys: ModeHotKeyControl(
                apply: { _, _ in .success(()) }, suspend: {}, resume: { true }, global: { .standard }),
            layout: layout, systemHotKeys: NoSystemHotKeys(), keyMonitor: NoKeyMonitor())
    }
}

/// L'onglet Modes. `refusing` : l'enregistrement est refusé (fichier de réglages illisible), et la bascule de Dictée brute le
/// montre.
@MainActor func modesModel(refusing: Bool = false) -> ModesModel {
    let example = ExampleModes()
    let model = example.makeModel()
    if refusing {
        example.failure = SettingsError.unreadableFileKept(fileName: "settings.json")
        model.setReview(true, for: ModeChip.rawID)
    }
    return model
}

/// Les quatre modes de base et deux modes personnels : l'un avec son modèle, son moteur et son raccourci, l'autre dont le
/// fournisseur a été supprimé.
@MainActor func exampleModesSettings() -> AppSettings {
    var settings = ExampleModes().settings
    let gone = ModelChoice(providerID: UUID(uuidString: "00000000-0000-0000-0000-0000000000ff")!, model: "modele-exemple-ancien")
    settings.modes.insert(
        Mode(
            id: "perso-compte-rendu", name: "Compte rendu", instruction: "Résume la dictée en cinq lignes.",
            model: modesFast, engine: .parakeet, hotKey: keyB, reviewBeforePaste: true), at: 3)
    settings.modes.insert(
        Mode(id: "perso-courriel", name: "Courriel poli", instruction: "Écris un courriel poli.", model: gone), at: 4)
    return settings
}

@MainActor func panelModel(mode: String) -> PanelModel {
    let model = PanelModel(lastModeID: mode)
    model.hotKeyLabel = standardLabel
    return model
}

/// Le panneau dans un état de dictée : `state`, qui porte le dernier texte récupérable s'il y en a un.
@MainActor func dictationPanelModel(mode: String = ModeChip.rawID, state: DictationViewState) -> PanelModel {
    let model = panelModel(mode: mode)
    model.dictation = state
    return model
}

/// Une courbe de niveaux plausible, du plus ancien au plus récent : des syllabes et un creux.
func exampleLevels(_ count: Int) -> [Float] {
    (0..<count).map { index in
        let syllable = abs(sin(Double(index) * 0.55)) * 0.7 + abs(sin(Double(index) * 1.7)) * 0.25
        return Float(index % 17 == 0 ? 0.04 : min(syllable, 1))
    }
}

/// Textes d'exemple inventés et neutres.
let exampleShortText = "Bonjour à tous, voici le compte rendu de la réunion de ce matin."
let exampleLongText =
    "Bonjour à tous, voici le compte rendu de la réunion de ce matin. Nous avons convenu de commencer la livraison la semaine prochaine, de vérifier les accès de chaque équipe et de renvoyer le calendrier mis à jour avant la fin de la journée. Pensez aussi à relire le dernier paragraphe, car il manque encore une précision sur le budget."

/// Un texte de relecture plus long que seize lignes (la borne haute du champ) : le champ défile.
let exampleReviewText = Array(repeating: exampleLongText, count: 5).joined(separator: "\n\n")

/// Le panneau en relecture : le texte à relire, avec l'avis éventuel et ce qu'a donné « Copier ». `copy` : `true` ou `false`
/// refait un clic sur « Copier » dont le presse-papiers accepte ou refuse le texte. `keyboard` : le panneau a la frappe (il
/// est la fenêtre clé) ; l'aide en dépend, et l'image est rendue comme dans une fenêtre clé ou non (voir `render`).
@MainActor func reviewPanelModel(
    _ draft: String, stage: DictationStage = .review, notice: String? = nil, copy: Bool? = nil, keyboard: Bool = true,
    mode: String = ModeChip.rawID, canGoBack: Bool = false, canGoForward: Bool = false
) -> PanelModel {
    let model = dictationPanelModel(
        mode: mode,
        state: DictationViewState(
            stage: stage, notice: notice, lastTranscript: exampleShortText, draft: draft, canGoBack: canGoBack,
            canGoForward: canGoForward))
    model.panelHasKeyboard = keyboard
    if let copy {
        model.onCopy = { _ in copy }
        model.copyTranscript()
    }
    return model
}

/// Le panneau pendant une correction à la voix : le brouillon en lecture seule, l'étape, et la phrase que le contrôleur y met.
/// `streamed` : le texte que le modèle envoie à mesure (la réécriture), montré à la place du brouillon. Le texte de la consigne
/// en direct (`liveText` pendant l'écoute) n'est jamais montré : l'image n'en pose pas.
@MainActor func correctionPanelModel(
    _ step: CorrectionStep, draft: String, streamed: String = "", notice: String? = nil
) -> PanelModel {
    let listening = step == .recording
    let model = dictationPanelModel(
        state: DictationViewState(
            stage: .correcting(step), liveText: streamed, levels: listening ? exampleLevels(DictationViewState.levelCount) : [],
            elapsed: listening ? 4.2 : 0, notice: notice, lastTranscript: exampleShortText, draft: draft))
    model.panelHasKeyboard = true
    return model
}

/// Le nom du fournisseur des images de la mise en forme : fictif, comme les doubles.
let exampleProvider = "Fournisseur d'exemple"
/// Le début d'une réponse du modèle, coupé en cours de phrase comme à l'arrivée du flux : des paragraphes et des puces, comme une
/// vraie mise en forme. L'écran les aplatit pour montrer la fin du texte reçu.
let exampleStreamedText =
    "Bonjour à tous,\n\nVoici le compte rendu de la réunion de ce matin.\n\nNous avons convenu de :\n- commencer la livraison la semaine prochaine ;\n- vérifier les accès de chaque équipe ;\n- renvoyer le calendrier mis à jour avant la fin de la journée.\n\nMerci d'avance pour votre relecture.\n\nNous reviendrons vers vous avec"
/// Le texte mis en forme d'un mode qui relit avant de coller : des paragraphes et une formule de politesse.
let exampleFormattedText =
    "Bonjour à tous,\n\nVoici le compte rendu de la réunion de ce matin.\n\nNous avons convenu de commencer la livraison la semaine prochaine, de vérifier les accès de chaque équipe et de renvoyer le calendrier mis à jour avant la fin de la journée.\n\nCordialement,"

/// Le début de la réponse du modèle à la consigne « ajoute une formule de politesse plus chaleureuse », coupé en cours de phrase
/// comme à l'arrivée du flux : le texte reçu garde ses sauts de ligne, il est montré tel quel à la place du brouillon.
let exampleCorrectedStream =
    "Bonjour à tous,\n\nVoici le compte rendu de la réunion de ce matin.\n\nNous avons convenu de commencer la livraison la semaine prochaine, de vérifier les accès de chaque équipe et de renvoyer le calendrier mis à jour avant la fin de la journée.\n\nBien cordialement et bonne"

/// La raison que l'insertion donne quand elle n'a pas l'Accessibilité : celle de l'application, obtenue en l'exécutant sur un
/// presse-papiers en mémoire et un poseur de touches qui ne poste rien.
@MainActor func accessibilityReason() async -> String {
    let inserter = TextInserter(
        pasteboard: MemoryPasteboard(), keys: NoKeyPoster(), layout: layout, isTrusted: { false }, wait: { _ in })
    if case .copied(let reason) = await inserter.insert(exampleShortText) { return reason }
    return "(raison introuvable)"
}

// MARK: - Rendu

/// La vue seule, posée dans une fenêtre hors écran, à la taille donnée ou à sa taille idéale.
///
/// Pour les réglages, c'est le contenu de l'onglet sans la barre d'onglets : copiée par `cacheDisplay` avec la vue
/// cadre de la fenêtre, la barre d'onglets (matériau du système) sort blanche, sans texte, surtout en sombre. Elle
/// n'est donc pas rendue, plutôt que rendue fausse.
///
/// `keyWindow` : la vue est rendue comme dans une fenêtre clé (le bouton principal prend la couleur d'accent) ; la fenêtre hors
/// écran ne l'est jamais, et un bouton principal y sort gris, comme dans une fenêtre inactive. À dire pour chaque image de
/// relecture, selon que le panneau a la frappe dans cet état ou non.
@MainActor func render(
    _ view: some View, name: String, dark: Bool, background: NSColor, size: NSSize? = nil, keyWindow requested: Bool = false
) throws {
    // La fenêtre de réglages et ses feuilles ont la frappe quand on les regarde : elles sont rendues comme une fenêtre clé (contrôles
    // actifs, interrupteurs à la couleur d'accent). Le panneau, lui, dit lui-même s'il a la frappe (`keyWindow`).
    let isPanel = ["panneau", "dictee", "relecture", "mise-en-forme", "correction"].contains { name.hasPrefix($0) }
    let keyWindow = requested || !isPanel
    let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let host = NSHostingView(
        rootView: AnyView(
            view.background(Color(nsColor: background)).environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.controlActiveState, keyWindow ? .key : .inactive)))
    host.appearance = appearance
    let window = (keyWindow ? ActiveLookingWindow.self : NSWindow.self).init(
        contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size ?? host.fittingSize),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.appearance = appearance
    window.backgroundColor = background
    window.contentView = host
    if keyWindow { window.makeKeyAndOrderFront(nil) } else { window.orderFrontRegardless() }
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

let application = ActiveApplication.shared
application.setActivationPolicy(.accessory)

/// La taille de la vraie fenêtre (`SettingsView`).
let settingsSize = NSSize(width: 600, height: 460)
for dark in [false, true] {
    let panelBackground = dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.95, alpha: 1)
    let window = NSColor.windowBackgroundColor

    // Panneau prêt.
    try render(
        PanelView(model: panelModel(mode: ModeChip.rawID), permissions: PermissionsModel(probe: granted),
                  openSettings: {}, quit: {}),
        name: "panneau-pret", dark: dark, background: panelBackground)

    // Douze modes aux noms longs, inventés : les pastilles passent à la ligne, rien n'est coupé, le panneau grandit.
    let manyChips = [
        "Dictée brute", "Compte rendu de réunion", "Message court et poli", "Résumé en trois points",
        "Note de suivi pour l'équipe", "Réponse détaillée à un courriel", "Liste de tâches du jour",
        "Texte corrigé sans changer le ton", "Idée à creuser plus tard", "Prompt", "Traduction en anglais soigné", "Entretien",
    ].enumerated().map { ModeChip(id: "exemple-\($0.offset)", title: $0.element) }
    let crowded = PanelModel(lastModeID: "exemple-5", modes: manyChips)
    crowded.hotKeyLabel = standardLabel
    try render(
        PanelView(model: crowded, permissions: PermissionsModel(probe: granted), openSettings: {}, quit: {}),
        name: "panneau-pastilles-nombreuses", dark: dark, background: panelBackground)

    // Panneau du premier lancement : accueil et permissions manquantes.
    let first = panelModel(mode: ModeChip.rawID)
    first.welcome = AppController.welcome(hotKeyLabel: standardLabel)
    try render(
        PanelView(model: first, permissions: PermissionsModel(probe: missing), openSettings: {}, quit: {}),
        name: "panneau-premier-lancement", dark: dark, background: panelBackground)

    // Panneau avec avis et permissions manquantes.
    let noticed = PanelModel(lastModeID: ModeChip.promptID)
    noticed.setNotice(
        "Le raccourci \(standardLabel) a été refusé par macOS : ouvrez le panneau depuis la barre de menus, puis choisissez-en un autre dans Réglages.",
        for: .hotKey)
    noticed.setNotice(SettingsError.unreadableFileKept(fileName: "settings.json").localizedDescription, for: .save)
    try render(
        PanelView(model: noticed, permissions: PermissionsModel(probe: missing), openSettings: {}, quit: {}),
        name: "panneau-avis", dark: dark, background: panelBackground)

    // La dictée dans le panneau. Chaque état a sa hauteur naturelle : le panneau suit son contenu.
    let reason = await accessibilityReason()
    let cases: [(String, PanelModel, any PermissionsProbe)] = [
        ("dictee-preparation-telechargement",
         dictationPanelModel(state: DictationViewState(stage: .preparing, notice: DictationController.downloadNotice)), granted),
        ("dictee-preparation-chargement",
         dictationPanelModel(state: DictationViewState(stage: .preparing, notice: DictationController.loadingNotice)), granted),
        ("dictee-enregistrement",
         dictationPanelModel(state: DictationViewState(stage: .recording, levels: exampleLevels(30), elapsed: 7.4)), granted),
        ("dictee-enregistrement-texte-long",
         dictationPanelModel(
            state: DictationViewState(
                stage: .recording, liveText: exampleLongText, levels: exampleLevels(48), elapsed: 65.2)), granted),
        ("dictee-transcription",
         dictationPanelModel(
            state: DictationViewState(
                stage: .finalizing, liveText: exampleShortText, levels: exampleLevels(48), elapsed: 12.9)), granted),
        ("dictee-echec-aucune-voix",
         dictationPanelModel(
            state: DictationViewState(stage: .failed(.noSpeech), notice: DictationFailure.noSpeech.message)), granted),
        ("dictee-echec-preparation",
         dictationPanelModel(
            state: DictationViewState(
                stage: .failed(.engine("x")), notice: DictationController.preparationFailedNotice,
                lastTranscript: exampleShortText)), granted),
        ("dictee-texte-copie",
         dictationPanelModel(
            state: DictationViewState(stage: .copied, notice: reason, lastTranscript: exampleLongText)),
         ExamplePermissions(microphoneState: .granted, accessibilityState: .denied)),
        // Le pire cas de hauteur : un message de quatre lignes et un dernier texte de trois lignes.
        ("dictee-echec-message-long",
         dictationPanelModel(
            state: DictationViewState(
                stage: .failed(.engine("x")), notice: reason + " " + reason,
                lastTranscript: exampleLongText + " " + exampleLongText)),
         granted),
        ("dictee-mode-indisponible",
         dictationPanelModel(
            mode: ModeChip.interviewID, state: DictationViewState(notice: DictationController.laterModeNotice)), granted),
        ("dictee-dernier-texte", dictationPanelModel(state: DictationViewState(lastTranscript: exampleShortText)), granted),
        ("dictee-dernier-texte-copie", {
            let model = dictationPanelModel(state: DictationViewState(lastTranscript: exampleLongText))
            model.onCopy = { _ in true }
            model.copyTranscript()
            return model
        }(), granted),
        ("dictee-presse-papiers-refuse",
         dictationPanelModel(
            state: DictationViewState(
                stage: .failed(.clipboard), notice: DictationFailure.clipboard.message,
                lastTranscript: exampleShortText)), granted),
        ("dictee-copie-impossible", {
            let model = dictationPanelModel(state: DictationViewState(lastTranscript: exampleLongText))
            model.onCopy = { _ in false }
            model.copyTranscript()
            return model
        }(), granted),
    ]
    for (name, model, probe) in cases {
        try render(
            PanelView(model: model, permissions: PermissionsModel(probe: probe), openSettings: {}, quit: {}),
            name: name, dark: dark, background: panelBackground,)
    }

    // La relecture : le texte à corriger, puis coller ou copier. `keyboard` dit si le panneau a la frappe dans cet état : il
    // l'a au début de la relecture (`.focused`) et après un clic sur « Copier » ; pas après un collage manqué (`.available` : la
    // frappe est à l'application de dessous, jusqu'à un clic dans le panneau), ni après un clic dans une autre application,
    // ni pendant le collage (`.none`). L'image est rendue comme dans une fenêtre clé exactement quand le panneau a la frappe.
    let accessDenied = ExamplePermissions(microphoneState: .granted, accessibilityState: .denied)
    let reviewCases: [(name: String, model: PanelModel, probe: any PermissionsProbe)] = [
        ("relecture-courte", reviewPanelModel(exampleShortText), granted),
        ("relecture-longue", reviewPanelModel(exampleReviewText), granted),
        ("relecture-vide", reviewPanelModel(""), granted),
        ("relecture-collage", reviewPanelModel(exampleShortText, stage: .pasting, keyboard: false), granted),
        ("relecture-sans-frappe", reviewPanelModel(exampleShortText, keyboard: false), granted),
        ("relecture-copie-sans-accessibilite",
         reviewPanelModel(exampleShortText, notice: reason, keyboard: false), accessDenied),
        ("relecture-presse-papiers-refuse",
         reviewPanelModel(exampleShortText, notice: DictationController.reviewClipboardNotice, keyboard: false), granted),
        ("relecture-copiee", reviewPanelModel(exampleShortText, copy: true), granted),
        ("relecture-copie-impossible", reviewPanelModel(exampleShortText, copy: false), granted),
    ]
    for (name, model, probe) in reviewCases {
        try render(
            PanelView(model: model, permissions: PermissionsModel(probe: probe), openSettings: {}, quit: {}),
            name: name, dark: dark, background: panelBackground, keyWindow: model.panelHasKeyboard)
    }

    // La mise en forme : l'attente, le flux de la réponse, puis la relecture. Une panne ramène la transcription brute, avec la
    // phrase de la panne et celle de `rawTextNotice` ; l'application changée garde le texte mis en forme (le panneau n'a alors pas
    // la frappe : `.available`).
    let sending = DictationController.formattingNotice(provider: exampleProvider)
    let rawNotice = { (failure: RewriteFailure) in failure.message + " " + DictationController.rawTextNotice }
    let formattingCases: [(name: String, model: PanelModel, probe: any PermissionsProbe)] = [
        ("mise-en-forme-attente",
         dictationPanelModel(
            mode: ModeChip.cleanedID,
            state: DictationViewState(stage: .formatting, notice: sending, lastTranscript: exampleLongText)), granted),
        ("mise-en-forme-flux",
         dictationPanelModel(
            mode: ModeChip.cleanedID,
            state: DictationViewState(
                stage: .formatting, liveText: exampleStreamedText, notice: sending, lastTranscript: exampleLongText)),
         granted),
        ("mise-en-forme-echec-cle",
         reviewPanelModel(
            exampleLongText, notice: rawNotice(.noKey(provider: exampleProvider)), mode: ModeChip.cleanedID), granted),
        // Le cas le plus long : un nom de fournisseur de 60 caractères, rogné à 40 par `Provider.shortName`.
        ("mise-en-forme-echec-cle-nom-long",
         reviewPanelModel(
            exampleLongText,
            notice: rawNotice(.noKey(provider: Provider.shortName(String(repeating: "Fournisseur ", count: 5)))),
            mode: ModeChip.cleanedID), granted),
        ("mise-en-forme-echec-delai",
         reviewPanelModel(
            exampleLongText, notice: rawNotice(.timedOut(Int(RewritePolicy.standard.timeout.rounded()))),
            mode: ModeChip.cleanedID), granted),
        ("mise-en-forme-application-changee",
         reviewPanelModel(
            exampleFormattedText, notice: DictationController.frontApplicationChangedNotice, keyboard: false,
            mode: ModeChip.cleanedID), granted),
        ("relecture-apres-mise-en-forme", reviewPanelModel(exampleFormattedText, mode: ModeChip.cleanedID), granted),
    ]
    for (name, model, probe) in formattingCases {
        try render(
            PanelView(model: model, permissions: PermissionsModel(probe: probe), openSettings: {}, quit: {}),
            name: name, dark: dark, background: panelBackground, keyWindow: model.panelHasKeyboard)
    }

    // La correction à la voix : l'écoute de la consigne (forme d'onde et durée au-dessus du champ, en lecture seule), la
    // réécriture (le texte reçu à la place du brouillon), puis les deux retours à la relecture, texte intact, avec leur phrase
    // (seules les phrases publiques du contrôleur sont posées ici). Les versions : un bouton à flèche à gauche de la rangée.
    let correctionCases: [(name: String, model: PanelModel, probe: any PermissionsProbe)] = [
        ("correction-ecoute",
         correctionPanelModel(
            .recording, draft: exampleFormattedText,
            notice: DictationController.correctionListeningNotice(hotKeyLabel: standardLabel)), granted),
        // Tant que le micro ne s'ouvre pas, la phrase dit d'attendre ; en maintien, d'écouter jusqu'au relâchement.
        ("correction-preparation",
         correctionPanelModel(
            .preparing, draft: exampleFormattedText, notice: DictationController.correctionPreparingNotice), granted),
        ("correction-preparation-maintien",
         correctionPanelModel(
            .preparing, draft: exampleFormattedText,
            notice: DictationController.correctionPreparingSentence(hotKeyLabel: standardLabel, hold: true)), granted),
        ("correction-ecoute-maintien",
         correctionPanelModel(
            .recording, draft: exampleFormattedText,
            notice: DictationController.correctionListeningNotice(hotKeyLabel: standardLabel, hold: true)), granted),
        ("correction-reecriture",
         correctionPanelModel(
            .rewriting, draft: exampleFormattedText, streamed: exampleCorrectedStream,
            notice: DictationController.correctionRewritingNotice), granted),
        ("correction-echec",
         reviewPanelModel(exampleFormattedText, notice: DictationController.correctionNoModelNotice), granted),
        ("correction-echec-fournisseur",
         reviewPanelModel(
            exampleFormattedText, notice: DictationController.correctionNotice(for: .providerMissing)), granted),
        ("correction-vide",
         reviewPanelModel(exampleFormattedText, notice: DictationController.correctionEmptyNotice), granted),
        ("relecture-avec-version-precedente", reviewPanelModel(exampleFormattedText, canGoBack: true), granted),
        ("relecture-avec-version-suivante", reviewPanelModel(exampleFormattedText, canGoForward: true), granted),
        ("relecture-avec-deux-versions-copie-impossible",
         reviewPanelModel(exampleFormattedText, copy: false, canGoBack: true, canGoForward: true), granted),
        ("relecture-aide-correction", reviewPanelModel(exampleFormattedText), granted),
        ("relecture-aide-correction-sans-raccourci", {
            let model = reviewPanelModel(exampleFormattedText)
            model.hotKeyLabel = nil
            return model
        }(), granted),
    ]
    for (name, model, probe) in correctionCases {
        try render(
            PanelView(model: model, permissions: PermissionsModel(probe: probe), openSettings: {}, quit: {}),
            name: name, dark: dark, background: panelBackground, keyWindow: model.panelHasKeyboard)
    }

    // Réglages : vides, puis deux fournisseurs.
    for (name, list) in [("reglages-vide", [Provider]()), ("reglages-fournisseurs", [firstProvider, secondProvider])] {
        try render(
            SettingsView(
                providers: await providersModel(list), hotKey: hotKeyModel(),
                transcription: await transcriptionModel(UnavailableModelCatalog()), modes: modesModel(),
                permissions: PermissionsModel(probe: granted), openSystemSettings: { _ in }),
            name: name, dark: dark, background: window, size: settingsSize)
    }

    // Onglet Raccourci : normal, puis avec le message d'un refus.
    for (name, refusing) in [("raccourci", false), ("raccourci-erreur", true)] {
        try render(
            SettingsView(
                providers: await providersModel([]), hotKey: hotKeyModel(refusing: refusing),
                transcription: await transcriptionModel(UnavailableModelCatalog()), modes: modesModel(),
                permissions: PermissionsModel(probe: granted), openSystemSettings: { _ in }, initialTab: .hotKey),
            name: name, dark: dark, background: window, size: settingsSize)
    }

    // Onglet Permissions : accordées, puis refusées.
    for (name, probe) in [("permissions-accordees", granted), ("permissions-refusees", denied)] {
        try render(
            SettingsView(
                providers: await providersModel([]), hotKey: hotKeyModel(),
                transcription: await transcriptionModel(UnavailableModelCatalog()), modes: modesModel(),
                permissions: PermissionsModel(probe: probe), openSystemSettings: { _ in }, initialTab: .permissions),
            name: name, dark: dark, background: window, size: settingsSize)
    }

    // Onglet Modes : les défauts, puis un enregistrement refusé. À la taille de la vraie fenêtre.
    for (name, refusing) in [("modes", false), ("modes-erreur", true)] {
        try render(
            SettingsView(
                providers: await providersModel([]), hotKey: hotKeyModel(),
                transcription: await transcriptionModel(UnavailableModelCatalog()), modes: modesModel(refusing: refusing),
                permissions: PermissionsModel(probe: granted), openSystemSettings: { _ in }, initialTab: .modes),
            name: name, dark: dark, background: window, size: settingsSize)
    }
    // Toute la liste, avec deux modes personnels (modèle, moteur, raccourci ; fournisseur supprimé) : la vraie fenêtre la fait
    // défiler.
    try render(
        ModesPane(model: ExampleModes(exampleModesSettings()).makeModel()),
        name: "modes-complet", dark: dark, background: window, size: NSSize(width: 600, height: 1_000))

    // Premier lancement : aucun fournisseur, aucun modèle fort ni rapide. Toute la liste, avec la section Modèles.
    try render(
        ModesPane(model: ExampleModes(AppSettings.defaults).makeModel()),
        name: "modes-premier-lancement", dark: dark, background: window, size: NSSize(width: 600, height: 900))

    // Confirmations de suppression : un mode de base (Prompt), puis un mode personnel.
    let deletion = ExampleModes(exampleModesSettings()).makeModel()
    for (name, id) in [("base", ModeChip.promptID), ("perso", "perso-compte-rendu")] {
        let row = deletion.rows.first { $0.id == id }!
        try render(
            DeletionSheet(
                title: ModesPane.deletionTitle(for: row), message: ModesPane.deletionMessage(for: row, chosenInPanel: id != ModeChip.promptID), cancel: {}, confirm: {}),
            name: "mode-suppression-\(name)", dark: dark, background: window)
    }

    // Feuilles d'un mode, à la taille que la feuille prend.
    // La vraie taille de la feuille : ce que l'utilisateur voit sans faire défiler.
    let sheetHeight = ModeEditor.sheetHeight
    let sheetSize = NSSize(width: 520, height: sheetHeight)
    let realSheetSize = sheetSize
    // Un mode de base dont la consigne a été modifiée : le bouton « Revenir à la consigne d'origine ».
    let editedBase = ExampleModes()
    editedBase.settings.modes[2].instruction =
        "Tu transformes une demande dictée en un prompt court, en trois parties : Objectif, Contraintes, Résultat attendu. N'invente rien."
    try render(
        ModeEditor(model: editedBase.makeModel(), id: ModeChip.promptID, height: sheetHeight),
        name: "mode-edition-base", dark: dark, background: window, size: sheetSize, keyWindow: true)
    // Le cas le plus chargé : Prompt avec sa consigne d'origine (longue), son modèle et un raccourci. Toute la feuille tient, y
    // compris « Raccourci du mode », sans faire défiler.
    let loadedPrompt = ExampleModes()
    loadedPrompt.settings.modes[2].hotKey = keyB
    try render(
        ModeEditor(model: loadedPrompt.makeModel(), id: ModeChip.promptID, height: sheetHeight),
        name: "mode-edition-prompt-origine", dark: dark, background: window, size: sheetSize, keyWindow: true)
    // Premier lancement : Prompt sans fournisseur ni modèle fort (la réserve, et l'explication sous le sélecteur).
    try render(
        ModeEditor(model: ExampleModes(AppSettings.defaults).makeModel(), id: ModeChip.promptID, height: sheetHeight),
        name: "mode-edition-sans-fournisseur", dark: dark, background: window, size: sheetSize, keyWindow: true)
    // Entretien : consigne non modifiable, relecture imposée.
    try render(
        ModeEditor(model: ExampleModes().makeModel(), id: ModeChip.interviewID, height: sheetHeight),
        name: "mode-edition-entretien", dark: dark, background: window, size: sheetSize, keyWindow: true)
    // Un mode personnel avec son modèle : la note de vie privée.
    let personal = ExampleModes(exampleModesSettings())
    try render(
        ModeEditor(model: personal.makeModel(), id: "perso-compte-rendu", height: sheetHeight),
        name: "mode-edition-perso", dark: dark, background: window, size: sheetSize, keyWindow: true)
    // Un fournisseur dont la liste de modèles n'a pas été lue : le modèle choisi reste affiché, la feuille renvoie à l'onglet
    // Fournisseurs.
    var unlisted = exampleModesSettings()
    unlisted.providers[0].models = []
    try render(
        ModeEditor(model: ExampleModes(unlisted).makeModel(), id: "perso-compte-rendu", height: sheetHeight),
        name: "mode-edition-sans-modele", dark: dark, background: window, size: sheetSize, keyWindow: true)
    // Une combinaison refusée : celle du raccourci général.
    let refusedHotKey = ExampleModes(exampleModesSettings())
    let refusedModel = refusedHotKey.makeModel()
    refusedModel.record(.standard, for: "perso-compte-rendu")
    try render(
        ModeEditor(model: refusedModel, id: "perso-compte-rendu", height: sheetHeight),
        name: "mode-raccourci-refuse", dark: dark, background: window, size: sheetSize, keyWindow: true)
    // Une consigne de plusieurs milliers de caractères : elle défile dans son champ, la feuille garde sa taille.
    var long = exampleModesSettings()
    long.modes[3].instruction = Array(
        repeating: "Mets le texte au propre, garde le sens et le ton, n'ajoute rien et ne réponds jamais au contenu.", count: 45
    ).joined(separator: " ")
    try render(
        ModeEditor(model: ExampleModes(long).makeModel(), id: "perso-compte-rendu"),
        name: "mode-edition-longue", dark: dark, background: window, size: realSheetSize, keyWindow: true)

    // Onglet Transcription. La barre d'onglets n'est pas rendue (voir `render`).
    func transcriptionTab(_ model: TranscriptionModel) async -> SettingsView {
        SettingsView(
            providers: await providersModel([]), hotKey: hotKeyModel(), transcription: model, modes: modesModel(),
            permissions: PermissionsModel(probe: granted), openSystemSettings: { _ in }, initialTab: .transcription)
    }
    let allAbsentModels = exampleModels(parakeet: .absent, turbo: .absent, small: .absent, base: .absent, voice: .absent)
    let allReadyModels = exampleModels(parakeet: .ready, turbo: .ready, small: .absent, base: .absent, voice: .ready)
    let tallSize = NSSize(width: 600, height: 1_260)
    let whisperChosen = TranscriptionSettings(
        engine: .whisperKit, whisperModel: "large-v3-v20240930_turbo", language: "fr",
        vocabulary: ["Kubernetes", "PostgreSQL", "Keycloak"])

    // Tous les états d'une ligne : en cours sans fraction (Parakeet : deux téléchargements enchaînés, aucune fraction
    // honnête), prêt, incomplet, non téléchargé, en cours avec la fraction de la bibliothèque (détecteur de voix). Le
    // contenu de l'onglet en entier : la vraie fenêtre le fait défiler.
    try render(
        TranscriptionPane(
            model: await transcriptionModel(
                ExampleCatalog(
                    listed: exampleModels(
                        parakeet: .downloading(nil), turbo: .ready, small: .incomplete, base: .absent,
                        voice: .downloading(0.55))),
                settings: whisperChosen)),
        name: "transcription-etats", dark: dark, background: window, size: tallSize)
    // Un échec de téléchargement, avec « Réessayer » et « Supprimer… ».
    try render(
        TranscriptionPane(
            model: await transcriptionModel(
                ExampleCatalog(listed: exampleModels(parakeet: .ready, turbo: .absent, small: .absent, base: .absent, voice: .ready)),
                settings: whisperChosen,
                act: { model in
                    // Un échec réel du modèle : le catalogue d'exemple refuse ce téléchargement.
                    await model.download(turboID)
                })),
        name: "transcription-echec", dark: dark, background: window, size: tallSize)
    // Parakeet choisi alors que le modèle Whisper des réglages est le modèle par défaut, prêt : seul Parakeet porte
    // « moteur choisi », jamais la ligne Whisper.
    try render(
        TranscriptionPane(
            model: await transcriptionModel(
                ExampleCatalog(listed: allReadyModels),
                settings: TranscriptionSettings(
                    engine: .parakeet, whisperModel: "large-v3-v20240930_turbo", language: "fr", vocabulary: []))),
        name: "transcription-parakeet", dark: dark, background: window, size: tallSize)
    // Vocabulaire refusé : 40 termes d'exemple, trop longs pour Whisper. Le compte (136 pour une limite de 111) est une
    // valeur d'exemple fixée par le double du catalogue : elle n'a pas été mesurée avec le tokenizer sur cette liste. Le champ
    // garde la saisie refusée.
    let refused = await transcriptionModel(
        ExampleCatalog(listed: allReadyModels, tokenCount: 136),
        settings: TranscriptionSettings(
            engine: .whisperKit, whisperModel: "large-v3-v20240930_turbo", language: "fr",
            vocabulary: Array(exampleTerms.prefix(30))),
        act: { _ = await $0.setVocabulary(text: exampleTerms.joined(separator: "\n")) })
    try render(
        TranscriptionPane(model: refused, draft: exampleTerms.joined(separator: "\n")),
        name: "transcription-vocabulaire-refuse", dark: dark, background: window, size: tallSize)
    // Vocabulaire accepté, mais le modèle n'est pas là pour compter.
    try render(
        TranscriptionPane(
            model: await transcriptionModel(
                ExampleCatalog(listed: allAbsentModels, tokenCount: nil),
                act: { _ = await $0.setVocabulary(text: "Kubernetes\nPostgreSQL") })),
        name: "transcription-vocabulaire-avertissement", dark: dark, background: window, size: tallSize)
    // Suppression de Parakeet alors que WhisperKit est choisi : le bandeau, au-dessus du formulaire, à la taille de la vraie
    // fenêtre ; il ne recouvre rien.
    try render(
        await transcriptionTab(
            await transcriptionModel(
                ExampleCatalog(listed: allReadyModels), settings: whisperChosen,
                act: { await $0.delete(LocalModelID.parakeet) })),
        name: "transcription-fenetre-bandeau", dark: dark, background: window, size: settingsSize)
    // Les deux confirmations de suppression : un dossier partagé (Parakeet), et le modèle du moteur choisi.
    let confirming = await transcriptionModel(ExampleCatalog(listed: allReadyModels), settings: whisperChosen)
    for (name, id) in [("partagee", LocalModelID.parakeet), ("modele", turboID)] {
        let model = confirming.models.first { $0.id == id }!
        try render(
            DeletionSheet(
                title: "Supprimer « \(model.title) » de ce Mac ?", message: confirming.deletionConfirmation(for: model),
                cancel: {}, confirm: {}),
            name: "transcription-confirmation-\(name)", dark: dark, background: window)
    }
    // Version sans catalogue de modèles.
    try render(
        TranscriptionPane(model: await transcriptionModel(UnavailableModelCatalog())),
        name: "transcription-indisponible", dark: dark, background: window, size: NSSize(width: 600, height: 760))

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
