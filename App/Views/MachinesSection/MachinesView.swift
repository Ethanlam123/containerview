// Machines section. Apple's `container machine` has no stop endpoint in the
// backend, so the primary action surfaces the CLI command to run (matches web).

import AppKit
import SwiftUI
import ContainerMonitorCore

struct MachinesView: View {
    let model: DashboardModel

    var body: some View {
        let machines = model.lastState?.machines ?? []
        if machines.isEmpty {
            ContentUnavailableView("No machines", systemImage: "cpu",
                description: Text("Try `container machine create alpine:3.22 --name dev`"))
        } else {
            List {
                ForEach(Array(machines.enumerated()), id: \.offset) { _, m in
                    MachineRow(machine: m)
                }
            }
        }
    }
}

private struct MachineRow: View {
    let machine: MachineList

    private var name: String { machine.configuration?.name ?? machine.id ?? "unknown" }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(name).font(.headline)
                    if let state = machine.status?.state {
                        StatusPill(state: state)
                    }
                }
                if let img = machine.configuration?.image {
                    Text(img).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                let cpus = machine.configuration?.resources?.cpus
                let mem = machine.configuration?.resources?.memoryInBytes
                if cpus != nil || mem != nil {
                    Text("\(cpus.map { "\($0) cpu" } ?? "") \(mem.map { formatBytes($0) } ?? "")")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                if let ip = machine.status?.ipv4Address {
                    Text(ip).font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button {
                let cmd = "container machine run -n \(name)"
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(cmd, forType: .string)
            } label: {
                Label("Copy run", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
