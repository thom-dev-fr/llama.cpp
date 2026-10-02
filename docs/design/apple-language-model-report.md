# Rapport — Apple LanguageModel sur llama.cpp

Rapport prévu par le [plan](apple-language-model-plan.md). Il distingue ce qui est exécuté, compilé seulement, ou non encore traité. P0 à P7 sont achevés. Les capacités Foundation Models sont validées avec Qwen3.5-2B sur le simulateur iOS 27 (CPU) et sur un appareil, un iPad Pro M1 sous iPadOS 27.2 (Metal), où sont aussi faits le téléchargement en arrière-plan et les mesures. **La livraison est partiellement qualifiée** : macOS 27 est compilé seulement (Mac sous 26.7), et l’iPhone, hors ligne pendant P6 et P7, est remplacé par l’iPad (même famille iOS, puce M1, 8 Go).

Les décomptes CTest et HTTP ci-dessous précèdent le rebase sur master du 2 octobre 2026 ; les décomptes actuels sont dans la section « Rebase sur master » du [rapport du moteur](embedded-inference-engine-report.md). Les tests Swift et iOS n’ont pas été réexécutés après ce rebase.

## Suivi P0–P7

| Phase | État | Preuve | Blocage / remarque |
| --- | --- | --- | --- |
| P0 Contrat exécutable | **Terminé** | Matrice ci-dessous ; package `bindings/apple` compilé pour macOS 27, iOS 27 appareil et simulateur ; 8 tests Swift réussis sur simulateur iOS 27. | Aucune capacité déclarée : le squelette refuse toute requête explicitement. |
| P1 Signaux du moteur | **Terminé** | `test-engine-context` (nouveau) ; CTest 77/80, les 3 échecs préexistants ou d’environnement ; HTTP non-`slow` 393 réussis / 6 ignorés ; sonde Qwen3.5-2B (image, raisonnement) ; 12 tests Swift sur simulateur iOS 27. | `test-engine-operations` et `test-engine-acquisition` échouent aussi sans P1 (voir P1). |
| P2 Pont natif et XCFramework | **Terminé** | Pont C + `test-llama-bridge` (hôte, ASan+UBSan, TSan) ; `LlamaBridge.xcframework` iOS / simulateur / macOS ; 20 tests Swift sur simulateur iOS 27 dont 8 sur le vrai moteur ; consommateur externe compilé pour iOS et macOS, testé sur simulateur. | Exécution macOS et iPhone non faite (P7). Premier chargement Metal lent sur simulateur (voir P2). |
| P3 Runtime partagé, stockage | **Terminé** | `LlamaRuntime` (moteur natif en catalogue, admission, instances, chargements mutualisés, déchargement, observation) et `LlamaModelStore` ; 33 tests Swift sur simulateur iOS 27 dont 13 nouveaux `RuntimeTests` sur le vrai moteur, stables sur 5 itérations ; compilation macOS 27 et iOS 27 appareil. | Aucun changement du moteur ni du pont. Tests sur stories15M (CPU) ; iPhone et macOS 27 non exécutés (P7). |
| P4 Acquisition URLSession | **Terminé** | Manifeste `LlamaModelCatalog` et `Catalog/models.json` (Qwen3.5-2B, références vérifiées côté serveur et localement) ; `LlamaModelDownloads` ; 17 `DownloadTests` sur simulateur iOS 27, dont 15 avec serveur contrôlé (interruption, reprise, sans plages, fichier modifié, HTTP, pause, abandon, relance) ; téléchargement réel de l’entrée Qwen (1,95 Go) avec pause et reprise via le CDN ; 50 tests au total, stables sur 5 itérations. | Le système refuse une session de fond au processus `xctest` : exécuté en P6 dans l’application de démo (test hébergé et transfert réel sur simulateur, app suspendue), puis en P7 sur l’iPad (app suspendue puis terminée). |
| P5 Executor Foundation Models | **Terminé** | Executor complet (transcript, options, schémas stricts, outils, raisonnement, vision, flux, erreurs, annulation, moniteur) ; moteur : `strict_json_schema` et outils + schéma pour Qwen3.5 ; 27 tests scriptés, 9 sur le vrai moteur (stories15M), 12 avec Qwen3.5-2B sur simulateur iOS 27 (CPU) ; catalogue qualifié (outils, raisonnement, vision). | Metal du simulateur inutilisable pour Qwen3.5 (plantages) : qualification CPU ; Metal qualifié sur l’iPad en P7. |
| P6 Démo SwiftUI | **Terminé** | `examples/llama.foundationmodels` (projet Xcode partagé iOS/macOS 27) ; 19 tests unitaires hébergés (modèle de présentation scripté, moteur réel avec stories15M, session de fond dans l’app) ; 3 parcours XCUITest avec Qwen3.5-2B ; parcours manuel depuis une installation vide (téléchargement réel en arrière-plan, pause/reprise) et après relance ; compilation macOS 27 et iOS appareil. | Parcours d’interface rejoués sur l’iPad en P7. macOS 27 compilé seulement. |
| P7 Qualification | **Terminé, qualification partielle** | Téléchargement réel depuis une installation vide sur iPad (app suspendue puis terminée) ; 14 `DeviceQualificationTests` sur iPad (Metal) : chaque capacité, combinaisons, deux sessions, contexte plein, reprise après interruption, mesures ; 3 parcours XCUITest sur iPad ; suite du package (93 tests) et de la démo (33) sur simulateur ; CTest 77/80, HTTP 393/6 ; outils : argument chaîne énuméré imposé, contrainte non représentable refusée. | macOS 27 non exécuté (Mac 26.7) ; iPhone hors ligne, remplacé par l’iPad ; fermeture forcée par l’utilisateur non automatisable. |

## P0 — Constat de départ

### Dépôt

- Aucun `AGENTS.md` ni `CLAUDE.md` propre au dépôt (seul `tools/ui/node_modules/cytoscape/AGENTS.md`, hors sujet).
- Branche `master`, arbre propre au démarrage, dernier commit `f352ae664 apple-engine : plan & docs`.
- Artefacts historiques non repris : une trentaine de répertoires `build-*` et un stash `stash@{8}` intitulé « examples: llama-engine + llama-server apple LanguageModel implementation ». Conformément au plan, ils ne sont ni appliqués ni recopiés ; tout le code Apple est écrit à neuf.
- `bindings/` n’existait pas ; `examples/llama.swiftui` et `build-xcframework.sh` ne sont pas modifiés.

### Environnement (vérifié le 1er octobre 2026)

| Élément | Constat | Commande |
| --- | --- | --- |
| Xcode | 27.0 (27A266a), Swift 6.4 | `xcodebuild -version`, `xcrun swift --version` |
| SDK | iOS 27.0, simulateur iOS 27.0, macOS 27.0 | `xcodebuild -showsdks` |
| Mac | M1 Pro 16 Gio, macOS 26.7 (25G229) : compilation SDK 27 possible, exécution des API OS 27 impossible | `sw_vers` |
| Simulateurs | Runtime iOS 27.0 (24A434) ; iPhone 17 Pro `C64BD9F4-…` utilisé pour les tests | `xcrun simctl list` |
| iPhone | iPhone 16 Pro Max (iPhone17,2), iOS 27.0.1, appairé, mode développeur activé | `xcrun devicectl device info details` |
| Autres appareils | iPad Pro 11" 3e gén. appairé ; iPhone 13 Pro Max indisponible | `xcrun devicectl list devices` |
| Signature | 8 identités valides, dont 3 « Apple Development » personnelles ; 29 profils installés. Le déploiement sur iPhone reste à vérifier en P6/P7. | `security find-identity -v -p codesigning` |
| Modèle candidat | `unsloth/Qwen3.5-2B-GGUF`, révision `f6d5376be1edb4d416d56da11e5397a961aca8ae` : `Qwen3.5-2B-Q4_K_M.gguf` (sha256 `aaf42c8b…9223`) et `mmproj-BF16.gguf` (sha256 `f17196c0…d3c2`), cache Hugging Face local | `shasum -a 256` |
| Autres modèles locaux | `unsloth/gemma-4-E2B-it-GGUF` (Q4_K_M + mmproj), `prism-ml/Ternary-Bonsai-4B-gguf`, fixtures `stories15M-q4_0.gguf` et `moe_shakespeare15M.gguf` | — |

### Contrat Foundation Models du SDK compilé

Source : `MacOSX.sdk/…/FoundationModels.swiftmodule/arm64e-apple-macos.swiftinterface` (module 2.0.68.1.402). Les types de l’executor sont `@available(iOS 27.0, macOS 27.0, …)`, `tvOS` indisponible.

- `protocol LanguageModel: Sendable` : `associatedtype Executor` avec `Self == Executor.Model`, `capabilities: LanguageModelCapabilities`, `executorConfiguration: Executor.Configuration`.
- `protocol LanguageModelExecutor: Sendable` : `Configuration: Hashable & Sendable`, `init(configuration:) throws`, `prewarm(model:transcript:)` (implémentation par défaut), `nonisolated(nonsending) respond(to:model:streamingInto:) async throws`. Le canal n’a pas de `finish` : la fin découle du retour ou de l’erreur de `respond`.
- Capacités déclarables : `guidedGeneration`, `toolCalling`, `reasoning`, `vision`. Texte et streaming ne sont pas des capacités.
- `LanguageModelExecutorGenerationRequest` : `id: UUID`, `transcript`, `enabledToolDefinitions`, `schema: GenerationSchema?`, `generationOptions`, `contextOptions`, `metadata`.
- Événements : `response` (`appendText`/`replaceTextSegment` avec `segmentID` et `tokenCount`, `add/removeAttachmentSegment`, `updateMetadata`, `updateUsage`), `reasoning` (mêmes actions + `updateSignature`), `toolCalls` (`toolCall(id:name:action: appendArguments)`, `removeToolCall`, `updateUsage`). Chaque événement porte un `entryID` optionnel.
- Usage : `Input(totalTokenCount, cachedTokenCount)`, `Output(totalTokenCount, reasoningTokenCount)`.
- Transcript : entrées `instructions` (segments + définitions d’outils), `prompt` (segments, `options`, `contextOptions`, `responseFormat`), `toolCalls`, `toolOutput`, `response`, `reasoning` (segments + `signature: Data?`). Segments `text`, `structure` (`GeneratedContent`), `attachment` (seulement `image` : `CGImage`/`CIImage`/`CVPixelBuffer`/URL + `orientation`).
- Options : `SamplingMode.Kind` = `greedy | randomTopK(Int, seed: UInt64?) | randomProbabilityThreshold(Double, seed: UInt64?)`, `temperature`, `maximumResponseTokens`, `ToolCallingMode` = `allowed | required | disallowed`. `ContextOptions` : `includeSchemaInPrompt: Bool?`, `reasoningLevel` = `light | moderate | deep | custom(String)`.
- Erreurs : `LanguageModelError` = `contextSizeExceeded(contextSize, tokenCount)`, `rateLimited`, `guardrailViolation`, `refusal`, `unsupportedCapability(capability)`, `unsupportedTranscriptContent(entries)`, `unsupportedGenerationGuide(schemaName)`, `unsupportedLanguageOrLocale`, `timeout`. `TranscriptErrorHandlingPolicy` : `revertTranscript | preserveTranscript`.
- Guides : chaînes `constant`, `anyOf`, `pattern(Regex)` ; `Int`/`Float`/`Double`/`Decimal` `minimum`/`maximum`/`range` ; tableaux `minimumCount`/`maximumCount`/`count`/`element`.
- Hors protocole dans ce SDK : audio, embeddings, reranking.

Observations exécutées (simulateur iOS 27) :

- Une erreur levée par `respond` arrive telle quelle à l’appelant de `LanguageModelSession.respond` (type `LlamaEngineError` conservé, non enveloppé).
- `GenerationSchema` s’encode en JSON Schema : `$defs` + `$ref: "#/$defs/<Nom>"`, `"$ref": "#"` pour une récursion sur la racine, `additionalProperties: false`, `x-order` pour l’ordre de déclaration, optionnels absents de `required` (pas de `null`), enum de chaînes, `minItems`/`maxItems`, bornes entières et flottantes, `pattern` **non ancré**. L’ordre des clés de `properties` dans l’encodage diffère de `x-order`.

### Matrice par capacité

Légende du test : *P0* = test exécuté aujourd’hui ; les autres sont des tests à écrire dans la phase indiquée.

