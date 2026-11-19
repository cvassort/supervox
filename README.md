# supervox

[![Tests](https://github.com/cvassort/supervox/actions/workflows/tests.yml/badge.svg)](https://github.com/cvassort/supervox/actions/workflows/tests.yml)

supervox est une application macOS de dictée et d'entretien vocal. Elle est en cours de construction.
Ce dépôt contient l'application telle qu'elle est (le socle, la dictée, sa relecture, les modes à consigne, la correction
à la voix, l'entretien vocal et le réglage de sa voix, voir « Application », « Dictée », « Relecture », « Modes »,
« Corriger à la voix », « Entretien » et « Voix ») et le banc d'essai : `supervox-bench`, un outil en ligne de commande qui
mesure la qualité de transcription de plusieurs moteurs, le délai de réponse de bout en bout, la dictée en direct, et qui mène
un entretien entier à partir de fichiers WAV. **L'entretien vocal et le réglage de sa voix sont écrits et testés sur des
doubles, mais ils n'ont jamais été essayés sur le matériel** : ni le micro, ni les haut-parleurs, ni la voix du système, ni l'écho, ni l'interruption, ni l'écoute d'une voix, ni
VoiceOver. La liste des essais à faire à la main est dans `docs/essai-final.md` (étapes 6 et 7, « Jamais exécuté pendant la
construction »).

## Prérequis

- macOS 26 ou plus (version minimale déclarée par le paquet) et Xcode 27 (le code utilise des API de macOS 27,
  sous `if #available`, et il faut le SDK 27 pour compiler).
- État de la vérification : testé en local sous macOS 27 avec Xcode 27. Le pipeline GitHub Actions (étiquette
  `xcode-27`, image en préversion) exécute les tests unitaires sous Xcode 27 à chaque envoi et à chaque pull request. macOS 26 est la version minimale déclarée, mais
  elle n'est pas vérifiée.

## Tests

```sh
swift test
```

Les tests d'intégration sont désactivés par défaut, parce qu'ils téléchargent des modèles, ouvrent le micro, jouent un son ou
font travailler la voix du système. Ils ne tournent pas dans le pipeline. À la demande de l'utilisateur, aucun essai sur le
matériel n'a été fait pendant les étapes 6 et 7 : `SUPERVOX_SPEECH=1` et `SUPERVOX_PLAYER=1` n'ont **jamais** été lancés ; de
`SUPERVOX_SPEAKER=1`, trois tests sur quatre ont passé avant cet ordre (sur un casque Bluetooth, non généralisable) et le
quatrième n'a jamais été lancé.

- `SUPERVOX_INTEGRATION=1 swift test` : vrais moteurs de transcription et vrai détecteur de voix. Les modèles sont
  téléchargés au premier passage (leur taille dépend du moteur et n'a pas été mesurée pour ce README). Ces tests
  fabriquent leur audio avec la voix française `Thomas` de macOS (commande `say`) : elle doit être installée.
- `SUPERVOX_MIC=1 swift test` : capture d'environ une seconde de bruit ambiant avec le vrai micro (en mémoire,
  rien n'est écrit sur disque). **Ouvre le micro.**
- `SUPERVOX_SPEAKER=1 swift test --filter RealAudioIOTests` : le vrai son (suite « Son réel », quatre tests). **Ouvre le micro
  avec le traitement de la voix** (un casque Bluetooth en entrée peut passer en mode appel) **et joue, sur la sortie par défaut,
  des tons de 440 Hz d'amplitude 0,05** (−26 dB pleine échelle, calcul). L'autorisation du micro doit déjà être accordée à
  l'application qui lance les tests : sinon chaque test sort tôt avec un avertissement « non établi » et paraît vert. Ne change
  aucun réglage du système.
- `SUPERVOX_PLAYER=1 swift test --filter SystemClipPlayerHardwareTests` : le vrai lecteur de sortie de l'onglet Voix (cinq tests).
  **Joue des tons de 440 Hz d'amplitude 0,2** (choix non mesuré, plus fort que ceux de `SUPERVOX_SPEAKER`) sur la sortie par
  défaut, au volume du système : environ 2,6 s de son en tout, 24,6 s au pire (code lu). **N'ouvre pas le micro** : c'est la
  raison d'une variable à part. Ne change aucun réglage du système. Chaque test exige aussi que le compteur de fins de secours
  du lecteur reste à 0 (sinon le système ne signale pas la fin de lecture). Jamais lancé.
- `SUPERVOX_SPEECH=1 swift test --filter SystemSpeechIntegrationTests` : fait dire une phrase française à la voix du système
  (`AVSpeechSynthesizer.write`) et vérifie le clip. D'après le code, la synthèse reste en mémoire et rien n'est envoyé aux
  haut-parleurs (non vérifié à l'oreille). Demande une voix française installée.
- `SUPERVOX_PASTEBOARD=1 swift test` : le vrai presse-papiers du système, mais jamais le général (un presse-papiers nommé,
  unique, libéré à la fin) ; aucune touche n'est postée.
- `SUPERVOX_KEYCHAIN=1 swift test` : écrit, lit, remplace et supprime une entrée de test dans le vrai trousseau.
- `SUPERVOX_KEYBOARD=1 swift test` : interroge la vraie disposition de clavier.
- `SUPERVOX_WINDOWS=1 swift test --filter WindowIntegrationTests` : construit de vraies fenêtres d'AppKit ; **certains tests font
  apparaître brièvement le panneau** (`orderFrontRegardless`). Il faut un écran déverrouillé (session non verrouillée : sinon
  tous échouent sur `isKeyWindow`).

## Application

Supervox est une application de barre de menus : pas d'icône dans le Dock, une icône d'onde dans la barre de menus.
L'application tient le panneau, la dictée (voir « Dictée »), la relecture, les modes (voir « Modes »), la correction à la
voix, l'entretien vocal (voir « Entretien »), le réglage de sa voix (voir « Voix »), l'historique des entretiens, les fournisseurs, le
raccourci et les permissions.
Trois modes dictent : la dictée brute (le texte tel quel), la dictée nettoyée et le prompt (le texte est mis en forme par un
modèle de langage, chez le fournisseur que vous avez réglé). Le quatrième, l'entretien, pose des questions à voix haute et
rédige un prompt. Avec la dictée brute, rien ne quitte l'ordinateur sauf le téléchargement des modèles de transcription ; avec
un mode à consigne ou l'entretien, du texte (jamais l'audio) part chez votre fournisseur : voir « Modes » et « Entretien ».

### Construire

```sh
Scripts/make-app.sh
```

Le script compile en mode release, écrit `build/Supervox.app` (avec son `Info.plist`), signe le paquet puis vérifie la
signature (`codesign --verify --strict`).

### Signature

- Avec `SUPERVOX_SIGN_IDENTITY` (le nom d'une identité de signature du trousseau), le paquet est signé avec elle :

  ```sh
  SUPERVOX_SIGN_IDENTITY="Supervox local" Scripts/make-app.sh
  ```

- Sans cette variable, la signature est ad hoc : macOS ne reconnaît pas l'application d'une compilation à l'autre, et
  redemande le micro et l'Accessibilité après chaque compilation. Le script le rappelle.
- Pour un usage local, un certificat auto-signé suffit. Dans « Trousseaux d'accès », menu Trousseaux d'accès,
  Assistant de certification, « Créer un certificat… » : un nom (par exemple « Supervox local »), type d'identité
  « Racine auto-signée », type de certificat « Signature de code ». Ce nom est la valeur de `SUPERVOX_SIGN_IDENTITY`.
  `security find-identity -p codesigning` liste les identités disponibles.

### Lancer

```sh
open build/Supervox.app
```

- Raccourci par défaut : ⌃⌥Espace (contrôle, option, espace). Il ouvre le panneau et lance la dictée, depuis n'importe
  quelle application ; selon le réglage, un second appui la termine (bascule) ou le relâcher la termine (maintien).
  Le raccourci ne ferme pas le panneau : un appui, panneau ouvert et sans dictée en cours, relance une dictée. Le panneau
  se ferme par Échap, par un clic dans une autre application (sauf pendant une dictée ou une relecture), par le menu de
  l'icône, par « Réglages… » et « Quitter Supervox », ou après un collage réussi. Dans le mode Entretien, le raccourci lance
  l'entretien, et pendant un entretien un appui le **conclut** (voir « Entretien »). Pendant une relecture (voir
  « Relecture »), le raccourci ne lance pas de dictée : il commence une correction à la voix (voir « Corriger à la voix »).
- Au premier lancement (aucun fichier de réglages), le panneau s'ouvre seul : il dit à quoi sert le raccourci et où
  sont les réglages, et propose d'autoriser le micro puis l'Accessibilité. Rien n'est demandé avant ce clic.
- Relancer l'application déjà ouverte (`open build/Supervox.app`) ouvre le panneau, sans second exemplaire. Vérifié
  ainsi sur l'application construite ; la relance depuis le Finder ou le Dock ne l'a pas été.
- Un avis sur le fichier de réglages (mis de côté, illisible, version plus récente) ouvre aussi le panneau au
  lancement ; ce n'est pas l'accueil d'un nouvel utilisateur.
- Les réglages (huit onglets : fournisseurs, raccourci, permissions, transcription, modes, entretien, voix, historique) s'ouvrent
  par « Réglages… », dans le menu « … » du panneau ou dans celui de l'icône de la barre de menus ; « Historique… », dans le menu
  « … » du panneau, ouvre la fenêtre sur l'onglet Historique. La fenêtre fait 860 points de large sur 460 (la hauteur est un
  choix non mesuré) : la barre de huit onglets demande 804 points, **mesurés hors écran dans une fenêtre jamais affichée** ;
  elle n'a jamais été vue affichée. Avec sept onglets, la barre dépassait déjà les 600 points de l'ancienne fenêtre (environ
  703 points d'après une sonde hors écran, non conservée dans le dépôt).
- Si le raccourci est refusé par macOS, le panneau s'ouvre au lancement pour le dire. S'il est aussi un raccourci de
  macOS activé sur ce Mac, le panneau s'ouvre pour le dire au premier lancement où c'est le cas ; ensuite l'avis
  reste dans le panneau, qui ne s'ouvre plus seul pour ce raccourci. macOS ne signale pas les conflits avec une autre application : si le raccourci
  n'ouvre pas le panneau, choisissez-en un autre.

### Ce qui est stocké, et où

- Les réglages (fournisseurs sans leur clé, raccourci, dernier mode, réglages de transcription, les modes avec leur
  consigne, leur modèle, leur moteur, leur raccourci et leur choix de relecture, les modèles fort et rapide, les réglages de
  l'entretien (`interview`), la voix de Supervox (`voice`) et les voix de fournisseur enregistrées (`voices`), que l'onglet Voix
  règle (elles peuvent aussi s'éditer à la main, Supervox fermé), et la durée de conservation de l'historique (`history`)) :
  `~/Library/Application Support/Supervox/settings.json`. Le fichier est en **version 3** depuis l'étape 6 : un fichier de
  l'étape 5 (version 2) se lit sans rien mettre de côté, prend les valeurs d'origine pour `interview`, `voice` et `history`
  (absents de la version 2), et passe en version 3 à son premier enregistrement ; un fichier de l'étape 4 (version 1) se lit
  de même et garde son entrée `modeOptions` telle quelle. `voices` est un champ de plus **sans changement de version** (la version reste 3) : absent, il se
  lit vide ; une entrée illisible est gardée telle quelle et réécrite ; un fichier de l'étape 6 relu puis réécrit reste
  identique. **Après cette première écriture en version 3, une version plus ancienne de Supervox ne peut plus y enregistrer ses réglages** : elle dit que le fichier vient d'une version plus récente, le
  garde tel quel et n'y écrit rien (lu dans le code et vu par les tests ; jamais essayé avec une ancienne application
  construite : essai 66 de `docs/essai-final.md`). Les consignes de vos modes et le gabarit de l'entretien sont dans ce
  fichier, en clair : n'y mettez rien de confidentiel.
  Un fichier au contenu illisible est mis de côté dans le même dossier (`settings.json.illisible-<date>`), jamais
  écrasé ; un fichier qui ne peut pas être lu (droits, disque) reste en place et rien n'y est écrit jusqu'à la fin de
  la session, même s'il redevient lisible ; un fichier écrit par une version plus récente de Supervox est gardé tel
  quel et n'est pas réécrit.
- Le texte d'une dictée n'est écrit dans aucun fichier ni journal ; le panneau n'en garde que le dernier, en mémoire (le texte
  corrigé en relecture compris, et les versions d'une correction à la voix : quitter l'application les perd). Le bouton « Copier » le met dans le presse-papiers comme
  une copie ordinaire : un gestionnaire d'historique du presse-papiers peut alors le garder (le collage d'une dictée sans
  relecture, lui, marque sa copie comme provisoire et confidentielle pour qu'ils l'ignorent ; le « Coller » de la
  relecture laisse, après coup, une copie ordinaire : voir « Relecture »). **Seul un entretien conclu écrit du texte sur le
  disque, dans l'historique** (voir ci-dessous).
- **L'historique des entretiens** : `~/Library/Application Support/Supervox/Historique/`, un fichier JSON par entretien conclu
  (`aaaa-mm-jj-hhmmss-<identifiant>.json`, date en UTC), qui contient `{"version": 1, "record": {…}}` : la date, le prompt
  rédigé (absent si la rédaction a échoué) et la **conversation entière**. **Du texte en clair, que vous pouvez juger
  confidentiel** : ce que vous avez dit y est. Le dossier est créé en 0700 (un dossier déjà là, plus ouvert, est resserré),
  chaque fichier en 0600, écrit de façon atomique (un fichier temporaire, puis renommé) et forcé sur le disque par `fsync` (pas
  `F_FULLFSYNC` : durabilité non mesurée). Une racine qui est un lien symbolique ou un fichier est refusée.
  - *Durée.* 30 jours par défaut (choix non mesuré), réglable dans l'onglet Historique : « Ne rien garder », 7 jours, 30 jours,
    90 jours, 1 an. Avec « Ne rien garder », aucun entretien n'est écrit (choisir la durée écrit pourtant le fichier `conservation`, voir
    ci-dessous). Les entretiens plus vieux que la durée sont supprimés **au lancement**, sans confirmation, et à chaque
    raccourcissement de la durée, **sur confirmation** qui dit combien partent. Une horloge du Mac avancée fait donc purger selon
    la durée choisie.
  - *Durée confirmée.* La durée choisie dans l'onglet est d'abord gardée dans le dossier de l'historique (fichier
    `conservation`, 0600, `{"version": 1, "retentionDays": N}`, « Ne rien garder » compris), puis dans les réglages. Si les deux ne
    s'accordent pas (réglages remis à zéro, mis de côté ou édités à la main : une durée de la mauvaise forme est lue 30 jours),
    rien n'est supprimé automatiquement ; et avec « Ne rien garder » confirmé, aucun entretien n'est écrit, quelle que soit la durée
    que disent ensuite les réglages, jusqu'à ce que la personne confirme la durée dans l'onglet. Le fichier n'est pas un entretien :
    il n'est ni compté, ni listé comme illisible, ni supprimé par « Tout supprimer… » ou par la purge (il reste donc dans un
    dossier sans entretien). **La purge du lancement n'a lieu que si** ce n'est pas le premier lancement, si le fichier de réglages
    a été lu sans avis, **et** si la durée confirmée est absente (durée jamais choisie : les 30 jours par défaut s'appliquent) ou
    égale à celle des réglages. Dans les autres cas l'onglet le dit, dans son bas, au-dessus du sélecteur, avec un bouton qui
    confirme la durée affichée (« Confirmer « 30 jours » » : même chemin que le sélecteur, avec la feuille de confirmation s'il y a
    des entretiens plus vieux) : « La durée de conservation a changé hors de cet onglet : rien ne sera supprimé automatiquement
    tant que vous ne l'aurez pas choisie de nouveau ci-dessous. », ou, pour « Ne rien garder » oublié, « Vous aviez choisi
    « Ne rien garder » : rien n'est gardé tant que vous n'aurez pas choisi une durée de nouveau ci-dessous. » (la ligne d'en-tête
    « Avec « Ne rien garder »… » n'est alors pas affichée). Si l'écriture de la durée confirmée réussit mais pas celle des réglages,
    le dossier est en avance : plus aucune purge automatique tant que la durée n'est pas choisie de nouveau. Un essai sûr est à
    `docs/essai-final.md` (essai 87).
  - *Sauvegardes et réseau.* « Envoyés nulle part » vaut pour le réseau : le dossier est un dossier ordinaire du disque et fait
    partie des sauvegardes locales de l'ordinateur.
  - *Ce que l'onglet permet.* Copier le prompt ou la conversation (« Copié. » et les messages d'échec s'affichent dans une bande
    fixe au bas de l'onglet : aucun bouton ne bouge), supprimer un entretien (sur confirmation « Supprimer cet entretien ? C'est
    définitif. » ; ensuite aucun entretien n'est choisi), tout supprimer (sur confirmation). Avec « Ne rien garder », une ligne
    sous l'en-tête le dit. Une seule feuille sert aux trois confirmations. Choisir une durée relit le disque avant de compter :
    toute durée qui supprimerait des entretiens demande confirmation, avec leur nombre exact. Un fichier illisible ou d'une
    version inconnue n'apparaît pas dans la liste, n'est jamais supprimé par la purge, et une note le dit ; seul « Tout
    supprimer… » le supprime.
  - *Ce qui n'est jamais gardé.* L'audio. Un entretien annulé (Échap, fermeture du panneau, « Réglages… », « Quitter ») **avant** l'arrivée du prompt. Après, dans
    les deux secondes au plus où la relecture attend l'écriture, l'annuler ne défait pas l'écriture, déjà lancée : l'entretien peut
    être gardé alors que le panneau se ferme. Un
    entretien arrêté par une panne (micro, transcription) : sa conversation passe en relecture, mais n'est pas écrite. Un
    entretien où rien n'a été dit. La conversation d'une conclusion dont la rédaction a échoué, elle, est gardée, sans prompt. Le
    prompt gardé est celui que l'entretien a rédigé : le corriger ensuite à la voix ne change pas l'historique (lu dans le code,
    non vu).
  - *Écriture qui échoue.* Si un entretien conclu n'a pas pu être écrit (disque plein, dossier refusé), la relecture le dit,
    après son avis habituel : « Cet entretien n'a pas pu être gardé dans l'historique : copiez le texte si vous voulez le
    conserver. ». La relecture attend l'écriture au plus 2 s (choix non mesuré) avant de s'ouvrir ; au-delà, elle s'ouvre sans
    cet avis. Avec « Ne rien garder », aucun entretien n'est écrit et aucun avis ne s'affiche. Couvert par les tests, jamais provoqué à la main.
  - *Où c'est écrit.* `AppController` ne reçoit un dossier d'historique que de `Sources/Supervox/main.swift` : les tests et l'outil
    d'images n'en ont pas et n'en touchent aucun (un balayage des sources le vérifie).
- Les clés d'API : dans le trousseau de connexion, service `dev.supervox.app`, un compte par fournisseur (son
  identifiant). Jamais dans un fichier, ni dans les modes. Elles ne sont lues qu'au moment d'une requête qui en a besoin
  (la liste des modèles, la mise en forme, la correction, l'entretien : jusqu'à trois lectures à chaque lancement, pour le
  modèle rapide, le modèle fort et une voix de fournisseur ; et l'écoute d'une voix de fournisseur dans l'onglet Voix).
- Les requêtes porteuses de clé passent par une session réseau sans cache, sans cookie ni identifiant enregistré, et
  ne suivent aucune redirection vers une autre origine.

### Rendre les écrans en images

```sh
swift run supervox-snapshots /chemin/vers/un/dossier
```

`supervox-snapshots` écrit les écrans du panneau et des réglages en PNG, en clair et en sombre : pour la dictée, la
préparation (avec « Téléchargement du modèle… », puis avec « Chargement du modèle… »), l'enregistrement (sans texte, avec
un texte long), la transcription, « rien à transcrire », l'échec de préparation, le texte copié faute d'Accessibilité, le
texte refusé par le presse-papiers, un message long sous un dernier texte long, le dernier texte (avec « Copié » et « Copie impossible »), un mode non disponible, et la relecture (texte court, texte plus long que le champ, texte vide, collage en cours, panneau sans la frappe, texte copié faute d'Accessibilité, texte refusé par le presse-papiers, « Copié », « Copie impossible »), le panneau à douze pastilles, la mise en forme
(attente, texte reçu à mesure, échec faute de clé avec un nom de fournisseur long, échec au délai, application changée
pendant la mise en forme, relecture du texte mis en forme) et la correction à la voix (préparation, écoute, écoute en
maintien, réécriture, échec faute de modèle fort, échec faute de fournisseur, consigne vide, relecture avec une version
précédente, suivante ou les deux, aide de la correction avec et sans raccourci) ; pour l'entretien (`entretien-*` et
`dictee-mode-entretien`) : la préparation, l'écoute, la réflexion, la parole, la proposition de conclure, la voix indisponible,
la conclusion, un pire cas de hauteur, et la préparation et l'écoute sans la frappe ; pour les réglages, les onglets
Fournisseurs, Raccourci, Permissions et Transcription (avec leurs feuilles et confirmations), et l'onglet Modes : par
défaut, avec un enregistrement refusé, toute la liste, au premier lancement, les confirmations de suppression, et la
feuille d'un mode (consigne modifiée, Prompt d'origine, sans fournisseur, Entretien, mode personnel, sans liste de modèles,
raccourci refusé, consigne longue) ; l'onglet Entretien (`reglages-entretien*` : d'origine, réglages avancés ouverts,
complet, réglé à la main, enregistrement refusé), l'onglet Voix (`reglages-voix*` : la liste, une voix de fournisseur, une voix
inutilisable, une écoute en cours, une panne d'écoute ; `reglages-voix-editeur*` : l'éditeur, avec et sans refus ;
`reglages-voix-confirmation`) et l'onglet Historique (`reglages-historique*` : deux entretiens, vide,
« Copié. », « Ne rien garder », copie refusée avec un fichier illisible, échec d'écriture, refus de réglages, et les trois
confirmations `historique-confirmation-*` : durée, un entretien, tout) ; le panneau avec un dessin du menu « … » (`panneau-menu`,
et `panneau-menu-grise` pendant un entretien, « Historique… » grisée : des dessins de l'outil, **pas** des captures du vrai menu
ouvert, que l'outil ne peut pas copier). Il n'y a pas d'image pour « Dictée interrompue » ni « Micro indisponible ». Les données sont
d'exemple (`example.com`, textes inventés, noms de fournisseur d'exemple) : aucun accès au trousseau, au réseau, au
presse-papiers ni aux réglages réels ; les images de l'Historique lisent un vrai magasin d'entretiens d'exemple, dans un
dossier temporaire supprimé à la fin, jamais le vrai dossier. Les onglets des réglages sont rendus sans la barre d'onglets, que
la copie d'écran hors écran ne restitue pas fidèlement. Cette commande n'a pas été lancée pour ce README (à la demande de
l'utilisateur) ; les noms d'images viennent du code de `Sources/SupervoxSnapshots/main.swift`.

Le logo est dessiné par le code (`BrandMark`) : aucune image n'est suivie dans le dépôt. `Scripts/make-app.sh`
fabrique l'icône de l'application avec `supervox-snapshots --iconset <dossier.iconset>` puis `iconutil`.

## Dictée

La dictée brute de bout en bout : le raccourci ouvre le panneau, enregistre, puis colle le texte dans l'application au
premier plan.

### Ce qui marche

- **Bascule ou maintien** (Réglages, onglet Raccourci). En maintien, la dictée s'arrête dès que les touches de
  modification du raccourci sont relâchées, même si le système ne signale pas le relâchement de la touche principale
  (vérifié vingt fois par seconde). L'application refuse d'enregistrer un raccourci sans touche de modification (il
  taperait du texte) ; une garde interne, qui ne se déclenche que si les réglages en contenaient un écrit à la main, laisse
  alors seul le relâchement signalé par le système terminer la dictée, ou la durée maximale. **Échap** annule aussi une
  dictée en maintien : avec ⌃⌥ encore tenus, Échap n'est pas l'Échap seul que l'application réserve, donc la même
  surveillance lit l'état de la touche (lecture seule du clavier, comme pour les touches de modification, sans autorisation
  de plus) ; en bascule, Échap garde son chemin habituel. Une dictée garde le comportement (bascule ou maintien) avec lequel
  elle a commencé, même si le réglage change pendant.
