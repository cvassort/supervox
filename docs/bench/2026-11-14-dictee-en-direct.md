# Dictée en direct : mesure — 2026-11-14

**État : mesure faite le 15 novembre 2026**, un passage par configuration. Chaque chiffre du tableau est recopié du
`live.md` écrit par `supervox-bench live`, sans autre source.

Les rapports bruts (`live.md`, `live.json`) contiennent ce qui a été dit : ils restent hors du dépôt, dans `bench-data/`
(ignoré par git). Ce fichier ne cite ni phrase du corpus, ni nom de fournisseur.

## Ce que la mesure doit établir

1. Le texte final obtenu par la session de dictée (détecteur de voix, marge autour de la parole, moteur final) est-il
   aussi juste que la transcription en bloc de l'étape 1, par le même moteur sur les mêmes enregistrements ?
2. Le dernier aperçu (le texte en direct tel qu'il est à l'écran quand l'utilisateur termine) est-il proche du texte
   final, ou seulement un guide ?
3. Combien de temps s'écoule entre l'appui qui termine la dictée (`finish()`) et le texte final ?

Aucun seuil de réussite n'a été fixé avant la mesure : les chiffres se lisent après coup.

## Méthode

- **Rejeu dans une vraie session.** Chaque enregistrement du corpus est livré à une vraie `DictationSession` par le micro
  scripté, par tranches de 100 ms, à la vitesse de la parole. La cadence vient du détecteur de voix, qui attend la durée
  de chaque bloc (4 096 échantillons à 16 kHz, soit 256 ms) avant de le traiter : la session lit l'audio comme avec un
  vrai micro et lance ses passes d'aperçu au fil de la parole.
- **Fin de prise.** Après l'enregistrement, `--settle` secondes de silence sont ajoutées (1 s par défaut : le temps que
  l'utilisateur presse le raccourci ; valeur choisie, non mesurée), puis `finish()` est demandé une fois le dernier bloc
  passé. Le délai part de l'appel de `finish()` et s'arrête au texte final.
- **Réglages de la session** : ceux de l'application (`DictationConfig`) : passe d'aperçu au plus toutes les 0,5 s sur
  les 15 dernières secondes du passage ouvert, marge de 0,3 s autour de la parole.
- **Aperçu** : toujours Parakeet. **Moteur final** : WhisperKit (`large-v3-v20240930_turbo`) ou Parakeet, selon
  `--engine`.
- **Transcription en bloc** : le même exemplaire du moteur final, le même vocabulaire, sur l'enregistrement entier,
  sans détecteur de voix ni marge : c'est la mesure de l'étape 1.
- **Taux d'erreur** : erreurs de mots normalisés (voir le `README.md`, « Comparaison des textes »), agrégées sur les
  phrases où la session **et** la transcription en bloc ont rendu un texte : les trois taux portent sur les mêmes
  mots. Une phrase sans parole entendue ou en échec est comptée à part. Un aperçu vide compte, pour chaque mot de la
  référence, comme omis.
- **Corpus** : celui de l'étape 1 (`bench-data/`), les mêmes enregistrements.

## Commande

Quatre passages, un par moteur et par vocabulaire. À lancer depuis la racine du dépôt, en mode release (le mode debug
n'a pas été comparé : il pourrait fausser les délais). Les chemins sont ceux du corpus de l'étape 1 ; à adapter s'il
est ailleurs.

```sh
swift run -c release supervox-bench live \
  --corpus bench-data/corpus.tsv --audio bench-data/audio \
  --out bench-data/live-whisperkit --engine whisperkit

swift run -c release supervox-bench live \
  --corpus bench-data/corpus.tsv --audio bench-data/audio \
  --out bench-data/live-whisperkit-vocab --engine whisperkit --vocabulary bench-data/vocabulaire.txt

swift run -c release supervox-bench live \
  --corpus bench-data/corpus.tsv --audio bench-data/audio \
  --out bench-data/live-parakeet --engine parakeet

swift run -c release supervox-bench live \
  --corpus bench-data/corpus.tsv --audio bench-data/audio \
  --out bench-data/live-parakeet-vocab --engine parakeet --vocabulary bench-data/vocabulaire.txt
```

Options : `--corpus`, `--audio`, `--out` (obligatoires) ; `--engine whisperkit|parakeet` (défaut `whisperkit`) ;
`--whisperkit-model` ; `--vocabulary <fichier>` ; `--settle <secondes>` (défaut 1) ; `--overwrite`. Comme les autres
commandes du banc, elle refuse un dossier de sortie suivi par git et un rapport existant sans `--overwrite`, avant de
charger quoi que ce soit.

Les modèles manquants se téléchargent au premier passage. Le détecteur de voix, Parakeet et le moteur final sont chargés
et préchauffés avant la première phrase, hors mesure.

## Résultats

Lancements du 15 novembre 2026 (date lue dans `live.md`, section « Lancement »), sur un Mac à puce Apple, binaire compilé
en mode release. Le modèle exact de la machine n'est pas publié ici ; il est dans les rapports bruts, hors du dépôt.

| Configuration | Phrases comparées | Texte final de la session | Transcription en bloc | Écart (points) | Dernier aperçu | Aperçu vide | Délai médian (s) | Délai 90e centile (s) | Échecs | Sans parole |
|---|---|---|---|---|---|---|---|---|---|---|
| WhisperKit | 20 sur 20 | 12,4 % | 12,1 % | +0,3 | 14,5 % | 0 sur 20 | 0,57 | 0,61 | 0 | 0 |
| WhisperKit + vocabulaire | 20 sur 20 | 9,7 % | 9,1 % | +0,6 | 11,2 % | 0 sur 20 | 1,30 | 1,36 | 0 | 0 |
| Parakeet | 20 sur 20 | 15,2 % | 16,1 % | −0,9 | 14,5 % | 0 sur 20 | 0,09 | 0,09 | 0 | 0 |
| Parakeet + vocabulaire | 20 sur 20 | 11,5 % | 12,7 % | −1,2 | 11,2 % | 0 sur 20 | 0,12 | 0,14 | 0 | 0 |

Le vocabulaire des passages « + vocabulaire » compte 30 termes. L'écart est la différence « session moins bloc », calculée
ici à partir des deux colonnes voisines.

Termes techniques retrouvés, sur 55 (texte final / bloc / aperçu) : WhisperKit 35 / 36 / 35 ; WhisperKit + vocabulaire
44 / 44 / 44 ; Parakeet 35 / 34 / 35 ; Parakeet + vocabulaire 44 / 43 / 44.

### Lecture

- **Session contre bloc.** L'écart va de −1,2 à +0,6 point selon la configuration. Avec 20 phrases et un seul passage,
  un écart de cette taille ne se distingue pas du hasard : la mesure ne montre pas que la session dégrade le texte, et
  ne montre pas non plus qu'elle l'améliore.
- **Dernier aperçu.** Il est à 14,5 % sans vocabulaire et à 11,2 % avec. Face à WhisperKit, il est moins juste que le
  texte final (de 1,5 à 2,1 points) ; face à Parakeet, il est du même ordre, puisque c'est le même moteur. L'aperçu est
  un guide pendant la parole, le texte final fait foi.
- **Délai.** Le texte final arrive 0,09 à 0,14 s après `finish()` avec Parakeet, 0,57 s avec WhisperKit, 1,30 s avec
  WhisperKit et le vocabulaire (médianes). Le vocabulaire coûte donc environ 0,7 s à WhisperKit sur ces phrases. Aucun
  seuil n'avait été fixé avant la mesure.
- **Vocabulaire.** Il fait passer les termes retrouvés de 35 à 44 sur 55 dans le texte final, pour les deux moteurs.
- **Échecs.** Aucune phrase en échec, aucune sans parole entendue, aucun aperçu vide.

## Limite connue, non corrigée

Le texte en direct peut perdre le début d'un passage de parole de plus de 15 s : le moteur d'aperçu ne reçoit que les
15 dernières secondes du passage ouvert. Le texte final, lui, est complet. Cette mesure ne dit rien de plus sur cette
limite : elle ne l'exerce que si le corpus contient des phrases de plus de 15 s (voir ci-dessous).

## Incertitudes

Ce qui n'a pas pu être établi, et pourquoi.

- **Dictée longue non exercée.** Les enregistrements durent de 6,0 à 10,1 s (mesuré sur les fichiers) : aucun ne
  dépasse 15 s. La limite de l'aperçu n'est donc pas exercée, et rien ici ne dit comment une dictée longue se comporte
  (essai à la main : `docs/essai-final.md`).
- **Rejeu à 16 kHz.** Les enregistrements du banc sont à 16 kHz : le rééchantillonnage d'un vrai micro (44,1 ou 48 kHz)
  n'est pas exercé, ni sa durée.
- **Cadence un peu plus lente que le temps réel.** Chaque bloc attend sa durée, puis le détecteur le traite : la durée du
  traitement s'ajoute. L'effet sur l'aperçu et sur le délai n'a pas été mesuré.
- **Silence de fin choisi.** Le `--settle` de 1 s est un choix, pas une mesure du temps que met un utilisateur à presser le
  raccourci. Le délai et l'aperçu en dépendent (un silence plus long laisse l'aperçu rattraper la parole) ; refaire un
  passage avec une autre valeur dirait de combien.
- **Une seule voix, un seul micro, une seule prise par phrase** (corpus de l'étape 1) : aucun écart-type, aucune
  généralisation. Un seul passage par configuration : la variation d'un lancement à l'autre n'est pas connue ; en lancer
  plusieurs la donnerait.
- **Machine non isolée.** Les délais dépendent de la charge de la machine au moment du lancement, et d'un moteur déjà
  chaud (préchauffé avant la première phrase).
- **Résultats de la session et du bloc non indépendants.** Les deux passent par le même exemplaire du moteur, la
  transcription en bloc juste avant la session, sur la même phrase : un effet de cache ou d'état du moteur n'est pas
  exclu.
- **Pannes du moteur d'aperçu invisibles.** Si Parakeet ne se prépare pas, la session s'en passe (pas d'aperçu) : la mesure
  le montrerait par des aperçus vides, pas par un échec.
- **Texte du message d'échec de la session.** Le banc ne reprend que la phrase que la session donne : la cause exacte
  d'une panne de moteur n'y est pas.
