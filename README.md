# supervox

[![Tests](https://github.com/cvassort/supervox/actions/workflows/tests.yml/badge.svg)](https://github.com/cvassort/supervox/actions/workflows/tests.yml)

supervox sera une application macOS de dictée et d'entretien vocal. Elle est en cours de construction.
Ce dépôt contient pour l'instant le banc d'essai : `supervox-bench`, un outil en ligne de commande qui mesure
la qualité de transcription de plusieurs moteurs et le délai de réponse de bout en bout.

## Prérequis

- macOS 26 ou plus (version minimale déclarée par le paquet) et Xcode 27 (le code utilise des API de macOS 27,
  sous `if #available`, et il faut le SDK 27 pour compiler).
- État de la vérification : testé en local sous macOS 27 avec Xcode 27. Le pipeline GitHub Actions (étiquette
  `xcode-27`, image en préversion) n'a pas encore été exécuté. macOS 26 est la version minimale déclarée, mais
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

## Le banc d'essai

```sh
swift run supervox-bench <commande> --help
```

- `record` : enregistre ta voix pour chaque phrase d'un corpus (`--corpus`, `--out`, `--overwrite`).
  Un exemple de corpus est dans `Bench/corpus.example.tsv`. Aucune variable d'environnement.
- `transcribe` : fait transcrire les enregistrements par chaque moteur et compare les taux d'erreur
  (`--corpus`, `--audio`, `--engines`, `--out`, et d'autres options). Le moteur `endpoint` demande
  `--endpoint-model` et lit l'endpoint dans l'environnement ; les moteurs locaux n'en ont pas besoin.
  La commande charge un modèle de détection de voix avant tout moteur : il est téléchargé au premier lancement,
  même avec le seul moteur du système (`--engines apple`).
- `latency` : mesure le délai entre la fin de la parole et la première phrase synthétisée de la réponse
  (`--audio`, `--engine`, `--chat-model`, `--tts-model`, `--voice`, `--out`, et d'autres options).
  Elle lit toujours l'endpoint dans l'environnement.

### Comparaison des textes

Le taux d'erreur et le rappel des termes comparent des mots normalisés :

- plié, jamais compté comme erreur : la casse, les apostrophes, les traits d'union et la ponctuation ;
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
