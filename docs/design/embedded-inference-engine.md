# Moteur d’inférence embarquable — synthèse du design

Statut : arbitrages validés pendant l’entretien ; implémentés par le plan (P0–P8) et qualifiés à P9 ([rapport final](embedded-inference-engine-report.md), dont les points encore ouverts). Les noms et signatures illustratifs ci-dessous ont précédé le header ; l’interface retenue est décrite dans le [guide API](embedded-inference-engine-api.md).

Correspondance avec le code :

| Élément du design | Réalisation |
| --- | --- |
| Interface publique | `include/llama-engine.h`, cible CMake `llama-engine` (namespace `llama_engine`) ; exemple compilé `examples/engine-simple` |
| Moteur (décodeur, opérations JSON, catalogue, cycle de vie) | `engine/` : `llama-engine.cpp`, `engine-context.*` (boucle d’un modèle), `engine-operations.*`, `engine-models.*` et `engine-scheduler.h` (multi-modèles), `engine-catalog.*` (sources), `engine-options.*` (configuration), `server-{task,queue,chat,schema,common}.*` (types hérités du serveur) |
| Interface privée des consommateurs internes | cible `llama-engine-internal`, non installée (adapter HTTP du serveur, tests internes) |
| Utilitaires locaux / acquisition réseau optionnelle | `llama-common-local`, `llama-common-options` / `llama-common-acquisition` (`LLAMA_BUILD_COMMON_ACQUISITION`) |
| Consommateur serveur (HTTP, SSE, reprise, outils, MCP, UI) | `tools/server/` : `server-context.*` (routes), `server-models.*` (mode multi-modèles), `server-stream.*`, `server-tools.*`, `server-mcp.*` |
| Consommateur CLI | `tools/cli/cli-engine.*` (local, API publique), `cli-client.*` (`--server-base`, HTTP) |

Références : [vocabulaire](../../CONTEXT.md), [décision architecturale](../adr/0001-embedded-inference-engine.md).

Pour implémenter ou reprendre une étape de migration, lire le [plan progressif et ses critères de validation](embedded-inference-engine-plan.md).

## But et périmètre

Extraire un moteur C++ commun dont `server` et `cli` deviennent les consommateurs. L’inférence locale et le multi-modèles ne nécessitent ni HTTP ni sous-processus. Ce drop migre effectivement les deux exécutables ; l’exposition à Swift/iOS est une cible ultérieure, sans binding à livrer maintenant ni promesse de stabilité ABI.

La couverture est celle nécessaire à cette migration complète, pas une sélection limitée au chat. Les opérations existantes de chat, Responses, Anthropic Messages, completions natives/OpenAI, infill, transcription, embeddings, rerank, tokenisation, templates, contrôle de génération, slots et LoRA restent accessibles. Les capacités multimodales, de production d’appels d’outils et de sortie structurée sont conservées.

La compatibilité concerne les contrats et comportements publics, pas une génération bit-à-bit identique. Les écarts inévitables liés à la disparition des processus doivent être documentés.

## Répartition des responsabilités

| Moteur | Consommateurs et modules extérieurs |
| --- | --- |
| Validation et conversion des requêtes d’inférence ; contrats JSON des formats existants | Chemins HTTP, authentification, CORS, codes de statut et encodages réseau |
| Inférence, ordonnancement, slots, caches KV et optimisations existantes | Historique conversationnel et orchestration des tours |
| Production des appels d’outils | Exécution des outils et MCP |
| Catalogue, sélection et cycle de vie des modèles | UI et interactions terminal |
| Résultats et événements d’inférence indépendants du transport | SSE, reprise par offset et rétention des octets SSE |
| États, progression et statistiques | Rendu SSE des événements de modèles et rendu Prometheus |

Le CLI local appelle le moteur directement ; son mode client d’un serveur distant est conservé.

## Interface d’inférence

- Opérations nommées, sans chemins HTTP.
- Entrées et données de sortie en `nlohmann::json`, selon les schémas existants. Pas de seconde représentation entièrement typée des messages pour ce drop.
- Pièces jointes binaires nommées en complément du JSON, indépendantes du multipart HTTP. Leur durée de vie est garantie jusqu’à leur consommation ; aucun encodage base64 imposé pour ces entrées.
- Objet requête permettant une lecture bloquante du prochain événement et une annulation explicite.
- Résultat complet disponible pour les demandes sans streaming.
- Succès, erreur et annulation distingués ; une requête ne possède qu’une issue terminale.
- Erreurs opérationnelles sous forme de résultats explicites : catégorie stable, message et détails JSON. Les consommateurs réalisent la traduction vers leurs formats publics.

Exemple conceptuel, moteur déjà configuré :

```cpp
// Noms indicatifs, pas un exemple compilable avant définition du header.
auto request = engine.chat_completions({
    {"model", "assistant"},
    {"messages", {{{"role", "user"}, {"content", "Bonjour"}}}},
    {"stream", true},
});

for (;;) {
    auto event = request.next(); // bloque jusqu’au prochain événement
    if (event.is_terminal()) {
        handle_terminal(event); // succès, erreur ou annulation
        break;
    }
    consume_json(event.payload()); // aucun SSE à décoder
}
```

Les structures auxiliaires de l’interface, noms exacts et conventions de passage des valeurs seront fixés dans le header pendant l’implémentation, sans modifier les responsabilités et garanties décidées ici.

