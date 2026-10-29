import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var inputFile: URL?
    @State private var log: String = ""
    @State private var isDecoding = false
    @State private var generateCue = true
    @State private var cancelFlag = CancelFlag()
    @State private var progress: Double = 0
    @State private var eta: String = "--:--"

    let decoder = ECMDecoder()

    var body: some View {
        VStack(spacing: 16) {

            // Drag & Drop Box
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundColor(.accentColor)

                Text(inputFile?.lastPathComponent ?? "Drag .ecm file here")
                    .foregroundColor(.secondary)
                    .padding()
            }
            .frame(height: 120)
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers)
            }

            Toggle("Generate .cue file", isOn: $generateCue)

            // Buttons
            HStack {
                Button("Decode") { startDecode() }
                    .disabled(inputFile == nil || isDecoding)

                Button("Cancel") { cancelDecoding() }
                    .disabled(!isDecoding)
                
                Button("Clear") { clearInput() }
                    .disabled(isDecoding || inputFile == nil)
            }

            // Progress Bar + ETA
            VStack(alignment: .leading) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .padding(.vertical, 4)
                Text("Progress: \(Int(progress * 100))%   ETA: \(eta)")
                    .font(.system(size: 13))
            }

            ScrollView {
                Text(log)
                    .font(.system(size: 13)) // Match app font
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(maxHeight: 250)
        }
        .padding()
        .frame(width: 540)
    }

    // MARK: - Drag Handling
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !isDecoding, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            var fileURL: URL?
            if let data = item as? Data {
                fileURL = URL(dataRepresentation: data, relativeTo: nil)
            } else if let url = item as? URL {
                fileURL = url
            }
            DispatchQueue.main.async {
                guard let url = fileURL, url.pathExtension.lowercased() == "ecm" else {
                    self.logLine("Ignored: please drop a .ecm file.")
                    return
                }
                guard !self.isDecoding else { return }
                self.inputFile = url
                self.log = "Loaded: \(url.lastPathComponent)\n"
            }
        }
        return true
    }

    private func clearInput() {
        inputFile = nil
        logLine("Input file cleared.")
    }

    // MARK: - Decode
    private func startDecode() {
        guard let input = inputFile else { return }

        // Ask user for output folder (sandbox-safe)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Output Folder"

        guard panel.runModal() == .OK, let outputDir = panel.url else { return }

        isDecoding = true
        cancelFlag.set(false)
        progress = 0
        eta = "--:--"
        logLine("Starting decode...")

        let flag = cancelFlag
        let wantCue = generateCue
        let decoder = self.decoder
        // Computed on the main thread so the background work touches no View state
        let baseName = Self.cleanBaseName(from: input)
        let binURL = outputDir.appendingPathComponent(baseName).appendingPathExtension("bin")
        let startTime = Date()
        let appendLog: @Sendable (String) -> Void = { text in
            DispatchQueue.main.async { self.log += text + "\n" }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            // Balanced access for sandboxed / security-scoped URLs (returns false if not scoped)
            let inputAccess = input.startAccessingSecurityScopedResource()
            let outputAccess = outputDir.startAccessingSecurityScopedResource()
            defer {
                if inputAccess { input.stopAccessingSecurityScopedResource() }
                if outputAccess { outputDir.stopAccessingSecurityScopedResource() }
            }

            do {
                try decoder.decode(
                    inputURL: input,
                    outputURL: binURL,
                    progressHandler: { prog in
                        DispatchQueue.main.async {
                            // Clamp progress to 1.0 max
                            let value = min(Double(prog.bytesProcessed) / Double(max(prog.totalBytes, 1)), 1.0)
                            self.progress = value

                            // ETA calculation
                            let elapsed = Date().timeIntervalSince(startTime)
                            let totalEstimated = elapsed / max(value, 0.0001)
                            let remaining = totalEstimated - elapsed
                            self.eta = Self.formatTime(remaining)
                        }
                    },
                    cancelCheck: { flag.isSet }
                )

                appendLog("✅ Decoding completed: \(binURL.lastPathComponent)")
                if wantCue {
                    Self.createCue(in: outputDir, baseName: baseName, binURL: binURL, log: appendLog)
                }

                DispatchQueue.main.async {
                    // Ensure 100% at completion
                    self.progress = 1.0
                    self.eta = "00:00"
                    self.resetUI()
                }
            } catch {
                let nsError = error as NSError
                let canceled = nsError.domain == ECMDecoder.errorDomain && nsError.code == ECMDecoder.canceledCode
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    if canceled {
                        self.logLine("⚠️ Decoding canceled; partial output removed.")
                    } else {
                        self.logLine("❌ Decoding failed: \(message)")
                    }
                    self.isDecoding = false
                }
            }
        }
    }

    private func cancelDecoding() {
        cancelFlag.set(true)
        logLine("Cancel requested...")
    }

    private func resetUI() {
        isDecoding = false
        inputFile = nil
    }

    // MARK: - Cue Generation
    nonisolated private static func createCue(in directory: URL, baseName: String, binURL: URL, log: @escaping @Sendable (String) -> Void) {
        let binName = binURL.lastPathComponent
        guard !binName.contains("\"") else {
            log("CUE skipped: file name contains a quote character")
            return
        }
        do {
            guard let trackType = try detectTrackType(of: binURL) else {
                log("CUE skipped: output is not a raw 2352-byte/sector MODE1 or MODE2 image")
                return
            }
            let cueText = generateCueSheet(binName: binName, trackType: trackType)
            let cueURL = directory.appendingPathComponent(baseName).appendingPathExtension("cue")
            try cueText.write(to: cueURL, atomically: true, encoding: .utf8)
            log("CUE created: \(cueURL.lastPathComponent) (\(trackType))")
        } catch {
            log("CUE skipped: \(error.localizedDescription)")
        }
    }

    /// Returns MODE1/2352 or MODE2/2352 only when the file is a whole number of 2352-byte sectors
    /// whose first sector has the sync pattern and mode byte 1 or 2; otherwise nil.
    nonisolated private static func detectTrackType(of binURL: URL) throws -> String? {
        let attrs = try FileManager.default.attributesOfItem(atPath: binURL.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size % 2352 == 0 else { return nil }
        let handle = try FileHandle(forReadingFrom: binURL)
        defer { try? handle.close() }
        let header = [UInt8](try handle.read(upToCount: 16) ?? Data())
        let sync: [UInt8] = [0x00] + [UInt8](repeating: 0xFF, count: 10) + [0x00]
        guard header.count == 16, Array(header[0..<12]) == sync else { return nil }
        switch header[15] {
        case 1: return "MODE1/2352"
        case 2: return "MODE2/2352"
        default: return nil
        }
    }

    nonisolated private static func generateCueSheet(binName: String, trackType: String) -> String {
        let lines = [
            "FILE \"\(binName)\" BINARY",
            "  TRACK 01 \(trackType)",
            "    INDEX 01 00:00:00"
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func cleanBaseName(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".bin") {
            name = String(name.dropLast(4))
        }
        return name.isEmpty ? "output" : name
    }

    private func logLine(_ text: String) {
        DispatchQueue.main.async {
            self.log += text + "\n"
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "--:--" }
        let sec = Int(seconds)
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }
}

// MARK: - Cancellation flag (read from the decoding thread, written from the UI)
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }
}
