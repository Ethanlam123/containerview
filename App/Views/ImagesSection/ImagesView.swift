// Images section: pull field + filter + a grid of image cards; clicking a card
// opens a native sheet with the inspect JSON.

import SwiftUI

struct ImagesView: View {
    let model: DashboardModel
    @State private var filter = ""
    @State private var pullRef = ""
    @State private var pulling = false
    @State private var pullError: String?
    @State private var inspecting: ImageList?

    private var images: [ImageList] {
        (model.lastState?.images ?? []).filter {
            filter.isEmpty || $0.configuration.name.localizedCaseInsensitiveContains(filter)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Image reference (alpine:latest)", text: $pullRef)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(performPull)
                Button("Pull") { performPull() }.disabled(pulling || pullRef.trimmingCharacters(in: .whitespaces).isEmpty)
                if pulling { ProgressView().controlSize(.small) }
                if let pullError { Text(pullError).foregroundStyle(.red).font(.caption).lineLimit(1) }
            }
            .padding(8)

            HStack {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).controlSize(.small)
                Spacer()
                Text("\(images.count) image\(images.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.bottom, 6)

            Divider()
            if images.isEmpty {
                ContentUnavailableView("No images", systemImage: "square.stack.3d.up",
                    description: Text("Pull an image above."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                        ForEach(images) { img in
                            ImageCard(image: img) { inspecting = img }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .sheet(item: $inspecting) { img in
            ImageInspectSheet(name: img.configuration.name, client: model.client)
        }
    }

    private func performPull() {
        let ref = pullRef.trimmingCharacters(in: .whitespaces)
        guard !ref.isEmpty else { return }
        pulling = true
        pullError = nil
        Task {
            let err = await model.pullImage(ref)
            pulling = false
            if let err { pullError = err }
            else { pullRef = "" }
        }
    }
}

private struct ImageCard: View {
    let image: ImageList
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(image.configuration.name)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                HStack {
                    Text(shortHash(image.configuration.descriptor.digest))
                    Spacer()
                    Text(formatBytes(image.configuration.descriptor.size))
                }
                .font(.caption).foregroundStyle(.secondary)
                if let v = image.variants.first {
                    Text("\(v.platform.architecture) / \(v.platform.os)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct ImageInspectSheet: View {
    let name: String
    let client: ServerClient?
    @State private var json = "loading…"
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(10)
            Divider()
            ScrollView {
                Text(json)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .frame(minWidth: 520, minHeight: 380)
        .task {
            guard let client else { json = "unavailable"; return }
            do {
                let inspected = try await client.inspectImage(name)
                let data = (try? JSONEncoder().encode(inspected)) ?? Data()
                json = prettyJSON(data)
            } catch {
                json = "failed: \(error.localizedDescription)"
            }
        }
    }
}