- **Le panneau suit la hauteur de son contenu** (sa fenêtre est ancrée par le haut). **Il montre la dictée** : préparation (avec « Téléchargement du modèle… » pendant un téléchargement, puis « Chargement du modèle… » tant que les moteurs se chargent en mémoire ; rien s'ils le sont déjà), enregistrement
  (point rouge, durée, forme d'onde, texte en direct sur quatre lignes au plus, la fin toujours visible), transcription,
  puis le résultat. Échap annule la dictée : rien n'est collé.
- **Le collage est un ⌘V simulé** : le texte est mis dans le presse-papiers, collé, puis le contenu d'origine du
  presse-papiers (texte, image et les autres types lisibles) est rendu, sauf si une autre application y a écrit entre-temps
  (le « Coller » de la relecture fait exception : il laisse le texte copié, voir « Relecture ») ;
  un type dont les données ne se lisent pas (données promises par l'application d'origine, par exemple) n'est pas rendu.
  La touche envoyée est celle qui produit « v » dans la disposition de clavier en cours. Cela demande l'autorisation
  d'Accessibilité ; sans elle, ou si des touches de modification restent enfoncées, le texte est copié, laissé dans le
  presse-papiers, et le panneau dit pourquoi. Si le presse-papiers refuse le texte lui-même, le contenu d'origine est rendu,
  rien n'est collé, et le panneau dit « Texte non copié » (le texte reste dans « Dernière dictée »). Quitter l'application
  pendant un collage attend, trois secondes au plus, que le presse-papiers soit rendu.
- **Un micro qui s'arrête en pleine prise** (casque débranché, par exemple) fait échouer la dictée après une seconde sans
  tranche (trois secondes pour la toute première, comptées depuis l'ouverture du micro ; « le micro s'est arrêté pendant la
  prise ») : rien n'est collé. Un vrai micro livre des tranches même dans le silence. Ces durées sont des choix, non mesurés.
- **Au lancement**, si tous les modèles des réglages courants sont déjà sur le disque (et, pour WhisperKit, si son tokenizer se
  charge depuis le disque), les moteurs se préparent en tâche de fond (priorité basse, sans rien attendre : l'affichage n'est
  pas retardé par construction, mais cela n'a pas été vu à l'écran). Le préchargement ne télécharge ni ne supprime aucun modèle
  (voir « Ce qui touche le réseau ») ; une dictée, un téléchargement ou une suppression lancés pendant ce temps attendent sa
  fin, de quelques secondes. Un échec y est silencieux et ne supprime rien : la dictée suivante suit le chemin normal.
- **« Collé » ne prouve pas que l'application visée a reçu le texte** : l'application ne sait que ce qu'elle a envoyé. Le
  texte de la dernière dictée reste donc dans le panneau (carte « Dernière dictée », avec un bouton « Copier » qui copie
  le texte entier). Il n'est gardé qu'en mémoire : ni fichier, ni journal, et il disparaît quand on quitte l'application.
- **Silence** : « Aucune parole n'a été entendue. » ; rien n'est collé et le panneau reste ouvert.
- **Réglages de transcription** (Réglages, onglet Transcription) : moteur (WhisperKit, plus précis dans les mesures de
  l'étape 1 ; ou Parakeet, bien plus rapide), variante du modèle WhisperKit, langue (WhisperKit seulement), vocabulaire
  (une liste de termes à mieux reconnaître ; une liste trop longue pour WhisperKit est refusée sans effacer la saisie).
  Ils sont relus à chaque dictée : pas besoin de relancer l'application. Une dictée ne télécharge que les modèles dont elle
  a besoin ; si seul le petit modèle du vocabulaire manque et ne se télécharge pas, elle a lieu sans vocabulaire et le
  panneau le dit. Échap pendant un téléchargement annule la dictée : le modèle en cours finit, les suivants ne sont pas lancés.
- **Durée maximale** d'une prise : 5 minutes, après quoi la dictée se termine d'elle-même (choix de conception, non
  mesuré).

### Relecture

À la fin d'une dictée, le texte peut s'afficher dans le panneau au lieu d'être collé tout de suite : on le corrige au
clavier, puis on choisit « Coller » ou « Copier ». Rien n'est collé sans ce geste. Tous les modes qui dictent peuvent
passer par la relecture (voir « Modes »). Cette section dit ce que le code fait ; ce qu'aucun test automatique ne peut voir
est à essayer à la main (étapes 4 et 5 de `docs/essai-final.md`).

- **Où se règle la relecture.** Réglages, onglet Modes : un interrupteur « Relire avant de coller » par mode. Sans choix
  enregistré : éteint pour la dictée brute et la dictée nettoyée, allumé pour Prompt ; Entretien est toujours relu (sa ligne
  n'a pas d'interrupteur). Le choix est lu à l'appui qui commence la dictée : le changer pendant une dictée ne vaut qu'à la
  suivante. Il est écrit dans `settings.json`, dans le mode lui-même (champ `reviewBeforePaste` de chaque entrée de `modes`) ;
  le choix de l'étape 4 (entrée `modeOptions`) est repris une fois, à la lecture d'un fichier de la version 1 (voir « Ce
  qui est stocké »). Si l'enregistrement est refusé (fichier devenu illisible ou plus récent), l'onglet le dit et
  l'interrupteur revient à sa valeur enregistrée.
- **Le champ.** Le texte s'affiche en entier dans un champ de texte brut (titre « À relire »), qui prend la frappe tout de
  suite : le panneau devient la fenêtre clé sans activer Supervox (la barre des menus devrait rester celle de l'application
  de dessous). Rien ne modifie le texte dans le dos de l'utilisateur : ni guillemets ni tirets typographiques, ni
  remplacement, correction ou complétion automatiques. ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V et ⌘A sont traduits par le panneau lui-même
  (l'application n'a pas de menu Édition tant que les Réglages n'ont pas été ouverts) et suivent la lettre de la
  disposition du clavier en cours. Le champ fait la hauteur de son texte, de quatre à seize lignes, puis défile ; le panneau
  grandit avec lui.
- **Coller (le bouton, ou ⌘↩).** Le panneau rend la frappe à l'application de dessous, attend 0,15 s (choix de conception,
  non mesuré), puis colle par le même ⌘V simulé que la dictée directe, sous les mêmes conditions (Accessibilité accordée,
  touches de modification relâchées). **Contrairement à une dictée sans relecture, qui rend toujours le presse-papiers
  d'origine, « Coller » colle le texte et le laisse copié** : un second ⌘V ailleurs le recolle, et un gestionnaire
  d'historique du presse-papiers peut le garder. Si le système refuse de garder cette copie après le collage, le contenu
  d'origine est rendu, sans avis. « Coller » est inactif, et ⌘↩ sans effet, quand le texte est vide ou ne contient que des
  espaces (le champ dit alors « Le texte est vide. » s'il n'a aucun caractère).
- **Si le collage est impossible** (Accessibilité refusée, touches de modification restées enfoncées, ⌘V non envoyé,
  presse-papiers qui refuse le texte), le panneau revient à la relecture avec le texte intact et la raison sous le champ :
  les mêmes phrases qu'à une dictée directe, sauf pour le presse-papiers refusé, dont la phrase est adaptée. Il n'a plus la
  frappe : l'aide dit de cliquer dans le texte pour le corriger, ou sur « Coller » pour le coller, et ⌘↩ n'y serait pas
  reçu. C'est la même aide chaque fois que le panneau n'est pas la fenêtre clé (le panneau le remonte lui-même, à chaque
  prise et perte de la clé) : après un clic dans une autre application, ⌘↩ n'est plus annoncé, et il l'est de nouveau
  dès que le panneau reprend la frappe. Ce suivi est testé sur une fenêtre hors écran ; sur un vrai écran, il reste à
  confirmer (liste d'essai, essai 38).
- **Copier** met le texte entier du champ dans le presse-papiers (copie ordinaire), indique « Copié », et laisse le panneau
  ouvert ; une modification du texte remet « Copier ».
- **Échap** ferme sans coller ni copier, comme toute autre fermeture du panneau (menu de l'icône, « Réglages… », « Quitter
  Supervox »). Le texte corrigé devient « Dernière dictée » (un champ vidé laisse le texte d'origine). Un collage qui n'a pas
  encore envoyé ⌘V est annulé.
- **Pendant la relecture**, le raccourci global ne lance pas de dictée (il commence une correction à la voix, voir « Corriger
  à la voix »), celui d'un mode est ignoré, et un clic en dehors du panneau ne le ferme pas (comme pendant une dictée) : le
  clic sert à choisir où coller. Changer de pastille ne touche pas la relecture ; la dictée suivante suit le mode choisi. La
  relecture elle-même n'utilise aucun modèle de transcription : supprimer un modèle reste possible, sauf pendant qu'une
  consigne de correction est écoutée ou transcrite.
- **Le texte n'est gardé qu'en mémoire.** Quitter Supervox pendant une relecture le perd, sans demander confirmation (le
  prompt d'un entretien conclu est, lui, dans l'historique tel que l'entretien l'a rédigé, sans vos corrections, sauf avec
  « Ne rien garder » ou si l'écriture a échoué).
  Quitter pendant le collage attend, trois secondes au plus, la fin du collage.
- **Pas encore là** : l'annulation après fermeture du panneau. (L'historique sur disque ne garde que les entretiens conclus :
  voir « Ce qui est stocké, et où ». La relecture sert aussi à l'entretien : voir « Entretien ».)

### Modes

Un mode dit ce que devient le texte dicté. Il se règle dans Réglages, onglet Modes (rien ne se règle ailleurs). Chaque mode
a un nom, une consigne, un modèle (facultatif), un moteur de transcription (facultatif), un raccourci (facultatif) et un
choix de relecture.

- **Les quatre modes de base**, dans l'ordre des pastilles du panneau : « Dictée brute » (aucune consigne : le texte est
  collé tel quel), « Dictée nettoyée » (ponctuation, majuscules, hésitations retirées, sens et ton gardés), « Prompt » (la
  demande dictée devient un prompt en cinq parties : Objectif, Contexte, Contraintes, Résultat attendu, Critères de réussite ;
  ce que la dictée ne couvre pas est marqué « Non précisé. », rien n'est inventé) et « Entretien » (des questions à voix haute,
  puis un prompt : voir « Entretien » ; sans consigne à modifier, ses questions et son gabarit se règlent dans l'onglet
  Entretien). Dictée brute et Entretien ne se suppriment pas ; Dictée nettoyée et
  Prompt se suppriment et se remettent par « Ajouter un mode », avec leur consigne d'origine. On peut créer, renommer
  (60 caractères au plus, sans doublon), dupliquer, déplacer et supprimer les autres ; les pastilles suivent l'ordre de la
  liste, à la ligne quand elles débordent.
- **La consigne.** Le champ « Consigne » de la feuille d'un mode (« Modifier… ») contient la consigne d'origine pour un mode de
  base ; « Revenir à la consigne d'origine » la rétablit. Sans consigne, le texte est collé tel quel et rien n'est envoyé. Les
  consignes d'origine (`ModeDefaults`) sont des choix de produit, non mesurés : leur qualité se juge à l'essai. Ce que vous
  écrivez n'est pas toute la demande : l'application y ajoute elle-même le vocabulaire personnel (l'onglet Transcription),
  s'il y en a, et une règle qui dit au modèle que le texte dicté est une donnée à transformer, jamais une demande qui lui est
  adressée. Le texte part seul, entre des balises dont le nom porte un suffixe tiré au hasard à chaque
  requête (`<dictee-3f9a0c71b2d458e6>` … `</dictee-3f9a0c71b2d458e6>`, de même `<texte-…>` et `<consigne-…>` pour la correction
  à la voix : 64 bits en hexadécimal, un seul suffixe par requête), et la consigne système nomme ces balises exactes. Le texte
  dicté n'est **pas modifié** : il part tel quel, caractère pour caractère. Il ne connaît pas le suffixe, donc il ne peut pas
  écrire la balise de fin de sa zone (ni en ouvrir une), quelle que soit l'écriture qu'il essaie. Une seule garde : si le texte
  contient le suffixe tiré (probabilité négligeable), un autre est tiré. Modifier ou effacer une consigne ne retire donc pas
  cette protection. C'est une défense contre un texte qui imite la fin de la zone, non une garantie qu'un modèle n'obéira jamais
  à un texte : une dictée qui dit « ignore tes consignes » reste une donnée que le modèle doit traiter comme telle, ce que
  les tests ne vérifient pas (seule la forme de la requête l'est : liste d'essai, essai 51), et relire le résultat reste le
  filet.
- **Modèles fort et rapide.** En tête de l'onglet Modes, section « Modèles ». Le modèle fort sert à la correction à la voix, à
  la rédaction du prompt de l'entretien et à tout mode sans modèle propre ; un mode peut choisir le sien (« Modèle utilisé »).
  Le modèle rapide pose les questions de l'entretien vocal (une requête par tour) ; aucun autre mode ne l'emploie. Les modèles
  proposés sont ceux de la dernière liste lue de chaque fournisseur.
- **Ce qui part chez le fournisseur, et ce qui reste ici.** Pour un mode à consigne, une seule requête part, vers l'adresse du
  fournisseur (`<adresse>/v1/chat/completions` pour le type « Compatible OpenAI », `<adresse>/v1/messages` pour « Anthropic »),
  avec la clé dans l'en-tête : le nom du modèle, la consigne, le vocabulaire et le texte dicté. **L'audio ne part jamais**, il
  est transcrit sur l'ordinateur. La clé reste dans le trousseau, le texte dicté n'est écrit dans aucun fichier ni journal, la
  réponse du fournisseur non plus. La feuille d'un mode le rappelle : « Ce mode envoie le texte dicté à « <nom du
  fournisseur> ». L'audio reste sur cet ordinateur. » Pendant la mise en forme, le panneau dit à qui part le texte.
- **Pendant la mise en forme**, le titre est « Mise en forme… » : le texte du modèle s'écrit à mesure (sa fin, quatre lignes
  au plus), puis le texte est collé, ou s'ouvre en relecture si le mode relit. Échap annule la requête : rien n'est collé, et
  la transcription brute reste dans « Dernière dictée ». Un mode sans relecture ne colle pas si l'application au premier plan
  a changé pendant la mise en forme : le texte s'ouvre en relecture avec un avis, au lieu d'être collé là où l'on est allé.
  Le texte mis en forme remplace la transcription brute comme dernier texte ; avec relecture, la brute est la première
  « Version précédente ».
- **Quand le modèle échoue** (aucun modèle choisi, fournisseur supprimé, clé absente ou refusée, adresse ou modèle inconnus,
  limite de débit, serveur en erreur, réseau coupé, réponse coupée, refusée ou vide, aucune réponse en 30 secondes de silence
  ou en 120 secondes au total), la relecture s'ouvre sur la **transcription brute**, même si le mode n'a pas de relecture,
  avec une phrase fixe qui dit quoi faire : le texte n'est jamais perdu, rien n'est collé, et une réponse commencée n'est pas
  gardée. Ces phrases viennent d'une table du code ; jamais le corps d'une erreur du serveur ni le texte dicté.
- **Raccourci d'un mode** (feuille du mode, « Raccourci du mode ») : mêmes règles que le raccourci global : une touche de
  modification (⌃ ou ⌘) au moins, ni réservé par le système, ni pris par le raccourci global, un autre mode ou un raccourci de
  macOS activé. Il choisit le mode dans le panneau (comme un clic sur la pastille, enregistré) et commence la dictée, en
  bascule ou en maintien selon l'onglet Raccourci. Pendant une dictée, seul le raccourci du mode qui l'a commencée la termine ;
  celui d'un autre mode, ou le global, est ignoré. **Exception** : si ce raccourci n'existe plus (mode supprimé, raccourci
  retiré pendant la dictée), la dictée, en bascule, se termine par n'importe quel autre raccourci, pour ne pas rester sans
  issue ; en maintien, les autres raccourcis restent ignorés. Pendant une relecture, un raccourci de mode est ignoré. Si deux raccourcis
  portent la même combinaison (possible seulement en éditant `settings.json` à la main), le raccourci global gagne toujours,
  sinon le premier mode de la liste ; l'autre n'est pas enregistré et une ligne du panneau le dit.

### Régler un fournisseur depuis l'interface

1. Réglages, onglet Fournisseurs, « Ajouter un fournisseur… » : un nom (libre), l'adresse du serveur (en `https://` ; `http://`
   n'est permis que pour `localhost` et `127.0.0.1`, pour que la clé ne voyage jamais en clair ailleurs), le type
   (« Compatible OpenAI » ou « Anthropic » : le format des requêtes) et une clé d'API. Elle va dans le trousseau, jamais dans un
   fichier.
2. « Lister les modèles » : le nombre de modèles lus s'affiche. La liste est gardée pour les menus de l'onglet Modes.
3. Onglet Modes, section « Modèles » : choisissez le modèle fort.
4. **Un serveur local sans authentification exige quand même une clé quelconque** (un mot suffit) : une requête sans clé n'est
   jamais envoyée, et la liste des modèles sans clé n'est pas prise en charge pour le type « Compatible OpenAI ». C'est un
   choix de l'étape 5, qui coûte ce geste.
5. Changer d'hôte retire l'ancienne clé : une clé n'est envoyée qu'à l'adresse pour laquelle elle a été saisie.

### Corriger à la voix

En relecture, d'un texte qui n'est pas blanc : le bouton « Corriger à la voix », ou le raccourci global, commence une
correction. La consigne se dit à voix haute (« ajoute que les tests doivent passer ») ; elle est transcrite sur l'ordinateur
avec les mêmes réglages que la dictée relue ; le texte et la consigne partent ensuite au **modèle fort**, qui rend le texte
modifié, en entier, à la place de l'ancien.

- **Déroulé.** « Préparation… » (la phrase dit d'attendre), « Écoute de la consigne » (point rouge, durée, forme d'onde ; le
  bouton devient « Terminer »), « Transcription de la consigne… », « Réécriture… » (le texte du modèle s'écrit à mesure dans le
  champ), puis « À relire » avec le nouveau texte. Le champ est en lecture seule pendant la correction, et « Copier » et « Coller »
  sont inactifs à chaque étape (⌘↩ ne fait rien : on ne copie ni ne colle un texte que l'écran ne montre pas) ; Échap
  l'annule. Tant qu'elle n'a pas réussi, le texte n'a pas changé. En bascule, un second appui sur le raccourci (ou « Terminer ») termine la consigne ; en
  maintien, c'est le relâchement. Commencée par le bouton, elle se termine toujours par « Terminer » ou un appui, même en
  réglage « maintien ».
- **Versions.** Chaque correction réussie empile l'ancien texte : les boutons à flèche « Version précédente » et « Version
  suivante » (sans texte, nommés pour VoiceOver) et ⌘Z / ⇧⌘Z les parcourent. ⌘Z défait d'abord ce qui a été tapé dans le champ,
  puis change de version ; le texte tapé voyage avec sa version. Une nouvelle correction vide les versions suivantes. Pendant une
  saisie en attente (touche morte, méthode de saisie), changer de version est sans effet et rien n'est perdu. Les versions ne
  vivent qu'en mémoire, tant que la relecture est ouverte.
- **Quand elle n'aboutit pas** (aucune consigne entendue, aucun modèle fort, panne du fournisseur, micro non autorisé, réponse
  identique au texte), le texte reste intact, ce qu'on y avait tapé compris, avec une phrase qui dit pourquoi ; aucune version
  n'est ajoutée. Échap annule la correction seule (la relecture revient) ; un second Échap ferme le panneau sans rien coller.
- **Limites connues.** Le texte (et la consigne) part chez le fournisseur du modèle fort, comme une mise en forme. Quitter
  Supervox pendant la mise en forme ou une relecture perd le texte, la transcription brute comprise, sans confirmation. Une
  version abandonnée par une nouvelle correction est perdue. Pendant une correction, supprimer un modèle de transcription est
  refusé (une session le tient). Que ⌘Z et ⇧⌘Z changent de version avec un vrai clavier dans le panneau, que VoiceOver annonce
  de lui-même les étapes (il lit les éléments, l'application ne poste aucune annonce pour la correction ; l'entretien, lui, en
  poste : voir « Entretien ») et que les modèles obéissent aux
  consignes ne sont pas établis : ils sont à essayer (étape 5 de `docs/essai-final.md`).

### Où sont les modèles

Rien n'est embarqué : les modèles se téléchargent depuis Internet, à la demande (bouton « Télécharger » de l'onglet
Transcription, ou à la première dictée qui en a besoin), puis tournent sur ce Mac.

**Ce qui touche le réseau et ce qui ne le touche pas.**
- **Pour la transcription**, le réseau sert au téléchargement des modèles, et à lui seul : le dépôt de modèles de WhisperKit
  (le modèle et son tokenizer) et les modèles de FluidAudio (Parakeet, son petit modèle de vocabulaire, le détecteur de
  voix). L'audio ne part nulle part : les moteurs sont locaux, y compris pour la consigne d'une correction à la voix.
- **Pour la mise en forme, la correction à la voix et l'entretien**, le texte part au fournisseur choisi (voir « Modes » et
  « Entretien ») : un mode sans consigne (la dictée brute, un mode personnel vide) n'envoie rien. Ce sont les seuls cas où du
  texte quitte l'ordinateur (avec la voix d'un fournisseur, le texte que dit Supervox part aussi chez lui, et l'écoute d'une voix de
  fournisseur dans l'onglet Voix lui envoie la phrase d'essai) ; l'audio, jamais.
- Un modèle WhisperKit « Prêt » se charge depuis son dossier, sans requête réseau : le dossier du modèle, l'interdiction de
  télécharger et le dossier du tokenizer sont donnés à WhisperKit (code et dépendance lus, jamais essayé hors ligne). Le
  tokenizer n'y fait exception que si son fichier (`models/openai/whisper-<variante>/tokenizer.json` et
  `tokenizer_config.json`, sous le dossier des modèles de Supervox) manque ou ne se lit pas : WhisperKit va alors le chercher
  en ligne. Un nom de variante saisi à la main dans les réglages, inconnu du catalogue et absent du disque, est téléchargé
  par WhisperKit lui-même à la première dictée.
- Parakeet et le détecteur de voix (FluidAudio) : **hors préchargement**, une dictée peut les télécharger, et la bibliothèque
  peut supprimer puis retélécharger un modèle qui ne se charge pas (corrompu, ou jugé incomplet par elle seule). **Pendant le
  préchargement du lancement**, le réseau de FluidAudio est coupé (`ModelHub.offlineMode`, lu dans la bibliothèque : il lève
  une erreur à la place de tout accès réseau et du rattrapage « supprimer puis retélécharger ») et rétabli à la fin, succès
  ou échec : un modèle absent, incomplet ou illisible fait alors échouer le préchargement en silence, sans rien télécharger ni
  supprimer. Le tokenizer de WhisperKit, lui, ne peut pas être coupé du réseau : le préchargement WhisperKit n'a donc lieu
  que si le tokenizer se charge réellement depuis le disque. Cette garde est lue dans le code et testée avec des doubles ;
  jamais essayée avec de vrais modèles abîmés.
- Si un modèle indiqué « Prêt » ne se charge pas, la phrase du panneau renvoie à l'onglet Transcription : le supprimer puis
  le télécharger de nouveau est possible, mais **demande une connexion à Internet** (hors ligne, il ne faut pas le supprimer).

- WhisperKit : `~/Library/Application Support/Supervox/Models/` (sous-dossier `models/argmaxinc/whisperkit-coreml/`).
- Parakeet (avec son petit modèle de vocabulaire) et le détecteur de voix : le dossier de la bibliothèque FluidAudio,
  `~/Library/Application Support/FluidAudio/Models/`, partagé avec les autres applications qui l'utilisent. (Chemins lus
  dans le code ; pas relevés sur un disque ici.)

