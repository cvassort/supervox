# Supervox — socle (étape 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Une application de barre de menus qui s'ouvre par une touche globale sur un panneau flottant ne prenant pas le focus, avec des réglages (fournisseurs, clé dans le trousseau, liste des modèles, raccourci) et la demande des permissions micro et Accessibilité. Aucune dictée encore.

**Architecture:** Deux cibles s'ajoutent au paquet. `SupervoxApp` (bibliothèque) contient tout ce qui se teste sans écran : réglages, secrets, raccourci, états du panneau, états des permissions, et les vues. `Supervox` (exécutable) ne contient que le point d'entrée. Un script assemble le bundle `.app` et le signe. La logique vit dans des types purs pilotés par des protocoles ; AppKit et Carbon restent derrière ces protocoles.

**Tech Stack:** Swift 6, Swift Testing, AppKit (`NSPanel`, `NSStatusItem`), SwiftUI pour la fenêtre de réglages et le contenu du panneau, Carbon (`RegisterEventHotKey`), Security (trousseau), AVFoundation (permission micro), ApplicationServices (`AXIsProcessTrusted`).

**Spec:** `docs/superpowers/specs/2026-11-12-supervox-design.md` — étape 2 de la section 7 ; sections 5.2, 5.4, 6.1 (`Settings`, `Secrets`), 6.6, 6.7 et 9.

**Ce plan ne couvre que l'étape 2.** Le panneau montre les pastilles de modes et un état « prêt », sans capture audio : la dictée arrive à l'étape 3.

## Global Constraints

- Version minimale : macOS 26. Tout est vérifié sous macOS 27 avec Xcode 27.
- Licence MIT. Aucune dépendance nouvelle : uniquement les frameworks du système.
- Dépôt public : aucun nom d'employeur, de fournisseur d'IA hébergeant un endpoint, d'identifiant de modèle d'endpoint, d'adresse réelle ni de chemin `/Users/...` dans un fichier suivi ou un message de commit. Une garde de commit locale le refuse : ne jamais la contourner.
- Aucune clé d'API dans un fichier, un journal, un message d'erreur ou le fichier de réglages. La clé ne vit que dans le trousseau et, une fois lue, en mémoire.
- Identifiant du bundle : `dev.supervox.app`. Service du trousseau : `dev.supervox.app`. Dossier des réglages : `Application Support/Supervox/settings.json`.
- Raccourci par défaut : contrôle + option + espace. Une touche de modification seule ou Fn n'est pas un raccourci valide.
- Le panneau ne prend jamais le focus de l'application active.
- Les tests ne touchent ni le vrai trousseau, ni le vrai dossier de réglages, ni les vraies permissions, sauf tests d'intégration désactivés par défaut (`SUPERVOX_KEYCHAIN=1`).
- TDD : test d'abord, échec constaté, code, succès constaté.

### Faits établis par le prototype du 2026-11-13 (macOS 27, sans compte développeur)

- Un `NSPanel` de style `.nonactivatingPanel`, affiché par `orderFrontRegardless()`, laisse l'application active au premier plan (6 appuis sur 6).
- `RegisterEventHotKey` (Carbon) fonctionne sans aucune permission.
- Signature ad hoc : chaque recompilation fait redemander le micro et l'Accessibilité, et bloque la lecture du trousseau sur une invite.
- Signature par un certificat auto-signé local : le micro et l'Accessibilité sont conservés après recompilation ; le trousseau redemande quand même, y compris après « Toujours autoriser ».
- Le trousseau à protection des données (`kSecUseDataProtectionKeychain`) refuse l'écriture (statut −34018) sans profil d'approvisionnement.
- Une entrée d'Accessibilité ou de trousseau créée sous une ancienne signature ne vaut pas pour la nouvelle : il faut la retirer.
- L'utilisateur n'a pas trouvé l'icône de la barre de menus pour quitter.

