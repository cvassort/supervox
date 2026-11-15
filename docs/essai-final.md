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
  vocabulaire, disposition du clavier) : les essais suivants supposent l'état de départ (raccourci ⌃⌥Espace, bascule,
  mode « Dictée brute », micro et Accessibilité accordés, réseau actif, WhisperKit large-v3 turbo, français, vocabulaire
  vide). Si un essai échoue pour une raison qui ressemble à un état oublié, rétablissez-le avant de conclure.

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
     sur « Copier » avec un tel outil actif.

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
     (indicateur orange) et « Rien à transcrire » vient d'une prise vide, pas du micro resté fermé. Pour des moteurs
     froids, lancez l'essai juste après le lancement de l'application, ou juste après avoir changé de variante WhisperKit
     (essai 22.2). **Comportement à confirmer** : la brièveté de « Préparation… » avec des moteurs chargés.
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
3. Le panneau se ferme dans ces cas : Échap, clic dans une autre application hors dictée, le menu de l'icône,
   « Réglages… » ou « Quitter Supervox », un collage réussi, et, dans un mode autre que la dictée brute, le raccourci
   lui-même (essai 5 ci-dessous).
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
   `Models/models/openai/` de Supervox, voir le README) ne se charge pas hors ligne, alors que l'onglet dit « Prêt ».
   - Attendu : l'échec de préparation, avec une phrase qui renvoie à l'onglet Transcription : « s'il est indiqué « Prêt »,
     supprimez-le puis téléchargez-le de nouveau ». **Comportement à confirmer** : déduit du code, jamais essayé.
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
     mesuré (casque sans fil compris) ; si un micro lent déclenche l'échec à tort, notez le matériel.

### 28. Durée de « Chargement du modèle… »

À chronométrer (aucune durée n'a été mesurée) :

1. Quittez l'application, relancez-la, et tapez ⌃⌥Espace aussitôt (première dictée après le lancement).
   - Attendu : « Préparation… » avec « Chargement du modèle… » (pas « Téléchargement du modèle… »), puis
     « Enregistrement ». Notez la durée de « Chargement du modèle… » (variante large-v3 turbo, puis, après avoir choisi
     Parakeet, la même mesure ; rétablissez WhisperKit ensuite, essai 22.5).
2. Relancez l'application, attendez quelques dizaines de secondes (le préchargement se fait en tâche de fond, sans
   téléchargement), puis dictez.
   - Attendu : « Préparation… » très brève, sans « Chargement du modèle… » si le préchargement est fini ; sinon la
     mention s'affiche moins longtemps qu'à l'essai 1. Notez les deux durées. **Comportement à confirmer** : la durée du
     préchargement et le fait qu'il ne ralentit pas l'affichage du panneau au lancement.
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

### 32. Retour à faire

À la fin, notez : les essais pas OK ; ce qui était lent (préparation, transcription, téléchargement) ; ce qui était
déroutant dans le panneau ou les réglages ; si le message sur les « morceaux de mots » se comprend.
