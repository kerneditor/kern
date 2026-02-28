import XCTest
@testable import KernTextKit

final class NativeMarkdownCodecOptionsTests: XCTestCase {
    func testMermaidRenderModeDefaultsToRich() {
        let opt = NativeMarkdownCodec.Options()
        XCTAssertEqual(opt.mermaidRenderMode, .rich)
    }

    func testFromUserDefaultsReadsMermaidRenderMode() {
        let defaults = UserDefaults.standard
        let key = "nativeEditor.mermaidRenderMode"
        let hadValue = defaults.object(forKey: key) != nil
        let previous = defaults.object(forKey: key)
        defaults.set("ascii", forKey: key)
        defer {
            if hadValue {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let opt = NativeMarkdownCodec.Options.fromUserDefaults(defaults)
        XCTAssertEqual(opt.mermaidRenderMode, .ascii)
    }

    func testFromUserDefaultsInvalidMermaidRenderModeFallsBackToRich() {
        let defaults = UserDefaults.standard
        let key = "nativeEditor.mermaidRenderMode"
        let hadValue = defaults.object(forKey: key) != nil
        let previous = defaults.object(forKey: key)
        defaults.set("not-a-mode", forKey: key)
        defer {
            if hadValue {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let opt = NativeMarkdownCodec.Options.fromUserDefaults(defaults)
        XCTAssertEqual(opt.mermaidRenderMode, .rich)
    }

    func testLargeDocumentPlainImportIsOptInByDefault() {
        let opt = NativeMarkdownCodec.Options()
        XCTAssertFalse(opt.largeDocumentPlainImportEnabled)
    }

    func testLargeDocumentPlainImportUserDefaultIsIgnored() {
        let defaults = UserDefaults.standard
        let key = "nativeEditor.largeDocumentPlainImportEnabled"
        let hadValue = defaults.object(forKey: key) != nil
        let previous = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if hadValue {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let opt = NativeMarkdownCodec.Options.fromUserDefaults()
        XCTAssertFalse(opt.largeDocumentPlainImportEnabled)
    }

    @MainActor
    func testTaskRenderingKernShowsBulletDotForBulletedTasks() {
        let md = "- [ ] todo"
        var opt = NativeMarkdownCodec.Options()
        opt.taskRendering = .kern

        let attr = NativeMarkdownCodec.importMarkdown(md, options: opt)
        XCTAssertTrue(attr.string.contains("• ☐ todo"))

        let out = NativeMarkdownCodec.exportMarkdown(attr, options: opt)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "- [ ] todo")
    }

    @MainActor
    func testKernExportDialectPreservesStandaloneTaskSyntax() {
        let md = "[] todo"

        var opt = NativeMarkdownCodec.Options()
        opt.exportDialect = .kern

        let attr = NativeMarkdownCodec.importMarkdown(md, options: opt)
        let out = NativeMarkdownCodec.exportMarkdown(attr, options: opt)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "[ ] todo")
    }

    @MainActor
    func testOrderedTasksDisabledDoesNotCreateCheckboxes() {
        let md = "1. [ ] one"
        let attr = NativeMarkdownCodec.importMarkdown(md) // defaults: orderedTasksEnabled=false

        XCTAssertFalse(containsCheckbox(attr))
    }

    @MainActor
    func testOrderedTasksEnabledParsesAsOrderedTask() {
        let md = """
        1. [ ] one
        2. [x] two
        """

        var opt = NativeMarkdownCodec.Options()
        opt.orderedTasksEnabled = true

        let attr = NativeMarkdownCodec.importMarkdown(md, options: opt)
        XCTAssertTrue(containsCheckbox(attr))

        // First paragraph should be marked as an ordered task.
        let kind = attr.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(kind, KernBlockKind.ordered.rawValue)

        let isTask = (attr.attribute(.kernOrderedIsTask, at: 0, effectiveRange: nil) as? Bool) ?? false
        XCTAssertTrue(isTask)

        let out = NativeMarkdownCodec.exportMarkdown(attr, options: opt)
        XCTAssertTrue(out.contains("1. [ ] one"))
        XCTAssertTrue(out.contains("2. [x] two"))
    }

    @MainActor
    func testHeadingCheckboxesEnabledParsesAndExports() {
        let md = "## [ ] Heading"
        var opt = NativeMarkdownCodec.Options()
        opt.headingCheckboxesEnabled = true

        let attr = NativeMarkdownCodec.importMarkdown(md, options: opt)
        XCTAssertTrue(containsCheckbox(attr))

        let out = NativeMarkdownCodec.exportMarkdown(attr, options: opt)
        XCTAssertEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "## [ ] Heading")
    }

    @MainActor
    func testGfmPortableStrategyAvoidsKernExtensionSyntaxOnExport() {
        var opt = NativeMarkdownCodec.Options()
        opt.exportDialect = .gfm
        opt.gfmExtensionExportStrategy = .portable
        opt.orderedTasksEnabled = true
        opt.headingCheckboxesEnabled = true

        let md = """
        1. [ ] one
        2. [x] two

        ## [x] Heading
        """

        let attr = NativeMarkdownCodec.importMarkdown(md, options: opt)
        let out = NativeMarkdownCodec.exportMarkdown(attr, options: opt)

        XCTAssertTrue(out.contains("1. ☐ one"))
        XCTAssertTrue(out.contains("2. ☑ two"))
        XCTAssertTrue(out.contains("## ☑ Heading"))
    }

    @MainActor
    func testGfmLintStrategyRewritesHeadingCheckboxesAsTasks() {
        var opt = NativeMarkdownCodec.Options()
        opt.exportDialect = .gfm
        opt.gfmExtensionExportStrategy = .lint
        opt.headingCheckboxesEnabled = true

        let md = "## [x] Heading\n"
        let out = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md, options: opt), options: opt)
        XCTAssertTrue(out.contains("- [x] Heading"))
        XCTAssertFalse(out.contains("## [x] Heading"))
    }

