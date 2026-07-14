// System section: version components + macOS + status, with an Advanced
// disclosure that lazily loads system properties + DNS JSON.

import SwiftUI

struct SystemView: View {
    let model: DashboardModel

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("System", value: model.lastState?.health?.status ?? "-")
            }
            Section("Versions") {
                ForEach(model.lastState?.version ?? [], id: \.appName) { v in
                    LabeledContent(v.appName, value: "\(v.version) (\(v.buildType))")
                }
                if let mac = model.lastState?.macosVersion {
                    LabeledContent("macOS", value: mac)
                }
            }
            Section {
                DisclosureGroup("Advanced") {
                    AdvancedDetail(client: model.client)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedDetail: View {
    let client: ServerClient?
    @State private var properties = "loading…"
    @State private var dns = "loading…"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System Properties").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(properties).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("DNS Domains").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(dns).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .task {
            guard let client else { properties = "unavailable"; dns = "unavailable"; return }
            // Fire each independently so a slow endpoint never blocks the other.
            Task { properties = (try? await load(client, "/api/system/properties")) ?? "unavailable" }
            Task { dns = (try? await load(client, "/api/system/dns")) ?? "unavailable" }
        }
    }

    private func load(_ client: ServerClient, _ path: String) async throws -> String {
        prettyJSON(try await client.fetchJson(path))
    }
}
