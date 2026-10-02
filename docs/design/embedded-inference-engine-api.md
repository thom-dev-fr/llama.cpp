# API C++ du moteur d’inférence embarquable

L’interface est `include/llama-engine.h`, dans le namespace `llama_engine`. Elle
est expérimentale : aucune stabilité ABI n’est promise. Lier la cible CMake
`llama-engine` suffit ; elle n’expose que ce header et `nlohmann::ordered_json`
(alias `llama_engine::json`, cible `vendor::nlohmann`, qui conserve l’ordre natif
des champs). Ni `common_params`, ni types de tâches, ni header serveur/CLI/HTTP
ne sont visibles : `tests/test-engine.cpp` échoue à la compilation si un header
privé devient accessible.

- **Exemple compilé** : [`examples/engine-simple/engine-simple.cpp`](../../examples/engine-simple/engine-simple.cpp)
  (chat streamé puis requête complète), construit aussi par les tests sous le nom
  `test-engine-example` dans tous les profils, y compris sans HTTP.
- **Consommateurs** : `llama-cli` en mode local (API publique uniquement,
  `tools/cli/cli-engine.cpp`) ; `llama-server`, qui lie en plus
  `llama-engine-internal` (voir « Interface interne ») ; les tests publics
  `test-engine`, `test-engine-operations`, `test-engine-fixtures`,
  `test-engine-catalog`, `test-engine-sources` et `test-engine-acquisition`.
- **Qualification sur modèles représentatifs** : `test-engine-qualification`
  (API publique seule) exerce, sur le backend choisi, chat complet/streamé,
  appels d’outils streamés et tour de résultat, sortie structurée, reasoning,
  événements Responses/Anthropic, annulation, arrêt avec lecteur bloqué,
  moteurs coexistants, éviction multi-modèles, vision et audio (transcription
  et chat). Toujours compilé ; exécuté par CTest (label `heavy`) seulement si
  `LLAMA_ENGINE_QUALIFY_ARGS` fournit ses arguments (`--model`, `--gpu-layers`,
  `--second-model`, `--mmproj`/`--image`, `--audio-model`/`--audio-mmproj`/`--audio`).
- **Build** : `LLAMA_BUILD_ENGINE=ON` ; acquisition réseau optionnelle avec
  `LLAMA_BUILD_COMMON_ACQUISITION=ON` (commandes dans [docs/build.md](../build.md)).

Exemple minimal :

```cpp
#include "llama-engine.h"

llama_engine::config config;
config.model_path = "/models/stories260K-f32.gguf";
llama_engine::event error;
auto engine = llama_engine::engine::create(config, error);
if (!engine) {
    // error.category et error.message décrivent l’échec.
    return;
}
auto request = engine->completion({
    {"prompt", "Once upon a time"}, {"n_predict", 32}, {"stream", true}
});
for (;;) {
    auto event = request->next();
    if (event.terminal()) {
        // success, error ou cancelled : une seule issue par requête.
        break;
    }
    // event.data suit le schéma natif. Un payload null signale le début
    // de génération ; le dernier payload métier conserve stop/timings/etc.
}
engine->stop();
```

Pour une demande sans `stream`, utiliser `request->result()` à la place de la
boucle : son événement `success` contient l’objet natif complet, ou le tableau
ordonné des résultats des prompts/completions multiples. `next_for(milliseconds)`
permet au consommateur de vérifier une déconnexion ou d’émettre un keep-alive ;
`timeout` n’est pas terminal et ne provoque aucune annulation.

## Configuration d’un modèle

Un moteur charge synchronement son modèle. `create()` retourne `nullptr` et une
erreur explicite si la configuration ou le chargement échoue. `generation_defaults`
est fusionné avec le JSON des requêtes de génération, qui a priorité. La validation,
les alias de paramètres et l’ordonnanceur sont ceux du chemin natif existant.

`config` comporte deux niveaux, sans `common_params`, `argc/argv` ni option HTTP :

