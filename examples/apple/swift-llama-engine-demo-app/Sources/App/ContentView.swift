import SwiftUI

struct ContentView: View {
    @State private var vm = ChatViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(vm: vm)
            Divider()
            SettingsPanel(vm: vm)
            Divider()
            TranscriptView(vm: vm)
            Divider()
            ComposerView(vm: vm)
        }
        .frame(minWidth: 520, minHeight: 600)
    }
}
