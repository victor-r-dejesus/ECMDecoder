import Foundation
import XCTest
@testable import ECMDecoderCore

// Fixtures/mixed.bin is a synthetic CD image (mode 1, mode 2 form 1, mode 2
// form 2, a corrupted sector, interleaved sectors, a 70 KB raw run and an odd
// tail). Fixtures/mixed.bin.ecm is that image encoded by Neill Corlett's
// reference `ecm` v1.0, and the reference `unecm` decodes it back exactly.

final class ECMDecoderTests: XCTestCase {
    private var workDir: URL!
    private let decoder = ECMDecoder()

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ECMDecoderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Helpers

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func write(_ data: Data, as name: String) throws -> URL {
        let url = workDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Decodes `ecm` into a fresh output file and returns its URL and the progress reports.
    @discardableResult
    private func decode(_ ecm: Data,
                        output name: String = "out.bin",
                        cancelAfter checks: Int? = nil) throws -> (url: URL, reports: [ECMDecoder.Progress]) {
        let input = try write(ecm, as: "in.ecm")
        let output = workDir.appendingPathComponent(name)
        var reports: [ECMDecoder.Progress] = []
        var count = 0
        try decoder.decode(
            inputURL: input,
            outputURL: output,
            progressHandler: { reports.append($0) },
            cancelCheck: {
                count += 1
                return checks.map { count > $0 } ?? false
            }
        )
        return (output, reports)
    }

    private func assertDecodeFails(_ ecm: Data, code: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(ecm), file: file, line: line) { error in
            let e = error as NSError
            XCTAssertEqual(e.domain, ECMDecoder.errorDomain, file: file, line: line)
            XCTAssertEqual(e.code, code, "\(e.localizedDescription)", file: file, line: line)
        }
        assertNoOutputLeft(file: file, line: line)
    }