Conséquences, qui s'imposent à toutes les tâches : trousseau fichier classique ; **la clé n'est lue qu'au moment où une requête en a besoin, jamais au lancement**, puis gardée en mémoire ; le script de bundle signe avec l'identité donnée par `SUPERVOX_SIGN_IDENTITY` et retombe sur l'ad hoc en le disant ; le panneau lui-même offre « Réglages » et « Quitter ».

## Review Focus

1. **Fichier de réglages corrompu ou d'une version inconnue** : l'application démarre avec les valeurs par défaut, garde une copie du fichier illisible à côté, et le dit. Elle n'écrase jamais en silence. Test : tâche 1 (`corruptFileIsKeptAsideAndDefaultsAreUsed`).
2. **Trousseau qui refuse ou invite annulée** : l'erreur dit que la clé n'a pas pu être lue et propose de la ressaisir ; aucune valeur de clé n'apparaît. Test : tâche 2 (`deniedReadSurfacesAnErrorWithoutTheSecret`).
3. **Raccourci déjà pris par le système ou une autre application** : l'enregistrement échoue, l'ancien raccourci reste actif, les réglages affichent l'échec. Test : tâche 4 (`failedRegistrationKeepsThePreviousHotKey`).
4. **Endpoint injoignable ou clé refusée pendant « lister les modèles »** : message distinct pour 401, pour une adresse injoignable et pour une réponse qui n'est pas une liste ; la liste précédente n'est pas effacée. Test : tâche 3 (`listModelsMapsFailures`) et tâche 6 (`failedRefreshKeepsThePreviousModelList`).
5. **Accessibilité refusée ou retirée en cours de route** : l'état affiché suit la réalité à chaque ouverture du panneau ; rien ne plante. Test : tâche 5 (`permissionStateIsRereadOnEachOpen`).

---

## Structure des fichiers

```
Package.swift                                   (modifié : cibles SupervoxApp, Supervox, SupervoxAppTests)
Sources/SupervoxCore/Endpoint/ModelListing.swift          liste des modèles, deux types d'endpoint
Sources/SupervoxApp/Settings/AppSettings.swift            données des réglages
Sources/SupervoxApp/Settings/SettingsStore.swift          lecture, écriture, fichier corrompu
Sources/SupervoxApp/Secrets/SecretStore.swift             protocole, double en mémoire, cache
Sources/SupervoxApp/Secrets/KeychainSecretStore.swift     trousseau
Sources/SupervoxApp/HotKey/HotKey.swift                   touche + modificateurs, validation, libellé
Sources/SupervoxApp/HotKey/HotKeyCenter.swift             enregistrement avec repli
Sources/SupervoxApp/HotKey/CarbonHotKeyRegistrar.swift    Carbon
Sources/SupervoxApp/Panel/PanelModel.swift                états du panneau
Sources/SupervoxApp/Panel/PanelController.swift           NSPanel
Sources/SupervoxApp/Panel/PanelView.swift                 contenu SwiftUI
Sources/SupervoxApp/Permissions/PermissionsModel.swift    micro, Accessibilité
Sources/SupervoxApp/Permissions/SystemPermissions.swift   appels système
Sources/SupervoxApp/SettingsUI/ProvidersModel.swift       logique de l'écran Fournisseurs
Sources/SupervoxApp/SettingsUI/SettingsView.swift         fenêtre de réglages
Sources/SupervoxApp/AppController.swift                   assemblage : barre de menus, panneau, touche
Sources/Supervox/main.swift                               point d'entrée
Scripts/make-app.sh                                       bundle + signature
Tests/SupervoxAppTests/…                                  un fichier de tests par type ci-dessus
Tests/SupervoxCoreTests/ModelListingTests.swift
Tests/SupervoxCoreTests/Fixtures/endpoint/models-*.json
```

---

### Task 1: Réglages sur disque

