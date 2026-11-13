# Résultats du banc d'essai — 2026-11-13

Mesures faites avec `supervox-bench` sur une seule voix, un seul micro (micro intégré d'un MacBook Pro, 48 kHz),
20 phrases en français mêlé de termes techniques anglais, une prise par phrase. Les rapports bruts restent hors du
dépôt : ils contiennent ce qui a été dit.

## Transcription

Vocabulaire global de 30 termes, tiré des phrases du corpus.

| Moteur | Erreurs de mots (WER) | Termes trouvés | Durée médiane (s) |
|---|---|---|---|
| WhisperKit (`large-v3-v20240930_turbo`) + vocabulaire | 9,1 % | 44/55 | 1,33 |
| Parakeet (TDT 0.6B v3) + vocabulaire | 12,7 % | 43/55 | 0,19 |
| WhisperKit | 12,1 % | 36/55 | 0,57 |
| Endpoint distant (modèle de la famille Whisper) | 13,3 % | 36/55 | 0,88 |
| Endpoint distant + vocabulaire | 13,3 % | 36/55 | 2,52 |
| Parakeet | 16,1 % | 34/55 | 0,06 |
| Apple SpeechTranscriber (sans vocabulaire) | 19,7 % | 21/55 | 0,12 |

Constats :

- Le vocabulaire fait gagner 8 termes à WhisperKit et 9 à Parakeet.
- Avec Parakeet, le recalage par vocabulaire a aussi remplacé à tort deux mots corrects par des termes du
  vocabulaire (« worker » par « Docker », « retry » par « Sentry »), sur 20 phrases.
- Sur l'endpoint distant essayé, le vocabulaire n'a rien changé au texte et a allongé la durée.

## Latence d'un tour de conversation

Délai entre la fin de la parole et le premier son de la réponse. 40 essais par moteur, silence de fin de tour de
600 ms, objectif de 2,0 s, modèle de chat et synthèse vocale servis par un endpoint distant.

| Transcription | Médiane, détection en direct (s) | 90e centile (s) | Tours au-dessus de 2 s | Verdict |
|---|---|---|---|---|
| Parakeet + vocabulaire | 1,87 | 2,36 | 14/40 | non tenu |
| WhisperKit + vocabulaire | 2,99 | 3,40 | 40/40 | non tenu |

Avec un silence constant de 600 ms (sans le retard du détecteur de voix) : Parakeet, médiane 1,45 s, 2 tours sur 40
au-dessus, verdict non établi ; WhisperKit, médiane 2,56 s, 40 sur 40, non tenu.

Médianes par maillon avec Parakeet : silence 0,60 s ; transcription 0,19 s ; première phrase du modèle 0,34 s ;
synthèse 0,31 s. La détection en direct de la fin de tour demande au moins 1,02 s : c'est plus de la moitié du délai.

## Décisions

- Dictée : WhisperKit avec vocabulaire par défaut ; Parakeet reste sélectionnable.
- Entretien vocal : poursuivi, avec Parakeet. L'objectif « neuf tours sur dix sous 2 s » n'est pas tenu ; le poste à
  réduire est la détection de fin de tour, pas la transcription, le modèle ni la synthèse.

## Incertitudes

- Une seule voix, un seul micro, une seule prise par phrase : aucun écart-type, aucune généralisation.
- Le vocabulaire vient des phrases mesurées : son gain est optimiste par rapport à un dictionnaire personnel réel.
- Le taux de termes inventés par le recalage de Parakeet repose sur 2 cas : il n'est pas estimé.
- Les essais de latence s'enchaînent sans pause, contre un seul endpoint, à un seul moment de la journée. Après
  une longue pause, la réalité est plus lente (non mesuré).
- Le retard du détecteur de voix sur la vraie fin de parole n'est pas ajouté aux chiffres.
