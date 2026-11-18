# Supervox — étape 7 : réglage des voix — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** La voix de Supervox se choisit à l'écran. Un onglet « Voix » liste les voix du système installées et les voix de fournisseur que la personne a enregistrées, classées par langue et par genre ; elle en choisit une, peut l'écouter, et peut ajouter, modifier ou supprimer une voix de fournisseur (fournisseur, modèle, identifiant, langue, genre, paramètres supplémentaires libres). Aucun fichier à éditer.

**Architecture:** `SupervoxCore` apprend à lister les voix du système (nom, langue, genre, qualité), à parler avec une voix du système désignée par son identifiant, et à jouer un clip par la sortie seule (`ClipPlayer`, sans micro). `SupervoxApp` reçoit une liste de voix enregistrées dans les réglages (champ optionnel, version 3 inchangée), UNE règle « qui parle vraiment » partagée par l'entretien, la ligne de vie privée et l'onglet, un modèle d'onglet (`VoicesModel`), un aperçu sonore (`VoicePreview`) que l'application coupe dès qu'une dictée ou un entretien démarre, et l'onglet. `settings.voice` reste la seule chose que l'entretien lit.

**Tech Stack:** Swift 6, macOS 26+, Swift Testing, AVFAudio (`AVSpeechSynthesisVoice.speechVoices()`, `AVAudioPlayer`), SwiftUI. Aucune dépendance nouvelle.

**Spec:** `docs/superpowers/specs/2026-11-12-supervox-design.md` — sections 5.4 (« Voix : choix parmi des jeux de voix par langue et par genre »), 6.5 (une voix est une donnée ; paramètres libres ; voix du système en secours), 9 (ligne « Voix française »), 3 (dépôt public).

## Ce qui existe et que ce plan suppose

Faits lus dans le code à la fin de l'étape 6. Les numéros de ligne sont indicatifs : chaque tâche retrouve le symbole par `git grep -n` avant d'y toucher. Dernier essai de `docs/essai-final.md` à la fin de l'étape 6 : 96, « Retour à faire ».

Faits qui commandent le plan :
- `VoiceChoice` (`providerID`, `model`, `identifier`, `language`, `gender`, `extra`) existe et se lit sans échec ; aucun écran ne l'écrit ; aucune validation.
- `SystemSpeechSynthesizer` ignore `identifier` : il prend la meilleure voix de la langue. `SystemVoiceInfo` n'a ni nom ni genre.
- `extra` part au premier niveau du corps JSON, en texte ; `model`, `input`, `voice`, `response_format` l'écrasent (`OpenAICompatibleClient.swift:80-85`).
- Aucun moyen de jouer un `Speech` hors d'une conversation ; `LiveAudioIO` ouvre le micro pour jouer.
- `SupervoxApp` ne peut construire ni `SystemSpeechSynthesizer` ni `LiveAudioIO` (garde de source) : tout passe par des fermetures données par `Sources/Supervox/main.swift` à travers `InterviewEnvironment`.
- `InterviewSettingsModel.privacyText` (`InterviewSettingsModel.swift:244`) et `resolveVoiceProvider` (`InterviewEnvironment.swift:132`) n'appliquent pas la même règle : la première ne regarde que la présence du fournisseur, la seconde écarte aussi un fournisseur au format Anthropic et une voix sans modèle ou sans identifiant.
- `WavFile.write(_:to:)` encode déjà un clip en WAV PCM 16 bits mono (`WavFile.swift:27`), mais seulement vers un fichier.
- La fenêtre des réglages est fixe (600×460) ; sa barre de sept onglets n'a jamais été vue ; l'outil de rendu ne la dessine pas.

## Global Constraints

Celles de l'étape 6 valent toutes (plan `2026-11-16-supervox-entretien.md`, section du même nom). S'y ajoutent :

