import XCTest
@testable import KernTextKit

@MainActor
final class NativeEditorTableEditingTests: XCTestCase {
    func testTabMovesCaretToNextTableCell() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = """
        | Name | Value |
        | --- | --- |
        | Alpha | Beta |
        """

        let tv = vc.textViewForTesting()
        placeCaret(in: tv, row: 1, col: 0)

        let handled = vc.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(handled)

        assertCaret(in: tv, row: 1, col: 1)
    }

    func testShiftTabMovesCaretToPreviousTableCell() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = """
        | Name | Value |
        | --- | --- |
        | Alpha | Beta |
        """

        let tv = vc.textViewForTesting()
        placeCaret(in: tv, row: 1, col: 1)

        let handled = vc.textView(tv, doCommandBy: #selector(NSResponder.insertBacktab(_:)))
        XCTAssertTrue(handled)

        assertCaret(in: tv, row: 1, col: 0)
    }

    func testTabAtLastCellAppendsNewRowAndPreservesExport() {
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.stringValue = """
        | Name | Value |
        | --- | --- |
        | Alpha | Beta |
        """

        let tv = vc.textViewForTesting()
        placeCaret(in: tv, row: 1, col: 1)

        let handled = vc.textView(tv, doCommandBy: #selector(NSResponder.insertTab(_:)))
        XCTAssertTrue(handled)

        assertCaret(in: tv, row: 2, col: 0)

        let exported = NativeMarkdownCodec.exportMarkdown(
            vc.attributedTextForTesting(),
            options: NativeMarkdownCodec.Options.fromUserDefaults()
        )
        XCTAssertTrue(exported.contains("|  |  |"), "Expected a new empty table row after tabbing from last cell.\n\(exported)")
    }

    private func placeCaret(in textView: NativeMarkdownTextView, row: Int, col: Int) {
        guard let location = tableCellStart(in: textView, row: row, col: col) else {
            XCTFail("Missing target table cell row=\(row) col=\(col)")
            return
        }
        textView.setSelectedRange(NSRange(location: location, length: 0))
    }

    private func assertCaret(in textView: NativeMarkdownTextView, row: Int, col: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let location = tableCellStart(in: textView, row: row, col: col) else {
            XCTFail("Missing target table cell row=\(row) col=\(col)", file: file, line: line)
            return
        }
        XCTAssertEqual(textView.selectedRange().location, location, file: file, line: line)
    }

    private func tableCellStart(in textView: NativeMarkdownTextView, row: Int, col: Int) -> Int? {
        guard let storage = textView.textStorage else { return nil }
        let full = NSRange(location: 0, length: storage.length)
        var found: Int?
        storage.enumerateAttributes(in: full, options: []) { attrs, range, stop in
            guard found == nil else {
                stop.pointee = true
                return
            }
            let kindRaw = attrs[.kernBlockKind] as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            guard kind == .tableCell else { return }
            let r = attrs[.kernTableRow] as? Int ?? -1
            let c = attrs[.kernTableColumn] as? Int ?? -1
            guard r == row, c == col else { return }
            let content = paragraphContentRange(in: storage.string as NSString, paragraphRange: range)
            found = content.location
            stop.pointee = true
        }
        return found
    }

    private func paragraphContentRange(in ns: NSString, paragraphRange: NSRange) -> NSRange {
        var length = paragraphRange.length
        if length > 0 {
            let last = paragraphRange.location + length - 1
            if last < ns.length, ns.character(at: last) == 0x0A {
                length -= 1
            }
        }
        return NSRange(location: paragraphRange.location, length: max(0, length))
    }
}