| Capacité Apple | Entrée Apple | Opération moteur | Sortie attendue | Restrictions et écarts constatés | Test associé |
| --- | --- | --- | --- | --- | --- |
| Texte | Transcript (instructions, prompts, réponses) | `operation::chat`, `messages` + template du modèle | `response.appendText` par delta, `updateUsage` final | Transcript complet à chaque requête ; le cache n’est pas l’identité de conversation. | P0 : refus explicite (`textRequestFailsExplicitly`, `sessionSurfacesTheFailure`). P5 : deltas, UTF-8, ordre. |
| Streaming | Canal de l’executor | `request::next()` (deltas OAI) | Ordre et segments préservés | Lecture bloquante → worker dédié (P2). | P5 |
| Génération structurée (`guidedGeneration`) | `request.schema`, `Prompt.responseFormat`, `includeSchemaInPrompt` | `response_format`/`json_schema` → `json_schema_to_grammar` | JSON conforme, streamé en `appendText` | Écarts du convertisseur : `"$ref": "#"` rejeté (seul `#/…` résolu) ; `pattern` non ancré ou hors sous-ensemble = **avertissement et chaîne libre** (approximation silencieuse à interdire) ; bornes `number` ignorées (Double/Float/Decimal) ; ordre des propriétés à imposer depuis `x-order`. Diagnostic à localiser via `unsupportedGenerationGuide(schemaName)`. | P0 : encodage figé (`GenerationSchemaEncodingTests`), refus sans capacité (`undeclaredCapabilityIsRefused`). P5 : conversion stricte, refus localisé. |
| Outils (`toolCalling`) | `enabledToolDefinitions`, définitions des instructions, entrées `toolCalls`/`toolOutput`, `ToolCallingMode` | `tools` + `tool_choice` `auto`/`required`/`none` ; arguments fragmentés ; `parallel_tool_calls` | `toolCalls.toolCall(id:name: appendArguments)` | Exécution par Foundation Models ; JSON partiel = incomplet. `allowed→auto`, `required→required`, `disallowed→none`. Combinaison outils + schéma : `Cannot specify grammar with tools` sur le chemin grammaire ; support via l’autoparser à vérifier. | P0 : détection (`requirementsAreDetectedBeforeComputation`). P5 : appels multiples, outils + structuré. |
| Raisonnement (`reasoning`) | `ContextOptions.reasoningLevel`, entrées `reasoning` | `reasoning_format`, `enable_thinking`, `reasoning_effort` (kwarg du template) | `reasoning.appendText` distinct, `reasoningTokenCount` | `light/moderate/deep` → `reasoning_effort` seulement si le template le prend en charge ; `custom(String)` sans représentation générale → refus ; `signature` sans équivalent. Rejouer un raisonnement antérieur dépend du template. | P0 : détection. P5 : séparation et refus des niveaux non traduisibles. |
| Vision (`vision`) | Segments `attachment(.image)` avec orientation | Pièces jointes `attachment` + mtmd + projecteur | Image prise en compte avant le texte suivant | Encodage CGImage → PNG/JPEG avec orientation appliquée ; projecteur compatible requis ; context shift désactivé par mtmd. | P0 : détection. P5/P7 : Qwen3.5-2B + `mmproj-BF16`. |
| Sampling | `greedy`, `randomTopK(k)`, `randomProbabilityThreshold(p)`, `temperature` | `top_k`, `top_p`, `temperature` | Paramètres identiques | `greedy` → `top_k = 1` ; combinaison exacte des samplers par défaut du moteur (min_p, pénalités…) à neutraliser pour une traduction fidèle. | P5 |
| Seed | `seed: UInt64?` | `seed` 32 bits (`uint32_t`), `0xFFFFFFFF` = aléatoire | Reproductibilité | Valeurs `> 0xFFFFFFFE` sans représentation fidèle → refus avant lancement. | P5 |
| Limite de sortie | `maximumResponseTokens` | `n_predict` / `max_tokens` | Arrêt « budget atteint » | Distinct du contexte épuisé (P1). | P1/P5 |
| Contexte plein | — | `fail_on_context_full` : erreur `context_exceeded` avec `context_phase` `prompt`/`generation` (P1) | `LanguageModelError.contextSizeExceeded(contextSize, tokenCount)` | Avant P1, le chemin chat rapportait `finish_reason: length` pour le contexte comme pour le budget. Jamais de context shift pour ces requêtes. | P1 : `test-engine-context`, `ContextSignalTests`. |
| Usage et occupation | `updateUsage(input:output:)` | `return_context` : `n_ctx`, `n_tokens`, `n_prompt_tokens`, `n_cache_tokens`, `n_decoded`, `n_reasoning_tokens` par requête (P1) ; `prompt_progress` | `Usage.Input(total, cached)`, `Usage.Output(total, reasoning)` ; occupation séparée | `session.usage` est cumulatif, jamais une occupation. | P1 : requêtes intercalées ; P5 : traduction. |
| Erreurs | — | Catégories d’`event` | `LanguageModelError` / erreurs typées du runtime | Pas de cas Apple « file pleine » ni « modèle invalide » : erreurs propres à la bibliothèque. `rateLimited`, `guardrailViolation`, `refusal`, `unsupportedLanguageOrLocale` sans source moteur. | P5 |
| Combinaisons | Schéma + outils, vision + outils, raisonnement + schéma | — | — | Chaque combinaison annoncée exige un test (conception). | P5/P7 |
| Hors protocole | Audio, embeddings, reranking | Existants dans le moteur | — | Non exposés via `LanguageModel`. | — |

### Squelette de conformité

`bindings/apple` (package `LlamaApple`, Swift 6, iOS/macOS 27) :

- `LlamaEngine` : `LlamaRuntime` (instance explicite, limites 1 actif / 4 en attente / 1 résident par défaut), `LlamaModelID`, `LlamaLoadProfile`, `LlamaEngineError`.
- `LlamaFoundationModels` : `LlamaLanguageModel` (léger : runtime + modèle + profil, aucune capacité déclarée), `LlamaLanguageModelExecutor` dont la `Configuration` compare le runtime **par identité**, et `RequestRequirements` qui détecte avant calcul schéma, outils, `required`, niveau de raisonnement, raisonnement/outils/images présents dans le transcript. Toute capacité non déclarée produit `LanguageModelError.unsupportedCapability` ; une requête texte produit `LlamaEngineError.engineUnavailable` tant que le pont (P2) manque.

Commandes exécutées depuis `bindings/apple` :

```bash
xcodebuild build-for-testing -scheme LlamaApple-Package -destination 'generic/platform=macOS' -derivedDataPath <dd> -quiet
xcodebuild build-for-testing -scheme LlamaApple-Package -destination 'generic/platform=iOS' -derivedDataPath <dd> -quiet
xcodebuild build-for-testing -scheme LlamaApple-Package -destination 'generic/platform=iOS Simulator' -derivedDataPath <dd> -quiet
xcodebuild test -scheme LlamaApple-Package -destination 'platform=iOS Simulator,id=C64BD9F4-EA4D-44EC-8613-F3A3AC915618' -derivedDataPath <dd>
```

Résultats : trois compilations réussies (code 0, sans avertissement) ; `TEST SUCCEEDED`, 8 tests dans 2 suites. Les tests macOS sont compilés mais non exécutables sur macOS 26.7.

## P1 — Signaux publics du moteur

### Constat avant modification

- Prompt trop long : erreur native `exceed_context_size_error` avec `n_prompt_tokens` et `n_ctx`, mais catégorie publique générique `inference_error`.
- Contexte rempli pendant la génération (`engine-context.cpp`, `process_token`) : `STOP_TYPE_LIMIT` + `truncated`, rendu en chat par `finish_reason: "length"`, comme le budget `max_tokens` ; `truncated` n’existe qu’au format natif.
- Context shift : réglage du modèle (`params_base.ctx_shift`, désactivé par défaut), pas de la requête.
- Compteurs existants, tous propres au résultat d’une tâche et donc à sa requête : `n_prompt_tokens` (images et outils du template inclus), `n_prompt_tokens_cache`, `n_decoded`, `prompt_progress` (`total`, `cache`, `processed`). Manquaient : la capacité effective du slot (`n_ctx`) dans les résultats et tout compteur de tokens de raisonnement. L’instantané `slots` est global et ne sert pas à l’attribution.

### Extension (opt-in, documentée dans [l’API du moteur](embedded-inference-engine-api.md))

- `fail_on_context_full: true` : contexte rempli avant le budget de sortie → erreur `context_exceeded`, `context_phase: "generation"`, `n_decoded`, après les fragments déjà livrés ; prompt trop long → `context_phase: "prompt"` ; budget atteint → succès `finish_reason: "length"`. Le context shift ne s’applique jamais à ces requêtes.
- `return_context: true` : objet `context` (`n_ctx`, `n_tokens`, `n_prompt_tokens`, `n_cache_tokens`, `n_decoded`, `n_reasoning_tokens`) dans les fragments streamés porteurs de deltas, ceux de `prompt_progress` et le résultat final (natif, completions, chat).
- `n_reasoning_tokens` : suivi des balises de raisonnement du template sur les tokens générés, par le détecteur de `common/reasoning-budget` instancié hors de la chaîne de sampling (aucun effet sur la génération). L’état initial vient du texte du prompt de génération (`<think>\n` ouvert par Qwen3.5) : avec le vocabulaire SPM de test, `<think>` ne se tokenise pas de la même façon isolé et dans le prompt.
- Catégorie publique `context_exceeded` pour toute erreur de contexte (auparavant `inference_error`). Le serveur lit le JSON natif (`read_native`, champ `code`) et n’utilise pas cette catégorie ; le CLI affiche le message, inchangé.
- Côté Swift (`bindings/apple`) : `LlamaContextReport`, `LlamaContextOverflow` (décodage des données natives), `LlamaEngineError.contextExceeded`, et conversion en `LanguageModelError.contextSizeExceeded(contextSize:tokenCount:)` avec la phase dans `debugDescription`.

### Preuves

Build dédié `build-apple-p1` (Release, Metal, moteur, outils, serveur, tests ; `LLAMA_ENGINE_TEST_MODEL=tools/server/tests/tmp/stories15M-q4_0.gguf`) :

```bash
cmake -S . -B build-apple-p1 -DCMAKE_BUILD_TYPE=Release -DLLAMA_BUILD_ENGINE=ON -DLLAMA_BUILD_TESTS=ON -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_EXAMPLES=ON -DLLAMA_ENGINE_TEST_MODEL=$PWD/tools/server/tests/tmp/stories15M-q4_0.gguf
cmake --build build-apple-p1 -j 10
(cd build-apple-p1 && ctest -j 6)
(cd tools/server/tests && LLAMA_SERVER_BIN_PATH=../../../build-apple-p1/bin/llama-server python -m pytest -m 'not slow' -q unit)
```

- Compilation sans erreur ni avertissement nouveau.
- `test-engine-context` (API publique, enregistré dans CTest) : **PASS**. Sortie : slot de 128 tokens (contexte d’entraînement de stories15M), prompt de 29 tokens ; « the context is full after 99 generated tokens (prompt: 29 tokens, context size: 128 tokens) » ; raisonnement 12/12. Il couvre :
  1. budget atteint → `length`, rapport `n_decoded = 8`, `n_tokens = prompt + 8`, streamé et non streamé ;
  2. contexte plein en génération → `context_exceeded`/`generation` après des fragments, sans `finish_reason`, streamé et non streamé ; sans le champ → `length` comme avant, sans objet `context` ;
  3. prompt trop long → `context_exceeded`, `context_phase: "prompt"` seulement avec le champ ;
  4. deux requêtes intercalées (lecteurs alternés, `parallel = 2`) → rapports monotones, `n_prompt_tokens` constants et distincts, `n_decoded` 6 et 20, `n_tokens` exacts pour chacune ;
  5. modèle avec `context-shift` → shift sans le champ (succès au-delà du contexte), erreur `generation` avec ;
  6. template Qwen3.5 → 12/12 tokens de raisonnement avec `enable_thinking`, 0 sans.