**Files:**
- Modify: `Package.swift` (cibles `SupervoxApp` dépendant de `SupervoxCore`, et `SupervoxAppTests`)
- Create: `Sources/SupervoxApp/Settings/AppSettings.swift`, `Sources/SupervoxApp/Settings/SettingsStore.swift`
- Test: `Tests/SupervoxAppTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces:
  - `enum ProviderKind: String, Codable, Sendable { case openAICompatible, anthropic }`
  - `struct Provider: Codable, Equatable, Identifiable, Sendable { var id: UUID; var name: String; var baseURL: String; var kind: ProviderKind; var models: [String] }` — `models` est la dernière liste lue depuis l'endpoint. Aucune clé ici.
  - `enum HotKeyBehavior: String, Codable, Sendable { case toggle, hold }`
  - `struct AppSettings: Codable, Equatable, Sendable { var version: Int; var providers: [Provider]; var hotKey: HotKey; var hotKeyBehavior: HotKeyBehavior; var lastModeID: String }` avec `static let current = 1` et `static var defaults: AppSettings` (aucun fournisseur, raccourci par défaut, `toggle`, `lastModeID = "dictee-brute"`).
  - `struct SettingsLoad: Equatable { var settings: AppSettings; var notice: String? }`
  - `struct SettingsStore { init(file: URL); func load() -> SettingsLoad; func save(_ settings: AppSettings) throws; static func defaultFile() throws -> URL }`
- Consumes: `HotKey` (tâche 4). Pour que cette tâche compile seule, elle crée `HotKey.swift` avec la structure et sa valeur par défaut ; la tâche 4 y ajoute validation et libellé.

- [ ] **Step 1: Tests en échec**

```swift
@Test func missingFileGivesDefaultsWithoutNotice()
// load() sur un chemin absent == SettingsLoad(settings: .defaults, notice: nil) ; aucun fichier créé.

@Test func saveThenLoadRoundTrips()
// deux fournisseurs, raccourci modifié, hold : load().settings == ce qui a été sauvé.

@Test func saveIsAtomicAndCreatesTheFolder()
// dossier parent absent : save() le crée ; aucun fichier temporaire ne reste à côté.

@Test func corruptFileIsKeptAsideAndDefaultsAreUsed()
// fichier contenant "{pas du json" : load().settings == .defaults ; notice non nil et nomme le fichier mis de côté ;
// ce fichier (settings.json.illisible-<horodatage>) existe et contient exactement les octets d'origine ;
// un save() qui suit n'efface pas la copie.

@Test func newerVersionIsNotOverwritten()
// version = 99 : même traitement que le fichier corrompu, notice disant que la version est inconnue.

@Test func settingsFileNeverContainsASecretField()
// le JSON produit par save() n'a aucune clé nommée key, apiKey, secret, token (parcours récursif).
```

- [ ] **Step 2: Lancer, constater l'échec.** `swift test --filter SettingsStoreTests` → échec de compilation (types absents).
- [ ] **Step 3: Écrire `AppSettings` et `SettingsStore`.** Écriture atomique (`Data.write(options: .atomic)`), JSON trié et indenté. La mise de côté est un déplacement, pas une copie.
- [ ] **Step 4: Relancer, constater le succès.**
- [ ] **Step 5: Commit** — `feat: réglages sur disque, fichier illisible mis de côté`

### Task 2: Secrets

**Files:**
- Create: `Sources/SupervoxApp/Secrets/SecretStore.swift`, `Sources/SupervoxApp/Secrets/KeychainSecretStore.swift`
- Test: `Tests/SupervoxAppTests/SecretStoreTests.swift`, `Tests/SupervoxAppTests/KeychainIntegrationTests.swift`

**Interfaces:**
- Produces:
  - `enum SecretError: Error, Equatable { case denied; case unavailable(status: Int32) }`
  - `protocol SecretStore: Sendable { func read(account: String) throws -> String?; func write(_ secret: String, account: String) throws; func delete(account: String) throws }`
  - `final class InMemorySecretStore: SecretStore` (pour les tests ; compte ses lectures dans `readCount`, peut être réglé pour lever une erreur).
  - `final class CachedSecretStore: SecretStore { init(_ underlying: any SecretStore) }` — une lecture réussie est gardée en mémoire ; `write` et `delete` mettent le cache à jour ; une erreur n'est jamais mise en cache.
  - `struct KeychainSecretStore: SecretStore { init(service: String) }` — mot de passe générique, trousseau fichier (ne pas passer `kSecUseDataProtectionKeychain`). `errSecItemNotFound` → `nil` ; `errSecUserCanceled` et `errSecAuthFailed` → `.denied` ; autre statut → `.unavailable(status:)`. `write` met à jour si l'entrée existe.
  - Le compte d'un fournisseur est `provider.id.uuidString`.

- [ ] **Step 1: Tests en échec**

```swift
@Test func cachedStoreReadsTheUnderlyingStoreOnce()
// trois read() du même compte : underlying.readCount == 1.

