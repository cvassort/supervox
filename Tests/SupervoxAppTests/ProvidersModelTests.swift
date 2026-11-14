import Foundation
import Synchronization
import SupervoxCore
import Testing

@testable import SupervoxApp

/// Magasin double : délègue à un magasin en mémoire, note pour chaque appel s'il a eu lieu sur le
/// fil principal, et peut faire échouer `delete` seul.
final class RecordingSecretStore: SecretStore {
    struct Call {
        var name: String
        var account: String
        var onMainThread: Bool
        /// Libellé de la file d'exécution de l'appel (`""` hors d'une file nommée).
        var queueLabel: String
    }

    struct State {
        var calls: [Call] = []
        var deleteFailure: SecretError?
        var writeFailure: SecretError?
    }

    let inner: InMemorySecretStore
    private let state = Mutex(State())

    init(secrets: [String: String] = [:]) {
        inner = InMemorySecretStore(secrets: secrets)
    }

    /// Lectures faites par l'application (celles de `peek` ne comptent pas).
    var readCount: Int { calls.filter { $0.name == "read" }.count }
    var calls: [Call] { state.withLock { $0.calls } }
    var deleteFailure: SecretError? {
        get { state.withLock { $0.deleteFailure } }
        set { state.withLock { $0.deleteFailure = newValue } }
    }
    var writeFailure: SecretError? {
        get { state.withLock { $0.writeFailure } }
        set { state.withLock { $0.writeFailure = newValue } }
    }

    /// Valeur actuelle, lue sans compter comme une lecture de l'application.
    func peek(_ account: String) -> String? {
        (try? inner.read(account: account)) ?? nil
    }

    private func note(_ name: String, _ account: String) {
        let call = Call(
            name: name, account: account, onMainThread: Thread.isMainThread,
            queueLabel: String(cString: __dispatch_queue_get_label(nil)))
        state.withLock { $0.calls.append(call) }
    }

    func read(account: String) throws -> String? {
        note("read", account)
        return try inner.read(account: account)
    }

    func write(_ secret: String, account: String) throws {
        note("write", account)
        if let failure = writeFailure { throw failure }
        try inner.write(secret, account: account)
    }

    func contains(account: String) throws -> Bool {
        note("contains", account)
        return try inner.contains(account: account)
    }

    func delete(account: String) throws {
        note("delete", account)
        if let failure = deleteFailure { throw failure }
        try inner.delete(account: account)
    }
}

/// Enregistrement double : garde chaque liste enregistrée ; lève `failure` si elle est définie.
@MainActor final class ProvidersSaver {
    var saved: [[Provider]] = []
    var failure: (any Error)?

    func save(_ providers: [Provider]) throws {
        if let failure { throw failure }
        saved.append(providers)
    }
}

/// Liste de modèles double : rend `result`, note les appels (fournisseur et clé reçus).
final class FakeLister: Sendable {
    private struct State {
        var result: Result<[String], any Error> = .success([])
        var calls: [(Provider, String)] = []
    }

    private let state = Mutex(State())

    func set(_ result: Result<[String], any Error>) { state.withLock { $0.result = result } }
    var calls: [(Provider, String)] { state.withLock { $0.calls } }

    func list(_ provider: Provider, _ key: String) async throws -> [String] {
        try state.withLock { state in
            state.calls.append((provider, key))
            return try state.result.get()
        }
    }
}

/// Barrière : `wait` reste suspendu jusqu'à `open` ; une fois ouverte, elle ne retient plus personne.
final class Gate: Sendable {
    private struct State {
        var waiting: [CheckedContinuation<Void, Never>] = []
        var isOpen = false
        var calls = 0
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let passThrough = state.withLock { state in
                state.calls += 1
                if !state.isOpen { state.waiting.append(continuation) }
                return state.isOpen
            }
            if passThrough { continuation.resume() }
        }
    }

    var isWaiting: Bool { state.withLock { !$0.waiting.isEmpty } }
    var isOpen: Bool { state.withLock { $0.isOpen } }
    var calls: Int { state.withLock { $0.calls } }

    func open() {
        let waiting = state.withLock { state in
            state.isOpen = true
            defer { state.waiting = [] }
            return state.waiting
        }
        waiting.forEach { $0.resume() }
    }
}

struct SaveFailure: Error, LocalizedError {
    var errorDescription: String? { "disque plein" }
}

