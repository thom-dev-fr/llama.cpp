# Journal — moteur d’inférence embarquable

## Passation / état courant

- Référence initiale : `e4c142c5765abf9e5e2285b4b7379e4e84edacea`. Reprise P2 sur `642c8ea7b`, avec P0/P1 commités et arbre propre.
- **P3 implémenté le 29 septembre 2026 : tous les contrats mono-modèle utilisent le runtime moteur ; qualification et limites détaillées dans la section P3 ci-dessous.**
- **P3 revérifié puis P4 implémenté le 29 septembre 2026** (section P4) : cycle de vie multi-modèles dans le processus, sans sous-processus ni port. **Prochaine étape : P5.** Le drop complet P0–P9 n’est pas terminé. P3 et P4 ne sont pas commités à la fin de cette session.
- P0/P1 : inventaire, références et graphe recontrôlés ; 16/16 tests locaux dans chaque profil et 9/9 tests C++ ciblés repassés avant P2. Les réserves de performance et capacités consignées à P1 restent ouvertes.
- P2 : `include/llama-engine.h`, décodeur unique dans `engine/`, handlers `/completion` et `/completions` migrés. Voir la section P2 et [le guide API](embedded-inference-engine-api.md). CLI local et routeur conservent leurs chemins legacy jusqu’à P6/P7.
- Références obligatoires lues intégralement : CONTEXT, design, ADR 0001, CONTRIBUTING, README-dev serveur et README tests serveur.
- P2 commité dans `da40e15ae`. Les notes « non suivis » des lots P0/P1 décrivent leur état historique ; ces lots figurent désormais dans HEAD.
- **Revue P0–P2 du 29 septembre 2026** : régressions HTTP de `/completion` trouvées puis corrigées (voir « P2 — Correctif de revue »). **Décision** : le serveur conserve la sémantique upstream, sans aucune régression observable ; les bornes restent le défaut de l’API embarquée. Parité vérifiée octet par octet et en performance contre `e4c142c`. Correctif non commité à la fin de cette session.
- Swift / XCFramework : hors périmètre.
- Passation : tous les builds/tests lancés sont terminés ; aucun travail de fond laissé à reprendre. `git diff --check` final passe.
- Légende : PASS = exécuté et vérifié ; FAIL = exécuté, assertion/build échoué ; BLOCKED = prérequis indisponible ; OUVERT = non encore implémenté/vérifié. Un test sauté n’est jamais PASS.
- Preuves locales : `build-agent-engine-evidence/` (répertoire ignoré par Git, commandes et synthèses ci-dessous pour reproduction).

## P0 — Matrice des opérations

La completion native est **migrée à P2** ; les contrats mono-modèle sont **migrés à P3** (correspondance opérations/tests dans la section P3). Les lignes multi-modèles, acquisition et CLI restent ouvertes selon leurs étapes. Les tests cités sont existants, pas implicitement exécutés. Sauf mention contraire, les handlers sont dans `tools/server/server-context.cpp::server_routes::init_routes`. Les opérations publiques sont nommées dans `llama_engine::operation`, sans chemins HTTP.

| Opération / chemins et alias | Comportement actuel / configuration requise | Destination | Tests existants / à ajouter |
| --- | --- | --- | --- |
| GET `/health`, `/v1/health` | Middleware chargement/erreur, réponse sans réveil ; public sans clé | Snapshot moteur + adapter HTTP | `test_basic`, `test_sleep` ; direct états |
| GET `/metrics` | Tâche prioritaire, reset des compteurs par fenêtre, snapshot pendant sommeil ; `endpoint_metrics=false` | Statistiques moteur, texte Prometheus/headers HTTP | `test_metrics`, `test_sleep` ; direct snapshot concurrent |
| GET `/props` | Métadonnées, templates, defaults, capacités, UI ; snapshot sommeil | Snapshot moteur + propriétés UI hôte | `test_basic`, `test_template`, `test_sleep` |
| POST `/props` | `endpoint_props=false` ; actuellement succès sans mutation effective | Contrôle moteur si mutations ajoutées, garde HTTP conservée | Ajouter test direct/HTTP du no-op et garde |
| GET `/models`, `/v1/models` | Mono : snapshot ; routeur : catalogue/alias/tags/source/modalités, `reload`, args/preset/exit_code historiques | Catalogue moteur, sérialisation compat HTTP | `test_router`, `test_sleep`, `test_basic` |
| POST `/completion`, `/completions` | Native, prompts texte/tokens/batchs, stream, `n`, sampling, cache, timings, progression | Moteur P2 puis P3 ; SSE HTTP | `test_completion`, `test_ignore_eos`, `test_ctx_shift` |
| POST `/v1/completions` | Conversion OpenAI, usage/finish_reason/logprobs ; même ordonnanceur | Moteur P3 | `test_completion` |
| POST `/chat/completions`, `/v1/chat/completions` | Templates, outils produits, reasoning, JSON schema, médias, `n`, usage ; reprise opt-in | Moteur P3 ; reprise chez serveur | `test_chat_completion`, `test_tool_call`, `test_vision_api`, `test_stream`, `test-chat` |
| POST `/v1/chat/completions/control` | `id`, `action=reasoning_end`, tâche de contrôle | Moteur P3 | `test_chat_completion` ; contrôle direct |
| POST `/responses`, `/v1/responses` | Conversion Responses → chat, événements nommés, usage | Conversion/événements sémantiques moteur ; SSE HTTP | `test_compat_oai_responses` |
| POST `/v1/messages` | Conversion Anthropic → chat, erreurs et événements spécifiques | Moteur P3 + adapter HTTP | `test_compat_anthropic` |
| POST `/audio/transcriptions`, `/v1/audio/transcriptions` | Multipart `req.files`, modèle audio requis, conversion vers chat | Pièces jointes possédées + conversion moteur ; multipart HTTP | Fixture audio réelle à qualifier ; tests directs à ajouter |
| POST `/infill` | Vérification tokens FIM ; prefix/suffix/extra, `spm_infill` | Moteur P3 | `test_infill` |
| POST `/embedding`, `/embeddings`, `/v1/embeddings` | Native/OpenAI, batching, normalisation, pooling ; `embedding`, `n_batch<=n_ubatch` | Moteur P3 | `test_embedding` |
| POST `/rerank`, `/reranking`, `/v1/rerank`, `/v1/reranking` | TEI/Jina, query/documents/texts/top_n ; embedding et pooling RANK | Moteur P3 | `test_rerank` |
| POST `/tokenize`, `/detokenize` | Texte/tokens mixtes, add_special/parse_special/with_pieces, octets invalides UTF-8 | Moteur P3 | `test_tokenize` |
| POST `/apply-template` | Même conversion chat, sans génération | Moteur P3 | `test_template` |
| POST `/chat/completions/input_tokens`, `/v1/chat/completions/input_tokens` | Comptage du chat préparé | Moteur P3 | `test_chat_completion` ; direct |
| POST `/responses/input_tokens`, `/v1/responses/input_tokens` | Comptage Responses converti | Moteur P3 | `test_compat_oai_responses` ; direct |
| POST `/v1/messages/count_tokens` | Comptage Anthropic converti | Moteur P3 | `test_compat_anthropic` ; direct |
| GET/POST `/lora-adapters` | Liste/échelles des adapters chargés, validation tableau, tâche sérialisée | Moteur P3 | `test_lora` ; direct |
| GET `/slots` | `endpoint_slots=true`, `fail_on_no_slot`, tâche prioritaire | Moteur P3 ; garde HTTP | `test_basic`, `test_slot_save` |
| POST `/slots/:id_slot` | save/restore/erase ; `slot_save_path` vide par défaut, validation nom | Moteur P3 ; garde HTTP | `test_slot_save`, `test_security` |
| POST `/models/load`, `/models/unload` (routeur) | Validation état/alias ; lancement/arrêt enfant, annulation téléchargement | Cycle de vie moteur **implémenté P4** (`engine::load/unload`) ; bascule HTTP P6 | `test_router` ; `test-engine-models`, `test-engine-catalog` |
| POST `/models` (routeur) | Validation distante, téléchargement enfant, rafraîchissement cache | Acquisition optionnelle P5, catalogue moteur | `test_router`, `test-model-resolution` ; serveur contrôlé |
| DELETE `/models` (routeur) | Suppression explicite du cache, restrictions de source et de chemins | Cache local partagé + cycle de vie moteur | `test_router`, `test_security` ; courses suppression/chargement |
| GET `/models/sse` (routeur) | Abonnement progression/états, déconnexion abonné indépendante du modèle | Observation moteur **implémentée P4** (`engine::subscribe`) ; SSE HTTP P6 | `test_router` ; saturation/resync dans `test-engine-models` |
| Sommeil/réveil (pas une route) | `sleep_idle_seconds=-1`, snapshot avant destroy, requête réveille ; **P4 : réveil échoué = erreur explicite récupérable** (`wake_failed`, HTTP 503) au lieu de GGML_ABORT | Machine d’états moteur P4 | `test_sleep` (dont réveil échoué), `test-engine-catalog` |
| GET `/v1/stream`, POST `/v1/streams/lookup`, DELETE `/v1/stream` | conv_id/from, lookup privé, rétention, remplacement, drainage après déconnexion, Stop ; routeur proxy enfant | Serveur seul P3/P6, possède la requête moteur | `test_stream`, `test_router` ; arrêt pendant replay |
| GET/POST `/cors-proxy` | Proxy UI optionnel, sinon 403 | Serveur uniquement | `test_proxy`, `test_security` |
| GET/POST `/tools` | Outils exécutés/MCP, streaming propre, sinon 403 | Serveur/hôte uniquement | `test_tools_builtin`, `test_mcp_servers` |
| GCP (`register_gcp_compat`) | Alias configurés par environnement vers handlers, enveloppe transport | Serveur uniquement, opérations sous-jacentes moteur | `test_compat_gcp` |
| UI/statique/auth/CORS/OPTIONS/préfixes | `server-http.cpp`, contenu intégré ou public_path | Serveur uniquement | `test_security`, `test_basic` ; smoke UI manuel à ajouter |
| CLI local initialisation | `cli-context.cpp::init`, `cli-server.h` lance llama_server sur thread et port loopback, attend health | Moteur direct P7, sans serveur | Ajouter smoke local sans port, arrêt/rechargement |
| CLI distant | `server_base`, `/health`, `/props`, `/v1/models`, POST SSE chat | `cli-client` reste HTTP | Ajouter mono/multi-modèles distant |
| CLI conversation | Choix modèle, system_prompt, prompt/image, fichiers/globs, historique, pièces jointes, sorties, timings, single_turn, interruption | Historique/rendu/IO CLI ; opérations moteur | Ajouter plusieurs tours, interruption puis requête, fichiers |

### Profils multimédias et champs historiques

| Capacité | Desktop complet actuel | Local sans subprocess cible | Qualification |
| --- | --- | --- | --- |
| Texte, images décodées par stb, audio miniaudio | Dans mtmd | Conserver, sans processus | Fixtures tinygemma3 présentes ; tests non encore exécutés |
| Vidéo conteneur | ffprobe + ffmpeg dans `mtmd-helper.cpp`, `MTMD_VIDEO` | Prétraitement externe non obligatoire ; pas de décodeur local équivalent existant | **OUVERT, arbitrage avant de revendiquer parité de formats** : décodeur embarqué ou entrée frames prétraitées |
| WebP | stb ne le décode pas ; fallback ffmpeg sous `MTMD_VIDEO` | Désactiver VIDEO perd aussi WebP | Même arbitrage ; ne pas compter comme couvert |
| Exécution outils/MCP | subprocess permis | Hors moteur ; option du consommateur | Ne pas confondre processus d’outil avec processus d’inférence |
| `status.args`, `status.preset`, `exit_code`, signaux enfant, `DEFAULT_STOP_TIMEOUT`, ports enfants | Processus réels | Pas de faux exit_code d’inférence | Adaptation HTTP explicite à définir/documenter en P6 |

## P0 — Configuration : registre de traduction

**Pas encore une interface publique.** La colonne cible désigne le propriétaire futur ; la traduction champ par champ et ses tests restent OUVERTS jusqu’à P2/P5. Ne pas remplacer ces familles par quelques paramètres chat. Les valeurs de référence sont dans `common/common.h` ; les overrides d’exécutable et de modèle sont dans `common/arg.cpp`, `common/preset.cpp`, `server.cpp`, `server-models.cpp`. Les lectures transitives de `common_init_from_params`, `common_model_params_to_llama`, `common_context_params_to_llama`, `common_base_params_to_speculative` font partie du périmètre.

