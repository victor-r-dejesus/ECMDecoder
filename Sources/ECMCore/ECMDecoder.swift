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

    private func eccComputeBlock(src: UnsafeMutablePointer<ECCUInt8>,
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

    private func eccGenerate(sector: inout [ECCUInt8], zeroAddress: Bool) {
        // Optionally zero out the address bytes, saving a copy to restore later
        var savedAddress: [ECCUInt8] = [0, 0, 0, 0]
        if zeroAddress {
            for i in 0..<4 {
                savedAddress[i] = sector[12 + i]
                sector[12 + i] = 0
            }
        }

        // Copy the source region to avoid overlapping inout accesses
        // Source starts at offset 12 and covers the whole sector payload we'll read from
        var src = Array(sector[12...])

        // Prepare local destination buffers for ECC results
        var dest1 = [ECCUInt8](repeating: 0, count: Int(86 * 2)) // majorCount * 2
        var dest2 = [ECCUInt8](repeating: 0, count: Int(52 * 2))

        // Compute ECC into local buffers
        dest1.withUnsafeMutableBufferPointer { d1 in
            src.withUnsafeMutableBufferPointer { s in
                eccComputeBlock(src: s.baseAddress!,
                                majorCount: 86,
                                minorCount: 24,
                                majorMult: 2,
                                minorInc: 86,
                                dest: d1.baseAddress!)
            }
        }

        dest2.withUnsafeMutableBufferPointer { d2 in
            src.withUnsafeMutableBufferPointer { s in
                eccComputeBlock(src: s.baseAddress!,
                                majorCount: 52,
                                minorCount: 43,
                                majorMult: 86,
                                minorInc: 88,
                                dest: d2.baseAddress!)
            }
        }

        // Write ECC results back into the sector after computations are complete
        for i in 0..<dest1.count {
            sector[0x81C + i] = dest1[i]
        }
        for i in 0..<dest2.count {
            sector[0x8C8 + i] = dest2[i]
        }

        // Restore address if needed
        if zeroAddress {
            for i in 0..<4 { sector[12 + i] = savedAddress[i] }
        }
    }

    func eccedcGenerate(sector: inout [ECCUInt8], type: Int) {
        switch type {
        case 1:
            // Compute EDC over first 0x810 bytes into a temporary buffer, then write back
            var edcDest1 = [ECCUInt8](repeating: 0, count: 4)
            sector.withUnsafeMutableBufferPointer { s in
                edcDest1.withUnsafeMutableBufferPointer { d in
                    edcComputeBlock(src: s.baseAddress!, size: 0x810, dest: d.baseAddress!)
                }
            }
            // Write EDC bytes back to sector at 0x810
            for i in 0..<4 { sector[0x810 + i] = edcDest1[i] }
            // Zero 8 bytes at 0x814
            for i in 0..<8 { sector[0x814 + i] = 0 }
            // Generate ECC using a copy to avoid overlapping inout access
            eccGenerate(sector: &sector, zeroAddress: false)

        case 2:
            // Compute EDC over sector[0x10..<(0x10+0x808)] into temp, then copy back to 0x818
            var edcDest2 = [ECCUInt8](repeating: 0, count: 4)
            // Create a local copy of the source slice to satisfy exclusivity
            let src2 = Array(sector[0x10..<(0x10 + 0x808)])
            src2.withUnsafeBufferPointer { s in
                edcDest2.withUnsafeMutableBufferPointer { d in
                    edcComputeBlock(src: s.baseAddress!, size: 0x808, dest: d.baseAddress!)
                }
            }
            for i in 0..<4 { sector[0x818 + i] = edcDest2[i] }
            // ECC generation (internally already avoids overlapping by copying)
            eccGenerate(sector: &sector, zeroAddress: true)

        case 3:
            // Compute EDC over sector[0x10..<(0x10+0x91C)] into temp, then copy back to 0x92C
            var edcDest3 = [ECCUInt8](repeating: 0, count: 4)
            let src3 = Array(sector[0x10..<(0x10 + 0x91C)])
            src3.withUnsafeBufferPointer { s in
                edcDest3.withUnsafeMutableBufferPointer { d in
                    edcComputeBlock(src: s.baseAddress!, size: 0x91C, dest: d.baseAddress!)
                }
            }
            for i in 0..<4 { sector[0x92C + i] = edcDest3[i] }

        default:
            break
        }
    }
}

