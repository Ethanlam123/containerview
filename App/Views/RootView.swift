// Container Monitor - root view. Switches on the launch phase; the ready case
// is replaced by DashboardView in step 3.

import SwiftUI

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.phase {
        case .launching:
            LaunchingView()
        case .failed(let message):
            ErrorPaneView(message: message)
        case .ready(let port):
            DashboardView(port: port)
        }
    }
}

private struct LaunchingView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large)
            Text("Starting Container Monitor…")
                .font(.headline)
            Text("Spawning the local server")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
    }
}

private struct ErrorPaneView: View {
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Container Monitor could not start")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.windowBackground)
    }
}
