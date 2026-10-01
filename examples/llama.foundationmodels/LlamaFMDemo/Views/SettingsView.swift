import LlamaEngine
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("Context", selection: $model.settings.contextSize) {
                    ForEach(DemoSettings.contextSizes, id: \.self) { Text("\($0.formatted()) tokens").tag($0) }
                }
                Toggle("GPU (Metal)", isOn: $model.settings.usesGPU)
                Toggle("Load the projector (images)", isOn: $model.settings.loadsProjector)
            } header: {
                Text("Loading")
            } footer: {
                Text("These settings apply to new conversations; a conversation keeps the profile it started with. "
                    + "The iOS simulator runs on the CPU by default: its Metal device fails with Qwen3.5.")
            }
            Section("Generation") {
                Toggle("Tools (calculator, shop)", isOn: $model.settings.tools)
                Toggle("Reasoning", isOn: $model.settings.reasoning)
                Toggle("Greedy sampling", isOn: $model.settings.greedy)
                Picker("Response limit", selection: $model.settings.maximumResponseTokens) {
                    ForEach(DemoSettings.responseTokenLimits, id: \.self) { Text("\($0.formatted()) tokens").tag($0) }
                }
            }
            Section {
                Button("Start a conversation with these settings") {
                    model.startConversation()
                    dismiss()
                }
                .disabled(model.selectedModel == nil)
            }
            Section {
                LabeledContent("Resident models", value: "\(AppModel.limits.maximumResidentModels)")
                LabeledContent("Generations at once", value: "\(AppModel.limits.maximumActiveGenerations)")
                LabeledContent("Waiting requests", value: "\(AppModel.limits.maximumWaitingRequests)")
            } header: {
                Text("Runtime")
            } footer: {
                Text("Settings and models are kept; conversations are not restored after the app quits.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
