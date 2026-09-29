# API C++ du moteur — mono-modèle P3, multi-modèles P4

L’interface expérimentale est `include/llama-engine.h`, dans le namespace
`llama_engine`. Lier `llama-engine` suffit dans le graphe CMake du dépôt ; le
header public utilise `nlohmann::ordered_json` (alias `llama_engine::json`), fourni par
la cible `vendor::nlohmann`, afin de conserver l’ordre natif des champs.
Aucune stabilité ABI ni installation autonome complète n’est promise pendant cette extraction.
Les consommateurs compilés sont `tests/test-engine.cpp`, `test-engine-operations.cpp` et `test-engine-fixtures.cpp`.

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

## Configuration et capacités de cette tranche

Un moteur charge synchronement un GGUF local. `create()` retourne `nullptr` et
une erreur explicite si la configuration ou le chargement échoue. CPU est le
profil par défaut ; `gpu_layers` est configurable. Le contexte, les slots,
threads et tailles de batch ont des champs explicites. `generation_defaults`
est fusionné avec le JSON des requêtes de génération, qui a priorité. La validation,
les alias de paramètres et l’ordonnanceur sont ceux du chemin natif existant.

La configuration de chargement publique sera étendue en P5 selon la matrice P0.
L’adapter privé serveur conserve **tous** ses `common_params` actuels ; cette
tranche ne prétend pas encore exposer tous les réglages de chargement via l’API
publique. P3 ajoute `chat_template` (nom ou source Jinja), `mmproj_path`,
`embeddings`, `pooling_type` (-1 défaut modèle, 0 none, 1 mean, 2 CLS, 3 last,
4 rank), `slot_save_path` et `lora_paths`. Un chemin de slots vide interdit les
écritures ; un chemin non vide reçoit automatiquement son séparateur final.
Les adapters LoRA configurés sont chargés à l’échelle 1, modifiable par requête.
Le multi-modèles est décrit plus bas (P4) ; les sources de catalogue
(presets, répertoires, cache) et l’acquisition arrivent en P5.

Les pièces jointes sont des valeurs possédées (`name`, `bytes`), sans type HTTP.
La completion native conserve son schéma `multimodal_data`. Pour chat, Responses,
Messages, application de template et comptage, les URLs de médias peuvent être
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
  Aucune opération publique ne traverse la file de résultats legacy non bornée. Un
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
`capacity_exceeded`, `queue_full`, `inference_error`, `preparation_failed`,
`model_not_found`, `model_not_loaded`, `wait_timeout`, `wake_failed`. Catégories
d’annulation : `cancelled`, `stopped`, `unloaded`, `evicted`.
Appeler `result()` sur un stream est une erreur de programmation
(`std::logic_error`), pas une deuxième issue terminale.
Les erreurs du décodeur conservent leurs détails JSON natifs. `cancelled` et
`stopped` accompagnent une issue d’annulation. Les erreurs fatales natives des
backends restent soumises aux limites du design.

## Plusieurs modèles dans le processus (P4)

`engine::create_catalog(catalog_config, error)` crée un moteur sans rien charger.
Chaque `model_entry` a un identifiant, des alias, des tags informatifs et sa
propre `config` (chargement et bornes par modèle). Les identifiants et alias
doivent être uniques entre eux (`invalid_config` sinon). `engine::create(config)`
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
  `sleeping`, `unloading`, `failed` (+ `error`). Présence au catalogue,
  résidence (`status`), attentes (`waiting`) et requêtes admises (`active`)
  sont distinctes. Un échec de chargement est récupérable : la demande suivante
  relance le chargement.
- **Limite et éviction** : `max_loaded` compte les modèles en chargement,
  chargés, endormis et en cours de déchargement. Seul un modèle sans requête
  admise ni attente peut être évincé, le moins récemment utilisé d’abord. La
  politique (`engine/engine-scheduler.h`) est celle du routeur, partagée avec lui
  jusqu’à P6.
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
- **Abonnements** : `subscribe()` fournit un instantané `snapshot`, puis des
  événements `status` (`model`, `status`, `waiting`, `error`) et `progress`
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

## Ressources globales et transition

L’initialisation des backends est partagée par `std::call_once` entre moteurs et
serveur. Registres/tables globaux restent à durée de vie processus ; détruire un
moteur ne les libère pas sous un autre. Ne pas appeler `llama_backend_free()`
manuellement pendant qu’un moteur ou un autre consommateur de llama fonctionne.
Le moteur ne configure ni signaux, ni priorité processus, ni NUMA global, ni
callback global de logging. Le serveur conserve ses choix explicites d’hôte.

`engine/engine-context.*` possède l’unique boucle extraite. Son nom interne
historique `server_context`, ses accesseurs et son `start_loop()` de compatibilité
servent encore l’initialisation serveur et les consommateurs legacy ; ce dernier
démarre/attend le thread possédé, sans décoder sur le thread appelant. Aucun handler
mono-modèle n’utilise le lecteur legacy. Ces façades restent à nettoyer en P8 après
les bascules routeur et CLI (P6/P7).
