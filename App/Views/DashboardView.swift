// Three-column NavigationSplitView: sidebar (sections + system status) |
// content (section-specific, e.g. the containers Table) | inspector (selected
// container detail - filled in step 4).

import SwiftUI

enum SidebarSection: String, CaseIterable, Identifiable {
    case containers, images, machines, builder, disk, system
    var id: String { rawValue }
    var label: String {
        switch self {
        case .containers: "Containers"
        case .images: "Images"
        case .machines: "Machines"
        case .builder: "Builder"
        case .disk: "Disk"
        case .system: "System"
        }
    }
    var systemImage: String {
        switch self {
        case .containers: "shippingbox"
        case .images: "square.stack.3d.up"
        case .machines: "cpu"
        case .builder: "hammer"
        case .disk: "externaldrive"
        case .system: "gearshape"
        }
    }
}

struct DashboardView: View {
    let port: Int
    @State private var model = DashboardModel()
    @State private var section: SidebarSection? = .containers
    @State private var selectedContainerID: String?
    @State private var showingCreate = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $section, model: model)
        } content: {
            switch section ?? .containers {
            case .containers:
                ContainersView(model: model, selection: $selectedContainerID)
            case .images:
                ImagesView(model: model)
            case .machines:
                MachinesView(model: model)
            case .builder:
                BuilderView(model: model)
            case .disk:
                DiskView(model: model)
            case .system:
                SystemView(model: model)
            }
        } detail: {
            if section == .containers, let id = selectedContainerID,
               let container = model.lastState?.containers?.first(where: { $0.id == id }) {
                ContainerInspector(container: container, model: model)
            } else {
                ContentUnavailableView("No selection", systemImage: "sidebar.left",
                    description: Text("Select an item to inspect."))
            }
        }
        .navigationTitle("Container Monitor")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingCreate = true } label: { Label("New Container", systemImage: "plus") }
                    .help("Create + start a container")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle("Auto", isOn: Binding(get: { model.autoRefresh }, set: { model.setAutoRefresh($0) }))
                    .help("Auto-refresh")
                Stepper(value: Binding(get: { model.intervalSec }, set: { model.setInterval($0) }), in: 1...60) {
                    Text("\(Int(model.intervalSec))s")
                }
                .help("Poll interval (seconds)")
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh now")
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateContainerSheet(model: model)
        }
        .focusedSceneValue(\.activeDashboardModel, model)
        .safeAreaInset(edge: .top) { StatusBanner(model: model) }
        .task { model.activate(port: port) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resume() } else { model.pause() }
        }
    }
}

private struct SidebarView: View {
    @Binding var selection: SidebarSection?
    let model: DashboardModel

    var body: some View {
        List(SidebarSection.allCases, selection: $selection) { s in
            Label(s.label, systemImage: s.systemImage).tag(s)
        }
        .safeAreaInset(edge: .top) {
            SystemStatusBadge(model: model).padding(.horizontal, 12).padding(.vertical, 6)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
    }
}

private struct SystemStatusBadge: View {
    let model: DashboardModel

    var body: some View {
        let running = model.systemRunning
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor(running))
                .frame(width: 8, height: 8)
            Text(label(running))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if model.polling {
                ProgressView().controlSize(.mini).scaleEffect(0.7)
            }
        }
    }

    private func dotColor(_ running: Bool?) -> Color {
        switch running {
        case true: .green
        case false: .red
        case nil: .secondary
        }
    }
    private func label(_ running: Bool?) -> String {
        switch running {
        case true: "Running"
        case false: "Stopped"
        case nil: "Checking"
        }
    }
}

// Non-intrusive top banner for the last poll error and section warnings.
private struct StatusBanner: View {
    let model: DashboardModel
    @State private var dismissedError: String?

    var body: some View {
        let warnings = model.lastState?.warnings ?? []
        let error = (model.lastError != nil && model.lastError != dismissedError) ? model.lastError : nil
        if error != nil || !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let error {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(error).font(.caption).lineLimit(2)
                        Spacer()
                        Button("Dismiss") { dismissedError = model.lastError }
                            .buttonStyle(.borderless).font(.caption)
                    }
                }
                if !warnings.isEmpty {
                    DisclosureGroup("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")") {
                        ForEach(Array(warnings.enumerated()), id: \.offset) { _, w in
                            Text("\(w.section): \(w.message)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                }
            }
            .padding(8)
            .background(.orange.opacity(0.1))
        }
    }
}

// MARK: - FocusedValue bridge (Cmd+R menu -> DashboardModel.refresh)

private struct ActiveDashboardModelKey: FocusedValueKey {
    typealias Value = DashboardModel
}
extension FocusedValues {
    var activeDashboardModel: DashboardModel? {
        get { self[ActiveDashboardModelKey.self] }
        set { self[ActiveDashboardModelKey.self] = newValue }
    }
}