- **Champs typés** : raccourcis aux défauts prudents pour l’embarqué (CPU,
  contexte 512, 2 threads, un slot, batchs 128, ni ajustement mémoire `fit` ni
  warmup ; `gpu_layers = 0` garde aussi le projecteur multimodal sur CPU).
  `std::nullopt` ou une valeur vide conserve le défaut de llama.cpp. `chat_template`
  (nom ou source Jinja), `mmproj_path`, `embeddings`, `pooling_type` (-1 défaut
  modèle, 0 none, 1 mean, 2 CLS, 3 last, 4 rank), `slot_save_path` (répertoire
  existant ; vide interdit les écritures), `lora_paths` (échelle 1, modifiable par
  requête) et `sleep_idle_seconds` complètent la liste.
- **`options`** : tout autre réglage, nommé comme dans un fichier de presets INI —
  nom long sans tirets (`ctx-size`), forme négative (`no-warmup`) ou variable
  `LLAMA_ARG_*`. Les valeurs suivent la ligne de commande de `llama-server` :
  mêmes gestionnaires (registre de `common/arg.cpp`), même post-traitement
  (`common_params_finalize`), mêmes ajustements serveur (slots automatiques,
  batch des embeddings, pool KV par slot, alias par défaut). Ressources :
  `model`, `hf-repo`, `hf-file`, `model-url`, `docker-repo`, `hf-token`, `offline`,
  `mmproj*`, modèles de brouillon.

`find_option_scope(name)` indique à qui appartient une option, quelle que soit
son écriture (`ctx-size`, `--ctx-size`, `no-warmup`, `LLAMA_ARG_CTX_SIZE`) :
`engine` (acceptée par `config::options`), `host`, `catalog` ou `unknown`. Un
hôte qui lit une ligne de commande ou un preset complet ne transmet ainsi au
moteur que les options du modèle (c’est ce que fait `llama-cli`). `model_id(config)`
donne l’identifiant que `create()` attribue au modèle dans le catalogue (nom du
fichier ou du dépôt).

`config::from_options(options)` ignore les champs typés : le modèle est configuré
exactement comme par la ligne de commande de `llama-server` (c’est ce que font
les catalogues lus depuis des sources). Sont refusés avec `invalid_config` : une
option inconnue ou à valeur invalide, une option de l’hôte (HTTP, UI, outils,
journalisation, terminal, état global du processus : priorité, NUMA,
enregistrement RPC, actions qui quittent), une option de catalogue (`alias`,
`models-dir`, …) et une option qui répète un champ typé renseigné. La table
`engine/engine-options.cpp` attribue chaque option des registres serveur et CLI ;
`test-engine-options` échoue si une option ajoutée n’y est pas classée, et vérifie
la parité avec `common_params_parse`.

Une ressource distante déjà présente dans le cache (ou avec `offline`) est
locale : elle se charge sans réseau. Sans module d’acquisition, une ressource
absente localement échoue avec `capability_unavailable` ; avec lui, elle est
téléchargée pendant le chargement (progression `stage: "download"`, annulable
comme un chargement), comme un `llama-server -hf`.

Les pièces jointes sont des valeurs possédées (`name`, `bytes`), sans type HTTP.
La completion native conserve son schéma `multimodal_data`. Pour chat, Responses,
Messages, application de template, comptage et embeddings (entrées
`{"content": [...]}`), les URLs de médias peuvent être
`attachment:nom` : le moteur résout ce nom dans les buffers possédés, sans
encodage base64. Les capacités image/audio/vidéo et le décodage des formats sont
validés par les mêmes helpers que les médias JSON historiques. Les noms doivent
être non vides et uniques. Pour `transcription`, fournir une pièce nommée `file`.
Les autres opérations refusent les pièces jointes nommées. Le
profil local sans acquisition refuse les médias réseau. Les limites connues de
vidéo/WebP sans subprocess restent celles du plan ; aucune parité de formats
supplémentaire n’est revendiquée.

## Opérations et événements