- CTest complet : **77/80**. Échecs : `test-jinja-py` (module `jinja2` absent du python système, environnement, déjà signalé par le rapport du moteur) ; `test-engine-operations` (grammaire de sortie structurée préfixée par le prompt de génération, refusée avec stories15M) et `test-engine-acquisition` (assertion sur la disparition de `test/slow:Q8_0` après annulation). Ces deux derniers échouent **à l’identique sur les sources moteur sans P1** (`git stash` de `engine/`, recompilation de la cible, même modèle) : ils ne sont pas causés par P1 et restent à analyser hors de ce travail.
- Tests HTTP du serveur sur le binaire P1, `-m 'not slow'` : **393 réussis, 6 ignorés**, 199 désélectionnés (même décompte que la qualification du moteur).
- Sonde Qwen3.5-2B Q4_K_M + `mmproj-BF16` (Metal, contexte 4096) : texte seul 19 tokens de prompt, même question avec `tools/mtmd/test-1.jpeg` 321 tokens (le coût de l’image est dans l’occupation) ; avec raisonnement, 157 tokens de raisonnement sur 160 générés puis la réponse « 5 » ; raisonnement coupé par le budget : 256/256.
- Swift : 12 tests sur simulateur iOS 27 (dont 4 de signaux de contexte, avec les charges natives capturées sur le moteur) ; compilation macOS 27 et iOS 27 appareil.

### Constats SDK

- `LanguageModelError.ContextSizeExceeded(…, metadata:)` : sur le runtime iOS 27.0 du simulateur, `metadata` revient vide. La phase et le diagnostic moteur sont donc portés par `debugDescription`.

### Limites

- `n_reasoning_tokens` dépend des balises que le template déclare ; un modèle sans balises reconnues compte 0.
- Les fragments sans delta (balises, marqueurs retenus par l’analyseur) ne portent pas d’objet `context` ; le fragment suivant ou le résultat final rattrape `n_decoded`.
- Responses et Messages n’exposent pas ces champs (non requis par l’adaptateur, qui utilise chat).

## P2 — Pont natif et distribution Apple

### Pont C (`bindings/apple/bridge`)

- `include/llama_bridge.h` : handles opaques `llama_bridge_engine`, `_request`, `_subscription`, `_event` ; requêtes et résultats aux contrats JSON du moteur ; pièces jointes `{name, bytes, size}` copiées avant retour. Opérations : création d’un catalogue, `submit` (chat, completion, tokenize, apply_template, …), `next` borné ou non, `cancel`, `catalog`, `load`, `unload`, `update_catalog`, `subscribe`, `stop`, destructions.
- Erreurs : chaque fonction est enveloppée ; une exception C++ devient un événement d’erreur possédé (`invalid_request`, `out_of_memory`, `bridge_error`) ; aucune ne traverse la frontière.
- Durée de vie (documentée dans l’en-tête) : un lecteur à la fois, `cancel` concurrent autorisé, destruction sans appel concurrent sur le même handle, requêtes et abonnements pouvant survivre au moteur.
- Framework dynamique `LlamaBridge` : llama, ggml (Metal, shaders embarqués, Accelerate), mtmd et moteur local liés statiquement ; seules les 21 fonctions `llama_bridge_*` sont exportées (`-exported_symbol`, visibilité cachée) ; sans acquisition réseau du moteur (ADR 0003) ni OpenSSL. Le CMake du pont inclut le dépôt comme sous-projet, sans modifier le CMake racine.

### Couche Swift (`LlamaEngine`, accès `package`)

`NativeEngine`, `NativeRequest`, `NativeSubscription`, `NativeEvent`. Les appels bloquants — `next`, `unload`, `update_catalog`, `stop`, la préparation de `submit` et les destructions — s’exécutent sur `NativeWorkers` (file GCD concurrente dédiée), jamais sur le pool coopératif ni le MainActor. L’annulation de la tâche Swift qui attend dans `next` annule la requête native. Un second lecteur simultané est refusé (`LlamaEngineError.concurrentReaders`). Les handles sont détruits sur un worker à la dernière référence. Les erreurs natives deviennent `LlamaEngineError.native(category:message:details:)`.

### Distribution

`scripts/build-apple-language-model.sh` construit cinq builds CMake dédiés (`build-apple-lm/<plateforme>-<arch>`), fusionne les architectures avec `lipo`, produit les dSYM et `bindings/apple/Frameworks/LlamaBridge.xcframework`, puis l’archive `build-apple-lm/LlamaBridge.xcframework.zip` et son checksum SwiftPM. Il ne supprime que ses propres sorties ; `build-xcframework.sh` et ses répertoires ne sont pas touchés.

| Slice | Architectures | `minos` | Binaire |
| --- | --- | --- | --- |
| `ios-arm64` | arm64 | iOS 27.0 | 15 Mo |
| `ios-arm64_x86_64-simulator` | arm64, x86_64 | iOS Simulator 27.0 | 32 Mo |
| `macos-arm64_x86_64` | arm64, x86_64 | macOS 27.0 | 32 Mo |

Archive : 186 Mo, dont la plus grande partie en dSYM. `Package.swift` référence l’XCFramework local (`binaryTarget(path:)`) ; le README décrit la variante `binaryTarget(url:checksum:)` pour une publication ultérieure.

### Preuves

| Vérification | Résultat |
| --- | --- |
| `test-llama-bridge` (consommateur C, stories15M, CPU) : entrées invalides, flux, pièces jointes copiées, annulation pendant une lecture d’un autre thread, annulation d’une requête bloquée derrière l’unique slot, déchargement pendant génération (lecteur terminé avec `unloaded`, rechargement automatique ensuite), destruction du moteur pendant une lecture (`stopped`, handle survivant), arrêt idempotent, soumission après arrêt | **PASS** (Release, CTest 1/1) |
| Même test sous ASan + UBSan | **PASS**, aucun rapport |
| Même test sous TSan | **PASS** après correction d’une course **dans le test** (drapeau non atomique), aucun rapport sur le pont ni le moteur |
| `xcodebuild test` du package sur simulateur iOS 27 (iPhone 17 Pro) | **20/20** : 12 tests existants et 8 `NativeEngineTests` sur le vrai moteur (création invalide typée, chat streamé avec chargement à la demande, flux `events()`, annulation de tâche → `cancelled`, 20 lecteurs bloqués nativement pendant ≥ 250 ms sans bloquer le pool coopératif (tâche détachée servie en < 100 ms), déchargement qui termine tous les lecteurs (`unloaded`), requête survivant à son moteur (`stopped`), second lecteur refusé) |
| Consommateur externe (package hors dépôt, dépendance par chemin) | Compilé pour iOS appareil et macOS ; exécutable macOS lié à `@rpath/LlamaBridge.framework` (`minos` 27.0) ; test exécuté sur le simulateur iOS 27 avec le framework embarqué dans le bundle de test : **PASS** |
| Reconstruction depuis un checkout propre (`git clone` de `81db64062`, puis `LLAMA_BRIDGE_TEST_MODEL=… scripts/build-apple-language-model.sh --test`) | **PASS** en 8 min 29 s : XCFramework, archive et checksum produits, `test-llama-bridge` 1/1. Le checksum diffère d’un build à l’autre (binaire non reproductible au bit près) : publier l’archive et le manifeste ensemble |
| Avertissements de compilation | Aucun dans le pont ; 7 avertissements de ggml Metal (API dépréciées dans le SDK 27, slices x86_64), hors périmètre |

### Observations et limites

- **Premier chargement sur simulateur : 29 s** pour le premier test qui charge le modèle (CPU, `gpu_layers = 0`), les suivants < 0,3 s. Attribution probable : compilation à l’exécution de la bibliothèque Metal embarquée lors de l’initialisation du backend. À mesurer sur iPhone en P7 ; une `metallib` précompilée (`GGML_METAL_EMBED_LIBRARY=OFF`) est l’alternative si le coût s’y retrouve.
- Le package ne se résout pas tant que l’XCFramework n’a pas été construit (documenté).
- L’identité d’un package local est son nom de dossier (`apple`), à utiliser dans `.product(…, package: "apple")`.
- Non fait en P2 : exécution sur iPhone (signature à configurer avec la démo, P6/P7) et sur macOS 27 (indisponible).

## P3 — Runtime Swift partagé et stockage des modèles

### Conception retenue

`bindings/apple/Sources/LlamaEngine` ; aucun changement du moteur C++ ni du pont C.

- **Instance explicite** : `LlamaRuntime(configuration:store:)` crée un `NativeEngine` en mode catalogue (vide, rien n’est chargé) ; aucun singleton. Le runtime est une classe `Sendable` ; la `Configuration` de l’executor le compare toujours par identité.
- **Artefact, profil, instance** : `LlamaModelArtifact` (identifiant, poids — tous les segments —, projecteur, copie gérée ou fichier de l’application) ; `LlamaLoadProfile` (contexte par génération, `LlamaComputeConfiguration` : déport GPU, threads, batchs, flash attention ; projecteur ; template ; options moteur supplémentaires). Une instance = artefact × profil, entrée du catalogue natif nommée `<id>@<empreinte du profil>` (SHA-256 tronqué d’une description canonique). Même artefact et même profil → même entrée → poids partagés ; tout écart de profil → entrée distincte. Les entrées sont ajoutées à la première utilisation par `update_catalog`, avec des réglages déterministes : les instances inchangées ne sont pas rechargées.
- **Une seule autorité d’admission** : la file Swift (`Admission`). Au plus `maximumActiveGenerations` générations actives (permis), au plus `maximumWaitingRequests` en attente, FIFO ; au-delà, `LlamaEngineError.queueFull` immédiat ; attente bornée par `admissionTimeout` (`admissionTimedOut`) et annulable. Chaque entrée native reçoit `parallel = maximumActiveGenerations` et `context_size = contexte × slots` (sans cache KV unifié, chaque slot a le contexte du profil) : une génération admise n’attend jamais un slot dans le moteur. Le `max_waiting` natif (générations admises + 64 chargements explicites) n’est qu’une borne de sûreté ; le `wait_timeout` natif (`loadTimeout`) ne couvre plus que le chargement et l’éviction. Constat qui motive ce choix : côté moteur, `max_waiting` ne compte que les requêtes en attente de chargement ; une fois le modèle résident, les tâches attendent un slot dans une file non bornée par cette limite.
- **Permis libéré une seule fois** : `AdmissionPermit` (drapeau sous verrou) est rendu à l’issue terminale lue, à l’annulation, à la fermeture par le runtime ou à la destruction du handle. Un ticket annulé ou expiré est retiré de la file sous verrou et ne peut plus être servi ; une génération fermée pendant sa soumission annule aussitôt sa requête native (`attach`).
- **Génération** (`LlamaGeneration`, accès `package` pour l’executor P5) : lecture tirée, sans tampon Swift ; la file native bornée (`max_events`) termine en `queue_full` un lecteur trop lent, jamais de perte silencieuse. `NativeRequest.events()` est devenu lui aussi tiré (il utilisait auparavant un `AsyncThrowingStream` au tampon non borné). Erreurs typées : `contextExceeded`, `unloaded`, `modelUnavailable`.
- **Chargement explicite mutualisé** (`load`) : un `SharedLoad` par instance ; l’annulation d’un appelant n’arrête que son attente ; si le dernier appelant part avant la fin, la requête native de chargement est annulée, ce qui retire une attente non commencée sans interrompre un chargement démarré (sémantique native conservée). Les générations chargent à la demande (`autoload`), en partageant le chargement natif.
- **Déchargement explicite** (`unload`) : ferme les admissions du modèle (`availability = unloading`), échoue ses attentes Swift, ferme ses générations, attend la fin des soumissions natives en cours, puis appelle `unload` natif pour chaque instance, sur les workers, et rouvre les admissions. Les appels concurrents partagent la même tâche. Le résultat est visible dans le snapshot au retour.
- **Observation** : `snapshot()` (modèles, disponibilité, instances avec état natif — `loading(progress:)`, `loaded`, `failed`… —, requêtes actives/en chargement, attentes d’admission par modèle, compteurs d’admission) et `updates(bufferLimit:)` : `.snapshot` d’abord, puis `.changed` ; au-delà de la limite, la file d’un abonné est remplacée par un unique `.resync(snapshot, droppedUpdates:)`. Les événements d’abonnement natifs (dont `resync` natif) alimentent une pompe qui relit le catalogue natif.
- **Stockage** (`LlamaModelStore`, racine par défaut `Application Support/LlamaModels`) : un répertoire par modèle avec `manifest.json` (persistant entre lancements). Import : vérification du magique GGUF, de tous les segments annoncés par le nom (`-00001-of-0000N.gguf`, le premier segment est exigé) et de l’espace libre (`volumeAvailableCapacityForImportantUsage`, avec 64 Mio de réserve) ; copie (clone APFS) dans `staging/`, manifeste, exclusion de la sauvegarde, puis un seul `rename` vers `models/<id>` ; nettoyage du staging en cas d’échec ou au démarrage suivant. Accès « security-scoped » pour les fichiers choisis par l’utilisateur. Suppression : `rename` vers `trash/` puis effacement. Le fichier source n’est jamais modifié ; un modèle ajouté par `register(_:)` n’est jamais effacé.
- **Absence de course** : import réservé par identifiant (`modelExists`) ; `removeModel` attend un déchargement en cours, ferme les admissions (`removing`), ferme les générations, attend les soumissions, retire les entrées par `update_catalog` (sous un mutex asynchrone qui sérialise toutes les mises à jour du catalogue natif), puis efface la copie gérée ; la création d’instance revérifie la disponibilité sous ce mutex.

