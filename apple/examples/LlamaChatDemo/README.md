# LlamaChatDemo

Exemple minimal d'application **SwiftUI** (macOS / iOS) qui exploite le produit
`LlamaEngine` exposé par le `Package.swift` racine de ce fork.

L'app illustre :

- le chargement / déchargement d'un modèle `.gguf` via `LlamaEngine.load(_:)`,
- l'envoi d'une requête chat **OpenAI-compatible** via
  `LlamaEngine.chatCompletionStream(requestJSON:)`,
- le parsing des chunks streaming (acceptant les deux formes : objet JSON et
  tableau `[{…}]`),
- la gestion des modèles de **raisonnement** (DeepSeek-R1, QwQ, …) via
  `delta.reasoning_content` affiché dans un bloc « Thinking » repliable,
- le **function calling** OAI : déclaration de tools, détection des
  `tool_calls` en streaming, exécution locale, relance automatique de la
  complétion avec les résultats,
- l'annulation coopérative (`Task.cancel()` → `llama_engine_stream_cancel`),
- l'état du moteur (`unloaded` / `loading` / `ready` / …) exposé par
  `EngineState`.

```
apple/examples/LlamaChatDemo/
├── Package.swift
└── Sources/LlamaChatDemo/
    ├── LlamaChatDemoApp.swift    # @main, WindowGroup, AppDelegate macOS
    ├── ContentView.swift         # UI SwiftUI (header, settings, transcript, composer)
    ├── ChatViewModel.swift       # @MainActor ObservableObject, bridge vers LlamaEngine
    ├── ChatMessage.swift         # modèle (user / assistant / tool + ToolCall)
    └── ToolRegistry.swift        # tools exposés au modèle (get_current_time, calculator)
```

## Prérequis

1. Xcode 15+ et CMake 3.28+.
2. Construire le xcframework **avant** toute ouverture de l'exemple :

   ```bash
   # depuis la racine du dépôt
   ./apple/scripts/build-xcframework.sh
   ```

   Cela produit `apple/build/LlamaEngineCore.xcframework`, référencé par le
   `Package.swift` racine.

3. Avoir un modèle `.gguf` quelque part sur le disque (ex.
   `Meta-Llama-3-8B-Instruct.Q4_K_M.gguf`).

## Lancer sur macOS (ligne de commande)

```bash
cd apple/examples/LlamaChatDemo
swift run LlamaChatDemo
```

Une fenêtre s'ouvre. Colle le chemin absolu vers ton `.gguf` dans le champ
prévu, clique **Load**, attends que l'indicateur passe au vert (`ready`), puis
discute.

## Lancer sur iOS / macOS via Xcode

1. `File → Open…` et sélectionne le fichier `Package.swift` de ce dossier
   (`apple/examples/LlamaChatDemo/Package.swift`).
2. Choisis le schéma `LlamaChatDemo` et un device (simulateur iOS 16+ ou Mac).
3. **Run**.

Sur iOS tu devras embarquer le `.gguf` dans le bundle ou dans le conteneur de
l'app (Documents) et adapter le champ de chemin en conséquence ; la démo vise
principalement macOS, où un chemin de système de fichiers fonctionne
directement.

### Note sur macOS : « Cannot index window tabs due to missing main bundle identifier »

Une app SwiftUI lancée depuis un `executableTarget` SwiftPM n'est pas empaquetée
dans un `.app` : elle n'a donc ni `Info.plist` ni `CFBundleIdentifier`. Par
défaut AppKit la considère comme un **agent** et ne montre pas la fenêtre. C'est
exactement ce que signale la console avec :

```
Cannot index window tabs due to missing main bundle identifier
```

La démo embarque un petit `AppDelegate` qui contourne le problème en forçant
`NSApp.setActivationPolicy(.regular)` et `NSApp.activate(ignoringOtherApps:)` au
lancement (cf. `LlamaChatDemoApp.swift`). Après cette correction, la fenêtre
s'ouvre correctement ; l'avertissement peut rester dans les logs — il est
inoffensif et disparaît uniquement si on empaquette l'app dans un vrai bundle.

Pour t'en débarrasser entièrement, crée un **projet Xcode macOS/iOS** classique
(`File → New → Project… → App`), supprime le fichier Swift d'exemple,
déposes-y les quatre sources de `Sources/LlamaChatDemo/`, puis ajoute le fork
comme dépendance Swift Package (`File → Add Package Dependencies… → Add
Local…` → sélectionne la racine du dépôt `llama.cpp`). Le projet Xcode génère
un `Info.plist` complet, donc AppKit s'y retrouve et l'avertissement disparaît.

## Tools (function calling)

Le toggle **« Enable tools »** dans le panneau Paramètres injecte, dans chaque
requête, le tableau `tools` contenant la déclaration OAI des deux fonctions
définies dans `ToolRegistry.swift` :

| Tool               | Description                                                    |
|--------------------|----------------------------------------------------------------|
| `get_current_time` | Renvoie l'heure courante ISO 8601, timezone optionnelle        |
| `calculator`       | Évalue une expression arithmétique (`+ - * / ( )`) via NSExpression |

Quand le modèle répond avec des `tool_calls` plutôt qu'avec du texte :

1. Les appels sont accumulés à partir des deltas streamés
   (`delta.tool_calls[].function.arguments` est concaténé morceau par morceau),
   puis affichés dans une bulle orange « Call `<name>` » sous la bulle
   assistant.
2. À la fin du stream, chaque tool est exécuté localement par son handler Swift
   et le résultat est ajouté comme message `role: "tool"` (bulle verte).
3. Une nouvelle complétion est lancée automatiquement avec l'historique enrichi
   — le modèle produit alors sa **réponse finale** à l'utilisateur. Limite :
   `maxToolHops = 4` pour éviter les boucles infinies.

Exemple de prompts qui déclenchent les tools :

- « *Quelle heure est-il à Tokyo ?* »
- « *Combien font 17 × 42 + 3 ?* »

Le choix du modèle compte : tous les modèles ne savent pas utiliser les tools.
Les familles **Qwen2.5 / Qwen3 Instruct**, **Llama 3.1+**, **Mistral Small**
fonctionnent bien ; les modèles « base » ou très petits appelleront rarement
un tool correctement.

## Ce que la démo ne fait **pas**

- Pas d'images / audio (l'API mtmd n'est pas exposée en v1).
- Pas de persistance de conversation.
- Pas de gestion de plusieurs modèles simultanément.
- Pas de configuration avancée des sampleurs (seuls `temperature` est exposé ;
  tout le reste suit les défauts de `server-context`).

Le but est de rester court et lisible ; la logique « moteur » tient dans
`ChatViewModel.swift` (~150 lignes) et peut servir de point de départ pour une
app plus ambitieuse.