`engine::submit(operation, json, attachments)` est l’entrée commune. `completion()`
reste un raccourci pour la completion native. Les schémas existants sont conservés :

| Opération | Entrée / résultat |
| --- | --- |
| `completion`, `completions`, `infill` | Completion native, OpenAI texte, infill ; lots et `n` conservés |
| `chat`, `responses`, `messages` | OpenAI chat, Responses, Anthropic ; tools produits, reasoning, structured output |
| `transcription` | Champs JSON de transcription et pièce `file` ; modèle audio requis |
| `embeddings`, `embeddings_openai`, `rerank` | Formats natif/OpenAI et Jina/TEI ; pooling configuré au chargement |
| `tokenize`, `detokenize`, `apply_template` | Contrats JSON existants sans génération |
| `chat_tokens`, `response_tokens`, `message_tokens` | Comptage selon le format d’entrée correspondant |
| `control` | `id` de completion et `action: "reasoning_end"` |
| `slots` | Instantané des slots ; option booléenne `fail_on_no_slot` |
| `slot_save`, `slot_restore`, `slot_erase` | `id_slot` entier ; `filename` pour save/restore, validé dans le répertoire configuré |
| `lora_list`, `lora_apply` | Liste ; tableau d’objets `id`/`scale` pour modification |
| `properties`, `models` | Instantanés possédés, utilisables pendant sommeil sans réveil |
| `properties_update` | Succès sans mutation, comme le contrat historique POST props |
| `metrics` | Instantané sémantique ; `reset` booléen (défaut true) remet à zéro les buckets, sans réveil |

Pour chat, un payload streamé peut contenir un **tableau ordonné de deltas**.
Responses et Anthropic livrent des tableaux `{event, data}` : `event` est le nom
sémantique, sans préfixes SSE, sentinelle `[DONE]` ni keep-alive dans le moteur.
Lire chaque élément, y compris ceux du dernier payload, avant l’issue terminale.
`result()` assemble les choix OpenAI multiples et les enveloppes embeddings/rerank
selon le contrat d’origine. `next()` reste incrémental ; les familles non génératives
peuvent livrer un résultat par tâche, tandis que `result()` fournit leur enveloppe complète.

Les statistiques exposent `t_start`, des tableaux `counters`/`gauges`
(`name`, `description`, `value`) et `n_accepted_per_pos`. L’adapter HTTP produit
seul le texte Prometheus et le header de date. Le reset pendant sommeil est
répercuté au réveil, sans double comptage. Les propriétés conservent aussi les
champs de compatibilité attendus par le serveur ; la disponibilité des endpoints
et les gardes HTTP restent des décisions du consommateur.

```cpp
auto request = engine->submit(llama_engine::operation::chat, {
    {"messages", {{{"role", "user"}, {"content", "Bonjour"}}}},
    {"max_tokens", 32}, {"stream", false}
});
auto result = request->result();
// En cas de succès, result.data contient l’enveloppe chat avec choices et usage.
```

La reprise après déconnexion reste dans `server-stream.cpp`. Le producteur HTTP
possède la requête moteur jusqu’à la fin du drainage. Remplacement, DELETE/Stop
et déconnexion sans reprise entraînent son annulation ; le replay conserve ses
propres offsets, rétention et contrôle d’accès.

### Contexte : motifs d’arrêt et occupation

Deux champs de requête facultatifs de la completion native, de completions et
de chat servent les consommateurs embarqués (Responses et Messages ne les
exposent pas). Absents, le résultat est inchangé, octet pour octet
côté serveur.