### Preuves

Commandes exécutées depuis `bindings/apple` (XCFramework de P2, inchangé) :

```bash
xcodebuild test -scheme LlamaApple-Package -destination 'platform=iOS Simulator,id=C64BD9F4-EA4D-44EC-8613-F3A3AC915618' -derivedDataPath <dd>
xcodebuild test -scheme LlamaApple-Package -destination 'platform=iOS Simulator,id=C64BD9F4-EA4D-44EC-8613-F3A3AC915618' -derivedDataPath <dd> -test-iterations 10 -run-tests-until-failure
xcodebuild build-for-testing -scheme LlamaApple-Package -destination 'generic/platform=macOS' -derivedDataPath <dd>
xcodebuild build-for-testing -scheme LlamaApple-Package -destination 'generic/platform=iOS' -derivedDataPath <dd>
```

| Vérification (simulateur iOS 27, iPhone 17 Pro, stories15M CPU) | Résultat |
| --- | --- |
| Suite complète : 12 tests `LlamaFoundationModelsTests` + 21 `LlamaEngineTests` (8 P2, 13 P3) | **33/33** réussis |
| `configurationIsValidated`, `instanceIdentityFollowsArtifactAndProfile` : limites et identifiants refusés, identité d’instance | réussi |
| `twoSessionsShareOneInstance` : deux conversations intercalées, même profil → **un seul** passage natif à `loading` ; un autre profil → une seconde instance, la première reste chargée | réussi |
| `eachGenerationGetsTheProfileContext` : deux slots, `n_ctx` rapporté = contexte du profil | réussi |
| `fullQueueFailsExplicitly` : file pleine → `queueFull(1)` immédiat, snapshot `isQueueFull`, l’attente est servie après libération | réussi |
| `cancellingAWaitingRequestFreesItsPlaceOnce` : annulation en attente → place libérée une fois ; double fermeture d’une génération → un seul admis | réussi |
| `admissionWaitIsBounded` : `admissionTimedOut` après 200 ms | réussi |
| `unloadEndsRunningAndWaitingWorkAndKeepsHistories` : déchargement pendant une génération infinie et une attente → `unloaded` pour les deux ; instance `unloaded` au retour ; historique de l’appelant renvoyé → rechargement et succès | réussi |
| `concurrentLoadsShareOneNativeLoad` : trois `load` concurrents dont un annulé → un seul chargement natif | réussi |
| `slowSubscriberIsResynchronized` : abonné à limite 2 non lu → `resync` avec `droppedUpdates > 0`, puis fin de l’abonnement à l’arrêt | réussi |
| `importCopiesAtomicallyAndRemovalKeepsTheSource` : copie identique, exclusion de sauvegarde, staging vide, manifeste relu par un nouveau store, suppression pendant une génération (`modelUnavailable(removed)`), catalogue natif vide, source et projecteur intacts | réussi |
| `importChecksFilesAndSpace` : GGUF segmenté (3 segments copiés), segment manquant, segment non initial, fichier non GGUF, espace insuffisant (rien copié, source intacte), modèle enregistré jamais effacé | réussi |
| `catalogChangesKeepOtherModelsLoaded` : import, chargement et suppression d’un autre modèle pendant une génération → aucun rechargement du premier, génération terminée | réussi |
| Répétitions (`-run-tests-until-failure`) | Premier essai (5 itérations de `LlamaEngineTests`) : **échec** intermittent du test P2 `taskCancellationCancelsTheNativeRequest` (voir ci-dessous). Après correction : **10/10 répétitions** des 33 tests réussies, puis 3/3 après le dernier nettoyage. |
| `build-for-testing` macOS 27 et iOS 27 appareil | réussis, sans avertissement Swift |

Défauts trouvés par ces tests et corrigés avant le commit :

- décodage des dates du manifeste : le catalogue géré n’aurait pas survécu à un redémarrage ;
- comptage des chargements dans le test lui-même : le moteur republie `loading` quand une requête rejoint un chargement en cours ;
- **course de P2** dans `NativeRequest.next` : une tâche annulée entre deux lectures recevait `CancellationError` sans que la requête native soit annulée (le test P2 échouait par intermittence). Désormais, une lecture depuis une tâche annulée annule la requête native puis rend ses fragments restants et l’issue terminale `cancelled`, que l’annulation survienne pendant l’attente ou avant l’appel.

Le premier chargement de ces exécutions n’a pas reproduit les 29 s observées en P2 (test complet en 1 s, chargement compris) ; la cause du coût observé alors n’est pas établie. La mesure sur iPhone reste due en P7.

### Choix et limites

- **Résidence** comptée par instance native : deux profils du même modèle occupent deux places de `maximumResidentModels`.
- **Générations pour plusieurs modèles** : une génération admise pour un modèle non résident peut attendre côté moteur l’éviction d’un modèle actif (borne `loadTimeout`). C’est une attente de ressource, pas une seconde file d’admission ; elle conserve son permis.
- **Pendant un déchargement ou une suppression**, une nouvelle demande échoue explicitement (`modelUnavailable`) au lieu d’attendre ; une demande suivante recharge le modèle.
- **Réglages** : le catalogue géré est persistant (manifestes) ; les réglages de l’application (profil choisi, limites) relèvent de la démo (P6), la bibliothèque n’écrit rien d’autre.
- **Segments** : seuls les GGUF segmentés annoncés par leur nom sont reconnus ; les métadonnées `split.count` ne sont pas relues en Swift (llama.cpp les vérifie au chargement).
- **Copie** : `copyItem` clone sur APFS ; sur un autre volume, la copie d’un gros fichier n’est annulable qu’entre deux fichiers.
- Les tests de stockage utilisent de faux GGUF (magique seul) pour les segments et le projecteur ; ils ne valident pas le chargement d’un modèle segmenté ni de la vision (P5/P7).
- Les tests tournent sur simulateur ; iPhone et macOS 27 restent à exécuter (P7).

## P4 — Acquisition URLSession et catalogue qualifié

### Conception retenue

`bindings/apple/Sources/LlamaEngine` et `bindings/apple/Catalog` ; aucun changement du moteur ni du pont.

- **Manifeste versionné** (`LlamaModelCatalog`, format 1) : version de contenu, puis par modèle identifiant, source (dépôt + révision immuable), fichiers de poids (un fichier ou tous les segments dans l’ordre) et projecteur avec URL, taille et SHA-256, licence, template (`embedded` + SHA-256 du Jinja, ou nom de template llama.cpp), capacités **déclarées** et capacités **qualifiées** (sous-ensemble des déclarées), référence de la preuve. `decode`/`validate` refusent : autre version de format, révision non hexadécimale (`main`), URL ne contenant pas la révision, URL non https (http seulement vers la boucle locale, pour les tests), noms de fichiers dangereux ou dupliqués, `manifest.json`, SHA-256 invalide, taille nulle, suite de segments incohérente, vision sans projecteur, capacité qualifiée non déclarée, identifiant dupliqué.
- **Catalogue livré** (`Catalog/models.json`, version `2026-10-01`) : `qwen3.5-2b-q4_k_m`, `unsloth/Qwen3.5-2B-GGUF` à la révision `f6d5376be1edb4d416d56da11e5397a961aca8ae` (aussi tête de `main` au 1er octobre 2026), `Qwen3.5-2B-Q4_K_M.gguf` (1 280 835 840 octets, `aaf42c8b…9223`) et `mmproj-BF16.gguf` (671 372 992 octets, `f17196c0…d3c2`), licence apache-2.0 (métadonnée GGUF et carte du modèle, modèle non restreint), template intégré `7f0e5290…ed67` (7 816 caractères, contient raisonnement, outils et images). Capacités déclarées : outils, raisonnement, vision ; **qualifiées : aucune** tant que P5/P7 ne les ont pas prouvées avec l’adaptateur. La génération structurée n’est pas déclarée : elle dépend de la grammaire du moteur, pas du modèle, et sera qualifiée en P5.
- **Vérification des références** (`Catalog/verify-catalog.py`) : requête HEAD à la révision épinglée, comparaison de `x-repo-commit`, `x-linked-size` et `x-linked-etag` (SHA-256 des fichiers LFS de Hugging Face), et hachage des copies locales avec `--local`.
- **Téléchargements** (`LlamaModelDownloads`) : une instance par identifiant de session, créée au lancement. Session de fond par défaut (`sessionSendsLaunchEvents`, `isDiscretionary` et cellulaire configurables, conteneur partagé optionnel), session de premier plan possible. Un téléchargement par modèle ; ses fichiers sont transférés en parallèle dans `<store>/downloads/<id>`, exclu de la sauvegarde, jamais lu par le catalogue.
- **Identités persistantes** : `record.json` (entrée, jeton, phase, fichiers reçus/vérifiés) et données de reprise `<fichier>.resume`. Chaque tâche porte `{model, file, token, resumed}` dans `taskDescription`. À la création, l’instance relit les records (un fichier présent compte comme reçu — il n’arrive que par un `rename` complet — et sera revérifié), rattache par `allTasks` les tâches du jeton courant, annule les autres, signale `interrupted(transferLost)` les fichiers sans tâche, et ne relance rien d’elle-même. Le jeton change à chaque pause, reprise, échec ou abandon : les événements des anciennes tâches ne modifient plus l’état, sauf un fichier complet arrivé juste avant une pause, conservé.
- **États** : `downloading`, `paused`, `interrupted(issue)` (récupérable : erreurs de connectivité, HTTP 5xx/408/429, transfert perdu ou annulé par le système, avec la raison `NSURLErrorBackgroundTaskCancelledReasonKey`), `verifying`, `installing`, `failed(issue)` (HTTP 4xx, taille ou SHA-256 différents, espace, écriture locale, installation). Un échec arrête les autres transferts en conservant leurs données de reprise.
- **Reprise et redémarrage** : `pause` produit les données de reprise (`cancelByProducingResumeData`) ; `resume` repart de ces données, sinon du début. Sans validateur ni plages, URLSession ne fournit pas de données de reprise : le fichier redémarre. Une tâche lancée depuis des données de reprise qui échoue hors connectivité et sans nouvelles données est relancée une fois depuis le début (données inutilisables). Après `failed`, `resume` redémarre le fichier en échec ; les autres gardent leurs données. `cancel` abandonne et efface ; il est refusé (`downloadInstalling`) pendant l’installation.
- **Validation et installation** : taille puis SHA-256 de chaque fichier, sur une file utilitaire dédiée (jamais le pool coopératif). Quand tous les fichiers sont vérifiés, `LlamaRuntime.installDownload` réserve l’identifiant, déplace les fichiers (même volume) dans un staging, écrit le manifeste du store avec l’entrée de catalogue, exclut le répertoire de la sauvegarde, puis un seul `rename` vers `models/<id>` ; le modèle apparaît alors dans le runtime avec `catalogEntry`. Un projecteur absent, partiel ou en échec laisse le modèle hors du catalogue : aucune capacité vision ne peut en sortir. En cas d’échec d’installation, les fichiers retournent au téléchargement.
- **Espace** : vérifié au démarrage (taille totale) et à la reprise (reste à transférer), avec la réserve de 64 Mio du store ; refus avant toute requête.
- **Observation** : `snapshot()` et `updates()` comme le runtime (le hub d’observation de P3 est devenu générique, `LlamaStateUpdate<Snapshot>` ; `LlamaRuntimeUpdate` reste un alias). Progression publiée au plus toutes les 100 ms par téléchargement.
- **Cycle de vie de l’application** : `handleBackgroundEvents(forSession:completionHandler:)` pour `application(_:handleEventsForBackgroundURLSession:completionHandler:)`, `backgroundEventsFinished()` pour `.backgroundTask(.urlSession(_:))` de SwiftUI ; un lot d’événements livré avant l’appel est mémorisé. Le système poursuit les transferts d’une session de fond quand l’application est suspendue ou terminée par le système ; il les annule lorsque l’utilisateur force la fermeture, et ils apparaissent `interrupted` au lancement suivant. Aucune poursuite n’est promise après une fermeture forcée.

