// Container Monitor - SwiftUI app entry point.

import SwiftUI

@main
struct ContainerMonitorApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @FocusedValue(\.activeDashboardModel) private var dashboardModel

    var body: some Scene {
        WindowGroup("Container Monitor") {
            RootView(model: model)
                .task { model.start() }
                .onAppear { appDelegate.model = model }
        }
        .commands {
            // Cmd+R Refresh, wired to the frontmost dashboard via @FocusedValue.
            CommandGroup(after: .toolbar) {
                Button("Refresh") { dashboardModel?.refresh() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(dashboardModel == nil)
            }
        }
    }
}