- **`fail_on_context_full: true`** distingue les trois motifs d’arrêt :
  - prompt plus grand que le contexte : erreur `context_exceeded`, données
    natives `type: "exceed_context_size_error"`, `n_prompt_tokens`, `n_ctx`, et
    `context_phase: "prompt"` ;
  - contexte rempli pendant la génération alors que le budget de sortie n’est
    pas atteint : erreur `context_exceeded` après les fragments déjà livrés,
    avec `context_phase: "generation"` et `n_decoded`. Sans ce champ, ce cas
    reste un arrêt `finish_reason: "length"` (`truncated` au format natif) ;
  - budget de sortie atteint (`max_tokens`/`n_predict`) : succès avec
    `finish_reason: "length"`, qui ne désigne alors plus que ce budget.
  Le context shift ne s’applique jamais à une telle requête, même si le modèle
  l’active (`context-shift`).
- **`return_context: true`** ajoute un objet `context` aux fragments streamés
  qui portent des deltas (et à ceux de `prompt_progress`) puis au résultat
  final :
  `n_ctx` (capacité effective du slot qui sert la requête), `n_tokens`
  (occupation : tokens du prompt, images et définitions d’outils compris, plus
  tokens générés ; tokens traités pendant `prompt_progress`), `n_prompt_tokens`,
  `n_cache_tokens` (préfixe réutilisé), `n_decoded` et `n_reasoning_tokens`.
  Chaque objet appartient à la requête qui le lit : deux requêtes intercalées
  ne partagent aucun compteur, contrairement à l’instantané `slots`.
  `n_reasoning_tokens` suit, sur les tokens générés, les balises de
  raisonnement du template (balises comprises), y compris un raisonnement
  ouvert par le prompt de génération ; il vaut 0 sans balises.

La catégorie `context_exceeded` s’applique aussi sans `fail_on_context_full`
au prompt trop long (auparavant `inference_error`, mêmes données natives).

### Sortie structurée : vérification stricte et outils

- **`strict_json_schema: true`** (chat uniquement, facultatif) : un schéma que
  la grammaire ne ferait qu’approcher est une erreur `invalid_request` au lieu
  d’un avertissement. Le contrôle passe par le même convertisseur que la
  grammaire (`json_schema_check_strict`) : aujourd’hui, un `pattern` hors du
  sous-ensemble de regex pris en charge (non ancré, lookaround, `\d`…), qui
  deviendrait sinon une chaîne libre. Il s’applique au `response_format`
  (message préfixé `response_format:`) et aux paramètres de chaque outil
  (`parameters of tool <nom>:`), avec le nom de la règle concernée. Avec outils
  et `response_format` à la fois, un format de chat qui ne sait pas les
  combiner est refusé (« does not support tools combined with a response
  format ») au lieu de remplacer les outils par le schéma. Un format qui écrit
  les arguments chaîne d’un outil en texte brut (format XML Qwen3-Coder /
  Qwen3.5, sans guillemets) signale les contraintes qu’il ne peut pas porter
  (`common_chat_params::unenforced_tool_constraints` : motif, format, longueur,
  valeurs de chaîne mêlées à d’autres types) ; en mode strict, la requête est
  refusée (`parameters of tool <nom>: parameter <p> has pattern …, which the
  chat format of this model does not enforce`). Absent, rien ne change.
- **Arguments chaîne énumérés** (format Qwen3-Coder/Qwen3.5) : un paramètre
  chaîne à `enum` ou `const` est restreint par la grammaire à ses valeurs, en
  texte brut ; auparavant il était généré librement. Avec ou sans mode strict.
- **Outils et `response_format` ensemble** (format Qwen3-Coder/Qwen3.5,
  `supports_tools_with_response_format`) : avec `tool_choice: "auto"`, la
  réponse est soit des appels d’outils, soit le JSON du schéma, sous une
  grammaire non paresseuse ; avec `"required"`, des appels d’outils seulement,
  le schéma s’appliquant à la réponse qui suit leurs résultats. Auparavant,
  `auto` échouait (« failed to parse grammar ») et `required` ignorait les
  outils. Les autres formats gardent leur comportement : le schéma remplace les
  outils.
- Limite connue : le préremplissage de la grammaire par le prompt de
  génération (`common_sampler_init`) écarte un premier token précédé d’un
  espace ; quand les marqueurs du template ne sont pas des tokens spéciaux du
  vocabulaire (fixture stories15M avec chatml), ce token porte aussi un
  caractère du marqueur et l’initialisation échoue (« Failed to initialize
  samplers »). C’est l’échec préexistant de `test-engine-operations`.

