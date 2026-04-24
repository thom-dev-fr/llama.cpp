import SwiftUI

#if os(macOS)
import AppKit

/// Quand l'app est lancée depuis un `executableTarget` SwiftPM, il n'y a ni
/// `Info.plist` ni `CFBundleIdentifier` : par défaut AppKit la traite comme un
/// agent, la fenêtre ne s'affiche pas au premier plan et la console émet
/// « Cannot index window tabs due to missing main bundle identifier ».
///
/// On force la politique d'activation à `.regular` et on demande l'activation
/// explicitement — l'avertissement de bundle identifier peut rester (il est
/// inoffensif) mais la fenêtre apparaît correctement.
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