@MainActor @Suite struct ProvidersModelTests {
    let secrets: RecordingSecretStore
    let saver = ProvidersSaver()
    let lister = FakeLister()

    init() {
        secrets = RecordingSecretStore()
    }

    static let existing = Provider(
        id: UUID(), name: "Serveur local", baseURL: "http://localhost:8080", kind: .openAICompatible,
        models: ["model-a"])

    func makeModel(providers: [Provider] = [], secrets: RecordingSecretStore? = nil) -> ProvidersModel {
        let saver = saver
        let lister = lister
        return ProvidersModel(
            providers: providers, secrets: secrets ?? self.secrets,
            listModels: { try await lister.list($0, $1) },
            save: { try saver.save($0) })
    }

    // MARK: - Ajout et suppression

    @Test func addingAProviderStoresTheKeyInSecretsNotInSettings() async throws {
        let model = makeModel()
        try await model.add(name: "Distant", baseURL: "https://models.invalid/v1", kind: .anthropic, key: "sk-secret-1")

        let provider = try #require(model.providers.first)
        #expect(model.providers.count == 1)
        #expect(provider.name == "Distant")
        #expect(provider.baseURL == "https://models.invalid/v1")
        #expect(provider.kind == .anthropic)
        #expect(secrets.peek(provider.id.uuidString) == "sk-secret-1")
        // Ce qui part vers le fichier de réglages ne contient pas la clé.
        let saved = try #require(saver.saved.last)
        #expect(saved == model.providers)
        let json = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(!json.contains("sk-secret-1"))
        #expect(model.keyState(provider.id) == .present)
        #expect(secrets.calls.map(\.name) == ["write"])
        #expect(secrets.calls.allSatisfy { !$0.onMainThread })
    }

    @Test func keyIsTrimmedBeforeBeingStored() async throws {
        let model = makeModel()
        try await model.add(name: "Distant", baseURL: "https://models.invalid", kind: .anthropic, key: "  sk-2\n")
        let provider = try #require(model.providers.first)
        #expect(secrets.peek(provider.id.uuidString) == "sk-2")
    }

