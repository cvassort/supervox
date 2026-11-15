# Essai manuel de Supervox

Cette liste est pour la personne qui essaie l'application. Rien ici n'a pu être vérifié par les tests automatiques : ils
n'ouvrent ni le vrai micro, ni le vrai presse-papiers, ni une vraie fenêtre, ni un vrai clavier.

Pour chaque essai : faites le geste, comparez avec le résultat attendu, notez **OK** ou **pas OK** (et ce que vous avez
vu à la place). Un essai marqué **comportement à confirmer** décrit ce que le code prévoit, sans que personne l'ait vu :
c'est justement ce qu'il faut regarder.

Ce fichier est public : n'y écrivez ni texte dicté, ni clé, ni nom de personne.

## Avant de commencer

- Construisez l'application : `Scripts/make-app.sh`, puis `open build/Supervox.app` (voir le `README.md`). Sans identité
  de signature, macOS redemande le micro et l'Accessibilité après chaque construction.
- Il vous faut un micro, et trois applications où l'on peut coller du texte : une application de notes, un terminal
  (Terminal) et un champ de texte dans un navigateur.
- Gardez sous la main du texte à dicter, dans un français courant, avec quelques mots techniques.
- Le raccourci par défaut est ⌃⌥Espace (contrôle, option, espace).
- **Chaque essai qui change un état le rétablit à sa fin** (raccourci, mode, permissions, réseau, moteur, langue,
  vocabulaire, disposition du clavier, relecture) : les essais suivants supposent l'état de départ (raccourci ⌃⌥Espace,
  bascule, mode « Dictée brute », relecture désactivée pour Dictée brute, micro et Accessibilité accordés, réseau actif,
  WhisperKit large-v3 turbo, français, vocabulaire vide). Si un essai échoue pour une raison qui ressemble à un état
  oublié, rétablissez-le avant de conclure. Une seule exception, dite en tête de l'étape 4 : les essais 32 à 45 gardent la
  relecture activée, et l'essai 46 la désactive.

## Étape 2 — socle

### 1. Premier lancement

Pour un vrai premier lancement, il ne doit pas y avoir de fichier de réglages. Quittez l'application, puis déplacez
(sans le supprimer) `settings.json` hors du dossier `~/Library/Application Support/Supervox/`. S'il y a aussi un fichier
`settings.json.illisible-<date>`, déplacez-le : sa seule présence dit à l'application qu'elle a déjà servi, et l'accueil
n'apparaîtrait pas. Ne touchez pas au dossier `Models` voisin : ce sont les modèles de transcription.

1. Lancez l'application.
   - Attendu : une icône en forme d'onde apparaît dans la barre des menus ; aucune icône dans le Dock ; aucune fenêtre
     de permission n'apparaît toute seule.
2. Regardez le panneau, qui s'est ouvert tout seul.
   - Attendu : un mot d'accueil qui dit à quoi sert le raccourci et où sont les réglages ; en dessous, « Prêt » et le
     raccourci ; en bas, une ligne qui dit ce qui manque (micro, Accessibilité) avec un bouton « Autoriser… ». Le
     raccourci est écrit avec les signes du clavier Mac : ⌃ (Contrôle) ressemble à un accent circonflexe, mais c'est bien
     le signe de la touche Contrôle, pas la lettre « ^ ».

### 2. Permissions

1. Cliquez sur « Autoriser… » dans le panneau.
   - Attendu : macOS demande l'accès au micro. Rien n'était demandé avant ce clic.
2. Acceptez, puis cliquez de nouveau sur « Autoriser… ».
   - Attendu : macOS vous envoie vers l'Accessibilité (invite du système, ou fenêtre des Réglages Système) ; accordez
     l'autorisation à Supervox. **Comportement à confirmer** : ce qui s'affiche exactement dépend de macOS.
3. Rouvrez le panneau.
   - Attendu : la ligne des permissions a disparu quand tout est accordé.
4. Refusez l'une des deux dans les Réglages Système, puis rouvrez le panneau.
   - Attendu : la ligne dit ce qui manque et ce que cela empêche (micro : « la dictée est impossible » ;
     Accessibilité : « le texte sera copié, pas collé »). Accordez de nouveau la permission avant la suite.
5. Ouvrez « Réglages… », onglet Permissions.
   - Attendu : « Autorisé », « Pas encore demandé » ou « Non autorisé » pour chacune ; un bouton « Ouvrir les réglages
     du système » pour une permission refusée.

### 3. Raccourci, Échap, clic en dehors, menu