    @MainActor
    func testOrderedListNumberingGfmDefaultNormalizesSequentially() {
        let md = """
        1. one
        5. five
        """

        var gfm = NativeMarkdownCodec.Options()
        gfm.orderedListNumbering = .gfmDefault
        let outGfm = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md, options: gfm), options: gfm)
        XCTAssertTrue(outGfm.contains("1. one"))
        XCTAssertTrue(outGfm.contains("2. five"))

        var preserve = NativeMarkdownCodec.Options()
        preserve.orderedListNumbering = .preserveTyped
        let outPreserve = NativeMarkdownCodec.exportMarkdown(NativeMarkdownCodec.importMarkdown(md, options: preserve), options: preserve)
        XCTAssertTrue(outPreserve.contains("5. five"))
    }

    @MainActor
    func testForcePlainImportEnvironmentSkipsRichParsing() {
        let previousForcePlain = getenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT").map { String(cString: $0) }
        let previousAllowPlain = getenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE").map { String(cString: $0) }
        let previousForceFull = getenv("KERN_FORCE_FULL_MARKDOWN_IMPORT").map { String(cString: $0) }
        setenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT", "1", 1)
        setenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE", "1", 1)
        unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")
        defer {
            if let previousForcePlain {
                setenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT", previousForcePlain, 1)
            } else {
                unsetenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT")
            }
            if let previousAllowPlain {
                setenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE", previousAllowPlain, 1)
            } else {
                unsetenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE")
            }
            if let previousForceFull {
                setenv("KERN_FORCE_FULL_MARKDOWN_IMPORT", previousForceFull, 1)
            } else {
                unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")
            }
        }

        let md = "# Heading\n- [ ] todo"
        let attr = NativeMarkdownCodec.importMarkdown(md)

        XCTAssertFalse(containsCheckbox(attr))
        let kindRaw = attr.attribute(.kernBlockKind, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(kindRaw, KernBlockKind.paragraph.rawValue)
    }

    @MainActor
    func testForceFullImportEnvironmentOverridesForcedPlainImport() {
        let previousForcePlain = getenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT").map { String(cString: $0) }
        let previousAllowPlain = getenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE").map { String(cString: $0) }
        let previousForceFull = getenv("KERN_FORCE_FULL_MARKDOWN_IMPORT").map { String(cString: $0) }
        setenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT", "1", 1)
        setenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE", "1", 1)
        setenv("KERN_FORCE_FULL_MARKDOWN_IMPORT", "1", 1)
        defer {
            if let previousForcePlain {
                setenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT", previousForcePlain, 1)
            } else {
                unsetenv("KERN_FORCE_PLAIN_MARKDOWN_IMPORT")
            }
            if let previousAllowPlain {
                setenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE", previousAllowPlain, 1)
            } else {
                unsetenv("KERN_ALLOW_PLAIN_IMPORT_OVERRIDE")
            }
            if let previousForceFull {
                setenv("KERN_FORCE_FULL_MARKDOWN_IMPORT", previousForceFull, 1)
            } else {
                unsetenv("KERN_FORCE_FULL_MARKDOWN_IMPORT")
            }
        }

        let md = "- [ ] todo"
        let attr = NativeMarkdownCodec.importMarkdown(md)
        XCTAssertTrue(containsCheckbox(attr))
    }

    @MainActor
    func testMermaidAutoModeFallsBackToASCIIForComplexDiagram() {
        var lines: [String] = [
            "```mermaid",
            "flowchart TD",
        ]
        for i in 0..<22 {
            lines.append("  N\(i)[Node \(i) with long descriptive label for complexity]")
        }
        for i in 0..<21 {
            lines.append("  N\(i) -->|edge \(i) label| N\(i + 1)")
        }
        lines.append("```")
        let markdown = lines.joined(separator: "\n")

        var opt = NativeMarkdownCodec.Options()
        opt.mermaidRenderMode = .auto

        let attr = NativeMarkdownCodec.importMarkdown(markdown, options: opt)
        let attachment = firstMermaidAttachment(in: attr)
        XCTAssertNotNil(attachment)
        XCTAssertEqual(attachment?.debugEffectiveRenderModeForTesting, .ascii)
    }

    @MainActor
    func testMermaidAutoModeKeepsRichForSmallDiagram() {
        let markdown = """
        ```mermaid
        graph TD
          A[Start] --> B[End]
        ```
        """

        var opt = NativeMarkdownCodec.Options()
        opt.mermaidRenderMode = .auto

        let attr = NativeMarkdownCodec.importMarkdown(markdown, options: opt)
        let attachment = firstMermaidAttachment(in: attr)
        XCTAssertNotNil(attachment)
        XCTAssertEqual(attachment?.debugEffectiveRenderModeForTesting, .rich)
    }

    private func containsCheckbox(_ attr: NSAttributedString) -> Bool {
        let full = NSRange(location: 0, length: attr.length)
        var found = false
        attr.enumerateAttribute(.kernCheckbox, in: full, options: []) { value, _, stop in
            if (value as? Bool) == true {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    private func firstMermaidAttachment(in attr: NSAttributedString) -> MarkdownMermaidAttachment? {
        let full = NSRange(location: 0, length: attr.length)
        var found: MarkdownMermaidAttachment?
        attr.enumerateAttribute(.attachment, in: full, options: []) { value, _, stop in
            if let attachment = value as? MarkdownMermaidAttachment {
                found = attachment
                stop.pointee = true
            }
        }
        return found
    }
}
