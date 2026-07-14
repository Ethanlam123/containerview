// Builder section: state + resources + Start/Stop.

import SwiftUI

struct BuilderView: View {
    let model: DashboardModel
    @State private var busy = false

    private var builder: BuilderStatus? { model.lastState?.builder?.first }

    var body: some View {
        Form {
            Section("Builder") {
                LabeledContent("State") {
                    Text(builder?.state ?? "unknown").font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.quaternary.opacity(0.4), in: Capsule())
                }
                LabeledContent("CPUs", value: builder?.cpus.map(String.init) ?? "-")
                LabeledContent("Memory", value: formatBytes(builder?.memoryInBytes))
                LabeledContent("Container", value: shortHash(builder?.containerID))
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Start") { perform(start: true) }.disabled(busy)
                Button("Stop") { perform(start: false) }.disabled(busy)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(10)
        }
    }

    private func perform(start: Bool) {
        busy = true
        Task {
            await model.controlBuilder(start: start)
            busy = false
        }
    }
}
