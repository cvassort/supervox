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

/// Fenêtre de réglages : fournisseurs, raccourci, permissions.
public struct SettingsView: View {
    let providers: ProvidersModel
    let hotKey: HotKeySettingsModel
    let permissions: PermissionsModel
    let openSystemSettings: @MainActor (SystemSettingsPane) -> Void

    public init(
        providers: ProvidersModel, hotKey: HotKeySettingsModel, permissions: PermissionsModel,
        openSystemSettings: @escaping @MainActor (SystemSettingsPane) -> Void
    ) {
        self.providers = providers
        self.hotKey = hotKey
        self.permissions = permissions
        self.openSystemSettings = openSystemSettings
    }

    /// La vraie fenêtre, branchée sur le contrôleur : toutes ses écritures passent par
    /// `AppController.updateSettings`, qui tient la seule copie vivante des réglages.
    public static let provider: AppController.SettingsViewProvider = { controller in
        AnyView(
            SettingsView(
                providers: makeProvidersModel(controller), hotKey: makeHotKeyModel(controller),
                permissions: controller.permissions,
                openSystemSettings: { NSWorkspace.shared.open($0.url) }))
    }

    /// Construit sans lire aucune clé.
    static func makeProvidersModel(_ controller: AppController) -> ProvidersModel {
        ProvidersModel(
            providers: controller.settings.providers, secrets: controller.secrets,
            listModels: ProvidersModel.live,
            save: { [weak controller] providers in try controller?.updateSettings { $0.providers = providers } })
    }

    static func makeHotKeyModel(_ controller: AppController, layout: any KeyboardLayout = SystemKeyboardLayout())
        -> HotKeySettingsModel
    {
        HotKeySettingsModel(
            hotKey: controller.settings.hotKey, active: controller.hotKeys.active,
            behavior: controller.settings.hotKeyBehavior, layout: layout,
            apply: { [weak controller] in controller?.changeHotKey($0) ?? .failure(.taken) },
            save: { [weak controller] hotKey, behavior in
                try controller?.updateSettings {
                    $0.hotKey = hotKey
                    $0.hotKeyBehavior = behavior
                }
            })
    }

    public var body: some View {
        TabView {
            Tab("Fournisseurs", systemImage: "server.rack") { ProvidersPane(model: providers) }
            Tab("Raccourci", systemImage: "keyboard") { HotKeyPane(model: hotKey) }
            Tab("Permissions", systemImage: "lock.shield") {
                PermissionsPane(model: permissions, openSystemSettings: openSystemSettings)
            }
        }
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

private struct ProvidersPane: View {
    let model: ProvidersModel
    @State private var draft: ProviderDraft?
    @State private var removal: Provider?
    @State private var failure: String?

    var body: some View {
        Form {
            if model.providers.isEmpty {
                Text("Aucun fournisseur.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.providers) { provider in
                Section {
                    LabeledContent("Adresse", value: provider.baseURL)
                    LabeledContent("Type", value: kindLabel(provider.kind))
                    modelsRow(provider)
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
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("Ajouter un fournisseur…") { draft = ProviderDraft(existing: nil) }
            }
            .padding([.horizontal, .bottom], 20)
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
            failure ?? "",
            isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
        ) {
            Button("OK") { failure = nil }
        }
    }

    @ViewBuilder
    private func modelsRow(_ provider: Provider) -> some View {
        let status = model.status(of: provider.id)
        HStack(alignment: .firstTextBaseline) {
            switch status {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let message):
                Text(message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle, .ok:
                Text(provider.models.isEmpty ? "Aucun modèle listé" : "\(provider.models.count) modèle(s)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Lister les modèles") { Task { await model.refreshModels(provider.id) } }
                .disabled(status == .loading)
        }
        if !provider.models.isEmpty {
            DisclosureGroup("Modèles") {
                ForEach(provider.models, id: \.self) { id in
                    Text(id)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Feuille d'ajout ou de modification. Le champ de clé est vide à l'ouverture : la clé n'est jamais
/// relue pour être affichée.
private struct ProviderEditor: View {
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
                Spacer()
                Button("Annuler", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(existing == nil ? "Ajouter" : "Enregistrer") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
    }

    /// Ce qu'on sait de la clé enregistrée, sans la lire.
    private var keyNote: String? {
        guard let existing else { return nil }
        switch model.keyState(existing.id) {
        case .present: return "Une clé est enregistrée. Laissez vide pour la garder."
        case .absent: return "Aucune clé enregistrée."
        case .unknown: return "Laissez vide pour ne pas changer la clé."
        }
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
            }
            Section {
                Picker(
                    "Touche",
                    selection: Binding(get: { model.behavior }, set: { model.setBehavior($0) })
                ) {
                    Text("Appuyer pour ouvrir ou fermer le panneau").tag(HotKeyBehavior.toggle)
                    Text("Maintenir pour dicter (à venir)").tag(HotKeyBehavior.hold)
                        .disabled(!HotKeySettingsModel.isAvailable(.hold))
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .onDisappear { model.cancelRecording() }
    }
}

/// Bouton qui capte la prochaine combinaison tapée. La logique est dans `HotKeySettingsModel` ; ici,
/// seulement le moniteur d'événements local, posé pendant la capture.
private struct HotKeyRecorder: View {
    let model: HotKeySettingsModel
    @State private var monitor = KeyDownMonitor()

    var body: some View {
        Button {
            model.isRecording ? model.cancelRecording() : model.startRecording()
        } label: {
            Text(model.isRecording ? "Tapez la combinaison…" : model.label)
                .font(model.isRecording ? .body : .body.monospaced())
                .frame(minWidth: 160)
        }
        .help(model.isRecording ? "Échap pour annuler" : "Cliquer pour changer")
        .onChange(of: model.isRecording) { _, recording in
            if recording {
                monitor.start { model.keyDown(keyCode: $0.keyCode, flags: $0.modifierFlags) }
            } else {
                monitor.stop()
            }
        }
        .onDisappear { monitor.stop() }
    }
}

/// Moniteur local des touches pressées : chaque touche est donnée à `handler` et n'atteint pas la fenêtre.
@MainActor
private final class KeyDownMonitor {
    private var token: Any?

    func start(_ handler: @escaping @MainActor (NSEvent) -> Void) {
        stop()
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handler(event) }
            return nil
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    let model: PermissionsModel
    let openSystemSettings: @MainActor (SystemSettingsPane) -> Void

    var body: some View {
        Form {
            Section {
                row("Micro", state: model.microphone, pane: .microphone)
                row("Accessibilité", state: model.accessibility, pane: .accessibility)
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

    private func row(_ title: String, state: PermissionState, pane: SystemSettingsPane) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                switch state {
                case .granted:
                    Label("Autorisé", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .notDetermined:
                    Label("Pas encore demandé", systemImage: "questionmark.circle").foregroundStyle(.secondary)
                case .denied:
                    Label("Non autorisé", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    Button("Ouvrir les réglages du système") { openSystemSettings(pane) }
                }
            }
        }
    }
}