### Preuves

Commandes exécutées depuis `bindings/apple` (XCFramework de P2 inchangé) :

```bash
bindings/apple/Catalog/verify-catalog.py --local ~/.cache/huggingface/hub/models--unsloth--Qwen3.5-2B-GGUF/snapshots/f6d5376be1edb4d416d56da11e5397a961aca8ae
xcodebuild test -scheme LlamaApple-Package -destination 'platform=iOS Simulator,id=C64BD9F4-EA4D-44EC-8613-F3A3AC915618' -derivedDataPath <dd> -test-iterations 5 -run-tests-until-failure
TEST_RUNNER_LLAMA_DOWNLOAD_REAL_CATALOG=1 xcodebuild test -scheme LlamaApple-Package -destination 'platform=iOS Simulator,id=C64BD9F4-EA4D-44EC-8613-F3A3AC915618' -derivedDataPath <dd> -only-testing:'LlamaEngineTests/DownloadTests/realCatalogEntryDownloadsAndInstalls()'
xcodebuild build-for-testing -scheme LlamaApple-Package -destination 'generic/platform=macOS' -derivedDataPath <dd>
xcodebuild build-for-testing -scheme LlamaApple-Package -destination 'generic/platform=iOS' -derivedDataPath <dd>
```

| Vérification | Résultat |
| --- | --- |
| `verify-catalog.py` : révision, taille et SHA-256 annoncés par Hugging Face ; copies locales hachées | **OK** pour les deux fichiers ; le CDN (redirection 302) répond `206` avec `ETag` et `Accept-Ranges: bytes` |
| `shippedCatalogIsValid`, `invalidCatalogsAreRefused` : catalogue livré décodé et validé ; 12 entrées invalides refusées, segments valides acceptés, doublon et format 2 refusés | réussi |
| `downloadVerifiesAndInstallsTheWholeSet` : poids + projecteur, contenu identique, `catalogEntry` persistée et relue par un nouveau store, exclusion de sauvegarde, répertoire de transfert supprimé ; second `start` → `modelExists` | réussi |
| `interruptedTransferResumesWithARange` : coupure à 200 000 octets → `interrupted(network)` avec données de reprise ; `resume` → `Range: bytes=200000-` et `If-Range: "w1"` | réussi |
| `serverWithoutRangesRestartsCleanly` : ni validateur ni plages → pas de données de reprise ; second GET complet sans `Range` | réussi |
| `fileChangedOnTheServerFailsTheDigest` : contenu et ETag changés pendant l’interruption → le serveur renvoie le nouveau fichier entier (`If-Range` ne correspond plus) → `failed(digestMismatch)`, rien installé, fichier supprimé ; serveur rétabli, `resume` → nouveau GET complet et installation | réussi |
| `partialProjectorNeverMakesTheModelLoadable` : projecteur en 404 → `failed(httpStatus 404)`, poids vérifiés mais modèle absent du runtime et du store, `load(usesProjector:)` → `modelNotFound` ; 503 → `interrupted` ; puis seul le projecteur est retransféré | réussi |
| `resumingKeepsTheOtherTransfersRunning` : projecteur coupé pendant que les poids transfèrent → `interrupted` ; `resume` → la tâche des poids continue de rapporter sa progression sous le nouveau jeton ; un seul GET des poids | réussi ; **échoue sans la correction** (vérifié) |
| `pauseKeepsResumeDataAndResumeContinues` : pause en cours de transfert ralenti → `paused`, données de reprise, aucun événement tardif ne change l’état ; reprise par plage | réussi |
| `cancelAbandonsTheDownloadAndItsData` : abandon → disparition, répertoire effacé, second abandon `downloadNotFound`, nouveau départ non perturbé par les anciennes tâches, `downloadExists` sur doublon | réussi |
| `stateSurvivesARelaunch` : fin de session pendant un transfert → nouvelle instance : `interrupted(transferLost)` sans relance automatique ; pause puis nouvelle instance : `paused`, reprise par plage | réussi |
| `receivedFilesAreVerifiedAgainAfterARelaunch` : fichier reçu altéré sur disque avant relance → revérifié → `failed(digestMismatch)` ; retry → installé | réussi (a d’abord **échoué** : voir ci-dessous) |
| `unusableResumeDataRestartsCleanly` : données de reprise corrompues → redémarrage propre sans `Range` | réussi |
| `insufficientSpaceIsRefusedBeforeAnyTransfer` | réussi, aucune requête émise |
| `observationReportsTheStates` : `downloading` → … → `installing`, puis disparition | réussi |
| `backgroundSessionDownloads` (session de fond) | **ignoré** hors app hôte (voir limites) |
| `realCatalogEntryDownloadsAndInstalls` (opt-in) : entrée Qwen depuis Hugging Face via le CDN, session de premier plan, simulateur | **réussi, 2 exécutions** : pause après ~50 Mo avec données de reprise pour les deux fichiers ; à la reprise, la progression des poids (26 498 586 octets à la pause) ne redescend jamais sous ce point, donc reprise par plage à travers la redirection ; 1 952 208 832 octets vérifiés et installés en 247 s puis 310 s ; `catalogEntry` et projecteur présents |
| Suite complète, 5 itérations (`-run-tests-until-failure`) | **50 tests** (12 + 38 dont 2 ignorés) réussis à chaque itération |
| `build-for-testing` macOS 27 et iOS 27 appareil | réussis, sans avertissement Swift dans le package |

Défauts trouvés par ces tests et corrigés :

- après un échec d’intégrité, l’annulation des autres transferts du même modèle conservait le jeton courant : elle était prise pour une annulation système et remplaçait `failed(digestMismatch)` par `interrupted(transferLost)`. L’arrêt après échec change désormais le jeton ;
- relecture, puis test dédié : `resume` d’un téléchargement `interrupted` changeait le jeton alors qu’un autre fichier transférait encore ; sa progression était ignorée et une erreur ultérieure l’aurait été aussi, laissant le téléchargement en `downloading` sans tâche. Les tâches vivantes sont désormais ré-étiquetées (`taskDescription`) avec le nouveau jeton ;
- relecture : une tâche créée par `start` avant la fin du rattachement aurait été annulée comme inconnue ; `pause` n’arrêtait pas les transferts restants d’un téléchargement `interrupted` ; un lot d’événements de fond livré avant l’appel de l’application n’était pas consommé une seule fois. Corrigés avant la dernière série.

### Choix et limites

- **Session de fond et tests** : le système refuse une session de fond au processus `xctest` du package (« Background URLSession adopters are required to have matching bundle identifier… and code signing identifier ») ; le transfert y stagne à 64 Kio. Les tests utilisent donc une session de premier plan, de comportement identique pour le délégué ; `backgroundSessionDownloads` s’active dans une app hôte. Dans un même processus, une seconde session ne peut pas réutiliser l’identifiant d’une session vivante : le rattachement par `allTasks` après relance n’est vérifiable qu’en relançant l’application.
- **Scénario réel en arrière-plan sur iPhone : non exécuté.** Il exige une application signée ; il sera exécuté avec la démo (P6) puis consigné en P7 : transfert poursuivi app suspendue, relance système avec `handleEventsForBackgroundURLSession`, fermeture forcée → `interrupted`.
- **Reprise** : dépend du serveur (validateur, plages) et des données conservées par le système ; sans elles, le fichier redémarre proprement. Les URL signées du CDN de Hugging Face expirent : la reprise réelle s’est faite quelques secondes après la pause ; une reprise après expiration n’est pas testée (URLSession relance la requête d’origine, qui produit une nouvelle redirection).
- **Intégrité** : vérifiée après transfert, le fichier étant écrit par le système ; la durée du hachage sur iPhone reste à mesurer (P7). Un hachage interrompu par la suspension de l’app reprend au lancement suivant.
- **Fichiers en parallèle** : les fichiers d’un modèle sont transférés simultanément ; le système borne les connexions par hôte.
- **Imports locaux** : aucune capacité ne leur est attribuée ; seul un modèle installé depuis le catalogue porte une `catalogEntry` (et donc des capacités qualifiées, quand il y en aura).

## P5 — LanguageModel, executor et conformité Foundation Models

### Constats du SDK (simulateur iOS 27, sonde par un modèle scripté)

- En mode `toolCallingMode: .required`, Foundation Models **répète** `required` dans la requête qui suit l’exécution des outils. Traduire `required` par « un appel à chaque requête » ferait boucler la session : l’executor l’interprète comme « au moins un appel d’outil dans la réponse au dernier prompt » (`required` tant qu’aucune entrée `toolCalls` ne suit le dernier prompt, `auto` ensuite).
- L’identifiant d’un `ToolOutput` est celui de l’appel ; les arguments du transcript sont réécrits par le framework (`{"expression": "6*7"}`).
- Avec des outils et sans instructions, la session ajoute une entrée `instructions` vide qui porte les définitions : elle ne produit pas de message système.
- `includeSchemaInPrompt` vaut `true` par défaut avec un type `Generable`, et le prompt porte alors `responseFormat` ; avec `false`, ni l’un ni l’autre.
- `updateUsage` remplace, pour la requête, les comptes déduits des `tokenCount` des fragments ; `session.usage` cumule les requêtes.
- Une erreur levée après des fragments arrive telle quelle à l’appelant et le tour est retiré du transcript (politique par défaut) ; la requête suivante repart du dernier tour complet.
- `GenerationOptions(maximumResponseTokens: 0)` est neutralisé par le framework (journal « must be positive ») : l’executor ne le reçoit jamais.
- Annuler la tâche qui attend `respond`, ou celle qui consomme `streamResponse`, annule la tâche de l’executor.

### Extensions du moteur

