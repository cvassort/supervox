# Supervox — banc d'essai (étape 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Un outil en ligne de commande, `supervox-bench`, qui mesure sur la voix de l'utilisateur la qualité des moteurs de transcription et la latence de bout en bout de la chaîne d'entretien, pour choisir le moteur par défaut et décider si la cible de 2 secondes est tenue.

**Architecture:** Un paquet Swift à trois cibles. `SupervoxCore` contient la logique pure et les clients d'endpoint, sans dépendance externe ; elle sera reprise telle quelle par l'application. `SupervoxEngines` enveloppe les moteurs locaux derrière les protocoles de `SupervoxCore`. `SupervoxBench` est l'exécutable : enregistrement du corpus, comparaison des moteurs, mesure de latence.

**Tech Stack:** Swift 6, Swift Testing, AVFoundation, FluidAudio 0.18.x (Apache-2.0 : Parakeet, détection de voix), argmax-oss-swift 1.1.x (MIT : WhisperKit), framework Speech d'Apple, swift-argument-parser (Apache-2.0).

**Spec:** `docs/superpowers/specs/2026-11-12-supervox-design.md` (étape 1 de la section 7, sections 4, 8 et 9).

**Ce plan ne couvre que l'étape 1.** Les étapes 2 à 7 du design dépendent du moteur retenu et du verdict de latence ; leurs plans seront écrits après la tâche 8.

## Global Constraints

