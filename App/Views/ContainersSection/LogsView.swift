// SSE logs view for one container. Owns a LogsModel that reconnects past the
// server's 120s stream cap (URLSession does not auto-reconnect like EventSource).

import SwiftUI

@MainActor
@Observable
final class LogsModel {
    private(set) var lines: [String] = []
    private(set) var connected = false
    var paused = false

    private let client: ServerClient
    private let id: String
    private var task: Task<Void, Never>?

    init(client: ServerClient, id: String) {
        self.client = client
        self.id = id
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.runLoop() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func clear() { lines.removeAll() }

    private func runLoop() async {
        // The server caps every SSE stream at 120s; URLSession does not
        // auto-reconnect like EventSource, so reopen on stream end.
        while !Task.isCancelled {
            do {
                for try await line in client.logs(id: id) {
                    if Task.isCancelled { return }
                    connected = true
                    guard !paused, !line.isEmpty else { continue }
                    lines.append(line)
                    if lines.count > 1000 { lines.removeFirst(lines.count - 1000) }
                }
            } catch { /* fall through to reconnect */ }
            connected = false
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }
}

struct LogsView: View {
    @State private var model: LogsModel

    init(client: ServerClient, id: String) {
        _model = State(initialValue: LogsModel(client: client, id: id))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Logs").font(.headline)
                if !model.connected {
                    Text("reconnecting…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Pause", isOn: $model.paused).controlSize(.small)
                Button("Clear") { model.clear() }.controlSize(.small)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(6)
                        .id("bottom")
                }
                .background(.quaternary.opacity(0.3))
                .onChange(of: model.lines.count) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}
