import Foundation
import PDFKit
import AppKit

@MainActor
final class ConversionEngine: ObservableObject {
    @Published private(set) var phase: ConversionPhase = .idle
    @Published private(set) var progressFraction: Double = 0
    @Published private(set) var statusText: String = ""

    private var process: Process?
    private var runningTask: Task<Void, Never>?
    private let renderer = PDFRenderer()

    func start(pstURL: URL, destinationDirectory: URL, baseName: String, structure: OutputStructure) {
        guard !phase.isRunning else { return }
        phase = .extracting
        progressFraction = 0
        statusText = "Extracting PST contents…"

        runningTask = Task { [weak self] in
            await self?.run(pstURL: pstURL, destinationDirectory: destinationDirectory, baseName: baseName, structure: structure)
        }
    }

    func cancel() {
        guard phase.isRunning else { return }
        process?.terminate()
        runningTask?.cancel()
    }

    func reset() {
        guard !phase.isRunning else { return }
        phase = .idle
        progressFraction = 0
        statusText = ""
    }

    // MARK: - Orchestration

    private func run(pstURL: URL, destinationDirectory: URL, baseName: String, structure: OutputStructure) async {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("PSTConvert-\(UUID().uuidString)")
        let sanitizedBaseName = Self.sanitizeFilename(baseName)
        let outputRoot = Self.uniqueURL(destinationDirectory.appendingPathComponent(sanitizedBaseName))

        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: outputRoot, withIntermediateDirectories: true)

            try await extract(pstURL: pstURL, into: workDir)
            try Task.checkCancellation()

            let tree = try buildTree(at: workDir, pathComponents: [])
            let total = countEmails(tree)
            guard total > 0 else {
                throw ConversionError(message: "No email messages were found in this PST file.")
            }
            phase = .rendering(current: 0, total: total)

            var index = 0
            switch structure {
            case .combined:
                try await renderCombined(tree, outputRoot: outputRoot, baseName: sanitizedBaseName, total: total, index: &index)
            case .perFolder:
                try await renderPerFolder(tree, outputRoot: outputRoot, total: total, index: &index)
            case .perEmail:
                try await renderPerEmail(tree, outputRoot: outputRoot, total: total, index: &index)
            case .binder:
                try await renderBinder(tree, outputRoot: outputRoot, baseName: sanitizedBaseName, total: total, index: &index)
            }

            try Task.checkCancellation()
            phase = .finishing
            try? fm.removeItem(at: workDir)

