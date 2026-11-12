#!/bin/bash
# Enregistre des réponses réelles d'un endpoint compatible OpenAI, pour les tests du client.
#
# Environnement : SUPERVOX_BASE_URL (adresse de l'endpoint), SUPERVOX_API_KEY (clé).
# Arguments     : <modele-transcription> <modele-chat> <modele-raisonnement> <modele-voix> <voix> <champ=valeur>
#   <champ=valeur> : champ supplémentaire ajouté au niveau supérieur du corps JSON de la synthèse vocale.
#
# Le script n'écrit que des corps de réponse et affiche les codes de statut. Il n'enregistre jamais
# d'en-tête ni la clé. Les identifiants de modèle et de voix passés en arguments sont remplacés dans les
# fichiers écrits par des valeurs neutres. Relire chaque fichier avant de le versionner : ce remplacement
# ne retire pas les mentions du fournisseur éventuelles dans le texte des réponses.
#
# Attention : relancer le script écrase des fixtures relues et versionnées. Une passerelle avec cache peut
# répondre à un prompt déjà vu en un seul morceau, ce qui appauvrit les flux enregistrés : changer le prompt
# de chat plutôt que de relancer à l'identique.
set -euo pipefail

if [ "$#" -ne 6 ]; then
  echo "usage : $0 <modele-transcription> <modele-chat> <modele-raisonnement> <modele-voix> <voix> <champ=valeur>" >&2
  exit 64
fi
: "${SUPERVOX_BASE_URL:?SUPERVOX_BASE_URL manquante}"
: "${SUPERVOX_API_KEY:?SUPERVOX_API_KEY manquante}"

STT_MODEL="$1"; CHAT_MODEL="$2"; REASONING_MODEL="$3"; TTS_MODEL="$4"; VOICE="$5"; EXTRA="$6"
EXTRA_KEY="${EXTRA%%=*}"; EXTRA_VALUE="${EXTRA#*=}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${SUPERVOX_FIXTURES_DIR:-$ROOT/Tests/SupervoxCoreTests/Fixtures/endpoint}"
BASE="${SUPERVOX_BASE_URL%/}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT"

SENTENCE="Bonjour, ceci est une phrase de test pour la reconnaissance vocale."

# La clé passe par l'entrée standard de curl (option -K) : elle n'apparaît pas dans la liste des processus.
auth_config() { printf 'header = "Authorization: Bearer %s"\n' "$1"; }

# Remplace par des valeurs neutres : les identifiants passés en arguments, tout champ "model" (l'endpoint
# renvoie le nom du modèle servi, qui diffère de l'alias demandé) tout identifiant de requête textuel et le bloc "backend" (détail interne de la passerelle).
sanitize() {
  local f="$1"
  python3 -I - "$f" "$STT_MODEL" "modele-test" "$CHAT_MODEL" "modele-test" \
    "$REASONING_MODEL" "modele-test" "$TTS_MODEL" "modele-test" "$VOICE" "voix-test" <<'PY'
import re, sys
path, pairs = sys.argv[1], sys.argv[2:]
data = open(path, "rb").read()
for old, new in zip(pairs[0::2], pairs[1::2]):
    data = data.replace(old.encode(), new.encode())
data = re.sub(rb'"model":\s*"[^"]*"', b'"model":"modele-test"', data)
data = re.sub(rb'"id":\s*"[^"]*"', b'"id":"requete-test"', data)
data = re.sub(rb'"backend":\s*\{[^{}]*\},?', b'', data)
open(path, "wb").write(data)
PY
}

# call <fichier> <statut attendu> <clé> <args curl...> : écrit le corps, vérifie le statut.
call() {
  local file="$1" expected="$2" key="$3"; shift 3
  local status
  status=$(auth_config "$key" | curl -sS -K - -o "$OUT/$file" -w '%{http_code}' "$@")
  case "$file" in *.wav) ;; *) sanitize "$OUT/$file" ;; esac
  echo "$file : statut $status"
  if [ "$status" != "$expected" ]; then
    echo "statut inattendu pour $file (attendu $expected)" >&2
    exit 1
  fi
}

# Phrase de test : synthèse vocale système, jamais une voix humaine.
/usr/bin/say -v Thomas --file-format=WAVE --data-format=LEI16@16000 -o "$WORK/phrase.wav" "$SENTENCE"

STT_URL="$BASE/v1/audio/transcriptions"
call transcription-200.json 200 "$SUPERVOX_API_KEY" "$STT_URL" \
  -F "file=@$WORK/phrase.wav;type=audio/wav" -F "model=$STT_MODEL" -F "language=fr" \
  -F "prompt=Test" -F "response_format=json"
call transcription-401.json 401 "cle-volontairement-fausse" "$STT_URL" \
  -F "file=@$WORK/phrase.wav;type=audio/wav" -F "model=$STT_MODEL" -F "language=fr" -F "response_format=json"

CHAT_URL="$BASE/v1/chat/completions"
chat_body() { jq -nc --arg m "$1" --argjson n "$2" \
  '{model:$m, stream:true, max_tokens:$n, messages:[{role:"user", content:"Compte de un à cinq, en toutes lettres, séparés par des virgules."}]}'; }
call chat-stream-content.sse 200 "$SUPERVOX_API_KEY" "$CHAT_URL" -N \
  -H "Content-Type: application/json" -d "$(chat_body "$CHAT_MODEL" 40)"
call chat-stream-reasoning.sse 200 "$SUPERVOX_API_KEY" "$CHAT_URL" -N \
  -H "Content-Type: application/json" -d "$(chat_body "$REASONING_MODEL" 60)"

SPEECH_BODY=$(jq -nc --arg m "$TTS_MODEL" --arg i "$SENTENCE" --arg v "$VOICE" --arg k "$EXTRA_KEY" --arg x "$EXTRA_VALUE" \
  '{model:$m, input:$i, voice:$v, response_format:"wav"} + {($k):$x}')
call speech-200.wav 200 "$SUPERVOX_API_KEY" "$BASE/v1/audio/speech" \
  -H "Content-Type: application/json" -d "$SPEECH_BODY"