| Champs lus / famille | Defaults et overrides à préserver | Traduction cible / test |
| --- | --- | --- |
| `model.{path,url,hf_repo,hf_file,docker_repo}`, `mmproj`, `no_mmproj`, `hf_token`, `offline` | chemins vides ; résolution dans `common_models_handler_*`, pas dans `common_init_from_params` | Ressource locale moteur / résolution acquisition optionnelle ; `test-model-resolution` |
| `models_dir`, `models_preset`, `models_preset_hf`, `model_alias`, `model_tags`, `models_max`, `models_autoload` | max=4, autoload=true ; cache/répertoire/presets/globaux/args, alias et déduplication ; `load_models` | Catalogue/politique par moteur P4/P5 ; fixtures presets |
| `n_ctx`, `n_parallel`, `n_batch`, `n_ubatch`, `n_outputs_max`, `n_outputs_max_per_seq` | 0/1/2048/512/0/1 ; serveur np auto→4 + kv_unified ; embedding batch ramené à ubatch | Configuration modèle/contextes ; direct + batching |
| `kv_unified_per_slot`, `fit_params`, `fit_params_min_ctx`, `fit_params_target`, `fit_params_print` | par-slot=0 ; fit=true, min_ctx=4096, marge 1GiB/device ; `-c` explicite empêche auto-size | Chargement/fit local ; préserver marqueurs d’override |
| `devices`, `n_gpu_layers`, `main_gpu`, `tensor_split`, `split_mode`, `load_mode`, `lazy_mode`, `tensor_buft_overrides`, `kv_overrides` | ngl=-1(auto), main=0, split layer, load/lazy auto ; terminators internes | Configuration modèle sans exposer common_params ; CPU/backend |
| `cpuparams`, `cpuparams_batch`, `numa` | threads/affinité/priorité/poll, propagation defaults dans parse | Pools internes ; NUMA/priorité process à auditer pour coexistence |
| `rope_scaling_type`, `rope_freq_base`, `rope_freq_scale`, `yarn_{ext_factor,attn_factor,beta_fast,beta_slow,orig_ctx}` | unspecified/0/0, -1/-1/-1/-1/0 | Configuration contexte modèle |
| `pooling_type`, `attention_type`, `flash_attn_type`, `embedding`, `embd_normalize` | unspecified/unspecified/auto, false, 2 | Configuration modèle + options requête embeddings |
| `cache_type_k`, `cache_type_v`, `no_kv_offload`, `no_op_offload`, `no_extra_bufts`, `no_host`, `check_tensors`, `warmup`, `swa_full`, `kv_unified`, `no_perf` | f16/f16, flags false sauf warmup=true | Chargement/contextes locaux ; tests cache/backend |
| `cb_eval`, `cb_eval_user_data`, `load_progress_callback`, `load_progress_callback_user_data` | null ; callback de chargement remplacé par serveur pour progression | Hooks internes possédés, observation publique P4 ; durée de vie à tester |
| `lora_adapters`, `lora_init_without_apply`, `control_vectors`, `control_vector_layer_start/end` | vides, false, couches -1 ; application au chargement puis LoRA mutable | Configuration modèle + opérations LoRA ; pas de pointeurs publics |
| `n_predict`, `n_keep`, `special`, `antiprompt`, `spm_infill` | -1, 0, false, vide, false ; requête/clamp limite serveur | Defaults génération puis JSON requête ; completion/infill |
| `sampling.seed`, `n_prev`, `n_probs`, `min_keep`, `top_k`, `top_p`, `min_p`, `typ_p`, `temp` | seed défaut, 64/0/0/40/.95/.05/1/.8 | Defaults sampling + overrides JSON ; `test-sampling`, HTTP |
| `sampling.xtc_probability/threshold`, `dynatemp_range/exponent`, `top_n_sigma`, `adaptive_target/decay`, `mirostat/tau/eta` | 0/.1, 0/1, -1, -1/.9, 0/5/.1 | Même traduction sampling, pas de sous-ensemble |
| `sampling.penalty_last_n/repeat/freq/present`, `dry_multiplier/base/allowed_length/penalty_last_n/sequence_breakers` | 64/1/0/0, 0/1.75/2/64, quatre breakers | Idem ; `test-sampling` |
| `sampling.samplers`, `user_sampling_config`, `ignore_eos`, `logit_bias`, `logit_bias_eog`, `backend_sampling`, `no_perf`, `timing_per_token` | metadata modèle seulement pour champs non explicités ; biais EOG calculés au chargement | Préserver priorité metadata < valeurs explicites < requête ; buffers backend internes |
| `sampling.grammar`, `grammar_lazy`, `grammar_triggers`, `preserved_tokens`, `generation_prompt` | grammaire typée user/output/tool, préremplissage conditionnel | JSON/template/schema dans workers moteur hors decode ; tests grammar/chat |
| `sampling.reasoning_budget_tokens/start/end/forced/message`, `reasoning_control` | budget -1, chaînes/tokens dérivés du template | Defaults et contrôle requête ; budget/fragmentation outils |
| `speculative.types`, `draft.{mparams,n_max,n_min,p_min,p_split,backend_sampling,n_gpu_layers,cache_type_k,cache_type_v,cpuparams,cpuparams_batch,devices,tensor_buft_overrides}`, `ngram_mod`, `ngram_simple`, `ngram_map_k`, `ngram_map_k4v`, `ngram_cache`, `synth_len/rates` | types NONE ; draft 3/0/0/.1 ; chargement draft local, caches ngram ; ctx_tgt/ctx_dft internes | Configuration modèle et overrides acceptés aujourd’hui ; `test_speculative`, sampling |
| `cont_batching`, `ctx_shift`, `n_cache_reuse`, `cache_prompt`, `cache_idle_slots`, `n_ctx_checkpoints`, `checkpoint_min_step`, `cache_ram_mib`, `slot_prompt_similarity` | true/false/0/true/true/32/8192/8192/.1 | Ordonnanceur/cache inchangé ; slot/cache/speculation tests |
| `chat_template`, `use_jinja`, `enable_chat_template`, `force_pure_content_parser`, `reasoning_format`, `enable_reasoning`, `prefill_assistant`, `default_template_kwargs`, `preserve_reasoning_specified` | vide/true/true/false/deepseek/-1/true/vide/false | Préparation requête moteur ; templates/prefill/reasoning/tool calls |
| `mmproj_use_gpu`, `mmproj_device`, `image_min_tokens/max_tokens`, `mtmd_batch_max_tokens`, `video_fps`, `video_timestamp_interval_ms`, `video_ffmpeg_bin_dir` | true/null/-1/-1/1024/4/5000/vide | Capacités modèle et prétraitement optionnel ; voir matrice formats |
| `sleep_idle_seconds`, `slot_save_path`, `media_path`, `path_prompts_log_dir` | -1, chemins vides ; accès filesystem explicite | Cycle de vie + politique IO moteur ; contrôles hôte conservés |
| `endpoint_metrics/props/slots` | false/false/true | Gardes d’accès HTTP ; le moteur expose opérations/statistiques |
| `port`, `hostnames`, `reuse_port`, `timeout_read/write`, `sse_ping_interval`, `n_threads_http`, `api_prefix`, `api_keys`, `ssl_file_key/cert`, `cors_*`, `public_path` | 8080/loopback/false/3600/3600/30/-1 ; autres defaults common.h | HTTP uniquement, aucune traduction dans config moteur |
| `ui`, `ui_config_json`, `ui_mcp_proxy`, `server_tools`, `server_tools_runtime`, `mcp_servers_config/json` | UI=true, proxy=false, listes/chaînes vides | Hôte uniquement |
| `server_base`, `system_prompt`, `prompt`, `image`, `multiline_input`, `out_file`, `show_timings`, `single_turn`, `verbosity`, `log_json` | chaînes vides, flags false sauf timings=true, verbosity=3 | CLI / logging hôte ; system/prompt/media deviennent JSON/pièces jointes |

### Priorités et paramètres mutables

- `common_params` → defaults spécifiques `common_params_parser_init` → options/env (`common_params_parse`) ; modèle : résolution `common_models_handler` puis sampling metadata uniquement si non explicite. Les marqueurs de sampling et fit doivent survivre à la traduction.
- Catalogue : `server_models::load_models` charge cache, répertoire et INI puis cascade avec preset global/options du routeur ; relire les conflits/règles exactes et établir des fixtures avant extraction P5. Cette priorité n’est pas encore vérifiée par un nouveau test.
- Requête : `server_task::params_from_json`/préparation dans `server-context.cpp`, `server-chat.cpp` ; inclut `id_slot`, `n`, `stream`, `cache_prompt`, `n_keep/n_discard`, stop, sampling, logprobs, grammaires, délais prompt/génération, `response_fields`, `return_tokens`, `return_progress`, LoRA, spéculation et contrôles reasoning. Ces paramètres ne sont pas tous des membres de common_params.
- Mutables : LoRA global/requête, contrôle reasoning actif, slots/caches, catalogue/résidence ; POST props est actuellement un no-op gardé. Ne pas inventer une mutation de defaults pendant cette extraction.
- Limite de l’inventaire : les recherches textuelles incluent plusieurs types nommés `params` ; elles ne prouvent pas seules l’exhaustivité sémantique. Audit final champ→traduction→test obligatoire en P5.

## P0 — Dépendances et états globaux

- `llama-common` lie PRIVATELY cpp-httplib mais cette dépendance reste transitive en statique. Sources HTTP : `download.cpp`, `hf-cache.cpp`; args/presets/résolution s’appellent mutuellement (`arg.cpp`, `preset.cpp`, `download.cpp`). Une simple suppression de target_link_libraries casserait les symboles.
- `common_init_from_params` est déjà local : charge `params.model.path`, fit, LoRA/control vectors, sampling metadata, pools et warmup. N’appelle pas la résolution réseau. Il appelle cependant `set_process_priority`; ne pas imposer cette politique à plusieurs moteurs sans audit P2.
- `common_init` modifie le callback global de logging ; `common_log_main`, verbosity/JSON/couleurs sont globaux. `hf_cache::get_cache_directory` mémorise un chemin statique issu de l’environnement au premier accès. Ne pas traiter ce cache implicite comme catalogue fourni par défaut au moteur.
- `server.cpp` : `shutdown_handler`, `is_terminating`, setlocale/signaux, init backend et free dans plusieurs branches de cleanup. `cli-server.h` réutilise ces chemins depuis un thread. P2 doit centraliser la durée de vie backend, pas ajouter un free par moteur.
- `src/llama.cpp::llama_backend_init/free` et registre ggml globaux ; callbacks de chargement et `server_context::callback_state` doivent avoir une durée de vie détenue par le moteur. Coexistence à tester.
- `server-stream.cpp::g_stream_sessions` singleton + GC : reste serveur. `server-models.cpp` : compteur SSE statique, registry conv→child, subprocess, ports, environnement, protocoles stdin/stdout ; disparaîtront pour l’inférence P6.
- `server-context` cible actuelle comprend HTTP headers, stream, tools et MCP ; ne peut pas être rebaptisée moteur. `test-chat` la lie aujourd’hui. La boucle/tasks/queues et préparation JSON devront être extraites avec directions de dépendances corrigées.
- `mtmd` ne doit jamais lier llama-common. `MTMD_VIDEO` utilise directement sheredom/subprocess pour ffmpeg/ffprobe. Sans subprocess, vidéo **et WebP** ne sont pas équivalents au profil desktop.

## P0 — Référence reproductible

Machine : Apple M1 Pro, 16 GiB RAM, macOS Darwin 25.6 arm64 (T6000), CMake Homebrew, Apple Clang/Xcode ; configure Release, backends CPU/BLAS Accelerate/Metal détectés, OpenSSL 3.6.1.

Commandes réellement exécutées :

```sh
git status --short
git rev-parse HEAD
cmake -S . -B build-agent-engine-baseline \
  -DLLAMA_BUILD_TESTS=ON -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
cmake --build build-agent-engine-baseline --parallel 2 \
  --target llama-server llama-cli test-chat test-json-schema-to-grammar test-sampling
.venv-server-tests/bin/python -m pytest --version
```

- Configure : **PASS** (`p0-configure.log`). Python pytest 8.3.5 disponible dans `.venv-server-tests`.
- Build : **PASS** (`p0-build.log`, `p0-build.exit=0`). UI précompilée téléchargée au build : ce profil n’est pas sans réseau.
- CTest : **PASS 3/3**, test-chat, test-json-schema-to-grammar, test-sampling (8,63 s, `p0-ctest.log`).
- Premier lancement HTTP direct : **BLOCKED** par filelock absent ; pytest-xdist, prérequis du wrapper tests.sh, était aussi absent. Installation de `pytest-xdist~=3.6` et `filelock~=3.16` dans le venv existant puis relance.
- HTTP ciblé CPU : **PASS 90**, **1 SKIP non qualifié** (`test_cache_vs_nocache_prompt`, décorateur préexistant « fails on linux »), 54,60 s. Ni les familles non sélectionnées ni les tests lourds ne sont validés par ce résultat.
- Fixtures GGUF locales repérées dans `tools/server/tests/tmp` : stories260K-f32, stories260K-infill, stories15M_MOE, bert-bge-small, jina-reranker-v1-tiny, tinygemma3-Q8_0 + mmproj. Les GGUF de `models/ggml-vocab-*` ne sont pas des modèles génératifs.
- Tests lourds (LoRA/draft/audio/autres modèles), vidéo/WebP, sanitizers, UI et iOS : **OUVERTS**, aucune qualification revendiquée.
- Tests pytest utilisent `LLAMA_SERVER_DEBUG_FAKE_TIMING=1` : les performances ci-dessous ont été mesurées séparément, sans ce flag.

