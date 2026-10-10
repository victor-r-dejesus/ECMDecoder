import SwiftUI
import AppKit
import ECMCore
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

            Button("Choose File…") { chooseFile() }
                .disabled(isDecoding)

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
            let droppedURL: URL?
            if let data = item as? Data {
                droppedURL = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                droppedURL = item as? URL
            }
            guard let url = droppedURL else { return }
            guard url.pathExtension.lowercased() == "ecm" else {
                logLine("Not an .ecm file: \(url.lastPathComponent)")
                return
            }
            DispatchQueue.main.async {
                guard !self.isDecoding else { return }
                self.inputFile = url
                self.log = "Loaded: \(url.lastPathComponent)\n"
            }
        }
        return true
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ecmType = UTType(filenameExtension: "ecm") {
            panel.allowedContentTypes = [ecmType]
        }
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        inputFile = url
        log = "Loaded: \(url.lastPathComponent)\n"
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
        let flag = CancelFlag()
        cancelFlag = flag
        progress = 0
        eta = "--:--"
        logLine("Starting decode...")

        let wantsCue = generateCue

        DispatchQueue.global(qos: .userInitiated).async {
            let startTime = Date()
            let baseName = cleanBaseName(from: input)
            let binURL = outputDir.appendingPathComponent(baseName).appendingPathExtension("bin")

            do {
                try decoder.decode(
                    inputURL: input,
                    outputURL: binURL,
                    progressHandler: { prog in
                        guard prog.totalBytes > 0 else { return }
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
                    cancelCheck: { flag.isSet }
                )

                if wantsCue {
                    createCue(for: binURL, in: outputDir, baseName: baseName)
                }

                DispatchQueue.main.async {
                    // Ensure 100% at completion
                    progress = 1.0
                    eta = "00:00"
                    logLine("Decoding completed: \(binURL.lastPathComponent)")
                    resetUI()
                }
            } catch {
                DispatchQueue.main.async {
                    if let ecmError = error as? ECMError, ecmError == .canceled {
                        logLine("Decoding canceled.")
                    } else {
                        logLine("Decoding failed: \(error.localizedDescription)")
                    }
                    progress = 0
                    eta = "--:--"
                    isDecoding = false
                }
            }
        }
    }

    private func cancelDecoding() {
        cancelFlag.set()
        logLine("Cancel requested...")
    }

    private func resetUI() {
        isDecoding = false
        inputFile = nil
    }

    // MARK: - Cue Generation
    /// Writes a single-track cue sheet for the decoded .bin only.
    /// Runs off the main thread (reads the output file); logs via logLine.
    private func createCue(for binURL: URL, in directory: URL, baseName: String) {
        do {
            let handle = try FileHandle(forReadingFrom: binURL)
            defer { try? handle.close() }

            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            let head = [UInt8](try handle.read(upToCount: 16) ?? Data())
            let syncPattern: [UInt8] = [0x00] + [UInt8](repeating: 0xFF, count: 10) + [0x00]

            let trackMode: String
            if size > 0, size % 2352 == 0, head.count == 16, Array(head[0..<12]) == syncPattern {
                // Raw 2352-byte sectors: the mode byte follows the sync and address
                switch head[0x0F] {
                case 1: trackMode = "MODE1/2352"
                case 2: trackMode = "MODE2/2352"
                default:
                    logLine("CUE skipped: unrecognized sector mode")
                    return
                }
            } else if size > 0, size % 2336 == 0, head.count == 16, Array(head[0..<4]) == Array(head[4..<8]) {
                // Headerless mode 2 sectors (ECM types 2/3 without raw sync/header bytes)
                trackMode = "MODE2/2336"
            } else {
                logLine("CUE skipped: output is not a raw 2352- or 2336-byte sector image")
                return
            }

            let cueText = generateCueSheet(binName: binURL.lastPathComponent, trackMode: trackMode)
            let cueURL = directory.appendingPathComponent(baseName).appendingPathExtension("cue")
            try cueText.write(to: cueURL, atomically: true, encoding: .utf8)
            logLine("CUE created: \(cueURL.lastPathComponent) (\(trackMode))")
        } catch {
            logLine("CUE skipped: \(error.localizedDescription)")
        }
    }

    private func generateCueSheet(binName: String, trackMode: String) -> String {
        // Cue sheets have no escape for quotes, so replace them
        let safeName = binName.replacingOccurrences(of: "\"", with: "'")
        var lines: [String] = []
        lines.append("FILE \"\(safeName)\" BINARY")
        lines.append("  TRACK 01 \(trackMode)")
        lines.append("    INDEX 01 00:00:00")
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

// MARK: - Cancellation
/// Thread-safe cancellation flag shared between the UI and the decoding thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
