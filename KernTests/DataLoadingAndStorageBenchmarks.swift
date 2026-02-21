import AppKit
import Foundation
import XCTest
@testable import KernTextKit

// MARK: - Benchmark 1: mmap vs heap file loading

final class MmapVsHeapLoadingBenchmarks: XCTestCase {

    /// Generate a markdown file of approximately `targetBytes` size.
    /// Returns the temporary file URL.
    private func generateFixture(targetBytes: Int) throws -> URL {
        let paragraph = """
        ## Section Heading

        Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor
        incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud
        exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat.

        ```swift
        func fibonacci(_ n: Int) -> Int {
            guard n > 1 else { return n }
            return fibonacci(n - 1) + fibonacci(n - 2)
        }
        ```

        - Item one with **bold** and *italic* formatting
        - Item two with `inline code` and [a link](https://example.com)
        - Item three with ~~strikethrough~~ text

        > A blockquote with some text that wraps across multiple lines to simulate
        > realistic markdown content that a user might write in their editor.

        | Column A | Column B | Column C |
        |----------|----------|----------|
        | data 1   | data 2   | data 3   |
        | data 4   | data 5   | data 6   |


        """
        let paragraphBytes = paragraph.utf8.count
        let repeats = max(1, targetBytes / paragraphBytes)

        var content = "# Performance Test Document\n\n"
        for i in 0..<repeats {
            content += paragraph.replacingOccurrences(of: "## Section Heading",
                                                      with: "## Section \(i + 1)")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kern-bench-\(targetBytes).md")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func purgeFileCache(_ url: URL) {
        // Open + F_NOCACHE to invalidate unified buffer cache for this file.
        let fd = open(url.path, O_RDONLY)
        if fd >= 0 {
            fcntl(fd, F_NOCACHE, 1)
            // Read through the file to force cache purge on close.
            var buf = [UInt8](repeating: 0, count: 1 << 16)
            while read(fd, &buf, buf.count) > 0 {}
            close(fd)
        }
    }

    // MARK: - Heap loading (current approach: String(contentsOf:encoding:))

    func testHeapLoad_1MB() throws {
        try runHeapLoad(targetBytes: 1_000_000)
    }

    func testHeapLoad_10MB() throws {
        try runHeapLoad(targetBytes: 10_000_000)
    }

    func testHeapLoad_50MB() throws {
        try runHeapLoad(targetBytes: 50_000_000)
    }

    private func runHeapLoad(targetBytes: Int) throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run")
        }
        let url = try generateFixture(targetBytes: targetBytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let actualSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int

        let options = XCTMeasureOptions.default
        options.iterationCount = 10

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            purgeFileCache(url)
            autoreleasepool {
                // This is what NSDocument does: reads Data, then String(data:encoding:)
                guard let data = try? Data(contentsOf: url) else { XCTFail("read failed"); return }
                guard let _ = String(data: data, encoding: .utf8) else { XCTFail("decode failed"); return }
                // data + string = ~2x file size in heap at peak
            }
        }
        print("  [Heap] File size: \(actualSize) bytes")
    }

    // MARK: - mmap loading (proposed: Data mappedIfSafe + String)

    func testMmapLoad_1MB() throws {
        try runMmapLoad(targetBytes: 1_000_000)
    }

    func testMmapLoad_10MB() throws {
        try runMmapLoad(targetBytes: 10_000_000)
    }

    func testMmapLoad_50MB() throws {
        try runMmapLoad(targetBytes: 50_000_000)
    }

    private func runMmapLoad(targetBytes: Int) throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run")
        }
        let url = try generateFixture(targetBytes: targetBytes)
        defer { try? FileManager.default.removeItem(at: url) }
        let actualSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int

        let options = XCTMeasureOptions.default
        options.iterationCount = 10

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            purgeFileCache(url)
            autoreleasepool {
                // mmap: Data doesn't copy into heap — kernel maps file pages on demand.
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    XCTFail("mmap read failed"); return
                }
                // String(data:encoding:) still copies into heap, but we skip the initial
                // Data heap copy. At this point only 1x file size in heap (String) + mmap pages.
                guard let _ = String(data: data, encoding: .utf8) else {
                    XCTFail("decode failed"); return
                }
            }
        }
        print("  [Mmap] File size: \(actualSize) bytes")
    }

    // MARK: - mmap + deferred decode (proposed: keep Data mapped, decode on demand)

    func testMmapDeferredDecode_1MB() throws {
        try runMmapDeferred(targetBytes: 1_000_000)
    }

    func testMmapDeferredDecode_10MB() throws {
        try runMmapDeferred(targetBytes: 10_000_000)
    }

    func testMmapDeferredDecode_50MB() throws {
        try runMmapDeferred(targetBytes: 50_000_000)
    }

    private func runMmapDeferred(targetBytes: Int) throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run")
        }
        let url = try generateFixture(targetBytes: targetBytes)
        defer { try? FileManager.default.removeItem(at: url) }

        let options = XCTMeasureOptions.default
        options.iterationCount = 10

        // Measure just the I/O without String decoding — shows the mmap advantage most clearly.
        // In a real implementation, you'd decode line-by-line as needed during layout.
        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
            purgeFileCache(url)
            autoreleasepool {
                guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    XCTFail("mmap read failed"); return
                }
                // Just validate first byte to prove the mapping is live.
                XCTAssertEqual(data.first, UInt8(ascii: "#"))
            }
        }
    }
}

