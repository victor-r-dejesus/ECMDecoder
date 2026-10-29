import Foundation

// MARK: - Data types
typealias ECCUInt8 = UInt8
typealias ECCUInt16 = UInt16
typealias ECCUInt32 = UInt32

// MARK: - ECC/EDC Tables
struct ECCEDC: @unchecked Sendable {
    var eccFLUT = [ECCUInt8](repeating: 0, count: 256)
    var eccBLUT = [ECCUInt8](repeating: 0, count: 256)
    var edcLUT = [ECCUInt32](repeating: 0, count: 256)

    init() {
        for i in 0..<256 {
            let j = ECCUInt8((i << 1) ^ (i & 0x80 != 0 ? 0x11D : 0))
            eccFLUT[i] = j
            eccBLUT[Int(i ^ Int(j))] = ECCUInt8(i)
            
            var edc = ECCUInt32(i)
            for _ in 0..<8 { edc = (edc >> 1) ^ (edc & 1 != 0 ? 0xD8018001 : 0) }
            edcLUT[i] = edc
        }
    }

    func edcPartialComputeBlock(edc: ECCUInt32, src: UnsafePointer<ECCUInt8>, size: ECCUInt16) -> ECCUInt32 {
        var edc = edc
        for i in 0..<Int(size) {
            edc = (edc >> 8) ^ edcLUT[Int((edc ^ ECCUInt32(src[i])) & 0xFF)]
        }
        return edc
    }

    func edcComputeBlock(src: UnsafePointer<ECCUInt8>, size: ECCUInt16, dest: UnsafeMutablePointer<ECCUInt8>) {
        let edc = edcPartialComputeBlock(edc: 0, src: src, size: size)
        dest[0] = ECCUInt8((edc >> 0) & 0xFF)
        dest[1] = ECCUInt8((edc >> 8) & 0xFF)
        dest[2] = ECCUInt8((edc >> 16) & 0xFF)
        dest[3] = ECCUInt8((edc >> 24) & 0xFF)
    }

    private func eccComputeBlock(src: UnsafePointer<ECCUInt8>,
                                 majorCount: Int,
                                 minorCount: Int,
                                 majorMult: Int,
                                 minorInc: Int,
                                 dest: UnsafeMutablePointer<ECCUInt8>) {
        let size = majorCount * minorCount
        for major in 0..<majorCount {
            var index = (major >> 1) * majorMult + (major & 1)
            var eccA: ECCUInt8 = 0
            var eccB: ECCUInt8 = 0
            for _ in 0..<minorCount {
                let temp = src[index]
                index += minorInc
                if index >= size { index -= size }
                eccA ^= temp
                eccB ^= temp
                eccA = eccFLUT[Int(eccA)]
            }
            let tempA = eccFLUT[Int(eccA)]
            eccA = eccBLUT[Int(tempA ^ eccB)]
            dest[major] = eccA
            dest[major + majorCount] = eccA ^ eccB
        }
    }

    /// Generates the P and Q parity bytes in place. The P parity (written at 0x81C) is part of the
    /// input of the Q pass, exactly as in the reference implementation, so both passes must run on
    /// the same buffer.
    private func eccGenerate(sector: UnsafeMutablePointer<ECCUInt8>, zeroAddress: Bool) {
        // Optionally zero out the address bytes (header incl. mode byte), restoring them afterwards
        let a0 = sector[12], a1 = sector[13], a2 = sector[14], a3 = sector[15]
        if zeroAddress {
            sector[12] = 0; sector[13] = 0; sector[14] = 0; sector[15] = 0
        }

        eccComputeBlock(src: sector + 12, majorCount: 86, minorCount: 24, majorMult: 2, minorInc: 86,
                        dest: sector + 0x81C)
        eccComputeBlock(src: sector + 12, majorCount: 52, minorCount: 43, majorMult: 86, minorInc: 88,
                        dest: sector + 0x8C8)

        if zeroAddress {
            sector[12] = a0; sector[13] = a1; sector[14] = a2; sector[15] = a3
        }
    }

