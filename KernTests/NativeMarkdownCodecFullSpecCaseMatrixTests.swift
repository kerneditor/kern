import Foundation
import XCTest
@testable import KernTextKit

/// Data-driven full-spec matrix for "real editor" Markdown support.
///
/// This is where we get to 100s of cases without writing 100s of bespoke tests.
/// The intent is for this to FAIL in exhaustive mode until each feature is implemented.
final class NativeMarkdownCodecFullSpecCaseMatrixTests: XCTestCase {
    private struct Case {
        var name: String
        var markdown: String
        var options: NativeMarkdownCodec.Options = .init()

        var expectWysiwygContains: [String] = []
        var expectWysiwygNotContains: [String] = []

        var expectMinAttachments: Int = 0

        var expectExportContains: [String] = []
        var expectExportNotContains: [String] = []
    }

    @MainActor
    func testFullSpecCaseMatrix_Exhaustive() throws {
        try TestGates.skipUnlessExhaustive()

        let cases = buildCases()
        XCTAssertGreaterThanOrEqual(cases.count, 250, "Matrix should contain 250+ cases (currently \(cases.count))")

        for c in cases {
            try XCTContext.runActivity(named: "Case: \(c.name)") { _ in
                let attr = NativeMarkdownCodec.importMarkdown(c.markdown, options: c.options)
                let out = NativeMarkdownCodec.exportMarkdown(attr, options: c.options)

                var failed = false

                for s in c.expectWysiwygContains {
                    if !attr.string.contains(s) {
                        failed = true
                        XCTFail("WYSIWYG expected to contain: \(s)\nActual: \(attr.string)")
                    }
                }
                for s in c.expectWysiwygNotContains {
                    if attr.string.contains(s) {
                        failed = true
                        XCTFail("WYSIWYG expected NOT to contain: \(s)\nActual: \(attr.string)")
                    }
                }

                let attachments = countAttachments(in: attr)
                if attachments < c.expectMinAttachments {
                    failed = true
                    XCTFail("Expected >= \(c.expectMinAttachments) attachments, got \(attachments)")
                }

                for s in c.expectExportContains {
                    if !out.contains(s) {
                        failed = true
                        XCTFail("Export expected to contain: \(s)\nActual:\n\(out)")
                    }
                }
                for s in c.expectExportNotContains {
                    if out.contains(s) {
                        failed = true
                        XCTFail("Export expected NOT to contain: \(s)\nActual:\n\(out)")
                    }
                }

                if failed {
                    let a = XCTAttachment(string: c.markdown)
                    a.name = "input.md"
                    a.lifetime = .keepAlways
                    add(a)

                    let b = XCTAttachment(string: attr.string)
                    b.name = "wysiwyg.txt"
                    b.lifetime = .keepAlways
                    add(b)

                    let e = XCTAttachment(string: out)
                    e.name = "export.md"
                    e.lifetime = .keepAlways
                    add(e)
                }
            }
        }
    }

    // MARK: - Case builder

