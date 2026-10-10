import XCTest
import Foundation
@testable import ECMCore

final class ECMDecoderTests: XCTestCase {

    // MARK: - Helpers

    /// Fixtures live next to this file; located via #filePath so no package resources are needed.
    private static let fixturesDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    private func fixtureURL(_ name: String) -> URL {
        return ECMDecoderTests.fixturesDir.appendingPathComponent(name)
    }

    private func fixture(_ name: String) throws -> Data {
        return try Data(contentsOf: fixtureURL(name))
    }

    private func assertDecodeThrows(_ input: Data,
                                    _ expected: ECMError,
                                    file: StaticString = #filePath,
                                    line: UInt = #line) {
        let decoder = ECMDecoder()
        XCTAssertThrowsError(try decoder.decode(data: input), file: file, line: line) { error in
            XCTAssertEqual(error as? ECMError, expected, file: file, line: line)
        }
    }

    /// Builds a full 2352-byte working sector from a 2336-byte mode 2 chunk.
    private func mode2WorkingSector(from chunk: [UInt8], mode: UInt8) -> [UInt8] {
        var sector = [UInt8](repeating: 0, count: 2352)
        for i in 1..<11 { sector[i] = 0xFF }
        sector[0x0F] = mode
        for i in 0..<2336 { sector[0x10 + i] = chunk[i] }
        return sector
    }

    // MARK: - Fixture round trips

    func testMixedFixtureRoundTrip() throws {
        let ecm = try fixture("mixed.ecm")
        let expected = try fixture("mixed.bin")
        let output = try ECMDecoder().decode(data: ecm)
        XCTAssertEqual(output.count, expected.count)
        XCTAssertEqual(output, expected)
    }

    func testMode1FixtureRoundTrip() throws {
        let ecm = try fixture("mode1.ecm")
        let expected = try fixture("mode1.bin")
        let output = try ECMDecoder().decode(data: ecm)
        XCTAssertEqual(output.count, expected.count)
        XCTAssertEqual(output.count % 2352, 0)
        XCTAssertEqual(output, expected)
    }

    func testMode2FixtureRoundTrip() throws {
        let ecm = try fixture("mode2.ecm")
        let expected = try fixture("mode2.bin")
        let output = try ECMDecoder().decode(data: ecm)
        XCTAssertEqual(output.count, expected.count)
        XCTAssertEqual(output.count % 2336, 0)
        XCTAssertEqual(output, expected)
    }

    func testEmptyImageDecodesToEmptyData() throws {
        // "ECM\0" + end marker + EDC of nothing (0)
        let bytes: [UInt8] = [0x45, 0x43, 0x4D, 0x00, 0xFC, 0xFF, 0xFF, 0xFF, 0x3F, 0x00, 0x00, 0x00, 0x00]
        let output = try ECMDecoder().decode(data: Data(bytes))
        XCTAssertEqual(output.count, 0)
    }

    func testRawOnlyImage() throws {
        // "hello" as a single raw block.
        let bytes: [UInt8] = [0x45, 0x43, 0x4D, 0x00, 0x10, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
                              0xFC, 0xFF, 0xFF, 0xFF, 0x3F, 0xFD, 0x9B, 0x5C, 0x4C]
        let output = try ECMDecoder().decode(data: Data(bytes))
        XCTAssertEqual(output, Data("hello".utf8))
    }

    func testDecoderIsReusable() throws {
        let decoder = ECMDecoder()
        let ecm = try fixture("mode1.ecm")
        let expected = try fixture("mode1.bin")
        XCTAssertEqual(try decoder.decode(data: ecm), expected)
        XCTAssertEqual(try decoder.decode(data: ecm), expected)
    }

    // MARK: - Error cases

    func testFileTooShort() throws {
        assertDecodeThrows(try fixture("tooshort.ecm"), .fileTooShort)
        assertDecodeThrows(Data(), .fileTooShort)
    }

    func testInvalidHeader() throws {
        assertDecodeThrows(try fixture("badheader.ecm"), .invalidHeader)
    }

    func testTruncatedData() throws {
        assertDecodeThrows(try fixture("truncated.ecm"), .truncatedData)
    }

    func testMissingEndMarkerAndTrailerIsTruncated() throws {
        assertDecodeThrows(try fixture("noend.ecm"), .truncatedData)
    }

    func testMissingChecksumTrailerIsTruncated() throws {
        let full = try fixture("mixed.ecm")
        let cut = full.prefix(full.count - 2)
        assertDecodeThrows(Data(cut), .truncatedData)
    }

    func testInvalidCount() throws {
        assertDecodeThrows(try fixture("badcount.ecm"), .invalidCount)
    }