Documentées dans [l’API du moteur](embedded-inference-engine-api.md#sortie-structurée--vérification-stricte-et-outils) :

- `strict_json_schema` (opt-in, chat) : `json_schema_check_strict` réutilise le convertisseur de la grammaire en mode strict ; un motif hors du sous-ensemble pris en charge devient une erreur `invalid_request` qui nomme la règle (au lieu d’un avertissement et d’une chaîne libre), pour le `response_format` comme pour les paramètres d’outils. Avec outils et format à la fois, un format de chat qui ne sait pas les combiner est refusé.
- Format Qwen3-Coder / Qwen3.5 : outils et `response_format` combinés (`auto` → appels d’outils **ou** JSON du schéma, grammaire non paresseuse ; `required` → appels d’outils seulement). Auparavant `auto` échouait (« failed to parse grammar », grammaire paresseuse sans déclencheur) et `required` ignorait silencieusement les outils. Les autres formats ne changent pas.

### Adaptateur (`bindings/apple/Sources/LlamaFoundationModels`)

- **Modèle et executor** : `LlamaLanguageModel` reste une valeur légère (runtime, modèle, profil, moniteur facultatif) ; l’executor utilise la frontière moteur `LlamaChatBackend` (le runtime partagé ; un moteur scripté dans les tests). `respond` charge le modèle si besoin ; `prewarm` lance seulement un chargement en tâche de fond.
- **Capacités** : génération guidée toujours déclarée (grammaire du moteur, quel que soit le modèle) ; outils, raisonnement et vision depuis les capacités **qualifiées** de l’entrée de catalogue d’un modèle téléchargé, ou depuis `capabilities:` fourni explicitement par l’application ; rien pour un import. La vision exige en plus `usesProjector` et un projecteur. Les refus ont lieu avant tout calcul (`unsupportedCapability`).
- **Transcript** complet à chaque requête, sérialisé de façon déterministe (clés ordonnées) pour que le préfixe rendu reste réutilisable par le cache du moteur : instructions → `system`, prompts → `user`, raisonnement rattaché au tour assistant qui suit (`reasoning_content`), réponses et appels d’outils regroupés dans un message `assistant` (IDs conservés), sorties d’outils → `tool` avec `tool_call_id`. Images converties en PNG, orientation appliquée, à leur position parmi les textes, transmises en pièces jointes possédées (`attachment:image-N`) ; conversion hors du pool coopératif. Une pièce jointe dans une sortie du modèle est refusée (`unsupportedTranscriptContent`).
- **Options** : `greedy` → `samplers: ["top_k"]`, `top_k: 1` ; `random(top:)` → `["top_k", "temperature"]` ; `random(probabilityThreshold:)` → `["top_p", "temperature"]` (la chaîne par défaut du moteur — pénalités, DRY, min-p… — n’est jamais ajoutée à un mode choisi) ; sans mode, les réglages du modèle. Seed : 32 bits côté moteur, `0xFFFFFFFF` signifiant aléatoire → refus au-delà de 4 294 967 294 (`LlamaLanguageModelError.unsupportedOption`), de même que top-k ≤ 0, seuil hors de ]0, 1] et température négative. `maximumResponseTokens` → `max_tokens` (tous les tokens générés, raisonnement et appels compris).
- **Schémas** (`SchemaTranslation`) : liste blanche des mots-clés produits par l’encodeur du SDK (relevés sur un schéma couvrant tous les guides), refus des bornes de nombres flottants (ignorées par la grammaire), motifs ancrés (le guide porte sur toute la chaîne), `\d \w \s` réécrits en classes ASCII (sous-ensemble des classes Unicode de Swift : restriction, jamais élargissement), `\D \W \S \b \p` refusés, `"$ref": "#"` réécrit en définition, propriétés dans l’ordre de déclaration (`x-order`). Le reste est vérifié par le moteur (`strict_json_schema`). Diagnostic : `unsupportedGenerationGuide(schemaName:)` avec le chemin de la propriété ou la règle du moteur. Avec `includeSchemaInPrompt`, le schéma traduit est écrit à la fin du prompt.
- **Outils** : `allowed` → `auto`, `disallowed` → `none` (outils toujours décrits, pour un rendu stable), `required` → voir les constats. `required` sans outil activé est refusé.
- **Raisonnement** : `nil` → défaut du template (Qwen3.5 raisonne) ; `.custom("none")` → `enable_thinking: false` ; `light`/`moderate`/`deep`/`custom(x)` → `reasoning_effort` (`low`/`medium`/`high`/`x`) seulement si `chat_template_caps.supports_reasoning_effort` (lu par l’opération `properties` du moteur), sinon refus `unsupportedCapability(.reasoning)`. Un modèle qui ne déclare pas le raisonnement reçoit `enable_thinking: false`.
- **Flux** (`StreamTranslation`) : deltas `reasoning_content` → `reasoning.appendText`, `content` → `response.appendText` (un seul segment), `tool_calls` → `toolCalls.toolCall(id:name:appendArguments)` dans l’ordre des index ; le nombre de tokens d’un fragment vient de `context.n_decoded`. À la fin, chaque appel doit être un objet JSON complet, sinon `LlamaLanguageModelError.incompleteToolCall` (avec « limite de tokens » si `finish_reason: length`) ; puis `updateUsage(input: n_prompt_tokens/n_cache_tokens, output: n_decoded/n_reasoning_tokens)`.
- **Requête moteur** : `stream`, `fail_on_context_full`, `return_context`, `return_progress`, `strict_json_schema` toujours présents.
- **Erreurs** : contexte plein → `LanguageModelError.contextSizeExceeded` (phase dans `debugDescription`) ; refus de schéma du moteur → `unsupportedGenerationGuide` ; format sans combinaison outils + schéma → `unsupportedCapability(.toolCalling)` ; image refusée par le moteur → `unsupportedCapability(.vision)` ; annulation → `CancellationError` ; file pleine, attente expirée, modèle déchargé, retiré ou absent, erreurs natives → `LlamaEngineError` inchangée (pas de cas Apple correspondant). Une erreur après des fragments reste une erreur.
- **Annulation** : la requête native est annulée par l’annulation de la tâche (lecture tirée de P3) et, en sortie anticipée, par `cancel()` ; l’admission est rendue une fois.
- **Moniteur** (`LlamaGenerationMonitor`, un par conversation, pour P6) : phase (`waiting`, `processingPrompt`, `generating`, `idle`), progression du prompt (`prompt_progress`), dernier rapport de contexte (`n_tokens` / `n_ctx` effectif) marqué vivant pendant la requête puis « dernière mesure » ; absence de mesure = `nil`, jamais zéro. Mises à jour par état (`bufferingNewest(1)`), jamais de deltas.

### Preuves

Commandes exécutées :

```bash
cmake --build build-apple-p1 -j 8 && (cd build-apple-p1 && ctest -j 4)
(cd tools/server/tests && LLAMA_SERVER_BIN_PATH=../../../build-apple-p1/bin/llama-server ../../../.venv-server-tests/bin/python -m pytest -m 'not slow' -q unit)
scripts/build-apple-language-model.sh
cd bindings/apple
TEST_RUNNER_LLAMA_QWEN_OFFLOAD=none TEST_RUNNER_LLAMA_QWEN_DIR=<snapshot Qwen3.5-2B> \
  xcodebuild test -scheme LlamaApple-Package -destination 'platform=iOS Simulator,id=C64BD9F4-EA4D-44EC-8613-F3A3AC915618' -derivedDataPath <dd>
xcodebuild build-for-testing -scheme LlamaApple-Package -destination 'generic/platform=macOS' -derivedDataPath <dd>
xcodebuild build-for-testing -scheme LlamaApple-Package -destination 'generic/platform=iOS' -derivedDataPath <dd>
```

| Vérification | Résultat |
| --- | --- |
| `test-chat` : Qwen3.5 outils + schéma (`auto` → JSON accepté, `auto` → appel accepté, `required` → appel accepté), parseur **et** grammaire | réussi ; le cas `required` échoue sans la modification |
| `test-json-schema-to-grammar` : contrôle strict (motif accepté ; lookahead nommé par sa propriété, motif non ancré, motif invalide, `$ref: "#"` refusés) | réussi |
| CTest complet | **77/80**, les trois mêmes échecs qu’en P1 (`test-jinja-py` environnement ; `test-engine-operations` : préremplissage de grammaire avec stories15M, voir limites ; `test-engine-acquisition`) |
| Tests HTTP du serveur, `-m 'not slow'` | **393 réussis, 6 ignorés** (identique à P1) |
| Sonde `llama-server` Qwen3.5-2B : outils + schéma | `auto` et `required` → deux appels `calculate` ; tour suivant → nouvel appel ou JSON ; motif `\d+` non ancré refusé (`response_format: … pattern \d+ of answer is not supported`) |
| `AdapterTests` (27, adaptateur réel, moteur scripté, sessions Foundation Models réelles) : flux UTF-8 (accents, emoji) en un segment et usage ; sérialisation déterministe ; transcript complet (rôles, raisonnement, IDs d’appels, sorties, image tournée 4×2 → 2×4 à sa position) ; refus d’une image dans une sortie ; deux sessions sans contamination ; sampling exact ; refus des options non représentables avant soumission ; politiques d’outils dont `required` puis `auto` ; niveaux de raisonnement ; schémas (ordre, ancrage, `\d`, récursion, refus localisés, rendu dans le prompt) ; boucle à deux outils aux arguments fragmentés ; outils + `@Generable` ; appel coupé par la limite ; erreur après fragments puis requête suivante propre ; prompt trop long ; erreurs du runtime typées ; annulation par `respond` et par le consommateur du flux ; capacités issues de la qualification ; vision sans projecteur ; moniteur | **27/27** |
| `EngineAdapterTests` (9, vrai moteur, stories15M CPU) : flux et cache de préfixe (`cachedTokenCount > 0` au 2e tour) ; sortie `@Generable` contrainte par la grammaire (enum, entier borné, tableau de 2) ; motif refusé par le moteur avec le nom du schéma ; outils + schéma sans format adapté → `unsupportedCapability(.toolCalling)` ; lecture de `chat_template_caps` ; prompt trop long ; contexte plein en génération (≠ budget) ; deux sessions, une instance ; déchargement pendant une réponse puis rechargement | **9/9** |
| `QwenTests` (12, Qwen3.5-2B Q4_K_M + `mmproj-BF16`, catalogue, CPU du simulateur) : texte (« Paris ») ; raisonnement séparé (101 tokens, réponse « 42 », sans balises) ; niveau `deep` refusé ; sortie structurée streamée (35 instantanés, Paris/France/3 monuments) ; raisonnement + structuré (42) ; boucle à deux outils (`calculate:42`, `lookup:3 EUR`, réponse les citant) ; outils + `@Generable` avec `required` (492) ; vision (« MOON ») ; vision avec orientation `.right` d’une image tournée ; deux sessions simultanées (Rome, Madrid, une instance) ; annulation en 17 à 25 ms ; contexte plein avant (phase `prompt`) et pendant la génération (phase `generation`), budget atteint = réponse | **12/12** (voir l’exécution complète ci-dessous) |
| Suite complète du package (exécution finale, `LlamaEngineTests` et `LlamaFoundationModelsTests` en parallèle sur des clones du simulateur) | 92 tests, 2 ignorés par conception (session de fond, téléchargement réel) ; **89 réussis** ; `QwenTests.vision()` interrompu pendant l’encodage de l’image (« unexpected exit, crash, or test timeout », sans rapport de plantage : deux processus chargeant le modèle sur le CPU émulé), puis **réussi seul** en 201 s |
| Compilation macOS 27 et iOS 27 appareil | réussie, sans avertissement dans le package |

### Limites et observations

- **Metal du simulateur** : avec `offload: .all`, le chargement du projecteur plante (`ggml_metal_buffer_set_tensor` dans `clip_model_loader::load_tensors`) et, sans projecteur, la restauration d’un checkpoint de prompt du modèle hybride Qwen3.5 avorte (`checkpoint size mismatch: expected 20201932, got 0`, `common_prompt_checkpoint::load_tgt`). La même séquence ne plante pas sur Metal natif (serveur sur le Mac). Les tests Qwen tournent donc sur le CPU du simulateur ; Metal reste à qualifier sur iPhone (P7). Le premier chargement CPU prend ~27 s et une image ~3 min sur ce CPU émulé : ces durées ne sont pas des mesures d’appareil.
- **Raisonnement + schéma dans le prompt (Qwen3.5-2B)** : en glouton comme en échantillonnage par défaut, le modèle raisonne souvent sur le schéma jusqu’à la limite de tokens (1 essai sur 3 en défaut, 3 sur 3 en glouton) ; la session finit alors sans réponse. Sans le schéma dans le prompt, la grammaire suffit (test réussi). À reprendre pour la démo : schéma hors prompt ou raisonnement coupé pour les réponses structurées.
- **Niveaux de raisonnement** : sans `reasoning_effort` dans le template (cas de Qwen3.5), seuls `nil` et `.custom("none")` sont traduisibles.
- **Arguments d’outils** : dans le format XML de Qwen3.5, un paramètre de type chaîne est généré librement (le format n’a pas de guillemets) ; un `enum` ou un motif sur un tel paramètre n’est donc pas imposé par la grammaire. Foundation Models décode ensuite les arguments vers le type `Arguments` de l’outil ; le comportement de ce décodage face à une valeur hors contrainte n’a pas été vérifié. Les paramètres non chaîne sont contraints. Écart à traiter (grammaire de chaîne contrainte dans le format XML) ou à refuser explicitement avant de déclarer un outil à paramètre chaîne contraint.
- **Préremplissage de la grammaire (moteur)** : `common_sampler_init` écarte un premier token du prompt de génération qui commence par un espace ; avec un vocabulaire où les marqueurs du template ne sont pas spéciaux (stories15M + chatml), ce token contient aussi `<` et l’initialisation échoue. Les tests de sortie contrainte sur stories15M utilisent donc un template sans prompt de génération. C’est la cause de l’échec préexistant de `test-engine-operations` ; non corrigé ici (comportement partagé avec le serveur).
- **Formats de chat** : seule la famille Qwen3-Coder / Qwen3.5 combine outils et sortie structurée ; ailleurs l’adaptateur refuse explicitement.
- **Signature de raisonnement** : non produite ; une signature reçue dans un transcript est ignorée (le texte du raisonnement est transmis au template, qui décide de le rejouer).
- iPhone et macOS 27 : non exécutés (P7).

## P6 — Nouvelle démo SwiftUI

### Conception retenue