    private func buildCases() -> [Case] {
        var cases: [Case] = []

        // ── Bullets: -, *, + (flat)
        for marker in ["-", "*", "+"] {
            cases.append(.init(
                name: "bullet-flat-\(marker)",
                markdown: "\(marker) item\n",
                expectWysiwygContains: ["item"],
                expectWysiwygNotContains: ["\(marker) item"],
                expectExportContains: ["- item"],
                expectExportNotContains: marker == "-" ? [] : ["\(marker) item"]
            ))
        }

        // ── Bullets: marker whitespace + indentation variations (CommonMark/GFM)
        let bulletWS: [(label: String, value: String)] = [("1sp", " "), ("2sp", "  "), ("tab", "\t")]
        for marker in ["-", "*", "+"] {
            for indent in 0...3 {
                for ws in bulletWS {
                    let pad = String(repeating: " ", count: indent)
                    let md = "\(pad)\(marker)\(ws.value)item\n"
                    cases.append(.init(
                        name: "bullet-indent\(indent)-ws\(ws.label)-marker\(marker)",
                        markdown: md,
                        expectWysiwygContains: ["item"],
                        expectWysiwygNotContains: ["\(marker)\(ws.value)item"],
                        expectExportContains: ["- item"],
                        expectExportNotContains: marker == "-" ? [] : ["\(marker)\(ws.value)item"]
                    ))
                }
            }
        }

        // ── Bullets: wrapping + rich inline content
        for marker in ["-", "*", "+"] {
            cases.append(.init(
                name: "bullet-wrapping-\(marker)",
                markdown: "\(marker) lorem ipsum lorem ipsum lorem ipsum lorem ipsum lorem ipsum lorem ipsum\n",
                expectWysiwygContains: ["lorem ipsum"],
                expectWysiwygNotContains: ["\(marker) lorem"],
                expectExportContains: ["- lorem ipsum"]
            ))

            cases.append(.init(
                name: "bullet-inline-formatting-\(marker)",
                markdown: "\(marker) **bold** *italic* `code` [link](https://example.com)\n",
                expectWysiwygContains: ["bold", "italic", "code", "link"],
                expectWysiwygNotContains: ["**bold**", "*italic*", "`code`", "[link]("],
                expectExportContains: ["**bold**", "*italic*", "`code`", "[link](https://example.com)"]
            ))

            cases.append(.init(
                name: "bullet-multiline-item-\(marker)",
                markdown: "\(marker) first line\n  second line\n",
                expectWysiwygContains: ["first line", "second line"],
                expectWysiwygNotContains: ["\(marker) first"],
                expectExportContains: ["- first line"]
            ))
        }

        // ── Tasks: -, *, + markers
        for marker in ["-", "*", "+"] {
            for checked in [false, true] {
                let box = checked ? "x" : " "
                let glyph = checked ? "\u{2611}" : "\u{2610}"
                cases.append(.init(
                    name: "task-flat-\(marker)-\(checked ? "checked" : "unchecked")",
                    markdown: "\(marker) [\(box)] task\n",
                    expectWysiwygContains: ["\(glyph) task"],
                    expectWysiwygNotContains: ["[\(box)]", "\(marker) ["],
                    expectExportContains: ["- [\(box)] task"],
                    expectExportNotContains: marker == "-" ? [] : ["\(marker) [\(box)] task"]
                ))
            }
        }

        // ── Tasks: uppercase X + rich content + nesting + ordered tasks (Kern option)
        for marker in ["-", "*", "+"] {
            cases.append(.init(
                name: "task-uppercase-x-\(marker)",
                markdown: "\(marker) [X] Uppercase checked\n",
                expectWysiwygContains: ["\u{2611} Uppercase checked"],
                expectWysiwygNotContains: ["[X]", "\(marker) ["],
                expectExportContains: ["- [x] Uppercase checked"],
                expectExportNotContains: ["[X]"]
            ))

            cases.append(.init(
                name: "task-rich-content-\(marker)",
                markdown: "\(marker) [x] **bold** *italic* `code` [link](https://example.com)\n",
                expectWysiwygContains: ["\u{2611} bold", "italic", "code", "link"],
                expectWysiwygNotContains: ["[x]", "**bold**", "*italic*", "`code`", "[link]("],
                expectExportContains: ["- [x]", "**bold**", "*italic*", "`code`", "[link](https://example.com)"]
            ))
        }

        cases.append(.init(
            name: "task-nested",
            markdown: "- [ ] parent\n  - [x] child\n",
            expectWysiwygContains: ["parent", "child"],
            expectWysiwygNotContains: ["- [ ]", "- [x]"],
            expectExportContains: ["- [ ] parent", "  - [x] child"]
        ))

        do {
            var opt = NativeMarkdownCodec.Options()
            opt.orderedTasksEnabled = true
            cases.append(.init(
                name: "task-ordered-enabled",
                markdown: "1. [ ] ordered task\n",
                options: opt,
                expectWysiwygContains: ["\u{2610} ordered task"],
                expectWysiwygNotContains: ["[ ] ordered task"],
                expectExportContains: ["1. [ ] ordered task"]
            ))
        }

        do {
            var opt = NativeMarkdownCodec.Options()
            opt.taskRendering = .kern
            cases.append(.init(
                name: "task-rendering-kern-shows-bullet-dot",
                markdown: "- [ ] task\n",
                options: opt,
                expectWysiwygContains: ["\u{2022} \u{2610} task"],
                expectExportContains: ["- [ ] task"]
            ))
        }

        // ── Standalone task shortcuts (Kern extension input) should still export GFM by default.
        for input in ["[] todo\n", "[ ] todo\n", "[x] todo\n"] {
            let checked = input.hasPrefix("[x]")
            let glyph = checked ? "\u{2611}" : "\u{2610}"
            cases.append(.init(
                name: "standalone-task-shortcut-\(checked ? "checked" : "unchecked")",
                markdown: input,
                expectWysiwygContains: ["\(glyph) todo"],
                expectWysiwygNotContains: ["[]", "[ ]", "[x]"],
                expectExportContains: [checked ? "- [x] todo" : "- [ ] todo"]
            ))
        }

        // ── Heading checkbox extension (when enabled)
        for level in 1...6 {
            var opt = NativeMarkdownCodec.Options()
            opt.headingCheckboxesEnabled = true

            let prefix = String(repeating: "#", count: level)
            cases.append(.init(
                name: "heading-checkbox-h\(level)-unchecked",
                markdown: "\(prefix) [ ] Heading\n",
                options: opt,
                expectWysiwygContains: ["\u{2610} Heading"],
                expectWysiwygNotContains: ["[ ] Heading"],
                expectExportContains: ["\(prefix) [ ] Heading"]
            ))
            cases.append(.init(
                name: "heading-checkbox-h\(level)-checked",
                markdown: "\(prefix) [x] Heading\n",
                options: opt,
                expectWysiwygContains: ["\u{2611} Heading"],
                expectWysiwygNotContains: ["[x] Heading"],
                expectExportContains: ["\(prefix) [x] Heading"]
            ))
        }

        // ── Headings: H1-H6 (plain + inline formatting)
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level)
            cases.append(.init(
                name: "heading-h\(level)-plain",
                markdown: "\(prefix) Heading \(level)\n",
                expectWysiwygContains: ["Heading \(level)"],
                expectWysiwygNotContains: ["\(prefix) Heading \(level)"],
                expectExportContains: ["\(prefix) Heading \(level)"]
            ))

