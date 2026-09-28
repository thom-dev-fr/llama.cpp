# Plan d’implémentation — moteur d’inférence embarquable

## Mission et références

Implémenter progressivement le design validé, jusqu’à faire de `server` et du CLI local des consommateurs du même moteur. Une bibliothèque parallèle ou un wrapper appelant le serveur existant ne termine pas cette mission. Le binding Swift/iOS est une étape ultérieure.

Avant de modifier le code, lire :

1. [CONTEXT.md](../../CONTEXT.md) pour le vocabulaire ;
2. [le design](embedded-inference-engine.md) pour le contrat et le périmètre ;
3. [l’ADR](../adr/0001-embedded-inference-engine.md) pour les arbitrages ;
4. [CONTRIBUTING.md](../../CONTRIBUTING.md) pour les conventions ;
5. [README-dev du serveur](../../tools/server/README-dev.md) et [ses tests](../../tools/server/tests/README.md) pour l’existant.

Le design et l’ADR font autorité sur la nouvelle architecture. Le README-dev actuel demande de garder JSON/templates dans la couche HTTP : cette règle est remplacée par leur extraction dans le moteur, **sans déplacer ces traitements lourds dans la boucle de décodage**. Mettre cette documentation à jour lors de la migration.

Plan établi sur `e4c142c5765abf9e5e2285b4b7379e4e84edacea`. Recontrôler les points d’entrée si la branche a évolué. Les chemins proposés pour les nouveaux fichiers ne sont pas des fichiers déjà présents.

## Mode d’exécution

- Exécuter P0 → P9. Chaque étape produit un changement compilable, ses tests et un compte rendu ; elle peut être divisée en plusieurs petits lots. Préserver les modifications étrangères au travail.
- Extraire et réutiliser les algorithmes existants. Séparer les déplacements mécaniques des changements de comportement ; conserver batching, sampling, spéculation et réutilisation du cache.
- Pendant la transition, des façades de compatibilité peuvent déléguer à l’implémentation extraite. Attribuer à chacune une étape de suppression ; ne pas copier une deuxième implémentation.
- Un critère non vérifié reste ouvert. Distinguer `PASS`, `FAIL` et `BLOCKED` ; un modèle absent, un backend indisponible ou un test sauté n’est pas une validation.
- Si un contrat validé devient impossible à respecter, documenter le cas concret et demander un arbitrage plutôt que réduire silencieusement la couverture.

Créer à P0 un journal `docs/design/embedded-inference-engine-progress.md` contenant : étape courante, couverture, commandes réellement exécutées, résultats, écarts, façades temporaires et prochaine action. Le reprendre à chaque passage de relais.

## Organisation cible proposée

- `include/llama-engine.h` : interface C++ publique limitée, JSON, configuration, requêtes, résultats, pièces jointes et observation des modèles.
- `engine/` : implémentation privée et cible CMake `llama-engine`, indépendante des exécutables.
- Acquisition réseau dans une cible optionnelle distincte ; utilitaires locaux partagés dans les cibles appropriées de `common/`.
- `tools/server/` : adaptation HTTP, SSE/reprise, outils exécutés, MCP et intégration UI.
- `tools/cli/` : interface terminal, consommation locale du moteur et client HTTP distant.
- `tests/` : tests directs du moteur ; `tools/server/tests/` : tests du contrat HTTP.

Les noms peuvent être adaptés aux conventions du dépôt en l’indiquant dans le journal. Le graphe de dépendances, lui, doit rester orienté des consommateurs vers le moteur. Ne pas introduire de dépendance `mtmd → llama-common` : `tools/mtmd/CMakeLists.txt` l’interdit explicitement.

## P0 — Établir la couverture et la référence

**Travail**

