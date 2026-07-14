// Containers section: native Table bound to the poll model's derived rows.
// Row selection drives the inspector pane.

import SwiftUI

struct ContainersView: View {
    let model: DashboardModel
    @Binding var selection: String?

    var body: some View {
        if model.rows.isEmpty {
            ContentUnavailableView(
                "No containers",
                systemImage: "shippingbox",
                description: Text("Run `container run …` to create one.")
            )
        } else {
            Table(model.rows, selection: $selection) {
                TableColumn("Name") { Text(shortHash($0.id)) }
                    .width(min: 120, ideal: 150)
                TableColumn("Image") {
                    Text($0.imageRef).font(.system(.body, design: .monospaced))
                }
                TableColumn("Status") { StatusPill(state: $0.state) }
                TableColumn("IP") { Text($0.ip) }.width(min: 80, ideal: 100)
                TableColumn("CPU") { Text(formatPercent($0.cpuPercent)) }
                    .alignment(.trailing)
                TableColumn("Memory") { Text(formatBytes($0.memoryBytes)) }
                    .alignment(.trailing)
                TableColumn("Arch") { Text($0.arch) }.width(ideal: 70)
            }
        }
    }
}

struct StatusPill: View {
    let state: String

    var body: some View {
        Text(state.capitalized)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
    }

    private var tint: Color {
        let s = state.lowercased()
        if s.contains("running") { return .green }
        if s.contains("created") { return .orange }
        return .secondary
    }
}