            cases.append(.init(
                name: "heading-h\(level)-inline-formatting",
                markdown: "\(prefix) **Bold** *Italic* `Code`\n",
                expectWysiwygContains: ["Bold", "Italic", "Code"],
                expectWysiwygNotContains: ["\(prefix) **Bold**", "*Italic*", "`Code`"],
                expectExportContains: ["\(prefix) **Bold** *Italic* `Code`"]
            ))
        }

        // ── Thematic breaks (multiple syntaxes)
        for rule in ["---", "***", "___"] {
            cases.append(.init(
                name: "thematic-break-\(rule)",
                markdown: "Before\n\n\(rule)\n\nAfter\n",
                expectWysiwygContains: ["Before", "After"],
                expectWysiwygNotContains: [rule],
                expectExportContains: [rule]
            ))
        }

        // ── Thematic breaks: spaced + indented variants
        for rule in ["- - -", "* * *", "_ _ _", " ---", "*** ", "  ___"] {
            cases.append(.init(
                name: "thematic-break-variant-\(rule.replacingOccurrences(of: \" \", with: \"_\"))",
                markdown: "Before\n\n\(rule)\n\nAfter\n",
                expectWysiwygContains: ["Before", "After"],
                expectWysiwygNotContains: ["- - -", "* * *", "_ _ _", "---", "***", "___"],
                expectExportContains: ["---"]
            ))
        }

        // ── Blockquotes (simple + nested)
        cases.append(.init(
            name: "blockquote-basic",
            markdown: "> quote line 1\n> quote line 2\n",
            expectWysiwygContains: ["quote line 1", "quote line 2"],
            expectWysiwygNotContains: ["> "],
            expectExportContains: ["> quote line 1", "> quote line 2"]
        ))
        cases.append(.init(
            name: "blockquote-nested",
            markdown: "> a\n> > b\n> > > c\n",
            expectWysiwygContains: ["a", "b", "c"],
            expectWysiwygNotContains: ["> "],
            expectExportContains: ["> > b", "> > > c"]
        ))

        cases.append(.init(
            name: "blockquote-with-blank-line",
            markdown: "> one\n>\n> two\n",
            expectWysiwygContains: ["one", "two"],
            expectWysiwygNotContains: ["> "],
            expectExportContains: ["> one", "> two"]
        ))

        cases.append(.init(
            name: "blockquote-with-list",
            markdown: "> - item\n>   - nested\n",
            expectWysiwygContains: ["item", "nested"],
            expectWysiwygNotContains: ["> -", ">   -"],
            expectExportContains: ["> - item", ">   - nested"]
        ))

        cases.append(.init(
            name: "blockquote-with-code-fence",
            markdown: "> ```js\n> console.log(1)\n> ```\n",
            expectWysiwygContains: ["console.log(1)"],
            expectWysiwygNotContains: ["> ```", "```js"],
            expectExportContains: ["```js", "console.log(1)", "```"]
        ))

        // ── Autolinks + bare URLs
        cases.append(.init(
            name: "autolink-angle",
            markdown: "Visit <https://example.com>.\n",
            expectWysiwygContains: ["https://example.com"],
            expectWysiwygNotContains: ["<https://example.com>"],
            expectExportContains: ["<https://example.com>"]
        ))
        cases.append(.init(
            name: "autolink-bare",
            markdown: "Visit https://example.com now.\n",
            expectWysiwygContains: ["https://example.com"],
            expectExportContains: ["https://example.com"]
        ))

        cases.append(.init(
            name: "autolink-email-angle",
            markdown: "Contact <me@example.com>.\n",
            expectWysiwygContains: ["me@example.com"],
            expectWysiwygNotContains: ["<me@example.com>"],
            expectExportContains: ["<me@example.com>"]
        ))

        cases.append(.init(
            name: "link-inline-with-title",
            markdown: "A [title link](https://example.com \"Example\").\n",
            expectWysiwygContains: ["title link"],
            expectWysiwygNotContains: ["[title link](", "\")"],
            expectExportContains: ["[title link](https://example.com \"Example\")"]
        ))

        cases.append(.init(
            name: "link-reference-style",
            markdown: "See [ref][id].\n\n[id]: https://example.com\n",
            expectWysiwygContains: ["ref", "https://example.com"],
            expectWysiwygNotContains: ["[ref][id]"],
            expectExportContains: ["[ref][id]", "[id]: https://example.com"]
        ))

        cases.append(.init(
            name: "link-in-document-anchor",
            markdown: "Go to [Section 1](#section-1).\n",
            expectWysiwygContains: ["Section 1"],
            expectWysiwygNotContains: ["[Section 1]("],
            expectExportContains: ["[Section 1](#section-1)"]
        ))

        cases.append(.init(
            name: "bare-url-trailing-punctuation",
            markdown: "See https://example.com, then stop.\n",
            expectWysiwygContains: ["https://example.com"],
            expectExportContains: ["https://example.com,"]
        ))

        // ── Strikethrough
        cases.append(.init(
            name: "strikethrough",
            markdown: "This is ~~deleted~~ text.\n",
            expectWysiwygContains: ["deleted"],
            expectWysiwygNotContains: ["~~deleted~~"],
            expectExportContains: ["~~deleted~~"]
        ))

        cases.append(.init(
            name: "strikethrough-multiple",
            markdown: "~~a~~ ~~b~~ ~~c~~\n",
            expectWysiwygContains: ["a", "b", "c"],
            expectWysiwygNotContains: ["~~a~~", "~~b~~", "~~c~~"],
            expectExportContains: ["~~a~~ ~~b~~ ~~c~~"]
        ))

        cases.append(.init(
            name: "strikethrough-nested-bold",
            markdown: "**~~boldstrike~~**\n",
            expectWysiwygContains: ["boldstrike"],
            expectWysiwygNotContains: ["**~~", "~~**"],
            expectExportContains: ["**~~boldstrike~~**"]
        ))

        // ── Emphasis / strong / code (inline)
        let emphasisCases: [(String, String, [String], [String])] = [
            ("em-asterisk", "*italic*", ["italic"], ["*italic*"]),
            ("em-underscore", "_italic_", ["italic"], ["_italic_"]),
            ("strong-asterisk", "**bold**", ["bold"], ["**bold**"]),
            ("strong-underscore", "__bold__", ["bold"], ["__bold__"]),
            ("strong-em", "***both***", ["both"], ["***both***"]),
            ("nested-strong-em", "**bold *italic* bold**", ["bold", "italic"], ["**bold *italic* bold**"]),
            ("inline-code", "`code`", ["code"], ["`code`"]),
            ("inline-code-double-backtick", "``code with `tick` inside``", ["code with `tick` inside"], ["``code with `tick` inside``"]),
        ]
        for (name, md, contains, notContains) in emphasisCases {
            cases.append(.init(
                name: "inline-\(name)",
                markdown: "\(md)\n",
                expectWysiwygContains: contains,
                expectWysiwygNotContains: notContains,
                expectExportContains: [md]
            ))
        }

        // ── Code blocks (fenced + indented)
        let codeBlocks: [(String, String, [String])] = [
            ("fenced-js", "```js\nconsole.log(\"hi\")\nconsole.log(2)\n```\n", ["console.log(\"hi\")", "console.log(2)"]),
            ("fenced-no-lang", "```\nline 1\nline 2\n```\n", ["line 1", "line 2"]),
            ("fenced-tilde", "~~~python\nprint('x')\n~~~\n", ["print('x')"]),
            ("indented", "    let x = 1\n    let y = 2\n", ["let x = 1", "let y = 2"]),
        ]
        for (name, md, contains) in codeBlocks {
            cases.append(.init(
                name: "code-\(name)",
                markdown: md,
                expectWysiwygContains: contains,
                expectWysiwygNotContains: ["```", "~~~"],
                expectExportContains: name == "indented" ? ["```"] : ["```"]
            ))
        }

        // ── Images (full-spec: attachment)
        cases.append(.init(
            name: "image-remote",
            markdown: "![alt](https://example.com/image.png)\n",
            expectWysiwygNotContains: ["!["],
            expectMinAttachments: 1,
            expectExportContains: ["![alt]("]
        ))
        cases.append(.init(
            name: "image-local",
            markdown: "![local](screenshots/01-default-sample.png)\n",
            expectWysiwygNotContains: ["!["],
            expectMinAttachments: 1,
            expectExportContains: ["![local]("]
        ))

        cases.append(.init(
            name: "image-local-with-title",
            markdown: "![local](screenshots/01-default-sample.png \"Sample\")\n",
            expectWysiwygNotContains: ["!["],
            expectMinAttachments: 1,
            expectExportContains: ["![local](screenshots/01-default-sample.png \"Sample\")"]
        ))

        cases.append(.init(
            name: "image-remote-with-title",
            markdown: "![alt](https://example.com/image.png \"Alt title\")\n",
            expectWysiwygNotContains: ["!["],
            expectMinAttachments: 1,
            expectExportContains: ["![alt](https://example.com/image.png \"Alt title\")"]
        ))

        cases.append(.init(
            name: "image-reference-style",
            markdown: "![alt][img]\n\n[img]: https://example.com/image.png\n",
            expectWysiwygNotContains: ["!["],
            expectMinAttachments: 1,
            expectExportContains: ["![alt][img]", "[img]: https://example.com/image.png"]
        ))

        // ── Mermaid (full-spec: attachment / diagram)
        cases.append(.init(
            name: "mermaid",
            markdown: "```mermaid\ngraph TD\n  A-->B\n```\n",
            expectMinAttachments: 1,
            expectExportContains: ["```mermaid", "graph TD", "```"]
        ))

        let mermaidBodies: [(String, String)] = [
            ("flowchart", "flowchart TD\n  A[Start] --> B{Decision}\n  B -->|Yes| C[OK]\n  B -->|No| D[Retry]\n"),
            ("sequence", "sequenceDiagram\n  participant A\n  participant B\n  A->>B: hi\n"),
            ("mindmap", "mindmap\n  root\n    A\n    B\n"),
        ]
        for (name, body) in mermaidBodies {
            cases.append(.init(
                name: "mermaid-\(name)",
                markdown: "```mermaid\n\(body)```\n",
                expectMinAttachments: 1,
                expectExportContains: ["```mermaid", "```"]
            ))
        }

        // ── Math (inline + block)
        cases.append(.init(
            name: "math-inline",
            markdown: "Inline $E=mc^2$.\n",
            expectWysiwygContains: ["E=mc^2"],
            expectWysiwygNotContains: ["$E=mc^2$"],
            expectExportContains: ["$E=mc^2$"]
        ))
        cases.append(.init(
            name: "math-block",
            markdown: "$$\\n\\\\int_0^1 x^2 \\\\, dx\\n$$\\n",
            expectWysiwygNotContains: ["$$"],
            expectExportContains: ["$$"]
        ))

        cases.append(.init(
            name: "math-inline-multiple",
            markdown: "Math $a$ + $b$ = $c$.\n",
            expectWysiwygContains: ["a", "b", "c"],
            expectWysiwygNotContains: ["$a$", "$b$", "$c$"],
            expectExportContains: ["$a$", "$b$", "$c$"]
        ))

        cases.append(.init(
            name: "math-inline-with-escaped-dollar",
            markdown: "Price is \\$5, math is $x$.\n",
            expectWysiwygContains: ["$5", "x"],
            expectWysiwygNotContains: ["$x$"],
            expectExportContains: ["\\$5", "$x$"]
        ))

        cases.append(.init(
            name: "math-block-multiline",
            markdown: "$$\\n\\\\frac{1}{2}\\\\n\\\\sqrt{2}\\\\n$$\\n",
            expectWysiwygNotContains: ["$$"],
            expectExportContains: ["$$"]
        ))

        cases.append(.init(
            name: "math-in-list-item",
            markdown: "- item with $x^2$ inside\n",
            expectWysiwygContains: ["x^2"],
            expectWysiwygNotContains: ["$x^2$"],
            expectExportContains: ["$x^2$"]
        ))

        // ── Tables (escape + alignment edge cases)
        cases.append(.init(
            name: "table-minimal",
            markdown: "| A | B |\\n| --- | --- |\\n| c | d |\\n",
            expectWysiwygContains: ["A", "B", "c", "d"],
            expectWysiwygNotContains: ["| ---"],
            expectExportContains: ["| A | B |", "| --- | --- |", "| c | d |"]
        ))
        cases.append(.init(
            name: "table-escape-pipe",
            markdown: "| A | B |\\n| --- | --- |\\n| a\\\\|b | c |\\n",
            expectWysiwygContains: ["a|b", "c"],
            expectExportContains: ["a\\\\|b"]
        ))

        cases.append(.init(
            name: "table-alignment-left-right",
            markdown: "| A | B |\\n| :-- | --: |\\n| c | d |\\n",
            expectWysiwygContains: ["A", "B", "c", "d"],
            expectWysiwygNotContains: ["| :--", "| --:"],
            expectExportContains: ["| :-- | --: |"]
        ))

        cases.append(.init(
            name: "table-no-leading-trailing-pipes",
            markdown: "A | B\\n---|---\\nc|d\\n",
            expectWysiwygContains: ["A", "B", "c", "d"],
            expectWysiwygNotContains: ["---|---"],
            expectExportContains: ["| A | B |"]
        ))

        cases.append(.init(
            name: "table-empty-cell",
            markdown: "| A | B |\\n| --- | --- |\\n|  | d |\\n",
            expectWysiwygContains: ["A", "B", "d"],
            expectExportContains: ["|  | d |"]
        ))

        cases.append(.init(
            name: "table-inline-formatting",
            markdown: "| A | B |\\n| --- | --- |\\n| **bold** | `code` |\\n",
            expectWysiwygContains: ["bold", "code"],
            expectWysiwygNotContains: ["**bold**", "`code`"],
            expectExportContains: ["**bold**", "`code`"]
        ))

        cases.append(.init(
            name: "table-wide-6-cols",
            markdown: "| A | B | C | D | E | F |\\n| --- | --- | --- | --- | --- | --- |\\n| 1 | 2 | 3 | 4 | 5 | 6 |\\n",
            expectWysiwygContains: ["A", "F", "1", "6"],
            expectExportContains: ["| A | B | C | D | E | F |"]
        ))

        // ── Nested lists (bullet + ordered)
        cases.append(.init(
            name: "nested-bullet",
            markdown: "- one\\n  - nested\\n- two\\n",
            expectWysiwygContains: ["nested"],
            expectWysiwygNotContains: ["- nested"],
            expectExportContains: ["  - nested"]
        ))
        cases.append(.init(
            name: "nested-ordered-depth-aware-rendering",
            markdown: "1. Top\\n   1. Nested\\n",
            expectWysiwygContains: ["a. Nested"],
            expectExportContains: ["   1. Nested"]
        ))

        cases.append(.init(
            name: "nested-bullet-deep-3",
            markdown: "- a\\n  - b\\n    - c\\n      - d\\n",
            expectWysiwygContains: ["a", "b", "c", "d"],
            expectWysiwygNotContains: ["- b", "- c", "- d"],
            expectExportContains: ["  - b", "    - c", "      - d"]
        ))

        do {
            var opt = NativeMarkdownCodec.Options()
            opt.orderedListNumbering = .gfmDefault
            cases.append(.init(
                name: "ordered-numbering-gfmdefault-normalizes",
                markdown: "5. five\\n9. nine\\n",
                options: opt,
                expectWysiwygContains: ["5. five", "6. nine"],
                expectExportContains: ["5. five", "6. nine"],
                expectExportNotContains: ["9. nine"]
            ))
        }

        do {
            var opt = NativeMarkdownCodec.Options()
            opt.orderedListNumbering = .preserveTyped
            cases.append(.init(
                name: "ordered-numbering-preserve-typed",
                markdown: "5. five\\n9. nine\\n",
                options: opt,
                expectWysiwygContains: ["5. five", "9. nine"],
                expectExportContains: ["5. five", "9. nine"]
            ))
        }

        cases.append(.init(
            name: "mixed-ordered-with-nested-bullet",
            markdown: "1. one\\n   - child\\n2. two\\n",
            expectWysiwygContains: ["one", "child", "two"],
            expectExportContains: ["1. one", "   - child", "2. two"]
        ))

        // ── Preference permutations: full cross-product across codec options.
        // This is what prevents "works on my defaults" regressions.
        let permInput = """
        ## [x] Heading todo
        - [ ] todo
        1. [ ] ordered task
        1. one
        5. five
        """

        let dialects: [NativeMarkdownCodec.Options.ExportDialect] = [.gfm, .kern]
        let strategies: [NativeMarkdownCodec.Options.GfmExtensionExportStrategy] = [.preserve, .portable, .lint]
        let taskRenderings: [NativeMarkdownCodec.Options.TaskRendering] = [.gfm, .kern]
        let numbering: [NativeMarkdownCodec.Options.OrderedListNumbering] = [.gfmDefault, .preserveTyped]

        for dialect in dialects {
            for strat in strategies {
                for taskRendering in taskRenderings {
                    for orderedTasksEnabled in [false, true] {
                        for headingCheckboxesEnabled in [false, true] {
                            for orderedListNumbering in numbering {
                                var opt = NativeMarkdownCodec.Options()
                                opt.exportDialect = dialect
                                opt.gfmExtensionExportStrategy = strat
                                opt.taskRendering = taskRendering
                                opt.orderedTasksEnabled = orderedTasksEnabled
                                opt.headingCheckboxesEnabled = headingCheckboxesEnabled
                                opt.orderedListNumbering = orderedListNumbering

                                var expectWysiwygContains: [String] = ["todo", "one", "five"]
                                var expectWysiwygNotContains: [String] = []
                                var expectExportContains: [String] = ["todo", "one", "five"]
                                var expectExportNotContains: [String] = []

                                if headingCheckboxesEnabled {
                                    expectWysiwygContains.append("\u{2611} Heading todo")
                                    expectWysiwygNotContains.append("[x] Heading todo")

                                    if dialect == .kern {
                                        expectExportContains.append("## [x] Heading todo")
                                    } else {
                                        switch strat {
                                        case .preserve:
                                            expectExportContains.append("## [x] Heading todo")
                                        case .portable:
                                            expectExportContains.append("## \u{2611} Heading todo")
                                            expectExportNotContains.append("## [x] Heading todo")
                                        case .lint:
                                            expectExportContains.append("- [x] Heading todo")
                                            expectExportNotContains.append("## [x] Heading todo")
                                        }
                                    }
                                }

                                if orderedTasksEnabled {
                                    expectWysiwygContains.append("\u{2610} ordered task")
                                    expectWysiwygNotContains.append("[ ] ordered task")

                                    if dialect == .gfm && strat == .portable {
                                        expectExportContains.append("1. \u{2610} ordered task")
                                        expectExportNotContains.append("1. [ ] ordered task")
                                    } else {
                                        expectExportContains.append("1. [ ] ordered task")
                                    }
                                } else {
                                    // When the option is disabled, `[ ]` is plain text.
                                    expectExportContains.append("1. [ ] ordered task")
                                }

                                switch orderedListNumbering {
                                case .gfmDefault:
                                    expectExportContains.append("2. five")
                                    expectExportNotContains.append("5. five")
                                case .preserveTyped:
                                    expectExportContains.append("5. five")
                                }

                                cases.append(.init(
                                    name: "perm-d=\(dialect.rawValue)-s=\(strat.rawValue)-t=\(taskRendering.rawValue)-ot=\(orderedTasksEnabled ? "1" : "0")-hc=\(headingCheckboxesEnabled ? "1" : "0")-n=\(orderedListNumbering.rawValue)",
                                    markdown: permInput,
                                    options: opt,
                                    expectWysiwygContains: expectWysiwygContains,
                                    expectWysiwygNotContains: expectWysiwygNotContains,
                                    expectExportContains: expectExportContains,
                                    expectExportNotContains: expectExportNotContains
                                ))
                            }
                        }
                    }
                }
            }
        }

        return cases
    }

    private func countAttachments(in attr: NSAttributedString) -> Int {
        var n = 0
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length), options: []) { value, _, _ in
            if value != nil { n += 1 }
        }
        return n
    }
}