Supprimer un modèle se fait depuis le même onglet ; c'est refusé pendant une dictée et pendant le téléchargement du
modèle. Une dictée qui en a besoin le télécharge de nouveau.

### Ce que l'aperçu en direct est, et n'est pas

- C'est un texte **provisoire**, fait par Parakeet pendant que vous parlez (au plus toutes les 0,5 s, sur les
  15 dernières secondes du passage en cours), quel que soit le moteur choisi pour le texte final. Il peut changer d'une
  passe à l'autre et se tromper.
- Ce n'est **pas** le texte collé. Le texte collé vient du moteur choisi, une fois la prise terminée, sur toute la
  parole (avec 0,3 s de marge de chaque côté).
- **Limite connue, non corrigée** : le texte en direct peut perdre le début d'un passage de parole de plus de 15 s. Le
  texte final, lui, est complet.

### Vérifier

- Les essais à faire à la main, que les tests automatiques ne couvrent pas : `docs/essai-final.md`.
- La mesure de la dictée en direct (texte final contre transcription en bloc, dernier aperçu, délai) : commande
  `supervox-bench live` (voir « Le banc d'essai ») ; méthode et tableau dans `docs/bench/2026-11-14-dictee-en-direct.md`.

## Entretien

Le mode Entretien mène un entretien oral : Supervox (le modèle rapide) vous pose des questions à voix haute, une à la fois ;
vous répondez à voix haute ; à la conclusion, le modèle fort rédige un prompt, qui s'ouvre en relecture. **État de la preuve** :
tout est écrit et testé sur des doubles (micro, son et voix scriptés, serveur local de test). **Rien n'a été essayé sur le
matériel**, à la demande de l'utilisateur : ni le micro, ni les haut-parleurs, ni l'écho, ni l'interruption, ni la voix du
système, ni la vraie fenêtre, ni VoiceOver. Les essais à faire à la main (63 à 95) et la liste de ce qui n'a jamais tourné sont
dans `docs/essai-final.md`, étape 6 ; ceux des voix (96 à 114), étape 7 (voir « Voix »). Toute valeur chiffrée ci-dessous est
un **choix non mesuré**, sauf mention (« code lu » ou « mesuré »).

### Lancer

- **Trois chemins** : le raccourci global quand « Entretien » est le dernier mode choisi ; le raccourci propre du mode
  Entretien (feuille du mode, onglet Modes) ; un clic sur la pastille « Entretien » au repos, même déjà choisie. Rien ne se
  lance pendant une dictée, une relecture ou un autre entretien. Les pastilles sont inactives pendant l'entretien.
- Le micro doit être autorisé : sinon le panneau montre la ligne des permissions et rien ne démarre.
- **Avant d'ouvrir le micro**, l'application résout les réglages : un modèle rapide et un modèle fort doivent être choisis,
  leurs fournisseurs exister, leurs clés être lues dans le trousseau (jusqu'à trois lectures, avec la voix d'un fournisseur).
  Sinon le panneau dit quoi régler, sans micro ni son.
- **« Préparation de l'entretien… »** télécharge ce qui manque, puis charge le moteur de transcription du mode (Parakeet, tant
  qu'aucun autre n'est choisi dans la feuille du mode) et un détecteur de voix propre à l'entretien. Sa durée n'est pas mesurée.