- **Projet** `examples/llama.foundationmodels/LlamaFMDemo.xcodeproj`, écrit à la main au format Xcode 16+ (`objectVersion 77`, groupes synchronisés avec le système de fichiers : un fichier ajouté dans `LlamaFMDemo/`, `LlamaFMDemoTests/` ou `LlamaFMDemoUITests/` appartient à sa cible). Une cible d’application multiplateforme (iOS 27, macOS 27), des tests unitaires hébergés par l’application et des tests d’interface. Schémas partagés : `LlamaFMDemo` (application et tests unitaires) et `LlamaFMDemoUITests` (parcours avec Qwen, lents, à lancer exprès). Dépendance au package local `bindings/apple` ; le catalogue est `bindings/apple/Catalog/models.json`, copié dans l’application. `examples/llama.swiftui` n’est pas modifié.
- **Modèle d’application** (`AppModel`, `@MainActor @Observable`) : un `LlamaRuntime` (un modèle résident, une génération, quatre requêtes en attente), un `LlamaModelDownloads` créé au lancement avec la session de fond par défaut (lancements en arrière-plan compris, `.backgroundTask(.urlSession(_:))`), le catalogue, les réglages (JSON dans `UserDefaults`) et les conversations, en mémoire seulement. Chaque action longue (téléchargement, import, chargement, déchargement, suppression, génération) tourne dans une tâche ; son état (`running`) et son erreur (`errors[action]`) s’affichent sur la ligne de l’action.
- **Conversation** : une `LanguageModelSession` (transcript et outils à Foundation Models) et un `LlamaGenerationMonitor`. Les tours affichés (fragments, raisonnement, appels et sorties d’outils, réponse ou `CityGuide` partiel) sont distincts du transcript autoritatif. Une conversation garde le modèle et le profil de chargement de son début ; choisir un autre modèle, ou « Start a conversation with these settings », en crée une nouvelle et les autres restent consultables (une conversation vide remplacée est retirée). « Retry » soumet une fois la requête interrompue, avec les mêmes options.
- **Capacités et options** : outils, raisonnement et images ne sont proposés que pour ce que `LlamaLanguageModel.capabilities` déclare (catalogue qualifié ; rien pour un import) ; une image est refusée au compositeur avec la raison (import non qualifié, modèle sans vision, projecteur non chargé). `toolCallingMode` `allowed`/`disallowed` seulement si le modèle a les outils ; niveau de raisonnement `nil` (défaut du template) ou `.custom("none")` seulement si le modèle raisonne ; « City guide » met le schéma dans le prompt sans raisonnement et hors du prompt avec raisonnement (limite de Qwen3.5-2B relevée en P5).
- **Indicateurs** : `ActivityStatus` (en file avec le nombre d’attentes, chargement du modèle avec sa progression, attente, traitement du prompt avec sa progression, génération) et `ContextGauge` (occupé / capacité effective du moteur ; « Current request », « Last measure », ou « Unavailable » sans mesure, jamais zéro). `session.usage` n’apparaît que par réponse, comme consommation.
- **Cycle de vie** (`LifecyclePolicy`) : sur iOS, seul le passage réel en arrière-plan (`ScenePhase.background`) annule les générations et les attentes des chargements explicites ; `inactive` (sélecteur, sélecteur d’apps) ne change rien ; rien ne reprend au retour. Sur macOS, jamais. Les téléchargements suivent leur propre cycle de vie.
- **Images** : photothèque (`PhotosPicker`) ou fichier ; décodage et réduction à 1536 px hors de l’acteur principal ; l’orientation EXIF est lue, pas appliquée, et transmise à `Attachment(_:orientation:)`.
- **Simulateur** : calcul CPU par défaut (Metal du simulateur inutilisable avec Qwen3.5, voir P5).

### Constats du SDK (simulateur iOS 27.0)

- **Annulation d’un flux** : annuler la tâche qui consomme `streamResponse` termine le flux **sans erreur**, et Foundation Models **garde la réponse partielle dans le transcript** (une erreur, elle, retire le tour). La démo vérifie l’annulation après la boucle (`Task.checkCancellation()`) et retire les entrées du tour de `session.transcript` (modifiable en iOS 27 hors réponse) : le contexte repart bien du dernier tour complet. Documenté dans le README du package.
- **Retenue du dernier événement** : un fragment n’apparaît dans les instantanés qu’à l’arrivée de l’événement suivant, ou à la fin (test `fragmentsShowBeforeTheEnd`). Sans effet visible avec un vrai modèle (un token de retard) ; le dernier fragment d’un flux annulé peut ne jamais s’afficher.
- `Snapshot.transcriptEntries` contient les entrées du tour en cours (raisonnement, appels et sorties d’outils, réponses) : la démo les affiche dans l’ordre et remplace la dernière réponse par le texte ou la valeur partielle en cours.

### Preuves

Commandes exécutées :

```bash
cd examples/llama.foundationmodels
xcodebuild test -project LlamaFMDemo.xcodeproj -scheme LlamaFMDemo -destination 'platform=iOS Simulator,id=C64BD9F4-EA4D-44EC-8613-F3A3AC915618' -derivedDataPath <dd>
xcodebuild build-for-testing -project LlamaFMDemo.xcodeproj -scheme LlamaFMDemo -destination 'generic/platform=macOS' -derivedDataPath <dd> CODE_SIGNING_ALLOWED=NO
xcodebuild build-for-testing -project LlamaFMDemo.xcodeproj -scheme LlamaFMDemo -destination 'generic/platform=iOS' -derivedDataPath <dd> CODE_SIGNING_ALLOWED=NO
xcodebuild test -project LlamaFMDemo.xcodeproj -scheme LlamaFMDemoUITests -destination 'platform=iOS Simulator,id=C64BD9F4-EA4D-44EC-8613-F3A3AC915618' -derivedDataPath <dd>
```

| Vérification | Résultat |
| --- | --- |
| `LlamaFMDemoTests` — modèle de présentation contre un `LanguageModel` scripté pilotant de vraies `LanguageModelSession` : flux (UTF-8, emoji) ; erreur après fragments (fragments gardés, transcript au dernier tour complet, « Retry » soumis une seule fois, transcript resoumis vérifié) ; annulation (fragments, retour arrière du transcript, réessai) ; message de contexte plein ; sortie structurée en flux ; options selon les capacités ; politique de cycle de vie ; indicateurs ; outils | **13/13** |
| `LlamaFMDemoTests` — modèle d’application sur le vrai moteur (stories15M, CPU) : installation vide ; réglages conservés entre instances, conversations non restaurées ; arrière-plan iOS qui annule (et `inactive` qui n’annule pas) ; chargement à la demande, réponse en flux, mesure de contexte (capacité effective 128, plafonnée par l’entraînement de stories15M, marquée « dernière mesure ») ; deuxième conversation qui partage l’instance ; déchargement pendant la requête (refusée « being unloaded », historique de l’autre conversation intact) ; changement de modèle → nouvelle conversation, anciennes consultables ; « Retry » qui recharge | **5/5** (3 exécutions de suite pour le scénario de déchargement) |
| `backgroundSessionDownloadInstalls` — téléchargement en **session de fond** dans l’application hôte, depuis un serveur local contrôlé, installé dans le magasin (scénario de P4 refusé au processus `xctest`) | **réussi** |
| Compilation macOS 27 et iOS 27 appareil (application et tests) | réussie, sans avertissement dans la démo |
| Parcours manuel, simulateur iOS 27 : installation vide → bibliothèque → téléchargement réel de Qwen3.5-2B (1,95 Go) en session de fond ; application suspendue (accueil) : les fichiers de `nsurlsessiond` continuent de croître (≈ +5 Mo / 10 s par fichier) ; retour : progression rattrapée ; pause à 834,9 Mo puis reprise sans redémarrage ; vérification, installation, sélection automatique et conversation | **réussi** |
| Relance de l’application : modèle et réglages conservés, nouvelle conversation vide | **réussi** |
| Question « How much are three pens and one mug in total » (Qwen, CPU) : indicateurs « Loading the model » (progression), « Processing the prompt » (progression) puis contexte 256 → 635 / 4096 « Last measure » ; deux appels `lookup_product` et leurs sorties affichés ; réponse « 17.00 EUR » ; consommation de la réponse (559 tokens de prompt dont 506 en cache, 76 générés) affichée à part | **réussi** |
| `LlamaFMDemoUITests` (XCUITest, Qwen3.5-2B installé par le parcours ci-dessus, CPU) : boucle d’outils (`lookup_product({"product": "pen"})`, `lookup_product({"product": "mug"})`, sorties affichées, réponse, « Last measure ») ; « City guide » `@Generable` (Lyon, France, population, trois lieux, résumé) ; « Stop » → fragments gardés, « Stopped », « Retry » → nouvelle requête, passage à l’accueil → « Interrupted: the app moved to the background » et « Retry » proposé | **3/3** (une exécution précédente avait échoué sur une assertion de contenu dépendante de l’échantillonnage, remplacée par la vérification des appels et sorties) |

### Limites

- **iPhone : non exécuté** (appareil hors ligne pendant P6). Restent pour P7 : transfert en arrière-plan avec relance par le système (`handleEventsForBackgroundURLSession`), fermeture forcée → `interrupted`, Metal, mémoire avec l’autorisation `increased-memory-limit` (déclarée pour les builds iOS appareil ; la signature exige l’équipe du développeur).
- **macOS 27 : compilé seulement** (Mac sous 26.7).
- **Vision dans la démo** : le chemin image (sélection, réduction, orientation, refus selon les capacités) est testé unitairement et la vision est qualifiée au niveau de la bibliothèque (P5) ; le sélecteur de photos n’est pas piloté par les tests d’interface.
- **Débit en arrière-plan** : sur le simulateur, nettement plus faible application suspendue qu’au premier plan ; ce n’est pas une mesure d’appareil.
- **Effets d’outils** : une annulation ou une erreur ne défait pas un outil déjà exécuté (les deux outils de la démo n’ont pas d’effet externe).

## P7 — Qualification et livraison

### Environnement (1er octobre 2026, révision de départ `51e1eb0e0`)

| Élément | Constat |
| --- | --- |
| Xcode / SDK | 27.0 (27A266a), SDK iOS / macOS 27.0 |
| Mac | M1 Pro, macOS 26.7 : compilation et tests hôte seulement |
| Simulateur | iPhone 17 Pro, iOS 27.0 (`C64BD9F4-…`), Qwen3.5-2B installé dans la démo en P6 |
| Appareil | **iPad Pro 11" 3e gén. (iPad13,4, M1, 8 Go), iPadOS 27.2 (24B5089g)**, filaire, mode développeur ; signature automatique avec l’équipe personnelle du développeur (passée à `xcodebuild`, pas écrite dans le projet), autorisation `increased-memory-limit` accordée |
| iPhone 16 Pro Max | absent de `devicectl list devices` : non exécuté |
| Modèle | `unsloth/Qwen3.5-2B-GGUF` révision `f6d5376b…`, Q4_K_M + `mmproj-BF16`, téléchargé par l’application depuis le catalogue |

### Correction : arguments chaîne des outils au format XML de Qwen3.5