- Version minimale : macOS 26. Tout est mesuré sous macOS 27.
- Licence du projet : MIT. Dépendances permises : MIT, Apache-2.0, BSD. Aucune dépendance GPL.
- Aucun nom de fournisseur, d'endpoint ou de modèle en dur dans le code : tout passe par des arguments ou des variables d'environnement.
- Adresse de l'endpoint : variable `SUPERVOX_BASE_URL`. Clé : variable `SUPERVOX_API_KEY`. La clé n'est jamais écrite dans un fichier, un journal, un message d'erreur ou un rapport.
- Le dossier `bench-data/` (corpus, enregistrements de la voix de l'utilisateur, résultats bruts) est ignoré par git. Seuls le code, les tests et des fixtures sans donnée personnelle sont versionnés.
- Capture du micro : annulation d'écho active (`setVoiceProcessingEnabled(true)`), lecture du premier canal uniquement, sans supposer le nombre de canaux (9 mesurés sur haut-parleurs, 3 au casque).
- Aucune transcription d'un passage sans voix détectée.
- Les valeurs réelles de `SUPERVOX_BASE_URL` et la façon d'obtenir `SUPERVOX_API_KEY` sur la machine de l'utilisateur sont dans son journal local (`docs/journal.md`, non versionné). Les identifiants de modèles et de voix à passer en argument y sont aussi.
- **Les taux d'erreur de ce banc portent sur des phrases entières transcrites en bloc**, pas sur une transcription en flux. Le texte final de l'application devra venir du même mode, ou être remesuré.
- Les suites de tests qui utilisent `StubURLProtocol` (état statique partagé) sont marquées `.serialized`.
- Commits : seulement si l'utilisateur a donné son accord pour initialiser le dépôt ; sinon, les étapes « Commit » sont sautées et signalées.

## Review Focus

1. **Enregistrement vide ou presque silencieux dans le corpus** : il est signalé « aucune voix » et exclu des moyennes, au lieu de compter un texte inventé par le moteur. Test : tâche 7 (`silenceYieldsNoSpeech`) et tâche 5 (`itemWithoutSpeechIsExcluded`).
2. **Écarts de forme entre référence et transcription** (majuscules, apostrophes typographiques, ponctuation, traits d'union) : ils ne comptent pas comme des erreurs ; les chiffres écrits en lettres contre en chiffres, eux, comptent et c'est documenté. Test : tâche 1 (`normalizationFoldsFormOnly`).
3. **Endpoint en panne ou en erreur au milieu d'une série** : le moteur concerné est marqué en échec avec le code d'erreur, les autres moteurs continuent, le rapport est produit. Test : tâche 5 (`failingEngineDoesNotStopRun`).
4. **Modèle qui raisonne et ne rend aucun contenu** : la mesure indique « aucun contenu », jamais une latence nulle ou infinie comptée dans la médiane. Test : tâche 6 (`reasoningOnlyStreamYieldsNoContent`) et tâche 7 (`noContentRunIsReportedNotAveraged`).
5. **Clé ou adresse absente** : arrêt immédiat avec un message qui nomme la variable manquante, sans jamais afficher de valeur. Test : tâche 4 (`missingKeyFailsBeforeAnyRequest`).

---

## Structure des fichiers

```
Package.swift
Sources/SupervoxCore/
  Text/TextNormalizer.swift        découpe et normalise un texte en mots
  Text/WordErrorRate.swift         taux d'erreur de mots, rappel des termes techniques
  Text/SentenceSplitter.swift      découpe un flux de texte en phrases complètes
  Audio/WavFile.swift              lecture et écriture WAV mono 16 bits
  Audio/Resampler.swift            rééchantillonnage vers 16 kHz
  Audio/AudioCapture.swift         capture micro avec annulation d'écho
  Endpoint/EndpointConfig.swift    lecture des variables d'environnement
  Endpoint/OpenAICompatibleClient.swift   transcription, chat en flux, synthèse
  Transcription/Transcriber.swift  protocole
  Voice/VoiceDetector.swift        protocole
Sources/SupervoxEngines/
  WhisperKitTranscriber.swift
  ParakeetTranscriber.swift
  AppleSpeechTranscriber.swift
  EndpointTranscriber.swift
  FluidVoiceDetector.swift
Sources/SupervoxBench/
  Main.swift                       commande racine et sous-commandes
  Corpus.swift                     format et chargement du corpus
  RecordCommand.swift
  TranscribeCommand.swift
  LatencyCommand.swift
  Reports.swift                    statistiques et tableaux Markdown
Tests/SupervoxCoreTests/           + Fixtures/endpoint/
Tests/SupervoxBenchTests/
Scripts/record-fixtures.sh         enregistre des réponses réelles de l'endpoint
Bench/corpus.example.tsv           trois phrases d'exemple, génériques
```

---

### Task 1: Paquet Swift, normalisation et taux d'erreur

**Files:**
- Create: `Package.swift`, `Sources/SupervoxCore/Text/TextNormalizer.swift`, `Sources/SupervoxCore/Text/WordErrorRate.swift`, `Sources/SupervoxEngines/Placeholder.swift`, `Sources/SupervoxBench/Main.swift`
- Test: `Tests/SupervoxCoreTests/TextNormalizerTests.swift`, `Tests/SupervoxCoreTests/WordErrorRateTests.swift`

**Interfaces:**
- Produces:
  - `public enum TextNormalizer { public static func words(_ text: String) -> [String] }`
  - `public struct ErrorCounts: Equatable, Sendable { public let substitutions, deletions, insertions, referenceCount: Int; public var rate: Double }` (`rate` = (S+D+I)/N, 0 si N = 0 et aucune insertion, 1 si N = 0 avec insertions)
  - `public enum WordErrorRate { public static func compute(reference: String, hypothesis: String) -> ErrorCounts }`
  - `public enum TermRecall { public static func compute(terms: [String], hypothesis: String) -> (found: Int, total: Int) }`

- [ ] **Step 1: Créer `Package.swift`**

`// swift-tools-version: 6.2`, `platforms: [.macOS("26.0")]`. Produits : bibliothèques `SupervoxCore` et `SupervoxEngines`, exécutable `supervox-bench` (cible `SupervoxBench`). Dépendances : `https://github.com/FluidInference/FluidAudio.git` `from: "0.18.3"`, `https://github.com/argmaxinc/argmax-oss-swift.git` `from: "1.1.1"` (produit `WhisperKit`), `https://github.com/apple/swift-argument-parser.git` `from: "1.5.0"`. `SupervoxCore` n'a aucune dépendance. `SupervoxEngines` dépend de `SupervoxCore`, `FluidAudio`, `WhisperKit`. `SupervoxBench` dépend des deux et d'`ArgumentParser`. Cibles de test : `SupervoxCoreTests` (dépend de `SupervoxCore`, ressources `Fixtures`) et `SupervoxBenchTests` (dépend de `SupervoxBench` et `SupervoxEngines`). `Main.swift` contient pour l'instant une commande racine vide, `Placeholder.swift` un fichier vide, afin que le paquet compile.

- [ ] **Step 2: Écrire les tests qui échouent**

```swift
import Testing
@testable import SupervoxCore

@Test func normalizationFoldsFormOnly() {
    #expect(TextNormalizer.words("L’endpoint FastAPI, c'est OK !") == ["l", "endpoint", "fastapi", "c", "est", "ok"])
    #expect(TextNormalizer.words("Est-ce que… ça marche ?") == ["est", "ce", "que", "ça", "marche"])
    #expect(TextNormalizer.words("3 workers") != TextNormalizer.words("trois workers"))
    #expect(TextNormalizer.words("   ") == [])
}

@Test func werCountsEachErrorKind() {
    #expect(WordErrorRate.compute(reference: "le worker celery tourne", hypothesis: "le worker salary tourne")
        == ErrorCounts(substitutions: 1, deletions: 0, insertions: 0, referenceCount: 4))
    #expect(WordErrorRate.compute(reference: "le worker tourne", hypothesis: "le tourne").deletions == 1)
    #expect(WordErrorRate.compute(reference: "le worker", hypothesis: "le petit worker").insertions == 1)
    #expect(WordErrorRate.compute(reference: "a b c d", hypothesis: "a b c d").rate == 0)
    #expect(WordErrorRate.compute(reference: "", hypothesis: "merci").rate == 1)
    #expect(WordErrorRate.compute(reference: "", hypothesis: "").rate == 0)
}

@Test func termRecallMatchesMultiWordTermsAfterNormalization() {
    let r = TermRecall.compute(terms: ["FastAPI", "worker Celery", "pull request"],
                               hypothesis: "Le endpoint fastapi et le Worker  Celery, pas la poule requête.")
    #expect(r.found == 2 && r.total == 3)
}
```

- [ ] **Step 3: Lancer et constater l'échec**

Run: `swift test --filter SupervoxCoreTests` — Expected: échec de compilation, types inconnus.

- [ ] **Step 4: Implémenter `TextNormalizer`, `WordErrorRate`, `TermRecall`**

Normalisation : minuscules, apostrophes droites et typographiques et traits d'union traités comme des séparateurs, ponctuation retirée, accents conservés, chiffres laissés tels quels. Taux d'erreur : distance d'édition au niveau des mots avec remontée du chemin pour compter S, D, I. Rappel : un terme est trouvé si sa suite de mots normalisés apparaît de façon contiguë dans la transcription normalisée.

- [ ] **Step 5: Lancer et constater le succès**

Run: `swift test --filter SupervoxCoreTests` — Expected: 3 tests passent.

- [ ] **Step 6: Commit** — `git add Package.swift Sources Tests && git commit -m "feat: paquet Swift, normalisation et taux d'erreur de mots"`

---

### Task 2: Corpus

**Files:**
- Create: `Sources/SupervoxBench/Corpus.swift`, `Bench/corpus.example.tsv`
- Test: `Tests/SupervoxBenchTests/CorpusTests.swift`

**Interfaces:**
- Produces:
  - `struct CorpusItem: Equatable { let id: String; let text: String; let terms: [String] }`
  - `enum CorpusError: Error, Equatable { case malformedLine(Int), duplicateID(String, line: Int), empty }`
  - `enum Corpus { static func parse(_ contents: String) throws -> [CorpusItem]; static func load(from url: URL) throws -> [CorpusItem] }`
  - Format : une phrase par ligne, `id<TAB>texte<TAB>terme1|terme2`. Lignes vides et lignes commençant par `#` ignorées. La troisième colonne peut être vide.

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
@Test func parsesItemsAndSkipsComments() throws {
    let items = try Corpus.parse("# corpus\np01\tLe worker Celery plante.\tworker Celery\n\np02\tBonjour.\t\n")
    #expect(items == [CorpusItem(id: "p01", text: "Le worker Celery plante.", terms: ["worker Celery"]),
                      CorpusItem(id: "p02", text: "Bonjour.", terms: [])])
}
@Test func reportsLineNumberOfMalformedLine() {
    #expect(throws: CorpusError.malformedLine(2)) { try Corpus.parse("p01\tA.\t\nligne sans tabulation\n") }
}
@Test func rejectsDuplicateIDsAndEmptyCorpus() {
    #expect(throws: CorpusError.duplicateID("p01", line: 2)) { try Corpus.parse("p01\tA.\t\np01\tB.\t\n") }
    #expect(throws: CorpusError.empty) { try Corpus.parse("# rien\n") }
}
```

- [ ] **Step 2: Lancer et constater l'échec** — Run: `swift test --filter CorpusTests` — Expected: échec de compilation.
- [ ] **Step 3: Implémenter `Corpus`** et écrire `Bench/corpus.example.tsv` avec trois phrases génériques en français mêlé d'anglais technique.
- [ ] **Step 4: Lancer et constater le succès** — Expected: 3 tests passent.
- [ ] **Step 5: Commit** — `git commit -m "feat: format et chargement du corpus"`

---

### Task 3: Audio — fichiers WAV, rééchantillonnage, capture, commande `record`

**Files:**
- Create: `Sources/SupervoxCore/Audio/WavFile.swift`, `Sources/SupervoxCore/Audio/Resampler.swift`, `Sources/SupervoxCore/Audio/AudioCapture.swift`, `Sources/SupervoxBench/RecordCommand.swift`
- Modify: `Sources/SupervoxBench/Main.swift`
- Test: `Tests/SupervoxCoreTests/WavFileTests.swift`, `Tests/SupervoxCoreTests/ResamplerTests.swift`

**Interfaces:**
- Consumes: `Corpus.load(from:)`, `CorpusItem`.
- Produces:
  - `public struct AudioClip: Equatable, Sendable { public let samples: [Float]; public let sampleRate: Double; public var duration: Double }`
  - `public enum WavFile { public static func write(_ clip: AudioClip, to url: URL) throws; public static func read(_ url: URL) throws -> AudioClip }` (mono, PCM 16 bits)
  - `public enum Resampler { public static func resample(_ clip: AudioClip, to sampleRate: Double) -> AudioClip }`
  - `public final class AudioCapture { public init(voiceProcessing: Bool = true); public func start() throws; public func stop() -> AudioClip; public var inputDescription: String }` (premier canal, fréquence native du périphérique)
  - Commande : `supervox-bench record --corpus <tsv> --out <dossier>` écrit `<dossier>/<id>.wav` à 16 kHz.

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
@Test func wavRoundTripKeepsSamplesWithin16BitPrecision() throws {
    let clip = AudioClip(samples: (0..<1600).map { Float(sin(Double($0) * 0.05)) * 0.5 }, sampleRate: 16000)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    try WavFile.write(clip, to: url)
    let back = try WavFile.read(url)
    #expect(back.sampleRate == 16000 && back.samples.count == 1600)
    #expect(zip(clip.samples, back.samples).allSatisfy { abs($0 - $1) < 1.0 / 16384 })
}
@Test func wavReadRejectsNonWavFile() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    try? Data("pas un wav".utf8).write(to: url)
    #expect(throws: (any Error).self) { try WavFile.read(url) }
}
@Test func resamplingPreservesDurationAndTone() {
    let src = AudioClip(samples: (0..<48000).map { Float(sin(2 * .pi * 440 * Double($0) / 48000)) }, sampleRate: 48000)
    let out = Resampler.resample(src, to: 16000)
    #expect(abs(out.samples.count - 16000) <= 2)
    let crossings = zip(out.samples, out.samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
    #expect(abs(crossings - 440) <= 2)   // la fréquence de 440 Hz est conservée
}
```