@Test func cachedStoreNeverReadsBeforeItIsAsked()
// construire CachedSecretStore ne lit rien : readCount == 0.

@Test func writeAndDeleteUpdateTheCache()
// write puis read sans relire dessous ; delete puis read == nil.

@Test func deniedReadSurfacesAnErrorWithoutTheSecret()
// underlying lève .denied : read lève .denied ; String(describing:) de l'erreur ne contient pas le secret écrit avant ;
// la lecture suivante réessaie (readCount == 2).

@Test func missingSecretIsNilNotAnError()
```

Test d'intégration, désactivé sans `SUPERVOX_KEYCHAIN=1` : écrire, lire, mettre à jour, supprimer une entrée du service `dev.supervox.tests` avec un compte aléatoire ; l'entrée est supprimée en fin de test même en cas d'échec.

- [ ] **Step 2: Lancer, constater l'échec.**
- [ ] **Step 3: Écrire les trois types.**
- [ ] **Step 4: Relancer** ; lancer une fois le test d'intégration avec `SUPERVOX_KEYCHAIN=1` et mettre son bilan dans le rapport.
- [ ] **Step 5: Commit** — `feat: secrets dans le trousseau, lus à la demande`

### Task 3: Liste des modèles

**Files:**
- Create: `Sources/SupervoxCore/Endpoint/ModelListing.swift`
- Create: `Tests/SupervoxCoreTests/Fixtures/endpoint/models-openai-200.json`, `models-anthropic-200.json`, `models-401.json`
- Test: `Tests/SupervoxCoreTests/ModelListingTests.swift`

**Interfaces:**
- Consumes: `EndpointConfig`, `EndpointError`, le stub HTTP des tests existants (`StubURLProtocol`, `stubbedClient`).
- Produces:
  - `enum ModelListingKind: Sendable { case openAICompatible, anthropic }`
  - `struct ModelLister: Sendable { init(config: EndpointConfig, kind: ModelListingKind, session: URLSession = .shared, requestTimeout: TimeInterval = 15); func listModels() async throws -> [String] }` — identifiants triés, sans doublon.

**Avant d'écrire :** vérifier la forme exacte des deux routes dans la documentation officielle de chaque API (chemin, en-têtes d'authentification, en-tête de version, forme de la réponse, pagination). Ne rien écrire de mémoire. La fixture de type OpenAI est enregistrée depuis un endpoint réel avec `Scripts/record-fixtures.sh` étendu à cette route, puis réduite à trois modèles aux identifiants neutres (`model-a`, `model-b`, `model-c`) ; la fixture de l'autre type est écrite d'après l'exemple de la documentation officielle, et le rapport le dit.

- [ ] **Step 1: Tests en échec**

```swift
@Test func listsOpenAICompatibleModels()
// fixture 200 : ["model-a", "model-b", "model-c"] ; requête GET sur …/v1/models ; en-tête Authorization: Bearer <clé>.

@Test func listsAnthropicModels()
// fixture 200 : identifiants de la fixture ; en-têtes d'authentification et de version conformes à la doc ; pas d'en-tête Bearer.

@Test func followsPaginationUntilTheEnd()
// deux pages stubées : la liste contient les deux ; au plus 20 pages suivies, au-delà erreur.

@Test func baseURLWithOrWithoutTrailingV1GivesTheSameRoute()