- Inventorier les routes enregistrées dans `tools/server/server.cpp`, leurs handlers dans `server-context.cpp` et `server-models.cpp`, et les usages du CLI dans `cli-context.cpp`.
- Construire dans le journal une matrice : opération/alias, comportement actuel, emplacement cible, paramètres/configuration requis, test existant ou à ajouter, état de migration. Inclure opérations non génératives, chargement, sommeil/réveil, téléchargement, suppression du cache, statistiques et reprise des flux.
- Inventorier les options de `common_params` effectivement lues par ces chemins : defaults, overrides par modèle et par requête, presets, paramètres mutables. Chaque option conservée doit avoir une traduction explicite ; une configuration publique réduite ne doit pas perdre de capacités.
- Relever les dépendances HTTP, UI, subprocess et les états globaux : `server.cpp`, `server-stream.cpp`, initialisation/libération des backends, logging, callbacks, signaux et statiques mutables.
- Exécuter une référence de build/tests ; noter modèles, backend, paramètres et performances de quelques scénarios mono/concurrents. Réutiliser les fixtures existantes et séparer tests sans modèle, petit GGUF local et tests lourds.

**Vigilance découverte pendant la préparation**

`tools/mtmd/mtmd-helper.cpp` utilise ffmpeg/ffprobe pour la vidéo et certains WebP ; `MTMD_VIDEO` est désactivé sans subprocess. Traiter séparément inférence et prétraitement multimédia optionnel : conserver la couverture desktop existante sans rendre ce prétraitement externe obligatoire pour le socle. Inscrire les capacités de chaque profil dans la matrice. Si la prise en charge d’un format dans le profil sans processus impose un nouveau décodeur ou un nouveau contrat d’entrée, soumettre cet arbitrage ; ne pas annoncer une parité multimodale totale obtenue par simple désactivation de `MTMD_VIDEO`.

**Sortie** : chaque route et chaque capacité du CLI a une destination ; référence reproductible et lacunes de test connues. La vidéo/WebP et les champs historiques liés aux processus sont explicitement suivis.

## P1 — Rendre le graphe de build compatible avec un moteur local

**Fichiers de départ** : `CMakeLists.txt`, `common/CMakeLists.txt`, `vendor/CMakeLists.txt`, `tools/CMakeLists.txt`, `tools/server/CMakeLists.txt`, `tools/mtmd/CMakeLists.txt`, `tests/CMakeLists.txt`.

**Travail**

- Séparer les utilitaires locaux nécessaires à l’inférence des dépendances acquisition HTTP, arguments d’exécutables et subprocess. Auditer aussi les appels de `common_init_from_params`, la résolution de modèles, presets et caches ; une séparation de liste de sources sans séparation des références de symboles ne suffit pas.
- Conserver si nécessaire une cible agrégée de compatibilité pour les autres outils ; ceux-ci ne font pas l’objet d’une réécriture.
- Ajouter la cible moteur hors du conditionnement de `LLAMA_BUILD_SERVER` et des exécutables. Rendre `mtmd` accessible une seule fois, y compris dans un build bibliothèque seule.
- Ajouter les options CMake réellement nécessaires pour sélectionner moteur local et acquisition réseau. Enregistrer leurs noms et commandes exactes dans le journal ; ne pas supposer que ces options existent déjà.
- Vérifier les dépendances de tests : `test-chat` lie actuellement `server-context`, et les helpers de tests lient `llama-common`. Adapter la sélection des tests au profil local au lieu de réintroduire HTTP par les tests.

**Validation**

- Build habituel serveur/CLI encore fonctionnel.
- Petit consommateur compilé et lié uniquement aux dépendances locales extraites, en statique et en partagé là où disponibles.
- Profil local sans HTTP, UI, OpenSSL requis ni subprocess ; vérification des sources compilées, includes et dépendances transitives. `LLAMA_OPENSSL=OFF` seul ne prouve pas l’absence d’HTTP.

**Sortie** : graphe préparé, consommateurs existants non cassés, commandes reproductibles pour les deux profils. Le test réel d’inférence locale arrive à P2.

## P2 — Extraire une tranche verticale mono-modèle réelle

**Fichiers de départ** : `server-context.{h,cpp}`, `server-queue.{h,cpp}`, `server-task.{h,cpp}`, `server-common.{h,cpp}`.

**Travail**