Commandes de validation supplémentaires réellement exécutées :

```sh
ctest --test-dir build-agent-engine-baseline --output-on-failure \
  -R '^(test-chat|test-json-schema-to-grammar|test-sampling)$'
.venv-server-tests/bin/python -m pip install 'pytest-xdist~=3.6' 'filelock~=3.16'
PATH="$PWD/.venv-server-tests/bin:$PATH" \
  LLAMA_SERVER_BIN_PATH="$PWD/build-agent-engine-baseline/bin/llama-server" \
  N_GPU_LAYERS=0 PYTEST_WORKERS=1 ./tools/server/tests/tests.sh \
  unit/test_completion.py unit/test_chat_completion.py -m 'not slow' -v -x
MODEL="$PWD/tools/server/tests/tmp/models--ggml-org--test-model-stories260K/snapshots/479896ec924af6d40fd419ab8f4d1eb2101de00d/stories260K-f32.gguf"
python3 scripts/bench-server-baseline.py --server build-agent-engine-baseline/bin/llama-server \
  --model "$MODEL" --gpu-layers 0 --output build-agent-engine-evidence/p0-perf-cpu.json
python3 scripts/bench-server-baseline.py --server build-agent-engine-baseline/bin/llama-server \
  --model "$MODEL" --gpu-layers 99 --output build-agent-engine-evidence/p0-perf-metal.json
```

`bench-server-baseline.py` est un petit outil Unix de référence, **pas un moteur ni un test de conformité**. Il enregistre commande exacte, hash modèle, tous les échantillons, warmup et RSS maximale du processus serveur. Le binaire P0 non modifié a été utilisé avant son rebuild P1. Pas de compilation concomitante pendant les mesures.

Modèle stories260K F32 : SHA256 `270cba1bd5109f42d03350f60406024560464db173c0e387d91f0426d3bd256d`. Paramètres : CPU threads=2, batch threads=2, ctx=1024, slots=4, batch/ubatch=128, fit=off, cache RAM=0 ; prompt fixe, seed=42, température=0, ignore_eos, cache_prompt=false, 64 tokens, stream natif. Un warmup exclu des médianes, 3 répétitions à concurrence 1 puis 4. Chaque run vérifie la terminaison et 64 tokens, puis l’arrêt propre du serveur.

| P0 | Concurrence | Premier événement ms (médiane) | Prompt tokens/s par requête | Génération tokens/s par requête | Débit agrégé tokens/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPU ngl=0 | 1 | 1,29 | 40842 | 7160 | 6100 |
| CPU ngl=0 | 4 | 2,99 | 17980 | 2987 | 10288 |
| Metal ngl=99 | 1 | 3,09 | 12406 | 833 | 808 |
| Metal ngl=99 | 4 | 9,80 | 5371 | 592 | 2221 |

RSS maximale serveur : CPU 91 897 856 octets ; Metal 92 946 432 octets. **Ce n’est pas la mémoire des files d’événements**, qui reste à instrumenter en P2/P9. Modèle minuscule, mesures HTTP sensibles au bruit et au coût fixe GPU ; aucune généralisation aux modèles de production, ni seuil de non-régression revendiqué. Les logs serveur conservent l’offload effectif.

## P1 — Lot A : séparation des utilitaires locaux

Implémentation :

- Nouvelle cible `llama-common-local` : common/init/fit, sampling/spéculation/caches ngram, chat/templates/parsers/grammaires/JSON/logging, sans HTTP ni args/presets/subprocess.
- `llama-common` reste la cible de compatibilité pour les exécutables et délègue aux utilitaires locaux via un lien PUBLIC ; aucun algorithme dupliqué. Elle garde temporairement arg/console/download/hf-cache/preset/subproc et cpp-httplib.
- Nouvelle option `LLAMA_BUILD_COMMON_LOCAL=ON` pour construire les utilitaires lorsque `LLAMA_BUILD_COMMON=OFF`. Avec `LLAMA_BUILD_COMMON=ON`, les utilitaires locaux sont toujours construits. Pas encore d’option moteur/acquisition ni de header moteur : le lot ne prétend pas terminer P1/P2.
- Test `test-common-local` lié **uniquement** à llama-common-local, même en profil complet. Sans argument : schema + échec de chargement local ; avec chemin explicite : chargement/tokenisation/decode/sampling CPU réels, modèle manquant = échec et non skip.
- Tests locaux sélectionnés explicitement sans les helpers liés à llama-common. `test-chat` reste ouvert pour ce profil car il lie server-context ; aucun remplacement silencieux par un test moins large.
- Premier build local : **FAIL** sur test-jinja (son runner Python référençait common_subproc même sans `-py`). Corrigé : runner Python conditionné à LLAMA_SUBPROCESS, `-py` rejeté explicitement sinon ; les tests Jinja C++ restent dans le profil local. Aucun stub subprocess n’est ajouté au socle.

Commandes réellement exécutées (les deux répertoires locaux étaient neufs) :

```sh
cmake -S . -B build-agent-engine-local-static \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_COMMON_LOCAL=ON \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_TESTS=ON \
  -DLLAMA_SUBPROCESS=OFF -DLLAMA_OPENSSL=OFF -DGGML_METAL=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build build-agent-engine-local-static --parallel 2
cmake -S . -B build-agent-engine-local-static
cmake --build build-agent-engine-local-static --parallel 2
ctest --test-dir build-agent-engine-local-static --output-on-failure
build-agent-engine-local-static/bin/test-common-local "$MODEL"
cmake -S . -B build-agent-engine-local-shared \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_COMMON_LOCAL=ON \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
  -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_TESTS=ON \
  -DLLAMA_SUBPROCESS=OFF -DGGML_METAL=OFF -DBUILD_SHARED_LIBS=ON
cmake --build build-agent-engine-local-shared --parallel 2
cmake --build build-agent-engine-baseline --parallel 2 \
  --target llama-server llama-cli llama-app test-common-local test-chat \
  test-json-schema-to-grammar test-sampling test-model-resolution test-arg-parser
nm -u build-agent-engine-local-static/common/libllama-common-local.a
otool -L build-agent-engine-local-static/bin/test-common-local
```

Validation intermédiaire : statique build/12 tests/fixture réelle **PASS** avant réintégration de test-jinja. Validation finale A : statique **14/14 PASS**, partagé **14/14 PASS**, complet **7/7 PASS**, HTTP **90 PASS + 1 SKIP**, fixture CPU directe **PASS** en statique et partagé. Les 14 tests incluent le rejet explicite du runner Python non disponible, pas un test de parité Python. Build serveur/CLI/app et `llama-cli --version`, `llama --version` : **PASS**. Premier rebuild complet : les binaires ont été construits mais Make n’avait pas encore de règle pour le nouveau test-common-local ; reconfiguration CMake explicite puis rebuild : **PASS**. Jinja2 absent de Python au premier contrôle ; installation dans le venv puis `test-jinja-py` : **PASS** (27,81 s).

Attention aux sous-tests : Jinja C++ signale **10 SKIP préexistants**, non qualifiés : tojson sort_keys, tests escaped/filter, replace avec count, format avec numérotation/noms/accolades échappées, map avec filtre, min/max avec attribute. Le succès global CTest ne valide pas ces fonctionnalités. Contrôle Python de compile_commands et des `.o.d` actifs : pas de sources arg/console/download/hf-cache/preset/subproc/serveur, pas de flags/include cpp-httplib/OpenSSL/subprocess. `nm` : pas de symboles httplib/subproc/download/models_handler/preset/fork/spawn/socket/connect. `otool` consommateur statique : seulement libSystem, Accelerate, libc++. Partagé configuré avec **LLAMA_OPENSSL laissé ON** : aucun find_package OpenSSL n’est nécessaire puisque cpp-httplib n’est pas configuré. Vérification finale des deux profils : 135 unités compilées et tous leurs `.o.d`, sans exclusion de fichier résiduel, ne référencent ni HTTP ni subprocess. `otool` partagé : common-local/llama/ggml/CPU/BLAS/base + bibliothèques système uniquement.

Commandes finales A :

```sh
cmake -S . -B build-agent-engine-baseline
cmake --build build-agent-engine-baseline --parallel 2 \
  --target llama-server llama-cli llama-app test-common-local test-chat \
  test-json-schema-to-grammar test-sampling test-model-resolution test-arg-parser test-jinja
# Après la réintégration de Jinja, pour chacun des deux profils :
cmake -S . -B build-agent-engine-local-static
cmake --build build-agent-engine-local-static --parallel 2
ctest --test-dir build-agent-engine-local-static --output-on-failure
cmake -S . -B build-agent-engine-local-shared
cmake --build build-agent-engine-local-shared --parallel 2
ctest --test-dir build-agent-engine-local-shared --output-on-failure
ctest --test-dir build-agent-engine-baseline --output-on-failure \
  -R '^(test-common-local|test-chat|test-json-schema-to-grammar|test-sampling|test-model-resolution|test-arg-parser|test-jinja)$'
for PROFILE in static shared; do
  build-agent-engine-local-$PROFILE/bin/test-common-local "$MODEL"
done
.venv-server-tests/bin/python -m pip install Jinja2
PATH="$PWD/.venv-server-tests/bin:$PATH" ctest --test-dir build-agent-engine-baseline \
  --output-on-failure -R '^test-jinja-py$'
```

HTTP relancé avec la même commande P0 (`p1-http.log`, 39,41 s). Benchmark relancé avec les mêmes commandes P0 en remplaçant la sortie par `p1-perf-{cpu,metal}.json`.

| P1-A | Concurrence | Premier événement ms | Prompt tokens/s | Génération tokens/s | Débit agrégé tokens/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPU | 1 | 1,31 | 38869 | 7097 | 5988 |
| CPU | 4 | 3,40 | 21949 | 2846 | 10192 |
| Metal | 1 | 3,42 | 11677 | 875 | 843 |
| Metal | 4 | 7,68 | 6743 | 535 | 2029 |

RSS : CPU 91 439 104, Metal 93 306 880 octets. CPU débit agrégé médian -1,8%/-0,9% ; Metal +4,3%/-8,6%. **Qualification performance OUVERTE**, pas un PASS de non-régression : les 3 débits Metal concurrents P0 sont 2232/2221/2106, P1 2339/2029/1887, intervalles qui se chevauchent et variance importante. Aucun algorithme d’inférence changé dans ce lot ; approfondir sur séries longues/modèles représentatifs à P9 au lieu d’expliquer définitivement la baisse par le bruit.

À la fin du lot A, restaient notamment la cible moteur, mtmd et le cache/acquisition : les lots B/C ci-dessous les traitent. La traduction définitive des options et le catalogue/presets restent P2/P5 ; les helpers de sélection GGUF/cache encore dans download.cpp et la résolution dans arg.cpp sont explicitement à extraire avant de revendiquer une configuration/catalogue local complet.

## P1 — Lot B : cache local et acquisition optionnelle

- `common/hf-cache-local.cpp` contient uniquement le cache filesystem ; `hf-cache.cpp` ne contient plus que l’API HF distante. Validation/chemins partagés via le header privé `hf-cache-internal.h`. Vérification mécanique par comparaison de corps de fonctions avec HEAD : **22/22 inchangés**, après normalisation de la qualification `detail::`. Aucun nouvel algorithme ni seconde implémentation.
- Les fonctions locales `get_cached_files`, `get_cache_path`, `finalize_file`, `remove_cached_repo` sont désormais dans `llama-common-local`, sans HTTP. Les statiques de chemin et fallback symlink sont conservés, pas rendus artificiellement par-instance ; leur adaptation au catalogue explicite reste P5.
- Nouvelle cible `llama-common-acquisition` : download + HF distant, liens vers common-local et cpp-httplib, **aucune dépendance args/presets/subprocess/serveur**. Suppression de l’include arg.h inutilisé de download.cpp. L’agrégat llama-common la consomme.
- Nouvelle option `LLAMA_BUILD_COMMON_ACQUISITION=ON` permet de la construire sans llama-common/exécutables. Les builds complets la construisent pour préserver les options actuelles. Le profil sans acquisition ne configure toujours pas cpp-httplib.
- `test-hf-cache` ne lie que common-local : consultation sans écriture, finalisation, ref principale/fallback, filtrage, rejets de traversée, suppression explicite et préservation des fichiers voisins.
- `test-acquisition` ne lie que acquisition + cpp-httplib (fixture) : API HF contrôlée, modèle/sidecar, chemins/oid invalides, téléchargement/progression, annulation déterministe au callback et nettoyage du fichier incomplet, erreur 404, offline sans requête réseau. Pas d’Internet ni de processus enfant.
- Premier build du nouveau test : **FAIL**, initialisation JSON imbriquée non supportée par `common_json`. Corrigée en tableau explicite, sans changer la librairie. Retest ciblé complet : **4/4 PASS** (cache/acquisition/arg-parser/model-resolution). Rebuild et CTest local : **15/15 PASS** en statique et en partagé (les 10 skips internes Jinja restent ouverts).

