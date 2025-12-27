import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var inputFile: URL?
    @State private var log: String = ""
    @State private var isDecoding = false
    @State private var generateCue = true
    @State private var cancelRequested = false
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
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil),
                  url.pathExtension.lowercased() == "ecm"
            else { return }
            DispatchQueue.main.async {
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
        cancelRequested = false
        progress = 0
        eta = "--:--"
        logLine("Starting decode...")

        DispatchQueue.global(qos: .userInitiated).async {
            let startTime = Date()
            let baseName = cleanBaseName(from: input)
            let binURL = outputDir.appendingPathComponent(baseName).appendingPathExtension("bin")

            do {
                try decoder.decode(
                    inputURL: input,
                    outputURL: binURL,
                    progressHandler: { prog in
                        DispatchQueue.main.async {
                            // Clamp progress to 1.0 max
                            let value = min(Double(prog.bytesProcessed) / Double(prog.totalBytes), 1.0)
                            progress = value

                            // ETA calculation
                            let elapsed = Date().timeIntervalSince(startTime)
                            let totalEstimated = elapsed / max(value, 0.0001)
                            let remaining = totalEstimated - elapsed
                            eta = formatTime(remaining)
                        }
                    },
                    cancelCheck: { self.cancelRequested }
                )

                DispatchQueue.main.async {
                    // Ensure 100% at completion
                    progress = 1.0
                    eta = "00:00"
                    logLine("✅ Decoding completed: \(binURL.lastPathComponent)")

                    if generateCue {
                        createCue(in: outputDir, baseName: baseName)
                    }

                    resetUI()
                }
            } catch {
                DispatchQueue.main.async {
                    logLine("❌ Decoding failed: \(error.localizedDescription)")
                    isDecoding = false
                }
            }
        }
    }

    private func cancelDecoding() {
        cancelRequested = true
        logLine("Cancel requested...")
    }

    private func resetUI() {
        isDecoding = false
        inputFile = nil
    }

    // MARK: - Cue Generation
    private func createCue(in directory: URL, baseName: String) {
        do {
            let binFiles = try validatedBinFiles(in: directory)
            let cueText = generateCueSheet(from: binFiles)
            let cueURL = directory.appendingPathComponent(baseName).appendingPathExtension("cue")
            try cueText.write(to: cueURL, atomically: true, encoding: .utf8)
            logLine("CUE created: \(cueURL.lastPathComponent)")
        } catch {
            logLine("CUE skipped: \(error.localizedDescription)")
        }
    }

    private func validatedBinFiles(in directory: URL) throws -> [String] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let bins = files.filter { $0.pathExtension.lowercased() == "bin" }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                        .map { $0.lastPathComponent }
        guard !bins.isEmpty else { throw CueError.noBinFiles }
        logLine("Found \(bins.count) .bin file(s)")
        return bins
    }

    private func generateCueSheet(from files: [String]) -> String {
        var lines: [String] = []
        lines.append("FILE \"\(files[0])\" BINARY")
        lines.append("  TRACK 01 MODE2/2352")
        lines.append("    INDEX 01 00:00:00")
        for (index, file) in files.dropFirst().enumerated() {
            let track = index + 2
            lines.append("FILE \"\(file)\" BINARY")
            lines.append("  TRACK \(String(format: "%02d", track)) AUDIO")
            lines.append("   INDEX 00 00:00:00")
            lines.append("   INDEX 01 00:02:00")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func cleanBaseName(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.lowercased().hasSuffix(".bin") {
            name = String(name.dropLast(4))
        }
        return name
    }

    private func logLine(_ text: String) {
        DispatchQueue.main.async {
            self.log += text + "\n"
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "--:--" }
        let sec = Int(seconds)
        return String(format: "%02d:%02d", sec / 60, sec % 60)
    }
}

// MARK: - Errors
enum CueError: LocalizedError {
    case noBinFiles
    var errorDescription: String? {
        switch self {
        case .noBinFiles: return "No .bin files found in output directory"
        }
    }
}