## Concurrence, durée de vie et bornes

- `submit()`, `completion()` et `stop()` peuvent être appelés concurremment. La préparation
  (validation, tokenisation, médias) s’exécute sur le thread appelant, en
  parallèle entre appelants comme dans le serveur historique, hors du verrou du
  moteur et protégée contre le sommeil du contexte. `stop()` attend la fin des
  préparations en cours avant de libérer le modèle. Le moteur possède le thread de décodage et le worker
  déjà utilisé par l’ordonnanceur ; aucun thread par requête n’est créé.
- `next()`/`next_for()`/`result()` utilisent un lecteur sérialisé. Utiliser un seul
  lecteur logique par requête ; `cancel()` peut être appelé depuis un autre
  thread. La destruction d’un objet C++ ne doit pas courir avec une méthode sur
  ce même objet.
- Détruire le handle annule le travail inachevé. L’arrêt ferme l’admission,
  réveille les lecteurs, demande la fin de la boucle, attend les threads et
  libère les ressources du modèle. Un calcul backend en cours est coopératif :
  aucun délai strict d’interruption n’est promis.
- Les handles peuvent survivre au moteur. Les payloads déjà acceptés sont
  drainés avant leur issue terminale ; les appels suivants renvoient cette même
  issue immédiatement. L’annulation ne remplace pas un succès/une erreur déjà
  décidé. Un nouveau travail soumis après arrêt est explicitement annulé.
- `max_tasks` (64 par défaut) compte les tâches actives, en attente et en cours
  d’annulation, y compris les enfants de `n`. Les inscriptions de résultats
  servent de réservations jusqu’à la fin ou l’acquittement de l’annulation par
  le décodeur. Une annulation est coalescée par tâche. Les tâches différées ne
  créent pas de nouvelles réservations.
- `max_events` (256) borne la file de **résultats bruts**, avant conversion JSON.
  Le décodeur livre chaque résultat directement à la file de sa requête ; il n’existe
  pas d’autre file de résultats. Un
  dépassement termine la requête avec `queue_full`, annule son travail et
  conserve son issue dans un emplacement séparé de la file. Les autres
  requêtes continuent. `max_request_bytes` (16 MiB) borne le JSON sérialisé et les noms/octets des pièces jointes.
  Ces limites ne constituent pas un budget global de mémoire CPU/GPU.
- Ces valeurs sont les défauts d’un consommateur embarqué. Le serveur HTTP
  applique `detail::apply_http_compat_limits` à son instance : aucune limite
  d’admission, de file ni de taille propre au moteur, comme le serveur upstream.
  Son adapter lit les résultats natifs (`read_native`) et les sérialise une seule
  fois, sans passer par le type JSON public.
- La conversion des résultats et le remplacement des octets UTF-8 invalides
  ont lieu sur le lecteur. Le moteur ne produit pas de SSE. Le serveur garde
  le statut HTTP, l’encodage SSE, les keep-alives et la déconnexion.

La validation de forme de la requête (objet, champs, types) est celle du schéma
de tâche existant ; les messages d’erreur sont ceux du serveur historique.

Catégories d’erreur actuelles : `invalid_config`, `load_failed`, `invalid_request`,
`capacity_exceeded`, `queue_full`, `inference_error`, `context_exceeded`, `preparation_failed`,
`model_not_found`, `model_not_loaded`, `wait_timeout`, `wake_failed`,
`capability_unavailable`, `model_downloading`, `download_failed`. Catégories
d’annulation : `cancelled`, `stopped`, `unloaded`, `evicted`.
Appeler `result()` sur un stream est une erreur de programmation
(`std::logic_error`), pas une deuxième issue terminale.
Les erreurs du décodeur conservent leurs détails JSON natifs. `cancelled` et
`stopped` accompagnent une issue d’annulation. Les erreurs fatales natives des
backends restent soumises aux limites du design.