Commandes B :

```sh
cmake -S . -B build-agent-engine-baseline
cmake --build build-agent-engine-baseline --parallel 2 \
  --target llama-server llama-cli test-model-resolution test-arg-parser test-common-local
cmake --build build-agent-engine-baseline --parallel 2 \
  --target test-acquisition test-hf-cache test-model-resolution test-arg-parser
ctest --test-dir build-agent-engine-baseline --output-on-failure \
  -R '^(test-hf-cache|test-acquisition|test-model-resolution|test-arg-parser)$'
# Reconfigure/build/CTest des profils local-static et local-shared comme en A.
cmake -S . -B build-agent-engine-acquisition \
  -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_COMMON_ACQUISITION=ON \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF \
  -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_TESTS=ON -DLLAMA_SUBPROCESS=OFF \
  -DLLAMA_OPENSSL=OFF -DGGML_METAL=OFF -DBUILD_SHARED_LIBS=OFF
cmake --build build-agent-engine-acquisition --parallel 2
```

Profil acquisition seul : **build PASS, CTest 16/16 PASS** (7,55 s ; les 10 skips internes Jinja restent ouverts). `nm -u` sur libllama-common-acquisition.a : pas de référence aux parseurs d’arguments, presets, common_models_handler, subprocess ou serveur. Restent les couches plus hautes de sélection des fichiers GGUF/cache (dans download.cpp), presets/résolution (dans arg.cpp) et qualification complète des options. P5 n’est pas déclaré réalisé par ces tests d’acquisition.

## P1 — Lot C finalisé : cible moteur et séparation transport/processus

### Implémenté

- Nouvelle option `LLAMA_BUILD_ENGINE=ON` pour construire `llama-engine` hors serveur/outils. Les consommateurs serveur/CLI complets l’activent implicitement. La cible contient du code réel déjà consommé par le serveur, pas un wrapper HTTP ni une cible vide.
- Déplacement vers `engine/` de `server-{common,chat,task,queue,schema}.{h,cpp}`. Les quatre sources chat/task/queue/schema sont **identiques octet pour octet** à HEAD ; common conserve les algorithmes mais perd le wire SSE et le subprocess. Noms internes historiques conservés pour limiter le bruit mécanique.
- SSE déplacé dans `tools/server/server-wire.*` ; IO des processus routeur dans `tools/server/server-process.*`. Comparaison avec HEAD : corps des fonctions SSE/processus **inchangés**. Processus/MCP/outils/stream registry/UI non liés par llama-engine.
- `uploaded_file`/`raw_buffer` déplacés dans un header interne indépendant d’HTTP (`engine/server-attachment.h`). Ce n’est pas encore le contrat public de pièces jointes possédées de P2.
- Seule variante de capacité ajoutée : médias HTTP(S) du profil sans acquisition rejetés explicitement (« Remote media requires network acquisition support »). Le profil complet réutilise le downloader original. Test direct dans test-chat, uniquement pour le profil sans acquisition ; la première compilation de ce test a échoué à cause d’un JSON const passé au helper mutable, puis a été corrigée et revalidée.
- mtmd ajouté **une seule fois à la racine**, avant les consommateurs, y compris bibliothèque seule. Aucune dépendance mtmd→common-local/common/acquisition ; ses CLI restent conditionnés aux outils **et** common.
- `test-chat` lie désormais llama-engine et ne lie plus server-context. Il est construit et exécuté dans le profil sans HTTP. README-dev serveur mis à jour : JSON/templates partagés hors boucle de décodage, HTTP garde les enveloppes et le replay.
- Les headers privés du moteur et leurs include dirs sont encore visibles pour l’adapter legacy. Leur visibilité n’est pas le contrat public final : réduire en P8 après introduction de `llama-engine.h` à P2.

### Validé

| Vérification | Résultat |
| --- | --- |
| Build complet serveur / CLI / app | PASS (`p1c-full-build.log`) |
| CTest complet ciblé : common-local, hf-cache, acquisition, chat, schema, sampling, arg-parser, model-resolution, Jinja | PASS 9/9 ; reconfigure/build serveur/CLI/app et retest final après toutes les modifications : PASS 9/9 (`p1c-final-build.log`, `p1c-final-tests.log`, 5,18 s), sans warning nouveau |
| Profil moteur CPU local statique neuf | PASS build + 16/16 CTest (`p1c-core-static-final-tests.log`) |
| Profil moteur CPU local partagé neuf | PASS build + 16/16 CTest (`p1c-core-shared-final-tests.log`) |
| Chargement/tokenisation/decode/sampling CPU via utilitaires, vrai stories260K | PASS statique et partagé (`p1c-core-*-model.log`) ; **pas** une validation du contrat moteur P2 |
| Absence de dépendance HTTP/processus/serveur dans les profils locaux | PASS, 194 unités par profil, compile_commands + tous les `.o.d` + nm/otool ; LLAMA_OPENSSL laissé ON mais pas de cpp-httplib configuré |
| mtmd indépendant | PASS graphe et otool ; aucun lien common, seulement llama/ggml et système |
| Test de capacité média distant sans acquisition | PASS dans test-chat local, erreur explicite et aucun fichier ajouté |
| Suite HTTP `not slow` complète | Premier essai BLOCKED au téléchargement LoRA (certificat urllib Python), après 170 PASS + 2 SKIP. Relance avec bundle certifi explicite, sans désactiver TLS : **374 PASS + 6 SKIP**, 785,99 s (`p1c-http-certifi.log`) |
| CLI legacy local : prompt, single-turn et sortie | PASS code 0 (`p1c-cli-smoke.log`) ; il démarre encore son serveur local, suppression P7 |
| CPU/Metal mono/concurrent + arrêt propre | PASS exécution du benchmark de référence ; **qualification de non-régression toujours OUVERTE** |

Les 6 skips HTTP sont **non qualifiés** : `test_cache_vs_nocache_prompt` (skip préexistant), `test_with_qwen_model` (slow), `test_with_big_model` LoRA (slow), `test_tools_builtin_runtime_header[docker]`, `[podman]`, `test_tools_builtin_docker_runtime_cleans_up_spawned_container` (environnements externes indisponibles). Les 10 sous-cas Jinja C++ listés en A restent également ignorés. Les autres tests marqués slow sont exclus par la sélection, pas passés. La suite effectuée couvre notamment routeur, SSE/reprise, sommeil, slots multimodaux, LoRA petit modèle, spéculation, métriques, sécurité, outils et MCP ; cela protège les chemins existants, **pas** un cycle de vie moteur multi-modèles encore inexistant.

### Commandes C réellement exécutées

```sh
cmake -S . -B build-agent-engine-baseline
cmake --build build-agent-engine-baseline --parallel 2 \
  --target llama-server llama-cli llama-app test-chat
# Deux profils neufs ; SHARED règle BUILD_SHARED_LIBS :
for PROFILE in static shared; do
  if [ "$PROFILE" = static ]; then SHARED=OFF; else SHARED=ON; fi
  cmake -S . -B build-agent-engine-core-$PROFILE \
    -DLLAMA_BUILD_ENGINE=ON -DLLAMA_BUILD_COMMON=OFF \
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_TESTS=ON \
    -DLLAMA_SUBPROCESS=OFF -DGGML_METAL=OFF -DBUILD_SHARED_LIBS=$SHARED
  cmake --build build-agent-engine-core-$PROFILE --parallel 2
  ctest --test-dir build-agent-engine-core-$PROFILE --output-on-failure
  build-agent-engine-core-$PROFILE/bin/test-common-local "$MODEL"
done
ctest --test-dir build-agent-engine-baseline --output-on-failure \
  -R '^(test-common-local|test-hf-cache|test-acquisition|test-chat|test-json-schema-to-grammar|test-sampling|test-model-resolution|test-arg-parser|test-jinja)$'
PATH="$PWD/.venv-server-tests/bin:$PATH" \
  SSL_CERT_FILE="$(.venv-server-tests/bin/python -c 'import certifi; print(certifi.where())')" \
  LLAMA_SERVER_BIN_PATH="$PWD/build-agent-engine-baseline/bin/llama-server" \
  N_GPU_LAYERS=0 PYTEST_WORKERS=1 ./tools/server/tests/tests.sh -m 'not slow' -v -x
nm -u build-agent-engine-core-static/engine/libllama-engine.a
nm -u build-agent-engine-core-shared/bin/libllama-engine.dylib
otool -L build-agent-engine-core-shared/bin/libllama-engine.dylib \
  build-agent-engine-core-shared/bin/libmtmd.dylib
build-agent-engine-baseline/bin/llama-cli -m "$MODEL" --offline \
  -ngl 0 -t 2 -tb 2 -c 256 -np 1 -n 8 --single-turn -p 'Once upon a time'
```

Après ajout du test média : reconfigure, rebuild test-chat, CTest des deux profils réexécutés ; 16/16 chacun. Contrôle sources/includes : ni arg/console/download/hf-cache distant/preset/subproc/serveur ni flags cpp-httplib/OpenSSL/LLAMA_SUBPROCESS/MTMD_VIDEO. `LLAMA_BUILD_COMMON=OFF`, `LLAMA_BUILD_COMMON_ACQUISITION=OFF`, `LLAMA_SUBPROCESS=OFF`, `MTMD_VIDEO=OFF`, `LLAMA_OPENSSL=ON` vérifiés dans les deux caches. `nm` : aucune référence HTTP/subprocess/résolution exécutable. `otool` llama-engine : common-local, mtmd, llama, ggml, CPU, BLAS, base, système uniquement.

### Performance C : signal à investiguer, pas effacé

Même benchmark/modèle/paramètres que P0, sorties `p1c-perf-{cpu,metal}.json`, 3 répétitions :

| P1-C | Concurrence | Premier événement ms | Prompt tokens/s | Génération tokens/s | Débit agrégé tokens/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| CPU | 1 | 1,50 | 41147 | 6602 | 4986 |
| CPU | 4 | 3,09 | 24517 | 2631 | 9152 |
| Metal | 1 | 2,90 | 16004 | 1108 | 1046 |
| Metal | 4 | 8,29 | 7969 | 605 | 2238 |

RSS maximale CPU 90 914 816, Metal 93 274 112 octets. La baisse CPU agrégée vs P0 (~18% mono / 11% concurrent) a motivé une série supplémentaire **15 répétitions**, commande identique avec `--repeats 15 --output build-agent-engine-evidence/p1c-perf-cpu-15.json` : médianes 5881 / 9411 tokens/s, premiers événements 1,31 / 3,28 ms, plages de débit 1653–6664 / 8827–10238. Le signal concurrent (~8,5% sous la petite référence P0) n’est pas levé. Faire une comparaison A/B de séries longues sur le commit P0 et cette version, hôte au repos et modèle représentatif, avant de qualifier la performance. Aucun objectif bit-à-bit ajouté ; aucun résultat défavorable retiré.

## Façades temporaires et dette de migration

| Élément | Rôle actuel | Échéance |
| --- | --- | --- |
| `llama-common` | Agrégat args/presets/subprocess qui lie local + acquisition ; pas de copies de code | Les autres outils peuvent le conserver ; inférence serveur/CLI quitte cet agrégat P6/P7 |
| `tools/server/server-{common,chat,task,queue,schema}.h` | Cinq includes de compatibilité vers engine, zéro implémentation | P8 |
| Noms internes server_* et include dirs privés exportés temporairement par llama-engine | Adapter existant et tests internes utilisent encore les types historiques ; API publique P2 disponible séparément | Migration P3, nettoyage P8 |
| `server-process.*` et routeur/proxy enfants | Comportement desktop conservé, désormais hors cible moteur | P6/P8 |
| `tools/server/server-context.cpp` et accesseurs privés `engine/engine-context.h` | Handlers restants, snapshots référencés et lecteurs legacy ; décodeur extrait et natif migré à P2 | P3/P8 |
| `server-task.cpp::to_metrics`, champs legacy SSE/config UI/HTTP | Restes de responsabilités à séparer sémantiquement ; pas de dépendance réseau nécessaire dans le profil local | P3/P6/P8 |
| `download.cpp` helpers cache/sélection, `arg.cpp` résolution, `preset.cpp` cascades | Réutilisés, pas encore disponibles comme catalogue local autonome | P5 ; auditer avant intégration de chargement P2 |
| `server_lru_sched` (routeur) | Adaptateur des enfants du routeur vers la politique partagée `llama_engine::detail::load_queue` ; aucune copie de l’algorithme | P6 (suppression avec le routeur de processus) |
| `server_models::ensure_model_ready` (routeur) | Boucle d’attente du routeur, par sondage 200 ms, sans délai ; l’attente bornée du moteur est dans `model_manager` | P6 |

Aucune façade appelant le serveur depuis un moteur n’a été ajoutée. Un seul exemplaire de chaque algorithme extrait. Les suppressions `.cpp` dans tools/server sont des **déplacements vers engine non encore suivis par Git**, pas des fonctionnalités supprimées.

## P2 — Tranche verticale mono-modèle finalisée

### Vérification préalable de P0/P1