- [ ] **Step 2: Lancer et constater l'échec** — Run: `swift test --filter "WavFileTests|ResamplerTests"`.
- [ ] **Step 3: Implémenter `WavFile`, `Resampler` (avec `AVAudioConverter`), `AudioCapture`**

`AudioCapture` : `AVAudioEngine`, voice processing activé moteur arrêté, ducking au minimum, tap sur le nœud d'entrée en lisant `floatChannelData[0]`. **Montage vérifié pendant le cadrage, à reprendre tel quel** : un `AVAudioPlayerNode` est attaché et connecté au `mainMixerNode` *avant* l'activation du voice processing, même s'il ne joue rien. La capture seule, sans nœud de lecture connecté, n'a jamais été essayée ; si elle est tentée et échoue au démarrage du moteur, revenir à ce montage. Utiliser les variantes macOS 27 d'`installTap` sous `if #available(macOS 27, *)`.

- [ ] **Step 4: Implémenter `RecordCommand`**

Pour chaque phrase : afficher l'identifiant et le texte, attendre Entrée, enregistrer, attendre Entrée, rééchantillonner à 16 kHz, écrire le fichier, afficher la durée. Un fichier existant n'est pas écrasé sans `--overwrite`. Un enregistrement de moins de 0,5 s est refusé avec un message et la phrase est redemandée.

- [ ] **Step 5: Lancer les tests** — Expected: 3 tests passent.
- [ ] **Step 6: Vérification manuelle** — Run: `swift run supervox-bench record --corpus Bench/corpus.example.tsv --out /tmp/sv-rec` puis `afplay /tmp/sv-rec/<id>.wav`. Attendu : la voix est audible et nette ; `afinfo` indique 16000 Hz, 1 canal.
- [ ] **Step 7: Commit** — `git commit -m "feat: capture micro, fichiers WAV et commande record"`

---

### Task 4: Client d'endpoint — configuration et transcription

**Files:**
- Create: `Sources/SupervoxCore/Endpoint/EndpointConfig.swift`, `Sources/SupervoxCore/Endpoint/OpenAICompatibleClient.swift`, `Scripts/record-fixtures.sh`, `Tests/SupervoxCoreTests/Fixtures/endpoint/`
- Test: `Tests/SupervoxCoreTests/EndpointConfigTests.swift`, `Tests/SupervoxCoreTests/TranscriptionClientTests.swift`, `Tests/SupervoxCoreTests/StubURLProtocol.swift`

