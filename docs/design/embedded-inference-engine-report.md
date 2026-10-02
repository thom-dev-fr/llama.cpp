# Rapport final — moteur d’inférence embarquable (P9)

Qualification du 30 septembre 2026 sur `b536fde9a` + correctifs P9 (voir « Correctifs apportés par la qualification »). Journal détaillé, commandes P0–P8 et historique : [progress](embedded-inference-engine-progress.md). Interface : [guide API](embedded-inference-engine-api.md). Contrat : [design](embedded-inference-engine.md).

Les décomptes ci-dessous datent de cette qualification ; ceux de la branche rebasée sur master le 2 octobre 2026 sont dans « Rebase sur master ».

Légende : **PASS** exécuté et vérifié ; **FAIL** exécuté et en échec ; **BLOCKED** prérequis indisponible ; **OUVERT** non implémenté ou arbitrage requis. Un test sauté n’est jamais compté PASS.

## Verdict

Les neuf critères de fin du design sont satisfaits et vérifiés sur macOS arm64 (CPU, Metal). Le drop reste **non clos sur deux points hors de ma décision** :

1. **Vidéo et WebP sans sous-processus** (profil local) : aucun décodeur embarqué n’existe ; `MTMD_VIDEO=OFF` retire aussi le repli WebP. **Arbitrage requis** (décodeur embarqué ou contrat d’entrée de frames prétraitées). Aucune parité n’est revendiquée.
2. **Qualifications non exécutables sur cet hôte** : Linux/Windows, LeakSanitizer (non supporté par ASan sur macOS arm64), chemin vidéo desktop (ffmpeg absent), exécution iOS sur appareil. Les tests HTTP `slow` ont été exécutés ensuite (section « Tests lents contre upstream »).

## Rebase sur master (2 octobre 2026)