### Conduire

- **Les états** : « Préparation de l'entretien… », « À vous », « Réflexion… », « Supervox parle » (« Supervox répond » quand
  aucune voix ne parle), « Rédaction du prompt… ». Le panneau montre l'orbe, « Question n sur m » (à partir de la première
  question), la réplique de Supervox, la carte « Vous » (d'abord un aperçu provisoire, recalculé toutes les secondes), les
  avis, « Conclure », « Échap annule l'entretien sans rien garder. » et la ligne de vie privée. Avec une voix, le bloc « Supervox »
  est vide au début de la parole, puis chaque phrase s'y ajoute une fois dite jusqu'au bout (en texte seul, la réplique
  s'affiche à mesure) ; il défile au-delà de 128 points, avec un fondu en bas. L'application poste une annonce à VoiceOver à
  chaque changement de titre et à chaque avis (jamais écoutée). D'après le code, le panneau ne prend pas la frappe pendant
  l'entretien (le lancement ne la lui donne pas ; la relecture, elle, la prend).
- **L'écoute est continue**, même pendant que Supervox réfléchit ou parle : c'est une porte, non l'état, qui décide si ce qui
  est entendu devient un tour (voir « Interruption »).
- **Silence de fin de tour** : 0,5 s par défaut, de 0,3 à 2,0 s. Le détecteur de voix compte par blocs de 4 096 échantillons
  (0,256 s à 16 kHz) et attend 1 + ⌈silence / bloc⌉ blocs silencieux : 0,3 à 0,51 s demandées donnent 0,768 s, 0,6 s donne
  1,024 s, 2,0 s donne 2,304 s (formule lue dans le code de FluidAudio 0.18.3 et `FluidStreamingVoiceDetector.effectiveSilence`,
  chiffres refaits à la main ; jamais mesurés sur une voix réelle). L'onglet Entretien montre la valeur « en pratique »,
  un plancher. Le défaut de 0,5 s remplace les 0,6 s de la dictée : environ 0,26 s de moins, non remesuré, au risque de couper
  quelqu'un qui marque une pause.
- **Le modèle rapide** reçoit la consigne de l'intervieweur (`InterviewPrompt`) et la conversation ; il écrit en tête de sa
  réponse un marqueur seul, `[SUITE]` (une question), `[PROPOSER]` (« peut-on conclure ? ») ou `[CONCLURE]` (vous avez voulu
  conclure ou accepté : une courte phrase de fin, sans question). Le marqueur est retiré de ce qui est dit et montré ; un
  marqueur mal écrit par le modèle (avec des espaces, sans crochet fermant) n'est pas reconnu et serait donc **dit**. Chaque
  tour : 1 024 jetons au plus et 30 s au plus.
- **Plafond de questions** : 8 par défaut, de 1 à 20. Il compte les questions de Supervox, pas votre demande de départ. Une
  question compte quand sa première phrase commence à être jouée ; la dernière est annoncée (« Dernière question : après votre
  réponse, Supervox rédige le prompt. ») et, après votre réponse, la conclusion démarre sans troisième question.
- **Proposition de conclure** : l'avis « Supervox propose de conclure : dites-le s'il vous convient, ou continuez à préciser. »
  s'affiche ; quand le modèle juge le moment venu n'est pas garanti (jamais vu avec un vrai modèle).

### Interruption

- Pour couper la parole de Supervox, **deux conditions** : le détecteur de voix a ouvert un passage pendant que Supervox
  réfléchissait ou parlait, **et** la voix dure la durée réglée (0,30 s par défaut) à l'intérieur d'une fenêtre glissante du
  double de cette durée, au-dessus du niveau réglé (−30 dB pleine échelle par défaut). Trames de 20 ms, comptées en
  échantillons (`InterruptionGate`, code lu).
- Un bruit que le détecteur n'annonce pas comme de la voix ne coupe pas (mesuré sur des signaux d'essai, non sur une pièce).
  Des claquements épars non plus, une fois un passage ouvert (la fenêtre les écarte). **Jamais établi** : que l'annulation d'écho
  du système laisse un écho que le détecteur annonce comme de la voix. Si c'est le cas et que l'écho dépasse le niveau, Supervox
  se coupe seul ; l'onglet Entretien dit alors de monter le niveau, vers −20 dB.
- **Ce qui est retenu** : seules les phrases entendues entrent dans la conversation : jouées jusqu'au bout, montrées à
  l'écran, ou **coupées après au moins la moitié de leur durée** (gardées en entier). Une question dont rien n'a été entendu
  ne compte pas, et ce que vous dites alors s'ajoute à votre tour précédent. Couper pendant « Réflexion… » annule la requête.
  Ce que vous dites en coupant est transcrit **depuis son début**.
- Le délai entre le début de votre voix et l'arrêt de Supervox n'est ni calculé ni mesuré.
- **Une réponse commencée dans le dernier quart de seconde de la réplique** de Supervox peut perdre sa première syllabe : coût
  accepté, Supervox ne doit pas s'entendre lui-même (ce qui est capté pendant qu'il parle ne compte que s'il passe la porte). À
  l'inverse, le dernier quart de seconde d'un tour d'écoute, que le détecteur n'avait pas encore examiné, n'est pas perdu : il est
  reporté au début de l'écoute suivante.

### Conclure

- **Quatre façons** : le bouton « Conclure » ; la touche (en bascule, un appui ; en maintien, le relâchement ne fait **rien**
  et un nouvel appui conclut : l'entretien fonctionne toujours en bascule, une note le dit) ; la voix (le marqueur `[CONCLURE]`) ;
  le plafond de questions. Lancé par le raccourci d'un mode, seul ce raccourci conclut. « Conclure » est grisé en préparation et
  pendant la rédaction.
- **Dès qu'une conclusion est demandée**, ou déclenchée par le plafond, le micro est fermé et « Rédaction du prompt… » est
  affiché ; ce qui se disait au moment de la demande est transcrit micro fermé et fait partie de la conversation. Si ces
  derniers mots ne peuvent pas être transcrits (panne du moteur ou délai dépassé) et qu'un tour au moins existe, le prompt est
  rédigé sans eux et la relecture le dit. Un micro qui se tait après « Conclure » n'est pas une panne.
- **Rien n'a été dit** : pas de prompt, le panneau le dit (« Rien n'a été dit… ») et aucune requête ne part.
- **Le prompt** : le modèle fort reçoit le gabarit (modifiable dans l'onglet Entretien ; par défaut cinq parties : Objectif,
  Contexte, Contraintes, Résultat attendu, Critères de réussite), le vocabulaire personnel s'il y en a, et la conversation, qui
  part comme une **donnée délimitée** par des balises à suffixe tiré à chaque requête (`<entretien-…>`, même mécanisme que la
  dictée : voir « Modes »), jamais comme une demande. 120 s et 16 000 jetons au plus.

### Annuler, relire, pannes

- **Échap, « Fermer le panneau », « Réglages… » et « Quitter Supervox »** annulent l'entretien à n'importe quel état, rédaction
  comprise : rien n'est collé, rien n'est gardé (ni historique, ni relecture), le micro est fermé ; une seule exception, dite
  dans « Ce qui n'est jamais gardé » : l'annulation dans les deux secondes au plus qui suivent l'arrivée du prompt. Un clic dans une autre
  application ne ferme pas le panneau. Une dictée lancée juste après attend que le micro de l'entretien soit rendu.
  « Historique… » du menu « … » est grisée tant qu'un entretien, une dictée ou une relecture tient le panneau : elle ne peut
  plus annuler un entretien sans rien demander (« Réglages… », elle, l'annule toujours).
- **La relecture** (« À relire ») est celle de la dictée : « Coller », « Copier », « Corriger à la voix » (modèle fort), sans
  « Version précédente » avant la première correction. Rien n'est collé sans geste.
- **Ne rien perdre** : toute panne après au moins un tour ouvre la relecture sur la conversation (« Vous : » et « Supervox : »),
  avec une phrase fixe. Le modèle fort en panne : conversation en relecture, **gardée dans l'historique** sans prompt. Micro ou
  transcription arrêtés : conversation en relecture, non gardée. Le modèle rapide en panne : le tour est gardé, un avis, l'écoute
  reprend. Une panne avant le premier tour : une phrase, rien à relire.
- **Voix** : si aucune voix ne parle, l'entretien continue en texte seul (« Supervox répond », la question se lit à l'écran, un
  avis une seule fois), et la question compte. La voix d'un fournisseur (onglet Voix, voir « Voix », ou réglage `voice` à la main) a pour secours la
  voix du système : une phrase ratée (erreur ou 4 s) passe à la voix du système, puis la voix du fournisseur n'est plus appelée de
  tout l'entretien (avis une seule fois).
- **Les phrases du panneau** viennent d'une table de phrases fixes : jamais le corps d'une erreur HTTP, jamais
  `localizedDescription`, jamais un texte dit dans un journal.
- **Vocabulaire personnel** : même règle que la dictée (retiré avec un avis quand son petit modèle n'est pas prêt ou que la liste
  ne tient pas dans WhisperKit).

### Réglages de l'entretien

Onglet Entretien (l'ordre de la fenêtre) : nombre maximal de questions (8 ; 1 à 20), gabarit du prompt final (enregistré quand le
champ perd la main, quand l'onglet disparaît, à la fermeture de la fenêtre et à Quitter), puis, repliés, les **réglages
avancés** : silence de fin de tour (0,5 s ; 0,3 à 2,0), durée de voix pour couper la parole (0,30 s ; 0,10 à 1,00), niveau de voix
pour couper la parole (−30 dB ; −50 à −10). « Rétablir les valeurs d'origine » ne touche ni le nombre de questions ni le
gabarit. Les changements s'appliquent au prochain entretien. Une valeur hors borne dans le fichier est ramenée dans sa borne à la
lecture. Le moteur de transcription n'a pas d'onglet (la feuille du mode Entretien le choisit) ; la voix a le sien (voir « Voix »), et
une ligne « Voix », avec le bouton « Choisir la voix… », dans le premier groupe de l'onglet Entretien y mène.

### Vie privée (D11)

La phrase de l'onglet Entretien, mot pour mot : « Le texte de vos réponses est envoyé au fournisseur du modèle rapide et du
modèle fort ; l'audio du micro ne quitte jamais cet ordinateur. », suivie de « La voix de Supervox est celle du système : rien
n'est envoyé pour la produire. » (ou, avec une voix de fournisseur : « La voix de Supervox vient de « <nom> » : le texte qu'elle
dit lui est envoyé. »). Le panneau, à chaque entretien, nomme les fournisseurs : « Le texte de vos réponses part chez
« <nom> » ; l'audio du micro reste sur cet ordinateur. » (deux noms quand les modèles rapide et fort viennent de fournisseurs
différents), puis, avec une voix de fournisseur, « Le texte que dit Supervox part chez « <nom> ». ».

