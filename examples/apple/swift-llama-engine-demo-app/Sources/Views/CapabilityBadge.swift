import SwiftUI
import LlamaEngine

struct CapabilityBadge: View {
    let text: String
    let icon: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.12))
            .overlay(
                Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}

extension ModelCapabilities {
    var displayableCapabilities: Bool {
        supportsVision || supportsAudio || supportsToolCalls || supportsReasoning
    }
}
