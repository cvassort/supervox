import AppKit
import Combine
import SupervoxCore
import SwiftUI

/// Panneau des Réglages Système où l'utilisateur accorde une permission refusée.
public enum SystemSettingsPane: Sendable {
    case microphone, accessibility

    /// Adresses `x-apple.systempreferences:` des panneaux Confidentialité et sécurité.
    public var url: URL {
        switch self {
        case .microphone: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .accessibility: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

/// Les onglets de la fenêtre de réglages.
public enum SettingsTab: Hashable, Sendable {
    case providers, hotKey, permissions, transcription, modes, interview

    /// Le nom de l'onglet.
    public var title: String {
        switch self {
        case .providers: "Fournisseurs"
        case .hotKey: "Raccourci"
        case .permissions: "Permissions"
        case .transcription: "Transcription"
        case .modes: "Modes"
        case .interview: "Entretien"
        }
    }

    var systemImage: String {
        switch self {
        case .providers: "server.rack"
        case .hotKey: "keyboard"
        case .permissions: "lock.shield"
        case .transcription: "waveform"
        case .modes: "square.stack"
        case .interview: "person.wave.2"
        }
    }

    /// Les onglets montrés, dans l'ordre : Entretien vient après Modes, et n'existe que si son modèle est donné.
    static func visible(hasInterview: Bool) -> [SettingsTab] {
        [.providers, .hotKey, .permissions, .transcription, .modes] + (hasInterview ? [.interview] : [])
    }
}

/// Fenêtre de réglages : fournisseurs, raccourci, permissions, transcription, modes, entretien.
public struct SettingsView: View {
    let providers: ProvidersModel
    let hotKey: HotKeySettingsModel
    let transcription: TranscriptionModel
    let modes: ModesModel
    let permissions: PermissionsModel
    let openSystemSettings: @MainActor (SystemSettingsPane) -> Void
    /// `nil` : pas d'onglet Entretien (les appelants d'avant l'entretien).
    let interview: InterviewSettingsModel?
    /// L'onglet courant, partagé avec le contrôleur (`AppController.settingsNavigation`).
    let navigation: SettingsNavigation

    /// `initialTab` : l'onglet montré à l'ouverture (Fournisseurs par défaut), quand aucune `navigation` n'est donnée. `interview` :
    /// l'onglet Entretien n'apparaît que s'il est donné.
    public init(
        providers: ProvidersModel, hotKey: HotKeySettingsModel, transcription: TranscriptionModel, modes: ModesModel,
        permissions: PermissionsModel,
        openSystemSettings: @escaping @MainActor (SystemSettingsPane) -> Void, initialTab: SettingsTab = .providers,
        interview: InterviewSettingsModel? = nil, navigation: SettingsNavigation? = nil
    ) {
        self.providers = providers
        self.hotKey = hotKey
        self.transcription = transcription
        self.modes = modes
        self.permissions = permissions
        self.openSystemSettings = openSystemSettings
        self.interview = interview
        self.navigation = navigation ?? SettingsNavigation(tab: initialTab)
    }

    /// La vraie fenêtre, branchée sur le contrôleur : toutes ses écritures passent par
    /// `AppController.updateSettings`, qui tient la seule copie vivante des réglages.
    ///
    /// Sans catalogue de modèles locaux (`UnavailableModelCatalog`) : l'onglet Transcription règle le moteur, la langue
    /// et le vocabulaire, mais ne liste aucun modèle. Voir `provider(catalog:promptTokenLimit:)`.
    public static let provider: AppController.SettingsViewProvider = provider(
        catalog: UnavailableModelCatalog(), promptTokenLimit: 0)

    /// La vraie fenêtre avec un catalogue de modèles locaux. `promptTokenLimit` : le nombre de jetons d'amorce que le
    /// moteur Whisper garde (`WhisperKitTranscriber.promptTokenLimit`), au-delà duquel un vocabulaire est refusé.
    public static func provider(
        catalog: any ModelCatalog, promptTokenLimit: Int
    ) -> AppController.SettingsViewProvider {
        { controller in
            content(
                providers: makeProvidersModel(controller),
                hotKey: makeHotKeyModel(controller, keyMonitor: LocalKeyDownMonitor()),
                transcription: makeTranscriptionModel(controller, catalog: catalog, promptTokenLimit: promptTokenLimit),
                modes: makeModesModel(controller, keyMonitor: LocalKeyDownMonitor()),
                permissions: controller.permissions, openSystemSettings: { NSWorkspace.shared.open($0.url) },
                interview: makeInterviewModel(controller), navigation: controller.settingsNavigation)
        }
    }

    /// La fenêtre et ses deux moments : à chaque présentation, demander quelles clés existent et relire les modèles du
    /// disque ; quand l'utilisateur la quitte, mettre fin à une capture de raccourci (le raccourci global revient).
    static func content(
        providers: ProvidersModel, hotKey: HotKeySettingsModel, transcription: TranscriptionModel, modes: ModesModel,
        permissions: PermissionsModel, openSystemSettings: @escaping @MainActor (SystemSettingsPane) -> Void,
        interview: InterviewSettingsModel? = nil, navigation: SettingsNavigation = SettingsNavigation()
    ) -> SettingsContent {
        SettingsContent(
            view: AnyView(
                SettingsView(
                    providers: providers, hotKey: hotKey, transcription: transcription, modes: modes,
                    permissions: permissions, openSystemSettings: openSystemSettings, interview: interview,
                    navigation: navigation)),
            tabs: SettingsTab.visible(hasInterview: interview != nil),
            onPresent: {
                // La fenêtre gardée d'une ouverture à l'autre relit les réglages : un mode ou un fournisseur changé entre-temps
                // (le panneau, un autre onglet, le fichier) s'y voit. Avant les attentes ci-dessous : la fenêtre ne s'affiche pas
                // un instant avec l'ancien état.
                modes.reload()
                modes.clearMessage()
                interview?.reload()
                interview?.clearMessage()
                await providers.checkKeys()
                await transcription.refresh()
            },
            onLeave: {
                hotKey.cancelRecording()
                modes.cancelRecording()
                // Fenêtre fermée ou quittée, ou fin de l'application : le gabarit tapé est enregistré.
                interview?.commitTemplate()
            })
    }

    /// Les réglages de transcription s'enregistrent par `AppController.updateSettings`, comme tous les autres.
    static func makeTranscriptionModel(
        _ controller: AppController, catalog: any ModelCatalog, promptTokenLimit: Int
    ) -> TranscriptionModel {
        TranscriptionModel(
            settings: controller.settings.transcription, catalog: catalog, promptTokenLimit: promptTokenLimit,
            isDictating: { [weak controller] in controller?.dictation.isBusy ?? false },
            save: { [weak controller] transcription in
                try controller?.updateSettings { $0.transcription = transcription }
            })
    }

    /// L'onglet Modes lit les réglages en vigueur à chaque geste et les écrit par `AppController.updateSettings`, comme tous les
    /// autres : il ne garde aucune copie des modes à réécrire. Les raccourcis des modes passent par le contrôleur, qui les prend
    /// auprès du système.
    static func makeModesModel(_ controller: AppController, keyMonitor: any KeyEventMonitor) -> ModesModel {
        ModesModel(
            read: { [weak controller] in controller?.settings ?? .defaults },
            update: { [weak controller] change in try controller?.updateSettings(change) },
            hotKeys: ModeHotKeyControl(
                apply: { [weak controller] in controller?.changeModeHotKey($0, for: $1) ?? .failure(.refused) },
                suspend: { [weak controller] in controller?.suspendHotKeysForCapture() },
                resume: { [weak controller] in controller?.resumeHotKeys() ?? false },
                global: { [weak controller] in controller?.settings.hotKey }),
            layout: controller.keyboardLayout, systemHotKeys: controller.systemHotKeys, keyMonitor: keyMonitor)
    }

    /// L'onglet Entretien lit les réglages en vigueur à chaque geste et les écrit par `AppController.updateSettings`, comme les
    /// autres ; le silence en pratique vient de l'environnement de l'entretien du contrôleur (la formule du détecteur de voix réel).
    static func makeInterviewModel(_ controller: AppController) -> InterviewSettingsModel {
        InterviewSettingsModel(
            read: { [weak controller] in controller?.settings ?? .defaults },
            update: { [weak controller] change in try controller?.updateSettings(change) },
            effectiveTurnSilence: controller.interviewEnvironment.effectiveTurnSilence)
    }

    /// Construit sans appeler le magasin de secrets.
    static func makeProvidersModel(_ controller: AppController) -> ProvidersModel {
        ProvidersModel(
            providers: controller.settings.providers, secrets: controller.secrets,
            listModels: ProvidersModel.live,
            save: { [weak controller] providers in try controller?.updateSettings { $0.providers = providers } })
    }

    /// La disposition de clavier est celle du contrôleur : la fenêtre et le panneau nomment les touches de la même façon.
    static func makeHotKeyModel(_ controller: AppController, keyMonitor: any KeyEventMonitor) -> HotKeySettingsModel {
        HotKeySettingsModel(
            hotKey: controller.settings.hotKey, active: controller.hotKeys.active,
            behavior: controller.settings.hotKeyBehavior, layout: controller.keyboardLayout,
            systemHotKeys: controller.systemHotKeys,
            keyMonitor: keyMonitor,
            control: GlobalHotKeyControl(
                apply: { [weak controller] in controller?.changeHotKey($0) ?? .failure(.refused) },
                suspend: { [weak controller] in controller?.suspendHotKeysForCapture() },
                resume: { [weak controller] in controller?.resumeHotKeys() ?? false },
                clear: { [weak controller] in controller?.clearHotKey() },
                taken: { [weak controller] in controller?.modeHolding($0) }),
            save: { [weak controller] hotKey, behavior in
                try controller?.updateSettings {
                    $0.hotKey = hotKey
                    $0.hotKeyBehavior = behavior
                }
            })
    }

    public var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            ForEach(SettingsTab.visible(hasInterview: interview != nil), id: \.self) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) { pane(for: tab) }
            }
        }
        // Une capture ne survit pas à un changement d'onglet (en plus de `onDisappear` de l'onglet Raccourci).
        .onChange(of: navigation.tab) {
            hotKey.cancelRecording()
            modes.cancelRecording()
            // Un autre onglet : le gabarit tapé dans celui-ci est enregistré.
            interview?.commitTemplate()
        }
        .frame(width: 600, height: 460)
    }

    @ViewBuilder
    private func pane(for tab: SettingsTab) -> some View {
        switch tab {
        case .providers: ProvidersPane(model: providers)
        case .hotKey: HotKeyPane(model: hotKey)
        case .permissions: PermissionsPane(model: permissions, openSystemSettings: openSystemSettings)
        case .transcription: TranscriptionPane(model: transcription)
        case .modes: ModesPane(model: modes)
        case .interview:
            if let interview { InterviewPane(model: interview) }
        }
    }
}