## Plusieurs modèles dans le processus

`engine::create_catalog(catalog_config, error)` crée un moteur sans rien charger.
Chaque `model_entry` a un identifiant, des alias, des tags informatifs et sa
propre `config` (chargement et bornes par modèle). Les identifiants et alias
doivent être uniques entre eux (`invalid_config` sinon). Un catalogue vide est
valide : des modèles peuvent être ajoutés ensuite. `engine::create(config)`
reste le raccourci mono-modèle : même gestionnaire avec une seule entrée,
chargée avant le retour, et le champ `model` des requêtes n’est pas utilisé.

```cpp
llama_engine::catalog_config catalog;
catalog.max_loaded = 1;                       // chargements en cours inclus ; <= 0 : pas de limite
catalog.models = {{"small", {"s"}, {}, small_config}, {"large", {}, {}, large_config}};
auto engine = llama_engine::engine::create_catalog(catalog, error);
auto events = engine->subscribe();            // premier événement : "snapshot"
auto reply = engine->submit(llama_engine::operation::chat, {
    {"model", "s"}, {"messages", {{{"role", "user"}, {"content", "Bonjour"}}}},
})->result();                                 // charge "small" si nécessaire
engine->unload("small");                      // bloquant : admissions fermées, travaux annulés, ressources libérées
```

- **Sélection** : champ `model` (nom exact, puis alias), comme le routeur.
  Absent : `invalid_request` ; inconnu : `model_not_found` ; `autoload=false`
  et modèle ni chargé ni en chargement : `model_not_loaded`.
- **États** (`catalog()`, événements) : `unloaded`, `loading`, `loaded`,
  `sleeping`, `unloading`, `failed` (+ `error`), `downloading`. Présence au catalogue,
  résidence (`status`), attentes (`waiting`) et requêtes admises (`active`)
  sont distinctes. Un échec de chargement est récupérable : la demande suivante
  relance le chargement.
- **Limite et éviction** : `max_loaded` compte les modèles en chargement,
  chargés, endormis et en cours de déchargement. Seul un modèle sans requête
  admise ni attente peut être évincé, le moins récemment utilisé d’abord. La
  politique (`engine/engine-scheduler.h`) est celle de l’ancien routeur de
  processus ; le mode multi-modèles de `llama-server` est ce moteur.
- **Attente** : une requête pour un modèle non résident est mise en file et le
  handle est rendu immédiatement ; `cancel()`/destruction la retire. Les demandes
  pour un même modèle partagent une entrée et **un seul chargement**. Ordre de
  service : premier arrivé, premier servi par modèle ; seule la tête de file
  démarre un chargement. Bornes : `max_waiting` (`capacity_exceeded`) et
  `wait_timeout` (`wait_timeout`, 5 min par défaut, temps de chargement compris).
  Un modèle maintenu occupé en continu ne provoque donc pas de famine silencieuse :
  l’attente échoue explicitement à l’échéance.
- **Préparation différée** : une requête en attente est préparée par le thread
  de chargement une fois le modèle résident, dans l’ordre d’arrivée. Un
  `request` peut donc être lu avant sa préparation ; `stream` reflète la
  demande dès la soumission.
- **Chargement explicite** : `load(model)` suit la même file et renvoie un
  `request` qui réussit quand le modèle est résident. L’annuler retire
  l’attente, sans interrompre un chargement déjà démarré.
- **Déchargement explicite** : `unload(model)` ferme les admissions (les
  nouvelles requêtes attendent l’instance suivante), termine les attentes et les
  requêtes en cours avec `cancelled`/`unloaded`, attend l’arrêt du décodeur puis
  libère le modèle. Pendant un chargement, celui-ci est interrompu à son prochain
  rapport de progression. Modèle non résident : `model_not_loaded`.
