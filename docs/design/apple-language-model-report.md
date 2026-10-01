# Rapport — Apple LanguageModel sur llama.cpp

Rapport prévu par le [plan](apple-language-model-plan.md). Il distingue ce qui est exécuté, compilé seulement, ou non encore traité. Aucune capacité n’est validée à ce stade : seul P0 est achevé.

## Suivi P0–P7

| Phase | État | Preuve | Blocage / remarque |
| --- | --- | --- | --- |
| P0 Contrat exécutable | **Terminé** | Matrice ci-dessous ; package `bindings/apple` compilé pour macOS 27, iOS 27 appareil et simulateur ; 8 tests Swift réussis sur simulateur iOS 27. | Aucune capacité déclarée : le squelette refuse toute requête explicitement. |
| P1 Signaux du moteur | À faire | — | Écarts relevés en P0 : arrêt pour contexte épuisé confondu avec `length`, `truncated` absent du chat. |
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
| Contexte plein | — | Erreur avant prompt (`exceeds the available context size`) ; pendant génération : `STOP_TYPE_LIMIT` + `truncated` (`engine-context.cpp:1904`) | `LanguageModelError.contextSizeExceeded(contextSize, tokenCount)` | Le chemin chat rapporte `finish_reason: length` dans les deux cas ; `truncated` n’est exposé qu’au format natif `/completion`. Context shift à désactiver par requête. | P1 : trois motifs d’arrêt. |
| Usage et occupation | `updateUsage(input:output:)` | `timings`, `prompt_progress`, `n_ctx` de slot | Usage par requête ; occupation séparée | `session.usage` est cumulatif, jamais une occupation. Attribution par requête à prouver (P1). | P1 |
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

## Blocages et écarts ouverts

- **macOS 27 à l’exécution** : indisponible sur ce Mac (26.7) ; la livraison restera « compilée, non validée à l’exécution sur macOS 27 » tant qu’aucune machine 27 n’est disponible.
- **Approximations silencieuses du convertisseur de schéma** : patterns non pris en charge remplacés par une chaîne libre (simple avertissement), bornes flottantes ignorées. P5 doit rendre la conversion stricte pour l’adaptateur (erreur au lieu d’avertissement) ou refuser ces guides ; `"$ref": "#"` doit être réécrit ou pris en charge.
- **Signal de contexte plein** : à exposer par le moteur (P1) ; sans lui, `contextSizeExceeded` pendant la génération ne peut pas être distingué de `maximumResponseTokens`.
- **Encodage observé sur deux runtimes** : identique sur macOS 26.7 (sonde locale) et simulateur iOS 27.0 ; à revérifier sur l’iPhone.
