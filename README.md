# supervox

[![Tests](https://github.com/cvassort/supervox/actions/workflows/tests.yml/badge.svg)](https://github.com/cvassort/supervox/actions/workflows/tests.yml)

supervox sera une application macOS de dictée et d'entretien vocal. Elle est en cours de construction.
Ce dépôt contient l'application telle qu'elle est (le socle, la dictée, sa relecture, les modes à consigne et la correction
à la voix, voir « Application », « Dictée », « Relecture », « Modes » et « Corriger à la voix ») et
le banc d'essai : `supervox-bench`, un outil en ligne de commande qui mesure la qualité de transcription de plusieurs
moteurs, le délai de réponse de bout en bout et la dictée en direct. L'entretien vocal et la voix de réponse sont à venir :
ils n'existent pas encore.

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
L'application tient le panneau, la dictée (voir « Dictée »), la relecture, les modes (voir « Modes »), la correction à la
voix, les fournisseurs, le raccourci et les permissions. Trois modes dictent : la dictée brute (le texte tel quel), la
dictée nettoyée et le prompt (le texte est mis en forme par un modèle de langage, chez le fournisseur que vous avez
réglé). Le quatrième, l'entretien, n'est pas encore fait : le panneau le dit. Avec la dictée brute, rien ne quitte
l'ordinateur sauf le téléchargement des modèles de transcription ; avec un mode à consigne, le texte dicté (jamais
l'audio) part chez votre fournisseur : voir « Modes ».

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
  l'icône, par « Réglages… » et « Quitter Supervox », ou après un collage réussi. Seule exception : dans un mode qui ne
  dicte pas (l'entretien), un second appui, panneau ouvert, le ferme. Pendant une relecture (voir « Relecture »), le
  raccourci ne lance pas de dictée : il commence une correction à la voix (voir « Corriger à la voix »).
- Au premier lancement (aucun fichier de réglages), le panneau s'ouvre seul : il dit à quoi sert le raccourci et où
  sont les réglages, et propose d'autoriser le micro puis l'Accessibilité. Rien n'est demandé avant ce clic.
- Relancer l'application déjà ouverte (`open build/Supervox.app`) ouvre le panneau, sans second exemplaire. Vérifié
  ainsi sur l'application construite ; la relance depuis le Finder ou le Dock ne l'a pas été.
- Un avis sur le fichier de réglages (mis de côté, illisible, version plus récente) ouvre aussi le panneau au
  lancement ; ce n'est pas l'accueil d'un nouvel utilisateur.
- Les réglages (cinq onglets : fournisseurs, raccourci, permissions, transcription, modes) s'ouvrent par « Réglages… »,
  dans le menu « … » du panneau ou dans celui de l'icône de la barre de menus.
- Si le raccourci est refusé par macOS, le panneau s'ouvre au lancement pour le dire. S'il est aussi un raccourci de
  macOS activé sur ce Mac, le panneau s'ouvre pour le dire au premier lancement où c'est le cas ; ensuite l'avis
  reste dans le panneau, qui ne s'ouvre plus seul pour ce raccourci. macOS ne signale pas les conflits avec une autre application : si le raccourci
  n'ouvre pas le panneau, choisissez-en un autre.

### Ce qui est stocké, et où

- Les réglages (fournisseurs sans leur clé, raccourci, dernier mode, réglages de transcription, les modes avec leur
  consigne, leur modèle, leur moteur, leur raccourci et leur choix de relecture, les modèles fort et rapide) :
  `~/Library/Application Support/Supervox/settings.json`. Le fichier est en **version 2** depuis l'étape 5 : un fichier de
  l'étape 4 se lit sans rien mettre de côté, garde son entrée `modeOptions` telle quelle et passe en version 2 à son premier
  enregistrement ; l'application de l'étape 4 qui le relit dit qu'il vient d'une version plus récente et n'y écrit rien.
  Les consignes de vos modes sont dans ce fichier, en clair : n'y mettez rien de confidentiel.
  Un fichier au contenu illisible est mis de côté dans le même dossier (`settings.json.illisible-<date>`), jamais
  écrasé ; un fichier qui ne peut pas être lu (droits, disque) reste en place et rien n'y est écrit jusqu'à la fin de
  la session, même s'il redevient lisible ; un fichier écrit par une version plus récente de Supervox est gardé tel
  quel et n'est pas réécrit.
- Le texte dicté n'est écrit dans aucun fichier ni journal ; le panneau n'en garde que le dernier, en mémoire (le texte
  corrigé en relecture compris, et les versions d'une correction à la voix : quitter l'application les perd). Le bouton « Copier » le met dans le presse-papiers comme
  une copie ordinaire : un gestionnaire d'historique du presse-papiers peut alors le garder (le collage d'une dictée sans
  relecture, lui, marque sa copie comme provisoire et confidentielle pour qu'ils l'ignorent ; le « Coller » de la
  relecture laisse, après coup, une copie ordinaire : voir « Relecture »).
- Les clés d'API : dans le trousseau de connexion, service `dev.supervox.app`, un compte par fournisseur (son
  identifiant). Jamais dans un fichier, ni dans les modes. Elles ne sont lues qu'au moment d'une requête qui en a besoin
  (la liste des modèles, la mise en forme, la correction).
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
précédente, suivante ou les deux, aide de la correction avec et sans raccourci) ; pour les réglages, les onglets
Fournisseurs, Raccourci, Permissions et Transcription (avec leurs feuilles et confirmations), et l'onglet Modes : par
défaut, avec un enregistrement refusé, toute la liste, au premier lancement, les confirmations de suppression, et la
feuille d'un mode (consigne modifiée, Prompt d'origine, sans fournisseur, Entretien, mode personnel, sans liste de modèles,
raccourci refusé, consigne longue). Il n'y a pas d'image pour « Dictée interrompue » ni « Micro indisponible ». Les données sont
d'exemple (`example.com`, textes inventés) : aucun accès au trousseau, au réseau, au presse-papiers ni aux réglages
réels. Les onglets des réglages sont rendus sans la barre d'onglets, que la copie d'écran hors écran ne restitue pas
fidèlement.

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
- **Le texte n'est gardé qu'en mémoire.** Quitter Supervox pendant une relecture le perd, sans demander confirmation.
  Quitter pendant le collage attend, trois secondes au plus, la fin du collage.