- Définir le header public et les contrats de durée de vie : création/configuration du moteur, objet requête, lecture, annulation, résultat non streamé, erreurs et arrêt. Documenter qui peut appeler quoi concurremment, le comportement après terminaison et les handles survivant à l’arrêt du moteur.
- Garder `common_params`, `server_task`, les queues et pointeurs de contexte hors de l’interface publique. Prévoir JSON et pièces jointes possédées ou retenues jusqu’à consommation.
- Extraire la boucle mono-modèle sans réécrire son ordonnanceur. Le moteur possède ses threads ; le programme appelant ne fournit pas de boucle `start_loop()`.
- Migrer une opération de completion existante de bout en bout : JSON → validation → tâche → décodage → événements/résultat. Faire déléguer le handler HTTP correspondant au moteur dès cette étape.
- Séparer préparation/conversion des requêtes, décodage et adaptation réseau. Éviter de créer un thread non borné par requête ou de formatter les protocoles dans le thread de décodage.
- Implémenter issues terminales exclusives et files bornées. Borner aussi les files intermédiaires utilisées par le nouveau chemin, pas seulement son dernier buffer public. Réserver un moyen d’observer l’erreur terminale après saturation.
- Centraliser correctement les besoins d’initialisation des backends ; la destruction d’un moteur ne doit pas libérer les ressources globales nécessaires à un autre. Auditer les usages existants plutôt que simplement ajouter `llama_backend_free()` à chaque destructeur.

**Validation**

- Inférence directe CPU sur un petit GGUF local, complète et streamée, sans serveur ni port.
- Requête invalide, modèle introuvable/chargement échoué, abandon de requête, annulation pendant attente/génération, arrêt avec lecteur bloqué, création/destruction répétée.
- Course fin/annulation/arrêt : une seule issue terminale, aucune attente infinie ni accès après libération.
- Lecteur saturé : erreur observable ; seconde requête continue. Tests synchronisés, sans dépendre d’un modèle « assez lent ».
- Deux moteurs : arrêter l’un ne casse pas l’autre. Le handler HTTP migré passe ses tests existants.

**Sortie** : première capacité réelle partagée, consommée directement et par HTTP ; aucune invocation cachée du serveur.

## P3 — Migrer tous les contrats mono-modèle et le streaming

**Fichiers de départ** : `server_routes`, `server_res_generator`, `server-chat.{h,cpp}`, `server-schema.{h,cpp}`, conversion des résultats dans `server-task.cpp`, `server-stream.{h,cpp}`.

**Travail**

- Extraire par familles : chat + tools + sorties structurées ; Responses/Anthropic ; completions/infill ; embeddings/rerank ; tokenisation/templates/comptage ; transcription et multimodal ; contrôle, slots, LoRA, propriétés et statistiques.
- Pour chaque famille, déplacer validation/conversion une seule fois et basculer ses handlers HTTP vers l’opération du moteur. Préserver options, erreurs, batchs, `n`, usages et extensions existantes documentées dans la matrice.
- Exposer les informations sémantiques nécessaires aux événements Responses/Anthropic, sans chaînes SSE dans le moteur. L’adapter HTTP produit noms d’événement, encodage, sentinelles et keep-alives existants ; préserver notamment les keep-alives pendant une attente bloquante.
- Distinguer dernier payload métier et issue terminale de la requête afin de ne pas perdre contenu, usage ou finish reason. Conserver les deltas incrémentaux de tool calls/reasoning sans exécuter d’outil.
- Traduire le multipart en pièces jointes indépendantes d’HTTP. Maintenir les durées de vie et les validations de formats/capacités.
- Garder la reprise SSE côté serveur : possession de la requête, drainage après déconnexion, replay par offset, lookup, DELETE/Stop et rétention. Sans reprise demandée, une déconnexion annule la requête.
- Transférer snapshots de métadonnées et accès aux statistiques hors des références non protégées à un modèle ; les lectures pendant sommeil ne doivent pas provoquer un réveil injustifié.

**Validation**

- Tests directs pour chaque famille et suites HTTP correspondantes ; suivre les formats qui manquent encore de fixtures.
- Sortie structurée parseable/conforme aux cas supportés, tool calls streamés avec fragments d’arguments, réponses finales et erreurs avant/après début du stream.
- Déconnexion/reconnexion, offset perdu, remplacement d’une session, Stop pendant drainage et arrêt du serveur pendant replay.
- Tests `test-chat`, JSON schema, sampling et régressions slots/LoRA/spéculation toujours applicables.

**Sortie** : tous les handlers mono-modèle utilisent le moteur. HTTP n’est plus propriétaire de la logique d’inférence ni de ses conversions JSON.

## P4 — Implémenter le cycle de vie multi-modèles dans le processus