**Interfaces:**
- Produces:
  - `public struct EndpointConfig: Sendable { public let baseURL: URL; public let apiKey: String; public static func fromEnvironment(_ env: [String: String]) throws -> EndpointConfig }`
  - `public enum EndpointError: Error, Equatable { case missingVariable(String), http(status: Int, body: String), malformedResponse, streamInterrupted, transport(String) }`
  - `public final class OpenAICompatibleClient: Sendable { public init(config: EndpointConfig, session: URLSession = .shared); public func transcribe(wav: Data, model: String, language: String?, prompt: String?) async throws -> String }`

- [ ] **Step 1: Enregistrer des réponses réelles**

`Scripts/record-fixtures.sh` appelle l'endpoint (variables d'environnement) et écrit dans `Tests/SupervoxCoreTests/Fixtures/endpoint/` : `transcription-200.json`, `transcription-401.json` (appel avec une clé volontairement fausse), `chat-stream-content.sse`, `chat-stream-reasoning.sse`, `speech-200.wav`. Le script n'enregistre que le corps et le code de statut, jamais les en-têtes ni la clé. L'audio envoyé à la transcription est une phrase générée par `/usr/bin/say`, jamais la voix de l'utilisateur. Relire chaque fichier avant de le versionner : retirer les identifiants de requête et toute mention du fournisseur dans les corps. Vérifier que le flux enregistré se termine bien par `data: [DONE]` ; si l'endpoint n'envoie pas ce marqueur, le signaler avant d'écrire le test `streamCutBeforeDoneThrows`, car la règle de fin de flux change.

- [ ] **Step 2: Écrire les tests qui échouent**

`StubURLProtocol` est une sous-classe d'`URLProtocol` qui rejoue un statut et un corps, et expose la dernière requête reçue (corps compris). Elle remplace le « serveur local de test » du design : mêmes réponses réelles, sans port réseau. Dans un `URLProtocol`, le corps d'une requête arrive par `httpBodyStream` et non par `httpBody` : le lire depuis le flux. Une fois les fixtures enregistrées, remplacer dans les tests ci-dessous chaque `!text.isEmpty` par l'égalité avec le texte exact de la fixture.

```swift
@Test func missingKeyFailsBeforeAnyRequest() {
    #expect(throws: EndpointError.missingVariable("SUPERVOX_API_KEY")) {
        try EndpointConfig.fromEnvironment(["SUPERVOX_BASE_URL": "https://exemple.test"])
    }
    #expect(throws: EndpointError.missingVariable("SUPERVOX_BASE_URL")) {
        try EndpointConfig.fromEnvironment(["SUPERVOX_API_KEY": "k"])
    }
}
@Test func errorDescriptionNeverContainsTheKey() throws {
    let cfg = try EndpointConfig.fromEnvironment(["SUPERVOX_BASE_URL": "https://exemple.test", "SUPERVOX_API_KEY": "secret-123"])
    #expect(!String(describing: cfg).contains("secret-123"))
}
@Test func transcribeReturnsTextFromRecordedResponse() async throws {
    let client = stubbedClient(status: 200, fixture: "transcription-200.json")
    let text = try await client.transcribe(wav: Data([1, 2, 3]), model: "m", language: "fr", prompt: "FastAPI")
    #expect(!text.isEmpty)
    let body = String(decoding: StubURLProtocol.lastBody, as: UTF8.self)
    #expect(body.contains("name=\"model\"") && body.contains("name=\"language\"") && body.contains("name=\"prompt\"") && body.contains("name=\"file\""))
    #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer k")
}
@Test func transcribeMapsHTTPErrors() async {
    await #expect(throws: EndpointError.self) { try await stubbedClient(status: 401, fixture: "transcription-401.json").transcribe(wav: Data(), model: "m", language: nil, prompt: nil) }
    await #expect(throws: EndpointError.http(status: 503, body: "{\"error\":\"Internal Server Error\"}")) {
        try await stubbedClient(status: 503, body: "{\"error\":\"Internal Server Error\"}").transcribe(wav: Data(), model: "m", language: nil, prompt: nil)
    }
    await #expect(throws: EndpointError.malformedResponse) {
        try await stubbedClient(status: 200, body: "<html>").transcribe(wav: Data(), model: "m", language: nil, prompt: nil)
    }
}
```

- [ ] **Step 3: Lancer et constater l'échec** — Run: `swift test --filter "EndpointConfigTests|TranscriptionClientTests"`.
- [ ] **Step 4: Implémenter `EndpointConfig` et `transcribe`**

`EndpointConfig` a une description personnalisée qui masque la clé. `transcribe` envoie un `multipart/form-data` sur `<baseURL>/v1/audio/transcriptions` ; les champs `language` et `prompt` sont omis quand ils valent `nil`. Le corps d'erreur conservé dans `.http` est tronqué à 500 caractères.

- [ ] **Step 5: Lancer et constater le succès** — Expected: 4 tests passent.
- [ ] **Step 6: Commit** — `git commit -m "feat: configuration d'endpoint et client de transcription"`

---

### Task 5: Moteurs de transcription et commande `transcribe`

**Files:**
- Create: `Sources/SupervoxCore/Transcription/Transcriber.swift`, `Sources/SupervoxEngines/WhisperKitTranscriber.swift`, `Sources/SupervoxEngines/ParakeetTranscriber.swift`, `Sources/SupervoxEngines/AppleSpeechTranscriber.swift`, `Sources/SupervoxEngines/EndpointTranscriber.swift`, `Sources/SupervoxBench/TranscribeCommand.swift`, `Sources/SupervoxBench/Reports.swift`
- Delete: `Sources/SupervoxEngines/Placeholder.swift`
- Test: `Tests/SupervoxBenchTests/TranscriptionReportTests.swift`, `Tests/SupervoxBenchTests/EngineIntegrationTests.swift`

