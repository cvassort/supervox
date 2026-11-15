# Supervox — étape 3 : dictée brute avec insertion — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un appui sur le raccourci ouvre le panneau et démarre l'écoute ; le texte s'affiche pendant que l'on parle ; un second appui (ou le relâchement, en mode maintien) transcrit et colle le texte dans l'application active.

**Architecture:** `SupervoxCore` reçoit la capture en flux, le rééchantillonnage continu, la ligne de temps de la voix et la session de dictée (acteur, machine à états), tous derrière des protocoles et testés avec des doubles. `SupervoxEngines` fournit le détecteur de voix en flux et le catalogue des modèles locaux. `SupervoxApp` reçoit l'insertion par collage, le contrôleur de dictée, les réglages de transcription et la vue ; il ne dépend toujours que de `SupervoxCore`. La cible `Supervox` assemble les moteurs réels.

**Tech Stack:** Swift 6 (tools 6.2), macOS 26+, Swift Testing, AVFoundation (`AVAudioEngine`, `AVAudioConverter`), FluidAudio 0.18.3 (`VadManager` en flux, Parakeet v3), WhisperKit 1.1.1, AppKit (`NSPasteboard`), CoreGraphics (`CGEvent`), Carbon (raccourci), SwiftUI.

**Spec:** `docs/superpowers/specs/2026-11-12-supervox-design.md` — sections 5.1 (Dictée), 5.2, 5.4, 6.1, 6.4, 6.6, 6.7, 8.

## Décisions de conception de cette étape (choix du constructeur)

- **Texte en direct = aperçu, texte collé = transcription en bloc.** L'aperçu retranscrit périodiquement, avec le moteur rapide (Parakeet), le passage de voix en cours ; les passages clos sont figés. À la fin, le moteur du mode (WhisperKit avec vocabulaire par défaut) transcrit en bloc tout l'audio parlé : c'est ce texte qui est collé. Les API de flux natives des bibliothèques sont écartées (première mise à jour vers 13 s pour la fenêtre glissante de FluidAudio ; micro imposé pour le flux de WhisperKit) — lu dans leurs sources.
- **Mesuré avant ce plan** (essai jetable, voix réelle) : retranscrire un passage avec Parakeet coûte 0,05 s pour 5 s d'audio et 0,14 s pour 30 s ; rééchantillonner par tranches indépendantes change le texte 2 fois sur 8, donc **un seul convertisseur pour toute la prise** ; WhisperKit télécharge par défaut dans le dossier Documents de l'utilisateur, donc **les modèles de l'application vont sous Application Support**.
- **Clic en dehors du panneau pendant une dictée : ignoré.** L'utilisateur clique dans le champ où il veut coller.

## Global Constraints

- Dépôt public : aucun nom d'employeur, de fournisseur d'IA hébergeant un endpoint, d'identifiant de modèle d'endpoint, d'adresse réelle ni de chemin personnel dans un fichier ou un message de commit. Exemples : `example.com`. La garde de commit locale ne se contourne jamais.
- Aucune clé d'API dans un fichier, un journal, un message d'erreur. Toute requête réseau porteuse de clé passe par `EndpointSession`.
- `SupervoxApp` ne dépend que de `SupervoxCore`. Les moteurs sont injectés ; seule la cible `Supervox` importe `SupervoxEngines`.
- Suite par défaut : aucun test n'ouvre le micro, ne télécharge de modèle, n'écrit dans le presse-papiers général, n'émet d'événement clavier ou souris, n'affiche de fenêtre, ne touche le trousseau réel, les préférences réelles ni le réseau extérieur. Ce qui l'exige vit derrière `SUPERVOX_INTEGRATION=1`, `SUPERVOX_MIC=1`, `SUPERVOX_WINDOWS=1`.
- Aucun test ne dépend de la vitesse de la machine : horloge et attentes injectées, jamais de délai réel comme condition de réussite.
- TDD : test d'abord, échec constaté, code, succès, puis une panne volontaire qui prouve que le test mord. `swift build --build-tests` sans avertissement, `swift test` entier vert avant chaque commit.
- Aucune transcription sans voix détectée (design 6.2) : le silence ne produit jamais de texte.
- Rien n'est collé sans que l'utilisateur ait terminé la dictée ; Échap annule sans rien coller ni copier.
- Jamais d'appel bloquant sur le fil principal (trousseau, chargement de modèle, attente de permission).
- Réglages : tout nouveau champ est optionnel au décodage avec une valeur par défaut ; un nouveau cas d'énumération exige une nouvelle version (règle écrite dans `AppSettings.swift`).
- Textes d'interface en français, phrases complètes, qui disent quoi faire.

