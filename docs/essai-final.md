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
     raccourci ; en bas, une ligne qui dit ce qui manque (micro, Accessibilité) avec un bouton « Autoriser… ».

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
     Accessibilité : « le texte sera copié, pas collé »).
5. Ouvrez « Réglages… », onglet Permissions.
   - Attendu : « Autorisé », « Pas encore demandé » ou « Non autorisé » pour chacune ; un bouton « Ouvrir les réglages
     du système » pour une permission refusée.

### 3. Raccourci, Échap, clic en dehors, menu

1. Depuis une autre application, tapez ⌃⌥Espace.
   - Attendu : le panneau s'ouvre sans prendre la frappe (l'application de dessous reste active) et la dictée commence
     (voir l'étape 3).
2. Avec le panneau ouvert et aucune dictée en cours, tapez Échap.
   - Attendu : le panneau se ferme.
3. Rouvrez le panneau (menu de l'icône, « Ouvrir le panneau »), puis cliquez dans une autre application.
   - Attendu : le panneau se ferme et votre clic a bien servi dans l'autre application.
4. Ouvrez le menu de l'icône.
   - Attendu : « Ouvrir le panneau » (ou « Fermer le panneau » si ouvert), « Réglages… », « Quitter Supervox ».
5. Ouvrez « Réglages… » depuis le menu « … » du panneau.
   - Attendu : le panneau se ferme et la fenêtre de réglages s'ouvre.
6. Quittez par « Quitter Supervox ».
   - Attendu : l'icône disparaît de la barre des menus.
7. Choisissez un autre raccourci dans Réglages, onglet Raccourci (cliquez sur le raccourci, tapez la nouvelle
   combinaison), puis essayez-le.
   - Attendu : la nouvelle combinaison ouvre le panneau, l'ancienne ne fait plus rien. Une combinaison refusée par
     macOS est dite dans la fenêtre, et l'ancien raccourci reste actif. **Comportement à confirmer** pour les
     combinaisons que seul macOS refuse.

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
   - Attendu : le panneau s'ouvre avec un avis qui dit que le fichier n'a pas pu être repris ; le fichier abîmé est
     gardé à côté sous le nom `settings.json.illisible-<date>`, jamais écrasé, et l'application repart avec les réglages
     par défaut, sans l'accueil du premier lancement.

### 7. Icônes

1. Regardez l'icône de l'application dans le Finder, puis celle de la barre des menus, en apparence claire puis
   sombre (Réglages Système, Apparence).
   - Attendu : le logo (une onde) est net et lisible dans les deux apparences, sans fond blanc ni bord coupé.

## Étape 3 — dictée

Avant de commencer : micro et Accessibilité accordés, réglages par défaut (WhisperKit), mode « Dictée brute ». À la
première dictée, les modèles manquants se téléchargent : cela peut prendre un moment (leur taille n'a pas été mesurée).

### 8. Une dictée simple, par bascule

1. Placez le curseur dans l'application de notes, tapez ⌃⌥Espace.
   - Attendu : le panneau s'ouvre ; « Préparation… » (avec « Téléchargement du modèle… » si un modèle manque), puis
     « Enregistrement » avec un point rouge, la durée qui avance et une forme d'onde qui bouge quand vous parlez.
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
   - Attendu : la carte n'y est plus. Le texte n'est gardé qu'en mémoire, jamais dans un fichier.

### 12. Collage avec d'autres claviers

Le collage envoie ⌘V avec la touche qui produit « v » dans la disposition en cours. Changez la disposition du clavier
(Réglages Système, Clavier, Sources de saisie) puis faites une dictée collée avec chacune :

1. AZERTY (Français) ;
2. une disposition où la touche V n'est pas au même endroit : Dvorak, par exemple.
   - Attendu, pour chacune : le texte est collé (et non un autre caractère ni rien du tout).

### 13. Mode maintien

Réglages, onglet Raccourci, choisissez « Maintenir pour dicter ».

1. Maintenez ⌃⌥Espace, parlez, relâchez.
   - Attendu : la dictée dure tant que vous maintenez ; au relâchement, « Transcription… » puis le texte est collé.
2. Maintenez ⌃⌥Espace, parlez, puis relâchez **d'abord ⌃ et ⌥, ensuite Espace**.
   - Attendu : la dictée s'arrête en moins d'une seconde dans tous les cas (le système peut ne pas signaler ce
     relâchement-là ; l'application vérifie quatre fois par seconde).
3. Maintenez ⌃⌥Espace, et relâchez tout de suite (avant la fin de « Préparation… »).
   - Attendu : le micro ne s'ouvre pas ; le panneau reste ouvert avec « Rien à transcrire » et « Aucune parole n'a été
     entendue. ». Un nouvel appui relance une dictée.
4. En mode maintien, pendant « Préparation… », appuyez de nouveau sur le raccourci.
   - Attendu : cet appui est ignoré, la préparation continue.

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
3. Pendant un téléchargement de modèle (« Préparation… », « Téléchargement du modèle… »), tapez Échap.
   - Attendu : la dictée est annulée et le panneau se ferme. **Comportement à confirmer** : d'après le code, le
     téléchargement lui-même continue en arrière-plan ; vérifiez dans Réglages, onglet Transcription, que la ligne du
     modèle indique le téléchargement (« en cours »), puis qu'il se termine.
4. Pendant une dictée, cliquez dans une autre application.
   - Attendu : le clic est sans effet sur le panneau, qui reste ouvert et continue d'enregistrer. En dehors d'une
     dictée, ce même clic le ferme.

### 16. Le raccourci et le panneau ouvert

1. Ouvrez le panneau par le menu de l'icône (« Prêt »), puis tapez ⌃⌥Espace.
   - Attendu : une dictée démarre ; le raccourci ne ferme pas le panneau.
2. Après une erreur (par exemple « Rien à transcrire »), tapez ⌃⌥Espace.
   - Attendu : une nouvelle dictée démarre.
3. Le panneau se ferme dans ces cas, et seulement ceux-là : Échap, clic dans une autre application hors dictée, le menu
   de l'icône, « Réglages… » ou « Quitter Supervox », ou un collage réussi.
4. Choisissez un autre mode que « Dictée brute » (par exemple « Entretien »), puis tapez ⌃⌥Espace.
   - Attendu : le panneau s'ouvre avec « Ce mode arrive à une étape suivante. » et aucune dictée ne démarre. Un
     second appui, panneau ouvert, ferme le panneau (c'est le seul cas où le raccourci le ferme).

### 17. Silence complet

1. Tapez ⌃⌥Espace, ne dites rien pendant quelques secondes, retapez.
   - Attendu : « Rien à transcrire » et « Aucune parole n'a été entendue. » ; rien n'est collé, le presse-papiers est
     intact ; le panneau reste ouvert.

### 18. Refus de l'Accessibilité

1. Retirez l'autorisation d'Accessibilité à Supervox (Réglages Système), puis faites une dictée.
   - Attendu : le texte n'est pas collé ; le panneau reste ouvert avec « Texte copié », une phrase qui explique qu'il
     faut faire ⌘V soi-même et accorder l'Accessibilité, la carte du texte et « Copier ».
2. Faites ⌘V dans une application.
   - Attendu : le texte dicté est collé.
3. Retirez le micro à Supervox, tapez ⌃⌥Espace.
   - Attendu : le panneau s'ouvre, aucune dictée ne démarre, la ligne des permissions dit que le micro manque.

### 19. Premier téléchargement des modèles

Il y en a cinq : Parakeet (qui comprend un petit modèle pour le vocabulaire), les trois variantes de Whisper (large-v3
turbo, small, base) et le détecteur de voix. Si un modèle est déjà sur ce Mac, supprimez-le par son bouton « Supprimer… »
(la fenêtre de confirmation dit ce qui sera effacé, et que les fichiers de Parakeet sont dans un dossier partagé avec
d'autres applications).

1. Réglages, onglet Transcription : cliquez sur « Télécharger » pour chaque modèle, l'un après l'autre.
   - Attendu : la ligne passe à « Téléchargement en cours… » (ou « Téléchargement : N % ») avec une barre, puis à
     « Prêt » ; le bouton Télécharger disparaît pendant le téléchargement.
2. Supprimez un modèle, choisissez le moteur qui l'utilise, puis lancez une dictée : c'est la dictée qui le télécharge.
   - Attendu : « Préparation… » et « Téléchargement du modèle… » dans le panneau ; la dictée démarre une fois le
     modèle prêt.
3. Pendant ce téléchargement, ouvrez Réglages, onglet Transcription.
   - Attendu : la ligne du modèle montre le téléchargement en cours (ouvrir la fenêtre ouvre le panneau en cause :
     la dictée est alors interrompue, le téléchargement continue). **Comportement à confirmer** : l'onglet n'est
     relu qu'à son ouverture et à chaque action ; ne vous attendez pas à voir la barre avancer toute seule si l'onglet
     était déjà ouvert.
4. Coupez Internet puis lancez une dictée qui demande un téléchargement.
   - Attendu : un message d'échec qui dit d'ouvrir les Réglages, onglet Transcription ; pas de blocage.

### 20. Supprimer un modèle

1. Lancez une dictée, puis, **pendant qu'elle dure**, essayez de supprimer un modèle dans la fenêtre de réglages
   (ouverte avant la dictée).
   - Attendu : la suppression est refusée avec le message « Une dictée est en cours : attendez qu'elle se termine pour
     supprimer un modèle. ». **Comportement à confirmer** : la fenêtre de réglages et la dictée en même temps.
2. Supprimez Parakeet (ligne « Parakeet », « Supprimer… », confirmez), puis lancez une dictée.
   - Attendu : un avis dit que la prochaine dictée le téléchargera de nouveau ; la dictée suivante le retélécharge
     (« Téléchargement du modèle… ») puis fonctionne.

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
     ou écartée pour cette dictée.

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

### 25. Retour à faire

À la fin, notez : les essais pas OK ; ce qui était lent (préparation, transcription, téléchargement) ; ce qui était
déroutant dans le panneau ou les réglages ; si le message sur les « morceaux de mots » se comprend.
