# Supervox — document de design

Date : 2026-11-12. État : à valider par l'utilisateur.

Dans ce document, « décidé » désigne un choix de l'utilisateur. « Choix du concepteur » désigne un choix fait à sa place, qu'il peut contester. « Mesuré » désigne un résultat obtenu sur sa machine pendant le cadrage, avec le nombre d'essais.

## 1. Intention

Supervox est une application macOS de dictée vocale, personnelle et open source.

Elle fait deux choses :

1. **Dictée** : une touche, on parle, le texte arrive dans l'application active, brut ou retravaillé par un modèle de langage.
2. **Entretien vocal** : une conversation orale avec un modèle. Il pose des questions à voix haute, on lui répond, on peut lui couper la parole. À la fin il rédige un prompt complet et structuré, prêt à être donné à un agent IA.

Pourquoi : l'utilisateur dicte beaucoup de prompts pour des agents. Les outils existants remplacent des mots, font payer la reformulation, et aucun ne mène un entretien oral qui fait le tour d'une demande avant de l'écrire. L'entretien est la raison d'être du projet ; la dictée seule existe déjà ailleurs.

## 2. Objectifs, non-objectifs, anti-objectifs

**Objectifs**

- Obtenir en une à deux minutes de conversation un prompt qu'on n'aurait pas mieux écrit au clavier.
- Dicter du français mêlé de termes techniques anglais sans mots remplacés.
- Choisir librement ses modèles : endpoint personnel (OpenAI-compatible ou Anthropic) avec clé et liste de modèles, et modèles de transcription locaux téléchargeables dans l'app.
- Un modèle de langage local reste possible sans rien embarquer : il suffit de déclarer comme endpoint un serveur local OpenAI-compatible (Ollama, LM Studio). L'app n'exécute pas elle-même de modèle de langage (choix du concepteur).
- Une interface native, sobre, dans le style des apps Apple.

**Non-objectifs de la première version**

- Le moteur « voix à voix » (un seul modèle cloud qui écoute et parle). Sa place est prévue (section 6.3), son écriture est reportée.
- Windows, Linux, iOS.
- Transcription de fichiers, réunions, synchronisation entre appareils.
- Distribution en binaire signé et notarisé, App Store.

**Anti-objectifs** (l'outil serait raté même s'il fonctionnait)

- Un entretien où l'on attend plusieurs secondes entre chaque tour, ou qu'on ne peut pas interrompre.
- Un outil qui se coupe lui-même en entendant sa propre voix.
- Un prompt collé sans relecture possible.
- Une clé d'API écrite en clair dans un fichier.

## 3. Contraintes

- Machine cible : Mac Apple Silicon (M4 Pro, 24 Go), macOS 27.
- **Version minimale : macOS 26** (choix du concepteur). Sous macOS 27, `installTap` et `play()` d'`AVAudioEngine` sont dépréciés au profit de variantes qui signalent les erreurs ; elles sont utilisées sous condition de disponibilité.
- **Toutes les mesures de ce document ont été faites sous macOS 27.** Rien n'a été vérifié sous macOS 26 : l'app doit s'y compiler, mais l'annulation d'écho n'y est pas validée et le README le dira.
- Pas de compte développeur Apple payant : compilation locale. La permission Accessibilité peut être redemandée après une recompilation.
- Licence **MIT** (choix du concepteur). Toute dépendance doit être compatible (MIT, Apache-2.0, BSD). Pas de code sous GPL.
- Dépôt GitHub public. Rien de propre à un fournisseur ne figure dans le code : l'endpoint, les modèles et les voix sont des réglages.
- L'endpoint de l'utilisateur est OpenAI-compatible : `chat/completions` en flux, `audio/transcriptions` et `audio/speech` sans flux, aucune route temps réel.

## 4. Faits mesurés pendant le cadrage

Ces mesures fondent plusieurs choix. Un à trois essais par cas : ce sont des ordres de grandeur.