// MARK: - ECM Decoder
class ECMDecoder {
    private let eccedc = ECCEDC()

    struct Progress {
        var bytesProcessed: Int
        var totalBytes: Int
    }

    func decode(inputURL: URL,
                outputURL: URL,
                progressHandler: @escaping (Progress) -> Void,
                cancelCheck: @escaping () -> Bool) throws {

        let data = try Data(contentsOf: inputURL)
        var output = Data()
        var offset = 0
        let total = data.count

        guard data.count > 4 else {
            throw NSError(domain: "ECM", code: 1, userInfo: [NSLocalizedDescriptionKey: "File too short"])
        }

        guard data[offset] == 0x45, data[offset+1] == 0x43, data[offset+2] == 0x4D, data[offset+3] == 0 else {
            throw NSError(domain: "ECM", code: 2, userInfo: [NSLocalizedDescriptionKey: "Header not found"])
        }
        offset += 4

        while offset < data.count {
            if cancelCheck() {
                throw NSError(domain: "ECM", code: 99, userInfo: [NSLocalizedDescriptionKey: "Canceled"])
            }

            var c = data[offset]; offset += 1
            let type = Int(c & 3)
            var num = Int((c >> 2) & 0x1F)
            var bits = 5
            while c & 0x80 != 0 {
                guard offset < data.count else { break }
                c = data[offset]; offset += 1
                num |= Int(c & 0x7F) << bits
                bits += 7
            }
            if num == 0xFFFFFFFF { break }
            num += 1

            if type == 0 {
                guard offset + num <= data.count else { break }
                output.append(data[offset..<offset+num])
                offset += num
            } else {
                for _ in 0..<num {
                    // Prepare sector buffer
                    var sectorBuffer = [ECCUInt8](repeating: 0, count: 2352)
                    for i in 1..<11 { sectorBuffer[i] = 0xFF }

                    switch type {
                    case 1:
                        sectorBuffer[0x0F] = 0x01
                        guard offset + 0x003 + 0x800 <= data.count else { break }
                        sectorBuffer.replaceSubrange(0x00C..<(0x00C+0x003), with: data[offset..<(offset+0x003)])
                        offset += 0x003
                        sectorBuffer.replaceSubrange(0x010..<(0x010+0x800), with: data[offset..<(offset+0x800)])
                        offset += 0x800

                        eccedc.eccedcGenerate(sector: &sectorBuffer, type: 1)
                        output.append(contentsOf: sectorBuffer) // full array

                    case 2:
                        sectorBuffer[0x0F] = 0x02
                        guard offset + 0x804 <= data.count else { break }
                        sectorBuffer.replaceSubrange(0x014..<(0x014+0x804), with: data[offset..<(offset+0x804)])
                        offset += 0x804

                        eccedc.eccedcGenerate(sector: &sectorBuffer, type: 2)
                        let slice2 = Array(sectorBuffer[0x010..<(0x010+2336)])
                        output.append(contentsOf: slice2)

                    case 3:
                        sectorBuffer[0x0F] = 0x02
                        guard offset + 0x918 <= data.count else { break }
                        sectorBuffer.replaceSubrange(0x014..<(0x014+0x918), with: data[offset..<(offset+0x918)])
                        offset += 0x918

                        eccedc.eccedcGenerate(sector: &sectorBuffer, type: 3)
                        let slice3 = Array(sectorBuffer[0x010..<(0x010+2336)])
                        output.append(contentsOf: slice3)

                    default: break
                    }
                }
            }

            progressHandler(.init(bytesProcessed: offset, totalBytes: total))
        }

        try output.write(to: outputURL)
    }
}
