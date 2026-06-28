import SwiftUI
import LlamaEngine

struct SettingsPanel: View {
    @Bindable var vm: ChatViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Path to the .gguf model", text: $vm.modelPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vm.engineState != .unloaded)

                if vm.canLoad {
                    Button("Load", action: vm.loadModel)
                        .buttonStyle(.borderedProminent)
                } else if vm.canUnload {
                    Button("Unload", role: .destructive, action: vm.unloadModel)
                        .buttonStyle(.bordered)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 60)
                }

                lifecycleButtons
            }

            HStack {
                TextField("mmproj .gguf (optional, for vision/audio)", text: $vm.mmprojPath)
                    .textFieldStyle(.roundedBorder)
                    .disabled(vm.engineState != .unloaded)
            }

            if vm.engineState == .ready, vm.capabilities.displayableCapabilities {
                capabilitiesLabel
            }

            DisclosureGroup("Settings") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("System prompt", text: $vm.systemPrompt, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)

                    HStack {
                        Text("Context")
                        Stepper(value: $vm.contextSize, in: 512...32768, step: 512) {
                            Text("\(vm.contextSize)")
                                .monospacedDigit()
                                .frame(width: 64, alignment: .leading)
                        }
                        Spacer()
                        Text("GPU layers")
                        Stepper(value: $vm.gpuLayers, in: -1...999) {
                            Text("\(vm.gpuLayers)")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .leading)
                        }
                    }
                    .disabled(vm.engineState != .unloaded)

                    HStack {
                        Text("Temperature")
                        Slider(value: $vm.temperature, in: 0...2)
                        Text(String(format: "%.2f", vm.temperature))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }

                    Toggle("Flash attention", isOn: $vm.flashAttention)
                        .disabled(vm.engineState != .unloaded)

                    Toggle("Enable tools (get_current_time, calculator)", isOn: $vm.enableTools)
                        .disabled(vm.engineState == .ready && !vm.capabilities.supportsToolCalls)
                        .help(vm.engineState == .ready && !vm.capabilities.supportsToolCalls
                              ? "The loaded chat template does not advertise tool-call support."
                              : "Expose the local tools to the model as OpenAI-style functions.")
                }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var lifecycleButtons: some View {
        switch vm.engineState {
        case .pausing:
            Button("Pausing...") { }
                .buttonStyle(.bordered)
                .disabled(true)
        case .ready, .loading, .resuming:
            if vm.canPause {
                Button("Pause", action: vm.pauseModel)
                    .buttonStyle(.bordered)
                    .help(pauseHelp(for: vm.engineState))
            }
        case .paused:
            if vm.canResume {
                Button("Resume", action: vm.resumeModel)
                    .buttonStyle(.borderedProminent)
                    .help("Reloads the model with the same settings.")
            }
        case .unloaded, .unloading:
            EmptyView()
        }
    }

    private func pauseHelp(for state: EngineState) -> String {
        switch state {
        case .loading: return "Interrupts the current load and switches to paused."
        case .resuming: return "Interrupts the current resume and stays paused."
        default: return "Releases the context and keeps the config for resume()."
        }
    }

    private var capabilitiesLabel: some View {
        HStack(spacing: 6) {
            Text("Capabilities:")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if vm.capabilities.supportsVision {
                CapabilityBadge(text: "vision", icon: "eye", tint: .blue)
            }
            if vm.capabilities.supportsAudio {
                CapabilityBadge(text: "audio", icon: "waveform", tint: .blue)
            }
            if vm.capabilities.supportsToolCalls {
                CapabilityBadge(text: "tool calls", icon: "wrench.and.screwdriver", tint: .orange)
            }
            if vm.capabilities.supportsReasoning {
                CapabilityBadge(text: "reasoning", icon: "brain", tint: .purple)
            }

            Spacer(minLength: 0)
        }
    }
}
