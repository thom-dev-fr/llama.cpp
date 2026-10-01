import SwiftUI

/// When the demo cancels its inference work.
///
/// iOS: when the application really moves to the background (GPU work is not
/// allowed there and the system may suspend it). `inactive` is transitional
/// (a file or photo picker, the app switcher, a system alert): it changes
/// nothing. Nothing resumes on return; the user may retry.
///
/// macOS: hiding or leaving the window never interrupts a generation.
///
/// Downloads follow their own lifecycle (background `URLSession`).
enum LifecyclePolicy {
    enum Platform {
        case iOS, macOS

        static var current: Platform {
            #if os(macOS)
            .macOS
            #else
            .iOS
            #endif
        }
    }

    static let backgroundReason = "Interrupted: the app moved to the background"

    static func cancelsInference(from old: ScenePhase, to new: ScenePhase, on platform: Platform = .current) -> Bool {
        platform == .iOS && new == .background && old != .background
    }
}
