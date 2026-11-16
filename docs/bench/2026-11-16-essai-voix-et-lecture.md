# Essai de faisabilité : voix du système et fin de lecture réelle — 2026-11-16

**État : essai fait le 16 novembre 2026**, de 1 à 3 passages par question, sur la machine de développement (macOS 27.2,
sortie audio par défaut de type intégré, entrée par défaut intégrée). Le programme d'essai est un paquet jetable hors du
dépôt : aucun fichier de produit n'a été modifié. Les sorties sont recopiées du programme, sans retouche.

Ce fichier ne cite ni identifiant ni nom de voix, ni nom de machine ou de périphérique.

## Conditions réelles de l'essai (à lire avant les chiffres)

- **Le volume du système était à 0 et la sortie en sourdine** (lecture seule des réglages, constatée avant les essais).
  Consigne : ne rien changer aux réglages. Les lectures ont donc été **rendues par le moteur mais inaudibles**. Les
  mesures d'horloge (Q2) en sont indépendantes ; la mesure d'écho (Q3) ne l'est pas : voir Q3.
- Personne n'était devant la machine : le micro n'a capté que le bruit ambiant.
- Seule la sortie intégrée est la sortie par défaut ; **aucun casque** n'était disponible : Q2 n'a pas été faite au casque.
- Le micro était déjà autorisé pour le terminal (statut lu avant tout accès, sans invite).
- Binaire en mode debug. Phrases : « Bonjour, ceci est un essai de la voix du système. » (Q1, 3,47 s de parole) et
  « Bonjour, ceci est un essai. » (Q2, 2,27 s). Chaque exécution est bornée à 30 s par une alarme du système.
- Voix : la voix `fr-FR` de meilleure qualité installée. Neuf voix `fr-FR` sont installées, **toutes de qualité
  « défaut »** ; aucune voix améliorée ou premium n'est installée. Le résultat vaut pour cette qualité.

## Q1 — `AVSpeechSynthesizer.write(_:toBufferCallback:)` : tampons, fin, fil, libération, délai

Nature : **mesuré**. 3 passages normaux, 2 passages avec libération anticipée, 2 passages avec appel depuis un fil de fond.

| Question | Réponse |
|---|---|
| Rend-il des tampons ? | Oui : 300 rappels par phrase, tous des `AVAudioPCMBuffer` (3 passages sur 3). |
| Format commun | 22 050 Hz, 1 canal, flottant 32 bits, non entrelacé. 76 490 images au total pour la phrase (3 passages identiques). Tampons de 202, 256, 256… images. |
| Fin signalée | Par **un tampon de longueur nulle** (le 300e, `frameLength == 0`, capacité 1), **suivi de `didFinish` du délégué environ 0,1 à 0,2 ms plus tard** (3 passages sur 3). Les deux signaux existent. |
| Fil du rappel | **Le fil principal** (3 passages sur 3), y compris quand `write` est appelé depuis un fil de fond (1 passage). Le délégué aussi (`didStart`, `didFinish`). |
| Dépend de la boucle principale ? | **Oui** : `write` appelé depuis un fil de fond pendant que le fil principal est bloqué sur un sémaphore (aucune boucle d'exécution) : **0 tampon, ni tampon nul, ni `didFinish`** en 6 s (1 passage). Avec la boucle tournant : 300 tampons, tampon nul à 1 089 ms. |
| Synthétiseur libéré avant la fin | Libéré à 363 ms et 360 ms (avant le premier tampon) : **plus aucun rappel, ni tampon, ni tampon nul, ni `didFinish`, ni `didCancel`**, pendant les 10 s d'attente (2 passages sur 2). Libération en plein milieu d'un flux non essayée : voir Incertitudes. |
| Délai jusqu'au premier tampon | **554 ms, 989 ms, 1 620 ms** (3 passages, `write` rendu en 3 à 42 ms). Très dispersé. |
| Forme de la livraison | Tout arrive en rafale : du premier au dernier tampon, 33 à 42 ms (les 299 tampons de contenu et le tampon nul). La synthèse est donc terminée à l'arrivée du premier tampon, et le contenu se livre bien plus vite que la lecture. |

Issue retenue : **la fin est signalée** (tampon nul, doublé par `didFinish`) ; la variante « 0,5 s sans tampon » du
cahier des charges n'est pas nécessaire. Les points à retenir pour la tâche 3 :

- tout le flux étant livré en rafale sur le fil principal, l'appelant doit copier ou convertir sans bloquer ce fil ;
- il faut **garder le synthétiseur vivant** jusqu'à la fin (sinon silence total, sans aucun signal d'annulation) et prévoir une garde
  de durée (aucun signal en cas de libération, ni quand le fil principal ne tourne pas) ;