// MARK: - Benchmark 2: Piece Table vs NSTextStorage mutations

final class PieceTableVsTextStorageBenchmarks: XCTestCase {

    // A minimal piece table for benchmarking. Stores edits as a separate buffer
    // with a table of spans pointing into either the original or edit buffer.
    // This is the core Sublime Text / VS Code Monaco approach.
    private class PieceTable {
        enum Source { case original, edits }

        struct Piece {
            let source: Source
            var start: Int   // byte offset into the source buffer
            var length: Int
        }

        let original: [Character]
        var edits: [Character] = []
        var pieces: [Piece]

        var totalLength: Int {
            pieces.reduce(0) { $0 + $1.length }
        }

        init(_ content: String) {
            original = Array(content)
            pieces = [Piece(source: .original, start: 0, length: original.count)]
        }

        /// Insert `text` at character position `pos`. O(pieces) to find the piece, O(1) amortized for the insert.
        func insert(at pos: Int, text: String) {
            let chars = Array(text)
            let editStart = edits.count
            edits.append(contentsOf: chars)

            let newPiece = Piece(source: .edits, start: editStart, length: chars.count)

            // Find which piece contains `pos`.
            var offset = 0
            for i in 0..<pieces.count {
                let piece = pieces[i]
                if pos >= offset && pos <= offset + piece.length {
                    let splitAt = pos - offset
                    if splitAt == 0 {
                        // Insert before this piece.
                        pieces.insert(newPiece, at: i)
                    } else if splitAt == piece.length {
                        // Insert after this piece.
                        pieces.insert(newPiece, at: i + 1)
                    } else {
                        // Split this piece.
                        let left = Piece(source: piece.source, start: piece.start, length: splitAt)
                        let right = Piece(source: piece.source, start: piece.start + splitAt,
                                          length: piece.length - splitAt)
                        pieces.replaceSubrange(i...i, with: [left, newPiece, right])
                    }
                    return
                }
                offset += piece.length
            }
            // Append at end.
            pieces.append(newPiece)
        }

        /// Get the full text (for comparison/validation only — real usage would read ranges).
        func text() -> String {
            var result: [Character] = []
            result.reserveCapacity(totalLength)
            for piece in pieces {
                let source = piece.source == .original ? original : edits
                result.append(contentsOf: source[piece.start..<(piece.start + piece.length)])
            }
            return String(result)
        }
    }

    // MARK: - Generate base content

    private func generateContent(charCount: Int) -> String {
        let line = "The quick brown fox jumps over the lazy dog. "
        let repeats = max(1, charCount / line.count)
        return String(repeating: line, count: repeats)
    }

    // MARK: - Random inserts into NSTextStorage

    func testNSTextStorage_1000RandomInserts_10KDoc() throws {
        try runNSTextStorageBench(docChars: 10_000, insertCount: 1_000)
    }

    func testNSTextStorage_1000RandomInserts_100KDoc() throws {
        try runNSTextStorageBench(docChars: 100_000, insertCount: 1_000)
    }