- **Sommeil** : `sleep_idle_seconds` par modèle. Un modèle endormi reste compté
  et reçoit directement les requêtes, qui le réveillent. Un réveil qui échoue
  (fichier absent, allocation) termine la requête avec `wake_failed` ; le modèle
  reste endormi et le réveil est retenté à la requête suivante. Propriétés,
  modèles et statistiques restent lisibles sans réveil.
- **Métadonnées** : tant qu’un modèle est résident, son entrée de `catalog()`
  porte `info` (identifiant, alias, métadonnées GGUF, comme `/v1/models`), aussi
  présent dans l’événement `status` qui annonce `loaded`. `input_modalities`
  (`text`, puis `image`/`audio`) est renseigné par `read_catalog` quand le
  projecteur du modèle est trouvé localement, sans réseau.
- **Abonnements** : `subscribe()` fournit un instantané `snapshot`, puis des
  événements `status` (`model`, `status`, `waiting`, `error`, `info`) et `progress`
  (`stages`, `current`, `value`, au plus toutes les 200 ms). Au-delà de
  `max_subscriber_events` non lus, les événements en file sont remplacés par
  un seul `resync` contenant le catalogue courant. `stop()` termine l’abonnement
  (`cancelled`/`stopped`) ; le détruire n’affecte aucun modèle.
- **Arrêt** : `stop()` ferme les admissions, termine les attentes, interrompt
  les chargements, arrête chaque modèle puis joint tous les threads (chargement,
  entretien, décodeurs). Aucun sous-processus ni port n’est utilisé.

Threads possédés par un moteur multi-modèles : un thread d’entretien (délais,
déchargements, jointures), un thread de chargement par chargement en cours
(borné par `max_loaded`), et pour chaque modèle résident son décodeur et son
worker. Aucun thread par requête.

## Sources du catalogue, rechargement et acquisition

`read_catalog(catalog_sources, models)` lit uniquement les sources demandées :
cache Hugging Face (`cache = true`, chemin de `LLAMA_CACHE`/`HF_HUB_CACHE`/…),
répertoire (`models_dir`, un GGUF ou un sous-répertoire par modèle, projecteur
et brouillon détectés), fichier INI (`presets`, section `*` commune) et
`options` appliquées à tous les modèles. Règles de `llama-server` : un modèle du
répertoire remplace l’entrée du cache de même nom, la section INI de ce nom y
est fusionnée, `defaults` puis la section `*` s’appliquent en dessous et
`options` au-dessus de chaque modèle (`llama-server` y place respectivement son
environnement `LLAMA_ARG_*`/fichiers `config.ini` et sa ligne de commande) ; `dedup-cache-models` masque (`hidden`) l’entrée du cache déjà
fournie par un preset. Lecture seule : ni réseau ni écriture ; le cache absent
n’est pas créé. Chaque entrée reçoit `source`, `load_on_startup`,
`host_options` (options de l’hôte propres au modèle : `stop-timeout`, HTTP…) et
sa `config` (`config::from_options`). Une valeur invalide (`ctx-size = abc`)
laisse l’entrée listée avec `error` : son chargement échoue avec
`invalid_config`, comme un enfant du routeur. Une clé inconnue ou un alias en
conflit fait échouer la lecture ; `skip_conflicting_aliases` ignore l’alias avec
un avertissement, comme un rechargement du routeur.

```cpp
llama_engine::catalog_config catalog;
catalog.sources = llama_engine::catalog_sources{};
catalog.sources->cache      = true;
catalog.sources->models_dir = "/models";
catalog.sources->presets    = "/etc/models.ini";
catalog.sources->options    = {{"n-gpu-layers", "99"}};
auto engine = llama_engine::engine::create_catalog(catalog, error);
engine->reload();                               // relit les sources
auto download = engine->download("ggml-org/model:Q4_K_M"); // réseau optionnel
download->result();                             // success, download_failed ou cancelled
engine->remove("ggml-org/model:Q4_K_M");        // cache uniquement
```