    func testChecksumMismatchFromTrailer() throws {
        assertDecodeThrows(try fixture("badchecksum.ecm"), .checksumMismatch)
    }

    func testChecksumMismatchFromCorruptPayload() throws {
        var bytes = [UInt8](try fixture("mode1.ecm"))
        bytes[100] ^= 0xFF
        assertDecodeThrows(Data(bytes), .checksumMismatch)
    }

    func testEveryTruncationOfSmallStreamThrows() throws {
        let bytes: [UInt8] = [0x45, 0x43, 0x4D, 0x00, 0x10, 0x68, 0x65, 0x6C, 0x6C, 0x6F,
                              0xFC, 0xFF, 0xFF, 0xFF, 0x3F, 0xFD, 0x9B, 0x5C, 0x4C]
        for length in 5..<bytes.count {
            let decoder = ECMDecoder()
            let input = Data(bytes[0..<length])
            XCTAssertThrowsError(try decoder.decode(data: input), "length \(length)") { error in
                XCTAssertTrue(error is ECMError, "length \(length): \(error)")
            }
        }
    }

    func testErrorsAreEquatable() {
        XCTAssertEqual(ECMError.canceled, ECMError.canceled)
        XCTAssertNotEqual(ECMError.canceled, ECMError.truncatedData)
    }

    // MARK: - Cancellation

    func testCancelImmediately() throws {
        let ecm = try fixture("mixed.ecm")
        let decoder = ECMDecoder()
        XCTAssertThrowsError(try decoder.decode(data: ecm, progressHandler: nil, cancelCheck: { true })) { error in
            XCTAssertEqual(error as? ECMError, .canceled)
        }
    }

    func testCancelMidway() throws {
        let ecm = try fixture("mixed.ecm")
        var calls = 0
        let decoder = ECMDecoder()
        XCTAssertThrowsError(try decoder.decode(data: ecm, progressHandler: nil, cancelCheck: {
            calls += 1
            return calls > 2
        })) { error in
            XCTAssertEqual(error as? ECMError, .canceled)
        }
        XCTAssertGreaterThan(calls, 2)
    }

    func testCancelCheckReturningFalseDoesNotCancel() throws {
        let ecm = try fixture("mode2.ecm")
        let expected = try fixture("mode2.bin")
        let output = try ECMDecoder().decode(data: ecm, progressHandler: nil, cancelCheck: { false })
        XCTAssertEqual(output, expected)
    }

    // MARK: - Progress

    func testProgressIsMonotonicAndEndsAtTotal() throws {
        let ecm = try fixture("mixed.ecm")
        var updates: [ECMDecoder.Progress] = []
        let output = try ECMDecoder().decode(data: ecm, progressHandler: { update in
            updates.append(update)
        }, cancelCheck: nil)
        XCTAssertEqual(output, try fixture("mixed.bin"))
        XCTAssertFalse(updates.isEmpty)

        var previous = 0
        for update in updates {
            XCTAssertGreaterThanOrEqual(update.bytesProcessed, previous)
            XCTAssertLessThanOrEqual(update.bytesProcessed, update.totalBytes)
            XCTAssertEqual(update.totalBytes, updates[0].totalBytes)
            previous = update.bytesProcessed
        }
        XCTAssertGreaterThan(updates[0].totalBytes, 0)
        let last = updates[updates.count - 1]
        XCTAssertEqual(last.bytesProcessed, last.totalBytes)
    }

    func testProgressMode1Fixture() throws {
        let ecm = try fixture("mode1.ecm")
        var updates: [ECMDecoder.Progress] = []
        _ = try ECMDecoder().decode(data: ecm, progressHandler: { updates.append($0) }, cancelCheck: nil)
        XCTAssertFalse(updates.isEmpty)
        XCTAssertEqual(updates[updates.count - 1].bytesProcessed, updates[updates.count - 1].totalBytes)
    }

    // MARK: - URL variant