@Test func listModelsMapsFailures()
// 401 → EndpointError.http(status: 401, …) ; hôte injoignable → .transport ; corps "{}" ou HTML → .malformedResponse.

@Test func errorsNeverContainTheKey()
```

- [ ] **Step 2 à 4 :** échec constaté, code, succès constaté.
- [ ] **Step 5: Commit** — `feat: liste des modèles d'un endpoint`

### Task 4: Raccourci global

**Files:**
- Create/Modify: `Sources/SupervoxApp/HotKey/HotKey.swift`, `HotKeyCenter.swift`, `CarbonHotKeyRegistrar.swift`
- Test: `Tests/SupervoxAppTests/HotKeyTests.swift`

**Interfaces:**
- Produces:
  - `struct HotKey: Codable, Equatable, Sendable { var keyCode: UInt32; var modifiers: Modifiers }` ; `struct Modifiers: OptionSet, Codable { control, option, shift, command }` ; `static let standard` (espace, contrôle + option).
  - `enum HotKeyValidation: Equatable { case valid; case needsModifier; case modifierOnly; case reserved(String) }` ; `func validate() -> HotKeyValidation`. Réservés : commande + espace, commande + tab, commande + Q.
  - `var label: String` — par exemple `⌃⌥Espace`.
  - `protocol HotKeyRegistrar { func register(_ hotKey: HotKey, onPress: @escaping @MainActor () -> Void) -> Bool; func unregister() }`
  - `@MainActor final class HotKeyCenter { init(registrar: any HotKeyRegistrar); private(set) var active: HotKey?; func apply(_ hotKey: HotKey, onPress: @escaping @MainActor () -> Void) -> Result<Void, HotKeyError> }` ; `enum HotKeyError: Error, Equatable { case invalid(HotKeyValidation); case taken }`.
  - `final class CarbonHotKeyRegistrar: HotKeyRegistrar`.

- [ ] **Step 1: Tests en échec**

```swift
@Test func standardHotKeyIsValidAndLabelled()
@Test func keyWithoutModifierIsRejected()            // .needsModifier
@Test func reservedCombinationsAreRejected()         // .reserved, pour les trois
@Test func applyRegistersAndRemembers()
@Test func failedRegistrationKeepsThePreviousHotKey()
// registrar double : accepte A, refuse B. apply(A) puis apply(B) == .failure(.taken) ; active == A ;
// le double a de nouveau A enregistré, et l'appui sur A appelle encore onPress.
@Test func invalidHotKeyNeverReachesTheRegistrar()
@Test func hotKeyRoundTripsThroughJSON()
```

- [ ] **Step 2 à 4 :** échec, code, succès. `CarbonHotKeyRegistrar` n'a pas de test automatique : il est vérifié à la tâche 7.
- [ ] **Step 5: Commit** — `feat: raccourci global avec repli sur le précédent`

### Task 5: Panneau, permissions, application

**Files:**
- Modify: `Package.swift` (cible exécutable `Supervox`)
- Create: `Sources/SupervoxApp/Panel/PanelModel.swift`, `PanelController.swift`, `PanelView.swift`, `Sources/SupervoxApp/Permissions/PermissionsModel.swift`, `SystemPermissions.swift`, `Sources/SupervoxApp/AppController.swift`, `Sources/Supervox/main.swift`, `Scripts/make-app.sh`
- Test: `Tests/SupervoxAppTests/PanelModelTests.swift`, `PermissionsModelTests.swift`

