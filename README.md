# supervox

[![Tests](https://github.com/cvassort/supervox/actions/workflows/tests.yml/badge.svg)](https://github.com/cvassort/supervox/actions/workflows/tests.yml)

supervox sera une application macOS de dictée et d'entretien vocal. Elle est en cours de construction.
Ce dépôt contient le socle de l'application (voir « Application ») et le banc d'essai : `supervox-bench`, un outil
en ligne de commande qui mesure la qualité de transcription de plusieurs moteurs et le délai de réponse de bout en
bout.

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

Les tests d'intégration sont désactivés par défaut, parce qu'ils téléchargent des modèles ou ouvrent le micro.
Ils ne tournent pas dans le pipeline.

- `SUPERVOX_INTEGRATION=1 swift test` : vrais moteurs de transcription et vrai détecteur de voix. Les modèles sont
  téléchargés au premier passage (leur taille dépend du moteur et n'a pas été mesurée pour ce README). Ces tests
  fabriquent leur audio avec la voix française `Thomas` de macOS (commande `say`) : elle doit être installée.
- `SUPERVOX_MIC=1 swift test` : capture d'environ une seconde de bruit ambiant avec le vrai micro (en mémoire,
  rien n'est écrit sur disque).
- `SUPERVOX_KEYCHAIN=1 swift test` : écrit, lit, remplace et supprime une entrée de test dans le vrai trousseau.
- `SUPERVOX_KEYBOARD=1 swift test` : interroge la vraie disposition de clavier.
- `SUPERVOX_WINDOWS=1 swift test` : construit de vraies fenêtres d'AppKit, sans les afficher.

## Application

Supervox est une application de barre de menus : pas d'icône dans le Dock, une icône d'onde dans la barre de menus.
La dictée elle-même n'est pas encore branchée ; l'application tient aujourd'hui le panneau, les fournisseurs, le
raccourci et les permissions.

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

- Raccourci par défaut : ⌃⌥Espace (contrôle, option, espace). Il ouvre et ferme le panneau, depuis n'importe quelle
  application.
- Au premier lancement (aucun fichier de réglages), le panneau s'ouvre seul : il dit à quoi sert le raccourci et où
  sont les réglages, et propose d'autoriser le micro puis l'Accessibilité. Rien n'est demandé avant ce clic.
- Relancer l'application déjà ouverte ouvre le panneau.
- Les réglages (fournisseurs, raccourci, permissions) s'ouvrent par « Réglages… », dans le menu « … » du panneau ou
  dans celui de l'icône de la barre de menus.
- Si le raccourci est refusé par macOS, ou s'il est aussi un raccourci de macOS activé sur ce Mac, le panneau
  s'ouvre au lancement pour le dire. macOS ne signale pas les conflits avec une autre application : si le raccourci
  n'ouvre pas le panneau, choisissez-en un autre.

### Ce qui est stocké, et où

- Les réglages (fournisseurs sans leur clé, raccourci, dernier mode) : `~/Library/Application Support/Supervox/settings.json`.
  Un fichier au contenu illisible est mis de côté dans le même dossier (`settings.json.illisible-<date>`), jamais
  écrasé ; un fichier qui ne peut pas être lu reste en place ; un fichier écrit par une version plus récente de
  Supervox est gardé tel quel et n'est pas réécrit.
- Les clés d'API : dans le trousseau de connexion, service `dev.supervox.app`, un compte par fournisseur (son
  identifiant). Jamais dans un fichier. Elles ne sont lues qu'au moment d'une requête qui en a besoin.
- Les requêtes porteuses de clé passent par une session réseau sans cache, sans cookie ni identifiant enregistré, et
  ne suivent aucune redirection vers une autre origine.

### Rendre les écrans en images

```sh
swift run supervox-snapshots /chemin/vers/un/dossier
```

`supervox-snapshots` écrit chaque écran du panneau et des réglages en PNG, en clair et en sombre, avec des données
d'exemple (`example.com`) : aucun accès au trousseau, au réseau ni aux réglages réels. Les onglets des réglages
sont rendus sans la barre d'onglets, que la copie d'écran hors écran ne restitue pas fidèlement.

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

Pannes et interruptions :

- chaque requête à l'endpoint est abandonnée après `--request-timeout` secondes (30 par défaut) sans aucune donnée
  reçue : c'est un délai d'inactivité, pas une durée totale. La phrase (ou l'essai) est alors en échec.
- dans `transcribe`, un moteur est arrêté après 3 échecs de transport consécutifs (endpoint injoignable ou muet) :
  ses phrases restantes, et sa passe avec vocabulaire, sont en échec avec cette raison ; les moteurs suivants passent.
- les rapports sont réécrits au fil de l'eau, après chaque passe de moteur (`transcribe`) ou chaque essai
  (`latency`), avec la mention « Rapport partiel » en tête (et `"complete": false` dans le JSON) tant que le
  lancement n'est pas allé au bout. Un Ctrl-C laisse sur le disque le dernier rapport partiel ; le relancer dans le
  même dossier demande `--overwrite`.

Dossier de sortie (`--out`), contrôlé avant tout chargement de modèle et tout appel réseau :

- `transcribe` et `latency` refusent d'écrire sur un rapport existant (`transcription.md`, `transcription.json`,
  `latence.md`) sans `--overwrite`, et le message nomme le fichier : une mesure ne se refait pas à l'identique.
  Le registre des requêtes de synthèse de `latency` est cumulatif et n'est jamais effacé.
- les trois commandes refusent un dossier situé dans un dépôt git qui ne l'ignore pas (vérifié avec
  `git check-ignore`) : enregistrements et rapports contiennent ta voix et ce que tu as dit. Sans `git`, ou hors de
  tout dépôt, elles écrivent normalement.

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

Les commandes qui appellent un service distant lisent deux variables d'environnement :

- `SUPERVOX_BASE_URL` : adresse de base du service (compatible avec l'API OpenAI) ;
- `SUPERVOX_API_KEY` : clé d'API.

Avertissement de sécurité : avec une adresse en `http://`, la clé d'API voyage en clair sur le réseau.
Utilise une adresse `https://`. Ne mets jamais la clé dans un fichier suivi par git.

Le dossier `bench-data/` (corpus personnels, enregistrements, résultats) est ignoré par git.

## Conception

Voir `docs/superpowers/specs/`.

## Licence

MIT, voir le fichier `LICENSE`.