- **À chaque tour**, la consigne de l'intervieweur et la conversation jusque-là partent chez le fournisseur du **modèle rapide**
  (sans le vocabulaire). **À la conclusion**, le gabarit, le vocabulaire et la conversation partent chez celui du **modèle fort**.
  Avec la voix d'un fournisseur, chaque phrase de Supervox part chez lui (`POST <adresse>/v1/audio/speech`).
- **L'audio ne part jamais** : la transcription est locale (Parakeet ou WhisperKit).
- Les clés restent dans le trousseau ; aucune clé ni aucun texte dit n'est écrit dans un journal ou un message d'erreur.
- **Ce qui reste sur ce Mac** : l'historique des entretiens conclus, en clair, dans un dossier qui fait partie des sauvegardes
  locales de l'ordinateur (voir « Ce qui est stocké, et où »).

### Ce qui n'a jamais été essayé

Dit sans détour : aucun entretien complet sur le matériel ; les haut-parleurs intégrés et l'écho ; l'interruption avec une vraie
voix ; la voix du système telle que livrée et la voix d'un fournisseur ; le détecteur de voix en flux sur une voix réelle ; un
casque Bluetooth en mode appel ; la vraie fenêtre (huit onglets dans 860 points, panneau sans la frappe, feuilles de
confirmation) ; VoiceOver ; macOS 26 ; la qualité des questions et du prompt avec un vrai modèle ; le banc `interview` contre un
service. Le détail, avec ce qui a été mesuré isolément avant l'ordre d'arrêt, est dans `docs/essai-final.md`.

