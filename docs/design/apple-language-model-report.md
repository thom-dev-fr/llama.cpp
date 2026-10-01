# Rapport — Apple LanguageModel sur llama.cpp

Rapport prévu par le [plan](apple-language-model-plan.md). Il distingue ce qui est exécuté, compilé seulement, ou non encore traité. Aucune capacité Foundation Models n’est validée à ce stade : P0 et P1 sont achevés.

## Suivi P0–P7

| Phase | État | Preuve | Blocage / remarque |
| --- | --- | --- | --- |
| P0 Contrat exécutable | **Terminé** | Matrice ci-dessous ; package `bindings/apple` compilé pour macOS 27, iOS 27 appareil et simulateur ; 8 tests Swift réussis sur simulateur iOS 27. | Aucune capacité déclarée : le squelette refuse toute requête explicitement. |
| P1 Signaux du moteur | **Terminé** | `test-engine-context` (nouveau) ; CTest 77/80, les 3 échecs préexistants ou d’environnement ; HTTP non-`slow` 393 réussis / 6 ignorés ; sonde Qwen3.5-2B (image, raisonnement) ; 12 tests Swift sur simulateur iOS 27. | `test-engine-operations` et `test-engine-acquisition` échouent aussi sans P1 (voir P1). |
| P2 Pont natif et XCFramework | À faire | — | — |
| P3 Runtime partagé, stockage | À faire | — | `LlamaRuntime` n’est qu’une identité et des limites. |
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

## Blocages et écarts ouverts

- **macOS 27 à l’exécution** : indisponible sur ce Mac (26.7) ; la livraison restera « compilée, non validée à l’exécution sur macOS 27 » tant qu’aucune machine 27 n’est disponible.
- **Approximations silencieuses du convertisseur de schéma** : patterns non pris en charge remplacés par une chaîne libre (simple avertissement), bornes flottantes ignorées. P5 doit rendre la conversion stricte pour l’adaptateur (erreur au lieu d’avertissement) ou refuser ces guides ; `"$ref": "#"` doit être réécrit ou pris en charge.
- **Signal de contexte plein** : résolu en P1 (`fail_on_context_full`).
- **Tests moteur préexistants** : `test-engine-operations` et `test-engine-acquisition` échouent dans cet environnement avec stories15M, avec ou sans P1.
- **Encodage observé sur deux runtimes** : identique sur macOS 26.7 (sonde locale) et simulateur iOS 27.0 ; à revérifier sur l’iPhone.