- Reprise sur `642c8ea7b` (`engine : prepare local inference build graph`), arbre propre au démarrage : les travaux P0/P1 avaient été commités. Les mentions de fichiers non suivis des lots historiques décrivent leur état à cette époque.
- P0 : matrices opérations/configuration, références de build/tests, fixtures et résultats CPU/Metal présents. Les réserves de performance, formats et configuration publique finale ne sont pas reclassées en PASS.
- P1 : relecture du graphe local/acquisition/mtmd/moteur et des interfaces de compatibilité. Revalidation avant modification : **16/16 CTest statique**, **16/16 partagé**, **9/9 C++ complet ciblé**. Les consommateurs et profils existent réellement.
- Aucun besoin d’une nouvelle architecture ou d’un arbitrage de périmètre pour P2. Aucun sous-agent, commit, staging ou publication automatique.

### Implémentation livrée

- `include/llama-engine.h` : `llama_engine::engine`, configuration propre, `request`, événements JSON publics `nlohmann::json`, pièces jointes possédées et contrats de durée de vie. Guide : [API P2](embedded-inference-engine-api.md). `tests/test-engine.cpp` ne comprend que le header public et les headers standard, et lie uniquement `llama-engine`.
- Déplacement de l’unique décodeur dans `engine/engine-context.cpp`, avec son header privé. Comparaison mécanique avec HEAD : **3339 lignes non vides identiques** dans les algorithmes du décodeur après exclusion des deux setters globaux de logging retirés et de l’acquittement d’annulation ajouté. Batching, sampling, spéculation, cache et slots réutilisés.
- Les anciens handlers restent dans `tools/server/server-context.cpp`. Ils utilisent des accesseurs privés transitoires ; aucune dépendance `engine → server`. La préparation completion/infill est extraite une seule fois dans `server_context::prepare_completion`, utilisée aussi par les formats legacy.
- `engine/llama-engine.cpp` possède création/chargement, préparation sérialisée, lecture/conversion hors décodeur, annulation, arrêt et libération du modèle. Le runtime privé possède le thread décodeur et conserve le worker de l’ordonnanceur. Le `start_loop()` legacy démarre/attend ce thread ; il ne décode plus sur le thread appelant. L’API publique n’a aucune boucle à fournir.
- `/completion` et `/completions` délèguent à **la même soumission et au même objet requête** que le consommateur public. L’adapter HTTP garde SSE, statut, keep-alives, déconnexion et la gestion existante de sa réponse ; aucune conversion JSON d’inférence n’est copiée dans un deuxième moteur.
- Les requêtes natives utilisent des sinks vers une file bornée de résultats bruts. Elles ne passent jamais par le buffer legacy `queue_results`. `max_tasks` borne les admissions, enfants inclus ; les réservations restent présentes pendant l’annulation jusqu’à son acquittement par le décodeur, y compris si un résultat final arrive entretemps. Les annulations sont coalescées. La file d’événements est bornée par `max_events`, l’entrée par `max_request_bytes`.
- L’issue terminale est séparée du dernier payload métier et de la file : saturation observable (`queue_full`), sans bloquer les autres requêtes. Succès/erreur/annulation sont exclusifs ; les appels ultérieurs renvoient la même issue. Les handles survivent à l’arrêt/destruction. La destruction d’un handle annule ; l’arrêt réveille les lecteurs puis attend les threads. La durée d’un appel backend en cours reste coopérative.
- Préparation native protégée contre l’entrée en sommeil par un pin de contexte. Le démarrage du décodeur legacy reste après la création des métadonnées initiales. Correction de la course arrêt-avant-démarrage (l’entrée de boucle ne remet plus `running=true`) et protection de l’initialisation de l’horloge de file.
- Initialisation backends commune par `call_once`, sans libération par instance des tables de quantification globales. Les anciens `llama_backend_free()` du serveur sont retirés : ils pouvaient affecter un autre moteur. Les modèles/contextes sont libérés à l’arrêt du moteur public. Logging global, signaux, NUMA et priorité processus ne sont pas imposés par le moteur.
- Conversion des résultats avec remplacement des octets UTF-8 invalides, comme l’ancien transport. Un payload null conserve le signal natif de début de génération ; HTTP envoie alors les headers, pas `data: null`.

### Validation réellement exécutée

| Vérification | Résultat / preuve locale |
| --- | --- |
| Build final serveur, CLI, app et tests ciblés | **PASS**, `p2-final-build-full.log`, aucun warning nouveau |
| C++ complet ciblé avec nouveaux tests | **11/11 PASS**, `p2-final-tests-full.log` |
| CPU local statique, CTest incluant vrai GGUF | **19/19 PASS**, `p2-final-tests-core-static.log` |
| CPU local partagé, CTest incluant vrai GGUF | **19/19 PASS**, `p2-final-tests-core-shared.log` |
| Configuration invalide, modèle absent et GGUF corrompu | **PASS**, test-engine dans les profils ci-dessus |
| Completion complète/streamée, dernier payload, prompts en lot et `n=2` | **PASS**, test-engine-model ; stories260K F32 local, GPU layers=0, threads=2, ctx=512 |
| Abandon, annulation active/en attente, arrêt, lecteur réveillé, handles survivants, moteur après arrêt | **PASS**, tests directs et double décodeur synchronisé |
| Saturation puis seconde requête, erreur terminale réservée, admission pleine | **PASS**, injections synchronisées sans modèle + intégration réelle sans sommeil arbitraire |
| Courses fin/annulation/arrêt, arrêt avant entrée de boucle, instances répétées | **PASS**, 100 courses contrôlées et 8 cycles avec vrai modèle par exécution |
| Deux moteurs, arrêt du premier puis inférence du second | **PASS**, test-engine-model |
| ASan + UBSan instrumentant llama et ggml, erreurs/cycle de vie/vrai modèle | **3/3 PASS**, `p2-final-tests-p2-sanitize.log`, UBSan en halt-on-error |
| Sources/includes/liens locaux sans HTTP/OpenSSL/subprocess | **PASS**, 198 unités dans chaque profil, compile_commands + `.o.d`, `nm -u`, `otool -L` ; aucune dépendance interdite |
| HTTP natif/OpenAI/chat/sommeil/slots/replay/basic, sélection `not slow` | **114 PASS, 1 SKIP**, 74,97 s, `p2-http-final.log` |
| CLI legacy local single-turn et arrêt | **PASS**, code 0, `p2-cli-smoke.log` ; le serveur local du CLI reste à supprimer en P7 |
| Extraction mécanique, whitespace | **PASS**, comparaison décrite ci-dessus et `git diff --check` |

Le SKIP HTTP est `test_cache_vs_nocache_prompt`, préexistant, **non qualifié**. Les tests `slow` exclus ne sont pas passés. Les dix sous-cas Jinja ignorés à P1 restent ouverts. Aucun nouveau benchmark de non-régression CPU/Metal n’est revendiqué ; le signal P1 reste ouvert. Pas de qualification P2 spécifique Metal, Windows/Linux/iOS ou TSan. LeakSanitizer est **BLOCKED** sur cet hôte macOS : `detect_leaks=1` est refusé par le runtime, pas une fuite détectée ni une validation de fuite.

### Échecs intermédiaires et corrections

- Premier appel de build des nouveaux targets avant reconfiguration : cible inconnue ; reconfiguration puis build réussi.
- Premier test direct : `value()` appliqué au payload natif null de début de génération ; test et adaptation HTTP corrigés pour conserver ce signal.
- Premier HTTP : `data: null` et arrêt du serveur attendant une jointure déjà détenue par son thread principal. Séparation demande d’arrêt / jointure et correction du premier fragment. Retest final : pas de serveur forcé à terminer.
- Une tentative sans filtre `not slow` a buté sur le modèle Phi-3.5 absent en mode offline après 7 tests réussis. Ce cas reste **BLOCKED fixture**, pas couvert par le filtre final.
- Premier ASan avec `detect_leaks=1` : trois aborts avant les tests, runtime macOS non compatible. Relance avec `detect_leaks=0` : ASan/UBSan **PASS**, détection de fuites explicitement non qualifiée (`p2-sanitize-leaks-unsupported.log`).

### Commandes P2 reproductibles

Depuis la racine, avec la fixture déjà utilisée à P0/P1 :

```sh
MODEL="$PWD/tools/server/tests/tmp/models--ggml-org--test-model-stories260K/snapshots/479896ec924af6d40fd419ab8f4d1eb2101de00d/stories260K-f32.gguf"
# Profils locaux déjà configurés selon P1 ; ajouter le test réel explicitement :
cmake -S . -B build-agent-engine-core-static -DLLAMA_ENGINE_TEST_MODEL="$MODEL"
cmake -S . -B build-agent-engine-core-shared -DLLAMA_ENGINE_TEST_MODEL="$MODEL"
cmake --build build-agent-engine-core-static --parallel 2
cmake --build build-agent-engine-core-shared --parallel 2
ctest --test-dir build-agent-engine-core-static --output-on-failure
ctest --test-dir build-agent-engine-core-shared --output-on-failure
# Sans LLAMA_ENGINE_TEST_MODEL, le test sans modèle ne prétend pas qualifier l’inférence.
# Le consommateur peut aussi être lancé directement :
build-agent-engine-core-static/bin/test-engine "$MODEL"

cmake --build build-agent-engine-baseline --parallel 2 \
  --target llama-server llama-cli llama-app test-engine test-engine-lifecycle \
  test-chat test-common-local test-hf-cache test-acquisition \
  test-json-schema-to-grammar test-sampling test-model-resolution test-arg-parser test-jinja
ctest --test-dir build-agent-engine-baseline --output-on-failure \
  -R '^(test-engine|test-engine-lifecycle|test-common-local|test-hf-cache|test-acquisition|test-chat|test-json-schema-to-grammar|test-sampling|test-model-resolution|test-arg-parser|test-jinja)$'
PATH="$PWD/.venv-server-tests/bin:$PATH" \
  SSL_CERT_FILE="$(.venv-server-tests/bin/python -c 'import certifi; print(certifi.where())')" \
  LLAMA_SERVER_BIN_PATH="$PWD/build-agent-engine-baseline/bin/llama-server" \
  N_GPU_LAYERS=0 PYTEST_WORKERS=1 ./tools/server/tests/tests.sh \
  unit/test_completion.py unit/test_sleep.py unit/test_chat_completion.py \
  unit/test_slot_save.py unit/test_stream.py unit/test_basic.py -m 'not slow' -v -x
build-agent-engine-baseline/bin/llama-cli -m "$MODEL" --offline \
  -ngl 0 -t 2 -tb 2 -c 256 -np 1 -n 8 --single-turn -p 'Once upon a time'

cmake -S . -B build-agent-engine-p2-sanitize \
  -DLLAMA_BUILD_ENGINE=ON -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_TESTS=ON -DLLAMA_SUBPROCESS=OFF -DGGML_METAL=OFF \
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Debug \
  -DLLAMA_SANITIZE_ADDRESS=ON -DLLAMA_SANITIZE_UNDEFINED=ON \
  -DGGML_SANITIZE_ADDRESS=ON -DGGML_SANITIZE_UNDEFINED=ON \
  -DLLAMA_ENGINE_TEST_MODEL="$MODEL"
cmake --build build-agent-engine-p2-sanitize --parallel 3 --target test-engine test-engine-lifecycle
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 \
  ctest --test-dir build-agent-engine-p2-sanitize --output-on-failure \
  -R '^(test-engine|test-engine-lifecycle|test-engine-model)$'
```

### Limites conservées et prochaines extractions

- P2 expose la completion native, pas tous les contrats du design. Les réglages publics de chargement sont un premier sous-ensemble explicite ; tous les réglages legacy restent disponibles par l’adapter interne. P5 doit terminer la traduction de la matrice sans abandonner de champs.
- Les pièces jointes nommées sont prévues et possédées mais refusées pour cette opération ; la completion native conserve `multimodal_data`. Leur consommation pour chat/transcription appartient à P3. Pas de promesse de formats vidéo/WebP sans prétraitement externe.
- Les chemins **non migrés** ont encore `server_response_reader`, ses files legacy et leurs comportements d’arrêt historiques. Les garanties de bornes et d’issues terminales nouvelles s’appliquent au chemin natif migré ; P3 doit les généraliser, pas les présenter comme déjà universelles.
- Les snapshots legacy contiennent encore une référence à `chat_params`, et les getters de contexte sont des interfaces privées temporaires. P3 doit les remplacer par des instantanés possédés sans réveil involontaire.
- Le réveil legacy qui échoue contient encore un `GGML_ABORT` : P4 doit le remplacer par un état d’échec récupérable. Le moteur public P2 n’active pas de sommeil automatique. Les assertions fatales natives restantes sont conservées, conformément aux limites du design.
- Les capacités desktop du routeur, du CLI et des outils ne sont pas réécrites par P2. La suppression des processus d’inférence reste P6/P7 ; Swift demeure hors périmètre.

## P2 — Correctif de revue : parité HTTP avec upstream

### Constat