**Interfaces:**
- Produces:
  - `struct ModeChip: Equatable, Identifiable { let id: String; let title: String }` ; les quatre pastilles fixes de cette étape : `dictee-brute`, `dictee-nettoyee`, `prompt`, `entretien` ; aucune personnalisée.
  - `@MainActor @Observable final class PanelModel { private(set) var isOpen: Bool; private(set) var selectedModeID: String; func toggle(); func close(); func select(_ id: String) }` — `select` d'un identifiant inconnu est ignoré ; `selectedModeID` initial vient de `lastModeID` et retombe sur `dictee-brute` s'il est inconnu ; un changement est rendu par un rappel `onModeChanged` pour être sauvé.
  - `enum PermissionState: Equatable { case granted, denied, notDetermined }`
  - `protocol PermissionsProbe: Sendable { func microphone() -> PermissionState; func accessibility() -> PermissionState; func requestMicrophone() async -> Bool; func promptAccessibility() }`
  - `@MainActor @Observable final class PermissionsModel { init(probe: any PermissionsProbe); private(set) var microphone: PermissionState; private(set) var accessibility: PermissionState; func refresh(); func requestNext() async; var summary: String? }` — `requestNext` demande le micro d'abord, l'Accessibilité seulement une fois le micro décidé (ordre du design, 6.7). `summary` est `nil` quand tout est accordé, sinon une phrase qui dit ce qui manque et ce que cela empêche (sans Accessibilité : le texte sera copié, pas collé).
  - `PanelController` : `NSPanel` `.nonactivatingPanel`, flottant, sans barre de titre, fond translucide, coins arrondis, centré dans le tiers supérieur de l'écran actif, présent sur tous les bureaux ; `orderFrontRegardless()` ; Échap ferme ; ne devient jamais fenêtre principale.
  - `PanelView` : pastilles en haut, zone centrale « Prêt » avec le libellé du raccourci, ligne de permissions si `summary` n'est pas `nil`, et en bas à droite un menu « … » avec Réglages et Quitter.
  - `AppController` : politique `.accessory`, élément de barre de menus (Ouvrir le panneau, Réglages…, Quitter), assemblage de `SettingsStore`, `HotKeyCenter`, `PanelModel`, `PermissionsModel`. Le comportement `hold` est stocké mais sans effet à cette étape : le réglage l'affiche comme « à venir ».
  - `Scripts/make-app.sh` : `swift build -c release`, assemble `build/Supervox.app` (Info.plist : `dev.supervox.app`, `LSUIElement`, `NSMicrophoneUsageDescription`, version minimale 26.0), signe avec `SUPERVOX_SIGN_IDENTITY` si elle est définie, sinon en ad hoc en affichant que les permissions seront redemandées à chaque compilation ; affiche l'exigence désignée.

- [ ] **Step 1: Tests en échec**

```swift
@Test func toggleOpensThenCloses()
@Test func closeOnAClosedPanelIsHarmless()
@Test func unknownLastModeFallsBackToRawDictation()
@Test func selectingAModeReportsItForSaving()          // onModeChanged appelé une fois, avec le bon identifiant
@Test func selectingAnUnknownModeChangesNothing()
@Test func microphoneIsRequestedBeforeAccessibility()
// sonde double : micro notDetermined → requestNext appelle requestMicrophone, pas promptAccessibility ;
// micro décidé (accordé ou refusé) → requestNext appelle promptAccessibility.
@Test func permissionStateIsRereadOnEachOpen()
// la sonde change de réponse entre deux refresh() : le modèle suit, dans les deux sens.
@Test func summaryNamesWhatIsMissingAndItsConsequence()
@Test func summaryIsNilWhenEverythingIsGranted()
```

- [ ] **Step 2 à 4 :** échec, code, succès.
- [ ] **Step 5:** `Scripts/make-app.sh` puis `open build/Supervox.app` : l'application se lance, l'élément de barre de menus existe, le raccourci ouvre le panneau. Résultat dans le rapport.
- [ ] **Step 6: Commit** — `feat: application de barre de menus, panneau, permissions`

### Task 6: Fenêtre de réglages

**Files:**
- Create: `Sources/SupervoxApp/SettingsUI/ProvidersModel.swift`, `SettingsView.swift`
- Modify: `Sources/SupervoxApp/AppController.swift`
- Test: `Tests/SupervoxAppTests/ProvidersModelTests.swift`

