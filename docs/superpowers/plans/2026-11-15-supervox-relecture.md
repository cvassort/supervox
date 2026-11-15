# Supervox — étape 4 : relecture — plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pour un mode dont le réglage « relire avant de coller » est activé, la fin d'une dictée n'envoie rien : le texte s'affiche dans le panneau, se corrige au clavier, puis « Coller » le colle dans l'application qui était au premier plan, ou « Copier » le copie. Rien n'est collé sans ce geste. À cette étape, seule la Dictée brute produit du texte : la relecture s'essaie en activant son réglage.

**Architecture:** Tout se passe dans `SupervoxApp`, qui ne dépend toujours que de `SupervoxCore` ; `SupervoxCore` n'est pas modifié. L'écran de la dictée reçoit son propre état (`DictationStage`), distinct de la phase de la session (constat m12), et le dernier texte n'a plus qu'un propriétaire, le contrôleur de dictée (m13). Le réglage par mode vit dans `AppSettings` (champ optionnel, sans nouvelle version du format) et se règle dans un nouvel onglet « Modes ». Le panneau, déjà `NSPanel` non activant, devient capable d'être clé pendant la relecture seulement : il reçoit la frappe sans activer Supervox, puis rend la frappe avant le ⌘V. Les commandes d'édition (⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A) sont traduites par le panneau lui-même, sans dépendre du menu principal.

**Tech Stack:** Swift 6 (tools 6.2), macOS 26+, Swift Testing, AppKit (`NSPanel` `.nonactivatingPanel`, `NSTextView`, `NSEvent`), SwiftUI, Carbon (Échap réservé, inchangé). Aucune dépendance nouvelle.

**Spec:** `docs/superpowers/specs/2026-11-12-supervox-design.md` — sections 2 (anti-objectif « un prompt collé sans relecture possible »), 5.1 (Relecture, Relecture réglable par mode), 5.2, 6.4, 6.6, 6.7, 7 (point 4), 8.

## Ce qui existe et que ce plan suppose (lu dans le code le 2026-11-15)

- `FloatingPanel` (`Panel/PanelController.swift`) : `styleMask` `[.borderless, .nonactivatingPanel]`, `canBecomeKey` et `canBecomeMain` toujours faux, montré par `orderFrontRegardless()`. Le test `WindowIntegrationTests.panelCanNeitherBecomeKeyNorMain` fixe ce comportement : **la tâche 3 le remplace**.
- Échap est un raccourci Carbon réservé tant que le panneau est ouvert (`PanelController.escape`) ; il est donc pris avant tout champ de texte du panneau.
- `MainMenu.make` (menu Édition) n'est posé qu'à `AppController.openSettings()` ; son commentaire dit que sans lui ⌘X, ⌘C, ⌘V, ⌘A ne font rien dans un champ.
- `DictationViewState.phase` est une `DictationPhase` de `SupervoxCore` ; `.finished(texte)` y sert d'état d'écran « Texte copié » (36 occurrences de `.finished(` dans `Sources/SupervoxApp`, `Sources/SupervoxSnapshots` et `Tests/SupervoxAppTests`, dont une partie sont des phases de session émises par `FakeSession`, qui restent).
- Le dernier texte est gardé deux fois : `DictationController.lastTranscript` et `PanelModel.lastTranscript` (relayé par `onTranscriptChange` dans `AppController`). `PanelModel.setTranscript` d'un texte blanc le remet à `nil`.
- `TextInserter.insert(_:) async -> InsertionOutcome` (`.pasted`, `.copied(reason:)`, `.clipboardRefused`, `.nothing`), `TextInserter.copy(_:) -> Bool` (copie ordinaire, non transitoire). Les raisons `.copied` disent « Le texte dicté est copié dans le presse-papiers… faites ⌘V ».
- Les modes sont des `ModeChip` fixes (`Panel/PanelModel.swift`) ; il n'existe aucun autre type « mode ». Réglages, modes et insertion sont dans `SupervoxApp`, pas dans `SupervoxCore`.
- `SettingsView.init` a 5 appels : 1 dans `SettingsView.content`, 4 dans `Sources/SupervoxSnapshots/main.swift`.

## Global Constraints

- Dépôt public : aucun nom d'entreprise ou d'employeur, aucune adresse de service réelle, aucun identifiant de modèle d'un fournisseur privé, aucun nom de personne, aucune clé, ni chemin personnel, dans un fichier suivi, un test, une fixture ou un message de commit. Exemples : `example.com`, textes inventés. La garde de commit locale ne se contourne jamais.
- Aucune clé d'API dans un fichier, un journal, un message d'erreur. Toute requête porteuse de clé passe par `EndpointSession` (cette étape n'en fait aucune).
- `SupervoxApp` ne dépend que de `SupervoxCore`. Seule la cible `Supervox` importe `SupervoxEngines`.
- Suite par défaut : aucun test n'ouvre le micro, ne télécharge, ne touche le presse-papiers général, ne poste de vrai ⌘V ni aucun événement clavier ou souris au système, n'affiche de fenêtre, ne touche le trousseau, les préférences, les vrais dossiers de l'utilisateur ni le réseau, ne lance l'application. Ce qui l'exige vit derrière `SUPERVOX_WINDOWS=1` (fenêtres hors écran, jamais montrées) ou `SUPERVOX_PASTEBOARD=1` (presse-papiers nommé).
- Aucun test ne dépend de la vitesse de la machine : attentes injectées, jamais de délai réel comme condition de réussite.
- TDD : test d'abord, échec constaté, code, succès, puis une panne volontaire qui fait tomber un test nommé dans le rapport. Tests non complaisants : chaque règle a un test qui échouerait sans elle. `swift build --build-tests` sans avertissement, `swift test` entier vert avant chaque commit.
- Rien n'est collé sans le geste de l'utilisateur : relecture activée, seul « Coller » (clic ou ⌘↩) colle ; Échap ferme sans coller ni copier.
- Le texte dicté et le texte édité sont privés : jamais dans un journal, un fichier ou un message.
- Jamais d'appel bloquant sur le fil principal.
- Réglages : tout nouveau champ est optionnel au décodage avec une valeur par défaut ; un nouveau cas d'énumération enregistrée exige une nouvelle `AppSettings.current` (règle d'`AppSettings.swift`). Tout est réglable depuis l'interface, aucun fichier à éditer.
- Textes d'interface en français accentué, phrases complètes, sans jargon, qui disent quoi faire.
- Chaque écran nouveau ou modifié est rendu en clair et en sombre par `supervox-snapshots`, et chaque image est regardée.
- `docs/essai-final.md` et `README.md` sont mis à jour dans la dernière tâche.

