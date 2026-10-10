import Foundation

// MARK: - Data types
typealias ECCUInt8 = UInt8
typealias ECCUInt16 = UInt16
typealias ECCUInt32 = UInt32

// MARK: - ECC/EDC Tables
struct ECCEDC {
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
        return edcUpdate(edc, src, count: Int(size))
    }

    /// Continues an EDC computation over `count` bytes (no 16-bit size limit).
    func edcUpdate(_ edc: ECCUInt32, _ src: UnsafePointer<ECCUInt8>, count: Int) -> ECCUInt32 {
        var edc = edc
        for i in 0..<count {
            edc = (edc >> 8) ^ edcLUT[Int((edc ^ ECCUInt32(src[i])) & 0xFF)]
        }
        return edc
    }

    func edcComputeBlock(src: UnsafePointer<ECCUInt8>, size: ECCUInt16, dest: UnsafeMutablePointer<ECCUInt8>) {
        let edc = edcPartialComputeBlock(edc: 0, src: src, size: size)
        putLE32(edc, to: dest)
    }

    private func putLE32(_ value: ECCUInt32, to dest: UnsafeMutablePointer<ECCUInt8>) {
        dest[0] = ECCUInt8((value >> 0) & 0xFF)
        dest[1] = ECCUInt8((value >> 8) & 0xFF)
        dest[2] = ECCUInt8((value >> 16) & 0xFF)
        dest[3] = ECCUInt8((value >> 24) & 0xFF)
    }

    private func eccComputeBlock(src: UnsafePointer<ECCUInt8>,
                                 majorCount: ECCUInt32,
                                 minorCount: ECCUInt32,
                                 majorMult: ECCUInt32,
                                 minorInc: ECCUInt32,
                                 dest: UnsafeMutablePointer<ECCUInt8>) {
        let size = majorCount * minorCount
        for major in 0..<majorCount {
            var index = (major >> 1) * majorMult + (major & 1)
            var eccA: ECCUInt8 = 0
            var eccB: ECCUInt8 = 0
            for _ in 0..<minorCount {
                let temp = src[Int(index)]
                index += minorInc
                if index >= size { index -= size }
                eccA ^= temp
                eccB ^= temp
                eccA = eccFLUT[Int(eccA)]
            }
            let tempA = eccFLUT[Int(eccA)]
            eccA = eccBLUT[Int(tempA ^ eccB)]
            dest[Int(major)] = eccA
            dest[Int(major + majorCount)] = eccA ^ eccB
        }
    }

    /// Generates P parity (at 0x81C) and then Q parity (at 0x8C8), in place.
    /// Q covers the P bytes, so P must be written into the sector first.
    private func eccGenerate(sector: UnsafeMutablePointer<ECCUInt8>, zeroAddress: Bool) {
        // Optionally zero out the address bytes, saving a copy to restore later
        var savedAddress: (ECCUInt8, ECCUInt8, ECCUInt8, ECCUInt8) = (0, 0, 0, 0)
        if zeroAddress {
            savedAddress = (sector[12], sector[13], sector[14], sector[15])
            sector[12] = 0
            sector[13] = 0
            sector[14] = 0
            sector[15] = 0
        }

        // P parity: reads 0x00C..<0x81C, writes 0x81C..<0x8C8 (no overlap)
        eccComputeBlock(src: sector + 0xC,
                        majorCount: 86,
                        minorCount: 24,
                        majorMult: 2,
                        minorInc: 86,
                        dest: sector + 0x81C)

        // Q parity: reads 0x00C..<0x8C8 (including P), writes 0x8C8..<0x930 (no overlap)
        eccComputeBlock(src: sector + 0xC,
                        majorCount: 52,
                        minorCount: 43,
                        majorMult: 86,
                        minorInc: 88,
                        dest: sector + 0x8C8)

        if zeroAddress {
            sector[12] = savedAddress.0
            sector[13] = savedAddress.1
            sector[14] = savedAddress.2
            sector[15] = savedAddress.3
        }
    }

    func eccedcGenerate(sector: inout [ECCUInt8], type: Int) {
        guard sector.count >= 2352 else { return }
        sector.withUnsafeMutableBufferPointer { buf in
            guard let s = buf.baseAddress else { return }
            switch type {
            case 1:
                // Mode 1: EDC over the first 0x810 bytes, 8 zero bytes, then ECC
                let edc = edcPartialComputeBlock(edc: 0, src: s, size: 0x810)
                putLE32(edc, to: s + 0x810)
                for i in 0..<8 { s[0x814 + i] = 0 }
                eccGenerate(sector: s, zeroAddress: false)

            case 2:
                // Mode 2 form 1: EDC over 0x10..<0x818 stored at 0x818, then ECC with zeroed address
                edcComputeBlock(src: s + 0x10, size: 0x808, dest: s + 0x818)
                eccGenerate(sector: s, zeroAddress: true)

            case 3:
                // Mode 2 form 2: EDC over 0x10..<0x92C stored at 0x92C, no ECC
                edcComputeBlock(src: s + 0x10, size: 0x91C, dest: s + 0x92C)

            default:
                break
            }
        }
    }
}

// MARK: - Errors
public enum ECMError: Error, Equatable, LocalizedError {
    case fileTooShort
    case invalidHeader
    case truncatedData
    case invalidCount
    case checksumMismatch
    case canceled

    public var errorDescription: String? {
        switch self {
        case .fileTooShort: return "File too short"
        case .invalidHeader: return "Not an ECM file (header not found)"
        case .truncatedData: return "ECM data is truncated"
        case .invalidCount: return "ECM data is corrupt (invalid sector count)"
        case .checksumMismatch: return "Checksum mismatch: decoded data is corrupt"
        case .canceled: return "Canceled"
        }
    }
}