## Voix

L'onglet **Voix** des réglages (le septième de huit, entre Entretien et Historique) règle la voix de Supervox : celle que l'entretien
fait parler. **État de la preuve** : tout est écrit et testé sur des doubles (liste de voix, synthèse, lecteur, fournisseur
scriptés, fenêtres jamais affichées). **Rien n'a été essayé sur le matériel**, à la demande de l'utilisateur : ni le vrai lecteur,
ni la vraie liste des voix, ni une écoute entendue, ni une voix de fournisseur réelle, ni VoiceOver. Les essais à faire à la main
(96 à 114) et la liste de ce qui n'a jamais tourné sont dans `docs/essai-final.md`, étape 7. Les valeurs chiffrées sont des
**choix non mesurés** sauf mention (« code lu » ou « mesuré »).

### Ce qui se règle

- **La liste.** Deux sections : « Voix du système » (par langue, une ligne « Automatique » qui prend la meilleure voix de la
  langue, puis chaque voix installée) et « Voix de fournisseurs » (les voix enregistrées). Deux filtres, la langue (en clair, par
  exemple « français (France) » : la locale française du système, mesuré sur la machine de construction) et le genre. Le genre
  d'une voix du système vient d'une propriété du système qui rend souvent « non précisé » (documentation lue, non mesuré) : le
  filtre par genre peut laisser beaucoup de voix sous « Non précisé ». La voix en vigueur est cochée et reste affichée quel que
  soit le filtre.
