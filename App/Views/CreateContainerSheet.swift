// Create + start a container. Native sheet over a Form. The run body's
// ports/env/volumes/memory fields encode as bare JSON strings (single-value
// Codable via RawRepresentable<String>) to match the server's
// PortSpec/EnvSpec/VolumeSpec/MemorySpec decoding - a naive struct would 400.
// The server is the validation authority; client checks here are UX hints only.
// Form values persist to UserDefaults (matches app.js's createForm cache).

import SwiftUI

struct CreateContainerSheet: View {
    let model: DashboardModel
    @Environment(\.dismiss) private var dismiss

    @State private var image = ""
    @State private var name = ""
    @State private var ports: [RepeatItem] = [RepeatItem()]
    @State private var env: [RepeatItem] = [RepeatItem()]
    @State private var volumes: [RepeatItem] = [RepeatItem()]
    @State private var cpus = ""
    @State private var memory = ""
    @State private var args = ""
    @State private var rm = false
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New container").font(.headline)
                Spacer()
                Button("Cancel") { save(); dismiss() }
                Button("Create & start") { submit() }
                    .disabled(submitting || image.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
            Divider()
            Form {
                Section("Image") {
                    TextField("alpine:latest", text: $image)
                    TextField("Name (optional)", text: $name)
                }
                Section("Ports") { RepeatGroup(items: $ports, placeholder: "8080:80") }
                Section("Environment") { RepeatGroup(items: $env, placeholder: "KEY=value") }
                Section("Volumes") { RepeatGroup(items: $volumes, placeholder: "/host:/container") }
                Section("Resources") {
                    TextField("CPUs", text: $cpus)
                    TextField("Memory", text: $memory, prompt: Text("512M"))
                }
                Section("Command") {
                    // ponytail: no shell-quote parsing in v1; lands as init argv.
                    TextField("args (space-separated)", text: $args)
                    Toggle("Remove on stop (--rm)", isOn: $rm)
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.caption) }
                }
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 500, minHeight: 480)
        .onAppear { restore() }
    }

    private func submit() {
        submitting = true
        error = nil
        let body = buildBody()
        Task {
            do {
                _ = try await model.client?.createContainer(body)
                save(body)
                model.refresh()
                dismiss()
            } catch {
                submitting = false
                self.error = (error as? APIError)?.reason ?? error.localizedDescription
            }
        }
    }

    private func buildBody() -> ContainerRunRequest {
        let clean = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        let specs = { (items: [RepeatItem]) in
            items.compactMap { clean($0.value) }.filter { !$0.isEmpty }
                 .map { ContainerRunRequest.Spec(rawValue: $0) }
        }
        let mem = clean(memory)
        return ContainerRunRequest(
            image: clean(image),
            name: clean(name).isEmpty ? nil : clean(name),
            ports: specs(ports),
            env: specs(env),
            volumes: specs(volumes),
            cpus: Int(clean(cpus)),
            memory: mem.isEmpty ? nil : ContainerRunRequest.Spec(rawValue: mem),
            args: clean(args).split(separator: " ").map(String.init),
            rm: rm ? true : nil
        )
    }

    // MARK: Persistence

    private static let key = "containerDashboard:createForm"

    private struct Snapshot: Codable {
        var image: String; var name: String
        var ports: [String]; var env: [String]; var volumes: [String]
        var cpus: String; var memory: String; var args: String; var rm: Bool
    }

    private func save(_ body: ContainerRunRequest? = nil) {
        let snap = Snapshot(
            image: image, name: name,
            ports: ports.map(\.value), env: env.map(\.value), volumes: volumes.map(\.value),
            cpus: cpus, memory: memory, args: args, rm: rm)
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        image = snap.image; name = snap.name
        ports = snap.ports.isEmpty ? [RepeatItem()] : snap.ports.map(RepeatItem.init)
        env = snap.env.isEmpty ? [RepeatItem()] : snap.env.map(RepeatItem.init)
        volumes = snap.volumes.isEmpty ? [RepeatItem()] : snap.volumes.map(RepeatItem.init)
        cpus = snap.cpus; memory = snap.memory; args = snap.args; rm = snap.rm
    }
}

struct RepeatItem: Identifiable {
    let id = UUID()
    var value: String
    init(_ value: String = "") { self.value = value }
}

private struct RepeatGroup: View {
    @Binding var items: [RepeatItem]
    let placeholder: String

    var body: some View {
        ForEach($items) { $item in
            HStack {
                TextField(placeholder, text: $item.value).textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    items.removeAll { $0.id == item.id }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        Button {
            items.append(RepeatItem())
        } label: {
            Label("Add", systemImage: "plus.circle")
        }
    }
}