- des tampons français sont rendus : la décision (a)/(b) du cahier des charges n'est pas à poser.

## Q2 — Moteur à traitement de la voix monté comme `AudioCapture`, tap du micro actif

Montage : lecteur attaché et connecté (`connectNode`, format `nil`) avant `setVoiceProcessingEnabled(true)`, ducking au minimum,
tap du micro de 100 ms, `prepare()` puis `start()`. Nature : **mesuré** (horloge hôte, `mach_absolute_time`), 2 passages
pour `.dataPlayedBack`, 2 pour `.dataRendered`, 1 pour `.dataConsumed`, 3 passages avec `stop()`.

**Formats (3 passages, dont le détail est affiché : identiques)**

- Sortie du lecteur **avant** et **après** l'activation du traitement : 44 100 Hz, 2 canaux, flottant 32 bits, non entrelacé
  (**inchangée** : la connexion garde son format d'origine).
- Entrée du micro après activation : 48 000 Hz, **9 canaux** (cohérent avec la note de `AudioCapture`).
- Entrée du mélangeur : 44 100 Hz, 2 canaux ; sortie du mélangeur et nœud de sortie : 48 000 Hz, 2 canaux.
- `outputPresentationLatency` du lecteur et `presentationLatency` du nœud de sortie : 0,000 021 s (annoncées par le moteur ;
  la latence réelle du matériel n'est pas mesurée, la sortie étant muette).

**Un tampon converti à ce format joue-t-il ?** Oui. Le clip (22 050 Hz, 1 canal) converti par `AVAudioConverter` en
44 100 Hz, 2 canaux : état 0, aucune erreur, 100 244 images, soit 2,273 s. Le lecteur lit sa position (`playerTime`) qui
avance de 0 à 2,6 s ; la sortie du mélangeur dépasse 1e-4 de RMS (maximum 0,24 à 0,26) pendant la lecture. « Joue » veut dire
ici « rendu par le moteur » : **rien n'a été entendu** (sortie muette).

**`.dataPlayedBack` après la fin ?** Oui, 2 passages sur 2, **après la durée du tampon** :

| Type demandé | Appelé à (après `playAudio()`) | Durée du tampon | Écart |
|---|---|---|---|
| `.dataPlayedBack` (1er passage) | 2 324,3 ms | 2 273,1 ms | +51,2 ms |
| `.dataPlayedBack` (2e passage) | 2 317,4 ms | 2 273,1 ms | +44,3 ms |
| `.dataRendered` | 2 304,1 ms | 2 273,1 ms | +31,0 ms |
| `.dataConsumed` | 2 304,1 ms | 2 273,1 ms | +31,0 ms |

Le type reçu est celui demandé (2, 1, 0). Constat important : **avec un seul tampon, `.dataConsumed` arrive lui aussi à la
fin** (et non à la prise en charge), et à `.dataRendered` près : les trois types ne se distinguent que de 13 à 20 ms. Le rappel
arrive sur un fil non principal pendant la lecture normale. « Après la fin audible » : **non vérifié à l'oreille** (sortie
muette) ; le contenu du clip se termine à 2 081 ms et son dernier ~190 ms est quasi silencieux, donc la comparaison pertinente est
celle à la durée du tampon (+31 à +51 ms), pas à la fin du contenu.

**Après `player.stop()` (3 passages sur 3)** : le gestionnaire **est appelé**, **de façon synchrone dans l'appel de `stop()`**
(déjà appelé au retour ; 0,9, 1,1 et 0,5 ms après l'entrée), **sur le fil appelant** (le fil principal ici), **avec le type demandé**
(`.dataPlayedBack`, 2). Il n'est donc **pas distinguable** d'une fin naturelle par son seul argument : l'appelant doit se souvenir
qu'il a lui-même demandé l'arrêt. L'appel de `stop()` dure 0,5 à 1,2 ms. Un seul appel du gestionnaire, pas de second.

**Délai entre `stop()` et le silence** : au niveau du mélangeur, le dernier tampon de 1 024 images (21,3 ms) au-dessus du seuil a
commencé 17,3 ms et 8,3 ms **avant**, puis 17,1 ms **après**, l'appel de `stop()` ; le suivant est sous le seuil. Le silence du
mélangeur est donc acquis **dans les 40 ms qui suivent `stop()`** au pire observé (granularité du tampon d'observation et
imprécision d'horloge de quelques dizaines de ms comprises). Le silence **audible** n'est pas mesuré : il s'ajoute la
latence du matériel de sortie, non mesurée ici.

Issue retenue : **`.dataPlayedBack` est présent et arrive après la durée du tampon** (pas à la consommation) : la
variante de repli (`.dataRendered` puis sondage de `playerTime`) n'est pas nécessaire. `stop()` appelle bien le gestionnaire :
la tâche 2 ne rend pas `.stopped` « à la main » pour ce motif, mais **doit distinguer elle-même arrêt demandé et fin naturelle**
(le type reçu est le même), et ne pas retenir de verrou dans le gestionnaire qu'elle tient en appelant `stop()` (appel synchrone,
sur le fil appelant). La comparaison à la fin audible reste à faire avec le son en marche : voir Incertitudes.

## Q3 — Niveau du micro pendant la lecture, pour situer le seuil de départ de −30 dB (D9)

Nature : **non établi**. La mesure demandée (écho des haut-parleurs intégrés, volume habituel) n'a pas pu être faite : le volume
du système était à 0 et la sortie en sourdine (voir plus haut), et la consigne interdit de le changer.

Ce qui a été mesuré tout de même, **à ne pas lire comme un écho** : le niveau du premier canal du micro (traitement de la voix
actif), par la formule de `DictationSession.level(of:)` avant la mise à l'échelle (10·log10 de la puissance moyenne), en fenêtres
de 20 ms, maximum, sur 4 passages. Pendant que le lecteur rendait la phrase vers une sortie muette :

| Passage | Maximum avant la lecture | Maximum pendant la lecture |
|---|---|---|
| 1 | −51,8 dB | −44,0 dB |
| 2 | −54,8 dB | −30,9 dB |
| 3 | −43,2 dB | −20,5 dB |
| 4 | −47,7 dB | −45,0 dB |

C'est vraisemblablement le **bruit ambiant de la pièce**, sans source précise identifiée : les pics (−30,9 dB et −20,5 dB)
tombent à partir de 2,0 s, à la fin ou après le contenu du clip (qui s'arrête à 2,08 s), et la parole elle-même n'a rien produit
de tel. Un cinquième passage (avec `stop()`, sans lecture après 1 s) donne −51,9 dB avant et −45,6 dB pendant. Deux choses en ressortent, **constatées sans pouvoir les généraliser** :
un bruit de pièce sans personne qui parle a atteint −20,5 dB sur une fenêtre de 20 ms ; un seuil de −30 dB sur le maximum
d'une fenêtre de 20 ms est donc franchi, par du bruit seul, sur 1 passage sur 5 (et approché à 0,9 dB sur un autre). La formule et la fenêtre de
la mesure du design §4 ne sont pas lisibles dans le dépôt : l'écart entre les deux mesures est **non établi**.

Issue retenue : on **ne change pas la valeur par défaut de −30 dB**. Le rapport final signale que l'écho n'a pas été mesuré
(volume nul) et que le réglage avancé de la tâche 10 doit permettre de l'ajuster ; la mesure d'écho est à faire par
l'utilisateur à son volume habituel.

## Q4 — `playAudio()` (macOS 27) contre `play()`

Nature : **mesuré**. Ton de 0,5 s, moteur sans traitement de la voix, `.dataPlayedBack`. 2 passages par appel, plus 1 passage
moteur arrêté pour chacun.

| Cas | `play()` | `playAudio()` |
|---|---|---|
| Moteur démarré, 2 passages | revient en 8,5 à 9,1 ms, `isPlaying` vrai, gestionnaire type 2 à 553 et 555 ms | revient en 8,8 à 9,2 ms, `isPlaying` vrai, gestionnaire type 2 à 555 et 556 ms |
| Moteur arrêté, 1 passage | **revient sans rien dire**, `isPlaying` faux, gestionnaire jamais appelé | **lève une erreur** (code −10863, domaine `com.apple.coreaudio.avfaudio`), `isPlaying` faux, gestionnaire jamais appelé |

Réponse : **identique sur un moteur démarré** (au bruit de mesure près). **Différent sur un moteur arrêté** : `playAudio()`
signale l'échec, `play()` ne fait rien sans le dire.

Issue retenue : la tâche 2 appelle `playAudio()` derrière `if #available(macOS 27, *)` (et traite l'erreur levée), et `play()`
sinon ; sur le chemin `play()`, elle doit vérifier elle-même `engine.isRunning` avant, faute de signal.

## Incertitudes

- **Écho (Q3) : non établi.** Volume système à 0 et sourdine : aucun écho des haut-parleurs n'a pu exister. Le chiffre de −30 dB
  n'est ni confirmé ni infirmé. Le plafond de bruit ambiant observé (−20,5 dB) vient d'une pièce non contrôlée, 4 passages, sans
  garantie de représentativité.
- **« Après la fin audible » (Q2) : non vérifié.** Les écarts (+31 à +51 ms) sont à la durée du tampon, sur l'horloge hôte, sans
  son en sortie ; la latence matérielle réelle de la sortie intégrée n'est pas mesurée (la latence annoncée est de 0,02 ms,
  non vérifiée). Au casque (Bluetooth notamment), la latence est typiquement bien plus grande : **non essayé**, aucun casque.
- **Silence audible après `stop()` (Q2) : non mesuré** ; seul le silence du mélangeur l'est, à 40 ms près.
- **`.dataConsumed` arrive à la fin pour un tampon unique** : constaté sur 1 passage ; le comportement avec plusieurs tampons
  planifiés à la suite (cas de la tâche 2 si elle planifie par tranches) **n'est pas essayé**.
- **Q1, libération en plein flux : non essayée.** Les deux libérations ont eu lieu avant le premier tampon ; la livraison en rafale
  (33 à 42 ms) rend une libération intermédiaire difficile à provoquer sans appeler depuis le rappel lui-même.
- **Q1, voix : qualité « défaut » seulement** ; une voix améliorée ou premium pourrait avoir un autre format, un autre délai et
  une autre durée de synthèse. Le délai au premier tampon (554 à 1 620 ms) est mesuré en mode debug, 3 passages, très dispersé :
  pas un chiffre de référence.
- **Q1, `didCancel` : non essayé** (`stopSpeaking(at:)` n'a pas été exercé).
- **Montage de Q2 : écart avec `AudioCapture`** — le programme d'essai reprend la séquence (lecteur connecté, traitement de la
  voix activé, ducking au minimum, tap 100 ms) mais n'est pas le code de production ; l'essai du moteur de production reste à
  faire en tâche 2.
- **Fil du rappel de fin naturelle (Q2)** : non principal dans 4 passages sans `stop()` ; avec `stop()`, le fil appelant. Rien
  n'est établi sur d'autres conditions de charge.
- **Horloges** : l'horodatage du premier tampon actif du mélangeur va de 48 ms avant à 20 ms après le retour de `playAudio()`
  selon les passages ; ce décalage borne la précision des comparaisons de début de lecture à quelques dizaines de millisecondes.
