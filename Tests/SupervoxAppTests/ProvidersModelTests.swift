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
    }

    struct State {
        var calls: [Call] = []
        var deleteFailure: SecretError?
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

    /// Valeur actuelle, lue sans compter comme une lecture de l'application.
    func peek(_ account: String) -> String? {
        (try? inner.read(account: account)) ?? nil
    }

    private func note(_ name: String, _ account: String) {
        let call = Call(name: name, account: account, onMainThread: Thread.isMainThread)
        state.withLock { $0.calls.append(call) }
    }

    func read(account: String) throws -> String? {
        note("read", account)
        return try inner.read(account: account)
    }

    func write(_ secret: String, account: String) throws {
        note("write", account)
        try inner.write(secret, account: account)
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

    @Test func secondRefreshWhileOneIsRunningIsIgnored() async throws {
        let gate = Gate()
        let (model, _) = makeGatedModel(gate)
        let first = Task { await model.refreshModels(Self.existing.id) }
        while !gate.isWaiting { await Task.yield() }
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
        let refresh = Task { await model.refreshModels(Self.existing.id) }
        while !gate.isWaiting { await Task.yield() }

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
        let refresh = Task { await model.refreshModels(Self.existing.id) }
        while !gate.isWaiting { await Task.yield() }

        var moved = Self.existing
        moved.baseURL = "http://localhost:9999"
        try await model.update(moved, newKey: nil)
        gate.open()
        await refresh.value

        #expect(model.providers.first?.models == [])
        #expect(model.status(of: Self.existing.id) == .idle)
    }

    // MARK: - Ouverture

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