**Interfaces:**
- Consumes: `AudioClip`, `WavFile`, `WordErrorRate`, `TermRecall`, `CorpusItem`, `OpenAICompatibleClient.transcribe`.
- Produces:
  - `public protocol Transcriber: Sendable { var name: String { get }; func prepare() async throws; func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String }` (`clip` à 16 kHz)
  - `WhisperKitTranscriber(model: String)`, `ParakeetTranscriber()`, `AppleSpeechTranscriber(locale: String)`, `EndpointTranscriber(client: OpenAICompatibleClient, model: String)`
  - `struct ItemResult { let id: String; let hypothesis: String?; let seconds: Double?; let failure: String?; let hasSpeech: Bool }`
  - `struct EngineSummary: Equatable { let engine: String; let wer: Double?; let termsFound: Int; let termsTotal: Int; let medianSeconds: Double?; let p90Seconds: Double?; let failures: Int; let excluded: Int; var termRecall: Double? }` (`termRecall` = trouvés / total, `nil` si total = 0 ; le tableau affiche « trouvés/total », pas un pourcentage seul)
  - **Vocabulaire** : l'option `--vocabulary <fichier>` donne une liste globale, la même pour toutes les phrases. Les `terms` d'une phrase ne sont **jamais** passés au moteur : ce serait lui donner la réponse. Chaque moteur qui accepte un vocabulaire est mesuré deux fois, sans et avec la liste globale, et apparaît sur deux lignes (`whisperkit`, `whisperkit+vocab`).
  - `enum Reports { static func summarize(engine: String, corpus: [CorpusItem], results: [ItemResult]) -> EngineSummary; static func markdownTable(_ rows: [EngineSummary]) -> String; static func percentile(_ values: [Double], _ p: Double) -> Double? }`
  - `func runEngines(_ engines: [any Transcriber], corpus: [CorpusItem], audio: (String) throws -> AudioClip, hasSpeech: (AudioClip) async -> Bool, vocabulary: [String] = []) async -> [String: [ItemResult]]`
  - Commande : `supervox-bench transcribe --corpus <tsv> --audio <dossier> --engines whisperkit,parakeet,apple,endpoint --endpoint-model <id> --whisperkit-model <id> --out <dossier>`

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
struct FakeTranscriber: Transcriber {
    let name: String; let answers: [String: String]; var failOn: Set<String> = []
    func prepare() async throws {}
    func transcribe(_ clip: AudioClip, language: String, vocabulary: [String]) async throws -> String {
        let id = String(Int(clip.sampleRate))                 // l'identifiant est porté par la fréquence dans ce double
        if failOn.contains(id) { throw EndpointError.http(status: 503, body: "panne") }
        return answers[id] ?? ""
    }
}

