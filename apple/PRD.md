# LlamaEngine — PRD

## Problem Statement

En tant que développeur d'une application iOS/macOS 100 % Swift + SwiftUI, je veux faire tourner un modèle de langage local sur l'appareil sans devoir :

- déployer un serveur HTTP dans mon app (complexité réseau interne, ports, certificats, permissions, cycle de vie du thread serveur, sécurité au regard du sandbox Apple),
- ou perdre toutes les fonctionnalités avancées de `tools/server` (templates de chat jinja, tool-calling avec parseur auto/PEG, multimodal image/audio via `mtmd`, gestion de slots parallèles, streaming de tokens, cancellation propre, prompt cache),
- ou maintenir à la main un wrapper bas niveau autour de `llama_context` qui duplique ces fonctionnalités et dérive par rapport à l'upstream à chaque mise à jour.

Je veux aussi pouvoir libérer la VRAM Metal à la demande quand l'app passe en arrière-plan ou reçoit un avertissement mémoire, sans perdre la configuration du modèle et sans devoir fermer mon app.

## Solution

Un xcframework binaire distribué via SwiftPM, appelé `LlamaEngine`, qui :

- Expose une API Swift moderne (async/await, AsyncThrowingStream, actor, Task cancellation) pour charger un modèle local, générer des complétions chat OpenAI-compatibles en streaming ou non, et tokenizer.
- Accepte en entrée du JSON OpenAI-compatible et renvoie du JSON OpenAI-compatible, afin d'être consommable avec un client Swift OpenAI existant (par ex. MacPaw/OpenAI) moyennant un fin adaptateur côté app.
- Réutilise intégralement la cible CMake `server-context` du repo en amont (qui encapsule déjà toute la logique métier de `tools/server` indépendamment du transport HTTP). Aucune modification du code amont n'est nécessaire.
- Vit dans un dossier isolé `apple/` du fork, avec un `Package.swift` à la racine du repo qui expose un `binaryTarget` sur le xcframework généré localement par un script de build.
- Se synchronise avec l'amont par un simple `git merge` suivi d'un re-build du xcframework, grâce au périmètre strictement confiné des changements.
- Libère la VRAM Metal à la demande (sleep / unload) et la reconstitue automatiquement lors de la requête suivante (wake implicite), avec annulation préemptive des inférences en cours via `SERVER_TASK_TYPE_CANCEL` pour honorer les transitions sans blocage.

## User Stories

Développeur de l'app iOS / macOS consommateur du framework :