| Sujet | Résultat | Conséquence |
|---|---|---|
| Annulation d'écho d'Apple, haut-parleurs | Sans elle, la transcription du micro ne rend que la phrase de l'outil. Avec elle, elle ne rend que les mots de l'utilisateur, même en parole simultanée. | L'interruption sur haut-parleurs est faisable avec `setVoiceProcessingEnabled`. |
| Écho résiduel, utilisateur silencieux | Maximum −40 dB, contre −15 à −25 dB pour la voix de l'utilisateur. | L'outil ne déclenche pas sa propre interruption. |
| Casque Bluetooth | La voix de l'outil n'atteint pas le micro, avec ou sans annulation. | L'annulation peut rester active partout. |
| Micro avec annulation | 9 canaux identiques à 48 kHz (3 au casque). | Lire le premier canal ; ne rien supposer du nombre de canaux. |
| Transcription de silence | Whisper invente du texte (« Merci. », « Sous-titrage… »). | Ne jamais transcrire un passage sans voix détectée. |
| Modèle de langage rapide, via l'endpoint | Premier mot en 0,2 à 0,3 s pour le plus rapide ; 1 à 8 s pour ceux qui raisonnent d'abord. | Un modèle rapide et sans raisonnement pour les tours de parole. |
| Transcription via l'endpoint | 1,2 à 3,5 s pour 10 s d'audio, sans flux. | Correcte pour la dictée, trop lente pour l'entretien. |
| Synthèse vocale via l'endpoint | 1,2 à 1,3 s pour une phrase de 10 s, livrée d'un bloc ; 0,23 à 0,52 s pour une phrase courte (trois essais). Le français exige un paramètre propre au serveur. | Synthétiser phrase par phrase, en commençant par une phrase courte ; permettre des paramètres libres par voix. |

## 5. Ce que l'utilisateur a décidé

### 5.1 Parcours

**Dictée.** Une touche globale ouvre le panneau. On parle, le texte s'écrit en direct. À la fin, le texte (brut ou retravaillé selon le mode) est collé dans l'application active.

**Entretien.** Même panneau, mode Entretien. L'utilisateur expose sa demande. L'outil répond à la voix et pose une question à la fois. L'utilisateur répond, et peut parler par-dessus l'outil pour le couper. L'entretien se termine de deux façons : l'outil propose de conclure quand il a assez d'éléments, ou l'utilisateur conclut quand il veut, à la voix ou à la touche.

**Relecture.** Le prompt final s'affiche dans le panneau. L'utilisateur le relit, peut le corriger au clavier ou à la voix, puis un geste le colle dans l'application active et le copie. Rien n'est collé sans ce geste.