## Review Focus

1. **Échap ou second appui pendant la transcription finale** : aucun collage tardif, aucun texte laissé dans le presse-papiers après une annulation.
2. **Silence, ou micro coupé** : aucun texte inventé ; un message dit qu'aucune voix n'a été entendue.
3. **Presse-papiers** : restauré s'il n'a pas changé, laissé intact s'il a changé pendant le collage ; jamais restauré avant que l'application cible ait lu le texte ; contenu non textuel (image, fichier) restauré tel quel.
4. **Modificateurs encore enfoncés au moment du collage** (mode maintien : contrôle et option tenus) : le collage attend leur relâchement, avec une limite, puis se rabat sur la copie avec un message.
5. **Modèle absent, téléchargement impossible** : la dictée ne se bloque pas ; l'état le dit et renvoie aux réglages.

---

### Task 1: Rééchantillonnage continu et capture en flux

**Files:**
- Create: `Sources/SupervoxCore/Audio/StreamingResampler.swift`, `Sources/SupervoxCore/Audio/MicrophoneFeed.swift`
- Modify: `Sources/SupervoxCore/Audio/AudioCapture.swift`
- Test: `Tests/SupervoxCoreTests/StreamingResamplerTests.swift`, `Tests/SupervoxCoreTests/MicrophoneFeedTests.swift`