## Review Focus

1. **⌘V doit arriver dans l'application visée, pas dans le champ de relecture.** Le panneau rend la frappe avant l'insertion, dans cet ordre exact : état `pasting`, `setKeyboard(.none)`, attente de `focusHandoverDelay`, `insert`. Test : tâche 4, règle 5 (journal des doubles) ; à l'écran : essai manuel 35.
2. **Collage impossible** (Accessibilité absente, presse-papiers qui refuse, ⌘ encore tenu après ⌘↩) : le texte édité reste à l'écran, intact, avec la raison, et la frappe redevient disponible. Test : tâche 4, règles 7 et 8.
3. **Échap, fermeture par le menu, les Réglages ou Quitter, pendant la relecture ou le collage** : rien n'est collé ; le texte édité devient la « Dernière dictée » ; un texte vidé ne l'efface pas. Un collage qui aboutit après la fermeture ne touche plus rien. Test : tâche 4, règles 10, 11, 16 et 17, et un test par chemin dans `AppControllerDictationTests`.
4. **Fichier de réglages écrit par la version actuelle** : relu sans mise de côté ni perte, relecture par défaut juste, Entretien forcé même si le fichier dit faux. Test : tâche 2, règles 1 à 3.
5. **Texte vidé ou très long** : Coller et Copier sans effet sur un texte blanc ; un texte long défile dans un champ de hauteur bornée, le panneau ne sort pas de l'écran. Test : tâche 4, règle 9 ; tâche 5, règles 2 et 3, et les images.

## Constats reportés de l'étape 3 (`.superpowers/sdd/2026-11-14-supervox-dictee/final-review.md`)