**Fichiers de départ** : politiques de `server-models.{h,cpp}`, cycle de vie/sommeil de `server-context.cpp` et `server-queue.cpp`.

**Travail**

- Réutiliser les règles de sélection, alias et LRU ; remplacer l’hypothèse « un processus enfant = un modèle » par des états de modèles et leurs ressources possédées par le moteur.
- Définir/transcrire une machine d’états couvrant chargement, disponibilité, sommeil, déchargement et échec. Séparer présence au catalogue, ressources résidentes, admissions et requêtes actives.
- Compter les chargements en cours dans la limite ; réunir les demandes simultanées pour le même modèle autour d’un seul chargement. Libérer les réservations sur erreur et annulation.
- Implémenter attente bornée/annulable avec délai, protection des modèles utilisés et éviction LRU des seuls inactifs. Fixer et tester l’ordre de service afin d’éviter une famine silencieuse.
- Déchargement explicite : fermer les admissions pour le modèle, annuler ses travaux, attendre leur arrêt puis libérer. Gérer les courses avec soumission, rechargement, suppression et arrêt du moteur.
- Conserver sommeil/réveil et snapshots associés ; traduire les échecs récupérables de réveil en résultats explicites plutôt qu’en `GGML_ABORT` volontaire.
- Ajouter instantané du catalogue et abonnement aux états/progression. Définir gestion d’un abonné lent, resynchronisation et fermeture à l’arrêt ; un désabonnement ne doit pas annuler un chargement.

**Validation**

- Limite 1 : A occupé, B attend ; fin de A, éviction de A puis B ; annulation/expiration de B pendant attente.
- Limite 2 : deux modèles utilisables, échec de chargement sans réservation orpheline, demandes concurrentes d’un même modèle sans double chargement.
- Déchargement explicite pendant génération/chargement, sommeil/réveil échoué, erreurs et changement du catalogue pendant attente.
- Instances indépendantes ; progression observable ; aucun processus enfant ni port local pour ces tests. Utiliser doubles internes pour forcer les courses et tests publics avec vrais modèles pour valider l’intégration.

**Sortie** : moteur multi-modèles autonome, avec tests de ses transitions et limites ; aucune simulation de processus.

## P5 — Partager catalogue, configuration et acquisition optionnelle

**Fichiers de départ** : `server-models.cpp`, `common/arg.*`, `common/preset.*`, `common/download.*`, `common/hf-cache.*`, résolution de ressources multimodales.

**Travail**

- Extraire la lecture des sources locales/configurées et la traduction des presets vers la configuration du moteur ; garder les règles existantes de priorité, alias et defaults.
- Achever la matrice de traduction des options : aucun besoin d’inférence du serveur ne doit obliger à exposer un `common_params` brut, un `argc/argv` ou des paramètres HTTP.
- Fournir l’acquisition réseau dans un module partagé optionnel : résolution/téléchargement, progression, annulation et intégration au catalogue sans subprocess de téléchargement.
- Conserver les opérations explicites d’ajout/suppression et de gestion du cache, avec leurs contrôles d’accès, chemins et garanties existantes. La consultation du catalogue ne déclenche ni découverte ni écriture non configurée.
- Dans le profil sans réseau, une ressource distante demandée produit une erreur explicite de capacité ; les ressources locales restent opérationnelles.

**Validation**

- Fixtures de presets/répertoires/cache, alias en conflit, rechargement de source, modèle supprimé/modifié pendant utilisation ou attente.
- Téléchargements testés avec un serveur contrôlé : succès, erreur, annulation et fichier incomplet ; les essais ne dépendent pas tous d’un service Internet.
- Parité des options `-m`, `-hf`, URL et presets supportés dans le profil complet. Rebuild local sans dépendance HTTP transitive.

**Sortie** : le catalogue et l’acquisition sont partagés ; la sélection des modules ne change pas silencieusement le comportement des options conservées.

## P6 — Basculer entièrement le serveur, y compris le routeur

**Fichiers de départ** : `server.cpp`, `server-models.{h,cpp}`, `server-http.*`, `server-stream.*`, `tools/server/CMakeLists.txt` et tests routeur.

**Travail**