- **`update_catalog(models)`** remplace les entrées (moteurs de catalogue
  uniquement). Entrée retirée : attentes terminées avec `model_not_found`,
  requêtes en cours avec `unloaded`, ressources libérées puis entrée effacée.
  Configuration modifiée : instance résidente ou en chargement libérée, ses
  requêtes en cours terminées (`unloaded`) ; les **attentes sont conservées** et
  chargent la nouvelle configuration. Alias/tags seuls : aucun déchargement.
  Liste invalide : catalogue inchangé. Les abonnés reçoivent `reload` avec le
  catalogue courant.
- **`reload()`** relit `catalog_config::sources` (alias en conflit ignorés) et
  applique le résultat avec `update_catalog`, en conservant les entrées données
  explicitement dans `catalog_config::models`.
- **`download(repo, options)`** : mêmes règles de sélection que `hf-repo`
  (modèle, projecteur, fichiers de brouillon) ; `options` accepte par exemple
  `hf-token`. Les métadonnées du dépôt sont demandées avant le retour, comme la
  validation de `POST /models`. Pendant le téléchargement, l’entrée `downloading`
  refuse les requêtes (`model_downloading`) et publie `progress` (`stage`,
  `url`, `downloaded`, `total`) ; un second téléchargement du même nom est
  refusé. À la fin, l’entrée provisoire disparaît et, avec des sources, le
  catalogue est relu **avant** la publication de l’événement `download`
  (`finished`, `failed`, `cancelled`) : un abonné qui y réagit trouve déjà le
  modèle sous son nom de cache (`dépôt:quantification`). Annuler la requête, `unload()` sur l’entrée ou
  `stop()` interrompt le téléchargement et supprime le fichier incomplet. Sans
  module d’acquisition : `capability_unavailable`.
- **`remove(model)`** : uniquement pour une entrée de source `cache` (sinon
  `invalid_request`) ; annule son téléchargement ou la décharge, supprime ses
  fichiers du cache (au mieux, comme le routeur) et l’entrée, puis publie
  `remove`. Fonctionne sans module d’acquisition.

Téléchargements et chargements partagent l’annulation coopérative : aucun
sous-processus. Un thread par téléchargement en cours, joint par l’entretien.

## Ressources globales

L’initialisation des backends est partagée par `std::call_once` entre moteurs et
serveur. Registres/tables globaux restent à durée de vie processus ; détruire un
moteur ne les libère pas sous un autre. Ne pas appeler `llama_backend_free()`
manuellement pendant qu’un moteur ou un autre consommateur de llama fonctionne.
Le moteur ne configure ni signaux, ni priorité processus, ni NUMA global, ni
callback global de logging : les options correspondantes sont de portée `host`
et restent aux exécutables.

## Interface interne (serveur et tests)

`llama-engine-internal` (cible CMake `INTERFACE`, non installée) donne accès aux
headers privés de `engine/`. Elle sert uniquement :

- à l’adapter HTTP de `llama-server`, qui lit les résultats natifs
  (`detail::request_state::read_native`) pour les sérialiser octet pour octet
  comme avant le moteur, applique `detail::apply_http_compat_limits` et pilote
  le catalogue par `detail::model_manager` (routes `/models`, SSE, sélection par
  requête) ;
- aux tests des courses et politiques internes (`test-engine-lifecycle`,
  `test-engine-models`, `test-engine-events`, `test-engine-options`,
  `test-engine-transport`, `test-engine-replay`, `test-chat`).

Ce n’est pas une seconde interface : chaque opération n’a qu’une
implémentation, que l’API publique et le serveur appellent. Les types privés
gardent les noms `server_*` hérités de `llama-server` (`server_context` pour la
boucle d’un modèle dans `engine/engine-context.*`, `server_task`, `server_queue`,
…) pour que les évolutions amont du serveur continuent de s’y appliquer. La
boucle d’un modèle tourne sur un thread possédé par le moteur (`start()`,
`join()`, `terminate()`) ; aucun appelant ne fournit de boucle de décodage.