1. En tant que développeur iOS, je veux pouvoir installer LlamaEngine via SwiftPM en ajoutant une seule ligne à mon `Package.swift`, pour que l'intégration dans mon projet soit triviale.
2. En tant que développeur iOS, je veux que le framework soit distribué sous forme binaire (xcframework précompilé), pour que le temps de build de mon app reste rapide et ne dépende pas de la compilation de llama.cpp à chaque fois.
3. En tant que développeur iOS, je veux référencer le framework par chemin relatif local vers un repo voisin, pour travailler en environnement de développement contrôlé sans dépendre d'une URL distante ou d'une release GitHub.
4. En tant que développeur iOS, je veux créer une instance d'`LlamaEngine` et charger un modèle GGUF local via `async` / `await`, pour démarrer l'inférence avec une seule ligne de code.
5. En tant que développeur iOS, je veux que `load` lève une erreur claire si un modèle est déjà chargé dans l'instance, pour éviter des erreurs silencieuses de double-chargement.
6. En tant que développeur iOS, je veux configurer le modèle avec des paramètres typés (taille de contexte, couches GPU, nombre de slots parallèles, seed, template de chat, etc.), pour pouvoir ajuster le comportement sans manipuler des chaînes ou des dictionnaires.
7. En tant que développeur iOS, je veux une échappatoire `extraParameters` (dictionnaire libre) dans la configuration, pour pouvoir passer des options avancées de `common_params` sans attendre une évolution de l'API typée.
8. En tant que développeur iOS, je veux envoyer une requête chat en JSON OpenAI-compatible et recevoir une réponse complète en JSON OpenAI-compatible, pour pouvoir réutiliser les types de mon client OpenAI Swift sans mapping supplémentaire.
9. En tant que développeur iOS, je veux demander une réponse chat en streaming et recevoir un `AsyncThrowingStream` de chunks JSON `ChatCompletionChunk` un par un, sans enveloppe SSE et sans sentinelle `[DONE]`, pour décoder chaque chunk trivialement.
10. En tant que développeur iOS, je veux qu'annuler le `Task` qui consomme mon stream arrête immédiatement la génération côté moteur (libération du slot, arrêt du decoding), pour ne pas gaspiller de cycles GPU sur une requête abandonnée.
11. En tant que développeur iOS, je veux que le stream annulé lève une erreur de cancellation typée, pour pouvoir la distinguer proprement d'une erreur d'inférence réelle.
12. En tant que développeur iOS, je veux lancer plusieurs inférences chat en parallèle sur une même instance et qu'elles utilisent réellement les slots parallèles du moteur, pour servir plusieurs conversations ou requêtes simultanées.
13. En tant que développeur iOS, je veux tokenizer une chaîne de caractères en entiers (tokens) via `async` / `await`, pour pouvoir compter les tokens d'un prompt avant de l'envoyer.
14. En tant que développeur iOS, je veux détokenizer une séquence d'entiers en chaîne de caractères, pour afficher ou diagnostiquer des tokens manipulés côté Swift.
15. En tant que développeur iOS, je veux appeler `sleep` pour libérer la VRAM Metal quand mon app passe en arrière-plan, pour que l'OS ne tue pas mon app pour cause de pression mémoire.
16. En tant que développeur iOS, je veux que `sleep` préempte les inférences en cours par cancellation et se termine dans un délai borné, pour que la transition de cycle de vie ne bloque pas indéfiniment.
17. En tant que développeur iOS, je veux que la première requête chat après un `sleep` déclenche automatiquement le rechargement du modèle sans avoir à appeler `wake` explicitement, pour simplifier le code dans les callbacks de retour au premier plan.
18. En tant que développeur iOS, je veux pouvoir observer l'état du moteur (déchargé, en cours de chargement, prêt, en veille, en cours de déchargement) à tout moment, pour afficher un indicateur de progression dans mon UI SwiftUI.
19. En tant que développeur iOS, je veux appeler `unload` pour décharger complètement le modèle et oublier sa configuration, pour basculer proprement vers un autre modèle sans conserver l'ancien état.
20. En tant que développeur iOS, je veux configurer un délai d'inactivité après lequel le moteur passe automatiquement en veille, pour ne pas avoir à gérer moi-même la mise en veille dans mon code applicatif.
21. En tant que développeur iOS, je veux régler le niveau de verbosité des logs C++, pour pouvoir couper le bruit en production et l'activer lors du debug.
22. En tant que développeur iOS travaillant sur l'app, je veux une seule instance de `LlamaEngine` à la fois par processus, conformément aux garanties documentées, pour ne pas avoir à raisonner sur des interactions inter-instances.
23. En tant que développeur iOS, je veux que le framework expose une cancellation préemptive via les mécanismes Swift Concurrency idiomatiques (`Task`, `withTaskCancellationHandler`), pour que mon code soit naturel et que mes tests unitaires cancellation fonctionnent de manière prévisible.
24. En tant que développeur iOS utilisant SwiftUI, je veux que les erreurs du moteur soient typées (`LlamaError`) avec des cas distincts (modèle non chargé, déjà chargé, échec de chargement, requête invalide, échec d'inférence, annulation, timeout, erreur interne), pour router chaque cas vers un affichage approprié sans parser de chaînes.
25. En tant que développeur iOS, je veux pouvoir fournir un chemin optionnel vers un projector multimodal (CLIP) dans la configuration, pour activer la vision ou l'audio en entrée selon le modèle chargé.
26. En tant que développeur iOS, je veux que le xcframework contienne les slices iOS device, iOS simulator, macOS arm64 et macOS x86_64, pour builder et tester mon app sur simulateur ainsi qu'en natif Mac sans rebuild.
27. En tant que développeur iOS, je veux que le framework utilise Metal sur device et simulateur (Apple Silicon) avec la Metal library embarquée, pour éviter les problèmes de chargement de ressources au runtime.
28. En tant que développeur iOS, je veux pouvoir surcharger le template de chat du modèle via un paramètre de configuration, pour utiliser un template custom quand celui embarqué dans le GGUF ne convient pas.

Développeur mainteneur du fork :

29. En tant que mainteneur du fork, je veux que tout mon code applicatif soit confiné dans un dossier top-level unique, pour que `git diff` contre l'amont montre clairement et exclusivement ma valeur ajoutée.
30. En tant que mainteneur du fork, je veux que mon code ne modifie aucun fichier du code amont, pour que la synchronisation avec l'amont soit triviale (`git merge` sans conflit structurel attendu).
31. En tant que mainteneur du fork, je veux pouvoir re-synchroniser avec l'amont en une seule commande (fetch, merge, rebuild xcframework), pour faire évoluer mon fork au rythme des releases amont sans friction.
32. En tant que mainteneur du fork, je veux que le xcframework soit produit par un script shell auto-suffisant qui reprend les flags et toolchains du script équivalent présent à la racine de l'amont, pour ne pas réinventer la configuration Metal/BLAS/MinOS.
33. En tant que mainteneur du fork, je veux que le xcframework compilé soit exclu du suivi Git, pour que la taille du repo reste raisonnable au fil des builds.
34. En tant que mainteneur du fork, je veux pouvoir tester les modules purs (traduction de config, construction de tâches, formatage de résultats) sans charger de modèle GGUF, pour avoir une boucle de validation rapide en CI sans téléchargement d'assets.
35. En tant que mainteneur du fork, je veux que mes tests unitaires puissent tourner sur macOS uniquement dans un environnement de développeur standard, pour ne pas dépendre d'une ferme de machines ou d'un pipeline iOS complet.
36. En tant que mainteneur du fork, je veux que la surface C exposée entre le C++ et le Swift soit minimale et opaque (handles, fonctions C pures), pour pouvoir faire évoluer l'implémentation C++ sans casser l'ABI Swift.
37. En tant que mainteneur du fork, je veux qu'un patch futur éventuel sur `common/log.cpp` pour router les logs via un callback Swift reste isolé et documenté, pour pouvoir l'appliquer ou le retirer d'un commit atomique.

## Implementation Decisions

### Architecture d'ensemble

- Le framework réutilise intégralement la cible CMake `server-context` déjà exposée par le code amont. Cette cible contient tout le coeur métier (prompt cache, slots parallèles, application des templates de chat jinja, tool-calling PEG/auto, multimodal `mtmd`, streaming, speculative decoding, cancellation granulaire via `SERVER_TASK_TYPE_CANCEL`, sleep/wake automatique). Aucune modification de `tools/server/` ni d'autres fichiers amont n'est nécessaire.
- Le pilotage se fait via `server_response_reader`, qui est explicitement prévu dans le code amont pour un usage non-HTTP.
- Le framework n'embarque pas de serveur HTTP. Il expose une API locale native.

### Modules applicatifs

Six modules logiques principaux :

- `ParamsTranslator` (C++, pur) : traduit une structure de configuration publique en `common_params`, sans passer par `common_params_parse`. Interface déterministe in/out, sans effet de bord. Encapsule l'ensemble des décisions de valeurs par défaut, de validation et de mapping.
- `TaskBuilder` (C++, pur) : traduit un objet JSON de requête chat OpenAI-compatible en vecteur de `server_task`. Réutilise les helpers amont de `server-common` / `server-task` quand ils existent, pour ne pas dupliquer la logique.
- `ResultFormatter` (C++, pur) : traduit un `server_task_result` (ou un agrégat pour une réponse non-stream) en chunk JSON OpenAI-compatible. Symétrique de `TaskBuilder`.
- `EngineCore` (C++/ObjC++, stateful) : porte une instance de `server_context`, un thread dédié à la boucle principale de traitement, l'état de cycle de vie (déchargé, chargé, en veille, transitions), et orchestre les trois modules ci-dessus. Expose une API C opaque stable, conçue pour un binding Swift propre.
- `LlamaEngine` (Swift, actor) : façade Swift idiomatique sur l'API C d'`EngineCore`. Sérialise naturellement les transitions de cycle de vie par l'isolation actor, tout en laissant s'exécuter les consommateurs de streams hors du contexte actor pour permettre le vrai parallélisme d'inférence via les slots.
- Types value Swift (`ModelConfig`, `EngineState`, `LlamaError`, `KVCacheType`, `LogLevel`) : surface publique typée et `Sendable`.

### Contrat d'API côté Swift (haute niveau)

- Façade présentée sous forme d'actor, avec cycle de vie `load` / `unload` / `sleep` / `wake` et propriété d'état observable.
- Inférence chat exposée sous deux formes : non-stream (`async throws -> Data`) et streaming (`AsyncThrowingStream<Data, Error>`). Les deux acceptent en entrée un `Data` contenant du JSON OpenAI-compatible.
- Tokenisation et détokenisation exposées directement en Swift typé (pas de JSON).
- Contrôle de verbosité exposé via un setter de niveau de log.

### Contrat d'échange JSON

- Requêtes : JSON OpenAI-compatible pour `chat/completions`.
- Réponses non-stream : JSON OpenAI-compatible complet.
- Réponses stream : un objet `ChatCompletionChunk` JSON par élément du flux, sans préfixe `data: `, sans sentinelle `[DONE]`. La fin est signalée exclusivement par la fin naturelle de l'`AsyncThrowingStream`.
- L'adaptation vers un client OpenAI Swift tiers est à la charge de l'application consommatrice et ne fait pas partie du framework.

### Cycle de vie et concurrence

- Une seule instance `LlamaEngine` prise en charge à la fois par processus. Le backend ggml/Metal est initialisé une unique fois au premier `load`.
- Cycle de vie sérialisé par l'isolation actor Swift.
- Les inférences concurrentes sur une même instance sont autorisées et exploitent réellement les slots parallèles configurés.
- `sleep` et `unload` appliquent une politique de préemption : envoi de `SERVER_TASK_TYPE_CANCEL` à toutes les tâches en vol, puis attente bornée de leur fin avant démontage. Les streams préemptés lèvent une erreur de cancellation typée.
- `load` sur une instance déjà chargée lève une erreur typée (pas de remplacement implicite).
- `wake` implicite : une requête d'inférence sur une instance en veille déclenche automatiquement le rechargement du modèle à partir de la configuration préservée. L'état transite par `loading` puis `ready`.
- `wake` explicite sur une instance non-en-veille : no-op silencieux.
- La cancellation d'un `Task` Swift qui consomme un stream d'inférence est propagée activement côté C++ via `SERVER_TASK_TYPE_CANCEL` avec l'identifiant de tâche correspondant, pour un arrêt immédiat au niveau du slot et non au prochain poll.

### Configuration du modèle

Le `ModelConfig` public expose les champs suivants (avec défauts sensés) : chemin du GGUF, taille de contexte, couches GPU, nombre de slots parallèles, nombre de threads CPU (auto par défaut), seed, chemin du projector multimodal optionnel, override de template de chat optionnel, mmap, mlock, flash attention, type de quantification du KV cache, durée d'inactivité avant sleep automatique (désactivé par défaut), et dictionnaire d'options libres pour les paramètres avancés non typés.

### Backends et plateformes

- Cibles Apple minimales : iOS 26 (device et simulateur) et macOS 26 (arm64 et x86_64). Pas de visionOS, tvOS, watchOS, ni Catalyst en v1.
- Backends activés dans le xcframework : Metal (avec library embarquée), BLAS par défaut, flash attention possible. Multimodal `mtmd` activé dans le build ; son usage runtime est conditionnel à la présence d'un projector dans la configuration.
- Logs C++ : stderr laissé libre par défaut (invisible en production iOS, visible dans la console Xcode en debug). Le niveau est contrôlable via un setter exposé en Swift qui agit sur le threshold de verbosité et peut silencer les logs ggml/llama. Pas de routage OSLog en v1.

### Emplacement et distribution

- Le code applicatif vit exclusivement dans un dossier top-level `apple/` du fork. Aucune modification d'arborescence existante n'est introduite en dehors de l'ajout du manifest SwiftPM à la racine du repo (contrainte SPM incontournable).
- Le manifeste SwiftPM déclare un target Swift pour la façade et un `binaryTarget` pointant par chemin relatif vers le xcframework compilé localement (non suivi par Git).
- Les consommateurs (application dans un repo voisin) référencent le package par chemin relatif local.
- Le xcframework est produit par un script shell dédié, qui reprend la configuration du script amont équivalent (flags cmake, toolchains iOS device/sim, macOS arm64/x86_64, options ggml/Metal/BLAS).

### Synchronisation amont

- La stratégie de sync est le cas simple : `git fetch upstream && git merge upstream/master`. Aucun conflit structurel n'est attendu tant que tout le code applicatif reste confiné dans `apple/` et que le manifest racine ne touche qu'à lui-même.
- Un script shell dédié enchaîne fetch, merge, et re-build du xcframework.

### Versioning

- Pas d'étiquetage formel SemVer en v1. Le point de vérité est le commit courant du fork. L'app consommatrice pointe en chemin local et suit l'évolution du fork au rythme du développeur.

## Testing Decisions

### Principe

Les tests ciblent exclusivement le **comportement externe observable** des modules, jamais leur implémentation interne. Un test ne doit pas casser quand l'implémentation change mais que le contrat public reste honoré.

### Modules testés

Trois modules purs côté C++ font l'objet de tests unitaires :

- `ParamsTranslator` — tests que des `ModelConfig` variés produisent des `common_params` cohérents, que les défauts sont appliqués correctement, que les valeurs invalides sont détectées, que le dictionnaire d'échappatoire fusionne bien sans écraser les champs typés.
- `TaskBuilder` — tests avec fixtures JSON OpenAI de `chat/completions` couvrant : messages textuels simples, messages avec contenu multi-part, tool calls, response_format (text, json_object, json_schema), streaming activé ou non, paramètres de sampling variés, arguments invalides.
- `ResultFormatter` — tests avec objets `server_task_result` simulés couvrant : chunk stream incrémental, chunk stream avec tool call partiel, résultat final non-stream, usage counts, finish_reason. Doit produire exactement un objet JSON par appel, sans enveloppe SSE.

### Modules non testés en v1

- `EngineCore` et la façade Swift `LlamaEngine` : pas de tests d'intégration en v1. Ils seront validables manuellement (app de dev) en attendant. Les tests d'intégration avec un petit GGUF fixture sont reportés à une itération ultérieure.
- Scripts shell (build-xcframework, sync-upstream) : pas de tests ; le build est son propre test.
- Types value Swift (`ModelConfig`, `EngineState`, `LlamaError`, etc.) : pas de tests, le compilateur Swift fournit les garanties nécessaires pour des types essentiellement déclaratifs.

### Prior art

- Les tests amont de `tests/test-chat.cpp` et `tests/test-chat-template.cpp` donnent le ton et le format pour le test de logique liée aux templates et aux messages chat. Les tests unitaires du framework peuvent s'en inspirer pour la structure (usage de fixtures JSON, assertions par comparaison d'objets, séparation des cas par sous-test).
- Les tests Python de `tools/server/tests/` exercent les mêmes chemins de code (construction de `server_task`, formatage de résultat) côté bout-à-bout sur HTTP. Ils ne sont pas répliqués ici, mais servent de référence fonctionnelle : si `TaskBuilder` et `ResultFormatter` sont cohérents avec le comportement observé via ces tests sur l'endpoint HTTP correspondant, ils sont corrects.