- Remplacer le routeur/proxy vers enfants par sélection et gestion des modèles du moteur. Les modes publics mono/multi-modèles peuvent rester, mais utilisent le même chemin d’inférence.
- Adapter endpoints de modèles, SSE de progression, health/props, métriques, slots et LoRA ; vérifier leur routage et leurs états pendant chargement/sommeil/arrêt.
- Raccorder la reprise des streams au registre détenu par le serveur, sans lookup vers un enfant. Conserver la confidentialité de lookup et les identifiants/offsets publics.
- Sortir outils exécutés, MCP et replay des cibles moteur. Réutiliser leurs helpers communs si nécessaire sans créer de dépendance inverse vers `llama-server-impl`.
- Définir et documenter précisément l’adaptation des champs/options liés aux processus : `exit_code`, arguments de lancement, timeout de force-kill, etc. Une erreur d’inférence n’est pas un code de sortie fictif.
- Préserver le contrôle d’accès, les options désactivées par défaut pour opérations sensibles, l’UI et les modes d’écoute. Mettre signaux et arrêt d’exécutable exclusivement dans les consommateurs.

**Validation**

- Suite HTTP existante, notamment router, stream, sleep, metrics, security, tools et MCP ; les outils externes peuvent avoir leurs propres processus, distincts de l’inférence.
- Serveur multi-modèles sans sous-processus d’inférence et sans ports de modèles enfants, observé à l’exécution et vérifié dans le graphe d’appels.
- Régressions UI ciblées : liste/progression des modèles, chat, Stop et reconnexion. Tester les profils où les outils/processus externes sont désactivés.

**Sortie** : chaque ligne serveur de la matrice passe par le moteur ou est explicitement une responsabilité HTTP/UI/outils. L’ancien routeur de processus n’est plus utilisé.

## P7 — Basculer le CLI local, préserver le mode distant

**Fichiers de départ** : `cli-context.{h,cpp}`, `cli-client.{h,cpp}`, `cli-server.h`, `tools/cli/CMakeLists.txt`, `app/CMakeLists.txt`.

**Travail**

- Brancher l’initialisation locale, les propriétés, le catalogue et le chat sur le moteur. Retirer le démarrage d’un serveur local et l’attente `/health` sur loopback.
- Conserver le client HTTP pour `--server-base`. Partager les traitements du CLI au niveau des opérations qu’il utilise, avec deux adapters local/distant si cela simplifie réellement le code ; ne pas reconstituer un serveur HTTP en mémoire.
- Préserver options, sélection des modèles, rendu des deltas, pièces jointes, historique, fichiers de sortie et interruption clavier.
- Retirer la dépendance de `llama-cli-impl` à `llama-server-impl` et ses includes serveur devenus inutiles. Conserver les points d’entrée requis par le binaire unifié `llama-app`.

**Validation**

- CLI local sans écoute réseau ; chat plusieurs tours, interruption puis nouvelle requête, erreurs de modèle et sortie propre.
- CLI distant avec serveur mono/multi-modèles, streaming et erreurs HTTP toujours fonctionnels.
- Build et smoke tests `llama-cli`, `llama-server`, `llama-app` ; commandes de téléchargement existantes non cassées.

**Sortie** : le CLI local est un vrai consommateur ; le client distant reste un chemin HTTP distinct et testé.

## P8 — Supprimer les chemins transitoires et terminer la séparation

**Travail**

- Supprimer façades, fonctions mortes, classes enfant/proxy devenues inutiles et anciens chemins d’inférence/chargement. Mettre à jour chaque test lié à une ancienne cible ; conserver ceux qui protègent le comportement.
- Vérifier que les headers moteur ne tirent ni `server-http.h`, ni headers CLI/UI, ni `common_params`, ni types de tâches internes.
- Remplacer les tests d’organisation interne obsolète par des tests de comportement à l’interface ; conserver des tests internes ciblés pour les courses/politiques, pas un second contrat concurrent.
- Documenter l’interface finale : configuration, erreurs, durée de vie, thread-safety, limites, pièces jointes, ressources optionnelles et exemple réellement compilé.
- Mettre à jour README-dev serveur, documentation CLI/build et différences de compatibilité. Relier le design aux noms de fichiers/header finalement retenus.

**Sortie** : aucune façade temporaire restante dans le journal ; une seule implémentation des traitements partagés, documentation conforme au code.

## P9 — Qualification finale et passation

**Matrice obligatoire**