Le runtime créé par `server.cpp` gardait les valeurs par défaut de `llama_engine::config` (`max_tasks=64`, `max_events=256`, `max_request_bytes=16 MiB`), non configurables côté serveur et non documentées comme écart. Mesure avec `llama-server -np 1` et 80 requêtes simultanées de 32 tokens : `/completion` **65 × 200 et 15 × 500** (« Engine task limit reached »), tandis que le chemin legacy `/v1/completions` répondait **80 × 200**. Avant P2, `/completion` mettait ces requêtes en file sans limite. Le critère P2 « le handler HTTP migré passe ses tests existants » était satisfait, mais le comportement n’était pas préservé : **FAIL** de compatibilité, non détecté par les suites existantes. Un lecteur SSE lent pouvait aussi atteindre `max_events=256` ; ce cas n’a pas été reproduit sur cet hôte, car les buffers socket loopback ont absorbé 2047 événements.

### Correctif

- `llama_engine::detail::apply_http_compat_limits(runtime &)` (`engine/engine-runtime.h`, `engine/llama-engine.cpp`) rend explicites les limites de l’adapter HTTP : admissions, événements et taille des requêtes sans borne, comme avant P2. La taille des corps reste gouvernée par la couche HTTP. `server.cpp` l’applique à la construction du contexte, avant tout handler ou démarrage du décodeur ; le serveur local du CLI legacy passe par le même chemin.
- **L’API publique garde ses bornes par défaut** (`engine::create` remplace les limites par `config`). Aucun changement de l’ordonnanceur ni des sinks.
- Quand `max_request_bytes` n’est pas borné, `submit` ne resérialise plus le JSON d’entrée juste pour le mesurer.

### Décision (29 septembre 2026)

Consigne : se rapprocher au plus près d’upstream ; une ré-architecture ne doit introduire **aucune régression**. En conséquence :

- Le serveur garde la sémantique upstream : admissions en file sans limite, résultats bufferisés sans limite, taille des corps gouvernée par HTTP. `apply_http_compat_limits` n’est plus une façade provisoire mais la configuration **définitive** de l’instance serveur. Aucune option serveur nouvelle n’est ajoutée.
- Les bornes (`max_tasks`, `max_events`, `max_request_bytes`) restent les défauts de l’API embarquée, configurables par instance. Design, ADR et guide API mis à jour en ce sens.
- Le handler `/completion` doit être **identique à upstream** sur le fil (statuts, types de contenu, messages d’erreur, ordre des champs, SSE, keep-alives). Cette exigence vaut pour chaque handler migré en P3.

### Régressions supplémentaires trouvées par comparaison avec upstream, et corrigées

| Écart | Correction |
| --- | --- |
| Ordre des champs JSON (`nlohmann::json` trie les clés) | `llama_engine::json` = `nlohmann::ordered_json` ; le chemin HTTP ne passe plus par le type public |
| Deux sérialisations + deux parsings supplémentaires par événement streamé, et une conversion supplémentaire du corps de requête | `request_state::read_native` et `detail::submit_native` : l’adapter HTTP parse le corps une fois et sérialise chaque résultat natif une fois, comme upstream |
| Préparation (tokenisation, médias) sérialisée sous le verrou du runtime ; les annulations attendaient une préparation longue | Préparation hors verrou, en parallèle sur les threads appelants comme upstream ; compteur `preparing` attendu par `stop()` avant la libération du contexte |
| Messages d’erreur différents : `"stream": "yes"` (message sans préfixe `Field 'stream':`) et corps non-objet (`Expected a JSON object`) | Validation déléguée au schéma de tâche existant ; `stream` lu depuis les paramètres validés de la tâche |
| `body.value(...)` pouvait lever avant la soumission (500 au lieu de 400) | `stream` issu de la tâche, `sse_ping_interval` via `json_value` comme upstream |
| Pas de `try/catch` dans le générateur SSE | Rétabli, même format d’erreur qu’upstream |
| Ligne sans effet dans `server_response::send` | Supprimée |

Le handler reproduit désormais la structure d’upstream : premier résultat hors flux (erreur → réponse non streamée), `data: ""` pour le signal de début, polling `HTTP_POLLING_SECONDS`, keep-alive `:\n\n` après `sse_ping_interval`, fin de flux native sans `[DONE]`, annulation à la déconnexion.

### Validation réellement exécutée

| Vérification | Résultat |
| --- | --- |
| Comparaison différentielle `scripts/diff-server-completion.py`, serveur upstream `e4c142c` compilé dans un worktree contre le serveur moteur, 32 cas (`/completion`, `/completions`, stream, lots, `n=2`, tokens, `n_probs`, stop, `response_fields`, `id_slot`, grammaire, JSON schema, `multimodal_data`, `n_predict=0`, erreurs de type/forme/JSON) | **32/32 identiques** : statut, type de contenu, corps et ordre des champs, champs de timing/id masqués. Avant ces corrections : 30/32 |
| Nouveau test HTTP `test_completion_queues_many_concurrent_requests` sur le binaire **sans** correctif | **FAIL attendu**, 500 « Engine task limit reached » |
| Même test avec correctif, 6 exécutions | **PASS** 6/6, synchronisé sur `llamacpp:requests_deferred` |
| Sonde 80 requêtes simultanées, `-np 1` | `/completion` 80 × 200, `/v1/completions` 80 × 200 |
| Suite HTTP complète `not slow` | **375 PASS, 6 SKIP** (P1 : 374 + 6 ; +1 = nouveau test). Même nombre de skips, liste non réexaminée individuellement |
| Build serveur/CLI/app + 12 tests C++ ciblés | **PASS** 12/12, aucun warning |
| Profil local statique neuf (sans HTTP, vrai GGUF) | **PASS** 19/19 ; audit compile_commands/`nm -u` sans HTTP/subprocess |
| Profil local partagé (avec `LLAMA_ENGINE_TEST_MODEL`) | **PASS** 19/19 ; `otool -L` sans dépendance interdite |
| Nouveau test : soumissions concurrentes sur 4 threads pendant `stop()` (4 tours) | **PASS**, 30 exécutions consécutives |
| `test-engine-model` + `test-engine-lifecycle` répétés 50 fois | **PASS** 100/100 |
| ASan + UBSan (`detect_leaks=0`, halt-on-error) | **PASS** 3/3 |
| **TSan** (nouveau profil Debug, moteur seul, OpenMP off) | **PASS** 3/3 + 3 exécutions supplémentaires de `test-engine` : **0 rapport** |
| `test-engine-lifecycle` : défauts publics bornés, 1000 sinks et 1000 événements sans `queue_full` après `apply_http_compat_limits` | **PASS** |
| `git diff --check` | **PASS** |

LeakSanitizer reste **BLOCKED** sur macOS. Metal, Linux/Windows/iOS non qualifiés.

### Performance A/B contre upstream (CPU)

Même hôte au repos, binaires upstream `e4c142c` et moteur alternés (upstream, moteur) × 3 tours, `bench-server-baseline.py --gpu-layers 0 --repeats 5`, soit 15 échantillons par configuration. Même modèle et paramètres qu’à P0.

| Binaire | Concurrence | Débit agrégé médian tok/s [min–max] | Premier événement ms (méd.) | Génération tok/s par requête (méd.) | RSS max |
| --- | ---: | ---: | ---: | ---: | ---: |
| upstream | 1 | 5791 [4326–6212] | 1,41 | 6931 | 92 553 216 |
| moteur | 1 | 5584 [4517–6514] | 1,44 | 6941 | 92 372 992 |
| upstream | 4 | 9459 [7176–10051] | 3,47 | 2760 | 92 553 216 |
| moteur | 4 | 9903 [8076–11036] | 3,38 | 2855 | 92 372 992 |

Débit de génération, premier événement et RSS équivalents ; débit agrégé −3,6 % en mono et +4,7 % en concurrent, avec des plages qui se recouvrent largement. **Pas de régression détectée à cette résolution** ; le signal P1-C (mesuré contre des références non alternées) n’est pas reproduit en A/B alterné. Modèle minuscule : la qualification sur modèle représentatif et Metal reste à P9.

### Commandes

```sh
MODEL="$PWD/tools/server/tests/tmp/models--ggml-org--test-model-stories260K/snapshots/479896ec924af6d40fd419ab8f4d1eb2101de00d/stories260K-f32.gguf"
cmake -S . -B build-agent-engine-baseline -DLLAMA_ENGINE_TEST_MODEL="$MODEL"
cmake --build build-agent-engine-baseline --parallel 8 \
  --target llama-server llama-cli llama-app test-engine test-engine-lifecycle \
  test-chat test-common-local test-hf-cache test-acquisition \
  test-json-schema-to-grammar test-sampling test-model-resolution test-arg-parser test-jinja
ctest --test-dir build-agent-engine-baseline --output-on-failure \
  -R '^(test-engine|test-engine-lifecycle|test-engine-model|test-common-local|test-hf-cache|test-acquisition|test-chat|test-json-schema-to-grammar|test-sampling|test-model-resolution|test-arg-parser|test-jinja)$'
# Profil local statique neuf : mêmes options que P1-C, plus -DLLAMA_ENGINE_TEST_MODEL="$MODEL" et -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
PATH="$PWD/.venv-server-tests/bin:$PATH" \
  SSL_CERT_FILE="$(.venv-server-tests/bin/python -c 'import certifi; print(certifi.where())')" \
  LLAMA_SERVER_BIN_PATH="$PWD/build-agent-engine-baseline/bin/llama-server" \
  N_GPU_LAYERS=0 PYTEST_WORKERS=1 ./tools/server/tests/tests.sh \
  unit/test_completion.py unit/test_sleep.py unit/test_chat_completion.py unit/test_slot_save.py \
  unit/test_stream.py unit/test_basic.py unit/test_infill.py unit/test_security.py unit/test_metrics.py \
  -m 'not slow' -q
```

## Consignes de reprise P3 (historiques, exécutées ci-dessous)

1. Lire le plan, le design/ADR, ce journal et le guide API. P2 est finalisé ; **ne pas recommencer l’extraction du décodeur ni créer un second moteur**. P2 est dans `da40e15ae` ; le correctif de revue (parité HTTP) peut être encore non commité. **Règle** : aucun handler migré ne doit changer le comportement observable. Tout runtime utilisé par HTTP reçoit `apply_http_compat_limits` ; les adapters HTTP lisent via `read_native`/`submit_native`. Étendre `scripts/diff-server-completion.py` à chaque famille migrée et exiger l’identité contre `e4c142c`.
2. Revalider les trois tests moteur (`test-engine`, `test-engine-lifecycle`, `test-engine-model`) et les tests HTTP ciblés. `LLAMA_ENGINE_TEST_MODEL` doit désigner un vrai GGUF ; l’absence de fixture ne vaut pas PASS. Les logs P0/P1/P2 sont sous `build-agent-engine-evidence/`, ignoré par Git.
3. Premier lot P3 : migrer `/v1/completions` et infill en réutilisant `prepare_completion`, puis chat avec templates/tools/sorties structurées. Généraliser les opérations du runtime et la conversion sémantique par requête ; conserver les réservations d’admission, bornes, payload final et terminal séparés. Chaque handler doit déléguer dès que son opération est disponible.
4. Raccorder Responses/Anthropic aux événements sémantiques, **sans SSE dans le moteur**. Garder les keep-alives HTTP même pendant attente, les fragments incrémentaux de reasoning/tool calls et les erreurs avant/après headers. Les états de conversion `task_result_state` restent côté lecture.
5. Migrer ensuite embeddings/rerank, tokenisation/templates/comptage, audio/multimodal avec pièces jointes possédées, contrôle/slots/LoRA/propriétés/statistiques. Faire disparaître progressivement les accesseurs et lecteurs legacy ; mettre à jour chaque ligne de la matrice P0 avec test direct et test HTTP correspondant.
6. Laisser reprise/replay/rétention/lookup/DELETE chez le serveur : il doit posséder et drainer la requête, sans reconstruire une file moteur illimitée. Tester déconnexion/reconnexion, offset perdu, remplacement de session, Stop pendant drainage et arrêt du serveur pendant replay.
7. Terminer P3 avec snapshots indépendants des contextes/sommeil, tests de familles et vérification du profil local sans HTTP. P4 reste le cycle de vie multi-modèles ; ne pas le confondre avec le routeur actuel. P5 reste catalogue/configuration/acquisition ; P6/P7 les bascules routeur/CLI.
8. Garder les réserves de performance P1, TSan/LeakSanitizer, autres plateformes et formats absents visibles jusqu’à leur qualification. La suite complète P9 n’est pas annoncée comme exécutée par les tests ciblés P2.


## P3 — Contrats mono-modèle et streaming

### Implémentation

