# Journal — moteur d’inférence embarquable

## Passation / état courant

- Référence : `e4c142c5765abf9e5e2285b4b7379e4e84edacea` (HEAD vérifié au démarrage).
- **Point d’arrêt demandé par l’utilisateur : P1, lots A/B/C finalisés pour le graphe de build sur macOS. P2 n’est pas commencé.** Les critères encore ouverts (configuration/catalogue, formats, performances et autres plateformes) sont explicités ci-dessous. Le drop complet P0–P9 n’est **pas terminé**.
- P0 : inventaire et référence build/CTest/HTTP + CPU/Metal établis. P1 : utilitaires locaux/cache, acquisition optionnelle, cible llama-engine consommée par le serveur pour ses helpers, sans dépendance inverse. Il n’existe encore **ni `include/llama-engine.h`, ni moteur possédant ses threads, ni requête publique bornée** ; la boucle de décodage reste dans server-context.cpp.
- Aucun handler ne délègue encore une opération d’inférence de bout en bout au nouveau moteur. CLI local et routeur restent leurs anciens chemins HTTP/processus. Ne pas confondre extraction de helpers et accomplissement de P2/P6/P7.
- Références obligatoires lues intégralement : CONTEXT, design, ADR 0001, CONTRIBUTING, README-dev serveur et README tests serveur.
- Modifications préexistantes préservées : `CONTEXT.md`, `docs/adr/`, `docs/design/` non suivis. Les anciens `build*` ne sont pas utilisés comme preuves.
- Swift / XCFramework : hors périmètre.
- Passation : tous les builds/tests lancés sont terminés ; aucun travail de fond laissé à reprendre. `git diff --check` final passe. Aucun commit ni staging automatique effectué.
- Légende : PASS = exécuté et vérifié ; FAIL = exécuté, assertion/build échoué ; BLOCKED = prérequis indisponible ; OUVERT = non encore implémenté/vérifié. Un test sauté n’est jamais PASS.
- Preuves locales : `build-agent-engine-evidence/` (répertoire ignoré par Git, commandes et synthèses ci-dessous pour reproduction).

## P0 — Matrice des opérations

Toutes les lignes sont **OUVERTES à la migration**. Les tests cités sont existants, pas implicitement exécutés. Sauf mention contraire, les handlers sont dans `tools/server/server-context.cpp::server_routes::init_routes`. Les noms d’opérations moteur restent à fixer à P2/P3 ; les chemins HTTP ne seront pas l’interface moteur.

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
| POST `/models/load`, `/models/unload` (routeur) | Validation état/alias ; lancement/arrêt enfant, annulation téléchargement | Cycle de vie moteur P4/P6 | `test_router` ; courses directes à ajouter |
| POST `/models` (routeur) | Validation distante, téléchargement enfant, rafraîchissement cache | Acquisition optionnelle P5, catalogue moteur | `test_router`, `test-model-resolution` ; serveur contrôlé |
| DELETE `/models` (routeur) | Suppression explicite du cache, restrictions de source et de chemins | Cache local partagé + cycle de vie moteur | `test_router`, `test_security` ; courses suppression/chargement |
| GET `/models/sse` (routeur) | Abonnement progression/états, déconnexion abonné indépendante du modèle | Observation moteur ; SSE HTTP | `test_router` ; saturation/resync directes |
| Sommeil/réveil (pas une route) | `sleep_idle_seconds=-1`, snapshot avant destroy, requête réveille ; réveil échoué fait actuellement GGML_ABORT | Machine d’états moteur P4, erreur explicite | `test_sleep` ; injection échec et coexistence |
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
| Noms internes server_* et include dirs privés exportés temporairement par llama-engine | Adapter existant et tests internes utilisent encore les types historiques | API publique limitée P2, nettoyage P8 |
| `server-process.*` et routeur/proxy enfants | Comportement desktop conservé, désormais hors cible moteur | P6/P8 |
| `server-context.cpp` | Toujours boucle de décodage + handlers + durée de vie legacy | P2/P3 |
| `server-task.cpp::to_metrics`, champs legacy SSE/config UI/HTTP | Restes de responsabilités à séparer sémantiquement ; pas de dépendance réseau nécessaire dans le profil local | P3/P6/P8 |
| `download.cpp` helpers cache/sélection, `arg.cpp` résolution, `preset.cpp` cascades | Réutilisés, pas encore disponibles comme catalogue local autonome | P5 ; auditer avant intégration de chargement P2 |

