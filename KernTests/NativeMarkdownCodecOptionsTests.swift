import AppKit
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

    func testFromUserDefaultsReadsOfficialExternalMermaidRenderMode() {
        let defaults = UserDefaults.standard
        let key = "nativeEditor.mermaidRenderMode"
        let hadValue = defaults.object(forKey: key) != nil
        let previous = defaults.object(forKey: key)
        defaults.set("officialExternal", forKey: key)
        defer {
            if hadValue {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let opt = NativeMarkdownCodec.Options.fromUserDefaults(defaults)
        XCTAssertEqual(opt.mermaidRenderMode, .officialExternal)
    }

    func testOfficialExternalRendererEnvironmentIncludesCommonNodeToolPaths() {
        let environment = MermaidOfficialExternalRenderer.debugRendererProcessEnvironmentForTesting()
        let pathEntries = Set((environment["PATH"] ?? "").split(separator: ":").map(String.init))

        XCTAssertTrue(pathEntries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(pathEntries.contains("/usr/local/bin"))
        XCTAssertTrue(pathEntries.contains("/usr/bin"))
        XCTAssertTrue(pathEntries.contains("/bin"))
        XCTAssertFalse((environment["HOME"] ?? "").isEmpty)
    }

    func testOfficialExternalRendererParsesQuotedCommandComponents() {
        let components = MermaidOfficialExternalRenderer.debugCommandComponentsForTesting(
            #""/opt/homebrew/bin/npx" -y "@mermaid-js/mermaid-cli@11.15.0""#
        )

        XCTAssertEqual(components, [
            "/opt/homebrew/bin/npx",
            "-y",
            "@mermaid-js/mermaid-cli@11.15.0",
        ])
    }

    func testOfficialExternalCacheIdentityChangesWithRendererConfiguration() {
        let defaults = UserDefaults.standard
        let commandKey = MermaidOfficialExternalRenderer.commandUserDefaultsKey
        let puppeteerKey = MermaidOfficialExternalRenderer.puppeteerConfigFileUserDefaultsKey
        let preservedEnv = preserveEnvironment([
            "KERN_OFFICIAL_MERMAID_RENDERER_COMMAND",
            "KERN_OFFICIAL_MERMAID_USE_NPX",
            "KERN_OFFICIAL_MERMAID_PUPPETEER_CONFIG_FILE",
        ])
        unsetenv("KERN_OFFICIAL_MERMAID_RENDERER_COMMAND")
        unsetenv("KERN_OFFICIAL_MERMAID_USE_NPX")
        unsetenv("KERN_OFFICIAL_MERMAID_PUPPETEER_CONFIG_FILE")
        let preserved: [(String, Any?)] = [
            (commandKey, defaults.object(forKey: commandKey)),
            (puppeteerKey, defaults.object(forKey: puppeteerKey)),
        ]
        defer {
            restoreEnvironment(preservedEnv)
            for (key, value) in preserved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let source = """
        ```mermaid
        flowchart TD
          A --> B
        ```
        """
        defaults.set("mmdc", forKey: commandKey)
        defaults.removeObject(forKey: puppeteerKey)
        let baseIdentity = MermaidOfficialExternalRenderer.renderIdentity(
            sourceMarkdown: source,
            widthBucket: 640,
            themeIdentifier: "default"
        )

        defaults.set("npx -y @mermaid-js/mermaid-cli@11.15.0", forKey: commandKey)
        let commandChangedIdentity = MermaidOfficialExternalRenderer.renderIdentity(
            sourceMarkdown: source,
            widthBucket: 640,
            themeIdentifier: "default"
        )

        defaults.set("/tmp/kern-puppeteer.json", forKey: puppeteerKey)
        let puppeteerChangedIdentity = MermaidOfficialExternalRenderer.renderIdentity(
            sourceMarkdown: source,
            widthBucket: 640,
            themeIdentifier: "default"
        )

        XCTAssertNotEqual(baseIdentity, commandChangedIdentity)
        XCTAssertNotEqual(commandChangedIdentity, puppeteerChangedIdentity)
    }

    func testOfficialExternalClearCacheOnlyRemovesGeneratedArtifacts() throws {
        let defaults = UserDefaults.standard
        let cacheKey = MermaidOfficialExternalRenderer.cacheDirectoryUserDefaultsKey
        let preservedEnv = preserveEnvironment(["KERN_OFFICIAL_MERMAID_CACHE_DIR"])
        unsetenv("KERN_OFFICIAL_MERMAID_CACHE_DIR")
        let previous = defaults.object(forKey: cacheKey)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kern-official-mermaid-clear-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults.set(root.path, forKey: cacheKey)
        defer {
            restoreEnvironment(preservedEnv)
            if let previous {
                defaults.set(previous, forKey: cacheKey)
            } else {
                defaults.removeObject(forKey: cacheKey)
            }
            try? FileManager.default.removeItem(at: root)
        }

        let generatedPNG = root.appendingPathComponent(String(repeating: "a", count: 64) + ".png")
        let workDirectory = root.appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
        let unrelatedPNG = root.appendingPathComponent("user-image.png")
        let unrelatedText = root.appendingPathComponent("notes.txt")
        try Self.onePixelPNG.write(to: generatedPNG, options: .atomic)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelatedPNG)
        try Data("keep".utf8).write(to: unrelatedText)

        try MermaidOfficialExternalRenderer.clearCache(defaults: defaults)

        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "Clear Cache should not remove the configured directory itself")
        XCTAssertFalse(FileManager.default.fileExists(atPath: generatedPNG.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: workDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedPNG.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedText.path))
    }

    @MainActor
    func testOfficialExternalMermaidModeFallsBackToNativeRichWithoutBlocking() {
        let defaults = UserDefaults.standard
        let commandKey = MermaidOfficialExternalRenderer.commandUserDefaultsKey
        let npxKey = MermaidOfficialExternalRenderer.npxEnabledUserDefaultsKey
        let hadCommand = defaults.object(forKey: commandKey) != nil
        let previousCommand = defaults.object(forKey: commandKey)
        let previousNpx = defaults.object(forKey: npxKey)
        defaults.removeObject(forKey: commandKey)
        defaults.set(false, forKey: npxKey)
        defer {
            if hadCommand {
                defaults.set(previousCommand, forKey: commandKey)
            } else {
                defaults.removeObject(forKey: commandKey)
            }
            if let previousNpx {
                defaults.set(previousNpx, forKey: npxKey)
            } else {
                defaults.removeObject(forKey: npxKey)
            }
        }

        let markdown = """
        ```mermaid
        flowchart TD
          A[Start] --> B[Done]
        ```
        """
        var opt = NativeMarkdownCodec.Options()
        opt.mermaidRenderMode = .officialExternal

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: opt)
        var attachment: MarkdownMermaidAttachment?
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length), options: []) { value, _, stop in
            if let mermaid = value as? MarkdownMermaidAttachment {
                attachment = mermaid
                stop.pointee = true
            }
        }

        XCTAssertEqual(attachment?.debugRequestedRenderModeForTesting, .officialExternal)
        XCTAssertEqual(attachment?.debugEffectiveRenderModeForTesting, .rich)
        let exported = NativeMarkdownCodec.exportMarkdown(attributed, options: opt)
        XCTAssertTrue(exported.contains("```mermaid"))
        XCTAssertTrue(exported.contains("A[Start] --> B[Done]"))
    }

    @MainActor
    func testOfficialExternalMermaidModeUsesConfiguredCacheRenderer() throws {
        let defaults = UserDefaults.standard
        let commandKey = MermaidOfficialExternalRenderer.commandUserDefaultsKey
        let cacheKey = MermaidOfficialExternalRenderer.cacheDirectoryUserDefaultsKey
        let npxKey = MermaidOfficialExternalRenderer.npxEnabledUserDefaultsKey
        let preserved: [(String, Any?)] = [
            (commandKey, defaults.object(forKey: commandKey)),
            (cacheKey, defaults.object(forKey: cacheKey)),
            (npxKey, defaults.object(forKey: npxKey)),
        ]

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kern-official-mermaid-test-\(UUID().uuidString)", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        defaults.set("/usr/bin/true", forKey: commandKey)
        defaults.set(cacheDir.path, forKey: cacheKey)
        defaults.set(false, forKey: npxKey)
        defer {
            for (key, value) in preserved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }

        let markdown = """
        ```mermaid
        flowchart TD
          A -->
          this is not valid official syntax [[[
        ```
        """
        var opt = NativeMarkdownCodec.Options()
        opt.mermaidRenderMode = .officialExternal

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: opt)
        let attachment = try XCTUnwrap(firstMermaidAttachment(in: attributed))
        XCTAssertEqual(attachment.debugRequestedRenderModeForTesting, .officialExternal)
        XCTAssertEqual(attachment.debugEffectiveRenderModeForTesting, .rich)
        XCTAssertFalse(attachment.debugHasOfficialExternalImageForTesting)

        let widthBucket = MermaidOfficialExternalRenderer.widthBucket(for: 680)
        let cacheURL = MermaidOfficialExternalRenderer.cachedOutputURLForTesting(
            sourceMarkdown: attachment.sourceMarkdown,
            widthBucket: widthBucket,
            themeIdentifier: "dark"
        )
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.onePixelPNG.write(to: cacheURL, options: .atomic)

        attachment.debugPrepareOfficialExternalRenderForTesting(maxContentWidth: 680, themeIdentifier: "dark")

        XCTAssertTrue(attachment.debugHasOfficialExternalImageForTesting)
        XCTAssertEqual(attachment.debugOfficialExternalRenderStateForTesting, "cacheHit")
        XCTAssertTrue(attachment.debugOfficialExternalRenderIdentityForTesting?.hasPrefix("dark-") == true)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path))?.contains { $0.hasSuffix(".png") } == true)
    }

    @MainActor
    func testOfficialExternalMermaidModeMarksRendererFailureWithoutHanging() throws {
        let defaults = UserDefaults.standard
        let commandKey = MermaidOfficialExternalRenderer.commandUserDefaultsKey
        let cacheKey = MermaidOfficialExternalRenderer.cacheDirectoryUserDefaultsKey
        let npxKey = MermaidOfficialExternalRenderer.npxEnabledUserDefaultsKey
        let preserved: [(String, Any?)] = [
            (commandKey, defaults.object(forKey: commandKey)),
            (cacheKey, defaults.object(forKey: cacheKey)),
            (npxKey, defaults.object(forKey: npxKey)),
        ]

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kern-official-mermaid-failure-test-\(UUID().uuidString)", isDirectory: true)
        let cacheDir = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        defaults.set("/usr/bin/false", forKey: commandKey)
        defaults.set(cacheDir.path, forKey: cacheKey)
        defaults.set(false, forKey: npxKey)
        defer {
            for (key, value) in preserved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }

        let markdown = """
        ```mermaid
        flowchart TD
          A[Start] --> B[Done]
        ```
        """
        var opt = NativeMarkdownCodec.Options()
        opt.mermaidRenderMode = .officialExternal

        let attributed = NativeMarkdownCodec.importMarkdown(markdown, options: opt)
        let attachment = try XCTUnwrap(firstMermaidAttachment(in: attributed))
        attachment.debugPrepareOfficialExternalRenderForTesting(maxContentWidth: 680, themeIdentifier: "default")

        let deadline = Date().addingTimeInterval(2)
        while attachment.debugOfficialExternalRenderStateForTesting == "rendering", Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        XCTAssertEqual(attachment.debugOfficialExternalRenderStateForTesting, "failed")
        XCTAssertFalse(attachment.debugHasOfficialExternalImageForTesting)
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

    func testRemoteImageLoadingDefaultsToDisabledWhenUnset() {
        let defaults = UserDefaults.standard
        let key = MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey
        let hadValue = defaults.object(forKey: key) != nil
        let previous = defaults.object(forKey: key)
        defaults.removeObject(forKey: key)
        defer {
            if hadValue {
                defaults.set(previous, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let opt = NativeMarkdownCodec.Options.fromUserDefaults(defaults)
        XCTAssertFalse(opt.remoteImageLoadingEnabled)
    }

    func testFromUserDefaultsReadsRemoteImageLoadingPreference() {
        let defaults = UserDefaults.standard
        let key = MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey
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

        let opt = NativeMarkdownCodec.Options.fromUserDefaults(defaults)
        XCTAssertTrue(opt.remoteImageLoadingEnabled)
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


    private static let onePixelPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAACAAAAAQCAYAAAB3AH1ZAAAAK0lEQVR4nGNk+M+ABzCC6lGjBqMGjRo0atCoQaMGjRo0atCoAQBZYwIROrmwSQAAAABJRU5ErkJggg==")!

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

    private func preserveEnvironment(_ keys: [String]) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: keys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })
    }

    private func restoreEnvironment(_ values: [String: String?]) {
        for (key, value) in values {
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    private func shellQuoted(_ text: String) -> String {
        "'\(text.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
