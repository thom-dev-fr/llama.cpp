# Rapport — Apple LanguageModel sur llama.cpp

Rapport prévu par le [plan](apple-language-model-plan.md). Il distingue ce qui est exécuté, compilé seulement, ou non encore traité. Aucune capacité Foundation Models n’est validée à ce stade : P0 à P3 sont achevés.

## Suivi P0–P7

| Phase | État | Preuve | Blocage / remarque |
| --- | --- | --- | --- |
| P0 Contrat exécutable | **Terminé** | Matrice ci-dessous ; package `bindings/apple` compilé pour macOS 27, iOS 27 appareil et simulateur ; 8 tests Swift réussis sur simulateur iOS 27. | Aucune capacité déclarée : le squelette refuse toute requête explicitement. |
| P1 Signaux du moteur | **Terminé** | `test-engine-context` (nouveau) ; CTest 77/80, les 3 échecs préexistants ou d’environnement ; HTTP non-`slow` 393 réussis / 6 ignorés ; sonde Qwen3.5-2B (image, raisonnement) ; 12 tests Swift sur simulateur iOS 27. | `test-engine-operations` et `test-engine-acquisition` échouent aussi sans P1 (voir P1). |
| P2 Pont natif et XCFramework | **Terminé** | Pont C + `test-llama-bridge` (hôte, ASan+UBSan, TSan) ; `LlamaBridge.xcframework` iOS / simulateur / macOS ; 20 tests Swift sur simulateur iOS 27 dont 8 sur le vrai moteur ; consommateur externe compilé pour iOS et macOS, testé sur simulateur. | Exécution macOS et iPhone non faite (P7). Premier chargement Metal lent sur simulateur (voir P2). |
| P3 Runtime partagé, stockage | **Terminé** | `LlamaRuntime` (moteur natif en catalogue, admission, instances, chargements mutualisés, déchargement, observation) et `LlamaModelStore` ; 33 tests Swift sur simulateur iOS 27 dont 13 nouveaux `RuntimeTests` sur le vrai moteur, stables sur 5 itérations ; compilation macOS 27 et iOS 27 appareil. | Aucun changement du moteur ni du pont. Tests sur stories15M (CPU) ; iPhone et macOS 27 non exécutés (P7). |
| P4 Acquisition URLSession | À faire | — | Références Qwen3.5-2B relevées localement, à confirmer côté serveur. |
| P5 Executor Foundation Models | À faire | — | Écarts du convertisseur de schéma relevés en P0. |
| P6 Démo SwiftUI | À faire | — | — |
| P7 Qualification | À faire | — | Exécution macOS 27 impossible sur ce Mac (26.7). |

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

## Blocages et écarts ouverts

- **macOS 27 à l’exécution** : indisponible sur ce Mac (26.7) ; la livraison restera « compilée, non validée à l’exécution sur macOS 27 » tant qu’aucune machine 27 n’est disponible.
- **Approximations silencieuses du convertisseur de schéma** : patterns non pris en charge remplacés par une chaîne libre (simple avertissement), bornes flottantes ignorées. P5 doit rendre la conversion stricte pour l’adaptateur (erreur au lieu d’avertissement) ou refuser ces guides ; `"$ref": "#"` doit être réécrit ou pris en charge.
- **Signal de contexte plein** : résolu en P1 (`fail_on_context_full`).
- **Tests moteur préexistants** : `test-engine-operations` et `test-engine-acquisition` échouent dans cet environnement avec stories15M, avec ou sans P1.
- **Encodage observé sur deux runtimes** : identique sur macOS 26.7 (sonde locale) et simulateur iOS 27.0 ; à revérifier sur l’iPhone.