    @Test func emptyKeyIsRefusedOnCreationForAKindThatNeedsOne() async throws {
        let model = makeModel()
        let error = await #expect(throws: ProvidersError.self) {
            try await model.add(name: "Distant", baseURL: "https://models.invalid", kind: .anthropic, key: "  ")
        }
        #expect(error == .keyRequired)
        #expect(error?.errorDescription?.contains("clé") == true)
        #expect(model.providers.isEmpty)
        #expect(saver.saved.isEmpty)
        #expect(secrets.calls.isEmpty)
    }

    @Test func keylessOpenAICompatibleProviderIsAddedWithoutWritingAnyKey() async throws {
        let model = makeModel()
        try await model.add(name: "Local", baseURL: "http://127.0.0.1:9000", kind: .openAICompatible, key: "")
        let provider = try #require(model.providers.first)
        #expect(saver.saved.last == model.providers)
        #expect(secrets.calls.isEmpty)
        #expect(model.keyState(provider.id) == .absent)
    }

    @Test func emptyNameIsRefused() async throws {
        let model = makeModel()
        await #expect(throws: ProvidersError.emptyName) {
            try await model.add(name: " ", baseURL: "https://models.invalid", kind: .anthropic, key: "sk")
        }
        #expect(model.providers.isEmpty)
        #expect(secrets.calls.isEmpty)
    }

    @Test func removingAProviderDeletesItsKey() async throws {
        let other = Provider(id: UUID(), name: "Autre", baseURL: "https://other.invalid", kind: .anthropic, models: [])
        let store = RecordingSecretStore(secrets: [
            Self.existing.id.uuidString: "sk-local", other.id.uuidString: "sk-other",
        ])
        let model = makeModel(providers: [Self.existing, other], secrets: store)

        try await model.remove(Self.existing.id)

        #expect(model.providers == [other])
        #expect(saver.saved.last == [other])
        #expect(store.peek(Self.existing.id.uuidString) == nil)
        #expect(store.peek(other.id.uuidString) == "sk-other")
    }

    @Test func failedSaveOnRemoveKeepsTheProviderAndItsKey() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing], secrets: store)
        saver.failure = SaveFailure()

        await #expect(throws: SaveFailure.self) { try await model.remove(Self.existing.id) }
        #expect(model.providers == [Self.existing])
        #expect(store.peek(Self.existing.id.uuidString) == "sk-local")
        #expect(!store.calls.contains { $0.name == "delete" })
    }

    @Test func keyThatCannotBeDeletedIsReportedAfterTheProviderIsRemoved() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        store.deleteFailure = .denied
        let model = makeModel(providers: [Self.existing], secrets: store)

        let error = await #expect(throws: ProvidersError.self) { try await model.remove(Self.existing.id) }
        #expect(model.providers.isEmpty)
        #expect(saver.saved.last == [])
        guard case .keyNotDeleted = error else {
            Issue.record("erreur inattendue : \(String(describing: error))")
            return
        }
    }

    @Test func failedSaveSurfacesAnErrorAndLeavesSecretsConsistent() async throws {
        let model = makeModel()
        saver.failure = SaveFailure()

        await #expect(throws: SaveFailure.self) {
            try await model.add(name: "Distant", baseURL: "https://models.invalid", kind: .anthropic, key: "sk-orphan")
        }
        #expect(model.providers.isEmpty)
        // La clé écrite juste avant l'enregistrement a été retirée, sur le même compte.
        #expect(secrets.calls.map(\.name) == ["write", "delete"])
        let account = try #require(secrets.calls.first?.account)
        #expect(secrets.calls.last?.account == account)
        #expect(secrets.peek(account) == nil)
        #expect(secrets.calls.allSatisfy { !$0.onMainThread })
    }

    @Test func unreadableSettingsFileIsNamedInTheMessage() async throws {
        let model = makeModel()
        saver.failure = SettingsError.unreadableFileKept(fileName: "settings.json")
        do {
            try await model.add(name: "Distant", baseURL: "https://models.invalid", kind: .anthropic, key: "sk")
            Issue.record("add aurait dû lever")
        } catch {
            #expect(ProvidersModel.message(for: error).contains("settings.json"))
        }
    }

    // MARK: - Modification

    @Test func emptyKeyOnUpdateKeepsTheStoredKey() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing], secrets: store)
        var renamed = Self.existing
        renamed.name = "Renommé"

        try await model.update(renamed, newKey: "")

        #expect(model.providers == [renamed])
        #expect(saver.saved.last == [renamed])
        #expect(store.peek(Self.existing.id.uuidString) == "sk-local")
        #expect(!store.calls.contains { $0.name == "write" || $0.name == "delete" })
    }

    @Test func newKeyOnUpdateReplacesTheStoredKey() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing], secrets: store)

        try await model.update(Self.existing, newKey: "sk-new")

        #expect(store.peek(Self.existing.id.uuidString) == "sk-new")
        #expect(model.keyState(Self.existing.id) == .present)
    }

    @Test func keyThatCannotBeWrittenOnUpdateIsReportedAfterTheSettingsAreSaved() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing], secrets: store)
        store.inner.failure = .denied
        var renamed = Self.existing
        renamed.name = "Renommé"

        let error = await #expect(throws: ProvidersError.self) { try await model.update(renamed, newKey: "sk-new") }
        guard case .keyNotSaved = error else {
            Issue.record("erreur inattendue : \(String(describing: error))")
            return
        }
        #expect(model.providers == [renamed])
        #expect(saver.saved.last == [renamed])
        #expect(model.keyState(Self.existing.id) == .unknown)
    }

    @Test func failedSaveOnUpdateChangesNeitherTheProviderNorTheKey() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing], secrets: store)
        saver.failure = SaveFailure()
        var renamed = Self.existing
        renamed.name = "Renommé"

        await #expect(throws: SaveFailure.self) { try await model.update(renamed, newKey: "sk-new") }
        #expect(model.providers == [Self.existing])
        #expect(store.peek(Self.existing.id.uuidString) == "sk-local")
    }

    @Test func changingTheAddressOrTheKindDropsTheModelList() async throws {
        let model = makeModel(providers: [Self.existing])
        var moved = Self.existing
        moved.baseURL = "http://localhost:9090"
        try await model.update(moved, newKey: nil)
        #expect(model.providers.first?.models == [])

        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let other = makeModel(providers: [Self.existing], secrets: store)
        var retyped = Self.existing
        retyped.kind = .anthropic
        try await other.update(retyped, newKey: nil)
        #expect(other.providers.first?.models == [])
    }

    /// La feuille d'édition rend le fournisseur tel qu'il était à son ouverture : une liste lue depuis ne se perd pas.
    @Test func renamingKeepsTheCurrentModelListNotTheOneFromTheEditor() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing], secrets: store)
        var edited = Self.existing  // models == ["model-a"], copie prise avant la lecture
        lister.set(.success(["model-b"]))
        await model.refreshModels(Self.existing.id)

        edited.name = "Autre nom"
        try await model.update(edited, newKey: nil)
        #expect(model.providers.first?.name == "Autre nom")
        #expect(model.providers.first?.models == ["model-b"])
        #expect(model.status(of: Self.existing.id) == .ok(count: 1))
    }

    // MARK: - Nouvelle origine

    static let remote = Provider(
        id: UUID(), name: "Distant", baseURL: "https://models.invalid/v1", kind: .anthropic, models: ["m"])

    @Test func newOriginWithEmptyKeyDeletesTheOldKeyBeforeSaving() async throws {
        let store = RecordingSecretStore(secrets: [Self.remote.id.uuidString: "sk-remote"])
        let model = makeModel(providers: [Self.remote], secrets: store)
        var moved = Self.remote
        moved.baseURL = "https://elsewhere.invalid/v1"

        try await model.update(moved, newKey: "")

        #expect(store.peek(Self.remote.id.uuidString) == nil)
        #expect(store.calls.map(\.name) == ["delete"])
        #expect(model.providers.first?.baseURL == "https://elsewhere.invalid/v1")
        #expect(model.keyState(Self.remote.id) == .absent)
        // Aucune clé ne part vers le nouvel hôte.
        await model.refreshModels(Self.remote.id)
        #expect(lister.calls.isEmpty)
    }

    @Test(arguments: [
        ("https://models.invalid/v1", "https://models.invalid/api"),
        ("https://models.invalid", "https://MODELS.invalid:443/v1"),
        ("http://localhost:8080", "http://localhost:8080/v1"),
    ])
    func pathChangeKeepsTheKey(before: String, after: String) async throws {
        var provider = Self.remote
        provider.baseURL = before
        let store = RecordingSecretStore(secrets: [provider.id.uuidString: "sk-remote"])
        let model = makeModel(providers: [provider], secrets: store)
        var moved = provider
        moved.baseURL = after

        try await model.update(moved, newKey: nil)

        #expect(store.peek(provider.id.uuidString) == "sk-remote")
        #expect(!store.calls.contains { $0.name == "delete" })
        #expect(model.providers.first?.baseURL == after)
    }

    @Test(arguments: [
        ("https://models.invalid", "http://models.invalid"),
        ("https://models.invalid", "https://models.invalid:8443"),
        ("http://localhost:8080", "http://127.0.0.1:8080"),
        ("https://models.invalid", "https://models.invalid.evil.invalid"),
    ])
    func schemeHostOrPortChangeIsANewOrigin(before: String, after: String) {
        #expect(!ProvidersModel.sameOrigin(before, after))
    }

    @Test func failedDeletionOnANewOriginChangesNothing() async throws {
        let store = RecordingSecretStore(secrets: [Self.remote.id.uuidString: "sk-remote"])
        store.deleteFailure = .denied
        let model = makeModel(providers: [Self.remote], secrets: store)
        var moved = Self.remote
        moved.baseURL = "https://elsewhere.invalid"

        await #expect(throws: (any Error).self) { try await model.update(moved, newKey: nil) }

        #expect(model.providers == [Self.remote])
        #expect(saver.saved.isEmpty)
        #expect(store.peek(Self.remote.id.uuidString) == "sk-remote")
    }

    @Test func failedSaveAfterTheOldKeyWasRemovedSaysSo() async throws {
        let store = RecordingSecretStore(secrets: [Self.remote.id.uuidString: "sk-remote"])
        let model = makeModel(providers: [Self.remote], secrets: store)
        saver.failure = SaveFailure()
        var moved = Self.remote
        moved.baseURL = "https://elsewhere.invalid"

        let error = await #expect(throws: ProvidersError.self) { try await model.update(moved, newKey: nil) }
        guard case .oldKeyRemovedButNotSaved = error else {
            Issue.record("erreur inattendue : \(String(describing: error))")
            return
        }
        #expect(model.providers == [Self.remote])
        #expect(store.peek(Self.remote.id.uuidString) == nil)
        #expect(model.keyState(Self.remote.id) == .absent)
    }

    @Test func newOriginWithANewKeyNeverLeavesTheOldOneBehind() async throws {
        let store = RecordingSecretStore(secrets: [Self.remote.id.uuidString: "sk-remote"])
        let model = makeModel(providers: [Self.remote], secrets: store)
        var moved = Self.remote
        moved.baseURL = "https://elsewhere.invalid"

        try await model.update(moved, newKey: "sk-elsewhere")
        #expect(store.peek(Self.remote.id.uuidString) == "sk-elsewhere")

        // L'écriture de la nouvelle clé échoue : il ne reste aucune clé, surtout pas l'ancienne.
        let store2 = RecordingSecretStore(secrets: [Self.remote.id.uuidString: "sk-remote"])
        let model2 = makeModel(providers: [Self.remote], secrets: store2)
        store2.writeFailure = .denied
        await #expect(throws: ProvidersError.self) { try await model2.update(moved, newKey: "sk-elsewhere") }
        #expect(store2.peek(Self.remote.id.uuidString) == nil)
        #expect(model2.keyState(Self.remote.id) == .absent)
        #expect(model2.providers.first?.baseURL == "https://elsewhere.invalid")
    }

    // MARK: - Clés orphelines

    @Test func keyThatCannotBeDeletedIsRetriedOnTheNextSave() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        store.deleteFailure = .denied
        let model = makeModel(providers: [Self.existing], secrets: store)

        let error = await #expect(throws: ProvidersError.self) { try await model.remove(Self.existing.id) }
        #expect(error?.errorDescription?.contains(Self.existing.id.uuidString) == true)
        #expect(store.peek(Self.existing.id.uuidString) == "sk-local")

        store.deleteFailure = nil
        try await model.add(name: "Autre", baseURL: "https://other.invalid", kind: .anthropic, key: "sk-2")
        #expect(store.peek(Self.existing.id.uuidString) == nil)
    }

    @Test func keyLeftBehindByAFailedAddIsSignalledAndRetried() async throws {
        let model = makeModel()
        saver.failure = SaveFailure()
        secrets.deleteFailure = .denied

        let error = await #expect(throws: ProvidersError.self) {
            try await model.add(name: "Distant", baseURL: "https://models.invalid", kind: .anthropic, key: "sk-orphan")
        }
        guard case .notSavedKeyLeft = error else {
            Issue.record("erreur inattendue : \(String(describing: error))")
            return
        }
        let account = try #require(secrets.calls.first?.account)
        #expect(secrets.peek(account) == "sk-orphan")

        saver.failure = nil
        secrets.deleteFailure = nil
        try await model.add(name: "Autre", baseURL: "https://other.invalid", kind: .anthropic, key: "sk-2")
        #expect(secrets.peek(account) == nil)
    }

    @Test func updateValidatesTheAddressToo() async throws {
        let model = makeModel(providers: [Self.existing])
        var remote = Self.existing
        remote.baseURL = "http://models.invalid"
        await #expect(throws: ProvidersError.cleartextAddress) { try await model.update(remote, newKey: nil) }
        #expect(model.providers == [Self.existing])
        #expect(saver.saved.isEmpty)
    }

    // MARK: - Adresse

    @Test(arguments: ["http://models.invalid", "http://localhost.example.invalid", "http://localhost@example.invalid", "HTTP://models.invalid:80"])
    func plainHTTPToARemoteHostIsRefused(address: String) async throws {
        let model = makeModel()
        let error = await #expect(throws: ProvidersError.self) {
            try await model.add(name: "Distant", baseURL: address, kind: .anthropic, key: "sk")
        }
        #expect(error == .cleartextAddress)
        #expect(error?.errorDescription?.contains("en clair") == true)
        #expect(model.providers.isEmpty)
        #expect(secrets.calls.isEmpty)
    }

    @Test(arguments: ["http://localhost:8080", "http://127.0.0.1:9000/v1", "HTTP://LOCALHOST", "https://models.invalid/v1"])
    func plainHTTPToLocalhostIsAccepted(address: String) async throws {
        let model = makeModel()
        try await model.add(name: "Local", baseURL: address, kind: .openAICompatible, key: "sk")
        #expect(model.providers.first?.baseURL == address)
    }

    @Test(arguments: ["", "models.invalid", "ftp://models.invalid", "https://", "https:///v1"])
    func addressThatIsNotAFullHTTPURLIsRefused(address: String) async throws {
        let model = makeModel()
        await #expect(throws: ProvidersError.invalidAddress) {
            try await model.add(name: "Distant", baseURL: address, kind: .anthropic, key: "sk")
        }
    }

    // MARK: - Liste des modèles

    @Test func refreshStoresTheModelListAndSavesIt() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing], secrets: store)
        lister.set(.success(["model-b", "model-c"]))

        await model.refreshModels(Self.existing.id)

        #expect(lister.calls.map(\.1) == ["sk-local"])
        #expect(lister.calls.map(\.0.id) == [Self.existing.id])
        #expect(model.providers.first?.models == ["model-b", "model-c"])
        #expect(saver.saved.last?.first?.models == ["model-b", "model-c"])
        #expect(model.status(of: Self.existing.id) == .ok(count: 2))
        #expect(model.keyState(Self.existing.id) == .present)
    }

    @Test func keyIsReadOffTheMainThread() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing], secrets: store)
        await model.refreshModels(Self.existing.id)
        try await model.update(Self.existing, newKey: "sk-new")
        try await model.remove(Self.existing.id)

        #expect(store.calls.map(\.name) == ["read", "write", "delete"])
        #expect(store.calls.allSatisfy { !$0.onMainThread })
        // Sur la file commune de l'application, qui sépare les invites du trousseau.
        #expect(store.calls.allSatisfy { $0.queueLabel == SecretAccess.sharedQueue.label })
    }

    @Test func failedRefreshKeepsThePreviousModelList() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing], secrets: store)
        lister.set(.failure(EndpointError.http(status: 401, body: "")))

        await model.refreshModels(Self.existing.id)

        #expect(model.providers.first?.models == ["model-a"])
        #expect(saver.saved.isEmpty)
        guard case .failed(let message) = model.status(of: Self.existing.id) else {
            Issue.record("statut inattendu : \(model.status(of: Self.existing.id))")
            return
        }
        #expect(message.contains("Clé refusée"))
    }

    @Test func refreshMessagesDifferFor401UnreachableAndMalformed() {
        let refused = ProvidersModel.message(for: EndpointError.http(status: 401, body: "x"))
        let forbidden = ProvidersModel.message(for: EndpointError.http(status: 403, body: "x"))
        let notFound = ProvidersModel.message(for: EndpointError.http(status: 404, body: "x"))
        let unreachable = ProvidersModel.message(for: EndpointError.transport("SUPERVOX_BASE_URL détail"))
        let malformed = ProvidersModel.message(for: EndpointError.malformedResponse)
        let other = ProvidersModel.message(for: EndpointError.http(status: 502, body: "corps du serveur"))

        #expect(refused.contains("Clé refusée"))
        #expect(forbidden.contains("Clé refusée"))
        #expect(notFound.contains("introuvable"))
        #expect(unreachable.contains("injoignable"))
        #expect(malformed.contains("liste de modèles"))
        #expect(other.contains("502"))
        #expect(Set([refused, notFound, unreachable, malformed, other]).count == 5)
        // Ni le détail technique du transport ni le corps de la réponse ne sont montrés.
        #expect(!unreachable.contains("SUPERVOX"))
        #expect(!other.contains("corps du serveur"))
    }

    /// Une redirection vers une autre origine est refusée par le client : le message dit que la clé n'est pas partie
    /// et ce qu'il faut faire, au lieu d'un texte technique.
    @Test func crossOriginRedirectHasItsOwnMessage() {
        let message = ProvidersModel.message(for: EndpointError.crossOriginRedirect)
        #expect(message.contains("autre adresse"))
        #expect(message.contains("clé ne lui a pas été envoyée"))
        #expect(!message.contains("EndpointError"))
    }

    @Test func deniedKeychainHasItsOwnMessage() {
        let denied = ProvidersModel.message(for: SecretError.denied)
        #expect(denied.contains("trousseau"))
        #expect(denied != ProvidersModel.message(for: EndpointError.http(status: 401, body: "")))
    }

    @Test func refreshWithoutAStoredKeyDoesNotCallTheServer() async throws {
        let anthropic = Provider(id: UUID(), name: "Distant", baseURL: "https://models.invalid", kind: .anthropic, models: ["m"])
        let model = makeModel(providers: [Self.existing, anthropic])

        await model.refreshModels(Self.existing.id)
        await model.refreshModels(anthropic.id)

        #expect(lister.calls.isEmpty)
        #expect(model.keyState(Self.existing.id) == .absent)
        guard case .failed(let keyless) = model.status(of: Self.existing.id),
            case .failed(let missing) = model.status(of: anthropic.id)
        else {
            Issue.record("statuts inattendus")
            return
        }
        #expect(keyless.contains("sans clé"))
        #expect(keyless.contains("clé quelconque"))
        #expect(missing.contains("Aucune clé"))
        #expect(model.providers.map(\.models) == [["model-a"], ["m"]])
    }

    @Test func deniedKeychainReadFailsTheRefreshWithoutCallingTheServer() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        store.inner.failure = .denied
        let model = makeModel(providers: [Self.existing], secrets: store)

        await model.refreshModels(Self.existing.id)

        #expect(lister.calls.isEmpty)
        #expect(model.status(of: Self.existing.id) == .failed(ProvidersModel.message(for: SecretError.denied)))
        #expect(model.keyState(Self.existing.id) == .unknown)
    }

    @Test func failedSaveAfterRefreshKeepsThePreviousListAndSaysWhy() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing], secrets: store)
        lister.set(.success(["model-z"]))
        saver.failure = SettingsError.unreadableFileKept(fileName: "settings.json")

        await model.refreshModels(Self.existing.id)

        #expect(model.providers.first?.models == ["model-a"])
        guard case .failed(let message) = model.status(of: Self.existing.id) else {
            Issue.record("statut inattendu")
            return
        }
        #expect(message.contains("settings.json"))
    }

    @Test func cancelledRefreshReturnsToIdle() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing], secrets: store)
        lister.set(.failure(CancellationError()))
        await model.refreshModels(Self.existing.id)
        #expect(model.status(of: Self.existing.id) == .idle)
        #expect(model.providers.first?.models == ["model-a"])
    }

    @Test func modelFilterIgnoresCaseAndKeepsOrder() {
        let models = ["alpha-small", "Beta-large", "gamma-small"]
        #expect(ProvidersModel.filter(models, query: "SMALL") == ["alpha-small", "gamma-small"])
        #expect(ProvidersModel.filter(models, query: "  ") == models)
        #expect(ProvidersModel.filter(models, query: "zeta").isEmpty)
    }

    @Test func modelCountIsWrittenInPlainFrench() {
        #expect(ProvidersModel.modelCountLabel(0) == "Aucun modèle listé")
        #expect(ProvidersModel.modelCountLabel(1) == "1 modèle")
        #expect(ProvidersModel.modelCountLabel(2) == "2 modèles")
    }

    // MARK: - Lecture en cours

    func makeGatedModel(_ gate: Gate) -> (ProvidersModel, RecordingSecretStore) {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let saver = saver
        let model = ProvidersModel(
            providers: [Self.existing], secrets: store,
            listModels: { _, _ in
                await gate.wait()
                return ["model-late"]
            },
            save: { try saver.save($0) })
        return (model, store)
    }

    /// Lance `refreshModels` et attend qu'il soit suspendu dans la liste des modèles, ou terminé : une
    /// régression fait échouer le `#require` au lieu de bloquer.
    func startRefresh(_ model: ProvidersModel, _ gate: Gate) async throws -> Task<Void, Never> {
        let done = Gate()
        let refresh = Task {
            await model.refreshModels(Self.existing.id)
            done.open()
        }
        while !gate.isWaiting, !done.isOpen { await Task.yield() }
        try #require(gate.isWaiting, "la lecture aurait dû attendre le serveur")
        return refresh
    }

    @Test func secondRefreshWhileOneIsRunningIsIgnored() async throws {
        let gate = Gate()
        let (model, _) = makeGatedModel(gate)
        let first = try await startRefresh(model, gate)
        #expect(model.status(of: Self.existing.id) == .loading)

        // Lancée pendant la première. On attend qu'elle ait rendu la main, ou qu'elle soit arrivée au serveur
        // si la garde disparaissait ; la barrière, ouverte ensuite, ne retient plus personne.
        let secondDone = Gate()
        let second = Task {
            await model.refreshModels(Self.existing.id)
            secondDone.open()
        }
        while !secondDone.isOpen, gate.calls < 2 { await Task.yield() }
        gate.open()
        await first.value
        await second.value

        #expect(gate.calls == 1)
        #expect(model.providers.first?.models == ["model-late"])
    }

    @Test func resultIsDroppedAfterTheProviderWasRemoved() async throws {
        let gate = Gate()
        let (model, _) = makeGatedModel(gate)
        let refresh = try await startRefresh(model, gate)

        try await model.remove(Self.existing.id)
        gate.open()
        await refresh.value

        #expect(model.providers.isEmpty)
        #expect(model.status[Self.existing.id] == nil)
        #expect(saver.saved.last == [])
    }

    @Test func resultIsDroppedWhenTheAddressChangedMeanwhile() async throws {
        let gate = Gate()
        let (model, _) = makeGatedModel(gate)
        let refresh = try await startRefresh(model, gate)

        var moved = Self.existing
        moved.baseURL = "http://localhost:9999"
        try await model.update(moved, newKey: nil)
        gate.open()
        await refresh.value

        #expect(model.providers.first?.models == [])
        #expect(model.status(of: Self.existing.id) == .idle)
    }

    /// Lecture A en cours, l'adresse change, lecture B lancée : la fin de A ne doit pas effacer le
    /// « en cours » de B.
    @Test func staleRefreshDoesNotOverwriteTheStatusOfANewerOne() async throws {
        let gates = [Gate(), Gate()]
        let calls = Mutex(0)
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let saver = saver
        let model = ProvidersModel(
            providers: [Self.existing], secrets: store,
            listModels: { _, _ in
                let index = calls.withLock { count in
                    defer { count += 1 }
                    return count
                }
                await gates[min(index, 1)].wait()
                return ["model-\(index)"]
            },
            save: { try saver.save($0) })

        let first = try await startRefresh(model, gates[0])
        var renamedPath = Self.existing
        renamedPath.baseURL = "http://localhost:8080/v1"  // même origine : la clé reste
        try await model.update(renamedPath, newKey: nil)
        let second = try await startRefresh(model, gates[1])

        gates[0].open()
        await first.value
        #expect(model.status(of: Self.existing.id) == .loading)

        gates[1].open()
        await second.value
        #expect(model.status(of: Self.existing.id) == .ok(count: 1))
        #expect(model.providers.first?.models == ["model-1"])
    }

    // MARK: - Ouverture

    @Test func keyPresenceIsCheckedWithoutReadingAnyKey() async throws {
        let keyless = Provider(id: UUID(), name: "Sans clé", baseURL: "https://other.invalid", kind: .anthropic, models: [])
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        let model = makeModel(providers: [Self.existing, keyless], secrets: store)

        await model.checkKeys()

        #expect(model.keyState(Self.existing.id) == .present)
        #expect(model.keyState(keyless.id) == .absent)
        #expect(store.readCount == 0)
        #expect(store.inner.readCount == 0)
        #expect(store.calls.map(\.name) == ["contains", "contains"])
        #expect(store.calls.allSatisfy { !$0.onMainThread })
    }

    @Test func failedPresenceCheckLeavesTheStateUnknown() async throws {
        let store = RecordingSecretStore(secrets: [Self.existing.id.uuidString: "sk-local"])
        store.inner.failure = .denied
        let model = makeModel(providers: [Self.existing], secrets: store)

        await model.checkKeys()

        #expect(model.keyState(Self.existing.id) == .unknown)
        #expect(store.readCount == 0)
    }

    @Test func knownKeyStateIsNotAskedAgain() async throws {
        let model = makeModel()
        try await model.add(name: "Distant", baseURL: "https://models.invalid", kind: .anthropic, key: "sk")
        await model.checkKeys()
        #expect(!secrets.calls.contains { $0.name == "contains" })
        #expect(model.keyState(try #require(model.providers.first).id) == .present)
    }

    @Test func editorNoteSaysWhatIsKnownAboutTheKey() {
        #expect(ProvidersModel.keyNote(for: .present, newOrigin: false).contains("Une clé est enregistrée"))
        #expect(ProvidersModel.keyNote(for: .absent, newOrigin: false).contains("Aucune clé enregistrée"))
        #expect(ProvidersModel.keyNote(for: .unknown, newOrigin: false).contains("inconnu"))
        // Nouvel hôte : quel que soit l'état, l'ancienne clé ne partira pas.
        for state in [KeyState.present, .absent, .unknown] {
            #expect(ProvidersModel.keyNote(for: state, newOrigin: true).contains("ressaisissez"))
        }
    }

    @Test func openingSettingsNeverReadsAnyKey() {
        let model = makeModel(providers: [Self.existing])
        _ = model.providers
        _ = model.status
        _ = model.status(of: Self.existing.id)
        _ = model.keyState(Self.existing.id)
        #expect(model.keyState(Self.existing.id) == .unknown)
        #expect(secrets.calls.isEmpty)
        #expect(secrets.readCount == 0)
    }
}