    func testURLDecodeWritesOutputFile() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ECMDecoderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let outputURL = tempDir.appendingPathComponent("out.bin")
        var updates: [ECMDecoder.Progress] = []
        try ECMDecoder().decode(inputURL: fixtureURL("mixed.ecm"),
                                outputURL: outputURL,
                                progressHandler: { updates.append($0) },
                                cancelCheck: { false })

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        let written = try Data(contentsOf: outputURL)
        XCTAssertEqual(written, try fixture("mixed.bin"))
        XCTAssertFalse(updates.isEmpty)
    }

    func testURLDecodeMissingInputThrows() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).ecm")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("never-written-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertThrowsError(try ECMDecoder().decode(inputURL: missing,
                                                     outputURL: out,
                                                     progressHandler: { _ in },
                                                     cancelCheck: { false }))
    }

    func testURLDecodeCorruptInputThrowsECMError() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("corrupt-out-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: out) }
        XCTAssertThrowsError(try ECMDecoder().decode(inputURL: fixtureURL("badchecksum.ecm"),
                                                     outputURL: out,
                                                     progressHandler: { _ in },
                                                     cancelCheck: { false })) { error in
            XCTAssertEqual(error as? ECMError, .checksumMismatch)
        }
    }

    // MARK: - ECC / EDC regeneration

    func testMode1RegenerationReproducesSector() throws {
        let bin = [UInt8](try fixture("mode1.bin"))
        XCTAssertGreaterThanOrEqual(bin.count, 2352 * 3)
        let ecc = ECCEDC()
        for index in 0..<3 {
            let original = Array(bin[(index * 2352)..<((index + 1) * 2352)])
            var sector = original
            // wipe EDC + reserved + P/Q parity (0x810...0x92F)
            for i in 0x810..<0x930 { sector[i] = 0 }
            XCTAssertNotEqual(sector, original)
            ecc.eccedcGenerate(sector: &sector, type: 1)
            XCTAssertEqual(sector, original, "mode 1 sector \(index)")
        }
    }

    func testMode2Form1RegenerationReproducesSector() throws {
        let bin = [UInt8](try fixture("mode2.bin"))
        let ecc = ECCEDC()
        for index in 0..<6 {   // first six chunks in mode2.bin are form 1
            let chunk = Array(bin[(index * 2336)..<((index + 1) * 2336)])
            let original = mode2WorkingSector(from: chunk, mode: 2)
            var sector = original
            // wipe EDC (0x818...0x81B) and ECC (0x81C...0x92F)
            for i in 0x818..<0x930 { sector[i] = 0 }
            XCTAssertNotEqual(sector, original)
            ecc.eccedcGenerate(sector: &sector, type: 2)
            XCTAssertEqual(Array(sector[0x10..<0x930]), chunk, "mode 2 form 1 chunk \(index)")
            // Header address bytes must be preserved even though ECC is computed with them zeroed.
            XCTAssertEqual(Array(sector[12..<16]), Array(original[12..<16]))
        }
    }

    func testMode2Form2RegenerationReproducesSector() throws {
        let bin = [UInt8](try fixture("mode2.bin"))
        let ecc = ECCEDC()
        for index in 6..<12 {  // next six chunks are form 2
            let chunk = Array(bin[(index * 2336)..<((index + 1) * 2336)])
            let original = mode2WorkingSector(from: chunk, mode: 2)
            var sector = original
            for i in 0x92C..<0x930 { sector[i] = 0 }
            XCTAssertNotEqual(sector, original)
            ecc.eccedcGenerate(sector: &sector, type: 3)
            XCTAssertEqual(Array(sector[0x10..<0x930]), chunk, "mode 2 form 2 chunk \(index)")
        }
    }

    func testRegenerationIsIdempotent() throws {
        let bin = [UInt8](try fixture("mode1.bin"))
        let ecc = ECCEDC()
        var sector = Array(bin[0..<2352])
        let original = sector
        ecc.eccedcGenerate(sector: &sector, type: 1)
        ecc.eccedcGenerate(sector: &sector, type: 1)
        XCTAssertEqual(sector, original)
    }

    func testCorruptedDataChangesRegeneratedParity() throws {
        let bin = [UInt8](try fixture("mode1.bin"))
        let ecc = ECCEDC()
        let original = Array(bin[0..<2352])
        var sector = original
        sector[0x100] ^= 0x01
        ecc.eccedcGenerate(sector: &sector, type: 1)
        XCTAssertNotEqual(sector, original)
        XCTAssertNotEqual(Array(sector[0x810..<0x814]), Array(original[0x810..<0x814]))
    }

    func testUnknownTypeLeavesSectorUntouched() throws {
        let bin = [UInt8](try fixture("mode1.bin"))
        let ecc = ECCEDC()
        let original = Array(bin[0..<2352])
        var sector = original
        ecc.eccedcGenerate(sector: &sector, type: 0)
        XCTAssertEqual(sector, original)
    }

    /// Cross-check against a known EDC property: EDC of the first 0x810 bytes of a valid
    /// mode 1 sector equals the little-endian word stored at 0x810.
    func testMode1EDCFieldMatchesStoredValue() throws {
        let bin = [UInt8](try fixture("mode1.bin"))
        let ecc = ECCEDC()
        var sector = Array(bin[0..<2352])
        for i in 0x810..<0x814 { sector[i] = 0xAA }
        ecc.eccedcGenerate(sector: &sector, type: 1)
        XCTAssertEqual(Array(sector[0x810..<0x814]), Array(bin[0x810..<0x814]))
    }
}