@Test func summaryAggregatesErrorsOverAllWords() {
    let corpus = [CorpusItem(id: "a", text: "le worker celery tourne", terms: ["worker celery"]),
                  CorpusItem(id: "b", text: "bonjour", terms: [])]
    let results = [ItemResult(id: "a", hypothesis: "le worker salary tourne", seconds: 1.0, failure: nil, hasSpeech: true),
                   ItemResult(id: "b", hypothesis: "bonjour", seconds: 3.0, failure: nil, hasSpeech: true)]
    let s = Reports.summarize(engine: "x", corpus: corpus, results: results)
    #expect(abs(s.wer! - 0.2) < 1e-9)   // 1 erreur sur 5 mots, et non la moyenne des taux par phrase (0,125)
    #expect(s.termsFound == 0 && s.termsTotal == 1 && s.termRecall == 0.0)   // « worker celery » n'est pas retrouvé
    #expect(Reports.markdownTable([s]).contains("0/1"))
    #expect(abs(s.medianSeconds! - 2.0) < 1e-9 && s.failures == 0 && s.excluded == 0)
}
@Test func itemWithoutSpeechIsExcluded() {
    let corpus = [CorpusItem(id: "a", text: "bonjour", terms: []), CorpusItem(id: "b", text: "salut", terms: [])]
    let results = [ItemResult(id: "a", hypothesis: "bonjour", seconds: 1, failure: nil, hasSpeech: true),
                   ItemResult(id: "b", hypothesis: nil, seconds: nil, failure: nil, hasSpeech: false)]
    let s = Reports.summarize(engine: "x", corpus: corpus, results: results)
    #expect(s.wer == 0 && s.excluded == 1)
}
@Test func perItemTermsAreNeverPassedAsVocabulary() async {
    // un double qui mémorise le vocabulaire reçu : il doit valoir la liste globale, jamais les termes de la phrase
    let spy = VocabularySpy()
    _ = await runEngines([spy], corpus: [CorpusItem(id: "16000", text: "le worker celery", terms: ["worker celery"])],
                         audio: { AudioClip(samples: [0.1], sampleRate: Double($0)!) }, hasSpeech: { _ in true },
                         vocabulary: ["Kubernetes"])
    #expect(await spy.received == [["Kubernetes"]])
}
@Test func failingEngineDoesNotStopRun() async {
    let corpus = [CorpusItem(id: "16000", text: "bonjour", terms: []), CorpusItem(id: "8000", text: "salut", terms: [])]
    let bad = FakeTranscriber(name: "bad", answers: [:], failOn: ["16000", "8000"])
    let good = FakeTranscriber(name: "good", answers: ["16000": "bonjour", "8000": "salut"])
    let out = await runEngines([bad, good], corpus: corpus,
                               audio: { AudioClip(samples: [0.1], sampleRate: Double($0)!) }, hasSpeech: { _ in true })
    #expect(out["bad"]?.allSatisfy { $0.failure?.contains("503") == true } == true)
    #expect(out["good"]?.map(\.hypothesis) == ["bonjour", "salut"])
}
@Test func summaryOfAllFailuresHasNoRates() {
    let s = Reports.summarize(engine: "x", corpus: [CorpusItem(id: "a", text: "bonjour", terms: [])],
                              results: [ItemResult(id: "a", hypothesis: nil, seconds: nil, failure: "HTTP 503", hasSpeech: true)])
    #expect(s.wer == nil && s.medianSeconds == nil && s.failures == 1)
    #expect(Reports.markdownTable([s]).contains("échec"))
}
@Test func percentileOfEmptyIsNil() { #expect(Reports.percentile([], 0.9) == nil) }
```

- [ ] **Step 2: Lancer et constater l'échec** — Run: `swift test --filter TranscriptionReportTests`.
- [ ] **Step 3: Implémenter `Transcriber`, `Reports`, `runEngines`** — Le taux d'erreur est agrégé sur tous les mots du corpus. Une phrase en échec ou sans voix n'entre dans aucun taux.
- [ ] **Step 4: Lancer et constater le succès** — Expected: 5 tests passent.
- [ ] **Step 5: Implémenter les quatre moteurs**

Lire d'abord la documentation de chaque bibliothèque à la version épinglée ; ne pas écrire d'appel de mémoire.
- WhisperKit : `WhisperKit(WhisperKitConfig(model:))` ; modèle par défaut du banc `large-v3-v20240930_turbo`. Passer la langue `fr` et le vocabulaire comme amorce si l'API le permet.
- Parakeet : `AsrManager` de FluidAudio avec le modèle multilingue v3 (défaut de la bibliothèque). Il n'accepte pas de vocabulaire : le paramètre est ignoré et c'est noté dans le rapport.
- Apple : `SpeechAnalyzer` / `SpeechTranscriber` avec la locale `fr-FR`. Si la locale n'est pas dans `supportedLocales`, `prepare()` lève une erreur explicite.
- Endpoint : encode le clip en WAV et appelle `client.transcribe`, le vocabulaire joint par des virgules dans `prompt`.

- [ ] **Step 6: Écrire le test d'intégration des moteurs**

Activé seulement si `SUPERVOX_INTEGRATION=1` (téléchargement de modèles). Il génère une phrase avec `/usr/bin/say -v Thomas` (« Bonjour, ceci est un test de transcription. »), la convertit en 16 kHz, et exige pour chaque moteur local un taux d'erreur inférieur ou égal à 0,34 (au plus deux mots faux sur six) contre cette phrase.

- [ ] **Step 7: Lancer l'intégration** — Run: `SUPERVOX_INTEGRATION=1 swift test --filter EngineIntegrationTests` — Expected: les trois moteurs locaux passent. Un moteur qui échoue est signalé à l'utilisateur, pas retiré en silence.
- [ ] **Step 8: Implémenter `TranscribeCommand`**

Écrit `<out>/transcription.md` (tableau des moteurs, puis pour chaque moteur la liste des phrases fautives avec référence et transcription) et `<out>/transcription.json`. Le filtre `hasSpeech` vient de la tâche 7 ; jusque-là, il renvoie `true`.

- [ ] **Step 9: Commit** — `git commit -m "feat: moteurs de transcription et commande transcribe"`

---

### Task 6: Client d'endpoint — chat en flux, synthèse, découpage en phrases

**Files:**
- Modify: `Sources/SupervoxCore/Endpoint/OpenAICompatibleClient.swift`
- Create: `Sources/SupervoxCore/Text/SentenceSplitter.swift`
- Test: `Tests/SupervoxCoreTests/ChatStreamTests.swift`, `Tests/SupervoxCoreTests/SpeechClientTests.swift`, `Tests/SupervoxCoreTests/SentenceSplitterTests.swift`

**Interfaces:**
- Produces:
  - `public struct ChatMessage: Sendable { public let role: String; public let content: String }`
  - `public enum ChatDelta: Equatable, Sendable { case content(String), reasoning(String) }`
  - `public func chatStream(model: String, messages: [ChatMessage], maxTokens: Int) -> AsyncThrowingStream<ChatDelta, Error>`
  - `public func speech(model: String, input: String, voice: String, format: String, extra: [String: String]) async throws -> Data`
  - `public struct SentenceSplitter { public init(); public mutating func feed(_ fragment: String) -> [String]; public mutating func flush() -> String? }`

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
@Test func contentDeltasAreYieldedInOrder() async throws {
    var text = ""
    for try await d in stubbedClient(status: 200, fixture: "chat-stream-content.sse").chatStream(model: "m", messages: [], maxTokens: 50) {
        if case .content(let c) = d { text += c }
    }
    #expect(!text.isEmpty)
}
@Test func reasoningOnlyStreamYieldsNoContent() async throws {
    var content = 0, reasoning = 0
    for try await d in stubbedClient(status: 200, fixture: "chat-stream-reasoning.sse").chatStream(model: "m", messages: [], maxTokens: 50) {
        switch d { case .content: content += 1; case .reasoning: reasoning += 1 }
    }
    #expect(content == 0 && reasoning > 0)
}
@Test func streamCutBeforeDoneThrows() async {
    let cut = "data: {\"choices\":[{\"delta\":{\"content\":\"Bon\"}}]}\n\n"      // pas de [DONE]
    await #expect(throws: EndpointError.streamInterrupted) {
        for try await _ in stubbedClient(status: 200, body: cut).chatStream(model: "m", messages: [], maxTokens: 5) {}
    }
}
@Test func streamIgnoresMalformedLinesAndMapsHTTPError() async {
    let body = ": keep-alive\n\ndata: pas du json\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
    var parts: [ChatDelta] = []
    do { for try await d in stubbedClient(status: 200, body: body).chatStream(model: "m", messages: [], maxTokens: 5) { parts.append(d) } } catch {}
    #expect(parts == [.content("ok")])
    await #expect(throws: EndpointError.http(status: 404, body: "introuvable")) {
        for try await _ in stubbedClient(status: 404, body: "introuvable").chatStream(model: "m", messages: [], maxTokens: 5) {}
    }
}
@Test func speechSendsExtraParametersAtTopLevel() async throws {
    let data = try await stubbedClient(status: 200, fixture: "speech-200.wav")
        .speech(model: "m", input: "Bonjour", voice: "v", format: "wav", extra: ["lang_code": "f"])
    #expect(data.count > 44)
    let json = try JSONSerialization.jsonObject(with: StubURLProtocol.lastBody) as? [String: Any]
    #expect(json?["lang_code"] as? String == "f" && json?["input"] as? String == "Bonjour" && json?["voice"] as? String == "v")
}
@Test func speechRejectsEmptyAudio() async {
    await #expect(throws: EndpointError.malformedResponse) {
        try await stubbedClient(status: 200, body: "").speech(model: "m", input: "x", voice: "v", format: "wav", extra: [:])
    }
}

@Test func splitsOnSentenceEndAcrossFragments() {
    var s = SentenceSplitter()
    #expect(s.feed("D'accord. Quel est l'obj") == ["D'accord."])
    #expect(s.feed("ectif ? Et la") == ["Quel est l'objectif ?"])
    #expect(s.flush() == "Et la")
    #expect(s.flush() == nil)
}
@Test func doesNotSplitInsideAbbreviationsDecimalsOrEllipsis() {
    var s = SentenceSplitter()
    #expect(s.feed("M. Dupont utilise la version 3.5 du SDK, etc. ") == [])
    #expect(s.feed("Attends… je vérifie. ") == ["M. Dupont utilise la version 3.5 du SDK, etc. Attends… je vérifie."])
}
@Test func handlesEmptyAndWhitespaceOnlyFragments() {
    var s = SentenceSplitter()
    #expect(s.feed("") == [] && s.feed("   \n") == [] && s.flush() == nil)
}
```

- [ ] **Step 2: Lancer et constater l'échec** — Run: `swift test --filter "ChatStreamTests|SpeechClientTests|SentenceSplitterTests"`.
- [ ] **Step 3: Implémenter `chatStream`, `speech`, `SentenceSplitter`**

`chatStream` lit `URLSession.bytes`, ligne par ligne. Le raisonnement arrive selon les serveurs dans `delta.reasoning_content` ou `delta.reasoning` : accepter les deux. `speech` fusionne `extra` au premier niveau du corps JSON ; une clé d'`extra` ne peut pas écraser `model`, `input` ni `voice`. `SentenceSplitter` coupe après `.`, `?`, `!` suivis d'un espace ou d'une fin de ligne, sauf après une abréviation d'une liste fixe (`M.`, `Mme.`, `etc.`, `ex.`, `cf.`, `p.`, `n°`), entre deux chiffres, et dans `…` ou `...`.

- [ ] **Step 4: Lancer et constater le succès** — Expected: 9 tests passent.
- [ ] **Step 5: Commit** — `git commit -m "feat: chat en flux, synthèse vocale et découpage en phrases"`

---

### Task 7: Détection de voix et commande `latency`

**Files:**
- Create: `Sources/SupervoxCore/Voice/VoiceDetector.swift`, `Sources/SupervoxEngines/FluidVoiceDetector.swift`, `Sources/SupervoxBench/LatencyCommand.swift`
- Modify: `Sources/SupervoxBench/Reports.swift`, `Sources/SupervoxBench/TranscribeCommand.swift` (brancher `hasSpeech`)
- Test: `Tests/SupervoxBenchTests/LatencyReportTests.swift`, `Tests/SupervoxBenchTests/VoiceDetectorIntegrationTests.swift`

**Interfaces:**
- Consumes: `Transcriber`, `chatStream`, `speech`, `SentenceSplitter`, `AudioClip`, `Reports.percentile`.
- Produces:
  - `public struct SpeechSegment: Equatable, Sendable { public let start: Double; public let end: Double }`
  - `public protocol VoiceDetector: Sendable { func segments(in clip: AudioClip) async throws -> [SpeechSegment] }`
  - `FluidVoiceDetector()` (enveloppe `VadManager` de FluidAudio)
  - `struct TurnTiming: Equatable { let silence: Double; let transcription: Double; let firstSentence: Double?; let synthesis: Double?; var total: Double? }` (`total` vaut `nil` si une étape n'a rien rendu)
  - `struct LatencySummary: Equatable { let runs: Int; let noContent: Int; let medianTotal: Double?; let p90Total: Double?; let medianByLink: [String: Double]; let meetsTarget: Bool? }`
  - `extension Reports { static func summarizeLatency(_ timings: [TurnTiming], target: Double) -> LatencySummary }`
  - `func firstSentence(of stream: AsyncThrowingStream<ChatDelta, Error>) async throws -> String?` : la première phrase complète rendue par `SentenceSplitter` ; **si le flux se termine sans qu'aucune phrase ait été coupée, le texte restant (`flush()`) est la première phrase**. `nil` seulement si le flux n'a rendu aucun contenu.
  - Commande : `supervox-bench latency --audio <dossier> --engine <nom> --chat-model <id> --tts-model <id> --voice <id> --tts-extra key=value --silence-ms 600 --runs 10 --target 2.0 --out <dossier>`

- [ ] **Step 1: Écrire les tests qui échouent**

```swift
@Test func totalIsSumOfLinks() {
    // les durées sont des Double : comparer avec une tolérance de 1e-9, jamais avec ==
    #expect(abs(TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: 0.3).total! - 1.5) < 1e-9)
    #expect(TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: nil, synthesis: nil).total == nil)
}
@Test func singleQuestionWithoutTrailingSpaceIsTheFirstSentence() async throws {
    // cas mesuré pendant le cadrage : le modèle rapide répond par une seule question, sans rien après le « ? »
    let one = AsyncThrowingStream<ChatDelta, Error> { c in
        c.yield(.content("Quel est l'objectif du refacto")); c.yield(.content("ring ?")); c.finish()
    }
    #expect(try await firstSentence(of: one) == "Quel est l'objectif du refactoring ?")
    let reasoningOnly = AsyncThrowingStream<ChatDelta, Error> { c in c.yield(.reasoning("je réfléchis")); c.finish() }
    #expect(try await firstSentence(of: reasoningOnly) == nil)
    let two = AsyncThrowingStream<ChatDelta, Error> { c in c.yield(.content("D'accord. Et ensuite ?")); c.finish() }
    #expect(try await firstSentence(of: two) == "D'accord.")
}
@Test func noContentRunIsReportedNotAveraged() {
    let t = [TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: 0.3),
             TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.6, synthesis: 0.5),
             TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: nil, synthesis: nil)]
    let s = Reports.summarizeLatency(t, target: 2.0)
    #expect(s.runs == 3 && s.noContent == 1)
    #expect(abs(s.medianTotal! - 1.7) < 1e-9)   // médiane de 1,5 et 1,9 : l'essai sans contenu n'y entre pas
    #expect(s.meetsTarget == true)
}
@Test func targetIsJudgedOnP90AndUnknownWhenNothingMeasured() {
    let slow = (0..<10).map { TurnTiming(silence: 0.6, transcription: 0.2, firstSentence: 0.4, synthesis: $0 < 8 ? 0.3 : 1.5) }
    #expect(Reports.summarizeLatency(slow, target: 2.0).meetsTarget == false)   // médiane 1,5 mais p90 à 2,7
    #expect(Reports.summarizeLatency([], target: 2.0).meetsTarget == nil)
}
```

Test d'intégration (`SUPERVOX_INTEGRATION=1`) :

```swift
@Test func silenceYieldsNoSpeech() async throws {
    let silence = AudioClip(samples: [Float](repeating: 0, count: 32000), sampleRate: 16000)
    #expect(try await FluidVoiceDetector().segments(in: silence).isEmpty)
}
@Test func speechEndIsLocatedWithin200ms() async throws {
    // phrase générée par `say`, de durée d, suivie de 1 s de silence ajouté
    let segs = try await FluidVoiceDetector().segments(in: clipWithTrailingSilence)
    #expect(abs((segs.last?.end ?? -1) - speechDuration) <= 0.2)
}
```

- [ ] **Step 2: Lancer et constater l'échec** — Run: `swift test --filter LatencyReportTests`.
- [ ] **Step 3: Implémenter `VoiceDetector`, `FluidVoiceDetector`, `summarizeLatency`** — Le verdict `meetsTarget` porte sur le 90e centile, pas sur la médiane.
- [ ] **Step 4: Lancer et constater le succès** — Expected: 3 tests unitaires passent ; avec `SUPERVOX_INTEGRATION=1`, les 2 tests d'intégration passent.
- [ ] **Step 5: Implémenter `LatencyCommand`**

Pour chaque essai, sur un enregistrement du corpus : (1) repérer la fin de la voix avec le détecteur et couper le clip à cet instant ; (2) `silence` = valeur de `--silence-ms` ; (3) `transcription` = durée de la transcription du clip coupé par le moteur local ; (4) `firstSentence` = durée entre l'envoi au modèle (consigne d'intervieweur du design, section 6.2, plus la transcription obtenue) et la première phrase complète rendue par `SentenceSplitter` ; (5) `synthesis` = durée de l'appel de synthèse pour cette phrase. Un flux sans contenu donne `firstSentence = nil`.

Le rapport `<out>/latence.md` donne la médiane et le 90e centile du total, la médiane par maillon, le nombre d'essais sans contenu, le verdict, et **deux limites écrites en toutes lettres** : le silence de fin de tour est une constante ajoutée, pas une détection en direct ; la transcription est mesurée en bloc sur la phrase entière, ce qui majore ce que donnera un moteur en flux.

- [ ] **Step 6: Brancher `hasSpeech` dans `TranscribeCommand`** — Un enregistrement sans segment de voix est marqué `hasSpeech: false`.
- [ ] **Step 7: Commit** — `git commit -m "feat: détection de voix et mesure de latence de bout en bout"`

---

### Task 8: Passer le banc avec l'utilisateur et décider

**Files:**
- Create: `bench-data/corpus.tsv` (ignoré par git), `bench-data/resultats/` (ignoré), `docs/bench/2026-11-resultats.md` (versionné, sans nom de fournisseur ni phrase de l'utilisateur)

**Interfaces:**
- Consumes: les trois commandes de `supervox-bench`.
- Produces: le moteur de transcription par défaut et le verdict de latence, consignés ; ils sont l'entrée des plans des étapes 2 à 7.

- [ ] **Step 1: Écrire le corpus avec l'utilisateur** — Vingt phrases tirées de ses vrais prompts, en français mêlé d'anglais technique, chacune avec ses termes techniques dans la troisième colonne. Lui proposer une liste, il corrige.
- [ ] **Step 2: Enregistrer** — L'utilisateur lance `swift run supervox-bench record --corpus bench-data/corpus.tsv --out bench-data/audio`, au micro qu'il utilise d'habitude.
- [ ] **Step 3: Comparer les moteurs** — Run: `swift run supervox-bench transcribe --corpus bench-data/corpus.tsv --audio bench-data/audio --engines whisperkit,parakeet,apple,endpoint --endpoint-model <modèle de transcription de l'endpoint> --out bench-data/resultats`. Attendu : `transcription.md` contient une ligne par moteur.
- [ ] **Step 4: Mesurer la latence** — Avec le meilleur moteur local de l'étape 3 : `swift run supervox-bench latency --audio bench-data/audio --engine <nom> --chat-model <modèle rapide> --tts-model <modèle de voix> --voice <voix> --tts-extra <paramètres> --runs 10 --target 2.0 --out bench-data/resultats`.
- [ ] **Step 5: Appliquer la règle de décision du design**

Moteur par défaut : le plus grand nombre de termes techniques retrouvés ; à égalité (écart de deux termes ou moins, car avec une cinquantaine de termes un écart plus fin ne veut rien dire), le plus faible taux d'erreur global ; à égalité encore, le plus rapide. Donner les comptes « trouvés/total », pas seulement des pourcentages. Rappeler que ces taux portent sur des phrases entières transcrites en bloc. Si aucun moteur local ne dépasse l'endpoint sur les termes techniques, le dire : la dictée passera par l'endpoint et l'entretien par le meilleur moteur local. Si le verdict de latence est négatif, présenter les leviers (voix du système, silence plus court, autre modèle) et laisser l'utilisateur décider de continuer.

- [ ] **Step 6: Consigner** — Écrire `docs/bench/2026-11-resultats.md` : tableaux, nombre de phrases et d'essais, machine, limites de la mesure, décision. Reporter la décision dans le journal local.
- [ ] **Step 7: Commit** — `git add docs/bench && git commit -m "docs: résultats du banc d'essai et choix du moteur de transcription"`
