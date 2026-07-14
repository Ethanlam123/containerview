// Container Monitor - app delegate.
//
// Owns the two pre-runloop concerns the SwiftUI App can't reach cleanly:
// single-instance focusing and graceful server shutdown on quit. The
// `container` CLI check + server spawn live in AppModel (started from the root
// view's .task).

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Single-instance: if another copy is already running, focus it and exit
        // the new launch instead of opening a second window + second server.
        if let bid = Bundle.main.bundleIdentifier {
            for app in NSWorkspace.shared.runningApplications
            where app.bundleIdentifier == bid && app != NSRunningApplication.current {
                app.activate()
                exit(EXIT_SUCCESS)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}
