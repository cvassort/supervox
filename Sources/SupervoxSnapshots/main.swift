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

/// 40 termes d'infrastructure : un vocabulaire d'administrateur système réaliste (voir `transcription-vocabulaire-refuse`).
let infrastructureTerms = [
    "Kubernetes", "PostgreSQL", "Keycloak", "Terraform", "Ansible", "Grafana", "Prometheus", "Redis", "RabbitMQ",
    "OpenSearch", "Kafka", "Nginx", "GitLab", "Helm", "Traefik", "Elasticsearch", "Logstash", "Kibana", "Jenkins",
    "SonarQube", "Vault", "Consul", "Nomad", "Istio", "Envoy", "Argo CD", "Harbor", "MinIO", "Ceph", "Zabbix", "Nagios",
    "Wazuh", "Suricata", "Graylog", "Loki", "Tempo", "Jaeger", "OpenTelemetry", "Podman", "Buildah",
]

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

/// Le panneau dans un état de dictée : `state`, et le dernier texte récupérable s'il y en a un.
@MainActor func dictationPanelModel(
    mode: String = "dictee-brute", state: DictationViewState, transcript: String? = nil
) -> PanelModel {
    let model = panelModel(mode: mode)
    model.dictation = state
    model.setTranscript(transcript)
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

    // La dictée dans le panneau. Même largeur et même zone de dictée dans tous les états (voir `DictationView.height`).
    let reason = await accessibilityReason()
    let cases: [(String, PanelModel, any PermissionsProbe)] = [
        ("dictee-preparation-telechargement",
         dictationPanelModel(state: DictationViewState(phase: .preparing, notice: DictationController.downloadNotice)), granted),
        ("dictee-enregistrement",
         dictationPanelModel(state: DictationViewState(phase: .recording, levels: exampleLevels(30), elapsed: 7.4)), granted),
        ("dictee-enregistrement-texte-long",
         dictationPanelModel(
            state: DictationViewState(
                phase: .recording, liveText: exampleLongText, levels: exampleLevels(48), elapsed: 65.2)), granted),
        ("dictee-transcription",
         dictationPanelModel(
            state: DictationViewState(
                phase: .finalizing, liveText: exampleShortText, levels: exampleLevels(48), elapsed: 12.9)), granted),
        ("dictee-echec-aucune-voix",
         dictationPanelModel(
            state: DictationViewState(phase: .failed(.noSpeech), notice: DictationFailure.noSpeech.message)), granted),
        ("dictee-echec-preparation",
         dictationPanelModel(
            state: DictationViewState(phase: .failed(.engine("x")), notice: DictationController.preparationFailedNotice),
            transcript: exampleShortText), granted),
        ("dictee-texte-copie",
         dictationPanelModel(
            state: DictationViewState(phase: .finished(exampleLongText), notice: reason), transcript: exampleLongText),
         ExamplePermissions(microphoneState: .granted, accessibilityState: .denied)),
        // Le pire cas de hauteur : un message de quatre lignes et un dernier texte de trois lignes.
        ("dictee-echec-message-long",
         dictationPanelModel(
            state: DictationViewState(phase: .failed(.engine("x")), notice: reason + " " + reason), transcript: exampleLongText + " " + exampleLongText),
         granted),
        ("dictee-mode-indisponible",
         dictationPanelModel(
            mode: "entretien", state: DictationViewState(notice: DictationController.laterModeNotice)), granted),
        ("dictee-dernier-texte", dictationPanelModel(state: DictationViewState(), transcript: exampleShortText), granted),
        ("dictee-dernier-texte-copie", {
            let model = dictationPanelModel(state: DictationViewState(), transcript: exampleLongText)
            model.onCopy = { _ in true }
            model.copyTranscript()
            return model
        }(), granted),
        ("dictee-copie-impossible", {
            let model = dictationPanelModel(state: DictationViewState(), transcript: exampleLongText)
            model.onCopy = { _ in false }
            model.copyTranscript()
            return model
        }(), granted),
    ]
    for (name, model, probe) in cases {
        try render(
            PanelView(model: model, permissions: PermissionsModel(probe: probe), openSettings: {}, quit: {}),
            name: name, dark: dark, background: panelBackground)
    }

    // Réglages : vides, puis deux fournisseurs.
    for (name, list) in [("reglages-vide", [Provider]()), ("reglages-fournisseurs", [firstProvider, secondProvider])] {
        try render(
            SettingsView(
                providers: await providersModel(list), hotKey: hotKeyModel(),
                transcription: await transcriptionModel(UnavailableModelCatalog()),
                permissions: PermissionsModel(probe: granted), openSystemSettings: { _ in }),
            name: name, dark: dark, background: window, size: settingsSize)
    }

    // Onglet Raccourci : normal, puis avec le message d'un refus.
    for (name, refusing) in [("raccourci", false), ("raccourci-erreur", true)] {
        try render(
            SettingsView(
                providers: await providersModel([]), hotKey: hotKeyModel(refusing: refusing),
                transcription: await transcriptionModel(UnavailableModelCatalog()),
                permissions: PermissionsModel(probe: granted), openSystemSettings: { _ in }, initialTab: .hotKey),
            name: name, dark: dark, background: window, size: settingsSize)
    }

    // Onglet Permissions : accordées, puis refusées.
    for (name, probe) in [("permissions-accordees", granted), ("permissions-refusees", denied)] {
        try render(
            SettingsView(
                providers: await providersModel([]), hotKey: hotKeyModel(),
                transcription: await transcriptionModel(UnavailableModelCatalog()),
                permissions: PermissionsModel(probe: probe), openSystemSettings: { _ in }, initialTab: .permissions),
            name: name, dark: dark, background: window, size: settingsSize)
    }

    // Onglet Transcription. La barre d'onglets n'est pas rendue (voir `render`).
    func transcriptionTab(_ model: TranscriptionModel) async -> SettingsView {
        SettingsView(
            providers: await providersModel([]), hotKey: hotKeyModel(), transcription: model,
            permissions: PermissionsModel(probe: granted), openSystemSettings: { _ in }, initialTab: .transcription)
    }
    let allAbsentModels = exampleModels(parakeet: .absent, turbo: .absent, small: .absent, base: .absent, voice: .absent)
    let allReadyModels = exampleModels(parakeet: .ready, turbo: .ready, small: .absent, base: .absent, voice: .ready)
    let tallSize = NSSize(width: 600, height: 1_260)
    let whisperChosen = TranscriptionSettings(
        engine: "whisperkit", whisperModel: "large-v3-v20240930_turbo", language: "fr",
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
                    engine: "parakeet", whisperModel: "large-v3-v20240930_turbo", language: "fr", vocabulary: []))),
        name: "transcription-parakeet", dark: dark, background: window, size: tallSize)
    // Vocabulaire refusé : un vrai vocabulaire (40 termes d'infrastructure) trop long pour Whisper. Le compte vient du
    // tokenizer de large-v3, celui du modèle par défaut (`WhisperKitTranscriber.promptTokenCount`, hors ligne) : 30
    // premiers termes = 102, 40 termes = 136, pour une limite de 111. Le champ garde la saisie refusée.
    let refused = await transcriptionModel(
        ExampleCatalog(listed: allReadyModels, tokenCount: 136),
        settings: TranscriptionSettings(
            engine: "whisperkit", whisperModel: "large-v3-v20240930_turbo", language: "fr",
            vocabulary: Array(infrastructureTerms.prefix(30))),
        act: { _ = await $0.setVocabulary(text: infrastructureTerms.joined(separator: "\n")) })
    try render(
        TranscriptionPane(model: refused, draft: infrastructureTerms.joined(separator: "\n")),
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