**Corriger à la voix** (décidé) : l'utilisateur dit ce qu'il faut changer (« ajoute que les tests doivent passer », « enlève la partie sur l'API »). Le modèle fort réécrit le prompt selon cette consigne et la nouvelle version remplace l'ancienne à l'écran. Ce n'est ni une dictée insérée dans le texte, ni une reprise de l'entretien. La version précédente reste récupérable par une annulation.

**Relecture réglable par mode** (décidé) : chaque mode a un réglage « relire avant de coller ». Il est activé par défaut pour Prompt en un coup, désactivé pour les dictées brute et nettoyée. L'entretien passe toujours par la relecture.

### 5.2 Interface

Un panneau central flottant, façon Spotlight : translucide, coins arrondis, qui ne prend pas le focus de l'application active.

- En haut, les modes sous forme de pastilles.
- En dictée : un indicateur d'enregistrement, une forme d'onde, la durée, le texte en direct.
- En entretien : un orbe animé pour l'outil, sa question en texte, la dernière réplique de l'utilisateur, le numéro de la question, un bouton Conclure.
- En relecture : le prompt, puis Coller (action principale), Copier, Corriger à la voix.

Une icône dans la barre de menus donne accès aux réglages.

### 5.3 Modes de dictée de la première version

- **Dictée brute** : la transcription telle quelle, sans modèle de langage.
- **Dictée nettoyée** : ponctuation, mots parasites retirés, termes techniques corrigés, sens inchangé.
- **Prompt en un coup** : la dictée reformulée en prompt structuré, sans questions.
- **Modes personnalisés** : une consigne écrite par l'utilisateur, un modèle, un raccourci.

### 5.4 Réglages

- Fournisseurs : adresse de l'endpoint, type (OpenAI-compatible ou Anthropic), clé, liste des modèles lue depuis l'endpoint.
- Modèles de transcription locaux : liste, téléchargement, suppression.
- Voix : choix parmi des jeux de voix par langue et par genre.
- Raccourcis.

## 6. Architecture (choix du concepteur)

### 6.1 Briques

Chaque brique est derrière un protocole Swift, pour être remplaçable et testable avec un double.

| Brique | Rôle | Première réalisation |
|---|---|---|
| `AudioIO` | Capture du micro avec annulation d'écho, lecture de la voix, position de lecture | `AVAudioEngine`, voice processing actif |
| `VoiceDetector` | Dit quand quelqu'un parle et quand il a fini | Un détecteur de voix local à modèle |
| `Transcriber` | Audio vers texte, en flux ou en bloc | Un moteur local en flux ; l'endpoint en option pour la dictée |
| `LanguageModel` | Texte vers texte, en flux | Clients OpenAI-compatible et Anthropic |
| `SpeechSynthesizer` | Texte vers audio | Client `audio/speech` ; voix du système en secours |
| `ConversationEngine` | Mène l'entretien | La chaîne décrite en 6.2 |
| `TextInserter` | Colle dans l'application active | Collage simulé, presse-papiers sauvegardé et restauré |
| `Settings`, `Secrets` | Réglages ; clés dans le trousseau | Fichier dans Application Support ; Keychain |

### 6.2 L'entretien : une machine à états

États : Écoute, Réflexion, Parole, Conclusion, Relecture.

1. **Écoute.** Le détecteur de voix découpe la parole. La transcription locale tourne en flux. Un silence assez long marque la fin du tour.
2. **Réflexion.** Le modèle rapide reçoit l'historique et répond en flux.
3. **Parole.** La réponse est découpée en phrases dès qu'elles sont complètes. Chaque phrase est synthétisée puis lue à la suite. La première phrase doit être courte, pour que le son parte vite.
4. **Interruption.** Pendant la Parole, le micro reste ouvert. Si le détecteur entend de la voix pendant une durée minimale, la lecture s'arrête, la file de phrases est vidée et on repasse en Écoute.
5. **Conclusion.** Déclenchée par l'outil, la voix ou la touche. Le modèle fort reçoit toute la conversation et rédige le prompt final.

Trois règles que le constructeur ne doit pas rater :

- **L'historique ne contient que ce qui a été entendu.** En cas d'interruption, la réplique de l'outil est tronquée à la dernière phrase réellement lue.
- **Aucune transcription sans voix détectée.** Sinon le moteur invente du texte.
- **Le seuil d'interruption est au-dessus de l'écho résiduel.** Mesuré à −40 dB au pire ; la voix de l'utilisateur est entre −15 et −25 dB.

**Comment la conclusion est reconnue.** Le modèle rapide rend, en plus du texte à dire, un signal structuré : continuer, proposer de conclure, ou conclure. Le contrat de `LanguageModel` porte donc du texte et ce signal ; la forme exacte (sortie structurée ou marqueur) est laissée au constructeur, à condition que le marqueur ne soit jamais lu à voix haute. Aucune détection par mots-clés dans la transcription : c'est le modèle qui comprend « c'est bon, on arrête ». Quand l'outil propose de conclure, il attend l'accord oral de l'utilisateur. La touche conclut sans rien demander.

**Deux emplacements de modèle** : un modèle rapide pour les tours de parole, un modèle fort pour le prompt final, où la latence ne compte pas. Ils peuvent désigner le même modèle.

**Consigne de l'intervieweur** : une question à la fois, phrases courtes faites pour être dites, pas de liste ni de mise en forme, proposer de conclure quand l'objectif, le contexte, les contraintes et le résultat attendu sont connus. Le nombre de questions est plafonné par un réglage.

**Forme du prompt final** : objectif, contexte, contraintes, résultat attendu, critères de réussite. Le gabarit est modifiable.

### 6.3 Place du moteur voix à voix

`ConversationEngine` expose des **événements de conversation**, pas de l'audio : transcription partielle, fin de tour, texte de réponse, début et fin de parole de l'outil, interruption avec le texte entendu, fin d'entretien. L'interface ne connaît ni la chaîne ni ses maillons. Un second moteur pourra s'y brancher plus tard. Il n'est pas écrit dans cette version, et aucune abstraction supplémentaire n'est ajoutée pour lui.

### 6.4 Dictée

Un mode est une donnée : nom, consigne (vide pour la dictée brute), modèle, moteur de transcription, raccourci. Les quatre modes de base sont des modes comme les autres, fournis par défaut.

**Vocabulaire personnel** : une liste de termes (noms de produits, d'outils) transmise au moteur de transcription quand il l'accepte, et à la consigne de nettoyage.

**Moteur de transcription** : interchangeable. Le choix du moteur par défaut n'est pas fait dans ce document (voir étape 1).

### 6.5 Voix

Une voix est une donnée : fournisseur, modèle, identifiant, langue, genre, et **paramètres supplémentaires libres** envoyés tels quels au fournisseur. Ce dernier champ est nécessaire : certains serveurs exigent un paramètre non standard pour parler français.

Voix par défaut : celle de l'endpoint de l'utilisateur, jugée « acceptable pour démarrer ». Les voix du système servent de secours si l'endpoint ne répond pas.

### 6.6 Touche et raccourcis

- **Une touche globale** ouvre le panneau sur le dernier mode utilisé et démarre l'écoute aussitôt. On change de mode en cliquant sur une pastille (décidé : « on appuie sur une touche, une petite interface apparaît, on choisit ensuite en cliquant »).
- **Bascule par défaut** (choix du concepteur) : un appui démarre, un second appui termine. Un réglage propose le maintien (parler tant que la touche est enfoncée). Pas de comportement hybride où la durée de l'appui change le mode : c'est une source de bugs connue chez les outils existants.
- Échap annule sans rien coller.
- Chaque mode peut avoir son propre raccourci, qui ouvre le panneau directement sur ce mode. L'entretien est un mode comme un autre de ce point de vue.
- Les raccourcis sont des combinaisons classiques (touche avec modificateurs). Une touche de modification seule ou la touche Fn n'est pas prise en charge dans cette version : elle exigerait une autre méthode de capture et peut-être une permission de plus.

### 6.7 Insertion, permissions, données

- Insertion par collage simulé. Le presse-papiers est sauvegardé avant et restauré après, seulement s'il n'a pas changé entre-temps.
- Sans permission Accessibilité, l'outil copie le texte et le dit clairement, au lieu d'échouer en silence.
- Permissions demandées au premier lancement, avec une explication : micro, puis Accessibilité.
- **Historique local** (choix du concepteur) : les derniers entretiens et leurs prompts, pour ne pas perdre un prompt non collé. Stocké sur le disque, jamais envoyé. Durée de conservation réglable. Les enregistrements audio ne sont pas conservés.

## 7. Ordre de construction

Un seul lot, comme décidé, mais dans cet ordre. Chaque étape laisse quelque chose d'utilisable.

1. **Banc d'essai en ligne de commande**, avant toute interface. Deux mesures :
   - **Transcription.** Le corpus n'existe pas encore : l'utilisateur lit à voix haute une vingtaine de phrases écrites à l'avance, en français mêlé d'anglais technique, tirées de ses vrais prompts. Le texte écrit sert de référence. On compare les moteurs locaux en flux sous licence permise, et la transcription de l'endpoint. Critères, dans l'ordre : taux d'erreur sur les termes techniques, taux d'erreur global, délai de la transcription finale. Le même moteur local sert à la dictée et à l'entretien.
   - **Latence de bout en bout** de la chaîne de l'entretien, de la fin réelle de la parole au premier son. Cible : moins de 2 secondes.
   - **Si aucun moteur local n'est assez bon** : la dictée passe par l'endpoint (plus lent, sans texte en direct) et l'entretien utilise le meilleur moteur local disponible, avec ses défauts écrits noir sur blanc. **Si la cible de latence n'est pas tenue** : on le dit à l'utilisateur avant de construire l'interface, avec les leviers (voix du système, silence de fin de tour plus court, autre modèle). La décision de continuer lui revient.
2. **Socle** : app de barre de menus, touche globale, panneau, réglages, trousseau, permissions.
3. **Dictée brute** avec insertion.
4. **Relecture** : affichage, édition au clavier, Coller, Copier. Elle vient avant les modes, puisque Prompt en un coup en dépend.
5. **Modes avec modèle de langage** : nettoyée, prompt en un coup, personnalisés. Correction à la voix dans la relecture.
6. **Entretien vocal** : machine à états, interruption, conclusion.
7. **Réglage des voix.**

## 8. Tests

Les tests visent les endroits où l'outil peut réellement casser, pas la couverture.

- **Machine à états de l'entretien**, avec des doubles pour l'audio, le modèle et la voix : interruption au milieu d'une phrase, pendant la synthèse, pendant la réflexion ; double conclusion ; modèle qui ne répond pas ; voix qui échoue.
- **Troncature de l'historique** : après interruption, l'historique contient exactement les phrases lues.
- **Découpage en phrases** d'un flux de texte : abréviations, nombres décimaux, points de suspension, fragments coupés au milieu d'un mot.
- **Clients d'endpoint** contre un serveur local de test : flux interrompu, erreurs 4xx et 5xx, réponse vide, modèle qui raisonne avant de répondre. Le serveur de test rejoue des **réponses réelles enregistrées** depuis l'endpoint de l'utilisateur à l'étape 1 (clé et identifiants retirés), pas un comportement deviné. Le constructeur a accès à cet endpoint.
- **Presse-papiers** : restauré si inchangé, laissé intact s'il a changé.
- **Garde anti-invention** : un fichier audio de silence ne produit aucun texte.
- **Seuil d'interruption** : sur des enregistrements de synthèse rejoués, la voix de l'outil seule ne déclenche rien.

Ce qui ne se teste pas automatiquement (qualité de la voix, fluidité de l'échange, écho dans une pièce réelle) fait l'objet d'une vérification manuelle décrite à chaque étape.

## 9. Risques et inconnues

| Inconnue | Pourquoi elle n'est pas levée | Quand elle le sera |
|---|---|---|
| Qualité et vitesse d'une transcription locale en flux, en français technique | Aucun benchmark public ; non mesuré | Étape 1 |
| Délai entre la fin réelle de la parole et le premier son de l'outil | Seuls les maillons ont été mesurés séparément : environ 1,5 s en les additionnant, hors transcription locale. Cible : moins de 2 secondes, silence de fin de tour compris. La marge est mince. | Étape 1 |
| Qualité des questions posées par le modèle rapide | Seule sa vitesse a été mesurée | Étape 6 |
| Voix française | Une seule voix, jugée seulement « acceptable » | Étape 7, en cherchant d'autres voix |
| Annulation d'écho dans d'autres conditions | Testée dans une pièce, à un volume, avec un casque | À l'usage |
| Son dégradé dans un casque Bluetooth quand son micro est actif | Non mesuré | Étape 6 ; piste : micro du Mac avec sortie au casque |
| Fiabilité du collage selon les applications | Non testée | Étape 3 |
| Permission Accessibilité redemandée après recompilation | Compte développeur gratuit | Étape 2 |

## 10. Laissé au constructeur

- Le choix des bibliothèques de transcription et de détection de voix, dans les licences permises.
- La structure des fichiers et des modules.
- Le format du fichier de réglages.
- Le détail visuel du panneau, dans l'esprit décrit en 5.2.
- Les valeurs par défaut des seuils (durée de silence, durée minimale d'interruption), à régler à l'étape 6 et à exposer dans les réglages avancés.