- Dépôt public : aucun nom de voix installée sur une machine réelle, aucun identifiant de voix ou de modèle d'un fournisseur réel, aucun paramètre propre à un serveur réel, dans un fichier suivi, un test, une image ou un commit. Noms d'exemple : « Voix d'exemple A », `voix.exemple.a`, `voix-exemple`, `modele-voix-exemple`, paramètre `cle-exemple` = `valeur-exemple`, « Fournisseur d'exemple ».
- Suite par défaut : aucun test ne joue un son, ne liste les voix réellement installées, ne synthétise par une voix du système, n'ouvre le micro, ne touche le trousseau réel ni le réseau réel. Le lecteur réel et la liste réelle ne sont construits que dans `Sources/Supervox/main.swift` ; les tests reçoivent des doubles. Ce qui exige le matériel vit derrière `SUPERVOX_PLAYER=1` (lecteur de sortie seule, nouveau) ou `SUPERVOX_SPEECH=1`, désactivé par défaut, **jamais lancé par un agent** : écrit, puis listé dans `docs/essai-final.md`.
- L'écoute d'une voix n'utilise JAMAIS le repli (`FallbackSpeechSynthesizer`) et n'ouvre JAMAIS le micro.
- L'entretien ne lit que `settings.voice` (`InterviewEnvironment.swift:87` inchangé). La liste des voix enregistrées ne sert qu'à l'onglet.
- Version des réglages inchangée (3) : tout champ nouveau est optionnel au décodage ; un champ inconnu est gardé ; une entrée illisible d'une liste ne fait perdre ni les autres ni elle-même.
- Un message montré vient d'une table de phrases fixes ; jamais `localizedDescription`, jamais le corps d'une réponse.
- Machine : une seule commande `swift` à la fois, sous `perl -e 'alarm N; exec @ARGV' swift …` ; pannes volontaires bornées, une à la fois, filtrées par suite ; `pgrep -fl swiftpm-testing-helper` vide avant de rendre.
- Tests et ordonnancement (leçons de l'étape 6) : le pipeline lance `swift test --no-parallel`, les lancements locaux sont en parallèle : la suite est verte dans les DEUX modes avant de rendre. Aucun test n'attend par sémaphore un travail confié à `DispatchQueue.global()` (sur un lanceur à peu de cœurs la file n'est plus servie) : un fil dédié (`Thread.detachNewThread`) ou une attente asynchrone. Un test qui lit la fin d'un flux lu par une tâche à part attend d'abord ce lecteur. Toute attente d'une tâche rend la main à l'annulation ; chaque suite neuve porte `.timeLimit(.minutes(1))`. Aucun test ne dépend de la vitesse de la machine.

## Review Focus

1. **L'écoute dit vrai.** Une voix de fournisseur mal réglée (identifiant faux, service muet) échoue avec une phrase ; elle n'est jamais remplacée par la voix du système pendant l'écoute. Une voix du système qui n'est plus installée se dit, sans synthèse. Test : tâche 3, règles 6 à 8.
2. **Le micro n'entend jamais la voix d'essai.** Lancer une dictée ou un entretien coupe l'écoute avant d'ouvrir le micro ; quitter l'onglet, fermer la fenêtre ou cliquer « Arrêter » la coupe. Test : tâche 3, règle 9 ; tâche 4, règle 5.
3. **Paramètres supplémentaires.** Une clé réservée (`model`, `input`, `voice`, `response_format`), vide ou en double est refusée à l'écran avec une phrase ; rien de réservé n'atteint le fournisseur même si le fichier de réglages en contient. Test : tâche 2, règle 3 ; tâche 3, règle 5.
4. **Rien ne disparaît.** La voix en vigueur reste affichée même si elle n'est ni installée ni enregistrée ; une voix enregistrée dont le fournisseur a été supprimé reste listée, marquée, non utilisable ; une entrée illisible du fichier est réécrite telle quelle. Test : tâche 2, règles 1 et 2 ; tâche 3, règles 2 et 3.
5. **Une seule règle « qui parle ».** L'entretien, la ligne de vie privée de l'onglet Entretien, celle du panneau et l'onglet Voix donnent la même réponse pour la même voix (fournisseur supprimé, format sans synthèse, modèle ou identifiant vide). Test : tâche 2, règle 4.

## Constats reportés à cette étape

- **`localizedDescription` montrés** (plan de l'étape 6, l. 62) : `AppController.swift:342` et `:669` (et les journaux `:343`, `:458`, `:670`), `HotKeySettingsModel.swift:177` et `:199`, `ProvidersModel.swift:358`, `SupervoxSnapshots/main.swift:622`. Tâche 5.
- **Sur-avertissement de vie privée** quand la voix retombe sur le système (parqué, tâche 10 de l'étape 6) : tâche 2, règle 4. Si la revue finale de l'étape 6 l'a déjà fait corriger, la tâche 2 réutilise ce correctif au lieu d'en écrire un second.

---

### Task 1: `SupervoxCore` — voix du système listées et désignées ; lecteur de sortie seule

**Files:**
- Modify: `Sources/SupervoxCore/Speech/SystemSpeechSynthesizer.swift`, `Sources/SupervoxCore/Audio/WavFile.swift`, `Tests/SupervoxCoreTests/SourceScanTests.swift`
- Create: `Sources/SupervoxCore/Audio/ClipPlayer.swift`, `Tests/SupervoxCoreTests/SystemVoiceListTests.swift`, `Tests/SupervoxCoreTests/ClipPlayerTests.swift`

**Interfaces — Produces:**
- `public enum SystemVoiceGender: String, Sendable, Equatable { case female, male }` (absent : `nil`, « non précisé »).
- `SystemVoiceInfo` gagne `public var name: String` et `public var gender: SystemVoiceGender?` ; `public init(identifier: String, language: String, quality: Int, name: String = "", gender: SystemVoiceGender? = nil)` (les appels existants compilent sans changement).
- `public enum SystemVoices { public static let installed: @Sendable () -> [SystemVoiceInfo] }` : le seul endroit du dépôt qui appelle `speechVoices()` ; le genre vient de `AVSpeechSynthesisVoice.gender` (`.unspecified` → `nil`).
- `SystemSpeechSynthesizer` : `public convenience init(language: String, identifier: String? = nil)` ; l'init interne gagne `identifier: String? = nil`.
- `static func pickVoice(language: String, identifier: String?, among: [SystemVoiceInfo]) -> SystemVoiceInfo?`.
- `public static func data(from clip: AudioClip) -> Data` dans `WavFile` (PCM 16 bits mono, en-tête de 44 octets) : le corps est sorti de `write(_:to:)`, qui l'appelle ; un seul encodeur dans le dépôt.
- `public protocol ClipPlayer: Sendable { func play(_ clip: AudioClip) async throws; func stop() }` : `play` rend la main quand le clip est fini ou arrêté ; annuler la tâche arrête la lecture.
- `public final class SystemClipPlayer: ClipPlayer` (`public init()`), sortie seule par `AVAudioPlayer(data:)` ; `public final class ScriptedClipPlayer: ClipPlayer` (double public : garde les clips reçus, finit à la demande ou tout de suite, peut lever `ClipPlayerError.failed`).
- `public enum ClipPlayerError: Error, Equatable, Sendable { case failed }`.

**Règles (un test nommé chacune) :**
1. `pickVoice` : un identifiant installé est pris, quelle que soit la langue demandée ; un identifiant absent ou `nil` donne la meilleure voix de la langue (règle existante, inchangée). `anInstalledIdentifierWins`, `aMissingIdentifierFallsBackToTheBestVoiceOfTheLanguage`.
2. Le synthétiseur passe l'identifiant choisi au rendu (double de rendu : l'identifiant reçu est celui de la règle 1). `theChosenIdentifierReachesTheRenderer`.
3. Encodeur WAV : aller-retour `decode(data(from: clip))` rend la fréquence et le nombre d'échantillons, valeurs à 1/32 768 près ; un clip vide donne un fichier valide de 44 octets. `theEncoderRoundTrips`.
4. `ScriptedClipPlayer` : `play` ne rend la main qu'à la fin commandée ; `stop()` la rend ; l'annulation de la tâche appelante la rend et appelle `stop` une fois. `playReturnsOnlyAtTheEnd`, `stopEndsPlay`, `cancellingEndsPlay`.
5. `SystemClipPlayer` est écrit pour ne rien laisser à tester : il encode par la règle 3, crée le lecteur, attend sa fin par le délégué ou `stop()`. Un seul test matériel, **désactivé par défaut, jamais lancé par un agent**, derrière une variable À PART : `.enabled(if: ProcessInfo.processInfo.environment["SUPERVOX_PLAYER"] == "1")` (pas `SUPERVOX_SPEAKER`, qui active aussi des tests qui ouvrent le micro). Il joue 0,3 s d'un son à 440 Hz par la sortie seule et vérifie que `play` rend la main en moins de 3 s. Commentaire en tête : ce qu'il fait à la machine.
6. Gardes de source (étendre `SourceScanTests`, avec leurs tests de motif) : `speechVoices(` seulement dans `SystemSpeechSynthesizer.swift` ; `AVAudioPlayer` seulement dans `Audio/ClipPlayer.swift` ; `SystemClipPlayer(` et `SystemVoices.installed` seulement dans `Sources/Supervox/main.swift` (et leur fichier de définition) ; aucun fichier de test hors `SupervoxCoreTests` ne les nomme.

**Pannes volontaires :** règle 1 (ignorer l'identifiant), règle 4 (ne pas appeler `stop` à l'annulation), règle 6 (ajouter `SystemClipPlayer()` dans un fichier de `SupervoxApp`).

- [ ] Tests des règles 1 à 4 et 6, rouges ; code ; verts ; test matériel écrit et laissé désactivé ; commit par unité.

---

### Task 2: Réglages — voix enregistrées, validation, règle « qui parle »

**Files:**
- Modify: `Sources/SupervoxApp/Settings/InterviewSettings.swift`, `Sources/SupervoxApp/Settings/AppSettings.swift`, `Sources/SupervoxApp/Interview/InterviewEnvironment.swift`, `Sources/SupervoxApp/SettingsUI/InterviewSettingsModel.swift`, `Sources/Supervox/LiveInterview.swift`, `Sources/Supervox/main.swift`
- Create: `Sources/SupervoxApp/Settings/VoiceRoute.swift`, `Tests/SupervoxAppTests/SavedVoiceTests.swift`, `Tests/SupervoxAppTests/VoiceRouteTests.swift`

**Interfaces — Produces:**
- `public struct SavedVoice: Codable, Equatable, Sendable, Identifiable { public var id: UUID; public var name: String; public var voice: VoiceChoice }` (champs inconnus gardés).
- `AppSettings.voices: [SavedVoice]` (défaut `[]`, clé `voices`) ; les entrées illisibles sont gardées à part et réécrites à la suite, telles quelles.
- `VoiceChoice.reservedExtraKeys: Set<String>` = `model`, `input`, `voice`, `response_format` ; `VoiceChoice.maxExtraEntries = 16` (choix non mesuré) ; `public var normalized: VoiceChoice` (modèle et identifiant rognés, vides → `nil` ; langue vide → `fr-FR` ; clés d'`extra` rognées ; clés vides ou réservées retirées ; au plus 16 entrées, dans l'ordre des clés).
- `public enum VoiceRoute: Equatable, Sendable { case system(language: String, identifier: String?, because: SystemReason?); case provider(Provider, ProviderVoice) }` ; `public enum SystemReason: Equatable, Sendable { case providerRemoved, providerCannotSpeak, incomplete }` ; `extension VoiceChoice { public func route(in settings: AppSettings) -> VoiceRoute }`.
- `LiveInterview.makeSystemVoice: @Sendable (_ language: String, _ identifier: String?) -> any SpeechSynthesizer` ; `main.swift` : `{ SystemSpeechSynthesizer(language: $0, identifier: $1) }`.
- `extension VoiceChoice { public func isSameVoice(as other: VoiceChoice) -> Bool }` : LA règle « cette ligne est la voix en vigueur ». Deux voix de fournisseur sont la même si leurs formes `normalized` sont égales par `==` (les six champs connus : fournisseur, modèle, identifiant, langue, genre, paramètres ; les champs inconnus ne comptent pas). Deux voix du système (sans fournisseur) sont la même si l'identifiant et la langue (comparée sans casse, `_` et `-` confondus) sont égaux ; genre et paramètres ne comptent pas. Une voix du système et une voix de fournisseur ne sont jamais la même. `settings.voice` ne porte pas d'identité de ligne : si plusieurs voix enregistrées sont la même voix, la première de la liste est cochée.

**Règles :**
1. Lecture : un fichier sans `voices` se lit (`[]`) ; une entrée dont l'`id` ou la `voice` est illisible n'empêche pas de lire les autres, et se retrouve octet pour octet (comparaison de `JSONValue`) dans le fichier réécrit ; un champ inconnu d'une entrée est gardé. `aFileWithoutVoicesReads`, `anUnreadableEntryIsKeptAndRewritten`, `unknownFieldsOfAnEntrySurvive`.
2. Écriture : `voices` n'est écrit que s'il n'est pas vide ou s'il était présent à la lecture (un fichier de l'étape 6 relu puis réécrit sans changement reste identique). `anUntouchedFileStaysIdentical`.
3. `normalized` : table de cas (clé réservée, clé vide, espaces, 17 entrées, modèle blanc) ; et ce qui part au fournisseur est toujours `normalized.extra` (test sur `LiveInterview.makeVoice` avec une fabrique double : aucune clé réservée ne lui arrive, même écrite à la main dans le fichier). `reservedKeysNeverReachTheProvider`.
4. `route(in:)`, table complète : sans fournisseur → `.system(langue, identifiant, nil)` ; fournisseur supprimé → `.system(…, .providerRemoved)` ; fournisseur au format sans synthèse → `.providerCannotSpeak` ; modèle ou identifiant blanc → `.incomplete` ; sinon `.provider`. Dans les trois cas de repli, l'identifiant rendu est `nil` (un identifiant de fournisseur n'est pas un identifiant de voix du système). `InterviewSetup.resolveVoiceProvider` et `InterviewSettingsModel.privacyText` sont réécrits pour passer par `route(in:)` ; un test paramétré donne les mêmes voix aux trois et vérifie que la ligne de vie privée ne nomme un fournisseur que pour `.provider`. `everyReaderAgreesOnWhoSpeaks`.
5. Voix du système désignée : `makeVoice(choice, nil)` passe `choice.identifier` à `makeSystemVoice` ; le repli d'une voix de fournisseur passe `nil`. `theSystemIdentifierReachesTheFactoryOnlyForASystemVoice`.
6. `isSameVoice(as:)`, table de cas : mêmes six champs → vrai ; un paramètre de plus, un genre différent, un autre modèle → faux (fournisseur) ; champ inconnu de plus → vrai ; espaces autour du modèle → vrai (normalisation) ; système : même identifiant et `fr-FR` contre `fr_fr` → vrai, genre différent → vrai, identifiant `nil` contre un identifiant → faux ; système contre fournisseur → faux. `theSameVoiceRuleHasItsTable`.

**Pannes volontaires :** règle 1 (jeter l'entrée illisible), règle 3 (ne pas normaliser avant la fabrique), règle 4 (`privacyText` qui ne teste que la présence du fournisseur).

- [ ] Tests rouges ; code ; verts ; commit par unité.

---

### Task 3: `VoicesModel` et `VoicePreview` — le modèle de l'onglet et l'écoute

**Files:**
- Create: `Sources/SupervoxApp/SettingsUI/VoicesModel.swift`, `Sources/SupervoxApp/SettingsUI/VoicesText.swift`, `Sources/SupervoxApp/Interview/VoicePreview.swift`, `Tests/SupervoxAppTests/VoicesModelTests.swift`, `Tests/SupervoxAppTests/VoicePreviewTests.swift`
- Modify: `Sources/SupervoxApp/Interview/InterviewEnvironment.swift`, `Sources/SupervoxApp/AppController.swift`, `Sources/Supervox/LiveInterview.swift`, `Sources/Supervox/main.swift`, `Tests/SupervoxCoreTests/SourceScanTests.swift`

**Interfaces — Consumes:** tâche 1 (`SystemVoiceInfo`, `ClipPlayer`), tâche 2 (`SavedVoice`, `VoiceRoute`, `normalized`), `ProviderResolver.resolve`, `InterviewEnvironment.makeVoice`.

**Interfaces — Produces:**
- `InterviewEnvironment` gagne `public var systemVoices: @Sendable () -> [SystemVoiceInfo]` (défaut `{ [] }`) et `public var makePlayer: @Sendable () -> any ClipPlayer` (défaut : un lecteur qui lève `Unavailable()`). `main.swift` donne `SystemVoices.installed` et `{ SystemClipPlayer() }`.
- `@MainActor public final class VoicePreview` : `init(makeVoice:makePlayer:resolve:sleep:)` ; `func start(_ choice: VoiceChoice, settings: AppSettings, onState: @escaping @MainActor (State) -> Void)` ; `func stop()` ; `enum State: Equatable { case idle, preparing, playing, failed(Failure) }` ; `enum Failure: Equatable { case notInstalled, unusable(SystemReason), provider(RewriteFailure), silent, timedOut, playback, unavailable }`. Une seule écoute à la fois. `static let limitSeconds: Double = 15` (choix non mesuré).
- `AppController.voicePreview: VoicePreview` (interne), coupé par `AppController` avant tout départ de dictée ou d'entretien.
- `@MainActor @Observable public final class VoicesModel` : `init(read:update:systemVoices:preview:)` ; `rows: [Row]` (sections « Voix du système » et « Voix de fournisseurs ») ; filtres `language: String?`, `gender: GenderFilter` ; `selection: Row.ID?` ; `use()`, `listen()`, `stopListening()`, `beginAdding()`, `beginEditing()`, `requestDeletion()`, `confirmDeletion()`, `cancelConfirmation()` ; brouillon `draft: VoiceDraft?` avec `save()` et `cancel()` ; `message`, `previewState`.
- `VoicesText` : toutes les phrases de l'onglet, fixes, passées par `InterviewText.fr`.

**Règles :**
1. Lignes : pour chaque langue installée, une ligne « Automatique » (meilleure voix de la langue, `identifier == nil`) puis une ligne par voix installée (nom, langue, genre ou « Genre non précisé », qualité) ; puis les voix enregistrées (nom, fournisseur, modèle). Ordre stable : langue, puis nom. `rowsListSystemThenSaved`.
2. La voix en vigueur est toujours présente et cochée (la ligne cochée est celle que `isSameVoice(as:)` désigne, la première s'il y en a plusieurs ; « modifier » et « supprimer la voix en vigueur » des règles 5 et 6 s'entendent de cette même ligne) : si elle n'est ni installée ni enregistrée, une ligne « Voix en vigueur » la montre, marquée « n'est plus installée » ou « n'est pas enregistrée ». `theActiveVoiceIsAlwaysListed`.
3. Une voix enregistrée dont `route(in:)` n'est pas `.provider` reste listée avec sa raison en clair (fournisseur supprimé ; ce fournisseur ne sait pas parler ; modèle ou identifiant manquant) ; « Utiliser cette voix » est désactivé pour elle. `anUnusableSavedVoiceIsListedAndSaysWhy`.
4. Filtres : la langue par défaut est celle de la voix en vigueur ; « Toutes les langues » montre tout ; le genre filtre (« Tous », « Féminin », « Masculin », « Neutre », « Non précisé ») ; la voix en vigueur reste visible quel que soit le filtre. `filtersNarrowButNeverHideTheActiveVoice`.
5. Brouillon d'une voix de fournisseur : nom, fournisseur (seulement ceux qui savent parler), modèle (liste du fournisseur, ou saisie libre), identifiant, langue, genre, paramètres (lignes clé et valeur). `save()` refuse, avec une phrase par cas et sans rien écrire : nom vide, aucun fournisseur, modèle vide, identifiant vide, clé de paramètre vide, clé réservée (la phrase nomme les quatre), clé en double, plus de 16 paramètres. Accepté : écrit `voices` par `update` en une fois (réglages en vigueur relus) ; modifier la voix en vigueur met aussi `settings.voice` à jour dans la même écriture. `everyRefusalHasItsSentenceAndWritesNothing`, `savingTheActiveVoiceUpdatesBoth`.
6. `use()` écrit `settings.voice` (une voix du système : `VoiceChoice(language:identifier:gender:)` sans fournisseur ; une voix enregistrée : son `voice.normalized`). Supprimer une voix enregistrée demande confirmation (« Supprimer cette voix ? ») ; supprimer la voix en vigueur remet la voix du système automatique en français et le dit. `useWritesOnlyTheVoice`, `deletingTheActiveVoiceFallsBackAndSaysSo`.
7. Écoute d'une voix du système : identifiant absent de `systemVoices()` → `.failed(.notInstalled)` sans appeler `makeVoice` ; sinon `makeVoice(choice, nil)`, `synthesize(phrase d'essai)`, puis `player.play`. Jamais de `FallbackSpeechSynthesizer` (garde de source : ce nom n'apparaît ni dans `VoicePreview.swift` ni dans `VoicesModel.swift`). `aMissingSystemVoiceIsSaidWithoutSynthesis`.
8. Écoute d'une voix de fournisseur : `route(in:)` ; pas `.provider` → la phrase de la raison ; sinon `resolve` (clé lue hors du fil principal), `makeVoice(choice, resolved)`, synthèse bornée par `limitSeconds` (attente injectée), lecture. Table des pannes, sans second classement : une panne de `resolve` est déjà une `RewriteFailure` → `.provider(elle)`, phrase = son `message` fixe ; une erreur de synthèse du fournisseur est classée par la fonction qui classe déjà les erreurs de l'endpoint en `RewriteFailure` pour la réécriture (`git grep -n "RewriteFailure" -- Sources` : la réutiliser ; si elle est privée ou mêlée au flux de texte, l'extraire, pas la recopier) → `.provider` ; un clip vide (0 échantillon) → `.silent` ; la borne `limitSeconds` → `.timedOut` ; `ClipPlayerError` → `.playback` ; fabrique ou lecteur absent → `.unavailable`. Chaque cas a sa phrase fixe ; le synthétiseur du système n'est JAMAIS appelé (double qui fait échouer le test s'il l'est). `aFailingProviderVoiceNeverSpeaksWithTheSystemVoice`, `everyPreviewFailureHasItsSentence`.
9. Arrêt : `stop()` annule la synthèse en cours et appelle `player.stop()` ; un second `start` arrête le premier ; l'état revient à `.idle` ; rien n'est joué après `stop()` même si la synthèse rend sa réponse ensuite. `AppController` appelle `voicePreview.stop()` avant le départ d'une dictée et d'un entretien (test de bout en bout avec doubles : l'ordre observé est « lecteur arrêté » puis « micro demandé »). `stopSilencesALateSynthesis`, `aDictationOrAnInterviewStopsThePreviewFirst`.
10. Phrase d'essai : fixe par langue primaire (`fr`, `en`, `es`, `de`, `it` ; autre → anglais), table dans `VoicesText`. Vie privée de l'onglet, phrases fixes : voix du système → rien n'est envoyé ; voix de fournisseur → « Écouter cette voix envoie la phrase d'essai à « … » et lit sa clé dans le trousseau. » `thePrivacyNoteFollowsTheRoute`.
11. Erreur d'écriture des réglages : la phrase de `SettingsError` ou la phrase fixe d'échec, jamais `localizedDescription` (garde de source étendue à `VoicesModel.swift`, `VoicesPane.swift`, `VoicePreview.swift`, `VoicesText.swift`).

**Pannes volontaires :** règle 2 (ne pas ajouter la ligne de la voix en vigueur), règle 5 (accepter une clé réservée), règle 8 (envelopper dans le repli), règle 9 (ne pas couper avant la dictée ; laisser jouer une synthèse tardive).

- [ ] Tests rouges ; code ; verts ; commit par unité. Toute attente de tâche des tests rend la main à l'annulation (`bounded`).

---

### Task 4: L'onglet « Voix » : vue, fenêtre, images

**Files:**
- Create: `Sources/SupervoxApp/SettingsUI/VoicesPane.swift`, `Tests/SupervoxAppTests/VoicesPaneLayoutTests.swift`
- Modify: `Sources/SupervoxApp/SettingsUI/SettingsView.swift`, `Sources/SupervoxApp/SettingsUI/InterviewPane.swift`, `Sources/SupervoxSnapshots/main.swift`, `Tests/SupervoxAppTests/SettingsWiringTests.swift`, `Tests/SupervoxAppTests/AppControllerHistoryTests.swift`, `Tests/SupervoxAppTests/WindowIntegrationTests.swift`

**Interfaces — Produces:** `SettingsTab.voices` (titre « Voix », image `speaker.wave.2`) ; ordre : Fournisseurs, Raccourci, Permissions, Transcription, Modes, Entretien, Voix, Historique (toujours dernier) ; visible quand l'entretien l'est. `SettingsView.init` gagne `voices: VoicesModel? = nil` ; `SettingsView.makeVoicesModel(controller)`.

**Règles :**
1. Disposition dans 600×460 : en haut les deux filtres sur une ligne ; au milieu la liste qui défile (sections, coche sur la voix en vigueur, raison en clair pour une voix inutilisable) ; en bas une bande de message de hauteur fixe (comme l'onglet Historique : un message ne déplace aucun bouton), puis une ligne de boutons : « Utiliser cette voix », « Écouter » (devient « Arrêter » pendant l'écoute, avec un indicateur d'activité pendant la préparation), « Ajouter une voix… », « Modifier… », « Supprimer… ». Test de disposition sans fenêtre : les cadres des boutons sont les mêmes avec et sans message, pour la phrase la plus longue de `VoicesText`. `aMessageNeverMovesTheButtons`.
2. Une seule feuille pour l'éditeur et la confirmation (plusieurs `.sheet` sur la même vue se disputent : constat de l'étape 6). L'éditeur tient dans 520×420 et défile si les paramètres sont nombreux.
3. Liste des onglets : tests existants mis à jour (`SettingsWiringTests`, `AppControllerHistoryTests`) ; `.history` reste dernier ; sans entretien, pas d'onglet Voix. `theVoicesTabSitsBetweenInterviewAndHistory`.
4. Onglet Entretien : sous la ligne de vie privée, un bouton « Choisir la voix… » qui mène à l'onglet Voix (`navigation.tab = .voices`). Sa hauteur est comptée dans le test de composition existant de l'onglet Entretien (il doit toujours tenir dans la fenêtre fixe).
5. Quitter l'onglet, fermer la fenêtre (`onLeave`) ou changer d'onglet appelle `voices.stopListening()` et annule une confirmation en attente. `leavingStopsThePreview`.
6. Images (clair et sombre, noms inventés seulement) : `reglages-voix` (voix du système, automatique cochée), `reglages-voix-fournisseur` (voix enregistrée en vigueur), `reglages-voix-inutilisable` (fournisseur supprimé), `reglages-voix-ecoute`, `reglages-voix-erreur` (phrase la plus longue), `reglages-voix-editeur` (deux paramètres), `reglages-voix-editeur-refus`, `reglages-voix-confirmation`, et `reglages-entretien` rendu de nouveau. Chacune ouverte et décrite dans le rapport.
6 bis. Logo : l'outil de rendu produit `logo-barre-de-menus-clair` et `-sombre` (l'image gabarit de `BrandMark.menuBarImage()` teintée comme le système la teinte : noire sur une barre claire, blanche sur une barre sombre, à 18 points, agrandie quatre fois pour être jugée) et `logo-application` (icône à 256 points sur fond clair et sombre). Aucune de ces images n'est suivie par git. Elles sont regardées : les cinq barres sont distinctes à 18 points dans les deux thèmes.
7. Test de fenêtre (derrière `SUPERVOX_WINDOWS=1`) : la vraie fenêtre des réglages, huit onglets, la barre d'onglets ne tronque aucun titre et la fenêtre garde 600 points de large (mesure des cadres des éléments de la barre). S'il ne peut pas être lancé (écran verrouillé : `ioreg -n Root -d1 -a | grep -c CGSSessionScreenIsLocked` rend 1), le rapport dit « non lancé », jamais « vert ». La barre est celle d'un `TabView` de SwiftUI (`SettingsView.swift`), dessinée par le système dans la fenêtre : la tâche établit si sa largeur est mesurable sans fenêtre (hébergement hors écran, comme les tests de disposition) ; si oui, un test de largeur des huit titres dans 600 points ; sinon le rapport, la PR et `docs/essai-final.md` disent « barre de huit onglets : non vue », jamais « tient ».

**Pannes volontaires :** règle 1 (message dans le flux), règle 3 (Voix après Historique), règle 5 (ne pas couper en quittant).

- [ ] Tests rouges ; code ; verts ; images regardées ; commit par unité.

---

### Task 5: Phrases fixes à la place des textes d'erreur du système

**Files:** Modify `Sources/SupervoxApp/AppController.swift`, `Sources/SupervoxApp/SettingsUI/HotKeySettingsModel.swift`, `Sources/SupervoxApp/SettingsUI/ProvidersModel.swift`, `Sources/SupervoxSnapshots/main.swift`, `Tests/SupervoxCoreTests/SourceScanTests.swift`, tests des trois modèles.

**Règles :**
1. Un avis d'enregistrement montre la phrase d'une `SettingsError` (déjà fixe, en français) ou, pour toute autre erreur, une phrase fixe qui dit quoi faire (« Les réglages n'ont pas pu être enregistrés : vérifiez que le disque n'est pas plein, puis recommencez. »). Jamais `localizedDescription`. Tests : une erreur étrangère au texte reconnaissable (`"TEXTE-BRUT"`) ne se retrouve dans aucun message, pour les cinq sites.
2. Journal : le type de l'erreur seulement (`String(reflecting: type(of: error))`), jamais son texte.
3. Garde de source : `localizedDescription` interdit dans tout `Sources/SupervoxApp` et `Sources/SupervoxSnapshots`, commentaires compris (les balayages lisent les lignes entières, aucun ne retire les commentaires : on ne commence pas ici) : le commentaire de `InterviewText.swift` qui cite ce nom est reformulé (« le texte d'erreur du système ») ; les deux sites de `SupervoxCore/Endpoint` (texte de transport masqué) restent, nommés dans la garde avec leur raison.

**Pannes volontaires :** remettre `localizedDescription` à un site : le test du site et la garde tombent.

- [ ] Tests rouges ; code ; verts ; commit.

---

### Task 6: Documents — essais de l'étape 7 et README

**Files:** Modify `docs/essai-final.md`, `README.md`.

**Règles :**
1. Essais, dans l'ordre où une personne les ferait, une action par ligne, résultat attendu, quoi noter sinon ; un essai qui joue un son le dit dans son titre. D'abord sans son (ouvrir l'onglet, filtres, huit onglets lisibles dans la barre, ajouter une voix de fournisseur avec les valeurs de ses notes personnelles, refus de l'éditeur, supprimer) ; puis avec son (le test matériel du lecteur avec sa commande exacte, écouter une voix du système, écouter la voix du fournisseur, écoute coupée par le raccourci de dictée, voix de fournisseur fausse qui échoue sans voix du système) ; puis un entretien avec la voix choisie (repli annoncé si le service ne répond pas).
2. Chaque phrase attendue est copiée du code (`VoicesText`), vérifiée par `git grep`.
3. README : section « Voix » (ce qui se règle, ce qui part chez le fournisseur, paramètres en texte, noms réservés, voix par défaut = voix du système), mise à jour de la section vie privée et de la liste des tests matériels.
4. Sections « Jamais exécuté pendant la construction » complétées : lecteur réel, liste réelle des voix, écoute réelle, barre de huit onglets si le test de fenêtre n'a pas tourné ; et deux lacunes de l'étape 6 : le bas de l'onglet Historique (ligne de durée et bouton « Confirmer ») jamais vu dans une vraie fenêtre, et le pipeline qui lance les tests en série.
5. Aucun nom de voix réelle, de modèle réel, de paramètre de serveur réel.

- [ ] Rédaction ; contrôle des termes interdits (0) ; commit.

---

## Incertitudes

- Le lecteur réel (`AVAudioPlayer` sur des octets WAV) n'est exécuté par aucun agent : son premier essai est celui de l'utilisateur.
- `AVSpeechSynthesisVoice.gender` rend souvent « non précisé » (lu dans la documentation, non mesuré sur cette machine) : le filtre par genre peut laisser beaucoup de voix sous « Non précisé ».
- La barre de huit onglets dans 600 points : non vue tant que l'écran est verrouillé.
- L'onglet Historique de l'étape 6 (ligne de durée et bouton dans le pied) n'a jamais été vu dans une vraie fenêtre : le test de fenêtre de la tâche 4, s'il peut tourner, est le premier à le montrer.
- Un serveur qui exige un paramètre supplémentaire numérique (et non en texte) refusera la requête : non établi pour un service donné.

## Décisions du constructeur

- **Liste de voix enregistrées en plus de la voix en vigueur** — le design dit « choix parmi des jeux de voix » et aucun fournisseur compatible n'expose de liste de voix normalisée ; coût : un champ de réglages de plus (additif, version inchangée).
- **Voix par défaut = voix du système**, pas celle de l'endpoint de l'utilisateur (design 6.5) — un dépôt public ne peut pas nommer cet endpoint ni sa voix ; coût : la personne saisit sa voix une fois dans l'onglet.
- **Paramètres supplémentaires en texte, quatre noms réservés** — c'est ce que la requête fait déjà ; coût : un serveur qui veut un nombre peut refuser.
- **L'écoute sans repli** — sinon une voix fausse « marche » ; coût : un échec d'écoute là où l'entretien, lui, continuerait avec la voix du système.
- **Lecteur de sortie seule distinct du moteur de l'entretien** — le moteur de l'entretien ouvre le micro pour jouer ; coût : un second chemin de lecture, non exercé par l'entretien.
- **Une variable à part, `SUPERVOX_PLAYER`, pour le test du lecteur** — `SUPERVOX_SPEAKER` active aussi des tests qui ouvrent le micro ; coût : une variable de plus à connaître.
- **« La voix en vigueur » se reconnaît par ses champs, pas par une identité de ligne** — `settings.voice` reste la seule chose que l'entretien lit, sans champ nouveau ; coût : deux voix enregistrées identiques ne se distinguent pas (la première est cochée).
- **Identifiant de voix du système absent pendant un entretien : meilleure voix de la langue, sans avis** — l'entretien ne doit jamais se taire ; coût : la voix entendue peut ne pas être celle choisie (l'onglet, lui, le montre).

## Auto-relecture

- Design 5.4 « par langue et par genre » → tâche 3 (règles 1 et 4), tâche 4 (règle 1). Design 6.5 (six champs, paramètres libres, secours) → tâche 2 (règles 3 et 4), tâche 3 (règle 5). « Tout configurable depuis l'interface » → tâche 3 (règles 5 et 6).
- Types cohérents entre tâches : `SystemVoiceInfo`/`SystemVoiceGender` (1 → 3), `ClipPlayer` (1 → 3), `SavedVoice`/`VoiceRoute`/`normalized` (2 → 3, 4), `VoicePreview` (3 → 4), `SettingsTab.voices` (4).
