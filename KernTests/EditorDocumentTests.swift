import AppKit
import XCTest
@testable import KernTextKit

final class EditorDocumentTests: XCTestCase {

    // MARK: - Read

    func testReadUTF8Content() throws {
        let doc = EditorDocument()
        let content = "# Hello World\n\nSome **bold** text."
        let data = content.data(using: .utf8)!

        try doc.read(from: data, ofType: "net.daringfireball.markdown")

        XCTAssertEqual(doc.stringValue, content)
    }

    func testReadEmptyContent() throws {
        let doc = EditorDocument()
        let data = Data()

        // Empty string is valid UTF-8
        try doc.read(from: data, ofType: "net.daringfireball.markdown")
        XCTAssertEqual(doc.stringValue, "")
    }

    func testReadUnicodeContent() throws {
        let doc = EditorDocument()
        let content = "한국어 테스트\n日本語テスト\n中文测试\nEmoji: 🎉🚀"
        let data = content.data(using: .utf8)!

        try doc.read(from: data, ofType: "net.daringfireball.markdown")

        XCTAssertEqual(doc.stringValue, content)
    }

    func testReadUTF16BOMFallback() throws {
        let doc = EditorDocument()
        // UTF-16LE BOM (FF FE) followed by "Hi" in UTF-16LE
        let content = "Hi"
        let data = content.data(using: .utf16LittleEndian)!
        let bom = Data([0xFF, 0xFE])
        let bomData = bom + data

        try doc.read(from: bomData, ofType: "net.daringfireball.markdown")
        XCTAssertEqual(doc.stringValue, content)
    }

    func testReadLatin1Fallback() throws {
        let doc = EditorDocument()
        // Latin-1 encoded string with non-UTF-8 byte (0xE9 = é in Latin-1)
        let data = Data([0x48, 0x65, 0x6C, 0x6C, 0x6F, 0x20, 0xE9])  // "Hello é"

        try doc.read(from: data, ofType: "net.daringfireball.markdown")
        // Should decode via auto-detection
        XCTAssertTrue(doc.stringValue.contains("Hello"))
    }

    // MARK: - Write

    func testDataOfTypeReturnsUTF8() throws {
        let doc = EditorDocument()
        let content = "# Test Document\n\nWith content."
        doc.stringValue = content

        let data = try doc.data(ofType: "net.daringfireball.markdown")

        let decoded = String(data: data, encoding: .utf8)
        XCTAssertEqual(decoded, content)
    }

    func testDataOfTypeWithUnicode() throws {
        let doc = EditorDocument()
        doc.stringValue = "가나다라마바사\n$$\\frac{1}{2}$$"

        let data = try doc.data(ofType: "net.daringfireball.markdown")
        let decoded = String(data: data, encoding: .utf8)

        XCTAssertEqual(decoded, doc.stringValue)
    }

    func testDataOfTypeEmptyContent() throws {
        let doc = EditorDocument()
        doc.stringValue = ""

        let data = try doc.data(ofType: "net.daringfireball.markdown")

        XCTAssertEqual(data.count, 0)
    }

    // MARK: - Round-trip

    func testReadWriteRoundTrip() throws {
        let original = """
        # Heading

        Paragraph with **bold** and *italic*.

        ```swift
        let x = 42
        ```

        - [ ] Task 1
        - [x] Task 2
        """

        let doc = EditorDocument()
        let inputData = original.data(using: .utf8)!

        try doc.read(from: inputData, ofType: "net.daringfireball.markdown")
        let outputData = try doc.data(ofType: "net.daringfireball.markdown")

        XCTAssertEqual(inputData, outputData)
    }

    func testLargeDocumentRoundTrip() throws {
        // Simulate a large document (50KB+)
        var content = "# Large Document\n\n"
        for i in 1...500 {
            content += "Paragraph \(i): Lorem ipsum dolor sit amet, consectetur adipiscing elit.\n\n"
        }

        let doc = EditorDocument()
        let data = content.data(using: .utf8)!
        try doc.read(from: data, ofType: "net.daringfireball.markdown")

        XCTAssertEqual(doc.stringValue, content)

        let outputData = try doc.data(ofType: "net.daringfireball.markdown")
        XCTAssertEqual(data, outputData)
    }

    // MARK: - Class Properties

    func testAutosavesInPlace() {
        XCTAssertTrue(EditorDocument.autosavesInPlace)
    }

    func testCanConcurrentlyRead() {
        XCTAssertTrue(EditorDocument.canConcurrentlyReadDocuments(ofType: "net.daringfireball.markdown"))
    }

    // MARK: - Window controller integration

    @MainActor
    func testMakeWindowControllersEventuallyRendersInitialMarkdown() {
        let doc = EditorDocument()
        doc.stringValue = "# Visible Heading\n\nInitial body text."

        doc.makeWindowControllers()
        defer { doc.close() }

        // Normal app opens intentionally render on the next runloop turn so the window can
        // present first. Pump the main runloop once, then verify the real document/window path
        // produced visible editor content rather than only a titled blank window.
        let rendered = expectation(description: "initial document render")
        DispatchQueue.main.async { rendered.fulfill() }
        wait(for: [rendered], timeout: 1.0)

        let nativeEditor = doc.windowControllers
            .compactMap { $0.contentViewController as? NativeEditorViewController }
            .first

        XCTAssertNotNil(nativeEditor)
        XCTAssertEqual(nativeEditor?.stringValue, "# Visible Heading\n\nInitial body text.")
        XCTAssertTrue(nativeEditor?.attributedTextForTesting().string.contains("Visible Heading") == true)
        XCTAssertTrue(nativeEditor?.attributedTextForTesting().string.contains("Initial body text.") == true)
        XCTAssertGreaterThan(nativeEditor?.textViewForTesting().frame.width ?? 0, 0)
        XCTAssertGreaterThan(nativeEditor?.textViewForTesting().frame.height ?? 0, 0)
        XCTAssertGreaterThan(
            nativeEditor?.textViewForTesting().textContainer?.containerSize.width ?? 0,
            100,
            "Document open should not leave TextKit with a collapsed zero-width text container"
        )
    }

    // MARK: - Mod Date Tracking

    func testLastKnownFileModDateInitiallyNil() {
        let doc = EditorDocument()
        XCTAssertNil(doc.lastKnownFileModDate)
    }
}
