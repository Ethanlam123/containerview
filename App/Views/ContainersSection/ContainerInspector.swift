// Right-hand inspector for the selected container. Replaces the web's
// expandable-row drawer with the native inspector pattern (Mail/Finder):
// Details / Logs / Terminal tabs. Terminal lands in step 5.

import SwiftUI
import ContainerMonitorCore

struct ContainerInspector: View {
    let container: ContainerList
    let model: DashboardModel
    @State private var acting = false
    @State private var tab: InspectorTab = .details

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView(selection: $tab) {
                detailsForm
                    .tabItem { Label("Details", systemImage: "info.circle") }
                    .tag(InspectorTab.details)
                if let client = model.client {
                    LogsView(client: client, id: container.id)
                        .tabItem { Label("Logs", systemImage: "text.alignleft") }
                        .tag(InspectorTab.logs)
                }
                terminalTab
                    .tabItem { Label("Terminal", systemImage: "terminal") }
                    .tag(InspectorTab.terminal)
            }
            .padding(8)
        }
        .background(.windowBackground)
    }

    private enum InspectorTab: Hashable { case details, logs, terminal }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(container.id).font(.headline)
                Text(container.configuration.image.reference)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            StatusPill(state: container.status.state)
            actionButtons
        }
        .padding(10)
    }

    private var actionButtons: some View {
        let state = container.status.state.lowercased()
        return HStack(spacing: 6) {
            if state.contains("running") {
                Button("Stop") { perform(.stop) }.controlSize(.small).disabled(acting)
                Button("Kill") { perform(.kill) }.controlSize(.small)
                    .tint(.red).disabled(acting)
            } else {
                Button("Start") { perform(.start) }.controlSize(.small).disabled(acting)
            }
        }
    }

    private func perform(_ kind: DashboardModel.Action) {
        acting = true
        Task {
            await model.act(kind, id: container.id)
            acting = false
        }
    }

    @ViewBuilder
    private var terminalTab: some View {
        // Gate construction on the tab being active: SwiftTermView (and its ws +
        // PTY child) only mounts when the user opens this tab, and switching away
        // removes it from the tree -> dismantleNSView closes the ws. So an
        // ExecPool slot is held only while the Terminal tab is showing, not for
        // the lifetime of the inspector. (Pool cap is 8 on the server.)
        if model.execEnabled, let port = model.client?.port, tab == .terminal {
            SwiftTermView(port: port, id: container.id)
        } else if !model.execEnabled {
            ContentUnavailableView("Terminal unavailable", systemImage: "terminal",
                description: Text("Exec is disabled."))
        } else {
            ContentUnavailableView("Terminal", systemImage: "terminal",
                description: Text("Open this tab to start an interactive shell."))
        }
    }

    private var detailsForm: some View {
        Form {
            Section("General") {
                LabeledContent("ID", value: container.id)
                LabeledContent("Image", value: container.configuration.image.reference)
                LabeledContent("State", value: container.status.state)
                LabeledContent("Architecture",
                    value: "\(container.configuration.platform.architecture) / \(container.configuration.platform.os)")
                LabeledContent("CPUs", value: "\(container.configuration.resources.cpus)")
                LabeledContent("Memory", value: formatBytes(container.configuration.resources.memoryInBytes))
                if let host = container.configuration.hostname {
                    LabeledContent("Hostname", value: host)
                }
                if let started = container.status.startedDate {
                    LabeledContent("Started", value: started)
                }
            }
            if let ports = container.configuration.publishedPorts, !ports.isEmpty {
                Section("Published Ports") {
                    ForEach(ports, id: \.hostPort) { p in
                        LabeledContent("\(p.containerPort)/\(p.proto)",
                            value: "\(p.hostAddress):\(p.hostPort) -> \(p.containerPort)")
                    }
                }
            }
            if let nets = container.status.networks, !nets.isEmpty {
                Section("Networks") {
                    ForEach(nets, id: \.network) { n in
                        LabeledContent(n.network, value: n.ipv4Address ?? "-")
                    }
                }
            }
            if let mounts = container.configuration.mounts, !mounts.isEmpty {
                Section("Mounts") {
                    ForEach(mounts, id: \.destination) { m in
                        LabeledContent(m.destination, value: "\(m.source) [\(m.type.kind)]")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