Aucune façade appelant le serveur depuis un moteur n’a été ajoutée. Un seul exemplaire de chaque algorithme extrait. Les suppressions `.cpp` dans tools/server sont des **déplacements vers engine non encore suivis par Git**, pas des fonctionnalités supprimées.

## Prochaine session — reprise exacte

1. Lire le plan et ses références obligatoires, puis ce journal. Vérifier `git status --short` : rien n’a été commité/stagé automatiquement. Préserver les documents de cadrage non suivis présents dès le début. Les nouveaux fichiers engine/common/tests et ce journal font partie du travail ; ne pas les perdre en ne regardant que `git diff`.
2. Revalider rapidement `build-agent-engine-core-{static,shared}` (16 CTest chacun) et les 9 tests C++ ciblés du build complet. Les commandes/profils ci-dessus existent réellement. Le répertoire `build-agent-engine-baseline` contient **maintenant P1** et ne contient plus le binaire P0 ; pour une nouvelle mesure P0, reconstruire le commit de référence dans un worktree/build distinct. Les résultats P0 originaux sont dans les logs/JSON et les tableaux du journal.
3. Examiner le signal de performance CPU avec une vraie comparaison A/B ; garder cette qualification ouverte si elle n’est pas menée. Ne pas invoquer automatiquement le bruit ou les déplacements mécaniques comme preuve d’absence de régression.
4. **Commencer P2**, pas P3/P4 : extraire `server_context_impl`/server_context de `tools/server/server-context.cpp` vers engine, réutiliser l’ordonnanceur inchangé, puis définir `include/llama-engine.h` (nlohmann::json public ; common_json et common_params restent internes). Les références au contexte par server_routes, les snapshots de sommeil et callbacks sont les principales coutures restantes.
5. Livrer la tranche completion native de bout en bout avec délégation réelle du handler HTTP. Threads possédés par le moteur, préparation/conversion hors decode, limites d’admission **et files intermédiaires**, issue terminale exclusive observable après saturation, annulation/arrêt/coexistence : établir les tests synchronisés avant de prétendre P2 validé.
6. Auditer backend init/free, logging global, priorité/NUMA, callback chargement et `GGML_ABORT` au réveil. Les doubles moteurs ne sont **pas** qualifiés par test-common-local. Ne pas supprimer batching, sampling, spéculation ou réutilisation de cache.
7. P3/P5 : conserver intégralement les lignes de la matrice. Décision nécessaire avant une parité multimodale sans processus : WebP/vidéo nécessitent aujourd’hui ffmpeg/ffprobe ; proposer décodeur embarqué ou contrat frames, ne pas annoncer la parité en désactivant VIDEO. Transcription/audio, formats absents, tests lourds, sanitizers, autres plateformes et iOS restent OUVERTS. Swift demeure hors périmètre.

Prompt de reprise proposé :

> Reprends `docs/design/embedded-inference-engine-plan.md` après lecture de ses références et du journal `docs/design/embedded-inference-engine-progress.md`. P1 A/B/C est implémenté et qualifié sur macOS pour les profils consignés ; 374 tests HTTP passent, 6 restent ignorés, et le signal de performance CPU doit être investigué. Aucun contrat moteur public ni boucle détenue par le moteur n’existe encore. Préserve les changements non commités, revalide, puis commence P2 avec une completion native réellement partagée entre moteur et HTTP et ses garanties de concurrence/files/arrêt. Garde le journal et les critères ouverts ; aucun binding Swift.