- `engine/engine-operations.{h,cpp}` contient la préparation extraite des handlers : chat/templates/tools/structured output, Responses, Anthropic, completion OpenAI, infill, transcription, embeddings, rerank, tokenisation/comptage, contrôle, slots, LoRA et snapshots. Les helpers et algorithmes historiques sont réutilisés ; aucune deuxième boucle d’inférence.
- `engine::submit(operation, json, attachments)` expose ces familles. `completion()` reste compatible. Les derniers payloads métier et l’issue terminale restent distincts ; l’assemblage non streamé (`choices`, embeddings, rerank) est partagé entre lecteurs directs et HTTP. Les conversions incrémentales sont effectuées sur le lecteur, jamais dans le décodeur.
- `server_routes::handle_operation` est l’unique adapter de ces requêtes. Plus de `server_response_reader`, tokenisation, parsing de chat ou construction de tâches dans les handlers mono-modèle. Les gardes d’accès, paramètres d’URL, parsing du corps, SSE et Prometheus restent HTTP. Le précontrôle de capacité utilise une fonction moteur partagée, avant parsing, pour conserver la priorité historique des erreurs (par exemple embeddings désactivés + JSON malformé).
- Les events Responses/Anthropic sont des tableaux sémantiques `{event, data}`. Les sentinelles, commentaires keep-alive et encodages SSE restent dans le serveur. L’instance HTTP conserve ses limites non bornées upstream ; les autres instances restent bornées par défaut.
- Les noms de pièces jointes sont uniques ; `attachment:nom` référence directement leurs octets dans les champs médias. La transcription reçoit `file`. Le multipart ne sort pas de l’adapter HTTP. Les tests vision vérifient une image réelle, le comptage, la durée de vie du buffer et les erreurs de référence/décodage.
- Les métadonnées sont des valeurs possédées, avec templates partagés **const**, sans référence à `impl->chat_params`. Les snapshots sommeil et les buckets de statistiques appartiennent au moteur ; lecture sans réveil, reset reporté au réveil. La préparation garde son pin jusqu’à l’admission afin d’éviter qu’une tâche de statistiques soit postée après l’endormissement.
- Configuration publique supplémentaire : template, projector local, embeddings/pooling, répertoire de slots, chemins LoRA. La matrice complète de configuration reste P5 ; tous les paramètres serveur privés existants restent disponibles.

### Correspondance avec la matrice P0

| Famille / alias de P0 | Opérations moteur / responsabilité conservée | Preuves |
| --- | --- | --- |
| Completion native, OpenAI, infill | `completion`, `completions`, `infill` | `test-engine-model`, `test-engine-operations`, `test-engine-infill`, HTTP completion/infill, comparaison upstream |
| Chat, tools, JSON schema | `chat`, état incrémental par requête | direct génération/structured output, `test-engine-events` contrôlé (fragments tools/reasoning), `test-chat`, suites HTTP correspondantes |
| Responses, Anthropic | `responses`, `messages` | directs complets/streamés et comptage, HTTP compat, events nommés contrôlés, comparaison upstream |
| Transcription | `transcription`, pièce `file` | erreur de capacité directe ; conversion extraite à l’identique ; fixture audio positive **BLOCKED** |
| Multimodal | Médias existants et pièces jointes nommées | `test-engine-vision`, HTTP vision et slots multimodaux ; audio/vidéo/WebP voir limites |
| Embeddings et rerank | `embeddings`, `embeddings_openai`, `rerank` | directs batching/base64/pooling/ranking, HTTP, comparaison upstream |
| Tokens, templates, comptages | `tokenize`, `detokenize`, `apply_template`, `chat_tokens`, `response_tokens`, `message_tokens` | directs et suites HTTP, comparaison upstream |
| Contrôle de génération | `control` | succès/erreur directs, HTTP et comparaison upstream |
| Slots et LoRA | `slots`, `slot_save/restore/erase`, `lora_list/apply` | directs persistence/validation/liste/application vide, HTTP slots/security/LoRA ; fixture LoRA réelle couverte par HTTP |
| Props, modèles mono, métriques | `properties`, `properties_update`, `models`, `metrics` | directs, HTTP basic/metrics/sleep ; snapshots possédés, aucun réveil de lecture |
| Health | Readiness/middleware HTTP ; états de modèles P4 | HTTP basic/sleep ; aucun chargement implicite |
| Reprise SSE / lookup / DELETE | Serveur propriétaire de la requête, des octets et du replay | HTTP stream/routeur ; `test-engine-replay`, `test-engine-transport` |
| Acquisition/catalogue multi-modèles, routeur, CLI local/distant | P4–P7, hors P3 | pas de revendication de migration supplémentaire |

### Vérification et résultats

Les logs sont dans `build-agent-engine-evidence/p3-*.log`. Les échecs initiaux de build/tests de développement ont été corrigés : type enum masqué par une fonction, spécialisation `common_json` manquante pour un vecteur, assertions de test traitant les chunks chat comme un objet au lieu d’un tableau, et emplacement des tests HTTP dans le graphe CMake. La table finale ci-dessous ne compte pas ces essais comme des PASS.

| Vérification | Résultat |
| --- | --- |
| Build serveur/CLI/app et tests C++ ciblés | **PASS**, 13/13 après le dernier correctif de compatibilité |
| Suite HTTP complète disponible `not slow` | **PASS**, 375 tests, **6 SKIP** (non qualifiés), avant le dernier correctif de précontrôle ; régression ciblée finale ci-dessous |
| Régression HTTP finale après précontrôle | **PASS**, 169 tests, **2 SKIP**, dont les trois nouveaux cas JSON malformé / réveil / priorité des erreurs de capacité |
| Comparaison upstream `e4c142c` | **PASS**, 32 cas native, 80 contrats, 6 infill, 16 embeddings, 6 rerank ; statut, type, corps et ordre des champs, valeurs temporelles/IDs masquées ; périmètre de dernière exécution précisé ci-dessous |
| Profil local statique neuf, avec 4 GGUF/projector | **PASS**, 24/24 ; inférence réelle, infill, rerank et vision |
| Profil local partagé | **PASS**, 21/21 ; pas de fixture infill/rerank/vision configurée dans ce profil |
| ASan + UBSan | **PASS**, 5/5 ; LeakSanitizer désactivé sur cet hôte macOS |
| TSan | **PASS**, 5/5 ; aucun rapport lors de la passe précédant le dernier correctif de précontrôle ; dernière relance bloquée, voir ci-dessous |
| Replay déterministe | **PASS** : déconnexion/drainage, reconnexion par offset, offset perdu, remplacement, Stop pendant drainage et arrêt pendant replay |
| Adapter HTTP avec décodeur contrôlé | **PASS** : keep-alive pendant attente bloquante, erreur avant headers (400), erreur après headers (SSE), arrêt avec lecteur en attente |

La dernière passe C++ et les profils local statique, partagé et ASan/UBSan incluent le correctif final de précontrôle. La suite HTTP ciblée finale inclut sleep, metrics, completion, chat, Anthropic, Responses, embeddings et infill (`p3-http-last-change.log`). Le profil différentiel `contracts` contient désormais 89 cas ; seuls les 80 cas de la passe précédente ont été comparés. Le binaire upstream et le build TSan, stockés dans un répertoire temporaire externe, ont disparu avant la relance finale : ces deux relances sont **BLOCKED**, sans invalider ni étendre les résultats précédents. Les neuf cas différentiels ajoutés restent à rejouer contre upstream ; les trois régressions de réveil/priorité sont vérifiées par la suite HTTP finale.

### Commandes reproductibles

```sh
MODEL="$PWD/tools/server/tests/tmp/models--ggml-org--test-model-stories260K/snapshots/479896ec924af6d40fd419ab8f4d1eb2101de00d/stories260K-f32.gguf"
cmake -S . -B build-agent-engine-baseline -DLLAMA_ENGINE_TEST_MODEL="$MODEL"
cmake --build build-agent-engine-baseline --parallel 6 --target \
  llama-server llama-cli llama-app test-engine test-engine-lifecycle \
  test-engine-events test-engine-operations test-engine-fixtures \
  test-engine-replay test-engine-transport test-chat test-json-schema-to-grammar test-sampling
ctest --test-dir build-agent-engine-baseline --output-on-failure \
  -R '^(test-engine.*|test-chat|test-json-schema-to-grammar|test-sampling)$'
PATH="$PWD/.venv-server-tests/bin:$PATH" \
  SSL_CERT_FILE="$(.venv-server-tests/bin/python -c 'import certifi; print(certifi.where())')" \
  LLAMA_SERVER_BIN_PATH="$PWD/build-agent-engine-baseline/bin/llama-server" \
  N_GPU_LAYERS=0 PYTEST_WORKERS=1 ./tools/server/tests/tests.sh -m 'not slow' -q -x

cmake -S . -B build-agent-engine-p3-local \
  -DLLAMA_BUILD_ENGINE=ON -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_TOOLS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_TESTS=ON -DLLAMA_SUBPROCESS=OFF -DGGML_METAL=OFF \
  -DBUILD_SHARED_LIBS=OFF -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON \
  -DLLAMA_ENGINE_TEST_MODEL="$MODEL"
# Pour les tests facultatifs avec GGUF :
# -DLLAMA_ENGINE_TEST_INFILL_MODEL=/.../stories260K-infill-F32.gguf
# -DLLAMA_ENGINE_TEST_RERANK_MODEL=/.../jina-reranker-v1-tiny-en/ggml-model-f16.gguf
# -DLLAMA_ENGINE_TEST_VISION_MODEL=/.../tinygemma3-Q8_0.gguf
# -DLLAMA_ENGINE_TEST_MMPROJ=/.../mmproj-tinygemma3.gguf
cmake --build build-agent-engine-p3-local --parallel 6
ctest --test-dir build-agent-engine-p3-local --output-on-failure
# Profil partagé : mêmes options, BUILD_SHARED_LIBS=ON (build-agent-engine-core-shared).
# Sanitizers : options et commandes P2, plus cibles test-engine-events/test-engine-operations.
# Comparaison (utiliser le GGUF correspondant au profil) :
python3 scripts/diff-server-completion.py "$UPSTREAM_SERVER" \
  build-agent-engine-baseline/bin/llama-server "$MODEL" contracts
# Profils supplémentaires : infill, embeddings, rerank.
```

### Limites et passation

- **BLOCKED** : transcription/audio positif sans fixture de modèle audio locale ; les validations de capacité, la possession du buffer et la conversion existante sont implémentées, pas une qualification de transcription réelle. Les formats vidéo/WebP et les tests lourds restent ouverts comme à P0/P2.
- Les tests de production d’outils/reasoning streamés utilisent des résultats de décodeur contrôlés avec les vrais parsers et le vrai lecteur public. Ils ne prouvent pas la qualité de génération d’appels d’outils par un modèle entraîné ; les tests lourds correspondants restent distincts.
- Audit local : pas de source serveur/CLI/UI/acquisition, ni de référence HTTP/subprocess dans les archives moteur/common/mtmd ; dépendances partagées locales. **Précision par rapport aux audits P1/P2** : `ggml-base` conserve un chemin historique `fork`/`execlp` pour le debugger de backtrace fatale (optionnel sur macOS via `GGML_BACKTRACE_LLDB`). Il n’est pas appelé par l’inférence normale. Un binaire totalement dépourvu de tels symboles n’est pas revendiqué ; cette restriction de diagnostic reste à traiter dans la qualification stricte P9.
- Pas de changement d’ordonnanceur, sampling, spéculation ou réutilisation du cache. Les suites correspondantes sont passées ; pas de nouvelle qualification de performances A/B, Metal, Linux/Windows/iOS ni LeakSanitizer dans P3.
- Façades restantes : noms privés `server_context`/`server_task`, initialisation serveur via `common_params`, lecteur legacy pour consommateurs non migrés et forwarding headers. Nettoyage P8 après les bascules routeur P6 et CLI P7. Le moteur ne contient ni reprise SSE ni exécution d’outils/MCP.
- Reprendre à **P4** pour le cycle de vie multi-modèles dans le processus. Ne pas réextraire le mono-modèle ; conserver la règle de parité HTTP et les bornes configurables. Le routeur/CLI actuels peuvent encore lancer/utiliser le serveur selon les chemins prévus à P6/P7.


## P3 — Revérification avant P4 (29 septembre 2026)

Arbre de travail : P3 non commité par-dessus `8dd3003e9`. Revérification sans modification préalable :

| Vérification | Résultat |
| --- | --- |
| Reconfigure + build serveur/CLI/app + tests C++ | **PASS**, aucun warning (`p4-verify-build.log`) |
| `test-engine*`, `test-chat`, JSON schema, sampling | **PASS 13/13** |
| Suite HTTP complète `not slow` | **PASS 378, 6 SKIP** (`p4-verify-http.log`, 285,95 s) ; +3 tests P3 par rapport aux 375 de P2 |

Le plan est suivi : tous les handlers mono-modèle passent par `handle_operation` → `submit_native`, sans `server_response_reader` dans `server-context.cpp`. Les réserves P3 (audio **BLOCKED**, 9 cas différentiels non rejoués contre upstream, TSan final P3 **BLOCKED**) restent ouvertes ; le TSan P4 ci-dessous couvre de nouveau les tests moteur, pas le différentiel.

## P4 — Cycle de vie multi-modèles dans le processus

### Implémentation