    /// Only the input file may remain: no output and no temporary file.
    private func assertNoOutputLeft(file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workDir.path)) ?? []
        XCTAssertEqual(names.filter { $0 != "in.ecm" }, [], file: file, line: line)
    }

    // MARK: - Decoding

    func testDecodesMixedImageByteForByte() throws {
        let expected = try fixture("mixed.bin")
        let (url, _) = try decode(try fixture("mixed.bin.ecm"))
        XCTAssertEqual(try Data(contentsOf: url), expected)
    }

    func testProgressIsMonotonicAndReachesTotal() throws {
        let ecm = try fixture("mixed.bin.ecm")
        let (_, reports) = try decode(ecm)
        let last = try XCTUnwrap(reports.last)
        XCTAssertEqual(last.totalBytes, ecm.count)
        XCTAssertEqual(last.bytesProcessed, last.totalBytes)
        XCTAssertEqual(reports.map(\.bytesProcessed), reports.map(\.bytesProcessed).sorted())
    }

    func testDecodesEmptyImage() throws {
        let (url, _) = try decode(ECMBuilder().finish())
        XCTAssertEqual(try Data(contentsOf: url), Data())
    }

    func testRawRunsAroundChunkBoundaries() throws {
        // The decoder checksums raw data in chunks of at most 0xFFFF bytes.
        for size in [1, 0xFFFF, 0x10000, 0x1FFFF] {
            let raw = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            var builder = ECMBuilder()
            builder.raw(raw)
            let (url, _) = try decode(builder.finish(), output: "raw-\(size).bin")
            XCTAssertEqual(try Data(contentsOf: url), raw, "raw run of \(size) bytes")
        }
    }

    func testSeveralRawRecords() throws {
        var builder = ECMBuilder()
        builder.raw(Data("first".utf8))
        builder.raw(Data(repeating: 0xAB, count: 300))
        builder.raw(Data("last".utf8))
        let (url, _) = try decode(builder.finish())
        XCTAssertEqual(try Data(contentsOf: url),
                       Data("first".utf8) + Data(repeating: 0xAB, count: 300) + Data("last".utf8))
    }

    // MARK: - Malformed input

    func testRejectsEmptyAndTooShortFiles() {
        assertDecodeFails(Data(), code: 1)
        assertDecodeFails(Data("ECM".utf8), code: 1)
        assertDecodeFails(Data([0x45, 0x43, 0x4D, 0x00]), code: 1)
    }

    func testRejectsWrongHeader() {
        assertDecodeFails(Data("NOPE".utf8) + Data(repeating: 0, count: 16), code: 2)
    }

    func testRejectsTruncatedFiles() throws {
        let ecm = try fixture("mixed.bin.ecm")
        // Cut points near the start, inside records, and through the end
        // marker and trailing checksum.
        var cuts = Set([5, 6, 7, 100, 3000, ecm.count / 2])
        cuts.formUnion((ecm.count - 16)..<ecm.count)
        for cut in cuts.sorted() {
            assertDecodeFails(ecm.prefix(cut), code: 3)
        }
    }

    func testRejectsMissingEndMarker() throws {
        var builder = ECMBuilder()
        builder.raw(Data("no end".utf8))
        assertDecodeFails(builder.data, code: 3)
    }

    func testRejectsCorruptedSectorData() throws {
        var ecm = try fixture("mixed.bin.ecm")
        ecm[ecm.count / 2] ^= 0x01
        XCTAssertThrowsError(try decode(ecm))
        assertNoOutputLeft()
    }

    func testRejectsBadChecksum() throws {
        var ecm = try fixture("mixed.bin.ecm")
        ecm[ecm.count - 1] ^= 0xFF
        assertDecodeFails(ecm, code: 5)
    }

    func testRejectsOverlongCount() {
        // A count whose continuation bytes never end.
        var ecm = Data([0x45, 0x43, 0x4D, 0x00])
        ecm.append(contentsOf: [UInt8](repeating: 0xFF, count: 8))
        assertDecodeFails(ecm, code: 3)
    }

    func testRejectsCountLargerThanFile() {
        var builder = ECMBuilder()
        builder.record(type: 1, count: 1000)
        builder.data.append(Data(repeating: 0, count: 100))
        assertDecodeFails(builder.data, code: 3)
    }

    // MARK: - Cancel and output handling

    func testCancelThrowsAndRemovesOutput() throws {
        let ecm = try fixture("mixed.bin.ecm")
        XCTAssertThrowsError(try decode(ecm, cancelAfter: 1)) { error in
            XCTAssertEqual((error as NSError).code, ECMDecoder.canceledCode)
        }
        assertNoOutputLeft()
    }

    func testExistingOutputSurvivesFailedDecode() throws {
        let existing = workDir.appendingPathComponent("out.bin")
        try Data("keep me".utf8).write(to: existing)

        var corrupt = try fixture("mixed.bin.ecm")
        corrupt[corrupt.count - 1] ^= 0xFF
        XCTAssertThrowsError(try decode(corrupt))
        XCTAssertThrowsError(try decode(try fixture("mixed.bin.ecm"), cancelAfter: 1))

        XCTAssertEqual(try Data(contentsOf: existing), Data("keep me".utf8))
    }

    func testExistingOutputIsReplacedOnSuccess() throws {
        let existing = workDir.appendingPathComponent("out.bin")
        try Data("old".utf8).write(to: existing)
        try decode(try fixture("mixed.bin.ecm"))
        XCTAssertEqual(try Data(contentsOf: existing), try fixture("mixed.bin"))
    }

    func testMissingOutputFolderFails() throws {
        let input = try write(try fixture("mixed.bin.ecm"), as: "in.ecm")
        let output = workDir.appendingPathComponent("missing/out.bin")
        XCTAssertThrowsError(try decoder.decode(inputURL: input, outputURL: output,
                                                progressHandler: { _ in }, cancelCheck: { false }))
    }
}

// MARK: - A minimal ECM writer for building test inputs

/// Writes ECM files with raw (type 0) records. Its EDC is an independent
/// implementation of the reference checksum, so it doesn't reuse decoder code.
struct ECMBuilder {
    var data = Data([0x45, 0x43, 0x4D, 0x00])
    private var edc: UInt32 = 0

    private static let edcTable: [UInt32] = (0..<256).map { i in
        var e = UInt32(i)
        for _ in 0..<8 { e = (e >> 1) ^ ((e & 1) != 0 ? 0xD801_8001 : 0) }
        return e
    }

    /// Appends a type and count header, in the ECM variable-length encoding.
    mutating func record(type: Int, count: Int) {
        var n = UInt32(truncatingIfNeeded: count - 1)
        var byte = UInt8(type & 3) | UInt8((n & 0x1F) << 2)
        n >>= 5
        while n != 0 {
            data.append(byte | 0x80)
            byte = UInt8(n & 0x7F)
            n >>= 7
        }
        data.append(byte)
    }

    mutating func raw(_ bytes: Data) {
        record(type: 0, count: bytes.count)
        data.append(bytes)
        for b in bytes {
            edc = (edc >> 8) ^ Self.edcTable[Int((edc ^ UInt32(b)) & 0xFF)]
        }
    }

    /// Appends the end marker and the checksum of everything decoded.
    func finish() -> Data {
        var copy = self
        copy.record(type: 0, count: 0)   // count - 1 == 0xFFFFFFFF marks the end
        withUnsafeBytes(of: edc.littleEndian) { copy.data.append(contentsOf: $0) }
        return copy.data
    }
}