// MARK: - ECM Decoder
public final class ECMDecoder {
    private let eccedc = ECCEDC()

    public struct Progress {
        public var bytesProcessed: Int
        public var totalBytes: Int

        public init(bytesProcessed: Int, totalBytes: Int) {
            self.bytesProcessed = bytesProcessed
            self.totalBytes = totalBytes
        }
    }

    public init() {}

    public func decode(inputURL: URL,
                       outputURL: URL,
                       progressHandler: @escaping (Progress) -> Void,
                       cancelCheck: @escaping () -> Bool) throws {
        let data = try Data(contentsOf: inputURL)
        let output = try decode(data: data, progressHandler: progressHandler, cancelCheck: cancelCheck)
        try output.write(to: outputURL)
    }

    public func decode(data: Data,
                       progressHandler: ((Progress) -> Void)? = nil,
                       cancelCheck: (() -> Bool)? = nil) throws -> Data {
        return try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            let input = raw.bindMemory(to: UInt8.self)
            return try decodeBytes(input, progressHandler: progressHandler, cancelCheck: cancelCheck)
        }
    }

    private func decodeBytes(_ input: UnsafeBufferPointer<UInt8>,
                             progressHandler: ((Progress) -> Void)?,
                             cancelCheck: (() -> Bool)?) throws -> Data {
        let total = input.count
        guard total > 4, let base = input.baseAddress else {
            throw ECMError.fileTooShort
        }
        guard input[0] == 0x45, input[1] == 0x43, input[2] == 0x4D, input[3] == 0 else {
            throw ECMError.invalidHeader
        }

        var offset = 4
        var output = [UInt8]()
        output.reserveCapacity(total)
        var edc: ECCUInt32 = 0
        var lastReported = 0
        let reportInterval = 1 << 20

        // Reusable sector buffer; sync pattern is constant, the rest is rewritten per sector.
        var sector = [ECCUInt8](repeating: 0, count: 2352)
        for i in 1..<11 { sector[i] = 0xFF }

        func tick(force: Bool) throws {
            if let cancelCheck = cancelCheck, cancelCheck() {
                throw ECMError.canceled
            }
            if force || offset - lastReported >= reportInterval {
                lastReported = offset
                progressHandler?(Progress(bytesProcessed: offset, totalBytes: total))
            }
        }

        while true {
            try tick(force: false)

            guard offset < total else { throw ECMError.truncatedData } // no end marker

            var c = input[offset]; offset += 1
            let type = Int(c & 3)
            var num = Int((c >> 2) & 0x1F)
            var bits = 5
            while c & 0x80 != 0 {
                guard offset < total else { throw ECMError.truncatedData }
                guard bits <= 31 else { throw ECMError.invalidCount }
                c = input[offset]; offset += 1
                num |= Int(c & 0x7F) << bits
                bits += 7
            }
            guard num <= 0xFFFFFFFF else { throw ECMError.invalidCount }
            if num == 0xFFFFFFFF { break }
            num += 1

            if type == 0 {
                guard num <= total - offset else { throw ECMError.truncatedData }
                output.append(contentsOf: UnsafeBufferPointer(rebasing: input[offset..<(offset + num)]))
                edc = eccedc.edcUpdate(edc, base + offset, count: num)
                offset += num
                continue
            }

            // Bytes stored per sector and where they land in the sector buffer
            let storedSize: Int
            let destOffset: Int
            switch type {
            case 1: storedSize = 0x003 + 0x800; destOffset = 0x00C
            case 2: storedSize = 0x804;         destOffset = 0x014
            default: storedSize = 0x918;        destOffset = 0x014
            }

            for n in 0..<num {
                if n & 0xFF == 0xFF { try tick(force: false) }
                guard storedSize <= total - offset else { throw ECMError.truncatedData }

                if type == 1 {
                    // Mode 1: 3 address bytes at 0x0C, mode byte, 0x800 data bytes at 0x10
                    sector.withUnsafeMutableBytes { dst in
                        dst.baseAddress!.advanced(by: 0x00C).copyMemory(from: base + offset, byteCount: 0x003)
                        dst.baseAddress!.advanced(by: 0x010).copyMemory(from: base + offset + 0x003, byteCount: 0x800)
                    }
                    sector[0x0F] = 0x01
                } else {
                    // Mode 2: the stored data starts at 0x14; the subheader copy at 0x10 is a duplicate
                    sector.withUnsafeMutableBytes { dst in
                        dst.baseAddress!.advanced(by: destOffset).copyMemory(from: base + offset, byteCount: storedSize)
                    }
                    sector[0x0F] = 0x02
                    sector[0x10] = sector[0x14]
                    sector[0x11] = sector[0x15]
                    sector[0x12] = sector[0x16]
                    sector[0x13] = sector[0x17]
                }
                offset += storedSize

                eccedc.eccedcGenerate(sector: &sector, type: type)

                let start = (type == 1) ? 0 : 0x10
                let end = (type == 1) ? 2352 : 0x10 + 2336
                sector.withUnsafeBufferPointer { b in
                    edc = eccedc.edcUpdate(edc, b.baseAddress! + start, count: end - start)
                }
                output.append(contentsOf: sector[start..<end])
            }
        }

        // After the end marker: 4-byte little-endian EDC of all decoded output
        guard total - offset >= 4 else { throw ECMError.truncatedData }
        let stored = ECCUInt32(input[offset])
            | (ECCUInt32(input[offset + 1]) << 8)
            | (ECCUInt32(input[offset + 2]) << 16)
            | (ECCUInt32(input[offset + 3]) << 24)
        guard stored == edc else { throw ECMError.checksumMismatch }

        try tick(force: true)
        return Data(output)
    }
}