## Exécution, durée de vie et saturation

Le moteur possède ses threads et accepte plusieurs requêtes concurrentes. Plusieurs instances indépendantes peuvent coexister, tout en partageant naturellement les ressources matérielles ; un arrêt d’instance ne doit pas invalider les autres.

Détruire une requête demande son annulation. Arrêter le moteur annule ses travaux, réveille les lecteurs bloqués et attend ses threads. L’annulation est coopérative et ne promet pas d’interrompre instantanément un calcul GPU ou de terminer un chargement dans un délai strict.

Les files d’événements sont bornées par requête. La saturation termine la requête concernée en erreur, sans perte silencieuse de fragments ni blocage des autres générations. L’issue terminale doit rester observable, y compris lorsque la file est saturée.

Ces bornes sont des limites **configurables par instance**, bornées par défaut pour un consommateur embarqué. Le serveur HTTP configure son instance avec la sémantique upstream : admissions mises en file sans limite, résultats bufferisés sans limite et taille des corps gouvernée par HTTP. La ré-architecture ne doit introduire aucune régression observable côté HTTP ; toute nouvelle borne serveur serait une évolution de comportement distincte, hors de ce drop.

La reprise après déconnexion appartient au serveur : il garde la requête vivante, la draine et conserve les octets SSE selon le contrat existant. Le moteur ne possède pas de registre de conversations pour cette reprise.

## Modèles et ressources

- Catalogue fourni par modèles ou sources explicitement configurés ; aucune découverte implicite de la machine.
- Lecture des presets, répertoires et caches partagée entre consommateurs.
- Écritures persistantes uniquement par opération explicite.
- Sélection par identifiant, avec conservation des contrats existants de résolution des modèles.
- Auto-chargement et éviction selon la politique configurée.
- Éviction des modèles inactifs les moins récemment utilisés ; jamais d’éviction automatique d’un modèle utilisé.
- Si aucun modèle n’est éligible, attente bornée, annulable, avec délai maximal configurable.
- Déchargement explicite : fermeture des admissions pour ce modèle, annulation de ses travaux, puis libération des ressources.
- Limites par moteur : modèles résidents, requêtes admises/en attente, files d’événements et délais. Les chargements en cours comptent dans la limite de modèles.
- Pas de garantie de budget mémoire CPU/GPU exact ni d’arbitrage global entre instances. Un échec d’allocation reste possible et doit être explicite lorsqu’il est récupérable.
- Instantané du catalogue et abonnement indépendant aux changements d’état/progression. Se désabonner ne décharge pas les modèles.

## Configuration et dépendances

La configuration publique est propre au moteur et limitée à l’inférence, au catalogue et aux ressources. `server` et `cli` traduisent leurs options actuelles ; `common_params` peut rester un détail interne mais n’est pas imposé par le header public.

Un module réseau optionnel partagé assure l’acquisition des modèles et autres ressources distantes. Le socle local reste compilable sans HTTP et accepte des fichiers locaux ou des données en mémoire.

La séparation devra toucher les dépendances transitives : `common/CMakeLists.txt` lie actuellement `llama-common` à `cpp-httplib`. Déplacer seulement les fichiers du serveur ne suffit donc pas.

Le futur pont Swift adaptera JSON, données binaires, événements et erreurs sans imposer les types C++ directement à ses appelants. Sa réalisation et sa forme exacte sont hors de ce drop.

## Limites de compatibilité et de robustesse

L’exécution dans le même processus abandonne l’isolation des pannes natives, la terminaison forcée des enfants et les véritables codes de sortie. Le serveur adaptera et documentera les champs historiques correspondants, sans simuler un système de processus dans le moteur.

Les erreurs de chargement et de réveil récupérables doivent être remontées explicitement, plutôt que provoquer volontairement la terminaison de l’hôte. Cela ne constitue pas une garantie de récupération face aux assertions internes, erreurs fatales de backends ou corruptions mémoire.

Les signaux et mécanismes d’arrêt des exécutables ne doivent pas être imposés à l’application qui embarque le moteur. Les états globaux existants et l’initialisation/libération des backends devront être audités pour respecter la coexistence des instances.

## Critères de fin du drop

1. Toutes les opérations d’inférence et de gestion des modèles du serveur passent par le moteur.
2. Le CLI local ne démarre plus de serveur ni n’ouvre de port ; le mode distant reste fonctionnel.
3. Le multi-modèles local ne lance plus de sous-processus.
4. HTTP, UI, MCP et exécution d’outils restent hors du moteur.
5. Les tests existants du serveur restent applicables, avec adaptation explicite des seules différences de contrat approuvées.
6. Des tests directs exercent la même interface que les consommateurs : streaming et résultat complet, formats de requête, outils et sorties structurées, pièces jointes, annulation, arrêt, erreurs et saturation.
7. Des tests vérifient le chargement concurrent, les limites, l’attente, l’éviction des seuls modèles inactifs, le déchargement explicite, les événements de modèles et la coexistence d’instances.
8. Le socle local compile sans HTTP ni sous-processus requis ; les consommateurs réseau restent construisibles séparément.
9. Il ne subsiste pas de seconde implémentation durable des mêmes traitements derrière les anciens chemins.

La migration peut être progressive, mais un wrapper autour du serveur existant ou une bibliothèque parallèle non consommée par les exécutables ne satisfait pas ces critères.
