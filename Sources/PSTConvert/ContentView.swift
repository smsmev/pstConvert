import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var engine = ConversionEngine()

    @State private var pstURL: URL?
    @State private var destinationDir: URL?
    @State private var outputName: String = ""
    @State private var structure: OutputStructure = .combined
    @State private var isDropTargeted = false
    @State private var dropError: String?

    private var canStart: Bool {
        pstURL != nil && destinationDir != nil
            && !outputName.trimmingCharacters(in: .whitespaces).isEmpty
            && !engine.phase.isRunning
    }

    var body: some View {
        VStack(spacing: 16) {
            dropZone
            if pstURL != nil {
                configSection
            }
            Spacer(minLength: 0)
            controlBar
        }
        .padding(20)
        .animation(.default, value: pstURL)
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: pstURL == nil ? "tray.and.arrow.down" : "doc.badge.checkmark")
                .font(.system(size: 34))
                .foregroundStyle(pstURL == nil ? Color.secondary : Color.green)
            if let pstURL {
                Text(pstURL.lastPathComponent)
                    .font(.headline)
                Text(fileSizeString(pstURL))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose a Different File…") { chooseFile() }
                    .buttonStyle(.link)
            } else {
                Text("Drag & Drop a .pst File Here")
                    .font(.headline)
                Text("or")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose File…") { chooseFile() }
            }
            if let dropError {
                Text(dropError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
        )
        .background((isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 12)))
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .disabled(engine.phase.isRunning)
    }

    // MARK: - Config section

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Save To").font(.subheadline).bold()
                HStack {
                    Text(destinationDir?.path ?? "No location selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(destinationDir == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { chooseDestination() }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Output Name").font(.subheadline).bold()
                TextField("e.g. Archived Mail", text: $outputName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Output Structure").font(.subheadline).bold()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(OutputStructure.allCases) { option in
                        Button {
                            structure = option
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: structure == option ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(structure == option ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(option.title).font(.body)
                                    Text(option.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .disabled(engine.phase.isRunning)
    }

    // MARK: - Control bar

    private var controlBar: some View {
        Group {
            switch engine.phase {
            case .idle, .done, .cancelled, .failed:
                VStack(alignment: .leading, spacing: 6) {
                    if !engine.statusText.isEmpty {
                        Text(engine.statusText)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                    }
                    HStack {
                        if case .done(let url) = engine.phase {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            Spacer()
                        }
                        Button("Reset") { resetFile() }
                            .foregroundStyle(Color.pink)
                            .disabled(pstURL == nil)
                        Button("Start") { start() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canStart)
                    }
                }
            case .extracting, .rendering, .finishing:
                VStack(spacing: 6) {
                    if case .rendering(let current, let total) = engine.phase, total > 0 {
                        ProgressView(value: Double(current), total: Double(total))
                    } else {
                        ProgressView()
                    }
                    HStack {
                        Text(engine.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            engine.cancel()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle.fill")
                        }
                    }
                }
            }
        }
    }

    private var statusColor: Color {
        if case .failed = engine.phase { return .red }
        return .secondary
    }

    // MARK: - Actions

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "pst") ?? .data]
        panel.message = "Choose a .pst file to convert"
        if panel.runModal() == .OK, let url = panel.url {
            adopt(pstURL: url)
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save the converted PDF output"
        panel.prompt = "Select"
        if let destinationDir { panel.directoryURL = destinationDir }
        if panel.runModal() == .OK, let url = panel.url {
            destinationDir = url
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
            DispatchQueue.main.async {
                guard url.pathExtension.lowercased() == "pst" else {
                    dropError = "\"\(url.lastPathComponent)\" isn't a .pst file."
                    return
                }
                adopt(pstURL: url)
            }
        }
        return true
    }

    private func adopt(pstURL url: URL) {
        dropError = nil
        pstURL = url
        engine.reset()
        if outputName.isEmpty {
            outputName = url.deletingPathExtension().lastPathComponent
        }
        if destinationDir == nil {
            destinationDir = url.deletingLastPathComponent()
        }
    }

    private func resetFile() {
        pstURL = nil
        outputName = ""
        destinationDir = nil
        dropError = nil
        engine.reset()
    }

    private func start() {
        guard let pstURL, let destinationDir else { return }
        dropError = nil
        engine.start(pstURL: pstURL, destinationDirectory: destinationDir, baseName: outputName, structure: structure)
    }

    private func fileSizeString(_ url: URL) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