// MARK: - Fournisseurs

/// Fournisseur en cours de saisie dans la feuille d'édition ; `existing` est `nil` pour un ajout.
private struct ProviderDraft: Identifiable {
    let id = UUID()
    var existing: Provider?
}

private func kindLabel(_ kind: ProviderKind) -> String {
    switch kind {
    case .openAICompatible: "Compatible OpenAI"
    case .anthropic: "Anthropic"
    }
}

private func keyLabel(_ state: KeyState) -> String {
    switch state {
    case .present: "Enregistrée"
    case .absent: "Aucune"
    case .unknown: "État inconnu"
    }
}

private struct ProvidersPane: View {
    let model: ProvidersModel
    @State private var draft: ProviderDraft?
    @State private var removal: Provider?
    @State private var failure: String?

    var body: some View {
        Form {
            if model.providers.isEmpty {
                Text("Aucun fournisseur. Ajoutez-en un pour lister ses modèles.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.providers) { provider in
                Section {
                    LabeledContent("Adresse", value: provider.baseURL)
                    LabeledContent("Type", value: kindLabel(provider.kind))
                    LabeledContent("Clé", value: keyLabel(model.keyState(provider.id)))
                    ModelsRow(model: model, provider: provider)
                } header: {
                    HStack {
                        Text(provider.name)
                        Spacer()
                        Button("Modifier…") { draft = ProviderDraft(existing: provider) }
                        Button("Supprimer…", role: .destructive) { removal = provider }
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        // Présence des clés demandée (sans les lire) quand la liste s'affiche.
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Ajouter un fournisseur…") { draft = ProviderDraft(existing: nil) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
        .sheet(item: $draft) { draft in
            ProviderEditor(model: model, existing: draft.existing)
        }
        .confirmationDialog(
            "Supprimer « \(removal?.name ?? "") » et sa clé ?",
            isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            presenting: removal
        ) { provider in
            Button("Supprimer", role: .destructive) {
                Task {
                    do { try await model.remove(provider.id) } catch { failure = ProvidersModel.message(for: error) }
                }
            }
        }
        .alert(
            "Suppression incomplète",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK") { failure = nil }
        } message: {
            Text(failure ?? "")
        }
    }
}

/// État de la liste des modèles d'un fournisseur, bouton de lecture, liste repliable filtrée et paresseuse.
private struct ModelsRow: View {
    let model: ProvidersModel
    let provider: Provider
    @State private var query = ""

    /// Au-delà, un champ de filtre apparaît.
    private static let filterThreshold = 20

    var body: some View {
        let status = model.status(of: provider.id)
        HStack(alignment: .firstTextBaseline) {
            switch status {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .ok:
                Label(ProvidersModel.modelCountLabel(provider.models.count) + ", liste à jour", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .idle:
                Text(ProvidersModel.modelCountLabel(provider.models.count))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Lister les modèles") { Task { await model.refreshModels(provider.id) } }
                .disabled(status == .loading)
        }
        if !provider.models.isEmpty {
            DisclosureGroup("Modèles") {
                if provider.models.count > Self.filterThreshold {
                    TextField("Filtrer", text: $query)
                        .textFieldStyle(.roundedBorder)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(ProvidersModel.filter(provider.models, query: query), id: \.self) { id in
                            Text(id)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
            }
        }
    }
}

/// Feuille d'ajout ou de modification. Le champ de clé est vide à l'ouverture : la clé n'est jamais
/// relue pour être affichée.
public struct ProviderEditor: View {
    let model: ProvidersModel
    let existing: Provider?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var baseURL: String
    @State private var kind: ProviderKind
    @State private var key = ""
    @State private var failure: String?
    @State private var isSaving = false

    /// `existing` : `nil` pour un ajout. `initialFailure` : un message d'erreur déjà affiché (rendu des écrans).
    public init(model: ProvidersModel, existing: Provider?, initialFailure: String? = nil) {
        self.model = model
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _baseURL = State(initialValue: existing?.baseURL ?? "https://")
        _kind = State(initialValue: existing?.kind ?? .openAICompatible)
        _failure = State(initialValue: initialFailure)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Nom", text: $name)
                TextField("Adresse", text: $baseURL)
                Picker("Type", selection: $kind) {
                    Text(kindLabel(.openAICompatible)).tag(ProviderKind.openAICompatible)
                    Text(kindLabel(.anthropic)).tag(ProviderKind.anthropic)
                }
                Section {
                    SecureField("Clé d'API", text: $key)
                } footer: {
                    if let keyNote {
                        Text(keyNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let failure {
                    Text(failure)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button(existing == nil ? "Ajouter" : "Enregistrer") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .frame(minHeight: 360)
        // Une erreur arrivée après fermeture serait perdue : la feuille reste ouverte pendant l'enregistrement.
        .interactiveDismissDisabled(isSaving)
    }

    /// Ce qu'on sait de la clé enregistrée, sans la lire.
    private var keyNote: String? {
        guard let existing else { return nil }
        let newOrigin = !ProvidersModel.sameOrigin(existing.baseURL, baseURL)
        return ProvidersModel.keyNote(for: model.keyState(existing.id), newOrigin: newOrigin)
    }

    private func submit() {
        isSaving = true
        failure = nil
        Task {
            defer { isSaving = false }
            do {
                if var provider = existing {
                    provider.name = name
                    provider.baseURL = baseURL
                    provider.kind = kind
                    try await model.update(provider, newKey: key)
                } else {
                    try await model.add(name: name, baseURL: baseURL, kind: kind, key: key)
                }
                dismiss()
            } catch {
                failure = ProvidersModel.message(for: error)
            }
        }
    }
}

// MARK: - Raccourci

private struct HotKeyPane: View {
    let model: HotKeySettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Raccourci") { HotKeyRecorder(model: model) }
                if let message = model.message {
                    Text(message)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(HotKeySettingsModel.conflictHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker(
                    "Touche",
                    selection: Binding(get: { model.behavior }, set: { model.setBehavior($0) })
                ) {
                    ForEach(HotKeySettingsModel.behaviorOptions, id: \.behavior) { option in
                        Text(option.label).tag(option.behavior).disabled(!option.isEnabled)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .onDisappear { model.cancelRecording() }
    }
}

/// Bouton qui capte la prochaine combinaison tapée. Toute la logique, moniteur de touches compris, est dans
/// `HotKeySettingsModel`.
private struct HotKeyRecorder: View {
    let model: HotKeySettingsModel

    var body: some View {
        Button {
            model.isRecording ? model.cancelRecording() : model.startRecording()
        } label: {
            Text(model.isRecording ? "Tapez la combinaison…" : model.label)
                .font(model.isRecording ? .body : .body.monospaced())
                .frame(minWidth: 160)
        }
        .help(model.isRecording ? "Échap pour annuler" : "Cliquer pour changer")
    }
}

// MARK: - Permissions

/// Une ligne de l'onglet Permissions. `openSystemSettings` n'existe que pour une permission refusée, et
/// ouvre le panneau des Réglages Système de cette permission.
struct PermissionRow {
    let title: String
    let state: PermissionState
    let openSystemSettings: (@MainActor () -> Void)?

    @MainActor
    static func rows(
        for model: PermissionsModel, open: @escaping @MainActor (SystemSettingsPane) -> Void
    ) -> [PermissionRow] {
        func row(_ title: String, _ state: PermissionState, _ pane: SystemSettingsPane) -> PermissionRow {
            var action: (@MainActor () -> Void)?
            if state == .denied { action = { open(pane) } }
            return PermissionRow(title: title, state: state, openSystemSettings: action)
        }
        return [
            row("Micro", model.microphone, .microphone),
            row("Accessibilité", model.accessibility, .accessibility),
        ]
    }
}

private struct PermissionsPane: View {
    let model: PermissionsModel
    let openSystemSettings: @MainActor (SystemSettingsPane) -> Void

    var body: some View {
        Form {
            Section {
                ForEach(PermissionRow.rows(for: model, open: openSystemSettings), id: \.title) { row in
                    LabeledContent(row.title) {
                        HStack(spacing: 8) {
                            stateLabel(row.state)
                            if let open = row.openSystemSettings {
                                Button("Ouvrir les réglages du système", action: open)
                            }
                        }
                    }
                }
            }
            if model.canRequest {
                Section {
                    HStack {
                        Spacer()
                        Button("Autoriser…") { Task { await model.requestNext() } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refresh() }
        // Au retour des Réglages Système, l'onglet déjà affiché ne réapparaît pas : on relit à l'activation.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }

    /// La couleur porte sur l'icône seule : un texte vert clair sur fond clair se lit mal.
    @ViewBuilder
    private func stateLabel(_ state: PermissionState) -> some View {
        switch state {
        case .granted: stateLabel("Autorisé", "checkmark.circle.fill", .green)
        case .notDetermined: stateLabel("Pas encore demandé", "questionmark.circle", .secondary)
        case .denied: stateLabel("Non autorisé", "xmark.circle.fill", .red)
        }
    }

    private func stateLabel(_ title: String, _ symbol: String, _ tint: some ShapeStyle) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
    }
}
