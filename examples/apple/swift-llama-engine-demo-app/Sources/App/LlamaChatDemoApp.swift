import SwiftUI

#if os(macOS)
import AppKit

/// SwiftPM executable targets may launch as agents on macOS; force regular
/// activation so the window appears in front.
final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    true
  }
}
#endif

@main
struct LlamaChatDemoApp: App {
  #if os(macOS)
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  #endif

  var body: some Scene {
    WindowGroup("LlamaChatDemo") {
      ContentView()
    }
    #if os(macOS)
    .defaultSize(width: 780, height: 720)
    #endif
  }
}