| Profil | Preuve attendue |
| --- | --- |
| CPU local sans réseau/processus/UI | Configurer, compiler, lier et exécuter un consommateur du moteur seul ; tester les capacités locales supportées |
| Complet desktop | Serveur, CLI local/distant et app ; tests HTTP et directs |
| Statique et partagé | Headers publics utilisables, symboles disponibles et absence de dépendances HTTP cachées dans le profil local |
| Concurrence | Arrêts/annulations répétés, saturation, chargements/évictions, plusieurs moteurs ; ASan/UBSan et TSan lorsque supportés |
| Backend disponible, notamment Metal sur macOS | Smoke inférence, multi-modèles et arrêt ; comparaison avec référence CPU/backend de P0 |
| Multimodal/outils/sorties structurées | Fixtures réelles appropriées ; formats optionnels et tests non exécutés explicitement listés |

- Réexécuter la suite serveur complète disponible ; isoler les tests lourds/manquants plutôt que les compter comme passés.
- Comparer au relevé P0 latence premier événement, débit prompt/génération, concurrence et mémoire de files. Examiner les régressions ; conserver la méthodologie, les modèles et les paramètres.
- Contrôler les optimisations existantes avec leurs tests : batching, spéculation, cache, LoRA et sommeil. Aucun objectif de texte généré bit-à-bit identique n’est ajouté.
- Le packaging Swift/XCFramework n’est pas un livrable. Un smoke de compilation iOS est utile si le SDK est disponible ; son absence doit être signalée, pas remplacée par une promesse de validation iOS.
- Produire le rapport final : correspondance complète de la matrice P0, commandes/résultats, écarts de compatibilité, limites restantes et exemple compilé. Ne déclarer le drop terminé que lorsque les critères du design sont satisfaits ; toute qualification obligatoire bloquée reste visible.

**Sortie** : rapport permettant à un autre agent ou au mainteneur de reproduire la qualification, avec distinction explicite entre implémenté, testé et non vérifié.

## Commandes de départ et stratégie de tests

Depuis la racine, dans un répertoire neuf, les commandes suivantes concernent les cibles **existantes**, avant migration :

```bash
cmake -S . -B build-agent-engine-baseline \
  -DLLAMA_BUILD_TESTS=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
cmake --build build-agent-engine-baseline --parallel 2 \
  --target llama-server llama-cli test-chat test-json-schema-to-grammar test-sampling
ctest --test-dir build-agent-engine-baseline --output-on-failure \
  -R '^(test-chat|test-json-schema-to-grammar|test-sampling)$'

# Après préparation des dépendances Python et des fixtures décrites dans le README tests.
LLAMA_SERVER_BIN_PATH="$PWD/build-agent-engine-baseline/bin/llama-server" \
  PYTEST_WORKERS=1 ./tools/server/tests/tests.sh \
  unit/test_completion.py unit/test_chat_completion.py -v -x
```

Adapter chemins d’exécutables et configuration aux générateurs multi-configurations. Ne pas réutiliser un ancien build pour prouver le profil sans HTTP. Les commandes finales du moteur et des profils sans réseau seront ajoutées au journal après introduction effective des nouvelles cibles/options.

Pour chaque étape :

1. Tests rapides sans modèle pour validation, files, transitions et traductions ; synchronisation contrôlée plutôt que sleeps arbitraires.
2. Tests directs à l’interface publique avec modèles locaux appropriés ; résultats non streamés et flux.
3. Tests HTTP ciblés sur les familles migrées ; mêmes invariants observables, hors enveloppe transport.
4. Suite plus large à chaque bascule de consommateur et à P9. Établir les nouvelles assertions avant de retirer les anciens tests pertinents.

## Consigne courte de passation

> Implémente `docs/design/embedded-inference-engine-plan.md`, en lisant d’abord ses références obligatoires. Le périmètre et les arbitrages sont validés : commence à P0 puis avance étape par étape, avec build et tests à chaque jalon. Maintiens `docs/design/embedded-inference-engine-progress.md` avec preuves, écarts et prochaine action. Réutilise l’existant ; ne livre ni wrapper du serveur, ni seconde implémentation durable. Si une contrainte validée impose un nouvel arbitrage, isole le blocage au lieu de réduire la couverture. Aucun binding Swift n’est demandé dans ce drop.
