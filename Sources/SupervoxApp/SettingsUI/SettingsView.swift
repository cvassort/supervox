import AppKit
import Combine
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
    case providers, hotKey, permissions
}

/// Fenêtre de réglages : fournisseurs, raccourci, permissions.
public struct SettingsView: View {
    let providers: ProvidersModel
    let hotKey: HotKeySettingsModel
    let permissions: PermissionsModel
    let openSystemSettings: @MainActor (SystemSettingsPane) -> Void
    @State private var tab: SettingsTab

    /// `initialTab` : l'onglet montré à l'ouverture (Fournisseurs par défaut).
    public init(
        providers: ProvidersModel, hotKey: HotKeySettingsModel, permissions: PermissionsModel,
        openSystemSettings: @escaping @MainActor (SystemSettingsPane) -> Void, initialTab: SettingsTab = .providers
    ) {
        self.providers = providers
        self.hotKey = hotKey
        self.permissions = permissions
        self.openSystemSettings = openSystemSettings
        _tab = State(initialValue: initialTab)
    }

    /// La vraie fenêtre, branchée sur le contrôleur : toutes ses écritures passent par
    /// `AppController.updateSettings`, qui tient la seule copie vivante des réglages.
    public static let provider: AppController.SettingsViewProvider = { controller in
        content(
            providers: makeProvidersModel(controller),
            hotKey: makeHotKeyModel(controller, layout: SystemKeyboardLayout(), keyMonitor: LocalKeyDownMonitor()),
            permissions: controller.permissions, openSystemSettings: { NSWorkspace.shared.open($0.url) })
    }

    /// La fenêtre et ses deux moments : à chaque présentation, demander quelles clés existent ; quand l'utilisateur la
    /// quitte, mettre fin à une capture de raccourci (le raccourci global revient).
    static func content(
        providers: ProvidersModel, hotKey: HotKeySettingsModel, permissions: PermissionsModel,
        openSystemSettings: @escaping @MainActor (SystemSettingsPane) -> Void
    ) -> SettingsContent {
        SettingsContent(
            view: AnyView(
                SettingsView(
                    providers: providers, hotKey: hotKey, permissions: permissions,
                    openSystemSettings: openSystemSettings)),
            onPresent: { await providers.checkKeys() }, onLeave: { hotKey.cancelRecording() })
    }

    /// Construit sans appeler le magasin de secrets.
    static func makeProvidersModel(_ controller: AppController) -> ProvidersModel {
        ProvidersModel(
            providers: controller.settings.providers, secrets: controller.secrets,
            listModels: ProvidersModel.live,
            save: { [weak controller] providers in try controller?.updateSettings { $0.providers = providers } })
    }

    static func makeHotKeyModel(
        _ controller: AppController, layout: any KeyboardLayout, keyMonitor: any KeyEventMonitor
    ) -> HotKeySettingsModel {
        HotKeySettingsModel(
            hotKey: controller.settings.hotKey, active: controller.hotKeys.active,
            behavior: controller.settings.hotKeyBehavior, layout: layout, systemHotKeys: controller.systemHotKeys,
            keyMonitor: keyMonitor,
            control: GlobalHotKeyControl(
                apply: { [weak controller] in controller?.changeHotKey($0) ?? .failure(.refused) },
                suspend: { [weak controller] in controller?.suspendHotKeysForCapture() },
                resume: { [weak controller] in controller?.resumeHotKeys() ?? false },
                clear: { [weak controller] in controller?.clearHotKey() }),
            save: { [weak controller] hotKey, behavior in
                try controller?.updateSettings {
                    $0.hotKey = hotKey
                    $0.hotKeyBehavior = behavior
                }
            })
    }

    public var body: some View {
        TabView(selection: $tab) {
            Tab("Fournisseurs", systemImage: "server.rack", value: .providers) { ProvidersPane(model: providers) }
            Tab("Raccourci", systemImage: "keyboard", value: .hotKey) { HotKeyPane(model: hotKey) }
            Tab("Permissions", systemImage: "lock.shield", value: .permissions) {
                PermissionsPane(model: permissions, openSystemSettings: openSystemSettings)
            }
        }
        // Une capture ne survit pas à un changement d'onglet (en plus de `onDisappear` de l'onglet Raccourci).
        .onChange(of: tab) { hotKey.cancelRecording() }
        .frame(width: 600, height: 460)
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
struct ProviderEditor: View {
    let model: ProvidersModel
    let existing: Provider?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var baseURL: String
    @State private var kind: ProviderKind
    @State private var key = ""
    @State private var failure: String?
    @State private var isSaving = false

    init(model: ProvidersModel, existing: Provider?) {
        self.model = model
        self.existing = existing
        _name = State(initialValue: existing?.name ?? "")
        _baseURL = State(initialValue: existing?.baseURL ?? "https://")
        _kind = State(initialValue: existing?.kind ?? .openAICompatible)
    }

    var body: some View {
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

    @ViewBuilder
    private func stateLabel(_ state: PermissionState) -> some View {
        switch state {
        case .granted:
            Label("Autorisé", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .notDetermined:
            Label("Pas encore demandé", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        case .denied:
            Label("Non autorisé", systemImage: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}
