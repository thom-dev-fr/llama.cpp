# LlamaChatDemo

Minimal **SwiftUI** demo app (macOS 14+ / iOS 17+) using the `LlamaEngine` package from `examples/apple/swift-llama-engine`.

The app demonstrates:

- loading, pausing, resuming, and unloading a `.gguf` model through `LlamaEngine`,
- configuring context size, GPU layers, flash attention, temperature, and an optional multimodal projector (`mmproj`) path,
- probing model metadata with `LlamaEngine.modelInfo(modelURL:mmprojURL:)` and showing advertised capabilities,
- sending an **OpenAI-compatible** chat request with `LlamaEngine.chatCompletionStream(requestJSON:)` / `EngineStream`,
- parsing streaming chunks, accepting both JSON object chunks and `[{...}]` array chunks,
- handling **reasoning** models through `delta.reasoning_content`, displayed in a collapsible `Thinking` block,
- OAI **function calling**: tool declarations, streamed `tool_calls` detection, local execution, and automatic follow-up completion with the tool results,
- image and audio attachments for models whose metadata advertises vision or audio support,
- cooperative cancellation (`Task.cancel()` -> `llama_engine_stream_cancel`),
- engine state (`unloaded`, `loading`, `ready`, `paused`, etc.) exposed by `EngineState`.

## Prerequisites

1. Xcode 15+ and CMake 3.28+.
2. Build the xcframework **before** opening the example:

   ```bash
   # from the repository root
   ./examples/apple/swift-llama-engine/scripts/build-xcframework.sh
   ```

   This produces `examples/apple/swift-llama-engine/build/LlamaEngineCore.xcframework`, referenced by `examples/apple/swift-llama-engine/Package.swift`.

3. Have a `.gguf` model somewhere on disk, for example `Qwen3.5-2B-Q4_K_M.gguf`.
4. For vision or audio, also provide a compatible projector GGUF in the `mmproj` field.

## Run on macOS (command line)

```bash
cd examples/apple/swift-llama-engine-demo-app
swift run LlamaChatDemo
```

A window opens. Paste the absolute path to your `.gguf` into the model path field, optionally set an `mmproj` path, click **Load**, wait until the indicator turns green (`ready`), then chat.

## Run on iOS / macOS with Xcode

1. Use `File -> Open...` and select this folder's `Package.swift` (`examples/apple/swift-llama-engine-demo-app/Package.swift`).
2. Choose the `LlamaChatDemo` scheme and a destination compatible with the xcframework you built.
3. Run the app.

On iOS, the model and optional projector must be available through a path the app can read, such as a file in the app container. The demo is primarily aimed at macOS, where an absolute filesystem path works directly.

### macOS note: `Cannot index window tabs due to missing main bundle identifier`

A SwiftUI app launched from a SwiftPM `executableTarget` is not packaged as a `.app`: it has no `Info.plist` and no `CFBundleIdentifier`. AppKit can log:

```text
Cannot index window tabs due to missing main bundle identifier
```

The demo includes a small `AppDelegate` that calls `NSApp.setActivationPolicy(.regular)` and `NSApp.activate(ignoringOtherApps:)` at launch (see `Sources/App/LlamaChatDemoApp.swift`). The warning may remain in the logs; it is harmless and only disappears when the app is packaged in a regular app bundle.

To remove it entirely, create a regular **macOS/iOS Xcode project** (`File -> New -> Project... -> App`), delete the sample Swift file, add the sources from this package's `Sources/` directory, then add the Apple package as a Swift Package dependency (`File -> Add Package Dependencies... -> Add Local...` -> select `llama.cpp/examples/apple/swift-llama-engine`). The Xcode project generates a complete `Info.plist`, so AppKit can resolve the bundle metadata and the warning disappears.

## Attachments

When the loaded model advertises compatible capabilities, the composer shows attachment buttons:

| Capability | Request content |
| --- | --- |
| `vision` | Images are downscaled to a maximum side of 1024 px when possible and sent as `image_url` data URLs. |
| `audio` | `.wav` and `.mp3` files up to 20 MB are sent as `input_audio` parts. |

Attachment support depends on the model and projector metadata. The UI hides image or audio attachment buttons when the loaded files do not advertise the matching capability.

## Tools (function calling)

The **Enable tools** toggle in the Settings panel injects a `tools` array into each request with the OAI declarations for the two functions defined in `ToolRegistry.swift`:

| Tool | Description |
| --- | --- |
| `get_current_time` | Returns the current ISO 8601 time, with an optional IANA timezone. |
| `calculator` | Evaluates a simple arithmetic expression (`+ - * / ( )`). |

When the model answers with `tool_calls` instead of text:

1. Calls are accumulated from streamed deltas (`delta.tool_calls[].function.arguments` is concatenated chunk by chunk), then displayed in a `Call <name>` bubble below the assistant bubble.
2. At the end of the stream, each tool is executed locally by its Swift handler and the result is added as a `role: "tool"` message.
3. A new completion starts automatically with the enriched history, so the model can produce its final answer to the user. `maxToolHops = 4` avoids infinite loops.

Example prompts that trigger tools:

- `What time is it in Tokyo?`
- `What is 17 * 42 + 3?`

Model choice matters: not all models know how to use tools. The toggle is disabled after loading when the model metadata does not advertise tool-call support.

## What the demo does not do

- No conversation persistence.
- No multi-model management.
- No advanced sampler configuration beyond the controls exposed in the settings panel.
- No model picker or bundled model download flow.

The goal is to stay short and readable. The engine-facing logic lives in `Sources/Chat/ChatViewModel.swift` and can serve as a starting point for a larger app.