1. Depuis une autre application, tapez ⌃⌥Espace.
   - Attendu : le panneau s'ouvre sans prendre la frappe (l'application de dessous reste active) et la dictée commence
     (voir l'étape 3).
2. Ouvrez le panneau par le menu de l'icône (« Ouvrir le panneau »), puis, sans lancer de dictée, tapez Échap.
   - Attendu : le panneau se ferme. (Pendant une dictée, Échap l'annule : essai 15.)
3. Rouvrez le panneau de la même façon, puis cliquez dans une autre application.
   - Attendu : le panneau se ferme et votre clic a bien servi dans l'autre application.
4. Ouvrez le menu de l'icône.
   - Attendu : « Ouvrir le panneau » (ou « Fermer le panneau » si ouvert), « Réglages… », « Quitter Supervox ».
5. Ouvrez « Réglages… » depuis le menu « … » du panneau.
   - Attendu : le panneau se ferme et la fenêtre de réglages s'ouvre.
6. Quittez par « Quitter Supervox ».
   - Attendu : l'icône disparaît de la barre des menus. Relancez l'application (`open build/Supervox.app`) pour la suite.
7. Choisissez un autre raccourci dans Réglages, onglet Raccourci (cliquez sur le raccourci, tapez la nouvelle
   combinaison), puis essayez-le.
   - Attendu : la nouvelle combinaison lance une dictée (et ouvre le panneau), l'ancienne ne fait plus rien ; annulez la
     dictée par Échap. Une combinaison refusée par macOS est dite dans la fenêtre, et l'ancien raccourci reste actif.
     **Comportement à confirmer** pour les combinaisons que seul macOS refuse. Remettez ⌃⌥Espace avant la suite.

### 4. Relance de l'application

1. L'application étant déjà ouverte, relancez-la : `open build/Supervox.app`, puis depuis le Finder.
   - Attendu : le panneau s'ouvre, sans second exemplaire de l'application. **Comportement à confirmer** pour la
     relance depuis le Finder : seule la commande `open` a été vérifiée.
2. Quittez et relancez l'application.
   - Attendu : les réglages sont repris (fournisseurs, raccourci, dernier mode choisi dans le panneau) et l'accueil du
     premier lancement ne revient pas.

### 5. Fournisseurs et clé d'API

Utilisez une clé d'essai, jamais une clé de production.

1. Réglages, onglet Fournisseurs, « Ajouter un fournisseur… » : un nom, une adresse en `https://`, un type, une clé.
   - Attendu : le fournisseur apparaît avec la clé « Enregistrée ».
2. Cliquez sur « Lister les modèles ».
   - Attendu : « N modèles, liste à jour », ou un message d'erreur lisible (adresse fausse, clé refusée) qui ne montre
     jamais la clé.
3. Cherchez la clé sur le disque : `grep -r "<le début de la clé d'essai>" ~/Library/Application\ Support/Supervox/`.
   - Attendu : aucun résultat. La clé n'est dans aucun fichier.
4. Ouvrez « Trousseaux d'accès » et cherchez `dev.supervox.app`.
   - Attendu : une entrée par fournisseur, nommée par son identifiant.
5. Quittez, relancez, rouvrez l'onglet.
   - Attendu : la clé est toujours « Enregistrée ». Supprimez le fournisseur : la clé disparaît du trousseau.

### 6. Fichier de réglages abîmé

1. Quittez l'application, écrivez n'importe quoi dans `settings.json`, relancez.
   - Attendu : le panneau s'ouvre avec un avis qui dit que le fichier de réglages est illisible, qu'il a été mis de côté
     sous le nom `settings.json.illisible-<date>` et que les réglages par défaut sont utilisés. Le fichier abîmé n'est
     jamais écrasé, et l'accueil du premier lancement n'est pas répété.

### 7. Icônes

1. Regardez l'icône de l'application dans le Finder, puis celle de la barre des menus, en apparence claire puis
   sombre (Réglages Système, Apparence).
   - Attendu : le logo (une onde) est net et lisible dans les deux apparences, sans fond blanc ni bord coupé.

## Étape 3 — dictée

Avant de commencer : micro et Accessibilité accordés, réglages par défaut (WhisperKit), mode « Dictée brute ». À la
première dictée, les modèles manquants se téléchargent : cela peut prendre un moment (leur taille n'a pas été mesurée).

### 8. Une dictée simple, par bascule

1. Placez le curseur dans l'application de notes, tapez ⌃⌥Espace.
   - Attendu : le panneau s'ouvre ; « Préparation… » (avec « Téléchargement du modèle… » si un modèle manque, puis
     « Chargement du modèle… » tant que les moteurs se chargent en mémoire ; moteurs déjà chargés : aucune des deux
     mentions), puis « Enregistrement » avec un point rouge, la durée qui avance et une forme d'onde qui bouge quand vous
     parlez.
2. Parlez deux ou trois phrases.
   - Attendu : le texte en direct apparaît sous la forme d'onde, quatre lignes au plus, la fin du texte toujours
     visible. Ce texte est provisoire : il peut changer en cours de route.
3. Tapez de nouveau ⌃⌥Espace.
   - Attendu : « Transcription… » un court instant, puis le texte final est collé dans l'application de notes et le
     panneau se ferme.

### 9. Collage dans trois applications

Refaites l'essai 8 dans chacune :

1. l'application de notes ;
2. un terminal (Terminal) ;
3. un champ de texte dans un navigateur.
   - Attendu, pour chacune : le texte arrive là où se trouve le curseur, une seule fois, en entier.

**« Collé » ne prouve pas que l'application visée a reçu le texte** : l'application sait seulement qu'elle a envoyé
⌘V. Dans chaque cas, vérifiez dans l'application. Si le texte n'y est pas, ouvrez le panneau (menu de l'icône,
« Ouvrir le panneau ») : la carte « Dernière dictée » montre la fin du texte avec un bouton « Copier ».

### 10. Le presse-papiers est rendu

1. Copiez un texte ordinaire (⌘C), puis faites une dictée collée. Ensuite, collez (⌘V) dans l'application de notes.
   - Attendu : c'est votre texte d'avant qui est collé, pas la dictée.
2. Copiez une image (une capture d'écran copiée au presse-papiers, ⌃⇧⌘4), faites une dictée collée, puis collez dans
   une application qui accepte les images.
   - Attendu : c'est l'image qui est collée, intacte.
3. Dictez, et pendant le collage (une fraction de seconde) copiez autre chose dans une autre application.
   - Attendu : votre copie plus récente est gardée, la dictée ne l'écrase pas. **Comportement à confirmer** : la
     fenêtre de temps est très courte.

### 11. Texte récupérable

1. Après une dictée collée, ouvrez le panneau par le menu de l'icône.
   - Attendu : « Prêt », puis une carte « Dernière dictée » avec la fin du texte et un bouton « Copier ».
2. Cliquez sur « Copier », puis collez dans une application.
   - Attendu : le bouton passe à « Copié » ; c'est le texte entier de la dictée qui est collé, pas seulement la fin
     montrée dans la carte. Le bouton revient à « Copier » à la fermeture du panneau.
3. Quittez l'application, relancez, rouvrez le panneau.
   - Attendu : la carte n'y est plus. Le texte n'est gardé qu'en mémoire, jamais dans un fichier ni dans un journal.
4. Après avoir cliqué sur « Copier », regardez l'historique de votre gestionnaire de presse-papiers, si vous en avez un.
   - Attendu : le texte y apparaît. « Copier » est une copie ordinaire, que ces outils gardent ; le collage automatique,
     lui, marque sa copie provisoire pour qu'ils l'ignorent. Si vous dictez des choses confidentielles, ne cliquez pas
     sur « Copier » avec un tel outil actif. Le « Coller » de la relecture (essai 35) laisse, lui aussi, une copie
     ordinaire que ces outils peuvent garder : même précaution si la relecture est activée.

### 12. Collage avec d'autres claviers

Le collage envoie ⌘V avec la touche qui produit « v » dans la disposition en cours. Changez la disposition du clavier
(Réglages Système, Clavier, Sources de saisie) puis faites une dictée collée avec chacune :

1. AZERTY (Français) ;
2. une disposition où la touche V n'est pas au même endroit : Dvorak, par exemple.
   - Attendu, pour chacune : le texte est collé (et non un autre caractère ni rien du tout). Rétablissez ensuite votre
     disposition habituelle.

### 13. Mode maintien

Réglages, onglet Raccourci, choisissez « Maintenir pour dicter ».

1. Maintenez ⌃⌥Espace, parlez, relâchez.
   - Attendu : la dictée dure tant que vous maintenez ; au relâchement, « Transcription… » puis le texte est collé.
2. Maintenez ⌃⌥Espace, parlez, puis relâchez **d'abord ⌃ et ⌥, ensuite Espace**.
   - Attendu : la dictée s'arrête en moins d'une seconde dans tous les cas (le système peut ne pas signaler ce
     relâchement-là ; l'application vérifie vingt fois par seconde si les touches de modification du raccourci sont
     encore enfoncées).
3. Maintenez ⌃⌥Espace, et relâchez pendant « Préparation… ».
   - Attendu : si vous relâchez bien pendant « Préparation… », le micro ne s'ouvre pas ; le panneau reste ouvert avec
     « Rien à transcrire » et « Aucune parole n'a été entendue. ». Un nouvel appui relance une dictée. Avec des moteurs
     déjà chargés, « Préparation… » est trop brève pour relâcher avant sa fin : le micro s'ouvre alors un instant
     (indicateur orange) et « Rien à transcrire » vient d'une prise vide, pas du micro resté fermé. Pour obtenir un moteur
     froid, changez de variante WhisperKit (essai 22.2) puis dictez : la variante n'est pas préchargée (juste après le
     lancement, au contraire, la préparation attend la fin du préchargement, ce qui n'est pas la même chose).
     **Comportement à confirmer** : la brièveté de « Préparation… » avec des moteurs chargés.
4. En mode maintien, pendant « Préparation… », appuyez de nouveau sur le raccourci.
   - Attendu : cet appui est ignoré, la préparation continue.
5. Dans l'onglet Raccourci, essayez d'enregistrer un raccourci **sans** touche de modification (une lettre, ou une
   touche de fonction comme F5).
   - Attendu : il est refusé, avec un message du genre « Ajoutez ⌃ ou ⌘ : … taperait du texte ». Un raccourci sans touche
     de modification n'existe donc pas dans l'application (`HotKey.validate`) : il n'y a rien à essayer en maintien avec
     lui. Seul un fichier de réglages écrit à la main pourrait en contenir un ; ce cas n'est pas essayé.
6. Maintenez ⌃⌥Espace, parlez, puis, **sans lâcher ⌃⌥**, tenez Échap un instant (une pression franche, de l'ordre d'un
   dixième de seconde ou plus).
   - Attendu : la dictée est annulée, le panneau se ferme, rien n'est collé, l'indicateur du micro s'éteint. Avec ⌃⌥
     tenus, Échap n'est pas l'Échap seul que l'application réserve : en maintien, elle lit donc elle-même l'état de la
     touche vingt fois par seconde ; un effleurement plus bref qu'un vingtième de seconde peut passer entre deux lectures.
     Refaites l'essai pendant « Préparation… » (juste après le lancement de l'application). Après Échap, gardez ⌃⌥Espace
     enfoncé une seconde de plus : rien ne doit redémarrer (le raccourci est encore tenu et plus aucune dictée n'existe ;
     si le système répète l'appui d'une touche tenue, une dictée pourrait repartir : notez-le). **Comportement à
     confirmer** : jamais essayé avec un vrai clavier ; notez si une pression normale suffit toujours.

### 14. Bascule : appui pendant la préparation

Revenez à « Appuyer pour commencer et pour terminer la dictée ».

1. Tapez ⌃⌥Espace, puis retapez-le aussitôt, pendant « Préparation… » (ou « Téléchargement du modèle… »).
   - Attendu : le second appui est ignoré ; la dictée démarre normalement et continue jusqu'à votre prochain appui.
2. Tapez ⌃⌥Espace pendant « Transcription… ».
   - Attendu : ignoré aussi.

### 15. Échap

1. Pendant « Enregistrement », tapez Échap.
   - Attendu : la dictée est annulée, le panneau se ferme, rien n'est collé, l'indicateur du micro de macOS s'éteint.
2. Pendant « Transcription… », tapez Échap.
   - Attendu : même chose, rien n'est collé.
3. Pendant un téléchargement de modèle (« Préparation… », « Téléchargement du modèle… »), tapez Échap. Pour que ce soit
   visible, il faut au moins deux modèles à télécharger (supprimez le détecteur de voix et Parakeet, par exemple).
   - Attendu : la dictée est annulée et le panneau se ferme. **Comportement à confirmer** : d'après le code, le modèle
     en cours de téléchargement finit en arrière-plan, et ceux qui venaient après dans la liste ne sont pas lancés ;
     vérifiez dans Réglages, onglet Transcription, que la ligne du premier passe à « Prêt » et que celle des suivants
     reste « Non téléchargé ». Le téléchargement n'est pas relancé par l'annulation. Retéléchargez les modèles supprimés
     (onglet Transcription) avant la suite.
4. Pendant une dictée, cliquez dans une autre application.
   - Attendu : le clic est sans effet sur le panneau, qui reste ouvert et continue d'enregistrer. En dehors d'une
     dictée, ce même clic le ferme.

### 16. Le raccourci et le panneau ouvert

1. Ouvrez le panneau par le menu de l'icône (« Prêt »), puis tapez ⌃⌥Espace.
   - Attendu : une dictée démarre ; le raccourci ne ferme pas le panneau.
2. Après une erreur (par exemple « Rien à transcrire »), tapez ⌃⌥Espace.
   - Attendu : une nouvelle dictée démarre.
3. Le panneau se ferme dans ces cas : Échap, clic dans une autre application hors dictée et hors relecture (essai 38),
   le menu de l'icône, « Réglages… » ou « Quitter Supervox », un collage réussi, et, dans un mode autre que la dictée
   brute, le raccourci lui-même (essai 5 ci-dessous). Pendant une relecture, le raccourci ne fait rien (essai 41).
4. Ouvrez le panneau par le menu de l'icône, cliquez sur une autre pastille que « Dictée brute » (par exemple
   « Entretien »), puis fermez le panneau (Échap). Tapez ensuite ⌃⌥Espace.
   - Attendu : le panneau s'ouvre avec « Ce mode arrive à une étape suivante. » et aucune dictée ne démarre.
5. Tapez de nouveau ⌃⌥Espace, panneau ouvert.
   - Attendu : le panneau se ferme (c'est le seul cas où le raccourci le ferme). Si vous tapiez le raccourci avec le
     panneau déjà ouvert sur ce mode, avant de l'avoir fermé, il se fermerait aussi, sans montrer le message.
6. **Revenez à la pastille « Dictée brute »** (ouvrez le panneau par le menu de l'icône, cliquez sur « Dictée brute »).
   - Attendu : l'application garde le dernier mode choisi, même après un redémarrage, et refuse de dicter dans un autre
     (« Ce mode arrive à une étape suivante. ») : sans ce retour, les essais 17 et suivants échouent tous.

### 17. Silence complet

1. Tapez ⌃⌥Espace, ne dites rien pendant quelques secondes, retapez.
   - Attendu : « Rien à transcrire » et « Aucune parole n'a été entendue. » ; rien n'est collé, le presse-papiers est
     intact ; le panneau reste ouvert. Si vous avez déjà dicté quelque chose depuis le lancement, la carte « Dernière
     dictée » (le texte d'avant) est affichée dessous : ce n'est pas le résultat de cette dictée. **Comportement à
     confirmer** : cela dépend du détecteur de voix sur un vrai bruit de pièce. Aucune durée minimale de parole n'est
     exigée : un bruit pris pour de la voix part au moteur final, qui peut renvoyer un texte inventé, et ce texte serait
     collé. Refaites l'essai en tapant au clavier, puis en soufflant près du micro, et notez ce qui est collé.

### 18. Refus de l'Accessibilité

1. Retirez l'autorisation d'Accessibilité à Supervox (Réglages Système), puis faites une dictée.
   - Attendu : le texte n'est pas collé ; le panneau reste ouvert avec « Texte copié », une phrase qui explique qu'il
     faut faire ⌘V soi-même et accorder l'Accessibilité, la carte du texte et « Copier ».
2. Faites ⌘V dans une application.
   - Attendu : le texte dicté est collé.
3. Retirez le micro à Supervox, tapez ⌃⌥Espace.
   - Attendu : le panneau s'ouvre, aucune dictée ne démarre, la ligne des permissions dit que le micro manque (« la
     dictée est impossible »). Le titre du panneau reste « Prêt » : l'application ne le change pas dans ce cas ; notez si
     c'est déroutant. Rendez à Supervox le micro et l'Accessibilité avant la suite.

### 19. Premier téléchargement des modèles

Il y en a cinq : Parakeet (qui comprend un petit modèle pour le vocabulaire), les trois variantes de Whisper (large-v3
turbo, small, base) et le détecteur de voix. Si un modèle est déjà sur ce Mac, supprimez-le par son bouton « Supprimer… »
(la fenêtre de confirmation dit ce qui sera effacé, et que les fichiers de Parakeet sont dans un dossier partagé avec
d'autres applications).

1. Réglages, onglet Transcription : cliquez sur « Télécharger » pour chaque modèle, l'un après l'autre.
   - Attendu : la ligne passe à « Téléchargement en cours… » (ou « Téléchargement : N % ») avec une barre, puis à
     « Prêt » ; le bouton Télécharger disparaît pendant le téléchargement. Le bouton de Parakeet télécharge deux modèles
     de suite (la reconnaissance, puis le petit modèle du vocabulaire) ; tant que celui-ci manque, une légende sous la
     ligne le dit.
2. Supprimez un modèle, choisissez le moteur qui l'utilise, puis lancez une dictée : c'est la dictée qui le télécharge.
   - Attendu : « Préparation… » et « Téléchargement du modèle… » dans le panneau, puis « Chargement du modèle… » une fois
     le téléchargement fini (la première mention ne reste pas pendant la seconde) ; la dictée démarre une fois le modèle
     prêt. Une dictée ne télécharge que ce dont elle a besoin : le détecteur de voix, Parakeet (sa seule
     reconnaissance), la variante WhisperKit choisie si c'est le moteur, et le petit modèle du vocabulaire seulement si
     la liste de vocabulaire n'est pas vide. Les autres modèles restent « Non téléchargé ».
3. Pendant ce téléchargement, ouvrez Réglages (menu « … » du panneau).
   - Attendu : le panneau se ferme et la dictée est interrompue (essai 3.5) ; le téléchargement en cours, lui, continue.
     Dans l'onglet Transcription, la ligne du modèle indique « Téléchargement en cours… », puis « Prêt ».
     **Comportement à confirmer** : l'onglet n'est relu qu'à son ouverture et à chaque action ; ne vous attendez pas à
     voir la barre avancer toute seule si l'onglet était déjà ouvert.
4. Coupez Internet puis lancez une dictée qui demande un téléchargement.
   - Attendu : un message d'échec (« La transcription n'a pas pu être préparée. Ouvrez les Réglages, onglet
     Transcription… ») ; un nouvel appui relance une dictée. **Comportement à confirmer** : le temps avant l'échec dépend
     des délais du réseau, non mesurés ; notez s'il y a un blocage et combien de temps il dure (Échap en sort). Rétablissez
     Internet avant la suite.
5. Supprimez Parakeet puis lancez une dictée **sans vocabulaire** (le vocabulaire vide) : seule la reconnaissance se
   télécharge. Saisissez ensuite un vocabulaire, coupez Internet, et dictez.
   - Attendu : la dictée a lieu quand même, sans vocabulaire, et le panneau le dit : « Le vocabulaire n'a pas servi à
     cette dictée : le petit modèle qui le reconnaît n'a pas pu être téléchargé. Il sera retenté à la prochaine
     dictée. » **Comportement à confirmer** : ce chemin n'a jamais été vu avec un vrai téléchargement. Rétablissez
     Internet, puis videz le vocabulaire (essai 22.4) avant la suite.

### 20. Supprimer un modèle

1. Lancez une dictée, puis, **pendant qu'elle dure**, essayez de supprimer un modèle dans la fenêtre de réglages
   (ouverte avant la dictée).
   - Attendu : la suppression est refusée avec le message « Une dictée est en cours : attendez qu'elle se termine pour
     supprimer un modèle. ». **Comportement à confirmer** : la fenêtre de réglages et la dictée en même temps.
2. Supprimez Parakeet (ligne « Parakeet », « Supprimer… », confirmez), puis lancez une dictée.
   - Attendu : un avis dit que la prochaine dictée le téléchargera de nouveau ; la dictée suivante le retélécharge
     (« Téléchargement du modèle… ») puis fonctionne.
3. Pendant le téléchargement d'un modèle (depuis son bouton « Télécharger »), essayez de le supprimer.
   - Attendu : le bouton Supprimer n'est pas proposé tant que la ligne indique « Téléchargement en cours… ». Pour
     Parakeet, la suppression est aussi refusée pendant que son petit modèle de vocabulaire se télécharge.

### 21. Vocabulaire

Choisissez WhisperKit, avec son modèle téléchargé.

1. Dans « Vocabulaire », saisissez une liste très longue (une quarantaine de termes techniques, un par ligne), puis
   cliquez ailleurs ou sur « Enregistrer le vocabulaire ».
   - Attendu : la liste est refusée avec un message rouge ; **ce que vous avez saisi reste dans le champ**, rien n'est
     effacé. L'ancien vocabulaire reste en vigueur.
2. Relisez le message : « … équivaut à N morceaux de mots et le modèle en accepte N au plus (un terme long ou rare
   en compte plusieurs) ».
   - Question : est-il clair ? Comprenez-vous ce qu'est un « morceau de mot » et ce qu'il faut faire ? Notez ce qui
     n'est pas clair.
3. Réduisez la liste, enregistrez.
   - Attendu : le message disparaît, la liste est gardée.

### 22. Changer de réglage sans relancer

Sans quitter l'application, changez chaque réglage puis faites une dictée.

1. Le moteur (WhisperKit, Parakeet).
   - Attendu : avec Parakeet la transcription est nettement plus rapide.
2. Le modèle WhisperKit (large-v3 turbo, small, base).
   - Attendu : la dictée suivante prend le nouveau modèle (le téléchargement se fait si besoin).
3. La langue (par exemple Anglais, puis dictez une phrase en anglais).
   - Attendu : la phrase est transcrite en anglais. La langue ne compte que pour WhisperKit.
4. Le vocabulaire (ajoutez un terme rare, dictez-le).
   - Attendu : le terme est écrit comme dans la liste. Un avis apparaît dans le panneau si la liste a dû être raccourcie
     ou écartée pour cette dictée (trop longue pour le modèle, longueur impossible à vérifier, ou petit modèle du
     vocabulaire indisponible).
5. **Rétablissez l'état de départ** : WhisperKit, large-v3 turbo, Français, vocabulaire vide.
   - Attendu : les essais 23 et suivants dictent en français avec WhisperKit et sans vocabulaire ; avec Parakeet, la
     langue ne compte pas, et avec un vocabulaire resté en place la dictée n'est pas celle que ces essais décrivent.

### 23. Une dictée longue

1. Dictez sans interruption pendant plus de 15 secondes.
   - Attendu : le texte en direct peut perdre le début du passage (il ne suit que les dernières secondes de parole) ;
     **le texte final collé est complet, du début à la fin**.
2. Comparez le texte collé à ce que vous avez dit.
   - Attendu : rien ne manque au début.

### 24. Deux dictées coup sur coup

1. Faites une dictée, puis, dès que le texte est collé, tapez ⌃⌥Espace et faites-en une seconde.
   - Attendu : chaque texte est collé une fois, dans l'ordre, sans mélange. Un appui qui tombe pendant l'instant où le
     presse-papiers est rendu (moins d'une demi-seconde, durée choisie à la conception, non mesurée) est ignoré :
     recommencez l'appui.
2. Quand les deux sont finies, collez (⌘V).
   - Attendu : votre presse-papiers d'origine est revenu.

### 25. Le panneau suit son contenu

Le panneau a la hauteur de son contenu : sa fenêtre est ancrée par le haut et grandit ou rétrécit vers le bas.

1. Ouvrez le panneau par le menu de l'icône (« Prêt » seul), puis tapez ⌃⌥Espace.
   - Attendu : à « Préparation… », le panneau est plus bas qu'au repos (la ligne du raccourci et les permissions font
     place à l'état de la dictée) ; il grandit à « Enregistrement », qui est la hauteur la plus haute de cette séquence. Son
     bord haut ne bouge pas ; rien ne sort de l'écran. **Comportement à confirmer** : le saut de hauteur, jamais vu à
     l'écran (hauteurs relevées sur les images rendues : « Prêt » 183 points, préparation 139, enregistrement 229).
2. Parlez longtemps, jusqu'à remplir plus de quatre lignes de texte en direct.
   - Attendu : la hauteur ne change pas à chaque ligne (la place de quatre lignes est réservée dès le début de
     l'enregistrement) ; le texte en direct ne dépasse jamais quatre lignes et montre sa fin.
3. Terminez la dictée avec une erreur (silence : « Rien à transcrire »), puis laissez le panneau ouvert.
   - Attendu : le panneau change de hauteur pour l'erreur, sans clignoter. L'application ne ramène pas un panneau ouvert à
     « Prêt » tant que vous ne l'avez pas fermé : fermez-le (Échap) puis rouvrez-le par le menu de l'icône ; il montre
     « Prêt » seul et retrouve la hauteur de repos, sans grand vide dessous.
4. Faites apparaître un message long (le refus de l'Accessibilité : retirez de nouveau l'autorisation comme à l'essai 18,
   puis rendez-la après l'essai) avec un dernier texte long dessous.
   - Attendu : le panneau est plus haut, rien n'est coupé ni recouvert par le menu « … » ; le message long est coupé
     proprement par « … » s'il dépasse quatre lignes.
5. Répétez l'essai 1 avec le panneau placé sur un écran plus petit ou la fenêtre de l'application de dessous proche du bas.
   - Attendu : le panneau reste entièrement visible. **Comportement à confirmer** : le redimensionnement a été vérifié
     sur une fenêtre hors écran seulement, jamais à l'écran.

### 26. Dictée hors ligne, modèles présents

Les modèles nécessaires aux réglages courants sont « Prêt » dans l'onglet Transcription (détecteur de voix, Parakeet, la
variante WhisperKit choisie). Pour l'étape 2, avant de couper Internet : la ligne de Parakeet ne doit plus avoir de
légende (le petit modèle du vocabulaire est prêt ; sinon, téléchargez-le par le bouton de la ligne).

1. Coupez Internet (Wi-Fi et câble), quittez l'application puis relancez-la, et dictez.
   - Attendu : la dictée a lieu normalement : ni « Téléchargement du modèle… », ni « La transcription n'a pas pu être
     préparée ». « Chargement du modèle… » peut s'afficher quelques instants. **Comportement à confirmer** : le chargement
     de WhisperKit depuis son dossier, sans réseau, est lu dans le code mais n'a jamais été essayé hors ligne.
2. Refaites l'essai avec le moteur Parakeet (essai 22.1), puis avec un vocabulaire non vide (le petit modèle du
   vocabulaire doit être « Prêt » : la ligne de Parakeet n'a plus de légende).
   - Attendu : même résultat, hors ligne. Rétablissez ensuite WhisperKit et videz le vocabulaire (essai 22.5).
3. Essai pour qui veut voir une limite : un modèle WhisperKit « Prêt » dont le fichier du tokenizer manque (dossier
   `Models/models/openai/` de Supervox, voir le README) ne se charge pas hors ligne, alors que l'onglet dit « Prêt » (même
   chose, sans réseau non plus, si le fichier existe mais est illisible).
   - Attendu : l'échec de préparation, avec une phrase qui renvoie à l'onglet Transcription : « s'il est indiqué « Prêt »,
     vous pouvez le supprimer puis le télécharger de nouveau (cela demande une connexion à Internet) » : hors ligne, ne le
     supprimez pas. Le préchargement du lancement, lui, n'a pas lieu dans ce cas (le tokenizer ne se charge pas) et ne
     télécharge rien. **Comportement à confirmer** : déduit du code, jamais essayé.
4. Rétablissez Internet.

### 27. Micro coupé pendant la prise

1. Choisissez un casque (USB ou sans fil) comme entrée (Réglages Système, Son, Entrée), commencez une dictée en bascule,
   parlez, puis débranchez le casque (ou éteignez-le) en pleine prise.
   - Attendu : une seconde environ après la coupure, la dictée échoue : « Micro indisponible » et « Le micro ne
     fonctionne pas : le micro s'est arrêté pendant la prise. » ; rien n'est collé, l'indicateur du micro s'éteint.
     **Comportement à confirmer** : l'arrêt du flux audio à un débranchement n'a jamais été observé sur un vrai appareil ;
     si macOS bascule seul sur un autre micro et que le son continue, la dictée continue aussi (notez ce que vous voyez).
     Rétablissez ensuite votre entrée audio habituelle.
2. Même chose en mode maintien (essai 13). Revenez ensuite à la bascule (essai 14).
3. Micro branché, ne dites rien pendant dix secondes.
   - Attendu : aucun échec de micro ; seulement « Rien à transcrire » à la fin. Un vrai micro livre des tranches même dans
     le silence. **Comportement à confirmer** : l'écart entre l'ouverture du micro et la première tranche n'a pas été
     mesuré (casque sans fil compris) ; l'application lui laisse 3 secondes (1 seconde ensuite entre deux tranches) ; si un
     micro lent déclenche l'échec à tort, ou si la forme d'onde met plus d'une seconde à bouger, notez le matériel et le délai.

### 28. Durée de « Chargement du modèle… »

À chronométrer (aucune durée n'a été mesurée) :

1. Quittez l'application, relancez-la, et tapez ⌃⌥Espace aussitôt (première dictée après le lancement).
   - Attendu : « Préparation… » avec « Chargement du modèle… » (pas « Téléchargement du modèle… »), puis
     « Enregistrement ». Une dictée lancée pendant le préchargement attend sa fin : la mention reste affichée pendant cette
     attente, et c'est la durée du chargement total que vous chronométrez (le préchargement est probablement déjà en cours
     à votre appui : ce n'est pas un chargement « à froid » séparé du préchargement). Notez la durée (variante large-v3
     turbo, puis, après avoir choisi Parakeet, la même mesure ; rétablissez WhisperKit ensuite, essai 22.5).
2. Relancez l'application, attendez quelques dizaines de secondes (le préchargement se fait en tâche de fond, sans
   téléchargement), puis dictez.
   - Attendu : « Préparation… » très brève, sans « Chargement du modèle… » si le préchargement est fini ; sinon la
     mention s'affiche moins longtemps qu'à l'essai 1. Notez les deux durées. **Comportement à confirmer** : la durée du
     préchargement, le fait qu'il ne ralentit pas l'affichage du panneau au lancement (conçu ainsi, jamais vu à l'écran), et
     qu'un téléchargement ou une suppression de modèle demandé pendant ces secondes attend la fin du préchargement.
3. Faites une seconde dictée tout de suite après la première.
   - Attendu : aucune mention de chargement (les moteurs sont gardés d'une dictée à l'autre).
4. Changez de variante WhisperKit (essai 22.2, modèle déjà téléchargé), puis dictez.
   - Attendu : « Chargement du modèle… » revient (la variante n'était pas chargée). Rétablissez large-v3 turbo ensuite.

### 29. Quitter pendant le collage

Placez dans le presse-papiers un texte reconnaissable (⌘C), faites une dictée courte, et choisissez « Quitter Supervox »
dans le menu de l'icône **juste après** que le texte est collé (la fenêtre est d'une fraction de seconde : plusieurs essais).

1. Après la fermeture de l'application, collez (⌘V) dans une application de notes.
   - Attendu : c'est votre texte reconnaissable qui est collé, pas la dictée : l'application attend, trois secondes au
     plus, que le presse-papiers soit rendu avant de se terminer. **Comportement à confirmer** : jamais essayé ; cette
     fenêtre est très courte et difficile à viser. Relancez l'application pour la suite.

### 30. Touches de modification restées enfoncées au collage

1. En bascule, terminez une dictée en tapant ⌃⌥Espace et **gardez ⌃ ou ⌥ enfoncé** plus de deux secondes, le temps de la
   transcription et du collage.
   - Attendu : le texte n'est pas collé (une seconde d'attente, puis repli) ; le panneau reste ouvert avec « Texte
     copié » et une phrase qui dit que des touches de modification sont restées enfoncées et qu'il faut relâcher puis
     faire ⌘V. Le texte est dans le presse-papiers (votre contenu d'avant n'est pas rendu). Relâchées à temps, le collage
     se fait normalement.

### 31. Fin automatique à cinq minutes

1. En bascule, lancez une dictée et parlez par moments, sans la terminer, pendant plus de cinq minutes.
   - Attendu : à cinq minutes (durée affichée), la dictée se termine d'elle-même : « Transcription… », puis le texte est
     collé comme si vous aviez retapé le raccourci. **Comportement à confirmer** : jamais vu ; la durée de transcription
     d'une prise de cinq minutes n'a pas été mesurée. En maintien, avec ⌃⌥ encore tenus à ce moment, le texte est copié
     et non collé (essai 30).

## Étape 4 — relecture

À la fin d'une dictée, le texte peut ne pas être collé tout de suite : il s'affiche dans le panneau, dans un champ où
l'on corrige au clavier, puis on choisit « Coller » ou « Copier ». À cette étape, seule la « Dictée brute » dicte (les
autres pastilles disent « Ce mode arrive à une étape suivante. ») : c'est donc elle qu'on essaie, avec la relecture
activée dans Réglages, onglet Modes.

**Les états de cette étape.** Départ : relecture désactivée pour Dictée brute. L'essai 32 l'active ; les essais 34 à 45
la supposent activée ; l'essai 46 la désactive et rétablit l'état de départ. C'est la seule exception à la règle de
l'état rétabli d'un essai à l'autre. L'essai 33 modifie le fichier de réglages et le remet en état.

### Non vérifié automatiquement

Les tests automatiques ne peuvent pas voir ces points : ils n'ont ni vrai écran, ni vrai clavier, ni vrai presse-papiers.
Les essais ci-dessous sont faits pour les regarder.

- Que la frappe revienne à l'application de dessous quand le panneau la rend (après « Coller »). Le code retire le
  panneau de l'écran puis le remet devant, ce qui doit rendre la touche à l'application au premier plan : seul un vrai
  écran le dit (essais 35 et 44).
- Que Supervox ne passe pas au premier plan pendant la relecture : la barre des menus doit rester celle de
  l'application de dessous. Cette règle a été retirée des tests automatiques : dans le processus de test, le système
  a déclaré l'application active dès que le panneau est devenu clé, et ce que cela donne sur un vrai écran n'est pas
  établi (essai 34).
- ⌘↩ avec un vrai clavier dans un panneau qui n'active pas l'application : le test lui passe un événement fabriqué. Et
  le repli « touches de modification tenues » quand ⌘ reste enfoncé plus d'une seconde (essai 44).
- Que le panneau perde vraiment la frappe quand on clique dans une autre application, et la reprenne au clic dans le
  champ : les tests postent eux-mêmes les notifications de perte et de reprise de la clé, hors écran. C'est de là que
  l'aide tire l'annonce de ⌘↩ (essai 38) ; si le système ne les envoie pas, l'aide mentirait.
- Que le bouton « Coller » soit bleu (couleur d'accent) dans le vrai panneau : cela suppose que SwiftUI y voie la fenêtre
  comme clé. Et qu'un « Coller » actif mais grisé (panneau sans la frappe) ne se confonde pas avec un bouton inactif.
- L'effet réel de ⌘X, ⌘C et ⌘V dans le champ (aucun test n'écrit dans le vrai presse-papiers), et celui de ⌘A, ⌘Z et
  ⇧⌘Z au clavier (les tests leur passent des événements fabriqués).
- Le clavier AZERTY, les touches mortes (^ puis e), le menu d'accents de l'appui long, et une méthode de saisie à
  composition longue (japonais, chinois) : le champ ne doit pas être réécrit pendant un texte marqué (essai 37). Échap
  pendant le menu d'accents ou une touche morte en attente (Échap est réservé par Supervox).
- Le rendu du champ à l'écran : les images rendues hors écran ne montrent ni le curseur, ni la sélection, ni le
  défileur, ni le défilement ; « Coller » y est dessiné en couleur d'accent parce que le panneau y est supposé clé.
- Le délai de 0,15 s entre le retrait de la frappe et le collage : il n'est pas mesuré. S'il est trop court, le texte
  part dans le vide ou dans le panneau (essai 35).
- La hauteur du panneau avec un texte long, surtout sur un petit écran : le champ s'arrête à seize lignes, un choix
  non mesuré (essai 43). Avec « Afficher les barres de défilement : toujours » (Réglages Système, Apparence), la
  dernière ligne peut être coupée : la mesure de hauteur ne retire pas la largeur d'une barre fixe (non vu).
- Qu'il n'y ait aucun clignotement à la fermeture du panneau ni au moment de « Coller » : la fermeture est un seul
  retrait de l'écran (vérifié sur la suite des appels, pas à l'œil).
- Dans l'onglet Modes, l'interrupteur qui revient à sa position enregistrée après un enregistrement refusé : le
  modèle est testé, pas le dessin du vrai contrôle (essai 33).
- Que les cinq onglets des Réglages tiennent dans la fenêtre : les images rendues sont faites sans la barre des
  onglets (essai 32).
- Que le texte reste copié après « Coller » : si le système refuse cette copie, le contenu d'origine du presse-papiers
  est rendu, sans avis (essai 35). Si une copie universelle entre appareils Apple est active, on ne sait pas si le texte
  copié par « Coller » part sur un autre appareil (même question pour « Copier » à l'étape 3).
- ⌘Q pendant la relecture, avant et après une ouverture des Réglages : voir « À savoir » et l'essai 40 ; le comportement
  est supposé, jamais vu.
- Un raccourci tenu au moment où la relecture s'ouvre (bascule avec une transcription très courte, ou maintien) : aucun
  caractère parasite ne doit entrer dans le champ. Possible, non vu.
- Un champ sécurisé en cible (champ de mot de passe, « Secure Keyboard Entry » du terminal) : le ⌘V posté peut être
  bloqué alors que le résultat dit « collé » ; le panneau se ferme et le texte n'est plus que dans « Dernière dictée ».
  Déjà vrai à l'étape 3, plus gênant ici.
- VoiceOver : le nom du champ (« Texte à relire »), l'annonce de « Collage… » et celle de la raison d'un échec.
- Échap non réservé (l'avis de refus apparaît) : pendant la relecture, Échap arriverait au champ, qui pourrait ouvrir la
  liste de complétion ; seuls le menu de l'icône, « Coller » ou les Réglages ferment alors le panneau.
- Réglages ouverts, puis une relecture : une capture de raccourci en cours ne doit pas être interrompue par le panneau
  qui devient clé (il peut poster `didBecomeActive` et `didResignActive`).
- Plusieurs écrans, un autre bureau, une application en plein écran : le panneau devient clé et rend la frappe comme
  ailleurs.

### À savoir avant d'essayer

- **Quitter Supervox pendant une relecture perd le texte en cours, sans demander confirmation** : il n'est gardé qu'en
  mémoire, jamais dans un fichier. Fermer le panneau d'une autre façon (Échap, menu de l'icône, « Réglages… ») le garde
  dans « Dernière dictée » jusqu'à ce qu'on quitte.
- **Le raccourci global ne fait rien pendant la relecture** (ni pendant le collage) : il faut d'abord la fermer
  (Échap) ou coller.
- **Un clic en dehors du panneau ne le ferme pas pendant la relecture**, comme pendant une dictée : le clic sert à
  choisir où coller.
- **Le réglage « Relire avant de coller » est lu à l'appui qui commence la dictée** : le changer pendant une dictée ne
  vaut qu'à la suivante.
- **« Coller » colle le texte et le laisse copié** dans le presse-papiers (un second ⌘V ailleurs le recolle). Une dictée
  sans relecture, elle, rend toujours le presse-papiers d'origine (essai 10).
- Ouvrir « Réglages… » pendant une relecture ferme le panneau : le texte part dans « Dernière dictée ».
- **⌘Q dans le panneau peut quitter Supervox, et le texte en cours est alors perdu** (même règle que « Quitter » ci-dessus,
  sans confirmation). Le panneau ne retient pas ⌘Q : si les Réglages ont été ouverts au moins une fois depuis le
  lancement, l'application a un menu principal, avec « Quitter » sur ⌘Q, qui répondrait ; sinon ⌘Q ne ferait rien. C'est
  déduit du code, pas vu. Même risque en croyant taper dans l'application de dessous, dont la barre de menus reste affichée.
- Il n'y a pas de bouton « Corriger à la voix » à cette étape.

### 32. Réglage « Relire avant de coller »

1. Ouvrez « Réglages… » (menu de l'icône) et regardez la barre des onglets.
   - Attendu : cinq onglets, Fournisseurs, Raccourci, Permissions, Transcription et Modes, tous lisibles, aucun coupé ni
     caché. **Comportement à confirmer** : la fenêtre a une taille fixe (600 sur 460 points) ; jamais vue à l'écran avec
     sa barre d'onglets.
2. Ouvrez l'onglet Modes.
   - Attendu : une phrase d'explication en haut (« Quand la relecture est activée, le texte s'affiche dans le panneau à
     la fin de la dictée… »), puis quatre lignes dans l'ordre des pastilles du panneau : Dictée brute, Dictée nettoyée,
     Prompt, Entretien. Chaque ligne a, à droite, un interrupteur « Relire avant de coller », sauf Entretien, qui n'en a
     pas et dit « Toujours relu : l'entretien passe toujours par la relecture. » Si vous n'y aviez jamais touché :
     Dictée brute et Dictée nettoyée éteints, Prompt allumé. Dictée nettoyée et Prompt disent « Ce mode arrive à une
     étape suivante ; ce réglage vaudra dès qu'il sera là. »
3. Allumez l'interrupteur de Dictée brute.
   - Attendu : il reste allumé, sans message d'erreur.
4. Quittez Supervox (menu de l'icône), relancez-le, rouvrez « Réglages… », onglet Modes.
   - Attendu : Dictée brute est toujours allumé, Entretien toujours sans interrupteur : le choix est gardé. **Laissez
     Dictée brute allumé** : les essais 34 à 45 le supposent (l'essai 46 l'éteint).

### 33. Fichier de réglages d'avant la relecture, et enregistrement refusé

Le dossier est `~/Library/Application Support/Supervox/`.

1. Quittez Supervox. Copiez `settings.json` ailleurs : c'est la sauvegarde.
2. Ouvrez le fichier d'origine dans un éditeur de texte et effacez-y l'entrée « modeOptions » tout entière (son nom,
   ses accolades, ce qu'elles contiennent, et la virgule qui la suit). Elle se trouve entre les entrées « lastModeID »
   et « providers » (les entrées sont rangées par ordre alphabétique : lu dans le code, jamais vu dans un vrai fichier).
   Le fichier est alors tel que l'étape 3 l'écrivait. Relancez Supervox.
   - Attendu : aucun fichier `settings.json.illisible-<date>` n'est apparu dans le dossier ; le panneau ne parle pas de
     fichier illisible et l'accueil du premier lancement ne revient pas ; le raccourci, les fournisseurs, les réglages de
     transcription et le dernier mode sont ceux de la sauvegarde. Dans l'onglet Modes, Dictée brute est éteint (plus
     aucun choix enregistré).
3. Cliquez sur une autre pastille du panneau, puis revenez à « Dictée brute ». Comparez le fichier avec la sauvegarde.
   - Attendu : le fichier est réécrit avec les mêmes entrées que la sauvegarde, plus une entrée « modeOptions » dont les
     accolades sont vides : elle ne porte un choix qu'après une bascule dans l'onglet Modes.
4. Dans l'onglet Modes, allumez Dictée brute.
   - Attendu : dans le fichier, « modeOptions » contient maintenant une entrée « dictee-brute » avec
     `"reviewBeforePaste" : true`. L'interrupteur reste allumé, état à garder pour la suite.
5. **Enregistrement refusé.** Copiez de nouveau `settings.json` ailleurs (sauvegarde récente). Sans quitter Supervox,
   avec la fenêtre de réglages ouverte sur l'onglet Modes, remplacez le contenu du fichier par n'importe quel texte
   (qui n'est pas du réglage), puis cliquez sur l'interrupteur de Dictée brute (il est allumé : il va s'éteindre).
   - Attendu : une bande rouge apparaît au-dessus du formulaire : « Le fichier « settings.json » est illisible ou d'une
     version inconnue ; il est conservé tel quel et les réglages n'ont pas été enregistrés. » L'interrupteur **revient
     à sa position d'avant (allumé)**, et le fichier contient toujours votre texte. **Comportement à confirmer** : le
     retour du vrai interrupteur à l'écran n'a été vu que par ses règles, pas dessiné.
6. Remettez la sauvegarde récente à la place du fichier (copiez-la par-dessus), puis cliquez deux fois sur
   l'interrupteur (éteint, puis allumé).
   - Attendu : le message disparaît dès qu'un enregistrement réussit ; l'interrupteur est allumé à la fin. **Ne quittez
     pas Supervox avant d'avoir remis le fichier** : au lancement suivant, il le mettrait de côté comme illisible
     (essai 6) et vous perdriez vos réglages.

### 34. Dictée avec relecture

1. Placez le curseur dans l'application de notes et tapez ⌃⌥Espace. Dites deux ou trois phrases, puis retapez
   ⌃⌥Espace.
   - Attendu : après « Transcription… », le panneau reste ouvert et ne colle rien. Son titre est « À relire » (icône en
     forme de crayon). Le texte dicté, en entier, est dans un champ. À droite, « Copier » et « Coller » (« Coller »
     en couleur). En dessous, l'aide : « ⌘↩ colle le texte. Échap ferme sans coller ; le texte reste dans « Dernière
     dictée ». » Il n'y a pas de carte « Dernière dictée » tant que la relecture dure. L'application de notes n'a pas
     reçu de texte.
2. Tapez quelques mots, **sans cliquer** dans le champ.
   - Attendu : le curseur clignote dans le champ et ce que vous tapez s'y ajoute (pas dans l'application de notes). Si
     le texte s'allonge, le panneau grandit vers le bas. Notez si le curseur est au début ou à la fin du texte.
     **Comportement à confirmer** : que le champ prenne la frappe sans clic dans un vrai panneau à l'écran.
3. Regardez la barre des menus pendant la relecture.
   - Attendu : elle reste celle de l'application de notes (son nom à gauche de la barre), pas celle de Supervox :
     Supervox ne passe pas au premier plan. **Comportement à confirmer** : une règle qu'aucun test automatique ne peut
     vérifier. Si la barre montre Supervox, notez à quel moment.
4. Tapez Échap pour terminer (rien n'est collé).

### 35. « Coller » : où arrive le texte

Avant chaque passage, copiez un texte reconnaissable (⌘C) pour voir ce que devient le presse-papiers. Faites l'essai dans
l'application de notes, puis dans un terminal (Terminal), puis dans un champ de texte d'un navigateur : curseur dans
l'application, dictée avec relecture, correction visible du texte (ajoutez un mot), puis :

1. Cliquez sur « Coller ».
   - Attendu : le titre passe à « Collage… » un instant (champ atténué, qu'on ne peut plus modifier, boutons grisés, plus
     d'aide), puis le panneau se ferme d'un coup, **sans clignoter**. Le texte corrigé arrive à l'endroit du curseur de
     l'application d'origine, une fois, en entier, avec votre correction. Il n'est pas écrit dans le panneau, ni dans
     une autre application.
   - **Comportement à confirmer** : la frappe revient bien à l'application d'origine, sans clic de votre part. Si le texte
     part dans le vide ou dans le panneau, le délai de 0,15 s avant le collage est trop court : notez-le.
2. Faites ⌘V dans n'importe quelle application.
   - Attendu : le texte corrigé est recollé : il reste copié. Votre texte reconnaissable d'avant n'est pas rendu (c'est
     voulu pour la relecture ; une dictée sans relecture rend le presse-papiers d'origine, essai 10). Si c'est votre ancien
     texte qui revient, notez-le : le code le prévoit quand le système refuse de garder la copie, sans en avertir.
3. Refaites une dictée avec relecture, et collez par ⌘↩ au lieu du clic.
   - Attendu : même résultat, une seule fois ; ⌘↩ n'ajoute aucune ligne dans le champ (Retour, seul, va à la ligne).
     **Comportement à confirmer** : ⌘↩ avec un vrai clavier.

Les trois applications doivent donner le même résultat : notez les différences. Un outil d'historique du presse-papiers
peut garder la copie laissée par « Coller ».

### 36. Corriger le texte au clavier

1. Quittez Supervox et relancez-le **sans ouvrir les Réglages**. Faites une dictée avec relecture. Dans le champ :
   tapez quelques mots ; effacez avec la touche d'effacement ; ⌘A (tout sélectionner) ; tapez pour remplacer ;
   ⌘Z (annuler) ; ⇧⌘Z (rétablir) ; sélectionnez un mot, ⌘X puis ⌘V pour le remettre ; ⌘C puis ⌘V ; Retour.
   - Attendu : chaque commande agit **une seule fois**, sur le champ du panneau, jamais sur l'application de dessous.
     ⌘V ne colle qu'une fois. Retour va à la ligne et ne colle pas. Pour ⌘X et ⌘C, cliquez ensuite dans l'application de
     notes (le panneau reste) et faites ⌘V : c'est bien ce que vous aviez coupé ou copié. **Comportement à confirmer** :
     ces commandes avec un vrai clavier, dans un panneau qui n'active pas l'application.
2. Tapez des guillemets droits ("), deux tirets (--) et trois points (...).
   - Attendu : ils restent tels quels : pas de guillemets courbes, pas de tiret long, pas de « … ». Aucune correction ni
     complétion automatique ne modifie le texte. Notez si des mots sont soulignés en rouge : le code coupe la correction
     automatique, pas forcément le soulignement.
3. Ouvrez « Réglages… » puis refermez la fenêtre, refaites une dictée et le même enchaînement.
   - Attendu : identique (le menu de l'application existe maintenant) ; en particulier ⌘V ne colle toujours qu'une fois.
4. Refaites ⌘A, ⌘Z, ⌘X, ⌘C et ⌘V dans le champ avec le clavier AZERTY (Français), puis avec une disposition QWERTY
   (U.S., par exemple) : Réglages Système, Clavier, Sources de saisie.
   - Attendu : chaque commande répond à la touche qui porte sa lettre dans la disposition en cours (⌘A, par exemple, sur
     la touche marquée A, qui n'est pas au même endroit en AZERTY et en QWERTY). **Comportement à confirmer.** Si une
     disposition où ⌘ suit le QWERTY (« Dvorak – QWERTY ⌘ ») est installée, essayez-la aussi : le code peut y lire la
     mauvaise lettre. Rétablissez ensuite votre disposition habituelle.
5. Faites deux relectures de suite, sans quitter Supervox : dans la première, tapez et corrigez quelques mots ; fermez
   (Échap) ; faites une seconde dictée avec relecture et tapez ⌘Z **avant d'avoir rien tapé**.
   - Attendu : rien ne se passe : le texte de la seconde relecture reste tel quel, et rien de la première ne revient.
     Après avoir tapé un mot, ⌘Z ne retire que ce mot. **Comportement à confirmer.**
6. Tapez Échap pour terminer.

### 37. Accents

Dans le champ de relecture, avec le clavier AZERTY :

1. Touche morte : ^ puis e ; ¨ puis e.
   - Attendu : « ê », puis « ë ».
2. Appui long sur « e ».
   - Attendu : le menu des accents s'ouvre ; choisir un accent (par son chiffre ou d'un clic) l'écrit dans le champ.
     Si le menu ne s'ouvre pas, notez-le (c'est un réglage du système).
3. Appui long sur « e » pour rouvrir le menu, puis Échap pendant qu'il est ouvert.
   - Attendu : Échap est réservé par Supervox tant que le panneau est ouvert, donc le panneau se ferme sans rien coller
     (le texte reste dans « Dernière dictée »), au lieu de ne fermer que le menu des accents. **Comportement à
     confirmer** : notez ce qui arrive vraiment (le menu seul, le panneau seul, les deux). Refaites avec une touche
     morte en attente (tapez ^, puis Échap).
4. Tapez ^ et patientez une dizaine de secondes, puis tapez e. Si vous avez une méthode de saisie à composition
   (japonais, chinois), composez un mot long et attendez avant de valider.
   - Attendu : « ê » ; la composition en cours n'est pas effacée. **Comportement à confirmer** : on ne connaît aucun
     événement qui change le panneau pendant une saisie en attente (pas de relecture périodique des états : les permissions
     ne sont relues qu'à l'ouverture du panneau et au début d'une dictée), donc cet essai n'est qu'un témoin ; le code ne
     réécrit de toute façon le champ ni pendant un texte marqué ni pendant qu'une touche morte attend.

### 38. Cliquer dans une autre application pendant la relecture

1. Pendant une relecture (l'aide dit « ⌘↩ colle le texte… »), cliquez dans le champ d'une autre application (l'application
   de notes, par exemple).
   - Attendu : le panneau reste ouvert, le texte intact ; la frappe va à l'application cliquée, pas au panneau. L'aide
     du panneau change aussitôt : « Cliquez dans le texte pour le corriger, ou sur « Coller » pour le coller. Échap
     ferme sans coller. » Elle n'annonce plus ⌘↩. **Comportement à confirmer** : que le panneau perde la frappe à ce clic,
     et que l'aide le suive. Si elle dit encore « ⌘↩ colle le texte », notez-le et **n'utilisez pas ⌘↩** : il irait à
     l'application cliquée, qui pourrait y lire « envoyer ».
2. Recliquez dans le champ du panneau (sans taper).
   - Attendu : la frappe revient au panneau, et l'aide redit « ⌘↩ colle le texte… » dès le clic. Tapez un mot : il entre
     dans le champ. **Comportement à confirmer.**
3. Cliquez de nouveau dans l'autre application (curseur à l'endroit voulu), puis sur « Coller » dans le panneau.
   - Attendu : le texte est collé dans l'application cliquée en dernier, pas dans la première. **Comportement à
     confirmer.**

### 39. « Copier » pendant la relecture

1. Corrigez le texte (ajoutez un mot), cliquez sur « Copier ».
   - Attendu : le bouton passe à « Copié » ; le panneau reste ouvert, le texte reste dans le champ, rien n'est collé.
2. Cliquez dans une application où l'on peut coller (le panneau reste ouvert), puis faites ⌘V.
   - Attendu : c'est le texte corrigé en entier qui est collé, pas seulement la partie visible du champ.
3. Cliquez dans le champ du panneau, changez une lettre.
   - Attendu : le bouton revient à « Copier » (le texte n'est plus celui qui a été copié).

### 40. Échap et autres fermetures

Copiez d'abord un texte reconnaissable (⌘C).

1. Faites une dictée avec relecture, corrigez le texte (ajoutez un mot), puis tapez Échap.
   - Attendu : le panneau se ferme ; rien n'est collé ni copié (⌘V ailleurs colle votre texte reconnaissable).
2. Rouvrez le panneau par « Ouvrir le panneau » dans le menu de l'icône.
   - Attendu : « Prêt », et la carte « Dernière dictée » montre la fin du texte **corrigé** (pas du texte d'origine) ;
     « Copier » copie le texte corrigé en entier.
3. Refaites les points 1 et 2, en fermant le panneau d'abord par « Fermer le panneau » (menu de l'icône), puis par
   « Réglages… » (menu « … » du panneau ; la fenêtre de réglages s'ouvre).
   - Attendu : même résultat chaque fois.
4. Faites une dictée avec relecture, corrigez le texte, puis choisissez « Quitter Supervox » (menu de l'icône) ; relancez
   l'application et ouvrez le panneau.
   - Attendu : aucune confirmation n'est demandée à la sortie, et la carte « Dernière dictée » n'y est plus : le texte
     en cours est perdu.
5. **⌘Q.** Relancez Supervox **sans ouvrir les Réglages**, faites une dictée avec relecture, puis tapez ⌘Q dans le champ.
   - Attendu (déduit du code, jamais vu) : rien ne se passe, le panneau reste. Fermez par Échap.
   Ouvrez maintenant « Réglages… » puis refermez la fenêtre, refaites une dictée avec relecture et tapez de nouveau ⌘Q.
   - Attendu (déduit du code) : Supervox peut quitter, sans confirmation, et le texte en cours est perdu (voir « À savoir »).
     **Comportement à confirmer** : notez ce qui arrive dans chacun des deux cas.

### 41. Le raccourci pendant la relecture

1. En bascule, faites une dictée avec relecture, puis, pendant la relecture, tapez ⌃⌥Espace.
   - Attendu : rien ne se passe : aucune nouvelle prise, le texte et le panneau sont inchangés, le panneau ne se ferme
     pas. Fermez par Échap.
2. Réglages, onglet Raccourci : choisissez « Maintenir pour dicter », puis refermez la fenêtre. Faites une dictée avec
   relecture (maintenez ⌃⌥Espace, parlez, relâchez), puis, pendant la relecture, maintenez ⌃⌥Espace et relâchez.
   - Attendu : rien ne se passe, comme en bascule.
3. **Rétablissez la bascule** (Réglages, onglet Raccourci : « Appuyer pour commencer et pour terminer la dictée »). Ouvrir
   les Réglages ferme le panneau : c'est normal.

### 42. Vider le texte

1. Pendant une relecture, faites ⌘A puis effacez.
   - Attendu : le champ dit « Le texte est vide. » en gris ; « Copier » et « Coller » sont grisés ; l'aide dit « Tapez
     un texte, ou appuyez sur Échap pour fermer sans coller. » ; ⌘↩ ne fait rien.
2. Tapez seulement des espaces ou un retour à la ligne.
   - Attendu : les boutons restent grisés et l'aide est la même, mais « Le texte est vide. » disparaît (le champ n'est
     plus vide).
3. Videz de nouveau le champ, tapez Échap, rouvrez le panneau par le menu de l'icône.
   - Attendu : « Dernière dictée » montre le texte d'origine de la dictée : un texte vidé ne remplace pas l'original.

### 43. Un long texte

1. Dictez pendant une à deux minutes, avec relecture.
   - Attendu : le champ grandit avec le texte jusqu'à environ seize lignes, puis ne grandit plus : le texte défile à
     l'intérieur (molette ou pavé tactile). Le panneau (441 points de haut sur l'image rendue, mesure hors écran) reste
     entièrement dans l'écran ; « Copier » et « Coller » restent visibles. Il n'y a pas de barre de défilement en
     permanence : le défileur du système n'apparaît que pendant le défilement, et la dernière ligne visible peut sembler
     coupée (c'est le signe qu'il y a de la suite). Tapez à la fin du texte : notez si le curseur reste visible.
2. Refaites l'essai sur l'écran le plus petit dont vous disposez, ou avec la fenêtre de l'application de dessous proche du
   bas de l'écran.
   - Attendu : le panneau reste entièrement visible. **Comportement à confirmer** : la hauteur de seize lignes est un choix,
     jamais mesuré sur un petit écran.

### 44. Collage impossible

1. Retirez l'autorisation d'Accessibilité à Supervox (Réglages Système), faites une dictée avec relecture, corrigez un mot,
   puis cliquez sur « Coller ».
   - Attendu : rien n'est collé. Le panneau revient à la relecture : le titre reste « À relire » (et non « Texte copié »),
     le texte est intact avec votre correction, et sous le champ la phrase de l'étape 3 : « Le texte est copié dans le
     presse-papiers, mais Supervox n'a pas l'autorisation de le coller à votre place : faites ⌘V… ». La ligne des permissions dit que
     l'Accessibilité manque. L'aide devient « Cliquez dans le texte pour le corriger, ou sur « Coller » pour le coller.
     Échap ferme sans coller. » tant que le panneau n'a pas repris la frappe (la même phrase qu'après un clic dans une
     autre application, essai 38 ; sans « réessayer », qui échouerait de la même façon). **Dans cet état, n'utilisez pas
     ⌘↩** : le panneau n'a plus la frappe, ⌘↩ irait à l'application de dessous.
2. Cliquez à l'endroit voulu dans l'application de dessous (le panneau reste ouvert), puis faites ⌘V.
   - Attendu : le texte est collé.
3. Cliquez dans le champ du panneau et tapez un mot.
   - Attendu : l'aide redevient « ⌘↩ colle le texte… » dès que le panneau reprend la frappe (au clic, avant même de
     taper). Le presse-papiers ne suit pas vos retouches : « Coller » le réécrit. **Comportement à confirmer** : la frappe
     revient au panneau après un clic.
4. Rendez l'Accessibilité à Supervox. Faites une dictée avec relecture, tapez ⌘↩ et **gardez ⌘ enfoncé plus de deux
   secondes**.
   - Attendu : après environ une seconde d'attente, le texte n'est pas collé : le panneau revient à la relecture avec
     « Le texte est copié dans le presse-papiers, mais des touches de modification (⌃, ⌥, ⇧ ou ⌘) sont restées
     enfoncées et auraient faussé le collage : relâchez-les, puis faites ⌘V pour coller le texte. » Relâchez ⌘, cliquez à
     l'endroit voulu de l'application de dessous, ⌘V : le texte est collé. Fermez par Échap.

### 45. Changer de pastille pendant la relecture

1. Pendant une relecture, cliquez sur une autre pastille (par exemple « Prompt »).
   - Attendu : le texte et le champ restent tels quels, la relecture continue ; « Coller » colle ce texte. Le raccourci
     reste sans effet.
2. Fermez par Échap, puis tapez ⌃⌥Espace.
   - Attendu : le panneau dit « Ce mode arrive à une étape suivante. » et aucune dictée ne démarre : la dictée suivante
     suit le nouveau mode (le choix de pastille est enregistré, comme d'habitude).
3. **Revenez à la pastille « Dictée brute »** (essai 16.6).

### 46. Relecture désactivée, et réglage lu à l'appui

1. Réglages, onglet Modes : laissez la fenêtre ouverte. Placez le curseur dans l'application de notes et lancez une
   dictée (⌃⌥Espace). Pendant l'enregistrement, cliquez dans la fenêtre des Réglages et **éteignez** l'interrupteur de
   Dictée brute, puis terminez la dictée (⌃⌥Espace).
   - Attendu : la dictée finit **en relecture**, bien que l'interrupteur soit éteint : le réglage est lu à l'appui qui
     commence la dictée. Fermez par Échap. **Comportement à confirmer** : la fenêtre de réglages et la dictée en même
     temps (comme à l'essai 20.1).
2. Copiez un texte reconnaissable (⌘C), placez le curseur dans l'application de notes, et faites une dictée.
   - Attendu : le texte est collé tout seul, comme à l'étape 3, sans relecture ; le panneau se ferme ; ⌘V colle de nouveau
     votre texte reconnaissable (le presse-papiers d'origine est rendu).

L'état de départ est rétabli : relecture désactivée pour Dictée brute.

### 47. Retour à faire

À la fin, notez : les essais pas OK ; ce qui était lent (préparation, transcription, téléchargement, et le temps entre
« Coller » et l'arrivée du texte) ; ce qui était déroutant dans le panneau ou les réglages (la relecture, l'aide sous le
champ, l'état après un collage manqué) ; si la frappe s'est égarée (texte dans le vide, dans le panneau, dans la mauvaise
application) ; s'il y a eu un clignotement ; si le message sur les « morceaux de mots » se comprend.