    /// `sector` must point to a 2352-byte buffer.
    func eccedcGenerate(sector: UnsafeMutablePointer<ECCUInt8>, type: Int) {
        switch type {
        case 1:
            edcComputeBlock(src: sector, size: 0x810, dest: sector + 0x810)
            for i in 0..<8 { sector[0x814 + i] = 0 }
            eccGenerate(sector: sector, zeroAddress: false)

        case 2:
            edcComputeBlock(src: sector + 0x10, size: 0x808, dest: sector + 0x818)
            eccGenerate(sector: sector, zeroAddress: true)

        case 3:
            edcComputeBlock(src: sector + 0x10, size: 0x91C, dest: sector + 0x92C)

        default:
            break
        }
    }
}

// MARK: - ECM Decoder
final class ECMDecoder: @unchecked Sendable {
    private let eccedc = ECCEDC()

    struct Progress {
        var bytesProcessed: Int
        var totalBytes: Int
    }

    static let errorDomain = "ECM"
    static let canceledCode = 99

    private static func makeError(_ code: Int, _ message: String) -> NSError {
        NSError(domain: errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Decodes `inputURL` into `outputURL`, streaming the output to a hidden temp file next to it
    /// that replaces `outputURL` only on success (an existing `outputURL` is untouched on failure
    /// or cancellation). The trailing EDC of the ECM stream is verified. `progressHandler` is throttled
    /// (about 10 calls per second) and is called from the calling thread.
    func decode(inputURL: URL,
                outputURL: URL,
                progressHandler: @escaping (Progress) -> Void,
                cancelCheck: @escaping () -> Bool) throws {

        // Memory-mapped so large images are not copied into RAM (a file shrinking or its volume
        // disappearing mid-decode can cause SIGBUS).
        let data = try Data(contentsOf: inputURL, options: .alwaysMapped)
        let total = data.count

        guard total > 4 else {
            throw Self.makeError(1, "File too short")
        }

        guard data[0] == 0x45, data[1] == 0x43, data[2] == 0x4D, data[3] == 0 else {
            throw Self.makeError(2, "Header not found (not an ECM file)")
        }

        let truncated = { Self.makeError(3, "ECM file is truncated or corrupt") }

        let fm = FileManager.default
        let partialURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".ecmdecoder-\(UUID().uuidString).partial")
        guard fm.createFile(atPath: partialURL.path, contents: nil) else {
            throw Self.makeError(4, "Cannot create output file in \(outputURL.deletingLastPathComponent().path)")
        }
        var finished = false
        var closed = false
        var handleOpt: FileHandle?
        defer {
            if !finished {
                if !closed { try? handleOpt?.close() }
                try? fm.removeItem(at: partialURL)
            }
        }
        let handle = try FileHandle(forWritingTo: partialURL)
        handleOpt = handle

        let flushThreshold = 1 << 20
        var out = [UInt8]()
        out.reserveCapacity(flushThreshold + 4096)
        func flush() throws {
            if !out.isEmpty {
                try handle.write(contentsOf: out)
                out.removeAll(keepingCapacity: true)
            }
        }

        var lastReport = ProcessInfo.processInfo.systemUptime
        func tick(_ position: Int) throws {
            if cancelCheck() {
                throw Self.makeError(Self.canceledCode, "Canceled")
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastReport >= 0.1 {
                lastReport = now
                progressHandler(.init(bytesProcessed: position, totalBytes: total))
            }
        }

        let sector = UnsafeMutablePointer<ECCUInt8>.allocate(capacity: 2352)
        sector.initialize(repeating: 0, count: 2352)
        defer { sector.deallocate() }

        // Running EDC over every output byte, checked against the trailing EDC in the ECM stream
        var runningEDC: ECCUInt32 = 0
        func updateEDC(_ p: UnsafePointer<UInt8>, _ n: Int) {
            var done = 0
            while done < n {
                let step = min(n - done, 0xFFFF)
                runningEDC = eccedc.edcPartialComputeBlock(edc: runningEDC, src: p + done, size: ECCUInt16(step))
                done += step
            }
        }

        var offset = 4
        var sawEnd = false

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!

            func load(_ destination: Int, _ count: Int) {
                UnsafeMutableRawPointer(sector + destination).copyMemory(from: base + offset, byteCount: count)
                offset += count
            }

            while offset < total {
                try tick(offset)

                var c = base[offset]; offset += 1
                let type = Int(c & 3)
                var num = Int((c >> 2) & 0x1F)
                var bits = 5
                while c & 0x80 != 0 {
                    // A valid count needs at most 4 continuation bytes (32 bits)
                    guard offset < total, bits < 33 else { throw truncated() }
                    c = base[offset]; offset += 1
                    num |= Int(c & 0x7F) << bits
                    bits += 7
                }
                // Compare on the 32-bit value before the +1, like the reference unecm
                let num32 = UInt32(truncatingIfNeeded: num)
                if num32 == 0xFFFFFFFF {
                    guard total - offset >= 4 else { throw truncated() }
                    var stored: UInt32 = 0
                    for k in 0..<4 { stored |= UInt32(base[offset + k]) << UInt32(8 * k) }
                    offset += 4
                    guard stored == runningEDC else {
                        throw Self.makeError(5, "EDC error: decoded data does not match the checksum (file is corrupt)")
                    }
                    sawEnd = true
                    break
                }
                let count = Int(num32) + 1

                if type == 0 {
                    guard count <= total - offset else { throw truncated() }
                    var remaining = count
                    while remaining > 0 {
                        let n = min(remaining, 0xFFFF)
                        updateEDC(base + offset, n)
                        out.append(contentsOf: UnsafeBufferPointer(start: base + offset, count: n))
                        offset += n
                        remaining -= n
                        if out.count >= flushThreshold {
                            try flush()
                            try tick(offset)
                        }
                    }
                } else {
                    let payload: Int
                    switch type {
                    case 1: payload = 0x003 + 0x800
                    case 2: payload = 0x804
                    default: payload = 0x918
                    }
                    guard count <= (total - offset) / payload else { throw truncated() }

                    for i in 0..<count {
                        if i & 0xFF == 0xFF { try tick(offset) }

                        // Prepare sector buffer: zeros plus sync pattern
                        memset(sector, 0, 2352)
                        memset(sector + 1, 0xFF, 10)

                        switch type {
                        case 1:
                            sector[0x0F] = 0x01
                            load(0x00C, 0x003)
                            load(0x010, 0x800)
                            eccedc.eccedcGenerate(sector: sector, type: 1)
                            updateEDC(sector, 2352)
                            out.append(contentsOf: UnsafeBufferPointer(start: sector, count: 2352))

                        case 2, 3:
                            sector[0x0F] = 0x02
                            load(0x014, payload)
                            // Subheader is stored once in the ECM stream; duplicate it
                            sector[0x10] = sector[0x14]
                            sector[0x11] = sector[0x15]
                            sector[0x12] = sector[0x16]
                            sector[0x13] = sector[0x17]
                            eccedc.eccedcGenerate(sector: sector, type: type)
                            updateEDC(sector + 0x10, 2336)
                            out.append(contentsOf: UnsafeBufferPointer(start: sector + 0x10, count: 2336))

                        default:
                            break
                        }

                        if out.count >= flushThreshold { try flush() }
                    }
                }
            }
        }

        guard sawEnd else { throw truncated() }

        try flush()
        closed = true
        try handle.close()
        // rename(2) atomically replaces an existing file
        if rename(partialURL.path, outputURL.path) != 0 {
            let err = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "Cannot move decoded file into place: \(String(cString: strerror(err)))"])
        }
        finished = true
        progressHandler(.init(bytesProcessed: total, totalBytes: total))
    }
}
