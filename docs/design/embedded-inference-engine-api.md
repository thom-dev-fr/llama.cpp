# API C++ du moteur — tranche P2

L’interface expérimentale est `include/llama-engine.h`, dans le namespace
`llama_engine`. Lier `llama-engine` suffit dans le graphe CMake du dépôt ; le
header public utilise le `nlohmann::json` fourni par la cible `vendor::nlohmann`.
Aucune stabilité ABI ni installation autonome complète n’est promise à P2.
Le consommateur compilé et testé est `tests/test-engine.cpp`.

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
est fusionné avec le JSON de chaque requête, qui a priorité. La validation,
les alias de paramètres et l’ordonnanceur sont ceux du chemin natif existant.

La configuration de chargement publique sera étendue en P5 selon la matrice P0.
L’adapter privé serveur conserve **tous** ses `common_params` actuels ; cette
tranche ne prétend pas encore exposer tous les réglages de chargement via l’API
publique. Le chat, les embeddings, les autres formats, les contrôles et les
snapshots publics arrivent en P3. Le multi-modèles/catalogue arrive en P4/P5.

Les pièces jointes sont des valeurs possédées (`name`, `bytes`), sans type HTTP.
La completion native utilise son schéma existant `multimodal_data` ; elle refuse
explicitement les pièces jointes nommées, prévues pour les opérations P3. Le
profil local sans acquisition refuse les médias réseau. Les limites connues de
vidéo/WebP sans subprocess restent celles du plan ; aucune parité de formats
supplémentaire n’est revendiquée.

## Concurrence, durée de vie et bornes

- `completion()` et `stop()` peuvent être appelés concurremment. La préparation
  est sérialisée par moteur, exécutée sur le thread appelant et protégée contre
  le sommeil du contexte. Le moteur possède le thread de décodage et le worker
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
  Le chemin natif ne traverse pas la file de résultats legacy non bornée. Un
  dépassement termine la requête avec `queue_full`, annule son travail et
  conserve son issue dans un emplacement séparé de la file. Les autres
  requêtes continuent. `max_request_bytes` (16 MiB) borne l’entrée sérialisée.
  Ces limites ne constituent pas un budget global de mémoire CPU/GPU.
- La conversion des résultats et le remplacement des octets UTF-8 invalides
  ont lieu sur le lecteur. Le moteur ne produit pas de SSE. Le serveur garde
  le statut HTTP, l’encodage SSE, les keep-alives et la déconnexion.

Catégories d’erreur actuelles : `invalid_config`, `load_failed`, `invalid_request`,
`capacity_exceeded`, `queue_full`, `inference_error`.
Appeler `result()` sur un stream est une erreur de programmation
(`std::logic_error`), pas une deuxième issue terminale.
Les erreurs du décodeur conservent leurs détails JSON natifs. `cancelled` et
`stopped` accompagnent une issue d’annulation. Les erreurs fatales natives des
backends restent soumises aux limites du design.

## Ressources globales et transition

L’initialisation des backends est partagée par `std::call_once` entre moteurs et
serveur. Registres/tables globaux restent à durée de vie processus ; détruire un
moteur ne les libère pas sous un autre. Ne pas appeler `llama_backend_free()`
manuellement pendant qu’un moteur ou un autre consommateur de llama fonctionne.
Le moteur ne configure ni signaux, ni priorité processus, ni NUMA global, ni
callback global de logging. Le serveur conserve ses choix explicites d’hôte.

`engine/engine-context.*` possède l’unique boucle extraite. Son nom interne
historique `server_context`, ses accesseurs et son `start_loop()` de compatibilité
servent encore les opérations non migrées ; ce dernier démarre/attend le thread
possédé, il n’exécute plus le décodeur sur le thread appelant. Ces façades, la file
legacy et les conversions restantes sont à migrer en P3 puis nettoyer en P8.