- **m12** (`DictationPhase.finished` comme état d'écran) : intégré, tâche 1.
- **m13** (`lastTranscript` en double) : intégré, tâche 1.
- **m11** (identifiants en chaînes) : moitié « modes » intégrée, tâche 2 (le réglage est indexé par identifiant de mode). Moitié « moteurs » (`"whisperkit"`, `"parakeet"`) : **reporté à l'étape 5** — `TranscriptionSettings`, `TranscriptionModel` et `LiveDictation` ne sont pas touchés ici, et l'étape 5 fait des modes des données qui portent un moteur.
- **m5** (messages bruts des bibliothèques dans l'onglet Transcription) : **reporté à l'étape 5** — `TranscriptionModel` n'est pas touché ici ; à faire avant qu'un point d'accès passe par ce chemin, ce qui arrive à l'étape 5.
- **m10** (finalisation sans délai maximal) : **reporté à l'étape 5** — `DictationSession` n'est pas touchée ici ; l'étape 5 ajoute des attentes de modèle de langage qui demandent la même politique de délai.

---

### Task 1: État d'écran de la dictée et dernier texte unique (m12, m13)

Aucun changement de comportement : la suite existante passe après une migration mécanique, et les images de l'étape 3 sont les mêmes.

**Files:**
- Create: `Sources/SupervoxApp/Dictation/DictationStage.swift`
- Modify: `Sources/SupervoxApp/Dictation/DictationEnvironment.swift`, `Sources/SupervoxApp/Dictation/DictationController.swift`, `Sources/SupervoxApp/Panel/PanelModel.swift`, `Sources/SupervoxApp/Panel/PanelController.swift`, `Sources/SupervoxApp/Panel/PanelView.swift`, `Sources/SupervoxApp/Panel/DictationText.swift`, `Sources/SupervoxApp/AppController.swift`, `Sources/SupervoxSnapshots/main.swift`
- Test: migration de `DictationControllerTests.swift`, `AppControllerDictationTests.swift`, `DictationViewTests.swift`, `PanelControllerTests.swift`, `PanelModelTests.swift`, `DictationDoubles.swift`, `Tests/SupervoxTests/DictationEndToEndTests.swift` (lit `view.phase`) ; ajouts dans `DictationControllerTests.swift`, `PanelModelTests.swift`, `DictationViewTests.swift`

**Interfaces:**
- Consumes: `DictationPhase`, `DictationFailure` (`SupervoxCore`, inchangés).
- Produces:
  - `public enum DictationStage: Equatable, Sendable { case idle, preparing, recording, finalizing, review, pasting, copied, cancelled; case failed(DictationFailure) }` — `review` et `pasting` ne sont atteints qu'à la tâche 4 ; `copied` remplace `.finished(texte)` comme état d'écran (repli de l'insertion).
    - `public var isActive: Bool` — vrai pour `preparing`, `recording`, `finalizing` (même sens que l'actuel `DictationPhase.isActive`, qui est retiré de `SupervoxApp`).
    - `public var holdsPanel: Bool` — vrai si `isActive`, ou `review`, ou `pasting`.
  - `DictationViewState` : `phase: DictationPhase` devient `public var stage: DictationStage` ; ajout de `public var lastTranscript: String?`. `init(stage: DictationStage = .idle, liveText: String = "", levels: [Float] = [], elapsed: Double = 0, notice: String? = nil, lastTranscript: String? = nil)`.
  - `DictationController` : `lastTranscript` reste la seule copie stockée ; `onTranscriptChange` est retiré ; `setView` pose toujours `next.lastTranscript = lastTranscript`.
  - `PanelModel` : `lastTranscript` et `setTranscript(_:)` sont retirés ; `copyTranscript()` copie `dictation.lastTranscript`.
  - `DictationText.status(for stage: DictationStage) -> String` ; `DictationDisplay.init(state: DictationViewState, copy: CopyState = .idle)` (le texte récupérable vient de `state.lastTranscript`).

**Règles (chacune a son test) :**
- `view.lastTranscript == controller.lastTranscript` après chacun de ces événements : texte collé, repli copie, échec, annulation, Échap, fermeture du panneau, début d'une nouvelle dictée. Un échec ou une nouvelle dictée ne l'effacent pas.
- Repli `.copied(reason)` : `stage == .copied`, `notice == reason`, `lastTranscript ==` le texte ; libellé « Texte copié », comme avant.
- `PanelModel.copyState` revient à `.idle` quand `dictation.lastTranscript` change, quand une étape `isActive` commence, à l'ouverture et à la fermeture (ce que faisait `setTranscript`).
- `holdsPanel` : vrai pour `preparing`, `recording`, `finalizing`, `review`, `pasting` ; faux pour les autres. `PanelController.outsideClick` lit encore `stage.isActive` à cette tâche (la tâche 4 passe à `holdsPanel`).
- `DictationText.status(for:)` : chaque étape a un libellé non vide ; `review` → « À relire », `pasting` → « Collage… ».

- [ ] **Step 1: tests ajoutés** (miroir du dernier texte, remise à zéro de « Copier », libellés, `holdsPanel`). Échec attendu : types absents.
- [ ] **Step 2: migration** — `phase` → `stage` dans les sources et les tests ; chaque affirmation d'écran `.finished(t)` devient `.copied` avec `lastTranscript == t` ; les `.finished(t)` émis par `FakeSession` restent (ce sont des phases de session).
- [ ] **Step 3: images avant et après** — `supervox-snapshots` dans deux dossiers (avant la tâche, après) : même liste de fichiers ; `cmp` sur chaque paire ; toute image qui diffère est regardée et l'écart expliqué dans le rapport.
- [ ] **Step 4: pannes volontaires** — `setView` qui ne recopie plus `lastTranscript` ; repli `.copied` posé en `.idle` : chacune fait tomber un test nommé.
- [ ] **Step 5: Commit** — `refactor(dictée): état d'écran propre au contrôleur, un seul dernier texte`

### Task 2: Réglage « relire avant de coller » par mode, onglet Modes

**Files:**
- Create: `Sources/SupervoxApp/Settings/ModeOptions.swift`, `Sources/SupervoxApp/SettingsUI/ModesModel.swift`, `Sources/SupervoxApp/SettingsUI/ModesPane.swift`
- Modify: `Sources/SupervoxApp/Settings/AppSettings.swift`, `Sources/SupervoxApp/Panel/PanelModel.swift`, `Sources/SupervoxApp/Dictation/DictationController.swift`, `Sources/SupervoxApp/SettingsUI/SettingsView.swift`, `Sources/SupervoxSnapshots/main.swift`
- Test: `Tests/SupervoxAppTests/ModeOptionsTests.swift`, `Tests/SupervoxAppTests/ModesModelTests.swift`, ajouts dans `SettingsStoreTests.swift`, `SettingsWiringTests.swift`, `Tests/SupervoxCoreTests/SourceScanTests.swift`

**Interfaces:**
- Consumes: `ModeChip` (existant), `SettingsStore`, `AppController.updateSettings(_:)` (existants).
- Produces:
  - `extension ModeChip { public static let rawID = "dictee-brute"; public static let cleanedID = "dictee-nettoyee"; public static let promptID = "prompt"; public static let interviewID = "entretien" }` — `ModeChip.fixed`, `fallbackID`, `DictationController.rawModeID` et `AppSettings.defaults.lastModeID` s'en servent.
  - `public struct ModeOptions: Codable, Equatable, Sendable { public var reviewBeforePaste: Bool?; public init(reviewBeforePaste: Bool? = nil) }` — `nil` : la valeur par défaut du mode. Décodage tolérant (`decodeIfPresent`), pour que l'étape 5 y ajoute des champs.
  - `AppSettings` : `public var modeOptions: [String: ModeOptions]` (clé : identifiant de mode ; absent du fichier → `[:]`) ; `public func reviewsBeforePaste(_ modeID: String) -> Bool` ; `public static func reviewDefault(_ modeID: String) -> Bool` (vrai pour `promptID` et `interviewID`, faux sinon) ; `public static let alwaysReviewed: Set<String> = [ModeChip.interviewID]`. `AppSettings.current` reste 1 : aucune énumération enregistrée n'est ajoutée.
  - `@MainActor @Observable public final class ModesModel` : `public init(modes: [ModeChip], options: [String: ModeOptions], save: @escaping @MainActor ([String: ModeOptions]) throws -> Void)` ; `public private(set) var rows: [Row]` ; `public private(set) var message: String?` ; `public func setReview(_ on: Bool, for modeID: String)`. `public struct Row: Equatable, Identifiable, Sendable { public let id: String; public let title: String; public var reviews: Bool; public let isLocked: Bool; public let note: String? }`.
  - `SettingsTab.modes` ; `SettingsView.init(providers:hotKey:transcription:modes:permissions:openSystemSettings:initialTab:)` ; `SettingsView.makeModesModel(_ controller: AppController) -> ModesModel` (écrit par `updateSettings { $0.modeOptions = … }`).

**Règles (chacune a son test) :**
1. **Migration.** Une fixture JSON au format actuel, tous champs remplis (version 1, un fournisseur `example.com`, raccourci, `hotKeyBehavior` `hold`, `lastModeID` `prompt`, `systemConflictShown`, `transcription` avec vocabulaire) : décodée, chaque champ vaut l'attendu et `modeOptions == [:]` ; lue par `SettingsStore` dans un dossier temporaire : aucun avis, aucune copie mise de côté ; enregistrée puis relue : égale ; le JSON écrit garde toutes les clés d'origine avec leurs valeurs (comparaison des dictionnaires décodés, `modeOptions` mis à part).
2. **Défauts.** Sans choix enregistré : Dictée brute et Dictée nettoyée faux, Prompt vrai, Entretien vrai. Un objet d'options sans `reviewBeforePaste` prend le défaut. Un identifiant de mode inconnu dans `modeOptions` est gardé à l'aller-retour (modes personnalisés de l'étape 5).
3. **Entretien toujours.** Un fichier qui porte `"entretien": {"reviewBeforePaste": false}` donne `reviewsBeforePaste("entretien") == true` ; `setReview(false, for: interviewID)` ne change rien et n'appelle pas `save`.
4. **Enregistrement.** Chaque bascule appelle `save` une fois avec tout le dictionnaire ; si `save` lève, la ligne revient à l'ancienne valeur et `message` le dit ; l'enregistrement réussi suivant efface `message`. `message` ne porte jamais le texte d'une erreur étrangère (une erreur dont la description contient une adresse ne la fait pas apparaître) ; une `SettingsError` donne sa propre phrase.
5. **Câblage.** Par `SettingsView.makeModesModel` : la bascule de Dictée brute écrit `settings.json` par `updateSettings`, et `controller.settings.reviewsBeforePaste(ModeChip.rawID)` devient vrai.
6. **Identifiants.** `SourceScanTests` : sous `Sources/SupervoxApp`, les chaînes `"dictee-brute"`, `"dictee-nettoyee"` et `"entretien"` n'apparaissent que dans `Panel/PanelModel.swift` (`"prompt"`, trop courant, n'est pas balayé).
7. **Onglet « Modes ».** Une ligne par mode, dans l'ordre des pastilles, avec l'interrupteur « Relire avant de coller ». Entretien n'a pas d'interrupteur : la ligne dit « Toujours relu : l'entretien passe toujours par la relecture. ». Dictée nettoyée et Prompt portent la note « Ce mode arrive à une étape suivante ; ce réglage vaudra dès qu'il sera là. ». En tête : « Quand la relecture est activée, le texte s'affiche dans le panneau à la fin de la dictée : vous pouvez le corriger au clavier, puis choisir « Coller » ou « Copier ». Rien n'est collé sans votre geste. »

- [ ] **Step 1: tests des règles 1 à 6.** Échec attendu : types absents. **Step 2: implémentation.**
- [ ] **Step 3: onglet et images** — les 4 appels de `SettingsView` dans `supervox-snapshots` reçoivent `modes:` ; images `modes` (défauts) et `modes-erreur` (enregistrement refusé), clair et sombre ; regarder chacune.
- [ ] **Step 4: pannes volontaires** — Entretien non forcé à la lecture ; défaut de Prompt à faux ; pas de retour en arrière après un `save` qui lève.
- [ ] **Step 5: Commit** — `feat(réglages): relire avant de coller, par mode, onglet Modes`

### Task 3: Le panneau peut prendre la frappe sans activer Supervox

**Files:**
- Create: `Sources/SupervoxApp/Panel/PanelKeyboard.swift`, `Sources/SupervoxApp/Panel/ReviewTextView.swift`
- Modify: `Sources/SupervoxApp/Panel/PanelController.swift`, `Sources/SupervoxApp/Dictation/DictationEnvironment.swift`
- Test: `Tests/SupervoxAppTests/PanelKeyboardTests.swift`, ajouts dans `PanelControllerTests.swift` (`FakePanelSurface` journalise `setKeyboard`), `DictationDoubles.swift` (`FakeDictationPanel` journalise `setKeyboard`), `Tests/SupervoxTests/DictationEndToEndTests.swift` (son `Panel` privé est un autre conformant de `PanelOpening`), `WindowIntegrationTests.swift` (**remplace** `panelCanNeitherBecomeKeyNorMain`). Les seuls conformants, relevés par grep : `PanelOpening` — `PanelController`, `FakeDictationPanel`, `Panel` (fin-à-fin) ; `PanelSurface` — `FloatingPanelSurface`, `FakePanelSurface`.

**Interfaces:**
- Consumes: `PanelSurface`, `PanelOpening`, `FloatingPanel`, `FloatingPanelSurface` (existants).
- Produces:
  - `public enum PanelKeyboard: Equatable, Sendable { case none, available, focused }` — `none` : le panneau ne peut pas devenir clé (état actuel) ; `available` : il le peut sur un clic, mais rend la frappe tout de suite s'il l'a ; `focused` : il devient clé sans activer l'application et le champ de relecture prend la frappe.
  - `PanelSurface` : exigence `func setKeyboard(_ keyboard: PanelKeyboard)`, **sans** réalisation par défaut. `PanelOpening` : même exigence.
  - `PanelController.setKeyboard(_:)` — sans effet panneau fermé ; toute fermeture pose `.none` sur la surface avant `hide()`.
  - `public enum EditingCommand: Equatable, Sendable { case undo, redo, cut, copy, paste, selectAll }` ; `public enum PanelEditingKeys { public static func command(characters: String, modifiers: NSEvent.ModifierFlags) -> EditingCommand?; public static func selector(for command: EditingCommand) -> Selector }`.
  - `FloatingPanel` : `var keyboard: PanelKeyboard = .none` ; `canBecomeKey` vrai si `keyboard != .none` ; `canBecomeMain` toujours faux ; `performKeyEquivalent(with:)` laisse d'abord la vue SwiftUI répondre, puis traduit une commande d'édition en `NSApp.sendAction(selector, to: nil, from: self)`.
  - `FloatingPanelSurface.setKeyboard(_:)` : `focused` → `makeKey()` ; `available` ou `none` alors que le panneau est clé → `orderOut(nil)` puis `orderFrontRegardless()`, pour que la fenêtre de l'application au premier plan reprenne la frappe.
  - `struct ReviewTextView: NSViewRepresentable` : `init(text: String, isEditable: Bool, takesFocus: Bool, onEdit: @escaping @MainActor (String) -> Void)` ; `static func makeTextView() -> NSTextView` (configuration testée) ; à la mise à jour, la chaîne n'est remplacée que si elle diffère de celle du champ (le curseur et l'annulation ne sautent pas) ; avec `takesFocus`, le champ devient premier répondeur dès que les deux conditions sont réunies, dans n'importe quel ordre : il est dans la fenêtre (`viewDidMoveToWindow`) et la fenêtre est clé (`NSWindow.didBecomeKeyNotification`). `setKeyboard(.focused)` part en effet au changement d'étape, avant que SwiftUI ait posé le champ.

**Règles (chacune a son test) :**
- `PanelEditingKeys` : ⌘z → `undo` ; ⇧⌘z (caractère `z` ou `Z`) → `redo` ; ⌘x, ⌘c, ⌘v, ⌘a → `cut`, `copy`, `paste`, `selectAll` ; avec ⌥ ou ⌃ en plus → `nil` ; sans ⌘ → `nil` ; une autre lettre → `nil`. Sélecteurs : `undo:`, `redo:`, `cut:`, `copy:`, `paste:`, `selectAll:`. Lecture sur `charactersIgnoringModifiers`, pour suivre la disposition du clavier (⌘Z en AZERTY).
- `PanelController` : `setKeyboard` panneau fermé n'atteint pas la surface ; ouvert → la surface reçoit la valeur ; fermeture → `.none` puis `hide`, dans cet ordre (journal du double) ; réouverture : aucune valeur reportée de la fois précédente.
- `ReviewTextView.makeTextView()` : `isRichText` faux, `importsGraphics` faux, `allowsUndo` vrai, substitutions automatiques des guillemets, des tirets et du texte, correction orthographique automatique, détection des liens et des données désactivées (rien ne modifie un prompt dans le dos de l'utilisateur) ; police `callout` du système.
- Intégration (`SUPERVOX_WINDOWS=1`, fenêtre hors écran jamais montrée, aucun événement posté au système) : `FloatingPanel` ne peut devenir clé qu'avec `available` ou `focused`, jamais principal ; avec `ReviewTextView` et `focused`, le premier répondeur est le `NSTextView`, dans les deux ordres (fenêtre rendue clé puis champ ajouté, champ ajouté puis fenêtre rendue clé) ; `insertText` puis `undoManager?.undo()` rend le texte d'avant ; un `NSEvent` ⌘Z fabriqué et passé directement à `performKeyEquivalent` annule de même ; `NSApp.isActive` ne change pas.

- [ ] **Step 1: tests par défaut** (`PanelEditingKeys`, `PanelController`, `makeTextView`). **Step 2: implémentation.** **Step 3: tests d'intégration** et leur exécution avec `SUPERVOX_WINDOWS=1`, résultat dans le rapport.
- [ ] **Step 4: pannes volontaires** — `.none` non posé à la fermeture ; `allowsUndo` faux ; ⌥⌘z accepté comme annulation.
- [ ] **Step 5: Commit** — `feat(panneau): frappe possible sans activer l'application, commandes d'édition`

### Task 4: La relecture dans le contrôleur de dictée

**Files:**
- Modify: `Sources/SupervoxApp/Dictation/DictationController.swift`, `Sources/SupervoxApp/Dictation/DictationEnvironment.swift`, `Sources/SupervoxApp/Panel/PanelModel.swift`, `Sources/SupervoxApp/Panel/PanelController.swift`, `Sources/SupervoxApp/AppController.swift`
- Test: `Tests/SupervoxAppTests/DictationReviewTests.swift`, ajouts dans `AppControllerDictationTests.swift`, `PanelControllerTests.swift`, `PanelModelTests.swift`, `DictationDoubles.swift` ; `InsertionRig` et son `CallLog` (`TextInserterTests.swift`) sont partagés avec le double du panneau pour journaliser l'ordre des appels

**Interfaces:**
- Consumes: `DictationStage`, `DictationViewState.lastTranscript` (Task 1) ; `AppSettings.reviewsBeforePaste(_:)`, `ModeChip.rawID`, `ModesModel.setReview(_:for:)`, `SettingsView.makeModesModel(_:)` (Task 2) ; `PanelKeyboard`, `PanelOpening.setKeyboard(_:)` (Task 3) ; `TextInserter.insert(_:)`, `TextInserter.copy(_:)`, `InsertionOutcome` (existants).
- Produces:
  - `TextInserter` (`Sources/SupervoxApp/Insertion/`, à modifier, avec ses tests dans `TextInserterTests.swift`) : `insert(_ text: String, leaveCopied: Bool) async -> InsertionOutcome` ; `insert(_:)` reste et vaut `leaveCopied: false` (dictée sans relecture, étape 3 inchangée). Avec `leaveCopied: true` (design 5.1 : le geste « le colle… et le copie »), après le ⌘V le presse-papiers d'origine n'est **pas** rendu et le texte y reste comme une copie ordinaire (non transitoire) ; les replis `.copied(reason)` et `.clipboardRefused` sont inchangés ; une annulation avant le ⌘V rend toujours le presse-papiers d'origine.
  - `DictationViewState` : `public var draft: String` (texte en relecture, `""` hors relecture), paramètre `draft: String = ""` de l'init.
  - `DictationController.init` gagne, après `hold:`, `reviewBeforePaste: @escaping @MainActor (String) -> Bool = { _ in false }` et `wait: @escaping @MainActor (Double) async -> Void = { try? await Task.sleep(for: .seconds($0)) }`.
  - `public static let focusHandoverDelay = 0.15` — délai entre le retrait de la frappe et l'insertion ; choix non mesuré.
  - `public static let reviewClipboardNotice = "Le presse-papiers a refusé le texte : il n'a été ni collé ni copié. Il est toujours ci-dessus : réessayez « Coller » ou « Copier »."`
  - `public func reviewEdited(_ text: String)` ; `public func pasteReview()`.
  - Une relecture est un objet privé `Review`, relu comme une `Run` (`isLive`) : la relecture finie, aucun résultat qui la concerne ne touche plus l'écran ni le panneau.
  - `PanelModel` : `public func editDraft(_ text: String)` et `@ObservationIgnored public var onDraftChange: (@MainActor (String) -> Void)?` ; `public func paste()` et `@ObservationIgnored public var onPaste: (@MainActor () -> Void)?` ; `public var canPaste: Bool` (étape `review` et `draft` non blanc) ; `copyTranscript()` copie `dictation.draft` en `review`, `dictation.lastTranscript` ailleurs, et ne fait rien d'un texte blanc.
  - `AppController` : `reviewBeforePaste: { relay.settings?()?.reviewsBeforePaste($0) ?? false }` ; `panelModel.onDraftChange` → `dictation.reviewEdited` ; `panelModel.onPaste` → `dictation.pasteReview`.

**Règles (chacune a son test ; doubles : session, insertion `InsertionRig`, panneau qui journalise ; `wait` journalise ses durées) :**
1. Le réglage est lu **une fois, à l'appui** qui commence la dictée, pour le mode choisi (comme bascule ou maintien) ; le changer pendant l'enregistrement ne change pas cette dictée.
2. Relecture désactivée : comportement de l'étape 3 inchangé (la suite existante passe sans modification de ses attentes).
3. Relecture activée, texte final non blanc : étape `review`, `draft ==` le texte, `lastTranscript ==` le texte, panneau ouvert, `setKeyboard(.focused)` appelé une fois ; `insert` n'est **jamais** appelé, même après la fin du flux de la session et l'écoulement des tâches. Texte final blanc : échec « aucune parole », comme avant.
4. `reviewEdited(t)` en `review` : `draft == t` ; hors `review` : ignoré. `lastTranscript` ne change qu'à la fermeture ou au collage.
5. `pasteReview()` en `review`, `draft` non blanc, dans cet ordre exact : étape `pasting` et `lastTranscript = draft`, `setKeyboard(.none)`, `wait(focusHandoverDelay)`, `insert(draft, leaveCopied: true)`. Par la file d'insertion existante (`insertionTail`) : `isInserting` est vrai pendant ce temps. Un second `pasteReview()` pendant `pasting` est ignoré (un seul `insert`).
6. `.pasted` → étape `idle`, panneau fermé, `lastTranscript ==` le texte collé ; le presse-papiers (double) contient le texte collé, pas le contenu d'origine. Tests de `TextInserter` : `leaveCopied: true` laisse le texte en copie ordinaire après le ⌘V ; `leaveCopied: false` rend l'origine comme avant ; annulé avant le ⌘V, l'origine est rendue dans les deux cas.
7. `.copied(reason)` → étape `review`, `notice == reason` (phrases de l'étape 3, inchangées), `draft` intact, `setKeyboard(.available)`, panneau ouvert.
8. `.clipboardRefused` → étape `review`, `notice == reviewClipboardNotice`, `draft` intact, `setKeyboard(.available)`.
9. `draft` blanc : `pasteReview()` ne fait rien (aucun `insert`, aucun `setKeyboard`) ; `canPaste` faux ; `copyTranscript()` ne copie rien et laisse `copyState` à `.idle`.
10. Échap en `review` → panneau fermé, aucun `insert`, aucune copie ; `lastTranscript = draft` s'il n'est pas blanc, sinon le texte d'origine reste. Même règle pour `panelClosedByUser()` ; `AppControllerDictationTests` le prouve pour chaque chemin : menu « Fermer le panneau », « Réglages… », « Quitter Supervox ».
11. Échap en `pasting` → la tâche d'insertion est annulée (avant le ⌘V, `TextInserter` ne colle rien et rend le presse-papiers) ; panneau fermé ; `lastTranscript == draft`.
12. Raccourci en `review` ou `pasting` : l'appui est ignoré (aucune session fabriquée, étape inchangée), en bascule comme en maintien ; le relâchement est ignoré. Même chose après un changement de pastille vers un autre mode pendant la relecture (aujourd'hui, `begin()` fermerait le panneau dans ce cas) : le panneau reste ouvert, la relecture intacte. `isBusy` est faux en `review` (la relecture n'utilise aucun modèle).
13. Clic en dehors : ignoré tant que `stage.holdsPanel` (`PanelController.outsideClick`) ; en `copied` ou `idle`, il ferme comme avant.
14. Changement de pastille en `review` : `draft` et étape inchangés, `lastModeID` enregistré ; la dictée suivante suit le nouveau mode.
15. « Copier » en `review` : copie `draft` entier par `inserter.copy` ; `copyState` `copied` ou `failed` ; panneau ouvert, étape `review` ; une modification du texte remet `copyState` à `.idle`.
16. Un résultat d'insertion qui arrive après la fin de la relecture (Échap une fois le ⌘V posté, puis éventuellement une nouvelle dictée) ne change ni l'écran ni le panneau : test avec `insert` retenu par le test puis relâché.
17. Échap pendant l'attente de `focusHandoverDelay` (attente retenue par le test) : `insert` n'est jamais appelé.
18. De bout en bout (`AppControllerDictationTests`, session double et `InsertionRig`) : la bascule de Dictée brute par `ModesModel` puis une dictée mène à `review` ; `panelModel.paste()` mène au journal d'insertion de la règle 5.

- [ ] **Step 1: tests des règles 1 à 18.** Échec attendu : membres absents. **Step 2: implémentation.**
- [ ] **Step 3: pannes volontaires** — `insert` appelé à la fin d'une dictée en relecture ; `insert` avant `setKeyboard(.none)` ; Échap qui ne garde pas `draft` ; clic en dehors qui lit `isActive` au lieu de `holdsPanel` : chacune fait tomber un test nommé.
- [ ] **Step 4: Commit** — `feat(relecture): texte à relire, Coller qui rend la frappe, Copier, Échap sans collage`

### Task 5: La vue de relecture et ses images

**Files:**
- Create: `Sources/SupervoxApp/Panel/ReviewView.swift`
- Modify: `Sources/SupervoxApp/Panel/DictationView.swift`, `Sources/SupervoxApp/Panel/DictationText.swift`, `Sources/SupervoxApp/Panel/PanelView.swift`, `Sources/SupervoxSnapshots/main.swift`
- Test: ajouts dans `Tests/SupervoxAppTests/DictationViewTests.swift`

**Interfaces:**
- Consumes: `DictationViewState.draft`, `DictationStage` (Tasks 1 et 4) ; `ReviewTextView` (Task 3) ; `PanelModel.editDraft`, `paste`, `canPaste`, `copyTranscript`, `copyState` (Task 4).
- Produces:
  - `DictationDisplay.Mood` gagne `.review` ; `public struct Review: Equatable, Sendable { public var text: String; public var isEditable: Bool; public var canPaste: Bool; public var canCopy: Bool; public var isPasting: Bool; public var copy: CopyState }` ; `public var review: Review?`.
  - `public static let reviewHint = "⌘↩ colle le texte. Échap ferme sans coller ; le texte reste dans « Dernière dictée »."` ; `public static let editorMinHeight: CGFloat = 62` ; `public static let editorMaxHeight: CGFloat = 242` ; `public static func editorHeight(contentHeight: CGFloat) -> CGFloat` (dans `DictationText`).
  - `ReviewView` : titre « À relire », le champ (`ReviewTextView`, éditable en `review`, en lecture seule en `pasting`), la raison d'un échec de collage, « Copier » (avec « Copié » ou « Copie impossible »), « Coller » en action principale (`.borderedProminent`, `.keyboardShortcut(.return, modifiers: .command)`), la ligne d'aide. En `pasting` : indicateur d'attente et « Collage… », boutons inactifs. Aucun bouton « Corriger à la voix ».

**Règles (chacune a son test, sauf la dernière, vérifiée sur les images) :**
1. En `review` et `pasting` : `review` non nul, `transcript` nul (la carte « Dernière dictée » ne s'affiche pas en même temps), pas de texte en direct, `detail == notice`. Hors relecture : `review` nul.
2. `canPaste` et `canCopy` faux pour un texte blanc ou en `pasting` ; `isEditable` faux en `pasting`.
3. `editorHeight` : borne basse 62 points (quatre lignes de `callout` à 15 points plus 2, la même mesure que le texte en direct, relevée sur les images de l'étape 3 : commentaire de `DictationView.swift`) ; borne haute 242 points (seize lignes, choix non mesuré) ; au-delà, le champ défile. 0 → 62, 100 → 100, 10 000 → 242, négatif ou non numérique → 62. Le panneau reste borné à la zone utile de l'écran (`PanelController.resizedFrame`, existant).
4. Images, clair et sombre : `relecture-courte`, `relecture-longue` (texte plus long que seize lignes, barre de défilement), `relecture-vide`, `relecture-collage`, `relecture-copie-sans-accessibilite` (raison réelle de l'insertion, obtenue comme `accessibilityReason()`), `relecture-presse-papiers-refuse`, `relecture-copiee`, `relecture-copie-impossible`. Regarder chacune ; corriger ce qui est coupé ou illisible ; **vérifier que le texte du champ système apparaît bien sur l'image** (la copie hors écran a déjà rendu blanche la barre d'onglets) ; s'il n'apparaît pas, le dire dans le rapport et dans la liste d'essai plutôt que de maquiller l'image.

- [ ] **Step 1: tests de `DictationDisplay` et `editorHeight`.** **Step 2: la vue.** **Step 3: images, regardées une à une, décrites dans le rapport.**
- [ ] **Step 4: pannes volontaires** — carte « Dernière dictée » montrée pendant la relecture ; borne haute retirée.
- [ ] **Step 5: Commit** — `feat(panneau): vue de relecture, Coller et Copier`

### Task 6: Liste d'essai et README

**Files:**
- Modify: `docs/essai-final.md`, `README.md`

**Règles :**
- `docs/essai-final.md` : section « Étape 4 — relecture » insérée avant « Retour à faire », qui reste la dernière et prend le numéro suivant. L'état de départ de « Avant de commencer » ajoute « relecture désactivée pour Dictée brute ». Chaque essai : les gestes, puis le résultat attendu ; ce qui n'a jamais été vu est marqué **comportement à confirmer**. Essais, numérotés à partir de 32 :
  32. Onglet Modes : activer « Relire avant de coller » pour Dictée brute ; Entretien dit « Toujours relu ». Quitter, relancer : le choix est gardé.
  33. Fichier de l'étape 3 : avant de lancer cette version, copier `settings.json` ailleurs ; après le lancement, rien n'a été mis de côté, raccourci, fournisseurs et réglages de transcription sont là. Au premier enregistrement (changement de pastille, par exemple), le fichier gagne `"modeOptions": {}` (encodage synthétisé d'`AppSettings`) ; il ne porte un choix qu'après une bascule dans l'onglet Modes.
  34. Dicter : le texte s'affiche, le curseur est dans le champ, la frappe y va **sans cliquer** ; la barre de menus reste celle de l'application de dessous (Supervox n'est pas activée). **Comportement à confirmer.**
  35. Coller (clic) puis ⌘↩, dans une application de notes, Terminal et un champ de navigateur : le texte édité arrive à l'endroit du curseur de l'application d'origine, pas dans le panneau ; le panneau se ferme ; un second ⌘V ailleurs colle encore le texte (il reste copié, design 5.1). **Comportement à confirmer.**
  36. Édition : taper, effacer, ⌘A, ⌘X, ⌘C, ⌘V, ⌘Z et ⇧⌘Z dans le champ, juste après le lancement (sans avoir ouvert les Réglages), puis après les avoir ouverts ; aussi en AZERTY. Guillemets droits et doubles tirets ne sont pas transformés.
  37. Accents : touche morte (^ puis e), appui long sur « e » et choix dans le menu d'accents. Échap pendant ce menu ferme le panneau sans coller (Échap est réservé) : le noter. **Comportement à confirmer.**
  38. Pendant la relecture, cliquer dans une autre application : le panneau reste ; recliquer dans le champ : la frappe revient ; Coller colle dans l'application cliquée en dernier.
  39. Copier : « Copié », le panneau reste ; ⌘V ailleurs colle le texte édité.
  40. Échap, puis rouvrir par le menu de l'icône : « Dernière dictée » montre le texte édité. Même essai en fermant par « Fermer le panneau » et par « Réglages… ».
  41. Raccourci pendant la relecture, en bascule puis en maintien : rien ne se passe.
  42. Vider le texte : Coller et Copier inactifs ; Échap : la dernière dictée reste le texte d'origine.
  43. Une dictée d'une à deux minutes : le champ défile, le panneau ne dépasse pas l'écran (aussi sur l'écran le plus petit disponible).
  44. Sans Accessibilité : Coller → le message de l'étape 3, le texte reste à l'écran ; cliquer dans le champ visé et faire ⌘V colle le texte. Avec ⌘ tenu longtemps après ⌘↩ : repli copie et son message.
  45. Changer de pastille pendant la relecture : le texte reste ; la dictée suivante suit le nouveau mode.
  46. Relecture désactivée : la dictée se colle d'elle-même, comme à l'étape 3.
- Une liste « Non vérifié automatiquement » en tête de la section : retour de la frappe à l'application d'origine, absence d'activation de Supervox, ⌘↩ dans un panneau non activant, commandes d'édition, touches mortes et menu d'accents, rendu du champ sur les images (selon la tâche 5), délai `focusHandoverDelay` non mesuré.
- `README.md` : section « Relecture » sous « Dictée » (ce qui marche ; où se règle la relecture ; Coller, ⌘↩, Copier, Échap ; Coller colle le texte et le laisse copié dans le presse-papiers, alors qu'une dictée sans relecture rend le presse-papiers d'origine ; le texte édité n'est gardé qu'en mémoire) ; la liste des images de « Rendre les écrans en images » et la liste des onglets des réglages mises à jour.

- [ ] **Step 1: `docs/essai-final.md`.** **Step 2: `README.md`.** **Step 3: relire les deux contre le code** (chaque résultat attendu correspond à une règle testée ou est marqué à confirmer ; aucun texte dicté, nom ni adresse réelle).
- [ ] **Step 4: Commit** — `docs: relecture, liste d'essai de l'étape 4`

---

## Incertitudes (non établies en lisant le code)

- Qu'un `NSPanel` non activant devenu clé laisse Supervox inactive, et que la frappe revienne d'elle-même à l'application de dessous après `orderOut` : rappel de la doc d'AppKit, non relu ; seul un vrai écran le dira (essais 34, 35).
- Que les raccourcis du menu principal soient consultés quand l'application n'est pas active : inconnu, d'où la traduction par le panneau.
- Que le raccourci Carbon d'Échap passe avant un `NSTextView` de la même application, et ce qu'il fait au menu d'accents : déduit, non vu (essai 37).
- Que `.keyboardShortcut` de SwiftUI fonctionne dans un panneau non activant : non vérifié.
- Que `cacheDisplay` rende le texte d'un `NSTextView` hors écran : non vérifié (tâche 5, règle 4).
- La durée nécessaire entre le retrait de la frappe et le ⌘V : aucune mesure ; 0,15 s est un choix.

## Décisions du constructeur

« Commande » : décision donnée avec la commande de ce plan, appliquée telle quelle. « Seul » : prise en écrivant ce plan.

| Décision | Raison | Coût si elle est fausse |
|---|---|---|
| Relecture par mode : désactivée pour Dictée brute et nettoyée, activée pour Prompt, toujours pour Entretien, réglée dans l'interface (commande) | Design 5.1 | — |
| Aucun bouton « Corriger à la voix », ni inactif (commande) | Étape 5 | — |
| Annulation par celle du champ du système, ⌘Z (commande) | La plus simple | Pas d'annulation après fermeture du panneau |
| Échap ferme sans coller ; le texte reste dans « Dernière dictée », en mémoire seulement (commande) | L'historique sur disque (6.7) n'est pas de cette étape | Un texte édité est perdu en quittant l'application |
| Copier ne ferme pas le panneau et le dit (commande) | — | — |
| `modeOptions: [String: ModeOptions]`, `Bool?` = défaut, sans nouvelle version (seul) | Aucune énumération ajoutée, donc pas de version selon la règle d'`AppSettings` ; un défaut changé plus tard vaut pour qui n'a rien choisi | L'étape 5 peut ranger les options dans des modes-données et devoir migrer ; une ancienne version qui réenregistre le fichier perd le champ |
| Le réglage est lu à l'appui, pas à la fin (seul) | Même règle que bascule ou maintien (`Run.startedByHold`) | Une bascule pendant une dictée ne vaut qu'à la suivante |
| Entretien montré par une phrase, pas par un interrupteur grisé (seul) | Un contrôle inactif n'apprend rien | Aucun |
| Le panneau devient clé seulement pendant la relecture, sans activer Supervox (`.nonactivatingPanel` déjà posé, `canBecomeKey` conditionnel) (seul) | Le mécanisme le plus simple, sans permission ; la doc d'AppKit dit qu'un tel panneau reçoit la frappe sans activer son application (non relue pour ce plan) | Si Supervox s'active ou si la frappe ne revient pas, il faudra noter l'application au premier plan et la réactiver (`NSRunningApplication.activate`), ce que l'activation coopérative récente peut refuser : non vérifié |
| Rendre la frappe par `orderOut` puis `orderFrontRegardless`, puis attendre 0,15 s avant l'insertion (seul) | Il n'existe pas d'appel public « rendre la touche clé à une autre application » | Non mesuré : un délai trop court colle dans le vide ou dans le panneau ; seul l'essai 35 le dira |
| Commandes d'édition traduites par `FloatingPanel.performKeyEquivalent`, sans le menu principal (seul) | `MainMenu` n'est posé qu'à l'ouverture des Réglages, et une application inactive ne sait pas s'il serait consulté | Les dispositions où ⌘ suit le QWERTY (« Dvorak – QWERTY ⌘ ») peuvent mal lire la lettre |
| ⌘↩ par `.keyboardShortcut` de SwiftUI (seul) | Retour seul insère une ligne | Si SwiftUI ne le reçoit pas dans un panneau non activant, l'ajouter à `PanelEditingKeys` (une ligne) |
| `NSTextView` enveloppé plutôt que `TextEditor` (seul) | Couper guillemets typographiques, tirets et remplacements, qui modifieraient un prompt ; `allowsUndo` explicite | Une centaine de lignes de plus |
| Clic en dehors ignoré pendant la relecture (seul) | Comme pendant la dictée : le clic sert à choisir où coller | On ne ferme pas d'un clic ; Échap ou le menu |
| Raccourci ignoré pendant la relecture (seul) | Ne pas perdre un texte en cours ; laisser la touche libre pour « Corriger à la voix » (étape 5) | Une touche de plus (Échap) avant une nouvelle dictée |
| Échap et toute fermeture gardent le texte **édité** comme « Dernière dictée » ; un texte vidé garde l'original (seul) | Ce que l'utilisateur a corrigé est ce qu'il voudra récupérer | Le texte brut d'origine est perdu après une correction |
| Après un collage impossible, le panneau reste ouvert mais sans la frappe (`available`) (seul) | Le ⌘V que la raison conseille doit aller à l'application visée | Il faut recliquer dans le champ pour corriger encore |
| Coller de la relecture colle **et laisse le texte copié** (`leaveCopied: true`) ; la dictée sans relecture rend toujours le presse-papiers d'origine (tranché à la relecture du plan) | Design 5.1, décidé par l'utilisateur : « un geste le colle dans l'application active et le copie » ; 6.7 vaut pour l'insertion directe | Le contenu d'origine du presse-papiers est perdu après un Coller de relecture |
| **Écart à « mêmes messages qu'à l'étape 3 »** : les raisons `.copied` sont reprises mot pour mot ; celle du presse-papiers refusé est adaptée (`reviewClipboardNotice`) (seul) | Le message de l'étape 3 renvoie à « Dernière dictée, ci-dessous », absente pendant la relecture : il serait faux | Une phrase de plus à maintenir |
| La relecture ne compte pas dans `isBusy` (seul) | Elle n'utilise aucun modèle : supprimer un modèle pendant ce temps est sans danger | Aucun connu |
| Changer de pastille ne touche pas la relecture (seul) | À cette étape, un texte relu ne dépend d'aucun mode | L'étape 5 pourrait vouloir retraiter le texte selon le nouveau mode |
| Hauteur du champ 62 à 242 points, puis défilement (seul) | 62 : mesure existante ; 242 : seize lignes, choix | Non mesuré sur un petit écran ; essai 43 |
| Tous les cas de `DictationStage` posés dès la tâche 1 (seul) | Les tâches suivantes n'ont pas à rouvrir les `switch` | Deux cas inatteignables pendant une tâche |