- **Politique extraite, pas recopiée** : `engine/engine-scheduler.h` contient `load_queue` (file par modèle, `try_claim` en tête de file, `tick`, `pick_victim` LRU) et `find_model` (nom exact puis alias), déplacés depuis `server_lru_sched`/`has_model`/`get_meta` du routeur. Le routeur les consomme via un adaptateur (`server_lru_sched` hérite de `load_queue`, `find_instance`) ; journaux et comportements conservés. L’adaptateur disparaît avec le routeur de processus en P6.
- **Gestionnaire** : `engine/engine-models.{h,cpp}` (`model_manager`). États `unloaded`, `loading`, `loaded`, `sleeping`, `unloading`, `failed` ; présence au catalogue (entrées immuables), résidence (`status`/backend), attentes (`waiters`, entrée de file partagée) et requêtes admises (`active`, crochet de fin posé sur la requête) sont séparées. Une génération par chargement ignore les rappels tardifs d’une instance précédente.
- **Ressources possédées** : chaque modèle résident est un `server_context` (décodeur, slots, caches, sommeil) derrière `model_backend`. Pas de sous-processus, port, environnement ni protocole stdin. Les doubles de test implémentent la même interface.
- **Limite** : `max_loaded` compte chargements, résidents, endormis et déchargements, exactement comme `is_running()` du routeur. Demandes simultanées pour un même modèle : une entrée, **un chargement**. Échec : toutes les attentes du modèle reçoivent `load_failed`, l’entrée disparaît, l’état `failed` est récupérable, aucune réservation ne reste.
- **Attente bornée/annulable et ordre de service** : handle rendu immédiatement ; annulation = retrait de la file ; `max_waiting` et `wait_timeout` (5 min par défaut). Premier arrivé, premier servi par modèle ; seule la tête charge. Arbitrage conservé du routeur : les requêtes vers un modèle résident sont admises directement et un modèle occupé n’est jamais évincé ; la famine d’une attente face à un modèle occupé en continu se termine donc par `wait_timeout` explicite, jamais silencieusement. Les requêtes en attente sont préparées par le thread de chargement une fois le modèle résident.
- **Déchargement explicite** (`engine::unload`, bloquant) : ferme les admissions (état `unloading`, les nouvelles requêtes attendent l’instance suivante), termine attentes et requêtes admises en `cancelled`/`unloaded`, arrête le décodeur (attente des préparations en cours), puis libère. Pendant un chargement : annulation coopérative au prochain rapport de progression (`server_context::cancel_load`, le callback de progression renvoie `false`). Courses couvertes : soumission, rechargement, second déchargement, arrêt moteur.
- **Sommeil/réveil** : sommeil par modèle (`config::sleep_idle_seconds`), un modèle endormi reste compté. Le `GGML_ABORT` du réveil est remplacé : `handle_sleeping_state` libère le rechargement partiel et lève ; `server_queue::start_loop` reste endormi, mémorise l’erreur et réveille les attentes (`acquire_context`/`wait_until_no_sleep` ne bloquent plus indéfiniment) ; la requête reçoit `wake_failed` (HTTP 503) et la suivante retente. Les snapshots de sommeil restent valides.
- **Observation** : `engine::catalog()` et `engine::subscribe()` (instantané initial, `status`/`progress`, `resync` pour un abonné saturé, fermeture `stopped` à l’arrêt ; désabonnement sans effet sur les modèles). La progression réutilise le callback de chargement existant (limité à 200 ms).
- **Mono-modèle unifié** : `engine::create(config)` est un catalogue d’une entrée chargée à la création ; le champ `model` n’est pas utilisé pour la sélection. Aucune seconde implémentation : l’ancien `engine_impl` à contexte unique est supprimé. `engine::create_catalog` est nommé ainsi pour éviter l’ambiguïté de `create({}, …)`.
- **Serveur HTTP** : inchangé hors réveil échoué (503 au lieu d’un abort du processus). Le routeur conserve ses enfants jusqu’à P6.

### Validation réellement exécutée

| Vérification | Résultat |
| --- | --- |
| `test-engine-models` (doubles internes, sans modèle) : limite 1 A occupé/B attend/éviction de A avant chargement de B ; annulation et expiration en attente ; ordre FIFO b→c avec entrée partagée ; `max_waiting` ; limite 2, 8 demandes simultanées = 1 chargement ; échec sans réservation orpheline puis rechargement ; déchargement pendant génération, pendant chargement, pendant déchargement (nouvelle requête servie par l’instance suivante) ; sommeil ; abonnements ordonnés/resync/désabonnement ; 50 tours arrêt concurrent avec soumissions, annulations, déchargement et une deuxième instance indépendante | **PASS**, 30 exécutions consécutives |
| `test-engine-catalog` (API publique, vrai stories260K, CPU) : chargement à la demande par alias, progression observée, éviction LRU, échec de chargement puis modèle sain, modèle inconnu, 8 requêtes concurrentes limite 2 = une transition `loading`, déchargement pendant stream (`unloaded`), `model_not_loaded`, chargement explicite, sommeil puis réveil échoué (fichier déplacé) `wake_failed` puis récupération, propriétés sans réveil, mono-modèle déchargé/rechargé, deux instances | **PASS**, 8 exécutions consécutives |
| Nouveau test HTTP `test_failed_wake_up_is_reported_and_recoverable` + `test_sleep` + `test_router` | **PASS 25/25** (`p4-http-sleep-router.log`) ; 503 puis 200 après restauration, `/health` 200 pendant l’échec |
| Build serveur/CLI/app + C++ ciblé complet | **PASS**, 0 warning (`p4-full-build.log`), **15/15** (`p4-cpp.log`) |
| Suite HTTP complète `not slow` (routeur sur la politique partagée) | **PASS 379, 6 SKIP** (`p4-http-all.log`, 272 s) ; +1 = nouveau test de réveil ; mêmes 6 skips non qualifiés |
| Smoke CLI legacy single-turn | **PASS**, code 0 (`p4-cli-smoke.log`) |
| `git diff --check` | **PASS** |
| Profil local statique sans HTTP (`build-agent-engine-p3-local`, 4 GGUF) | **PASS 26/26** ; `nm -u` libllama-engine.a sans httplib/subprocess/spawn/socket/téléchargement |
| Profil local partagé (`build-agent-engine-core-shared`) | **PASS 23/23** ; `otool -L` : engine, common-local, mtmd, llama, ggml, système |
| ASan + UBSan (7 tests moteur dont models/catalog) | **PASS 7/7** (`p4-asan-tests.log`) ; LeakSanitizer toujours **BLOCKED** sur macOS |
| TSan (profil Debug moteur seul `build-agent-engine-p4-tsan`, OpenMP off) | **PASS 7/7**, 0 rapport ; puis models + catalog répétés 10 fois : 0 échec, 0 rapport (`p4-tsan-repeat.log`) |

Échecs intermédiaires corrigés, non comptés comme PASS : ambiguïté `engine::create({}, …)` (renommage `create_catalog`) ; prédicats de test verrouillant le mutex déjà tenu (interblocage du test, pas du moteur) ; sous TSan, un test comptait les republications `loading` (changement du nombre d’attentes) comme des chargements — assertion corrigée pour compter les transitions.

### Limites et passation

- Le délai `wait_timeout` inclut la durée du chargement ; un gros modèle nécessite un délai adapté. Le routeur n’avait pas de délai : P6 doit choisir la valeur serveur (probablement non bornée pour la parité HTTP) et l’inscrire dans la matrice.
- Les requêtes différées sont préparées séquentiellement sur le thread de chargement de leur modèle. Le thread d’entretien exécute les déchargements un par un ; un arrêt de décodeur long retarde les expirations (coopératif, sans délai strict, comme le design).
- L’annulation d’un chargement dépend des rapports de progression de llama/mtmd ; après le dernier rapport (création de contexte, projecteur), l’arrêt attend la fin du chargement.
- Pas de budget mémoire exact : limite en nombre de modèles par moteur, comme le design. Tests multi-modèles sur stories260K uniquement (même GGUF sous plusieurs identifiants + fichier absent) ; Metal, gros modèles, Linux/Windows/iOS non qualifiés.
- Les sources de catalogue (presets, répertoire, cache HF), la suppression du cache, le téléchargement et `DOWNLOADING` restent **P5** ; la bascule des routes `/models*`, SSE et proxy vers le moteur reste **P6** ; CLI P7.
- Échéances des façades : `server_lru_sched`/`ensure_model_ready` du routeur P6 (voir tableau).

### Commandes P4 reproductibles

```sh
MODEL="$PWD/tools/server/tests/tmp/models--ggml-org--test-model-stories260K/snapshots/479896ec924af6d40fd419ab8f4d1eb2101de00d/stories260K-f32.gguf"
cmake -S . -B build-agent-engine-baseline -DLLAMA_ENGINE_TEST_MODEL="$MODEL"
cmake --build build-agent-engine-baseline --parallel 8 --target llama-server llama-cli llama-app \
  test-engine test-engine-lifecycle test-engine-models test-engine-catalog test-engine-events \
  test-engine-operations test-engine-fixtures test-engine-replay test-engine-transport \
  test-chat test-json-schema-to-grammar test-sampling
ctest --test-dir build-agent-engine-baseline --output-on-failure \
  -R '^(test-engine.*|test-chat|test-json-schema-to-grammar|test-sampling)$'
for i in $(seq 1 30); do build-agent-engine-baseline/bin/test-engine-models || break; done
PATH="$PWD/.venv-server-tests/bin:$PATH" \
  SSL_CERT_FILE="$(.venv-server-tests/bin/python -c 'import certifi; print(certifi.where())')" \
  LLAMA_SERVER_BIN_PATH="$PWD/build-agent-engine-baseline/bin/llama-server" \
  N_GPU_LAYERS=0 PYTEST_WORKERS=1 ./tools/server/tests/tests.sh -m 'not slow' -q
# Profils locaux déjà configurés (P1/P3) : reconfigurer, construire, CTest
cmake -S . -B build-agent-engine-p3-local && cmake --build build-agent-engine-p3-local --parallel 4
ctest --test-dir build-agent-engine-p3-local --output-on-failure
cmake -S . -B build-agent-engine-core-shared && cmake --build build-agent-engine-core-shared --parallel 4
ctest --test-dir build-agent-engine-core-shared --output-on-failure
# ASan/UBSan : profil P2 (build-agent-engine-p2-sanitize), cibles + test-engine-models test-engine-catalog
ASAN_OPTIONS=detect_leaks=0 UBSAN_OPTIONS=halt_on_error=1 ctest --test-dir build-agent-engine-p2-sanitize \
  --output-on-failure -R '^(test-engine|test-engine-lifecycle|test-engine-model|test-engine-models|test-engine-catalog|test-engine-operations|test-engine-events)$'
cmake -S . -B build-agent-engine-p4-tsan -DLLAMA_BUILD_ENGINE=ON -DLLAMA_BUILD_COMMON=OFF \
  -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF \
  -DLLAMA_BUILD_TESTS=ON -DLLAMA_SUBPROCESS=OFF -DGGML_METAL=OFF -DGGML_OPENMP=OFF -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_BUILD_TYPE=Debug -DLLAMA_SANITIZE_THREAD=ON -DGGML_SANITIZE_THREAD=ON -DLLAMA_ENGINE_TEST_MODEL="$MODEL"
cmake --build build-agent-engine-p4-tsan --parallel 5 --target test-engine test-engine-lifecycle \
  test-engine-models test-engine-catalog test-engine-operations test-engine-events
TSAN_OPTIONS=halt_on_error=1 ctest --test-dir build-agent-engine-p4-tsan --output-on-failure
```

Le répertoire TSan est désormais dans le dépôt (ignoré par Git), pas dans un scratchpad temporaire comme à P3.

## Consignes de reprise P5

1. Lire le plan, ce journal (sections P3/P4) et le guide API. Ne pas réécrire le gestionnaire : P5 **alimente** `catalog_config` à partir des sources existantes.
2. Extraire de `server_models::load_models` (cache, `models_dir`, presets INI, preset global/arguments du routeur, alias/dédoublonnage, `hidden`, `load_on_startup`) une lecture partagée produisant des `model_entry` ; conserver priorités et règles de conflit, établir d’abord des fixtures qui figent le comportement actuel.
3. Terminer la traduction des options (`to_common_params` ne couvre qu’un sous-ensemble) : aucun champ de la matrice P0 ne doit exiger `common_params`, `argc/argv` ou HTTP. Prévoir comment une entrée de catalogue porte les options d’un preset sans exposer `common_params`.
4. Acquisition optionnelle (`llama-common-acquisition`) : téléchargement sans enfant, progression vers les abonnés (état `downloading` à ajouter au gestionnaire ou module distinct), annulation, fichiers incomplets ; suppression du cache avec les garanties de `server_models::remove`. Rechargement de catalogue pendant utilisation/attente : définir le sort des attentes et des modèles résidents retirés (le routeur les décharge).
5. Profil sans acquisition : ressource distante = erreur explicite de capacité. Revalider les profils locaux statique/partagé et le graphe sans HTTP.
6. P6 devra choisir `wait_timeout` serveur (parité : non borné), traduire les états (`failed` ↔ `unloaded`+`exit_code`, `unloading`) et supprimer `server_lru_sched`/`ensure_model_ready`.