**Interfaces:**
- Consumes: `SettingsStore`, `SecretStore`, `ModelLister`, `HotKeyCenter`.
- Produces:
  - `@MainActor @Observable final class ProvidersModel { init(settings: AppSettings, secrets: any SecretStore, listModels: @escaping (Provider, String) async throws -> [String], save: @escaping (AppSettings) throws -> Void) }`
  - `func add(name:baseURL:kind:key:) throws` ; `func update(_ provider: Provider, newKey: String?) throws` ; `func remove(_ id: UUID) throws` (supprime aussi la clé) ; `func refreshModels(_ id: UUID) async` ; `private(set) var status: [UUID: ProviderStatus]` avec `enum ProviderStatus: Equatable { case idle, loading, ok(count: Int), failed(String) }`.
  - Validation de l'adresse : schéma `https`, ou `http` seulement pour `localhost` et `127.0.0.1` ; sinon refus avec un message qui dit que la clé voyagerait en clair.
  - `SettingsView` : onglets Fournisseurs, Raccourci, Permissions. Le champ de clé est un champ sécurisé, vide à l'ouverture, avec la mention « une clé est enregistrée » quand c'est le cas : la clé n'est jamais relue pour être affichée.

- [ ] **Step 1: Tests en échec**

```swift
@Test func addingAProviderStoresTheKeyInSecretsNotInSettings()
@Test func removingAProviderDeletesItsKey()
@Test func refreshStoresTheModelListAndSavesIt()
@Test func failedRefreshKeepsThePreviousModelList()
// liste précédente ["model-a"] ; listModels lève http 401 : models inchangé, status == .failed(message parlant de la clé).
@Test func refreshMessagesDifferFor401UnreachableAndMalformed()
@Test func openingSettingsNeverReadsAnyKey()
// construire le modèle et lire tous ses états : secrets.readCount == 0.
@Test func plainHTTPToARemoteHostIsRefused()
@Test func plainHTTPToLocalhostIsAccepted()
@Test func failedSaveSurfacesAnErrorAndLeavesSecretsConsistent()
// save lève : add() lève, et la clé écrite juste avant est retirée.
```

- [ ] **Step 2 à 4 :** échec, code, succès.
- [ ] **Step 5: Commit** — `feat: réglages des fournisseurs, du raccourci et des permissions`

### Task 7: Vérification avec l'utilisateur, README

**Files:**
- Modify: `README.md`

Cette tâche n'est pas confiée à un sous-agent : elle demande l'écran et les clics de l'utilisateur.

- [ ] `Scripts/make-app.sh` avec `SUPERVOX_SIGN_IDENTITY` ; lancer ; accorder le micro puis l'Accessibilité.
- [ ] Dans un éditeur de texte : taper, appuyer sur le raccourci, continuer à taper. Le panneau s'affiche, le texte continue d'arriver dans l'éditeur.
- [ ] Échap ferme. Le menu « … » du panneau ouvre les réglages et quitte.
- [ ] Ajouter un fournisseur réel, lister ses modèles, quitter, relancer : le fournisseur et sa liste sont là ; `settings.json` ne contient pas la clé (`grep`).
- [ ] Changer le raccourci pour une combinaison prise : refus affiché, l'ancien fonctionne encore.
- [ ] Recompiler et relancer : noter ce qui est redemandé, et vérifier que rien n'est demandé au lancement pour le trousseau (la clé n'est lue qu'à « lister les modèles »).
- [ ] README : comment construire et lancer l'application, la création facultative d'un certificat local de signature et ce qu'elle évite, ce qui reste redemandé sans lui, où sont les réglages, comment retirer une ancienne entrée d'Accessibilité.
- [ ] Commit — `docs: construire et lancer l'application`

## Incertitudes

- Le comportement du panneau au-dessus d'une application en plein écran n'a pas été essayé.
- Le certificat auto-signé n'a été essayé que « non approuvé » ; l'utilisateur a refusé de le marquer comme approuvé. Son effet sur le trousseau reste donc inconnu.
- Le pipeline compile `SupervoxApp` sur une machine sans session graphique : attendu sans problème pour des tests de logique, non vérifié.
- La route de liste des modèles du second type d'endpoint n'a pas été relue dans sa documentation : c'est la première action de la tâche 3.