- **« Utiliser cette voix »** écrit la voix choisie dans `voice`, et rien d'autre : c'est la seule chose que l'entretien lit. Le
  bouton est inactif sur la voix déjà en vigueur et sur une voix qui ne peut pas parler (fournisseur supprimé, voix incomplète).
- **Une voix de fournisseur** (« Ajouter une voix… », « Modifier… », « Supprimer… ») : un nom, un fournisseur **au format
  compatible** (le seul type qui sait parler), un modèle de synthèse, un identifiant de voix chez lui, une langue, un genre, et des
  **paramètres libres**. Elle s'enregistre dans `voices`. L'éditeur (feuille de 520 sur 540 points) refuse, une phrase par cause :
  nom vide, fournisseur qui ne sait pas parler, modèle ou identifiant vide, clé de paramètre vide, clé réservée, clé en double,
  plus de 16 paramètres. La suppression se confirme (la confirmation nomme la voix) ; supprimer la voix en vigueur remet la voix
  automatique du système en français, et le dit.
- **Paramètres en texte.** Chaque paramètre est une paire clé et valeur **en texte**, envoyée telle quelle avec la requête de
  synthèse (16 au plus). C'est ce que la requête fait déjà : **un serveur qui exige un paramètre numérique refusera la requête**
  (non établi pour un service donné). **Quatre noms sont réservés**, posés par Supervox lui-même (code lu :
  la requête de synthèse) : `input`, `model`, `response_format` et `voice` ; la casse est ignorée.
- **Voix par défaut = voix du système.** Sans réglage, la voix est la voix automatique du système, en français, jamais celle d'un
  fournisseur : le dépôt ne nomme aucun service ni aucune voix. La personne saisit sa voix de fournisseur une seule fois, dans
  l'onglet.
- **Écouter.** Le bouton joue une phrase d'essai fixe de la langue de la voix (français, anglais, espagnol, allemand ou
  italien ; une autre langue prend l'anglais ; les quatre dernières sont des traductions non relues). **Sans repli** : une voix
  de fournisseur mal réglée échoue avec sa phrase propre (qui dit de vérifier le modèle, l'identifiant et les paramètres de la voix) et **aucune voix du système ne parle à sa place**, sinon une voix fausse « marcherait ». La synthèse est bornée à 15
  secondes ; la lecture passe par un lecteur de sortie seule (`SystemClipPlayer`, le clip encodé en WAV en mémoire), distinct du
  moteur de l'entretien, qui ouvre le micro pour jouer ; sa fin de secours tombe à la durée du clip plus 2 s.
- **Un micro tenu refuse l'écoute.** Tant qu'une dictée, une correction à la voix qui écoute ou transcrit, ou un entretien tient
  le micro, « Écouter » est grisé, et l'écoute refuse d'elle-même (phrase fixe). À l'inverse, **une écoute en cours est coupée
  dès qu'un micro va s'ouvrir** (dictée, correction à la voix, entretien), avant qu'il n'écoute. Limite connue : à l'instant
  d'une dictée annulée, le micro peut encore être en train de se fermer ; rien n'est gardé de ce son, mais un casque Bluetooth
  peut rester un instant en mode appel.
- **Une voix du système désinstallée.** L'onglet la montre (ligne « Voix en vigueur » avec sa note), l'écoute dit qu'elle n'est
  pas installée et ne fait parler aucune autre voix ; un entretien, lui, prend la meilleure voix de la langue, sans avis (il ne
  doit jamais se taire).
- **Quitter l'onglet** (autre onglet, autre application, fenêtre fermée) arrête l'écoute ; changer d'onglet ou voir le volet
  disparaître annule aussi la confirmation et abandonne l'éditeur ouvert (écrit et testé hors écran, jamais vu avec une feuille
  réellement présentée). Une panne d'écoute affichée reste quand on passe dans une autre application, et disparaît au geste
  suivant dans l'onglet.
- **Les phrases** de l'onglet et de l'écoute viennent d'une table de phrases fixes : jamais le corps d'une erreur HTTP, jamais
  le texte d'erreur du système. Une ligne « Voix » de l'onglet Entretien, avec le bouton « Choisir la voix… », mène à l'onglet.

### Vie privée (voix)

- **Écouter une voix du système n'envoie rien** : elle est produite sur l'ordinateur.
- **Écouter une voix de fournisseur envoie la phrase d'essai** (fixe, rien de vous) **à ce fournisseur et lit sa clé dans le
  trousseau** : une demande du trousseau peut apparaître. La bande de l'onglet le dit avant l'écoute. Une voix qui ne peut pas
  parler n'envoie rien et le dit.