**Interfaces:**
- Produces:
  - `public struct AudioChunk: Sendable, Equatable { public let samples: [Float]; public let sampleRate: Double }`
  - `public protocol MicrophoneFeed: Sendable { func start(onChunk: @escaping @Sendable (AudioChunk) -> Void) throws; func stop() }` — `onChunk` est appelé hors du fil principal, dans l'ordre ; `stop()` garantit qu'aucun `onChunk` n'arrive après son retour.
  - `public final class StreamingResampler` : `public init?(from: Double, to: Double)` ; `public func push(_ samples: [Float]) -> [Float]` ; `public func finish() -> [Float]` (vide la queue du filtre ; l'instance ne sert plus ensuite).
  - `AudioCapture` : `public init(voiceProcessing: Bool = true, promptsForAccess: Bool = true)` ; `public func start(onChunk: (@Sendable (AudioChunk) -> Void)? = nil) throws` ; conformité `MicrophoneFeed` par un adaptateur `public final class LiveMicrophoneFeed: MicrophoneFeed, @unchecked Sendable` qui possède une `AudioCapture` créée avec `promptsForAccess: false`.
  - `public final class ScriptedMicrophoneFeed: MicrophoneFeed` (dans `SupervoxCore`, pour les tests et l'outil de rendu) : `public init(chunks: [AudioChunk], startError: AudioCaptureError? = nil)` ; `start` livre toutes les tranches de façon synchrone, dans l'ordre, puis rend la main.

- [ ] **Step 1: tests du rééchantillonneur continu** (échec attendu : type absent)
  - Un signal de 3 s à 48 kHz (somme de sinus 220 Hz et 1 800 Hz) poussé par tranches de 4 800 échantillons puis `finish()` : le nombre d'échantillons à 16 kHz est égal à celui de `Resampler.resample` du clip entier à ± 64 près ; l'écart quadratique moyen entre les deux sorties, sur la partie commune après le premier dixième de seconde, est inférieur à 0,01.
  - Même signal poussé par tranches indépendantes passées à `Resampler.resample` : l'écart quadratique moyen dépasse celui du convertisseur continu (ce test fixe la raison d'être du type).
  - `init?(from: 16000, to: 16000)` : `push` rend ses échantillons inchangés, `finish()` rend vide.
  - Fréquence nulle ou négative : `init?` rend `nil`.
  - Tranche vide : `push([])` rend `[]` sans erreur.
- [ ] **Step 2: implémenter `StreamingResampler`** — un seul `AVAudioConverter` pour la durée de vie de l'instance, qualité maximale, même convention que `Resampler` (mono, Float32).
- [ ] **Step 3: tests de `ScriptedMicrophoneFeed`** — livre les tranches dans l'ordre ; `startError` est levée sans rien livrer ; rien n'est livré après `stop()`.
- [ ] **Step 4: `AudioCapture`** — `onChunk` reçoit chaque fenêtre du tap (premier canal, fréquence native) ; le tampon interne et `stop() -> AudioClip` restent inchangés pour le banc d'essai. Avec `promptsForAccess: false`, un statut « non déterminé » lève `AudioCaptureError.microphoneAccessDenied` sans afficher d'invite ni attendre. Le message d'accès refusé ne parle plus de « ce terminal » : il dit « Réglages Système > Confidentialité et sécurité > Micro ». Le fil audio ne fait qu'un verrou, une copie et l'appel de `onChunk` : aucun travail lourd.
- [ ] **Step 5: test d'intégration micro** (derrière `SUPERVOX_MIC=1`) : une seconde de capture livre des tranches dont la somme des durées est entre 0,6 et 1,4 s.
- [ ] **Step 6: Commit** — `feat: rééchantillonnage continu et capture du micro en flux`

### Task 2: Détection de voix en flux et ligne de temps de la voix

**Files:**
- Create: `Sources/SupervoxCore/Voice/StreamingVoiceDetector.swift`, `Sources/SupervoxCore/Dictation/SpeechTimeline.swift`, `Sources/SupervoxEngines/FluidStreamingVoiceDetector.swift`
- Test: `Tests/SupervoxCoreTests/SpeechTimelineTests.swift`, `Tests/SupervoxBenchTests/EngineIntegrationTests.swift` (ajout, derrière `SUPERVOX_INTEGRATION=1`)

**Interfaces:**
- Produces:
  - `public enum VoiceEvent: Equatable, Sendable { case speechStart(sample: Int); case speechEnd(sample: Int) }` — indices en échantillons à 16 kHz depuis le début de la prise.
  - `public protocol StreamingVoiceDetector: Sendable { var blockSize: Int { get }; func prepare() async throws; func reset() async; func process(_ block: [Float]) async throws -> VoiceEvent? }` — `block` a exactement `blockSize` échantillons à 16 kHz.
  - `public struct SpeechTimeline: Sendable` :
    - `public init(blockSize: Int, sampleRate: Double = 16000)`
    - `public mutating func append(_ samples: [Float]) -> [[Float]]` — ajoute à l'audio de la prise et rend les blocs complets devenus disponibles, dans l'ordre.
    - `public mutating func apply(_ event: VoiceEvent)`
    - `public var closedSegments: [Range<Int>] { get }`, `public var openSegmentStart: Int? { get }`, `public var hasSpeech: Bool { get }`, `public var duration: Double { get }`
    - `public func clip(of segment: Range<Int>) -> AudioClip`
    - `public func openClip(maxSeconds: Double) -> AudioClip?` — le passage ouvert, limité à ses `maxSeconds` dernières secondes ; `nil` sans passage ouvert.
    - `public func spokenClip(padding: Double) -> AudioClip?` — du début du premier passage à la fin du dernier (ou à la fin de la prise si un passage est ouvert), élargi de `padding` secondes de chaque côté, borné à la prise ; `nil` sans voix. Les silences intérieurs sont gardés : le moteur final reçoit la parole avec son rythme.
  - `public actor FluidStreamingVoiceDetector: StreamingVoiceDetector` : `public init(minSilence: Double = 0.6)` ; `blockSize` = 4096.

- [ ] **Step 1: tests de `SpeechTimeline`** (échec attendu : type absent)
  - `append` de 10 000 échantillons avec `blockSize` 4096 rend 2 blocs ; 2 192 de plus rendent le troisième ; l'ordre et le contenu sont exacts.
  - Sans événement : `hasSpeech` faux, `spokenClip` et `openClip` rendent `nil`.
  - `speechStart(8000)`, `speechEnd(24000)` : un passage clos `8000..<24000` ; `spokenClip(padding: 0.2)` couvre `4800..<27200` ; avec un début à 1 000, la borne basse est 0.
  - `speechStart` sans fin : `openSegmentStart` non nul, `spokenClip` va jusqu'à la fin de la prise, `openClip(maxSeconds: 1)` rend la dernière seconde.
  - Événements incohérents (deux débuts de suite, une fin sans début, une fin avant le début) : ignorés, l'état précédent est gardé.
  - Une fin au-delà de l'audio reçu est ramenée à la longueur reçue.
- [ ] **Step 2: implémenter `SpeechTimeline`.**
- [ ] **Step 3: `FluidStreamingVoiceDetector`** — `VadManager.makeStreamState()` et `processStreamingChunk` ; l'état de flux est gardé par l'acteur ; `reset()` le remet à neuf ; `speechPadding` à 0.
- [ ] **Step 4: test d'intégration** (`SUPERVOX_INTEGRATION=1`) : une phrase de synthèse (`/usr/bin/say`) encadrée d'une seconde de silence numérique donne exactement un `speechStart` puis un `speechEnd`, le début dans la première seconde et demie, la fin après la fin réelle ; trois secondes de silence ne donnent aucun événement.
- [ ] **Step 5: Commit** — `feat: détection de voix en flux et ligne de temps de la voix`

### Task 3: Session de dictée

**Files:**
- Create: `Sources/SupervoxCore/Dictation/DictationSession.swift`, `Sources/SupervoxCore/Dictation/DictationTypes.swift`
- Test: `Tests/SupervoxCoreTests/DictationSessionTests.swift`

**Interfaces:**
- Consumes: `MicrophoneFeed`, `AudioChunk`, `StreamingResampler` (Task 1) ; `StreamingVoiceDetector`, `SpeechTimeline` (Task 2) ; `Transcriber` (existant).
- Produces:
  - `public enum DictationFailure: Error, Equatable, Sendable { case microphone(String); case noSpeech; case engine(String) }` avec `public var message: String` (phrase complète en français).
  - `public enum DictationPhase: Equatable, Sendable { case idle, preparing, recording, finalizing, finished(String), cancelled, failed(DictationFailure) }`
  - `public struct DictationSnapshot: Equatable, Sendable { public var phase: DictationPhase; public var liveText: String; public var level: Float; public var elapsed: Double }` — `level` entre 0 et 1.
  - `public struct DictationConfig: Sendable { public var language: String; public var vocabulary: [String]; public var previewInterval: Double = 0.5; public var previewWindow: Double = 15; public var padding: Double = 0.2; public var maxDuration: Double = 300 }`
  - `public actor DictationSession` :
    - `public init(feed: any MicrophoneFeed, detector: any StreamingVoiceDetector, preview: (any Transcriber)?, final: any Transcriber, config: DictationConfig, now: @escaping @Sendable () -> Double)`
    - `public nonisolated let snapshots: AsyncStream<DictationSnapshot>` — un instantané à chaque changement ; le flux se termine après une phase terminale.
    - `public func start() async` — `idle` → `preparing` (prépare détecteur et moteurs) → `recording`.
    - `public func finish() async` — `recording` → `finalizing` → `finished(texte)` ou `failed`.
    - `public func cancel() async` — depuis toute phase non terminale → `cancelled`.
    - `public static func level(of samples: [Float]) -> Float` — niveau affichable (RMS en décibels ramené sur 0…1, −60 dB → 0, 0 dB → 1).

**Règles (chacune a son test) :**
- Aucune voix détectée à `finish()` : `failed(.noSpeech)` ; `final.transcribe` n'est **jamais** appelé (double qui compte ses appels).
- Le moteur final reçoit `spokenClip(padding:)`, la langue et le vocabulaire de la configuration, une seule fois.
- Texte final vide ou fait seulement d'espaces : `failed(.noSpeech)`.
- `cancel()` pendant `finalizing` : phase `cancelled`, et le résultat du moteur, quand il arrive, ne change plus rien (double dont la réponse est retenue par le test puis relâchée).
- `finish()` deux fois, `finish()` après `cancel()`, `start()` deux fois : le second appel est sans effet.
- Erreur de `feed.start` : `failed(.microphone(message))`, sans passer par `recording`.
- Erreur de `final.transcribe` : `failed(.engine(message))` ; la capture est arrêtée.
- Erreur du moteur d'aperçu ou `preview == nil` : la session continue ; `liveText` reste ce qu'il était.
- Aperçu : les passages clos sont transcrits une fois et figés ; le passage ouvert est retranscrit au plus une fois par `previewInterval`, jamais deux passes en même temps ; `liveText` est la concaténation, séparée par une espace, des textes figés puis du texte du passage ouvert.
- `maxDuration` atteinte : la session passe d'elle-même en `finalizing`, comme après `finish()`.
- Le rappel du micro ne fait que transmettre la tranche à l'acteur (pas de transcription ni de détection sur le fil audio) ; `feed.stop()` est appelé à toute sortie de `recording`.
- Le temps vient de `now` ; aucun test n'attend une durée réelle : les doubles de moteurs répondent quand le test le décide.

- [ ] **Step 1: écrire les tests ci-dessus avec des doubles** (`ScriptedMicrophoneFeed`, un détecteur scripté qui rend une liste d'événements par numéro de bloc, des moteurs doubles à réponse commandée). Échec attendu : types absents.
- [ ] **Step 2: implémenter `DictationSession`.**
- [ ] **Step 3: pannes volontaires** — retirer la garde « aucune voix », la garde d'annulation tardive, l'arrêt de la capture : chaque retrait fait échouer un test nommé dans le rapport.
- [ ] **Step 4: Commit** — `feat: session de dictée, aperçu en direct et texte final en bloc`

### Task 4: Insertion par collage

**Files:**
- Create: `Sources/SupervoxApp/Insertion/TextInserter.swift`, `Sources/SupervoxApp/Insertion/SystemPasteboard.swift`, `Sources/SupervoxApp/Insertion/SystemKeyPoster.swift`
- Test: `Tests/SupervoxAppTests/TextInserterTests.swift`

**Interfaces:**
- Consumes: `KeyboardLayout` (existant), `PermissionsProbe.accessibility()` (existant).
- Produces:
  - `public struct PasteboardContents: Equatable, Sendable { public var items: [[String: Data]] }` — un dictionnaire type → données par élément.
  - `@MainActor public protocol Pasteboard: AnyObject { var changeCount: Int { get }; func read() -> PasteboardContents; func write(_ contents: PasteboardContents); func writeText(_ text: String, transient: Bool) }`
  - `@MainActor public protocol KeyPoster: AnyObject { func modifiersHeld() -> Bool; func postPaste(keyCode: UInt16) -> Bool }`
  - `public enum InsertionOutcome: Equatable, Sendable { case pasted; case copied(reason: String); case nothing }`
  - `@MainActor public final class TextInserter` : `public init(pasteboard: any Pasteboard, keys: any KeyPoster, layout: any KeyboardLayout, isTrusted: @escaping @MainActor () -> Bool, wait: @escaping @MainActor (Double) async -> Void, restoreDelay: Double = 0.4, modifierPatience: Double = 1.0)` ; `public func insert(_ text: String) async -> InsertionOutcome` ; `public static func pasteKeyCode(layout: any KeyboardLayout) -> UInt16` (le code dont le caractère est « v » dans la disposition active ; 9 à défaut).
  - `public final class SystemPasteboard: Pasteboard` (`NSPasteboard.general`), `public final class SystemKeyPoster: KeyPoster` (`CGEventSource.flagsState`, `CGEvent` ⌘V posté sur `.cghidEventTap`).

**Règles (chacune a son test, avec des doubles ; `wait` est un double qui enregistre les durées) :**
- Texte vide ou fait d'espaces : `.nothing`, presse-papiers intact, aucune touche.
- Sans Accessibilité : le texte est écrit dans le presse-papiers et y reste ; `.copied(reason:)` dit que le texte est copié et qu'il suffit de faire ⌘V, et où accorder l'Accessibilité ; aucune touche.
- Cas nominal, dans cet ordre exact : lecture du contenu, écriture du texte (marqué transitoire), attente que les modificateurs soient relâchés, ⌘V avec le code de « v », attente de `restoreDelay`, restauration. Résultat `.pasted`.
- La restauration n'a lieu que si `changeCount` est encore celui noté juste après l'écriture du texte ; sinon le presse-papiers est laissé tel quel.
- Un contenu d'origine non textuel (deux éléments, types image et fichier) est restauré à l'identique ; un presse-papiers d'origine vide redevient vide.
- Modificateurs encore tenus après `modifierPatience` (sondés toutes les 0,05 s par `wait`) : aucune touche, le texte reste dans le presse-papiers, `.copied(reason:)` dit de relâcher les touches et de faire ⌘V.
- `postPaste` rend `false` : `.copied(reason:)`, le texte reste dans le presse-papiers.
- `pasteKeyCode` : disposition ANSI → 9 ; disposition où « v » est sur un autre code → ce code ; disposition sans « v » → 9.
- Le marquage transitoire utilise les types `org.nspasteboard.TransientType` et `org.nspasteboard.ConcealedType`, pour que les gestionnaires de presse-papiers n'archivent pas la dictée.

- [ ] **Step 1: tests** (échec attendu : types absents). **Step 2: implémentation.** **Step 3: pannes volontaires** (restauration inconditionnelle ; pas d'attente des modificateurs ; ordre écriture/touche inversé).
- [ ] **Step 4: test d'intégration du presse-papiers réel** derrière `SUPERVOX_PASTEBOARD=1` seulement, sur un presse-papiers **nommé** créé pour le test (`NSPasteboard(name:)`), jamais le général.
- [ ] **Step 5: Commit** — `feat: insertion par collage, presse-papiers sauvegardé et restauré`

### Task 5: Réglages de transcription et modèles locaux

**Files:**
- Create: `Sources/SupervoxApp/Settings/TranscriptionSettings.swift`, `Sources/SupervoxApp/SettingsUI/TranscriptionModel.swift`, `Sources/SupervoxApp/SettingsUI/TranscriptionPane.swift`, `Sources/SupervoxEngines/LocalModelCatalog.swift`
- Modify: `Sources/SupervoxApp/Settings/AppSettings.swift`, `Sources/SupervoxApp/SettingsUI/SettingsView.swift`, `Sources/SupervoxEngines/WhisperKitTranscriber.swift`, `Sources/SupervoxSnapshots/main.swift`
- Test: `Tests/SupervoxAppTests/TranscriptionSettingsTests.swift`, `Tests/SupervoxAppTests/TranscriptionModelTests.swift`

**Interfaces:**
- Produces:
  - `public struct TranscriptionSettings: Codable, Equatable, Sendable { public var engine: String; public var whisperModel: String; public var language: String; public var vocabulary: [String] }` — `engine` vaut `"whisperkit"` ou `"parakeet"` ; une valeur inconnue se lit comme `"whisperkit"` ; défauts : `whisperkit`, la variante mesurée à l'étape 1 (lire `docs/bench/2026-11-13-resultats.md` et `Sources/SupervoxBench/TranscribeCommand.swift` pour son nom exact), `fr`, liste vide. `AppSettings.transcription` est optionnel au décodage.
  - `public struct LocalModel: Equatable, Identifiable, Sendable { public let id: String; public let title: String; public let detail: String; public var state: State }` avec `public enum State: Equatable, Sendable { case absent, downloading(Double), ready, failed(String) }`.
  - `public protocol ModelCatalog: Sendable { func models() async -> [LocalModel]; func download(_ id: String, progress: @escaping @Sendable (Double) -> Void) async throws; func delete(_ id: String) async throws; func promptTokenCount(_ vocabulary: [String], whisperModel: String) async -> Int? }` (dans `SupervoxApp`).
  - `@MainActor @Observable public final class TranscriptionModel` : `init(settings: TranscriptionSettings, catalog: any ModelCatalog, promptTokenLimit: Int, save: @escaping @MainActor (TranscriptionSettings) throws -> Void)` ; `refresh() async`, `download(_:) async`, `delete(_:) async`, `setEngine(_:)`, `setWhisperModel(_:)`, `setLanguage(_:)`, `setVocabulary(text:) async` (un terme par ligne, lignes vides et doublons retirés) ; `message: String?`.
  - `public actor LocalModelCatalog: ModelCatalog` (dans `SupervoxEngines`) : `public init(root: URL)` ; les modèles WhisperKit sont téléchargés sous `root` (paramètre `downloadBase`), jamais dans le dossier Documents.
  - `WhisperKitTranscriber` : `public init(model: String, downloadBase: URL? = nil)`.
  - `SettingsView` reçoit un quatrième onglet « Transcription ».

**Règles (tests) :**
- Un fichier de réglages sans `transcription` se lit avec les défauts, sans mise de côté ; un moteur inconnu se lit `whisperkit`.
- Chaque changement est enregistré par `save` ; si `save` lève, la valeur affichée revient à l'ancienne et `message` dit pourquoi.
- Vocabulaire au-delà de la limite d'amorce du moteur (`promptTokenCount` > `promptTokenLimit`) : refusé, l'ancien est gardé, `message` donne les deux nombres. `promptTokenCount` `nil` (modèle absent) : accepté, avec un avertissement qui dit que la limite sera vérifiée quand le modèle sera là.
- Téléchargement : l'état passe par `downloading(fraction)` puis `ready` ; un échec donne `failed(message)` et un nouvel essai reste possible ; deux téléchargements du même modèle ne se lancent pas en parallèle.
- Suppression du modèle utilisé par le moteur choisi : permise, mais `message` prévient que la prochaine dictée le retéléchargera.
- L'onglet liste : Parakeet (aperçu en direct, et moteur possible), les variantes WhisperKit proposées (au moins celle par défaut et une plus petite ; lire la liste des variantes prises en charge dans les sources de WhisperKit plutôt que de la supposer), le détecteur de voix. Chaque ligne : état, bouton Télécharger ou Supprimer.

- [ ] **Step 1: tests du décodage et du modèle d'écran** (doubles de catalogue). **Step 2: implémentation.** **Step 3: `LocalModelCatalog`** et test d'intégration (`SUPERVOX_INTEGRATION=1`) : la liste reflète le disque ; supprimer puis lister rend `absent`. **Step 4: onglet, et ses images dans `supervox-snapshots`** (liste avec les quatre états, vocabulaire refusé) — regarder chaque image. **Step 5: pannes volontaires.**
- [ ] **Step 6: Commit** — `feat: réglages de transcription, vocabulaire et modèles locaux`

### Task 6: Contrôleur de dictée, raccourci en bascule et en maintien

**Files:**
- Create: `Sources/SupervoxApp/Dictation/DictationController.swift`
- Modify: `Sources/SupervoxApp/HotKey/HotKeyCenter.swift`, `Sources/SupervoxApp/HotKey/CarbonHotKeyRegistrar.swift`, `Sources/SupervoxApp/AppController.swift`, `Sources/SupervoxApp/Panel/PanelController.swift`, `Sources/SupervoxApp/Panel/PanelModel.swift`, `Sources/SupervoxApp/SettingsUI/HotKeySettingsModel.swift`, `Sources/Supervox/main.swift`, `Package.swift`
- Test: `Tests/SupervoxAppTests/DictationControllerTests.swift`, ajouts à `AppControllerTests.swift`, `HotKeyTests.swift`, `HotKeySettingsModelTests.swift`

**Interfaces:**
- Consumes: `DictationSession`, `DictationSnapshot`, `DictationConfig` (Task 3) ; `TextInserter`, `InsertionOutcome` (Task 4) ; `TranscriptionSettings` (Task 5).
- Produces:
  - `HotKeyRegistrar.register(_ hotKey: HotKey, onPress: @escaping @MainActor () -> Void, onRelease: (@MainActor () -> Void)?) -> Bool` ; `HotKeyCenter.apply(_:onPress:onRelease:)`.
  - `public struct DictationEnvironment: Sendable { public var makeSession: @Sendable (TranscriptionSettings) async throws -> DictationSession }` — construit par la cible `Supervox` avec les moteurs réels ; les tests et l'outil de rendu en donnent un double. `Supervox` dépend de `SupervoxEngines` dans `Package.swift`.
  - `@MainActor @Observable public final class DictationController` : `init(environment: DictationEnvironment, inserter: TextInserter, settings: @escaping @MainActor () -> TranscriptionSettings, behavior: @escaping @MainActor () -> HotKeyBehavior, panel: PanelOpening)` où `@MainActor public protocol PanelOpening: AnyObject { var isOpen: Bool { get }; func open(); func close() }` ; `public private(set) var view: DictationViewState` ; `func hotKeyPressed()`, `func hotKeyReleased()`, `func escapePressed()`, `func panelClosedByUser()`.
  - `public struct DictationViewState: Equatable, Sendable { public var phase: DictationPhase; public var liveText: String; public var levels: [Float]; public var elapsed: Double; public var notice: String? }` — `levels` garde les 48 derniers niveaux.
  - `PanelModel.dictation: DictationViewState` (lu par la vue, Task 7) ; `PanelController` : le clic en dehors est ignoré tant que `phase` vaut `preparing`, `recording` ou `finalizing`.

**Règles (tests, avec une session double pilotée par le test) :**
- Bascule : premier appui, panneau fermé → le panneau s'ouvre et la dictée démarre aussitôt ; second appui → `finish()`. Appui pendant `finalizing` : ignoré.
- Maintien : appui → démarre ; relâchement → `finish()` ; un relâchement sans dictée en cours est ignoré ; en mode bascule, le relâchement ne fait rien.
- Fin réussie en mode « Dictée brute » : `inserter.insert(texte)` est appelé une fois ; `.pasted` → le panneau se ferme ; `.copied(reason)` → le panneau reste ouvert et montre la raison ; `.nothing` ne peut pas arriver (le texte vide est un échec `noSpeech`).
- Échec (`noSpeech`, micro, moteur) : le panneau reste ouvert avec le message ; rien n'est collé ni copié ; un nouvel appui relance une dictée.
- Échap : pendant `preparing`, `recording` ou `finalizing` → `cancel()`, rien n'est collé ni copié, le panneau se ferme ; hors dictée → ferme le panneau (comportement actuel).
- Fermeture du panneau par le menu ou par Quitter pendant une dictée : `cancel()`.
- Une seule dictée à la fois : un appui pendant `preparing` est ignoré.
- Un mode autre que « Dictée brute » sélectionné : l'appui ouvre le panneau sans démarrer de dictée, et l'état dit « Ce mode arrive à une étape suivante. » (les pastilles restent cliquables pour choisir « Dictée brute »).
- Sans permission micro : pas de session ; le panneau s'ouvre sur la ligne des permissions existante.
- Modèle du moteur choisi absent : la phase `preparing` porte la mention « Téléchargement du modèle… » ; si la préparation échoue, message qui renvoie à l'onglet Transcription des réglages.
- `HotKeySettingsModel` : l'option « Maintenir pour dicter » devient disponible, sans la mention « à venir ».
- Le raccourci Carbon reçoit aussi `kEventHotKeyReleased` ; un double d'enregistreur prouve que `onRelease` est transmis et rétabli après `suspend`/`resume`.

- [ ] **Step 1: tests du contrôleur** (doubles : session, insertion, panneau). **Step 2: implémentation du contrôleur.** **Step 3: raccourci en maintien** (tests puis code). **Step 4: câblage dans `AppController` et `main.swift`** — `main.swift` construit `DictationEnvironment` avec `LiveMicrophoneFeed`, `FluidStreamingVoiceDetector`, `ParakeetTranscriber` pour l'aperçu, et pour le texte final le moteur des réglages (WhisperKit avec `downloadBase` sous Application Support, ou Parakeet). **Step 5: pannes volontaires** (collage après annulation ; clic en dehors non ignoré ; relâchement actif en mode bascule).
- [ ] **Step 6: essai sur l'application construite, sans événement simulé** — `Scripts/make-app.sh`, lancer, lire `log show` : l'application démarre, le raccourci est enregistré avec ses deux rappels. Le dire dans le rapport ; ce qui n'a pas pu être essayé (vrai appui, vraie voix, vrai collage) y est listé.
- [ ] **Step 7: Commit** — `feat: dictée brute pilotée par le raccourci, en bascule ou en maintien`

### Task 7: Vue de dictée dans le panneau, mesure et documentation

**Files:**
- Create: `Sources/SupervoxApp/Panel/DictationView.swift`, `Sources/SupervoxBench/LiveCommand.swift`, `docs/bench/2026-11-14-dictee-en-direct.md`, `docs/essai-final.md`
- Modify: `Sources/SupervoxApp/Panel/PanelView.swift`, `Sources/SupervoxSnapshots/main.swift`, `Sources/SupervoxBench/Main.swift`, `README.md`
- Test: `Tests/SupervoxAppTests/DictationViewTests.swift`, `Tests/SupervoxBenchTests/LiveCommandTests.swift`

**Interfaces:**
- Consumes: `DictationViewState` (Task 6), `DictationSession` (Task 3), `ScriptedMicrophoneFeed` (Task 1).
- Produces:
  - `public enum DictationText` : `static func duration(_ seconds: Double) -> String` (`0:07`, `1:05`) ; `static func tail(_ text: String, maxCharacters: Int) -> String` (garde la fin, coupe à une limite de mot, préfixe « … ») ; `static func status(for phase: DictationPhase) -> String`.
  - `DictationView` : indicateur d'enregistrement, forme d'onde (48 barres depuis `levels`), durée, texte en direct (quatre lignes au plus, la fin visible), états préparation / transcription / message d'échec / texte copié.
  - `supervox-bench live --audio <dossier> --corpus <fichier> --out <dossier>` : rejoue chaque enregistrement dans une `DictationSession` par tranches de 100 ms et écrit un rapport.

**Règles :**
- Tests de `DictationText` : durées, coupe à la limite de mot, texte plus court que la limite inchangé, chaque phase a un libellé non vide.
- Images ajoutées à `supervox-snapshots`, en clair et en sombre : préparation avec téléchargement, enregistrement sans texte, enregistrement avec un texte long, transcription en cours, échec « aucune voix », texte copié faute d'Accessibilité, mode non disponible. **Regarder chaque image** et corriger ce qui est coupé ou illisible ; décrire chacune dans le rapport.
- `supervox-bench live` (mêmes garde-fous que les autres commandes : sortie refusée dans un dossier suivi par git, `--overwrite`) mesure, sur le corpus de l'utilisateur : le taux d'erreur du texte final obtenu par la session, comparé à celui de la transcription en bloc de l'étape 1 ; le taux d'erreur du dernier aperçu ; le délai entre `finish()` et le texte final. Le test de la commande utilise des moteurs doubles.
- `docs/bench/2026-11-14-dictee-en-direct.md` : les chiffres mesurés avec leur commande, sans nom de fournisseur ni phrase du corpus, et une section « Incertitudes ».
- `docs/essai-final.md` est créé avec la section « Étape 2 — socle » et « Étape 3 — dictée » : pour chaque essai manuel, le geste et le résultat attendu (raccourci, Échap, clic en dehors, collage dans trois applications dont un terminal et un navigateur, presse-papiers restauré, image dans le presse-papiers restaurée, mode maintien, silence, refus d'Accessibilité, premier téléchargement de modèle, relance de l'application).
- README : section « Dictée » (ce qui marche, où sont les modèles, ce que l'aperçu en direct est et n'est pas).

- [ ] **Step 1: tests de `DictationText`, puis la vue.** **Step 2: images, regardées une à une.** **Step 3: `supervox-bench live`, test avec doubles.** **Step 4: mesure réelle** — l'implémenteur n'a pas accès au corpus : il laisse la commande prête ; le contrôleur lance la mesure et écrit le rapport de résultats. **Step 5: `docs/essai-final.md`, README.**
- [ ] **Step 6: Commit** — `feat: vue de dictée, mesure de la dictée en direct, liste d'essai`