            statusText = "Done — \(total) email\(total == 1 ? "" : "s") converted."
            phase = .done(outputURL: outputRoot)
            revealInFinder(outputRoot)
        } catch is CancellationError {
            try? fm.removeItem(at: workDir)
            try? fm.removeItem(at: outputRoot)
            statusText = "Cancelled."
            phase = .cancelled
        } catch {
            try? fm.removeItem(at: workDir)
            statusText = "Failed: \(error.localizedDescription)"
            phase = .failed(message: error.localizedDescription)
        }
        process = nil
    }

    // MARK: - readpst extraction

    private func extract(pstURL: URL, into dir: URL) async throws {
        guard let readpstURL = Bundle.main.resourceURL?.appendingPathComponent("bin/readpst"),
              FileManager.default.isExecutableFile(atPath: readpstURL.path) else {
            throw ConversionError(message: "Internal error: the bundled readpst tool could not be found.")
        }

        let proc = Process()
        proc.executableURL = readpstURL
        proc.arguments = ["-q", "-e", "-8", "-w", "-t", "e", "-o", dir.path, pstURL.path]
        let errPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = errPipe
        self.process = proc

        try proc.run()

        let stderrTask = Task.detached { () -> Data in
            errPipe.fileHandleForReading.readDataToEndOfFile()
        }

        await withTaskCancellationHandler {
            await Task.detached { proc.waitUntilExit() }.value
        } onCancel: {
            proc.terminate()
        }

        self.process = nil

        if proc.terminationReason == .uncaughtSignal {
            throw CancellationError()
        }
        if proc.terminationStatus != 0 {
            let errData = await stderrTask.value
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw ConversionError(message: msg.isEmpty ? "readpst failed reading this PST file (status \(proc.terminationStatus))." : msg)
        }
    }

    // MARK: - Folder tree

    private struct FolderNode {
        let name: String
        let pathComponents: [String]
        let emlFiles: [URL]
        let children: [FolderNode]
    }

    private func buildTree(at directory: URL, pathComponents: [String]) throws -> FolderNode {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var emlFiles: [URL] = []
        var children: [FolderNode] = []

        let sorted = contents.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in sorted {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                children.append(try buildTree(at: url, pathComponents: pathComponents + [url.lastPathComponent]))
            } else if url.pathExtension.lowercased() == "eml" {
                emlFiles.append(url)
            }
        }
        emlFiles.sort { (Int($0.deletingPathExtension().lastPathComponent) ?? 0) < (Int($1.deletingPathExtension().lastPathComponent) ?? 0) }

        return FolderNode(name: pathComponents.last ?? "PST", pathComponents: pathComponents, emlFiles: emlFiles, children: children)
    }

    private func countEmails(_ node: FolderNode) -> Int {
        node.emlFiles.count + node.children.reduce(0) { $0 + countEmails($1) }
    }

    // MARK: - Per-email rendering

    private func loadAndRenderPDF(emlURL: URL, scratchParentDir: URL) async throws -> (pdf: PDFDocument, attachments: [(name: String, data: Data)], subject: String) {
        let raw = try Data(contentsOf: emlURL)
        let message = MIMEMessage.parse(data: raw)

        let scratchDir = scratchParentDir.appendingPathComponent(".inline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        var cidMap: [String: String] = [:]
        var attachmentsOut: [(String, Data)] = []
        var counter = 0
        for part in message.attachments {
            counter += 1
            let filename = part.filename ?? "attachment\(counter)"
            if let cid = part.contentID {
                let safeName = Self.sanitizeFilename(filename)
                try? part.data.write(to: scratchDir.appendingPathComponent(safeName))
                cidMap[cid] = safeName
            }
            attachmentsOut.append((filename, part.data))
        }

        let html = EmailHTML.build(message: message, cidMap: cidMap)
        let pdfData = try await renderer.renderPDF(html: html, baseURL: scratchDir)
        guard let pdfDoc = PDFDocument(data: pdfData) else {
            throw ConversionError(message: "Could not build a PDF for \"\(message.subject)\".")
        }
        return (pdfDoc, attachmentsOut, message.subject)
    }

    private func reportProgress(index: Int, total: Int) {
        phase = .rendering(current: index, total: total)
        progressFraction = Double(index) / Double(total)
        statusText = "Converting email \(index) of \(total)…"
    }

    private func writePDF(_ doc: PDFDocument, to url: URL) throws {
        guard doc.write(to: url) else {
            throw ConversionError(message: "Failed to write PDF \"\(url.lastPathComponent)\".")
        }
    }

    // MARK: - Output structure: combined

    private func renderCombined(_ root: FolderNode, outputRoot: URL, baseName: String, total: Int, index: inout Int) async throws {
        let combinedDoc = PDFDocument()
        let attachmentsDir = outputRoot.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
        var attachmentIndex = 0

        func walk(_ node: FolderNode) async throws {
            for emlURL in node.emlFiles {
                try Task.checkCancellation()
                index += 1
                reportProgress(index: index, total: total)

                let (pdf, attachments, _) = try await loadAndRenderPDF(emlURL: emlURL, scratchParentDir: attachmentsDir)
                for p in 0..<pdf.pageCount {
                    if let page = pdf.page(at: p) { combinedDoc.insert(page, at: combinedDoc.pageCount) }
                }
                for (name, data) in attachments {
                    attachmentIndex += 1
                    let dest = Self.uniqueURL(attachmentsDir.appendingPathComponent("\(attachmentIndex)-\(Self.sanitizeFilename(name))"))
                    try? data.write(to: dest)
                }
            }
            for child in node.children {
                try await walk(child)
            }
        }
        try await walk(root)

        if let items = try? FileManager.default.contentsOfDirectory(atPath: attachmentsDir.path), items.isEmpty {
            try? FileManager.default.removeItem(at: attachmentsDir)
        }

        try writePDF(combinedDoc, to: outputRoot.appendingPathComponent("\(baseName).pdf"))
    }

    // MARK: - Output structure: binder (emails + attachments merged into one PDF)

    private func renderBinder(_ root: FolderNode, outputRoot: URL, baseName: String, total: Int, index: inout Int) async throws {
        let combinedDoc = PDFDocument()
        let attachmentsDir = outputRoot.appendingPathComponent("Attachments")
        var attachmentIndex = 0
        var extractedAnyFile = false

        func appendAttachment(_ name: String, _ data: Data) async throws {
            attachmentIndex += 1
            let kind = AttachmentInfoHTML.classify(filename: name, data: data)
            let sizeString = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            let infoHTML = AttachmentInfoHTML.build(filename: name, sizeString: sizeString, kind: kind)
            let infoPDFData = try await renderer.renderPDF(html: infoHTML, baseURL: nil)
            if let infoDoc = PDFDocument(data: infoPDFData) {
                for p in 0..<infoDoc.pageCount {
                    if let page = infoDoc.page(at: p) { combinedDoc.insert(page, at: combinedDoc.pageCount) }
                }
            }

            switch kind {
            case .image:
                if let image = NSImage(data: data), let page = PDFPage(image: image) {
                    combinedDoc.insert(page, at: combinedDoc.pageCount)
                }
            case .pdf:
                if let doc = PDFDocument(data: data) {
                    for p in 0..<doc.pageCount {
                        if let page = doc.page(at: p) { combinedDoc.insert(page, at: combinedDoc.pageCount) }
                    }
                }
            case .other:
                extractedAnyFile = true
                try FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
                let dest = Self.uniqueURL(attachmentsDir.appendingPathComponent("\(attachmentIndex)-\(Self.sanitizeFilename(name))"))
                try? data.write(to: dest)
            }
        }

        func walk(_ node: FolderNode) async throws {
            for emlURL in node.emlFiles {
                try Task.checkCancellation()
                index += 1
                reportProgress(index: index, total: total)

                let (pdf, attachments, _) = try await loadAndRenderPDF(emlURL: emlURL, scratchParentDir: outputRoot)
                for p in 0..<pdf.pageCount {
                    if let page = pdf.page(at: p) { combinedDoc.insert(page, at: combinedDoc.pageCount) }
                }
                for (name, data) in attachments {
                    try await appendAttachment(name, data)
                }
            }
            for child in node.children {
                try await walk(child)
            }
        }
        try await walk(root)

        if !extractedAnyFile {
            try? FileManager.default.removeItem(at: attachmentsDir)
        }

        try writePDF(combinedDoc, to: outputRoot.appendingPathComponent("\(baseName).pdf"))
    }

    // MARK: - Output structure: per-folder

    private func renderPerFolder(_ root: FolderNode, outputRoot: URL, total: Int, index: inout Int) async throws {
        func walk(_ node: FolderNode, parentDir: URL) async throws {
            let folderDir = node.pathComponents.isEmpty ? outputRoot : Self.uniqueURL(parentDir.appendingPathComponent(Self.sanitizeFilename(node.name)))
            if !node.pathComponents.isEmpty {
                try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
            }

            if !node.emlFiles.isEmpty {
                let doc = PDFDocument()
                let attachmentsDir = folderDir.appendingPathComponent("Attachments")
                var attachmentIndex = 0

                for emlURL in node.emlFiles {
                    try Task.checkCancellation()
                    index += 1
                    reportProgress(index: index, total: total)

                    let (pdf, attachments, _) = try await loadAndRenderPDF(emlURL: emlURL, scratchParentDir: folderDir)
                    for p in 0..<pdf.pageCount {
                        if let page = pdf.page(at: p) { doc.insert(page, at: doc.pageCount) }
                    }
                    if !attachments.isEmpty {
                        try? FileManager.default.createDirectory(at: attachmentsDir, withIntermediateDirectories: true)
                        for (name, data) in attachments {
                            attachmentIndex += 1
                            let dest = Self.uniqueURL(attachmentsDir.appendingPathComponent("\(attachmentIndex)-\(Self.sanitizeFilename(name))"))
                            try? data.write(to: dest)
                        }
                    }
                }
                let folderPDFName = node.pathComponents.isEmpty ? "PST" : Self.sanitizeFilename(node.name)
                try writePDF(doc, to: Self.uniqueURL(folderDir.appendingPathComponent("\(folderPDFName).pdf")))
            }

            for child in node.children {
                try await walk(child, parentDir: folderDir)
            }
        }
        try await walk(root, parentDir: outputRoot)
    }

    // MARK: - Output structure: per-email

    private func renderPerEmail(_ root: FolderNode, outputRoot: URL, total: Int, index: inout Int) async throws {
        func walk(_ node: FolderNode, parentDir: URL) async throws {
            let folderDir = node.pathComponents.isEmpty ? outputRoot : Self.uniqueURL(parentDir.appendingPathComponent(Self.sanitizeFilename(node.name)))
            if !node.pathComponents.isEmpty {
                try FileManager.default.createDirectory(at: folderDir, withIntermediateDirectories: true)
            }

            var emailCounter = 0
            for emlURL in node.emlFiles {
                try Task.checkCancellation()
                index += 1
                emailCounter += 1
                reportProgress(index: index, total: total)

                let (pdf, attachments, subject) = try await loadAndRenderPDF(emlURL: emlURL, scratchParentDir: folderDir)
                let subjectPart = Self.sanitizeFilename(subject.isEmpty ? "Untitled" : subject)
                let base = "\(String(format: "%03d", emailCounter)) - \(subjectPart)"

                if attachments.isEmpty {
                    try writePDF(pdf, to: Self.uniqueURL(folderDir.appendingPathComponent("\(base).pdf")))
                } else {
                    let emailDir = Self.uniqueURL(folderDir.appendingPathComponent(base))
                    try FileManager.default.createDirectory(at: emailDir, withIntermediateDirectories: true)
                    try writePDF(pdf, to: emailDir.appendingPathComponent("email.pdf"))
                    for (name, data) in attachments {
                        let dest = Self.uniqueURL(emailDir.appendingPathComponent(Self.sanitizeFilename(name)))
                        try? data.write(to: dest)
                    }
                }
            }

            for child in node.children {
                try await walk(child, parentDir: folderDir)
            }
        }
        try await walk(root, parentDir: outputRoot)
    }

    // MARK: - Helpers

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private static func sanitizeFilename(_ name: String) -> String {
        var result = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\u{0}")
        result = result.components(separatedBy: invalid).joined(separator: "-")
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { result = "Untitled" }
        if result.count > 120 { result = String(result.prefix(120)) }
        return result
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let candidate = ext.isEmpty ? dir.appendingPathComponent("\(base) \(n)") : dir.appendingPathComponent("\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