### Exécution

Les tests doivent pouvoir tourner sur un environnement de développement macOS standard, sans téléchargement d'assets ni accès réseau, et terminer en quelques secondes. Ils n'ont pas besoin de Metal ni de GPU.

## Out of Scope

Explicitement hors périmètre v1 :

- Completion brute (hors chat), embeddings, reranking, infill, transcription audio, endpoint "responses" OpenAI, endpoint "messages" Anthropic, save/restore/erase de slots, hotswap d'adapters LoRA, router multi-modèles, CORS proxy, tools intégrés côté serveur, apply-template exposé côté Swift, props/metrics exposés côté Swift.
- Support d'instances `LlamaEngine` multiples simultanées.
- Support de plusieurs modèles chargés concurremment dans une même instance.
- Speculative decoding avec modèle draft.
- Routage des logs C++ vers OSLog / `Logger` Apple.
- Distribution du xcframework via URL + checksum sur GitHub Releases.
- Distribution via Swift Package Registry, CocoaPods ou Carthage.
- Support visionOS, tvOS, watchOS, Mac Catalyst.
- Compatibilité Objective-C : le framework est consommé exclusivement depuis Swift.
- Compatibilité iOS / macOS antérieurs à la version 26.
- Tests d'intégration avec un GGUF fixture, tests de performance, tests de non-régression mémoire.
- Application de démonstration SwiftUI fournie avec le framework.
- Téléchargement ou gestion des fichiers GGUF (stockage, quotas, reprise, checksums) : à la charge de l'application consommatrice.
- Contribution en amont : il s'agit d'un fork assumé, sans intention de PR upstream.