Branche rebasée sur `master` `f1cee9941` (116 commits upstream). Les changements upstream portant sur du code déplacé par la branche ont été reportés à leur nouvel emplacement : API batch (`common_batch`, `llama_process`), limite `image_max_tokens` des projecteurs non causaux et embeddings sans cache de prompt (`engine-context.cpp`), entrées typées des embeddings (#29556, `engine-operations.cpp`), chemins `fs::path`/UTF-8 et `fs_write_atomic` (`hf-cache-local.cpp`, `download-local.cpp`, `arg-parse.cpp`, `preset.cpp` ; `common_params_config_files()` renvoie des `std::filesystem::path`). Contrôle : chaque ligne ajoutée par master depuis la base commune est présente dans l’arbre, hors adaptations volontaires.

| Contrôle (Release, Metal, partagé) | Avant rebase | Après rebase |
| --- | --- | --- |
| Build complet | 0 warning | 0 warning |
| CTest | 77/80 | **76/79** ; mêmes trois échecs connus (`test-jinja-py` environnement, `test-engine-operations`, `test-engine-acquisition`). Upstream a fusionné les trois variantes de `test-recurrent-state-rollback` (#29426) ; `test-engine-vision` et `test-engine-vision-embeddings` comptés avec tinygemma3 |
| HTTP `not slow` | 382 PASS, 6 SKIP, 11 erreurs de téléchargement des fixtures (SSL, environnement) | **407 PASS, 6 SKIP** |

Changements de comportement et ajouts :

- **JSON invalide → 400** : upstream (#29060) renvoie 400 pour `common_json_error`. Le moteur classe désormais ces erreurs en `invalid_request` au lieu de `preparation_failed` (500) ; `test_sleep` attend 400 pour un corps malformé, toujours après le réveil et les erreurs de capacité.
- **Embeddings multimodaux sans base64** : `embeddings` et `embeddings_openai` acceptent les pièces jointes nommées ; `attachment:nom` est résolu dans les entrées `{"content": [...]}` (`test-engine-vision-embeddings` : même vecteur qu’avec l’image en base64).
- **`model_id` en UTF-8** : le nom de fichier est converti par `fs_path_to_utf8`, comme les chemins upstream (`test-engine-options`).
- **`test-engine-sources` déterministe** : il échouait toujours lancé seul (génération de `beta` terminée par le contexte plein avant l’assertion, aussi sur la branche avant rebase) et ne passait que sous charge. Le preset `*` active `context-shift` : le flux de `beta` ne se termine plus que par son déchargement. 8/8 seul, et dans la suite complète.

## Critères de fin du drop

| # | Critère | Statut | Preuve |
| --- | --- | --- | --- |
| 1 | Opérations d’inférence et de gestion des modèles du serveur via le moteur | PASS | Matrice ci-dessous ; suite HTTP complète 393 PASS / 6 SKIP |
| 2 | CLI local sans serveur ni port ; distant fonctionnel | PASS | `test_cli.py` (absence de socket/enfant vérifiée), inclus dans les suites HTTP ASan/TSan/Metal |
| 3 | Multi-modèles sans sous-processus | PASS | `test_router` (5 répétitions CPU/Metal), `test-engine-models`, qualification Metal (éviction) |
| 4 | HTTP, UI, MCP, outils hors du moteur | PASS | `engine/` n’inclut ni `tools/server`, ni `tools/cli`, ni `httplib`, ni `subproc` ; `test-engine.cpp` échoue à la compilation si un header privé devient visible |
| 5 | Tests serveur existants applicables, écarts approuvés seulement | PASS | 393 PASS ; écarts documentés (section « Écarts de compatibilité ») |
| 6 | Tests directs : stream/complet, formats, outils, sortie structurée, pièces jointes, annulation, arrêt, erreurs, saturation | PASS | `test-engine*` (29 dans chaque profil local), `test-engine-qualification` sur modèles réels |
| 7 | Chargement concurrent, limites, attente, éviction, déchargement, événements, coexistence | PASS | `test-engine-models`, `-catalog`, `-lifecycle`, qualification (coexistence, éviction) ; ASan/UBSan + TSan |
| 8 | Socle local sans HTTP ni sous-processus requis ; consommateurs réseau séparés | PASS | Profils neufs statique/partagé ; `nm`/`otool` ; build iOS arm64 |
| 9 | Pas de seconde implémentation durable | PASS | Tableau des façades vide depuis P8 ; une seule implémentation appelée par l’API publique et le serveur |

## Matrice obligatoire P9

| Profil | Résultat | Détail |
| --- | --- | --- |
| CPU local sans réseau/processus/UI | **PASS** | Répertoires neufs `build-agent-engine-p9-local-{static,shared}` : configure sans téléchargement, 0 warning, **29/29** chacun. Sources compilées : aucune de `httplib`, `subproc`, `download.cpp`, `tools/server`, `tools/cli` ; aucun flag `CPPHTTPLIB`/`LLAMA_SUBPROCESS`/`MTMD_VIDEO`/`OPENSSL` ; `nm -u` moteur/common/mtmd sans symbole réseau ni processus |
| Complet desktop | **PASS** | Build complet (toutes cibles) 0 warning ; CTest **82/82** (`test-jinja-py` requiert `jinja2` : PASS avec l’interpréteur du venv, FAIL avec le `python3` système sans ce module — environnement) ; HTTP **393 PASS, 6 SKIP** |
| Statique et partagé | **PASS** | `test-engine-example` lié au seul `libllama-engine` ; `otool -L` : mtmd, common-options, common-local, llama, ggml, système. iOS arm64 (SDK iPhoneOS 27.0, Xcode) : bibliothèques statiques du profil moteur et **édition de liens de l’exemple** réussies |
| Concurrence | **PASS** | ASan+UBSan : moteur 13/13 (statique) et 16/16 (partagé, serveur), **HTTP complet 393 PASS** ; TSan : moteur 14/14 et 16/16, **HTTP complet 393 PASS** ; 0 rapport. LeakSanitizer **BLOCKED** (macOS) |
| Backend Metal | **PASS** | Qualification modèles réels (ci-dessous) ; HTTP routeur/stream/sommeil/CLI/completion/chat/vision/embeddings avec `N_GPU_LAYERS=99` : **183 PASS, 1 SKIP** ; A/B contre upstream sans régression |
| Multimodal / outils / sorties structurées | **PASS** (sauf vidéo/WebP) | `test-engine-qualification` : outils streamés (fragments d’arguments) + tour de résultat, JSON schema conforme, reasoning séparé, vision, **transcription audio réelle** (auparavant BLOCKED) et chat audio. Vidéo/WebP : **BLOCKED** (ffmpeg absent) / **OUVERT** (profil sans processus) |

### Qualification sur modèles représentatifs (Metal, `--gpu-layers 99`)

`test-engine-qualification` (API publique seule), 51 s : Qwen3.5-2B Q4_K_M (+ mmproj BF16), stories260K comme second modèle, gemma-4-E2B-it Q4_K_M (+ mmproj audio), `tools/mtmd/test-1.jpeg`, `tools/mtmd/test-2.mp3`.

| Scénario | Résultat |
| --- | --- |
| Chat complet et streamé | PASS (premier événement 5–10 ms) |
| Appel d’outil complet et streamé, `finish_reason = tool_calls`, arguments JSON reconstitués depuis 5 fragments ; tour avec résultat d’outil | PASS |
| Sortie structurée `json_schema` (types, `required`, `additionalProperties: false`) | PASS |
| Reasoning séparé du contenu | PASS |
| Événements Responses (`response.completed`) et Anthropic (`message_stop`) | PASS |
| Annulation d’une génération concurrente, l’autre termine | PASS |
| `stop()` avec lecteur bloqué ; handle survivant au moteur | PASS (`stopped`) |
| Deux moteurs, arrêt de l’un ; création/arrêt répétés | PASS |
| Catalogue `max_loaded = 1` : 3 bascules, éviction LRU, un seul résident, `unload` | PASS |
| Vision par pièce jointe | PASS |
| Transcription (pièce `file`) : **texte et usage identiques à `llama-server` upstream** sur la même requête | PASS |
| Chat audio (`input_audio` → `attachment:`) | PASS |

## Tests lents contre upstream

Les 199 tests HTTP marqués `slow` et les 2 tests conditionnés par `SLOW_TESTS` (infill Qwen2.5-Coder, LoRA 8B) ont été exécutés **sur le moteur et sur `llama-server` upstream `e4c142c`**, même modèle en cache, mêmes tests, Metal (`N_GPU_LAYERS=99`). 16 lots, un par modèle (15 modèles de 0,8 à 8,5 Go, environ 70 Go téléchargés au total), chaque modèle étant supprimé du cache de test après son lot (28 Gio libres sur le disque).

| Lot (modèle) | Moteur réussis/échecs | Upstream réussis/échecs | Ensembles d’échecs |
| --- | ---: | ---: | --- |
| Llama-3.2-1B | 8/2 | 8/2 | identiques |
| Qwen2.5-1.5B | 4/6 | 4/6 | identiques |
| gemma-2-2b | 0/12 | 0/12 | identiques |
| Llama-3.2-3B | 12/8 | 12/8 | identiques |
| Qwen2.5-Coder-3B | 4/10 | 4/10 | identiques |
| Phi-3.5-mini (+ arrêts OpenAI) | 4/19 | 4/19 | identiques |
| Qwen2.5-Coder-1.5B (infill) | 1/0 | 1/0 | — |
| Qwen2.5-7B | 8/8 | 8/8 | identiques |
| DeepSeek-R1-7B (+ thinking Anthropic) | 2/14 | 2/14 | identiques |
| Hermes-2-Pro-8B | 6/10 | 6/10 | identiques |
| Hermes-3-8B | 8/8 | 8/8 | identiques |
| Llama-3.1-8B | 6/6 | 6/6 | identiques |
| Llama-3.1-8B IQ2_M + LoRA | 1/0 | 1/0 | — |
| functionary-small v3.2 (Q8_0, Q4_K_M) | 8/16 | 8/16 | identiques |
| Mistral-Nemo-12B | 6/2 | 6/2 | identiques |
| command-r7b | 2/0 | 2/0 | — |
| **Total** | **80/121** | **80/121** | **aucun écart** |

Les échecs sont des réponses en prose au lieu d’un appel d’outil, ou des textes attendus devenus obsolètes (`test_completion_stream_with_openai_library_stops` : « Sure! Here's one… » contre « Sure, here's one… » attendu, **sortie identique** upstream). Les deux tests Anthropic « thinking » (DeepSeek-R1) passent. Durée du test LoRA : le premier binaire exécuté paie le téléchargement de l’adaptateur (~48 s) ; ordre inversé, à chaud, 19,9 s (moteur) contre 18,1 s (upstream).

## Performances : A/B contre upstream `e4c142c`

Binaires alternés sur le même hôte (upstream puis moteur, 3 tours × 5 répétitions, soit 15 échantillons par cellule), `scripts/bench-server-baseline.py`, paramètres P0 (ctx 1024, 4 slots, 64 tokens, température 0). **L’hôte n’était pas au repos** (visioconférence, charge 20–45) : seules les comparaisons alternées sont interprétables, pas les valeurs absolues.

| Modèle | Backend | Conc. | Δ débit agrégé | Δ premier événement | Δ génération |
| --- | --- | ---: | ---: | ---: | ---: |
| stories260K | CPU | 1 / 4 | +7,4 % / +1,9 % | −8,5 % / −6,5 % | +9,0 % / +5,6 % |
| stories260K | Metal | 1 / 4 | −0,8 % / +4,6 % | −3,5 % / −6,2 % | −1,3 % / +2,8 % |
| Qwen3.5-2B | CPU | 1 / 4 | +1,8 % / −0,3 % | −0,7 % / −0,9 % | +1,5 % / −0,6 % |
| Qwen3.5-2B | Metal | 1 / 4 | +0,3 % / **+0,3 %** ¹ | 0 % / −10,6 % | +0,2 % / ≈0 % ¹ |

¹ Première série : −10,1 % à concurrence 4, dû à l’état de l’hôte (au tour 3, les **deux** binaires sont à 110 tok/s ; au tour 1, les deux à ~127). Série dédiée de 6 tours, ordre inversé à chaque tour, 30 échantillons chacun : médiane 111 contre 111 tok/s, **+0,3 %**. RSS maximale : écart < 0,1 % (Qwen), −8 % (stories CPU). Le signal CPU de P1-C n’est pas reproduit. Aucune régression détectée ; aucun seuil de non-régression n’est revendiqué au-delà de cette résolution.

Mémoire des files : bornée par `max_events`/`max_tasks` dans l’API embarquée ; le serveur garde la sémantique upstream (non bornée). Aucune instrumentation dédiée au-delà de la RSS.

## Correctifs apportés par la qualification

1. **mtmd sans les flags du projet** (régression P1) : ajoutée depuis la racine et non plus depuis `tools/`, la bibliothèque perdait `-fsanitize=*` et `LLAMA_ALL_WARNINGS`. Symptôme : `container-overflow` ASan (faux positif d’instrumentation mixte) dans `test-engine-vision` du build partagé. Correctif : `llama_add_compile_flags()` dans `tools/mtmd/CMakeLists.txt`. Build complet toujours à 0 warning avec les warnings restaurés.
2. **Détection de départ d’un client en attente de modèle** (régression P6) : le routeur historique vérifiait la connexion toutes les 200 ms pendant l’attente d’un modèle, le moteur toutes les 1 s. Un client parti pouvait encore compter comme attente quand le modèle occupé devenait inactif et provoquer son éviction (`test_router_queue_client_disconnect_keeps_model`, échec selon la phase, observé sous Metal). Correctif : `MODEL_WAIT_POLLING` = 200 ms dans `server-context.cpp`. Suite routeur 5×/5 PASS (3 Metal, 2 CPU).
3. **Couverture** : `test-engine-qualification` ajouté (toujours compilé, exécuté avec `LLAMA_ENGINE_QUALIFY_ARGS`, label `heavy`).

## Correspondance de la matrice P0

| Opération (P0) | Destination finale | Preuve P9 |
| --- | --- | --- |
| `/health` | Snapshot moteur + adapter HTTP | `test_basic`, `test_sleep` |
| `/metrics` | `operation::metrics` ; Prometheus dans l’adapter | `test_metrics`, `test_sleep` |
| GET/POST `/props` | `properties` / `properties_update` (no-op gardé) | `test_basic`, `test_template`, `test_sleep` |
| `/models`, `/v1/models` | `catalog()` / entrées ; `exit_code` → `failed` + `error` | `test_router`, `test_basic` |
| `/completion`, `/completions` | `completion` | `test_completion`, `test_ctx_shift`, `test-engine` |
| `/v1/completions` | `completions` | `test_completion`, `test-engine-operations` |
| `/chat/completions` (+ outils, reasoning, schema, médias) | `chat` | `test_chat_completion`, `test_tool_call` (rapides), `test_vision_api`, qualification |
| `/v1/chat/completions/control` | `control` | `test_chat_completion` |
| `/responses` | `responses` | `test_compat_oai_responses`, qualification |
| `/v1/messages` | `messages` | `test_compat_anthropic`, qualification |
| `/audio/transcriptions` | `transcription` (pièce `file`) | **qualification audio réelle, parité upstream** |
| `/infill` | `infill` | `test_infill`, `test-engine-infill` |
| `/embedding(s)` | `embeddings`, `embeddings_openai` | `test_embedding` (CPU et Metal) |
| `/rerank` et alias | `rerank` | `test_rerank`, `test-engine-rerank` |
| `/tokenize`, `/detokenize` | `tokenize`, `detokenize` | `test_tokenize` |
| `/apply-template` | `apply_template` | `test_template` |
| Comptages chat/Responses/Messages | `chat_tokens`, `response_tokens`, `message_tokens` | `test_chat_completion`, `test_compat_*` |
| `/lora-adapters` | `lora_list`, `lora_apply` | `test_lora`, dont le test lent 8B + adaptateur (PASS, comme upstream) |
| `/slots`, `/slots/:id` | `slots`, `slot_save/restore/erase` ; gardes HTTP | `test_basic`, `test_slot_save`, `test_security` |
| `/models/load`, `/models/unload` | `load`, `unload` | `test_router`, `test-engine-models` |
| POST/DELETE `/models` | `download`, `remove` | `test_router`, `test-engine-acquisition`, `test-engine-sources` |
| `/models/sse` | `subscribe()` ; rendu SSE dans le serveur | `test_router`, `test-engine-models` |
| Sommeil/réveil | Machine d’états moteur ; `wake_failed` explicite | `test_sleep` (CPU et Metal) |
| Reprise `/v1/stream`, lookup, DELETE | Serveur (`server-stream.cpp`) | `test_stream`, `test-engine-replay` |
| `/cors-proxy`, `/tools`, MCP, GCP, UI/statique/auth | Serveur uniquement | `test_proxy`, `test_tools_builtin`, `test_mcp_servers`, `test_compat_gcp`, `test_security` |
| CLI local | `cli-engine.*` (API publique) | `test_cli` |
| CLI distant | `cli-client.*` (HTTP) | `test_cli` |
| CLI conversation | `cli_context` + `cli_backend` | `test_cli` |

## Écarts de compatibilité (approuvés et documentés)

- **P6, mode multi-modèles** : champs de processus adaptés sans émulation (`exit_code` → état `failed` + `error`, `status.args`, timeout de force-kill, ports enfants) ; options processus par modèle (`prio`, `numa`, `rpc`) et HTTP par modèle restent à l’hôte ; `LLAMA_ARG_*` et `config.ini` traduits explicitement ; alias modifiés au rechargement appliqués immédiatement. Détail : README-dev serveur « Router mode ».
- **P7, CLI** : plus de serveur loopback ni d’attente `/health` ; points d’entrée `llama_server(params, 0, nullptr)` et `llama_server_terminate` supprimés.
- **P8** : consommateurs CMake internes de `llama-engine` à relier à `llama-engine-internal` pour les headers privés. Aucun écart HTTP ni CLI.
- **Isolation** : l’exécution dans le processus abandonne l’isolation des pannes natives des enfants (design).

## Limites restantes

| Limite | Statut |
| --- | --- |
| Vidéo/WebP sans sous-processus | **OUVERT — arbitrage requis** |
| Chemin vidéo desktop (ffmpeg) | BLOCKED : ffmpeg absent ; code inchangé depuis upstream ; aucun test existant |
| 121 échecs des tests lents d’appels d’outils | **Identiques sur upstream `e4c142c`** (même ensemble, test par test) : comportement des modèles quantifiés et attentes de texte figées, pas une régression du moteur |
| LeakSanitizer | BLOCKED (macOS arm64) |
| Linux, Windows | Non qualifiés (hôte macOS) ; points d’attention : `lsof`/`pgrep` du test CLI, `_putenv_s`, export des symboles internes sous Windows |
| iOS | Compilation et édition de liens seulement ; ni exécution sur appareil ni packaging (hors périmètre) |
| Backtrace de ggml sur abort fatal | `ggml_print_backtrace` peut lancer un débogueur par `fork` (`GGML_NO_BACKTRACE` le désactive) : chemin d’erreur fatale amont, pas d’inférence |
| `-Wshorten-64-to-32` du générateur Xcode | 2240 avertissements, surtout ggml/src amont ; propres au générateur |
| Doublon `cpp-httplib` à l’édition de liens de `test-engine-acquisition` (statique + acquisition) | Avertissement `ld` cosmétique |

## Exemple compilé

`examples/engine-simple/engine-simple.cpp`, cible `llama-engine-simple` et test `test-engine-example`, lié au seul `llama-engine` : exécuté dans chaque profil (29/29), et lié pour iOS arm64.

## Reproduction

Commandes P9 exactes : section « P9 » du journal. Preuves dans `build-agent-engine-evidence/p9-*` (répertoire ignoré par Git).