L’écart ouvert en P5 est résolu dans le moteur (`common/parsers/qwen3-coder.cpp`), documenté dans [l’API du moteur](embedded-inference-engine-api.md#sortie-structurée--vérification-stricte-et-outils) :

- un paramètre chaîne à `enum`/`const` est restreint par la grammaire à ses valeurs (texte brut, sans guillemets) ; auparavant libre. S’applique aussi au serveur (la grammaire n’accepte plus que ce que le schéma autorise) ;
- une contrainte que le texte brut ne peut pas porter (motif, format, longueur, valeurs chaîne mêlées à d’autres types) est relevée dans `common_chat_params::unenforced_tool_constraints` ; avec `strict_json_schema`, la requête est refusée `parameters of tool <nom>: …`, que l’adaptateur traduit déjà en `LanguageModelError.unsupportedGenerationGuide(schemaName: <nom>)`. Sans mode strict, rien ne change.

Tests : `test-chat` (`test_qwen3_coder_string_constraints` : `red` et `light blue` acceptés, `green` et `redder` refusés par la grammaire en `auto` et `required`, valeur analysée en chaîne, contraintes relevées) — échoue sans la modification ; `EngineAdapterTests.toolArgumentConstraintTheFormatCannotEnforceIsRefused` (vrai moteur, template Qwen3.5 du dépôt : motif refusé avec le nom de l’outil ; même outil `disallowed` accepté).

### Commandes exécutées

```bash
cmake --build build-apple-p1 -j 6 && (cd build-apple-p1 && ctest -j 4)
(cd tools/server/tests && LLAMA_SERVER_BIN_PATH=../../../build-apple-p1/bin/llama-server ../../../.venv-server-tests/bin/python -m pytest -m 'not slow' -q unit)
LLAMA_BRIDGE_TEST_MODEL=$PWD/tools/server/tests/tmp/stories15M-q4_0.gguf scripts/build-apple-language-model.sh --test
# package, simulateur iOS 27 (Qwen sur CPU)
cd bindings/apple
TEST_RUNNER_LLAMA_QWEN_OFFLOAD=none TEST_RUNNER_LLAMA_QWEN_DIR=<snapshot Qwen3.5-2B> \
  xcodebuild test -scheme LlamaApple-Package -destination 'platform=iOS Simulator,id=C64BD9F4-…' -parallel-testing-enabled NO
xcodebuild build-for-testing -scheme LlamaApple-Package -destination 'generic/platform=macOS'
# démo
cd examples/llama.foundationmodels
xcodebuild test -scheme LlamaFMDemo -destination 'platform=iOS Simulator,id=C64BD9F4-…'
xcodebuild build-for-testing -scheme LlamaFMDemo -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO
xcodebuild test -scheme LlamaFMDemoUITests -destination 'id=<iPad>' DEVELOPMENT_TEAM=<équipe> -allowProvisioningUpdates \
  -only-testing:LlamaFMDemoUITests/DeviceDownloadUITests
TEST_RUNNER_LLAMA_DEVICE_QUALIFICATION=1 xcodebuild test -scheme LlamaFMDemo -destination 'id=<iPad>' \
  DEVELOPMENT_TEAM=<équipe> -allowProvisioningUpdates -only-testing:LlamaFMDemoTests/DeviceQualificationTests
TEST_RUNNER_LLAMA_DEVICE_QUALIFICATION=1 TEST_RUNNER_LLAMA_QUALIFICATION_OFFLOAD=none xcodebuild test … \
  -only-testing:'LlamaFMDemoTests/DeviceQualificationTests/measures()'
xcodebuild test -scheme LlamaFMDemoUITests -destination 'id=<iPad>' … -only-testing:LlamaFMDemoUITests/QwenScenarioUITests
```

### Résultats

| Vérification | Destination | Résultat |
| --- | --- | --- |
| CTest (tests enregistrés : 80) | Mac, hôte | **77/80** ; mêmes trois échecs qu’en P1/P5 (`test-jinja-py` environnement, `test-engine-operations` préremplissage de grammaire avec stories15M, `test-engine-acquisition`) |
| Tests HTTP du serveur, `-m 'not slow'` | Mac | **393 réussis, 6 ignorés** (identique à P1/P5) |
| XCFramework reconstruit (iOS appareil, simulateur, macOS) + `test-llama-bridge` | Mac | réussi ; archive 186 358 878 octets, checksum SPM `3a135fcb971721f75bd01b89ba37d532d7ab71bffb6f50d22dcd8976aaa43e16`. Les variantes ASan/TSan du pont n’ont pas été relancées (pont inchangé depuis P2) |
| Suite du package (`LlamaEngineTests` 38, `LlamaFoundationModelsTests` 55 dont 12 `QwenTests` sur CPU) | simulateur iOS 27.0 | **91 réussis**, 2 ignorés par conception (93 tests) (session de fond hors application, téléchargement réel opt-in) |
| Suite de la démo (`LlamaFMDemoTests`) | simulateur iOS 27.0 | **19 réussis**, 14 `DeviceQualificationTests` ignorés (opt-in) |
| Compilation et linkage macOS 27 (package et démo, tests compris) | Mac 26.7 | réussis ; **exécution non faite** |
| `DeviceDownloadUITests` : installation vide → téléchargement du catalogue (1,95 Go) → 20 s au premier plan (206 Mo) → 90 s suspendue (987,7 Mo au retour) → application **terminée** 90 s par l’outil de test → relance : « Installed » | iPad | **réussi** (248 s). Le transfert s’est poursuivi et achevé application terminée ; l’installation a eu lieu au plus tard à la relance |
| `DeviceQualificationTests` (14, Metal, capacités tirées de l’entrée de catalogue téléchargée) | iPad | **14/14** sur les deux dernières exécutions (détail ci-dessous) |
| `QwenScenarioUITests` : boucle d’outils (`lookup_product` pen et mug), City guide (Lyon, France), Stop → Retry → arrière-plan → « Interrupted » | iPad, Metal | **3/3** (≈ 21–24 s chacun, contre plusieurs minutes sur le CPU du simulateur) |

Capacités sur l’iPad (Metal, glouton) :

| Capacité | Preuve |
| --- | --- |
| Texte en flux | 21 instantanés, « Tokyo, Osaka, and Kyoto … » |
| Raisonnement séparé | 201 tokens de raisonnement, réponse « 42 » sans balises |
| Sortie structurée en flux (`CityGuide`) | 60 instantanés ; Lyon, France, 3 lieux, résumé |
| Raisonnement + structuré (schéma hors prompt) | 21,0 (7 × 3 EUR), entrée de raisonnement présente |
| Outils (deux appels) | `lookup_product` pen et mug, sorties dans le transcript, réponse citant 3,00 et 8,00 EUR |
| Outils + structuré (`required`) | `lookup_product:backpack`, total 78,0 |
| Vision + structuré | « MEN WALK ON MOON … », 1 photographie |
| Vision avec orientation (page tournée, `.right`) | titre lu (« MOON ») |
| Deux sessions simultanées | Rome, Madrid, une seule instance |
| Interruption puis requête suivante | « Berlin » sur la même session |
| Contexte plein avant / pendant la génération ; budget atteint | `contextSizeExceeded` phase `prompt` puis `generation`, budget = réponse |

### Mesures (iPad Pro M1, iPadOS 27.2, Qwen3.5-2B Q4_K_M, contexte 4096, projecteur chargé)

| Mesure | Metal (`offload: .all`) | CPU (`offload: .none`) |
| --- | --- | --- |
| Chargement (poids + projecteur) | 9,42 s au premier chargement après installation ; 0,66–0,70 s ensuite (fichiers en cache) | 2,10 s (cache chaud) |
| Empreinte physique : repos → chargé → pendant la génération (pic) | 56 → 945–952 Mo → 973–979 Mo ; pic du processus 1,22 Go après image et annulations | 55 → 922 → 952 Mo ; pic 1,31 Go |
| Premier token, prompt de 24 tokens | 0,12 s (0,59 s au premier appel après chargement à froid) | 0,77 s |
| Génération (256 tokens) | **39,8–40,1 tokens/s** | 19,1 tokens/s |
| Traitement du prompt (2 460 tokens, sans cache) | **497–517 tokens/s** | 113 tokens/s |
| Image (323 tokens de prompt) jusqu’au premier token | **1,6–2,0 s** | 172 s |
| Annulation pendant la génération : retour de `respond` | < 1 ms | < 1 ms |
| … puis requête suivante de 2 tokens servie | 0,09–0,16 s | 0,25–0,65 s |
| Déchargement | 0,02–0,05 s | 0,03 s |

Empreinte après déchargement (`unloadReleasesTheMemory`, 4 cycles) : sans projecteur, elle revient à ~100–130 Mo en 1 s ; avec projecteur, ~0,7–0,8 Go restent comptés pendant 45 à 125 s, puis l’empreinte revient à ~130–155 Mo sans action de l’application. Elle ne croît pas d’un cycle à l’autre. La même séquence sur le Mac par le pont (sonde hôte, Metal) rend la mémoire en 1 s : le délai est propre à iOS (récupération différée par le système). `os_proc_available_memory` annonce ~7,2 Go disponibles modèle chargé.

Profils retenus à partir de ces mesures :

- **Calcul** : Metal par défaut sur appareil (2× en génération, 4,5× sur le prompt, ×100 sur l’image) ; CPU par défaut sur le simulateur seulement (Metal du simulateur inutilisable, P5). C’est déjà le réglage de la démo.
- **Contexte** : 4096 par défaut confirmé ; à ~1 Go d’empreinte, un iPad de 8 Go garde une large marge. Les poids sont projetés en mémoire (fichier) et ne sont pas comptés dans l’empreinte ; le projecteur BF16 en représente l’essentiel : ne pas déduire la résidence de la taille des fichiers (1,95 Go). Un contexte plus grand n’a pas été mesuré.
- **Concurrence** : une génération active et quatre en attente restent les réglages de la démo (deux sessions servies par une instance vérifiées).

### Observations et limites

- **macOS 27** : compilé et lié (package, démo, tests), **jamais exécuté** (Mac 26.7). La livraison est partiellement qualifiée sur ce point.
- **iPhone** : non disponible ; la qualification « appareil » est faite sur iPad (iPadOS 27.2, M1). Une puce A-series et sa limite mémoire restent à vérifier.
- **Fermeture forcée par l’utilisateur** (balayage dans le sélecteur d’apps) : non automatisable ; iOS annule alors les transferts de la session de fond (comportement documenté par Apple, non vérifié ici). Le test couvre une terminaison par l’outil de test, que le système traite comme une fin de processus ordinaire.
- **Une exécution interrompue** : lors de la première exécution complète des `DeviceQualificationTests`, le processus a reçu `SIGKILL` pendant `contextFullBeforeAndDuringGeneration` (après le rechargement au contexte 256), sans rapport de plantage ni événement Jetsam sur l’appareil. Non reproduit : le test seul, puis deux exécutions complètes (14/14) réussissent. Cause non établie.
- **Mesure du premier token** : prise au passage du moniteur en phase de génération (le flux Foundation Models retient le dernier événement, voir P6).
- **Verrouillage** : un appareil verrouillé suspend `xcodebuild test` (« Unlock iPad to Continue ») ; garder l’écran déverrouillé pendant les tests.

## Blocages et écarts ouverts

- **macOS 27 à l’exécution** : indisponible sur ce Mac (26.7) ; la livraison est « compilée, non validée à l’exécution sur macOS 27 » tant qu’aucune machine 27 n’est disponible.
- **iPhone** : hors ligne pendant P6 et P7 ; qualification appareil faite sur iPad Pro M1 (iPadOS 27.2).
- **Approximations silencieuses du convertisseur de schéma** : résolues pour l’adaptateur en P5 (`strict_json_schema`, refus des bornes flottantes, réécriture de `"$ref": "#"`). L’argument chaîne contraint d’un outil au format XML de Qwen3.5 est résolu en P7 (énumération imposée, autres contraintes refusées en mode strict).
- **Metal du simulateur** (P5) : plantages au chargement du projecteur et à la restauration d’un checkpoint de Qwen3.5 ; qualification sur CPU du simulateur ; Metal qualifié sur l’iPad (P7), sans plantage.
- **Préremplissage de grammaire et vocabulaires sans marqueurs spéciaux** (moteur, préexistant) : cause de l’échec de `test-engine-operations` ; contourné dans les tests par un template sans prompt de génération.
- **Signal de contexte plein** : résolu en P1 (`fail_on_context_full`).
- **Tests moteur préexistants** : `test-engine-operations` et `test-engine-acquisition` échouent dans cet environnement avec stories15M, avec ou sans P1.
- **Encodage observé** : identique sur macOS 26.7 (sonde locale) et simulateur iOS 27.0 ; sur iPadOS 27.2, les scénarios de l’adaptateur (outils, schémas, transcript) réussissent.
- **Transfert en arrière-plan sur appareil (P4)** : exécuté sur iPad en P7 (suspendue puis terminée, installation à la relance) ; la fermeture forcée par l’utilisateur n’est pas automatisable.
- **Annulation d’un flux Foundation Models** (P6) : le flux annulé se termine sans erreur et garde la réponse partielle dans le transcript ; la démo rétablit le dernier tour complet, et le README du package le documente pour les applications.
- **Capacités qualifiées du catalogue** : renseignées en P5 (outils, raisonnement, vision) d’après `QwenTests` sur simulateur ; confirmées sur iPad (Metal) en P7.
- **Mémoire après déchargement sur iOS** : rendue au système 45 à 125 s après le déchargement d’une instance avec projecteur (P7), sans croissance d’un cycle à l’autre.