## Further Notes

- Le périmètre fonctionnel du coeur `server-context` est très large et évolue vite en amont (tool-calling, reasoning/thinking models, multimodal). Le fait que le framework soit un fin adaptateur permet d'hériter gratuitement de ces évolutions à chaque synchronisation, tant qu'elles restent pilotables par `server_task` sans changement de l'ABI interne. Si l'ABI interne d'`server_context` change de façon incompatible, le travail d'adaptation se concentre dans `EngineCore`, pas dans les modules purs.
- La décision de ne pas émuler le transport SSE dans l'API de streaming est délibérée. Le SSE est une convention HTTP, pas une convention d'API. Le format retenu (un JSON `ChatCompletionChunk` par élément) est strictement équivalent en information et trivialement consommable côté Swift.
- La décision de conserver une entrée et une sortie JSON (plutôt qu'une API Swift typée native) est pragmatique : l'application consommatrice utilise déjà un client OpenAI Swift qui produit et consomme ces JSON, et l'API OpenAI évolue. Un mapping typé complet coûterait plus cher à maintenir qu'à utiliser.
- L'auto-sleep configurable combiné au wake implicite forme un cycle de vie adapté aux contraintes mobiles : l'app peut "oublier" de libérer la VRAM — le moteur le fait seul après inactivité — et n'a qu'à relancer une requête pour la reprise. Cela simplifie nettement le code applicatif des callbacks de cycle de vie iOS.
- Si un besoin futur de routage des logs via OSLog apparaît, la voie la plus propre est un patch isolé de `common/log.cpp` ajoutant un setter de callback. Ce patch devra rester atomique et réversible pour faciliter la synchronisation amont. En attendant, l'utilisation de `setLogLevel(.off)` permet de supprimer le bruit à défaut de le rediriger.
- Les trois modules purs (`ParamsTranslator`, `TaskBuilder`, `ResultFormatter`) concentrent la valeur testable du framework. Un défaut dans `EngineCore` ou dans la façade Swift sera probablement détecté rapidement par l'usage manuel dans l'application de dev. Un défaut dans un module pur — par exemple un champ OpenAI mal mappé — peut passer inaperçu longtemps et causer des comportements silencieusement incorrects. Priorité donnée aux tests là où le ROI est maximal.
