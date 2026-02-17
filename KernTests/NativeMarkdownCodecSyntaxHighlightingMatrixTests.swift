import AppKit
import XCTest
@testable import KernTextKit

final class NativeMarkdownCodecSyntaxHighlightingMatrixTests: XCTestCase {
    @MainActor
    func testMegaLanguageMatrix_Exhaustive_SyntaxHighlightingUsesMultipleColors() throws {
        try TestGates.skipUnlessExhaustive()

        let cases: [(language: String, snippet: String)] = [
            ("javascript", "// comment\nconst x = \"hi\"\nconsole.log(2)"),
            ("typescript", "interface User { id: string }\nconst x: number = 2"),
            ("python", "# comment\ndef f(x: int):\n    return x + 1"),
            ("rust", "// comment\nlet x: i32 = 2;\nprintln!(\"{x}\");"),
            ("go", "// comment\nvar x int = 2\nfmt.Println(x)"),
            ("c", "/* comment */\nint x = 2;\nprintf(\"%d\", x);"),
            ("cpp", "// comment\nstd::string s = \"hi\";\nint x = 2;"),
            ("java", "// comment\nclass A { int x = 2; }"),
            ("kotlin", "// comment\nval x: Int = 2"),
            ("swift", "// comment\nlet x: Int = 2"),
            ("ruby", "# comment\nx = \"hi\"\nputs x"),
            ("php", "<?php\n// comment\n$z = 2;\necho \"hi\";"),
            ("sql", "-- comment\nSELECT 1 AS n;"),
            ("html", "<!-- comment -->\n<div id=\"a\">hi</div>"),
            ("css", "/* comment */\nbody { color: red; }"),
            ("scss", "// comment\n$x: 2;\nbody { color: $x; }"),
            ("yaml", "# comment\nname: kern\nenabled: true"),
            ("json", "{ \"name\": \"kern\", \"count\": 2 }"),
            ("toml", "# comment\n[app]\nname = \"kern\""),
            ("xml", "<?xml version=\"1.0\"?>\n<root id=\"a\">v</root>"),
            ("bash", "# comment\nx=\"hi\"\necho \"$x\""),
            ("powershell", "# comment\n$x = \"hi\"\nWrite-Host $x"),
            ("lua", "-- comment\nlocal x = 2"),
            ("haskell", "-- comment\nmodule M where\nx = 2"),
            ("elixir", "# comment\ndefmodule M do\n  def f, do: 2\nend"),
            ("clojure", "; comment\n(def x 2)"),
            ("scala", "// comment\nval x: Int = 2"),
            ("r", "# comment\nx <- 2\nprint(x)"),
            ("perl", "# comment\nmy $x = 2;\nprint $x;"),
            ("dart", "// comment\nfinal int x = 2;"),
            ("zig", "// comment\nconst x: i32 = 2;"),
            ("ocaml", "(* comment *)\nlet x = 2"),
            ("graphql", "# comment\ntype User { id: ID! }"),
            ("protobuf", "// comment\nsyntax = \"proto3\";\nmessage A {}"),
            ("dockerfile", "# comment\nFROM alpine\nRUN echo \"hi\""),
            ("makefile", "# comment\nCC := clang\nall:\n\t@echo \"ok\""),
            ("terraform", "# comment\nresource \"x\" \"y\" { count = 1 }"),
        ]

        for testCase in cases {
            let markdown = """
            ```\(testCase.language)
            \(testCase.snippet)
            ```
            """
            let attr = NativeMarkdownCodec.importMarkdown(markdown)
            guard let range = firstCodeBlockRange(in: attr) else {
                XCTFail("(\(testCase.language)) missing code block range")
                continue
            }
            XCTAssertTrue(
                hasMultipleForegroundColors(attr: attr, range: range),
                "(\(testCase.language)) expected multiple foreground colors for syntax highlighting"
            )
        }
    }

    private func firstCodeBlockRange(in attr: NSAttributedString) -> NSRange? {
        guard attr.length > 0 else { return nil }
        var start: Int?
        var end: Int?
        for i in 0..<attr.length {
            let kindRaw = attr.attribute(.kernBlockKind, at: i, effectiveRange: nil) as? Int
            let kind = KernBlockKind(rawValue: kindRaw ?? KernBlockKind.paragraph.rawValue) ?? .paragraph
            if kind == .codeBlock {
                if start == nil { start = i }
                end = i
            } else if start != nil {
                break
            }
        }
        guard let start, let end else { return nil }
        return NSRange(location: start, length: max(0, end - start + 1))
    }

    private func hasMultipleForegroundColors(attr: NSAttributedString, range: NSRange) -> Bool {
        guard range.location + range.length <= attr.length else { return false }
        var colors = Set<NSColor>()
        attr.enumerateAttribute(.foregroundColor, in: range, options: []) { value, _, _ in
            guard let color = value as? NSColor else { return }
            colors.insert(color)
        }
        return colors.count >= 2
    }
}
