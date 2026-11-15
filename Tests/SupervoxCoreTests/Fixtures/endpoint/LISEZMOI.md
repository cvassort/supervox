# Fixtures du dossier `endpoint`

Aucun de ces fichiers n'a été obtenu en essayant un service réel pour la tâche 1 de l'étape 5.

## Reprennent la forme de la documentation (non enregistrées)

- `messages-anthropic-text.sse`, `messages-anthropic-thinking.sse`, `messages-anthropic-max-tokens.sse`,
  `messages-anthropic-error-event.sse` : flux de l'API Messages, forme de la documentation officielle du flux
  (événements `message_start`, `content_block_*`, `message_delta`, `message_stop`, `error`). Leur première ligne est un
  commentaire SSE qui le dit.
- `messages-anthropic-401.json`, `messages-anthropic-529.json` : objet d'erreur
  `{"type":"error","error":{"type":…,"message":…}}` de la documentation. Un fichier JSON ne peut pas porter de commentaire :
  cette ligne en tient lieu.

## Construites sur la forme d'enregistrements existants

- `completion-openai-reasoning-then-content.sse`, `completion-openai-length.sse` : mêmes champs que
  `chat-stream-content.sse` et `chat-stream-reasoning.sse`, avec le modèle `modele-exemple` et l'identifiant
  `requete-exemple`. Le texte et l'ordre des morceaux sont écrits à la main.

## Autres fichiers

- `chat-stream-content.sse`, `chat-stream-reasoning.sse` : `ChatStreamTests` les décrit comme des enregistrements.
- `models-*.json`, `transcription-*.json`, `speech-200.wav` : leur provenance n'est consignée ni dans ce dossier ni dans
  l'historique de commits ; non établie ici.