- **L'entretien**, avec une voix de fournisseur, envoie chaque phrase de Supervox à ce fournisseur (voir « Entretien », « Vie
  privée (D11) »). Les voix enregistrées (noms, modèles, identifiants, paramètres) sont dans `settings.json`, en clair : n'y mettez
  aucune clé ni rien de confidentiel dans un paramètre.

### Ce qui n'a jamais été essayé

Dit sans détour : le vrai lecteur de sortie (son délai de démarrage face à la marge de 2 s, la durée de son arrêt sur le fil
principal) ; la vraie liste des voix du système (son contenu, le temps qu'elle prend) ; l'écoute réelle d'une voix, du système ou
d'un fournisseur, et la correspondance entre le nom, le genre affiché et la voix entendue ; une voix de fournisseur contre un
service ; la barre de huit onglets (mesurée hors écran, **non vue affichée**) ; les feuilles de l'éditeur et de la confirmation
dans une vraie fenêtre ; le défilement jusqu'à une voix enregistrée avec une vraie liste (mesuré hors écran avec 40 voix
inventées) ; VoiceOver. Le détail est dans `docs/essai-final.md`, « Jamais exécuté pendant la construction (étape 7) ».

## Le banc d'essai

```sh
swift run supervox-bench <commande> --help
```

- `record` : enregistre ta voix pour chaque phrase d'un corpus (`--corpus`, `--out`, `--overwrite`).
  Un exemple de corpus est dans `Bench/corpus.example.tsv`. Aucune variable d'environnement. Après chaque prise :
  Entrée pour la garder, `r` puis Entrée pour la refaire (rien n'est écrit avant « garder »). Chaque prise gardée
  est décrite dans `capture.json`, à côté des fichiers (périphérique d'entrée, fréquence native, date) ;
  `transcribe` et `latency` le reprennent dans leur rapport, avec la date du lancement et les identifiants de
  modèles passés en argument.
- `transcribe` : fait transcrire les enregistrements par chaque moteur et compare les taux d'erreur
  (`--corpus`, `--audio`, `--engines`, `--out`, et d'autres options). Le moteur `endpoint` demande
  `--endpoint-model` et lit l'endpoint dans l'environnement, avant toute autre étape ; les moteurs locaux n'en ont
  pas besoin. Les messages d'erreur sont débarrassés de l'adresse de l'endpoint et de la clé, comme dans `latency`.
  La commande charge un modèle de détection de voix avant tout moteur : il est téléchargé au premier lancement,
  même avec le seul moteur du système (`--engines apple`).
- `latency` : mesure le délai entre la fin de la parole et la première phrase synthétisée de la réponse
  (`--audio`, `--engine`, `--chat-model`, `--tts-model`, `--voice`, `--out`, et d'autres options).
  Elle lit toujours l'endpoint dans l'environnement. `--vocabulary <fichier>` mesure le moteur avec le vocabulaire
  global (même format et mêmes contrôles que dans `transcribe`) ; le rapport nomme la configuration mesurée
  (`parakeet` ou `parakeet+vocab`). Refusé avec `apple`, qui n'accepte pas de vocabulaire. Un fichier `.wav`
  illisible du dossier (pas un WAV, stéréo…) est ignoré avec un avertissement qui le nomme. Le rapport donne, pour
  chaque essai, la connexion de l'appel de synthèse (protocole négocié, connexion réutilisée ou nouvelle), et signale
  un enregistrement dont la voix court jusqu'à la fin du fichier (clip non coupé).

- `live` : rejoue les enregistrements du corpus dans une vraie session de dictée, avec le micro scripté et à la vitesse
  de la parole, et mesure le taux d'erreur du texte final de la session, celui de la transcription en bloc par le même
  moteur (la mesure de `transcribe`), celui du dernier aperçu, et le délai entre `finish()` et le texte final
  (`--corpus`, `--audio`, `--out`, `--engine`, `--vocabulary`, `--settle`, `--overwrite`). Écrit `live.md` et
  `live.json`. Aucune variable d'environnement. Méthode et incertitudes : `docs/bench/2026-11-14-dictee-en-direct.md`.

- `interview` : mène un entretien entier à partir de fichiers WAV (un par tour de la personne, PCM 16 bits mono), avec la
  **vraie** conversation de l'application (`ConversationSession`) mais sans micro ni haut-parleur : la lecture est simulée par une
  attente. Le tour i n'est poussé qu'après la fin de la réplique i−1 (ou, avec `--interrupt-after`, quelques secondes après son
  début). Options : `--fast-model` et `--strong-model` (obligatoires), `--voice-model` et `--voice` (ensemble ; sans eux, la
  voix du système, dont la synthèse reste en mémoire), `--max-questions` (8), `--interrupt-after`, `--turn-silence` (0,5 ; de 0,3
  à 2,0 s, les bornes des réglages de l'application, recopiées), `--output` (le rapport Markdown ; sans lui, sur la sortie),
  `--overwrite`. Elle lit **toujours** l'endpoint dans l'environnement. Ni la clé, ni l'adresse, ni les noms de modèle et de voix
  ne sont écrits dans le rapport ni sur la sortie. Code de sortie non nul si l'entretien ne rend pas de prompt (le rapport est
  écrit avant). Elle charge le détecteur de voix et Parakeet (téléchargés au premier lancement). Les durées du rapport ne
  contiennent pas le silence de fin de tour et ne sont **pas comparables** à celles de `latency` (la forme des requêtes
  diffère). Le rapport dit lui-même les secondes de silence réellement poussées après chaque tour (au moins 2 s, davantage au-delà
  de 0,5 s environ de `--turn-silence`) et le délai d'un tour « aucune réaction » (la limite de transcription du moteur, 120 s,
  plus 30 s de marge : 150 s). Le rapport n'est écrit qu'à la fin (pas de rapport partiel). **Le lancement réel n'a jamais été exécuté**
  (à la demande de l'utilisateur : il appelle un service et fait travailler la voix du système) :

  ```sh
  export SUPERVOX_BASE_URL="$ADRESSE_DU_SERVICE"
  export SUPERVOX_API_KEY="$CLE_DU_SERVICE"
  swift run supervox-bench interview \
    "$WAV_TOUR_1" "$WAV_TOUR_2" "$WAV_TOUR_3" \
    --fast-model "$MODELE_RAPIDE" --strong-model "$MODELE_FORT" \
    --max-questions 8 --turn-silence 0.5 \
    --output "$DOSSIER_IGNORE/entretien.md"
  ```

Pannes et interruptions :

- chaque requête à l'endpoint est abandonnée après `--request-timeout` secondes (30 par défaut ; option de `transcribe` et de
  `latency`, absente de `live` et de `interview`) sans aucune donnée reçue : c'est un délai d'inactivité, pas une durée totale. La phrase (ou l'essai) est alors en échec.
- dans `transcribe`, un moteur est arrêté après 3 échecs de transport consécutifs (endpoint injoignable ou muet) :
  ses phrases restantes, et sa passe avec vocabulaire, sont en échec avec cette raison ; les moteurs suivants passent.
- les rapports sont réécrits au fil de l'eau, après chaque passe de moteur (`transcribe`), chaque essai
  (`latency`) ou chaque phrase (`live`), avec la mention « Rapport partiel » en tête (et `"complete": false` dans le JSON) tant que le
  lancement n'est pas allé au bout. Un Ctrl-C laisse sur le disque le dernier rapport partiel ; le relancer dans le
  même dossier demande `--overwrite`.

Dossier de sortie (`--out`), contrôlé avant tout chargement de modèle et tout appel réseau :

- `transcribe`, `latency`, `live` et `interview` (le fichier de `--output`) refusent d'écrire sur un rapport existant
  (`transcription.md`, `transcription.json`, `latence.md`, `live.md`, `live.json`) sans `--overwrite`, et le message nomme le
  fichier : une mesure ne se refait pas à l'identique. Le registre des requêtes de synthèse de `latency` est cumulatif et n'est
  jamais effacé.
- `record`, `transcribe`, `latency`, `live` et `interview` (avec `--output`) refusent un dossier situé dans un dépôt git qui ne
  l'ignore pas (vérifié avec `git check-ignore`) : enregistrements et rapports contiennent ta voix et ce que tu as dit. Sans
  `git`, ou hors de tout dépôt, elles écrivent normalement. `interview` refuse en plus un `--output` qui est l'un des WAV
  d'entrée (même avec `--overwrite`), et ne remplace jamais un fichier que git suit : un dossier qui en contient un n'est pas
  tenu pour ignoré (mesuré une fois, avec la version de git de la machine de construction).

### Comparaison des textes

Le taux d'erreur et le rappel des termes comparent des mots normalisés :

- plié, jamais compté comme erreur : la casse, les apostrophes, les traits d'union et la ponctuation (un trait d'union vaut une espace : « e-mail » contre « email » compte comme une graphie séparée contre une jointe) ;
- compté comme erreur : des chiffres contre des nombres en lettres (« 3 » contre « trois »), une graphie jointe
  contre une graphie séparée (« FastAPI » contre « Fast API ») ; les accents comptent ;
- un terme est trouvé si ses mots normalisés se suivent dans la transcription : un moteur qui écrit « Fast API »
  perd le terme « FastAPI » et deux mots.

Au chargement du corpus, un terme de la 3e colonne est refusé, avec son numéro de ligne, s'il ne figure pas dans sa
propre phrase une fois normalisé (il ne pourrait jamais être trouvé), ou s'il se réduit à une seule lettre
(« C++ » et « C# » deviennent « c », trouvé dans « c'est »).

Les commandes qui appellent un service distant (`transcribe` avec le moteur `endpoint`, `latency`, `interview`) lisent deux
variables d'environnement :

- `SUPERVOX_BASE_URL` : adresse de base du service (compatible avec l'API OpenAI) ;
- `SUPERVOX_API_KEY` : clé d'API.

Avertissement de sécurité : avec une adresse en `http://`, la clé d'API voyage en clair sur le réseau.
Utilise une adresse `https://`. Ne mets jamais la clé dans un fichier suivi par git.

Le dossier `bench-data/` (corpus personnels, enregistrements, résultats) est ignoré par git.

## Conception

Voir `docs/superpowers/specs/`.

## Licence

MIT, voir le fichier `LICENSE`.
