// Disk usage section: per-category (containers/images/volumes) active/total/size
// + reclaimable, with a Prune action (native confirmation dialog).

import SwiftUI
import ContainerMonitorCore

struct DiskView: View {
    let model: DashboardModel
    @State private var pruningCategory: String?
    @State private var confirming: String?

    private var df: SystemDF? { model.lastState?.diskUsage }

    var body: some View {
        if let df {
            List {
                Section {
                    DiskRow(title: "Containers", category: df.containers) { confirming = "containers" }
                    DiskRow(title: "Images", category: df.images) { confirming = "images" }
                    DiskRow(title: "Volumes", category: df.volumes) { confirming = "volumes" }
                } header: { Text("System disk usage") }
            }
            .confirmationDialog(
                pruningCategory.map { "Prune \($0)? This removes unused \($0)." } ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible
            ) {
                Button("Prune", role: .destructive) {
                    if let key = confirming { performPrune(key) }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            }
        } else {
            ContentUnavailableView("No disk-usage data", systemImage: "externaldrive")
        }
    }

    private func performPrune(_ key: String) {
        pruningCategory = key
        Task {
            await model.prune(key)
            pruningCategory = nil
        }
    }
}

private struct DiskRow: View {
    let title: String
    let category: SystemDF.Category
    let onPrune: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Text(formatBytes(category.sizeInBytes))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Text("\(category.active) active / \(category.total) total")
                    if category.reclaimable > 0 {
                        Text("\(formatBytes(category.reclaimable)) reclaimable")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Button("Prune", role: .destructive, action: onPrune)
                .controlSize(.small)
                .disabled(category.reclaimable <= 0)
                .help(category.reclaimable > 0
                      ? "Remove unused \(title.lowercased())"
                      : "Nothing to reclaim")
        }
        .padding(.vertical, 2)
    }
}