    func testNSTextStorage_1000RandomInserts_1MDoc() throws {
        try runNSTextStorageBench(docChars: 1_000_000, insertCount: 1_000)
    }

    func testNSTextStorage_10000RandomInserts_1MDoc() throws {
        try runNSTextStorageBench(docChars: 1_000_000, insertCount: 10_000)
    }

    private func runNSTextStorageBench(docChars: Int, insertCount: Int) throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run")
        }

        let content = generateContent(charCount: docChars)
        let insertText = "INSERTED TEXT "

        let options = XCTMeasureOptions.default
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            autoreleasepool {
                let storage = NSTextStorage(string: content)
                // Seeded random for reproducibility.
                var rng = SeededRNG(seed: 42)
                for _ in 0..<insertCount {
                    let pos = Int.random(in: 0..<storage.length, using: &rng)
                    storage.beginEditing()
                    storage.replaceCharacters(in: NSRange(location: pos, length: 0),
                                              with: NSAttributedString(string: insertText))
                    storage.endEditing()
                }
            }
        }
    }

    // MARK: - Random inserts into PieceTable

    func testPieceTable_1000RandomInserts_10KDoc() throws {
        try runPieceTableBench(docChars: 10_000, insertCount: 1_000)
    }

    func testPieceTable_1000RandomInserts_100KDoc() throws {
        try runPieceTableBench(docChars: 100_000, insertCount: 1_000)
    }

    func testPieceTable_1000RandomInserts_1MDoc() throws {
        try runPieceTableBench(docChars: 1_000_000, insertCount: 1_000)
    }

    func testPieceTable_10000RandomInserts_1MDoc() throws {
        try runPieceTableBench(docChars: 1_000_000, insertCount: 10_000)
    }

    private func runPieceTableBench(docChars: Int, insertCount: Int) throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run")
        }

        let content = generateContent(charCount: docChars)
        let insertText = "INSERTED TEXT "

        let options = XCTMeasureOptions.default
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            let table = PieceTable(content)
            var rng = SeededRNG(seed: 42)
            for _ in 0..<insertCount {
                let pos = Int.random(in: 0..<table.totalLength, using: &rng)
                table.insert(at: pos, text: insertText)
            }
        }
    }

    // MARK: - Sequential inserts (simulating typing at cursor)

    func testNSTextStorage_10000SequentialInserts_100KDoc() throws {
        try runNSTextStorageSequential(docChars: 100_000, insertCount: 10_000)
    }

    func testPieceTable_10000SequentialInserts_100KDoc() throws {
        try runPieceTableSequential(docChars: 100_000, insertCount: 10_000)
    }

    func testNSTextStorage_10000SequentialInserts_1MDoc() throws {
        try runNSTextStorageSequential(docChars: 1_000_000, insertCount: 10_000)
    }

    func testPieceTable_10000SequentialInserts_1MDoc() throws {
        try runPieceTableSequential(docChars: 1_000_000, insertCount: 10_000)
    }

    private func runNSTextStorageSequential(docChars: Int, insertCount: Int) throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run")
        }

        let content = generateContent(charCount: docChars)

        let options = XCTMeasureOptions.default
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            autoreleasepool {
                let storage = NSTextStorage(string: content)
                // Type at the midpoint — worst case for array-backed storage.
                var cursor = storage.length / 2
                for _ in 0..<insertCount {
                    storage.beginEditing()
                    storage.replaceCharacters(in: NSRange(location: cursor, length: 0),
                                              with: NSAttributedString(string: "x"))
                    storage.endEditing()
                    cursor += 1
                }
            }
        }
    }

    private func runPieceTableSequential(docChars: Int, insertCount: Int) throws {
        guard TestRuntimeConfig.bool("KERN_ENABLE_PERF_TESTS") else {
            throw XCTSkip("Set KERN_ENABLE_PERF_TESTS=1 to run")
        }

        let content = generateContent(charCount: docChars)

        let options = XCTMeasureOptions.default
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            let table = PieceTable(content)
            var cursor = table.totalLength / 2
            for _ in 0..<insertCount {
                table.insert(at: cursor, text: "x")
                cursor += 1
            }
        }
    }
}

// MARK: - Deterministic RNG

private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        // xorshift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
