# llama.cpp/examples/llama.foundationmodels

SwiftUI demo (iOS 27, macOS 27) of the `LlamaApple` package
([bindings/apple](../../bindings/apple/README.md)): GGUF models run by the
llama.cpp engine behind Foundation Models' `LanguageModel` protocol, with
`LanguageModelSession`, `Tool` and `@Generable`.

`examples/llama.swiftui` is a separate, older example; it is unchanged.

## Build and run

1. Build the native framework once, from the repository root (Xcode 27,
   CMake ≥ 3.21):

   ```bash
   scripts/build-apple-language-model.sh
   ```

2. Open `LlamaFMDemo.xcodeproj` and run the `LlamaFMDemo` scheme on an iOS 27
   simulator, an iPhone, or a Mac with macOS 27. For a device, choose your team
   in Signing & Capabilities (the bundle identifier
   `org.ggml.llama.foundationmodels-demo` may need a suffix). On iOS the app
   requests the increased memory limit entitlement
   (`Config/LlamaFMDemo-iOS.entitlements`).

From the command line:

```bash
cd examples/llama.foundationmodels
xcodebuild build -scheme LlamaFMDemo -destination 'generic/platform=iOS Simulator'
xcodebuild test -scheme LlamaFMDemo -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The project depends on the local package (`../../bindings/apple`); its
sources are file system synchronized groups (`LlamaFMDemo/`,
`LlamaFMDemoTests/`): a file added there is part of the target. The
model catalog is the package's `bindings/apple/Catalog/models.json`, copied
into the app.

## What it shows

- **Model library.** The catalog's qualified models (Qwen3.5-2B Q4_K_M with its
  projector): download with a background `URLSession`, pause, resume, cancel,
  verification, installation. Import of a local GGUF file and its optional
  projector (copied into the app; the original is never modified). Load,
  unload and delete of installed models. Each state is shown where the action
  was asked: transfer, verification, installation, loading, failure.
- **Chat** with streamed answers, images (photo library or file, orientation
  kept), reasoning shown apart, tool calls and their outputs, and a
  **City guide** mode that generates a `@Generable` value (`CityGuide`) whose
  fields fill in as they stream.
- **Two local tools** without external effects: `calculate` (arithmetic) and
  `lookup_product` (a small fictitious shop). Try “How much are 3 pens and a
  mug?”.
- **Two indicators** above the chat: what the request is doing (queued,
  loading the model, processing the prompt with its progress, generating) and
  the context occupancy against the effective capacity reported by the engine
  (`LlamaGenerationMonitor`). Outside a request the last measure is marked as
  such; before any request it is “Unavailable”, never zero.
  `session.usage` is shown per response as a consumption, never as occupancy.
- **Capabilities.** Tool, reasoning and image controls are enabled only for
  what the model's catalog entry qualifies; an imported model gets structured
  output only. An image with a model or profile without vision is refused at
  the composer with the reason.

## Behaviour

- **Runtime.** One `LlamaRuntime` for the app: one resident model, one
  generation at a time, four waiting requests. A request loads a local model
  on demand; “Load” only does it earlier.
- **Conversations.** Each conversation keeps the model and load profile it
  started with. Choosing another model, or “Start a conversation with these
  settings”, starts a new one; the others stay readable for the life of the
  app. Conversations are not restored after the app quits; settings and models
  are.
- **Interruptions.** Stop, an error, an unload or the iOS background keep the
  fragments already shown in the turn, marked interrupted, but the session's
  transcript goes back to the last complete turn. “Retry” submits the same
  request once. Tools already run are not undone.
  Foundation Models reverts a failed turn itself; a **cancelled** stream ends
  without an error and keeps its partial response in the transcript
  (observed with iOS 27.0): the demo checks for cancellation and removes that
  response (`Conversation.rollBack`).
- **Lifecycle.** On iOS, moving to the background (`ScenePhase.background`)
  cancels the generations and the waits of explicit loads; `inactive` (a
  picker, the app switcher) changes nothing, and nothing resumes on return.
  On macOS, hiding or leaving the window never interrupts a generation.
  Downloads follow their own lifecycle: the `LlamaModelDownloads` object is
  created at launch, background launches included, and
  `.backgroundTask(.urlSession(_:))` forwards the session events.
- **Simulator.** Settings default to the CPU on the iOS simulator: its Metal
  device fails with Qwen3.5 (projector load and prompt checkpoints, see the
  [report](../../docs/design/apple-language-model-report.md)). The first load
  and an image take long on the simulator's CPU; these are not device
  measurements.
- **Streaming.** Foundation Models withholds the latest event of a stream: a
  fragment shows when the next one arrives, or at the end.

## Tests

`LlamaFMDemoTests` run in the app (host application):

- the presentation model against a scripted `LanguageModel` driving real
  `LanguageModelSession`s: streaming, error after fragments and retry (the
  transcript submitted again is checked), cancellation and rollback, context
  overflow message, structured output, capabilities and options, lifecycle
  policy, indicators, tools;
- the application model on the real engine with
  `tools/server/tests/tmp/stories15M-q4_0.gguf` (skipped when absent): empty
  installation, settings kept across instances, on-demand load, streamed
  answer, context measure (stories15M caps the context at its 128 training
  tokens: the effective capacity), unload during a request, new conversation
  on a model change, retry that reloads;
- a background `URLSession` download from a local server, installed in the
  store (the system refuses background sessions to the package's `xctest`
  process).

`LlamaFMDemoUITests` (scheme `LlamaFMDemoUITests`) play the journeys through
the interface with the catalog model, which must already be installed in the
app (download it once from the library; the tests skip otherwise): the tool
loop, the City guide, Stop → Retry, and the background interruption. They are
slow on the simulator's CPU (minutes):

```bash
xcodebuild test -scheme LlamaFMDemoUITests -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### On a device

Sign with your team (`DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates`)
and keep the device unlocked (Xcode waits otherwise). Metal is the default
there.

- `DeviceDownloadUITests` downloads the catalog model from an **empty
  installation** (delete the app first; skipped otherwise), suspends the app
  for 90 s, terminates it for 90 s, relaunches it and waits for the
  installation. It installs the model the other device tests use.
- `DeviceQualificationTests` (hosted, opt-in) runs each announced capability
  with the model the app downloaded, on Metal, and logs the measures (lines
  starting with `P7`): memory footprint, load, first token, generation and
  prompt rates, image, cancellation, load/unload cycles.
  `TEST_RUNNER_LLAMA_QUALIFICATION_OFFLOAD=none` measures the CPU.
- `QwenScenarioUITests` play the interface journeys as on the simulator.

```bash
xcodebuild test -scheme LlamaFMDemoUITests -destination 'id=<device>' DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates \
  -only-testing:LlamaFMDemoUITests/DeviceDownloadUITests
TEST_RUNNER_LLAMA_DEVICE_QUALIFICATION=1 xcodebuild test -scheme LlamaFMDemo -destination 'id=<device>' \
  DEVELOPMENT_TEAM=<team> -allowProvisioningUpdates -only-testing:LlamaFMDemoTests/DeviceQualificationTests
```

Measured on an iPad Pro 11" (M1, 8 GB, iPadOS 27.2) with Qwen3.5-2B Q4_K_M,
context 4096 and the projector: see the
[report](../../docs/design/apple-language-model-report.md#p7--qualification-et-livraison).