- **Pas encore là** : l'historique sur disque, l'annulation après fermeture du panneau, l'entretien vocal et la voix de
  réponse (à venir).

### Modes

Un mode dit ce que devient le texte dicté. Il se règle dans Réglages, onglet Modes (rien ne se règle ailleurs). Chaque mode
a un nom, une consigne, un modèle (facultatif), un moteur de transcription (facultatif), un raccourci (facultatif) et un
choix de relecture.

- **Les quatre modes de base**, dans l'ordre des pastilles du panneau : « Dictée brute » (aucune consigne : le texte est
  collé tel quel), « Dictée nettoyée » (ponctuation, majuscules, hésitations retirées, sens et ton gardés), « Prompt » (la
  demande dictée devient un prompt en cinq parties : Objectif, Contexte, Contraintes, Résultat attendu, Critères de réussite ;
  ce que la dictée ne couvre pas est marqué « Non précisé. », rien n'est inventé) et « Entretien » (pas encore fait : le
  panneau dit « Ce mode arrive à une étape suivante. »). Dictée brute et Entretien ne se suppriment pas ; Dictée nettoyée et
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
- **Modèles fort et rapide.** En tête de l'onglet Modes, section « Modèles ». Le modèle fort sert à la correction à la voix et
  à tout mode sans modèle propre ; un mode peut choisir le sien (« Modèle utilisé »). Le modèle rapide est enregistré pour
  l'entretien vocal, à venir : il ne sert encore à rien. Les modèles proposés sont ceux de la dernière liste lue de chaque
  fournisseur.
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
  de lui-même les étapes (il lit les éléments, l'application ne poste aucune annonce) et que les modèles obéissent aux
  consignes ne sont pas établis : ils sont à essayer (étape 5 de `docs/essai-final.md`).

### Où sont les modèles

Rien n'est embarqué : les modèles se téléchargent depuis Internet, à la demande (bouton « Télécharger » de l'onglet
Transcription, ou à la première dictée qui en a besoin), puis tournent sur ce Mac.

**Ce qui touche le réseau et ce qui ne le touche pas.**
- **Pour la transcription**, le réseau sert au téléchargement des modèles, et à lui seul : le dépôt de modèles de WhisperKit
  (le modèle et son tokenizer) et les modèles de FluidAudio (Parakeet, son petit modèle de vocabulaire, le détecteur de
  voix). L'audio ne part nulle part : les moteurs sont locaux, y compris pour la consigne d'une correction à la voix.
- **Pour la mise en forme et la correction à la voix**, le texte part au fournisseur choisi (voir « Modes ») : un mode sans
  consigne (la dictée brute, un mode personnel vide) n'envoie rien. C'est le seul cas où du texte dicté quitte l'ordinateur ;
  l'audio, jamais.
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

Pannes et interruptions :

- chaque requête à l'endpoint est abandonnée après `--request-timeout` secondes (30 par défaut) sans aucune donnée
  reçue : c'est un délai d'inactivité, pas une durée totale. La phrase (ou l'essai) est alors en échec.
- dans `transcribe`, un moteur est arrêté après 3 échecs de transport consécutifs (endpoint injoignable ou muet) :
  ses phrases restantes, et sa passe avec vocabulaire, sont en échec avec cette raison ; les moteurs suivants passent.
- les rapports sont réécrits au fil de l'eau, après chaque passe de moteur (`transcribe`), chaque essai
  (`latency`) ou chaque phrase (`live`), avec la mention « Rapport partiel » en tête (et `"complete": false` dans le JSON) tant que le
  lancement n'est pas allé au bout. Un Ctrl-C laisse sur le disque le dernier rapport partiel ; le relancer dans le
  même dossier demande `--overwrite`.

Dossier de sortie (`--out`), contrôlé avant tout chargement de modèle et tout appel réseau :

- `transcribe`, `latency` et `live` refusent d'écrire sur un rapport existant (`transcription.md`, `transcription.json`,
  `latence.md`, `live.md`, `live.json`) sans `--overwrite`, et le message nomme le fichier : une mesure ne se refait pas à l'identique.
  Le registre des requêtes de synthèse de `latency` est cumulatif et n'est jamais effacé.
- les quatre commandes refusent un dossier situé dans un dépôt git qui ne l'ignore pas (vérifié avec
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
