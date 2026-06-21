import AppKit
import SnapshotTesting
import XCTest
@testable import KernTextKit

@_silgen_name("uncompress")
private func zlibUncompress(
    _ destination: UnsafeMutablePointer<UInt8>!,
    _ destinationLength: UnsafeMutablePointer<UInt>!,
    _ source: UnsafePointer<UInt8>!,
    _ sourceLength: UInt
) -> Int32

final class NativeEditorSnapshotTests: XCTestCase {
    nonisolated override func setUp() {
        super.setUp()
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                Self.resetGlobalAppKitSnapshotState()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    Self.resetGlobalAppKitSnapshotState()
                }
            }
        }
    }

    nonisolated override func tearDown() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                Self.resetGlobalAppKitSnapshotState()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    Self.resetGlobalAppKitSnapshotState()
                }
            }
        }
        super.tearDown()
    }

    @MainActor
    func testBasicFixture_GfmDefault_Light() throws {
        try TestGates.skipUnlessSnapshots()

        try withNativeEditorDefaults(profile: .gfmDefault) {
            try withSnapshotTesting(record: snapshotRecordMode) {
                let appearance = NSAppearance(named: .aqua)
                applySnapshotTheme(for: appearance)
                let fixture = try loadFixture(name: "basic.in.md")
                let view = makeSnapshotView(
                    fixture: fixture,
                    size: NSSize(width: 900, height: 650),
                    appearance: appearance
                )
                assertSnapshot(of: view, as: snapshotImageStrategy(size: view.bounds.size))
            }
        }
    }

    @MainActor
    func testExtensionsFixture_KernProfile_Dark() throws {
        try TestGates.skipUnlessSnapshots()

        try withNativeEditorDefaults(profile: .kernExtensions) {
            try withSnapshotTesting(record: snapshotRecordMode) {
                let appearance = NSAppearance(named: .darkAqua)
                applySnapshotTheme(for: appearance)
                let fixture = try loadFixture(name: "extensions.in.md")
                let view = makeSnapshotView(
                    fixture: fixture,
                    size: NSSize(width: 900, height: 650),
                    appearance: appearance
                )
                assertSnapshot(of: view, as: snapshotImageStrategy(size: view.bounds.size))
            }
        }
    }

    @MainActor
    func testImagesFixture_GfmDefault_Light() throws {
        try TestGates.skipUnlessSnapshots()

        try withNativeEditorDefaults(profile: .gfmDefault) {
            try withSnapshotTesting(record: snapshotRecordMode) {
                let appearance = NSAppearance(named: .aqua)
                applySnapshotTheme(for: appearance)
                let fixture = try loadFixture(name: "images.fixture.md")
                let view = makeSnapshotView(
                    fixture: fixture,
                    size: NSSize(width: 960, height: 760),
                    appearance: appearance
                )
                assertSnapshot(of: view, as: snapshotImageStrategy(size: view.bounds.size))
            }
        }
    }

    @MainActor
    func testFullSpecVisualFixture_GfmDefault_Dark() throws {
        try TestGates.skipUnlessSnapshots()

        try withNativeEditorDefaults(profile: .gfmDefault) {
            try withSnapshotTesting(record: snapshotRecordMode) {
                let appearance = NSAppearance(named: .darkAqua)
                applySnapshotTheme(for: appearance)
                let fixture = try loadFixture(name: "full-spec-visual.fixture.md")
                let view = makeSnapshotView(
                    fixture: fixture,
                    size: NSSize(width: 980, height: 980),
                    appearance: appearance
                )
                assertSnapshot(of: view, as: snapshotImageStrategy(size: view.bounds.size))
            }
        }
    }

    @MainActor
    func testThemeAndFontPresetSnapshots() throws {
        try TestGates.skipUnlessSnapshots()

        let fixture = try loadFixture(name: "basic.in.md")
        let scenarios: [(theme: NativeEditorThemeMode, family: NativeEditorFontFamilyPreset, appearance: NSAppearance?)] = [
            (.githubDark, .inter, .init(named: .darkAqua)),
            (.solarizedLight, .sourceSerif, .init(named: .aqua)),
        ]

        withSnapshotTesting(record: snapshotRecordMode) {
            for scenario in scenarios {
                withNativeEditorDefaults(profile: .gfmDefault) {
                    let defaults = UserDefaults.standard
                    defaults.set(scenario.theme.rawValue, forKey: NativeEditorAppearance.themeModeKey)
                    defaults.set(scenario.family.rawValue, forKey: NativeEditorAppearance.fontFamilyKey)
                    NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)

                    let view = makeSnapshotView(
                        fixture: fixture,
                        size: NSSize(width: 900, height: 650),
                        appearance: scenario.appearance
                    )
                    assertSnapshot(
                        of: view,
                        as: snapshotImageStrategy(size: view.bounds.size),
                        named: "theme-\(scenario.theme.rawValue)-font-\(scenario.family.rawValue)"
                    )
                }
            }
        }
    }

    @MainActor
    func testFindReplaceOverlaySnapshot_Dark() throws {
        try TestGates.skipUnlessSnapshots()

        try withNativeEditorDefaults(profile: .gfmDefault) {
            try withSnapshotTesting(record: snapshotRecordMode) {
                let appearance = NSAppearance(named: .darkAqua)
                applySnapshotTheme(for: appearance)
                let fixture = try loadFixture(name: "full-spec-visual.fixture.md")
                let vc = NativeEditorViewController()
                _ = vc.view
                let view = hostInWindow(vc: vc, size: NSSize(width: 980, height: 700), appearance: appearance)

                vc.documentURL = fixture.url
                vc.stringValue = fixture.markdown
                vc.showFindReplace(nil)
                if let findField = findSubview(withAXIdentifier: "NativeEditor.FindField", in: view) as? NSSearchField {
                    findField.stringValue = "inline"
                    findField.sendAction(findField.action, to: findField.target)
                }

                settleSnapshotView(view)
                assertSnapshot(
                    of: view,
                    as: snapshotImageStrategy(size: view.bounds.size),
                    named: "find-replace-overlay-dark"
                )
            }
        }
    }

    @MainActor
    func testSettingsWindowSnapshot_Light() throws {
        try TestGates.skipUnlessSnapshots()

        withNativeEditorDefaults(profile: .gfmDefault) {
            withSnapshotTesting(record: snapshotRecordMode) {
                let appearance = NSAppearance(named: .aqua)
                applySnapshotTheme(for: appearance)
                let controller = NativeEditorPreferencesWindowController()
                defer { controller.close() }

                guard let window = controller.window,
                      let contentView = window.contentView else {
                    XCTFail("Expected settings window content view")
                    return
                }

                window.appearance = appearance
                if let appearance {
                    applyAppearance(appearance, to: contentView)
                }
                contentView.wantsLayer = true
                contentView.layer?.backgroundColor = resolvedWindowBackgroundColor(for: appearance).cgColor
                window.layoutIfNeeded()
                contentView.layoutSubtreeIfNeeded()
                contentView.displayIfNeeded()

                assertSnapshot(
                    of: contentView,
                    as: snapshotImageStrategy(size: contentView.bounds.size),
                    named: "settings-window-light"
                )
            }
        }
    }

    @MainActor
    func testFullSpecVisualFixture_RenderPipelineKeepsAttachments() throws {
        let fixture = try loadFixture(name: "full-spec-visual.fixture.md")
        let vc = NativeEditorViewController()
        _ = vc.view
        vc.documentURL = fixture.url
        vc.stringValue = fixture.markdown

        guard let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: vc.view) as? NSTextView,
              let storage = textView.textStorage else {
            XCTFail("Missing NativeEditor.TextView")
            return
        }

        let deadline = Date().addingTimeInterval(6.0)
        var attachmentCount = 0
        var attachmentsWithCell = 0
        while Date() < deadline {
            attachmentCount = 0
            attachmentsWithCell = 0
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                attachmentCount += 1
                if attachment.attachmentCell != nil {
                    attachmentsWithCell += 1
                }
            }
            if attachmentCount >= 4 {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertGreaterThanOrEqual(attachmentCount, 4, "Expected image + HR + math + mermaid attachments in full-spec fixture render pipeline")
        XCTAssertEqual(attachmentsWithCell, attachmentCount, "All rendered attachments must keep a cell")
    }

    /// Exhaustive visual matrix. This is intentionally gated behind `KERN_ENABLE_EXHAUSTIVE_TESTS=1`
    /// since it produces many snapshots and can be slow.
    @MainActor
    func testSnapshotMatrix_Exhaustive() throws {
        try TestGates.skipUnlessSnapshots()
        try TestGates.skipUnlessExhaustive()

        let fixtures = [
            "basic.in.md",
            "extensions.in.md",
            "code-chrome.fixture.md",
            "full-spec-visual.fixture.md",
            "ordered-numbering.in.md",
            "task-permutations.fixture.md",
            "soft-breaks.in.md",
            "tables.in.md",
        ]

        let profiles: [DefaultsProfile] = [.gfmDefault, .kernExtensions]
        let appearances: [(String, NSAppearance?)] = [
            ("light", .init(named: .aqua)),
            ("dark", .init(named: .darkAqua)),
        ]
        let sizes: [(String, NSSize)] = [
            ("sm", .init(width: 700, height: 520)),
            ("lg", .init(width: 900, height: 650)),
        ]

        for profile in profiles {
            try withNativeEditorDefaults(profile: profile) {
                try withSnapshotTesting(record: snapshotRecordMode) {
                    for fixture in fixtures {
                        let loaded = try loadFixture(name: fixture)

                        for (appearanceName, appearance) in appearances {
                            applySnapshotTheme(for: appearance)
                            for (sizeName, size) in sizes {
                                let view = makeSnapshotView(
                                    fixture: loaded,
                                    size: size,
                                    appearance: appearance
                                )
                                assertSnapshot(
                                    of: view,
                                    as: snapshotImageStrategy(size: view.bounds.size),
                                    named: "\(profile)_\(fixture)_\(appearanceName)_\(sizeName)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Snapshot gating

    private var snapshotRecordMode: SnapshotTestingConfiguration.Record {
        TestGates.recordSnapshots ? .all : .never
    }

    /// SnapshotTesting's default AppKit image diff can report false mismatches for attachment-heavy
    /// fixtures when PNG encoders choose different row filters or AppKit re-decodes identical pixels
    /// through different color paths. Keep the recorded artifact as PNG, but compare decoded RGBA
    /// bytes first so metadata/filter-only differences do not fail the release gate.
    private struct SnapshotPNG {
        let image: NSImage
        let data: Data
    }

    private func snapshotImageStrategy(size: CGSize) -> Snapshotting<NSView, SnapshotPNG> {
        return Snapshotting<NSView, SnapshotPNG>(
            pathExtension: "png",
            diffing: normalizedImageDiffing()
        ) { view in
            let image: NSImage
            if Thread.isMainThread {
                image = MainActor.assumeIsolated {
                    Self.renderSnapshotImage(view: view, size: size)
                }
            } else {
                var rendered: NSImage?
                DispatchQueue.main.sync {
                    rendered = MainActor.assumeIsolated {
                        Self.renderSnapshotImage(view: view, size: size)
                    }
                }
                image = rendered ?? NSImage(size: size)
            }

            let normalized = Self.normalizedSnapshotImage(image)
            return SnapshotPNG(
                image: normalized,
                data: Self.pngData(for: normalized) ?? Data()
            )
        }
    }

    @MainActor
    private static func renderSnapshotImage(view: NSView, size: CGSize) -> NSImage {
        let initialSize = view.frame.size
        let scale: CGFloat = 2
        let renderSize = NSSize(
            width: max(1, size.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, size.height.rounded(.toNearestOrAwayFromZero))
        )
        view.frame.size = renderSize
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        let pixelsWide = max(1, Int((renderSize.width * scale).rounded(.toNearestOrAwayFromZero)))
        let pixelsHigh = max(1, Int((renderSize.height * scale).rounded(.toNearestOrAwayFromZero)))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        else {
            view.frame.size = initialSize
            return NSImage(size: renderSize)
        }

        bitmap.size = renderSize
        view.cacheDisplay(in: view.bounds, to: bitmap)
        view.frame.size = initialSize

        let image = NSImage(size: renderSize)
        image.addRepresentation(bitmap)
        return image
    }

    private func normalizedImageDiffing() -> Diffing<SnapshotPNG> {
        let imageDiffing = Diffing<NSImage>.image
        return Diffing<SnapshotPNG>(
            toData: { $0.data },
            fromData: { data in
                SnapshotPNG(
                    image: imageDiffing.fromData(data),
                    data: data
                )
            },
            diff: { old, new in
                if let oldPixels = Self.decodedRGBA8PNGPixelData(old.data),
                   let newPixels = Self.decodedRGBA8PNGPixelData(new.data) {
                    guard oldPixels.width == newPixels.width,
                          oldPixels.height == newPixels.height else {
                        return (
                            "Newly-taken snapshot@\(new.image.size) does not match reference@\(old.image.size).",
                            []
                        )
                    }
                    if oldPixels.data == newPixels.data {
                        return nil
                    }
                    if Self.snapshotPixelDataIsWithinEncodingNoiseTolerance(oldPixels.data, newPixels.data) {
                        return nil
                    }
                }

                return imageDiffing.diff(old.image, new.image)
            }
        )
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let representation = NSBitmapImageRep(cgImage: cgImage)
        representation.size = image.size
        return representation.representation(using: .png, properties: [:])
    }

    private static func normalizedSnapshotImage(_ image: NSImage) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: cgImage.width,
                height: cgImage.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return image
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))

        guard let normalizedCGImage = context.makeImage() else {
            return image
        }

        let representation = NSBitmapImageRep(cgImage: normalizedCGImage)
        representation.size = image.size

        let normalizedImage = NSImage(size: image.size)
        normalizedImage.addRepresentation(representation)
        return normalizedImage
    }

    private static func decodedRGBA8PNGPixelData(_ pngData: Data) -> (width: Int, height: Int, data: Data)? {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard pngData.count > signature.count,
              Array(pngData.prefix(signature.count)) == signature else {
            return nil
        }

        var width = 0
        var height = 0
        var bitDepth = 0
        var colorType = 0
        var compressionMethod = 0
        var filterMethod = 0
        var interlaceMethod = 0
        var compressed = Data()
        var offset = signature.count

        func readUInt32(at index: Int) -> UInt32? {
            guard index + 4 <= pngData.count else { return nil }
            return pngData[index..<index + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }

        while offset + 12 <= pngData.count {
            guard let lengthValue = readUInt32(at: offset) else { return nil }
            let length = Int(lengthValue)
            let typeStart = offset + 4
            let dataStart = offset + 8
            let dataEnd = dataStart + length
            let chunkEnd = dataEnd + 4
            guard chunkEnd <= pngData.count else { return nil }

            let type = String(decoding: pngData[typeStart..<typeStart + 4], as: UTF8.self)
            let chunkData = pngData[dataStart..<dataEnd]
            switch type {
            case "IHDR":
                guard length == 13,
                      let parsedWidth = readUInt32(at: dataStart),
                      let parsedHeight = readUInt32(at: dataStart + 4) else {
                    return nil
                }
                width = Int(parsedWidth)
                height = Int(parsedHeight)
                bitDepth = Int(pngData[dataStart + 8])
                colorType = Int(pngData[dataStart + 9])
                compressionMethod = Int(pngData[dataStart + 10])
                filterMethod = Int(pngData[dataStart + 11])
                interlaceMethod = Int(pngData[dataStart + 12])
            case "IDAT":
                compressed.append(contentsOf: chunkData)
            case "IEND":
                offset = pngData.count
                continue
            default:
                break
            }

            offset = chunkEnd
        }

        guard width > 0,
              height > 0,
              bitDepth == 8,
              colorType == 6,
              compressionMethod == 0,
              filterMethod == 0,
              interlaceMethod == 0,
              !compressed.isEmpty else {
            return nil
        }

        let bytesPerPixel = 4
        let rowByteCount = width * bytesPerPixel
        let filteredRowByteCount = rowByteCount + 1
        let filteredByteCount = filteredRowByteCount * height
        var filtered = Data(count: filteredByteCount)
        var decodedByteCount = UInt(filteredByteCount)
        let zlibStatus = filtered.withUnsafeMutableBytes { dstBuffer -> Int32 in
            compressed.withUnsafeBytes { srcBuffer -> Int32 in
                guard let dst = dstBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let src = srcBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return 0
                }
                return zlibUncompress(
                    dst,
                    &decodedByteCount,
                    src,
                    UInt(compressed.count)
                )
            }
        }
        guard zlibStatus == 0,
              Int(decodedByteCount) == filteredByteCount else {
            return nil
        }

        var pixels = Data(count: rowByteCount * height)
        let success = filtered.withUnsafeBytes { filteredBuffer -> Bool in
            pixels.withUnsafeMutableBytes { pixelBuffer -> Bool in
                guard let src = filteredBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let dst = pixelBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return false
                }

                for row in 0..<height {
                    let filter = src[row * filteredRowByteCount]
                    let sourceRowStart = row * filteredRowByteCount + 1
                    let destRowStart = row * rowByteCount
                    let previousRowStart = destRowStart - rowByteCount

                    for index in 0..<rowByteCount {
                        let raw = src[sourceRowStart + index]
                        let left = index >= bytesPerPixel ? dst[destRowStart + index - bytesPerPixel] : 0
                        let up = row > 0 ? dst[previousRowStart + index] : 0
                        let upLeft = row > 0 && index >= bytesPerPixel ? dst[previousRowStart + index - bytesPerPixel] : 0
                        let reconstructed: UInt8
                        switch filter {
                        case 0:
                            reconstructed = raw
                        case 1:
                            reconstructed = raw &+ left
                        case 2:
                            reconstructed = raw &+ up
                        case 3:
                            reconstructed = raw &+ UInt8((UInt16(left) + UInt16(up)) / 2)
                        case 4:
                            reconstructed = raw &+ paethPredictor(left: left, up: up, upLeft: upLeft)
                        default:
                            return false
                        }
                        dst[destRowStart + index] = reconstructed
                    }
                }

                return true
            }
        }

        return success ? (width: width, height: height, data: pixels) : nil
    }

    private static func paethPredictor(left: UInt8, up: UInt8, upLeft: UInt8) -> UInt8 {
        let a = Int(left)
        let b = Int(up)
        let c = Int(upLeft)
        let p = a + b - c
        let pa = abs(p - a)
        let pb = abs(p - b)
        let pc = abs(p - c)
        if pa <= pb && pa <= pc {
            return left
        }
        if pb <= pc {
            return up
        }
        return upLeft
    }

    private static func snapshotPixelDataIsWithinEncodingNoiseTolerance(_ old: Data, _ new: Data) -> Bool {
        guard old.count == new.count else { return false }

        var differentByteCount = 0
        var maxChannelDelta = 0
        let limit = max(1, Int(Double(old.count) * 0.0002))

        let isWithinTolerance = old.withUnsafeBytes { oldBuffer in
            new.withUnsafeBytes { newBuffer in
                guard let oldBase = oldBuffer.bindMemory(to: UInt8.self).baseAddress,
                      let newBase = newBuffer.bindMemory(to: UInt8.self).baseAddress else {
                    return false
                }

                for index in 0..<old.count {
                    let delta = abs(Int(oldBase[index]) - Int(newBase[index]))
                    if delta != 0 {
                        differentByteCount += 1
                        maxChannelDelta = max(maxChannelDelta, delta)
                    }
                    if differentByteCount > limit || maxChannelDelta > 2 {
                        return false
                    }
                }
                return true
            }
        }

        return isWithinTolerance
    }

    // MARK: - Defaults profiles

    private enum DefaultsProfile {
        case gfmDefault
        case kernExtensions
    }

    private func withNativeEditorDefaults(profile: DefaultsProfile, _ f: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let keys = [
            "nativeEditor.exportDialect",
            "nativeEditor.gfmExtensionExportStrategy",
            "nativeEditor.taskRendering",
            "nativeEditor.orderedTasksEnabled",
            "nativeEditor.headingCheckboxesEnabled",
            "nativeEditor.orderedListNumbering",
            NativeEditorSyntaxVisibilityMode.userDefaultsKey,
            "nativeEditor.mermaidRenderMode",
            "nativeEditor.checkboxHitTarget",
            "nativeEditor.syntaxHighlightingEnabled",
            "nativeEditor.paragraphBlockSeparationEnabled",
            "nativeEditor.headingOutlineVisible",
            NativeEditorAppearance.themeModeKey,
            NativeEditorAppearance.customThemeJSONKey,
            NativeEditorAppearance.fontFamilyKey,
            NativeEditorAppearance.customFontFamilyKey,
            NativeEditorAppearance.fontDesignKey,
            NativeEditorAppearance.fontSizeKey,
            NativeEditorAppearance.tableOverflowModeKey,
            NativeEditorAppearance.readableWidthModeKey,
            NativeEditorAppearance.readableMaxWidthKey,
            MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey,
        ]

        let previous: [String: Any?] = keys.reduce(into: [:]) { acc, k in
            acc[k] = defaults.object(forKey: k)
        }
        defer {
            for k in keys {
                if let v = previous[k] {
                    defaults.set(v, forKey: k)
                } else {
                    defaults.removeObject(forKey: k)
                }
            }
        }

        switch profile {
        case .gfmDefault:
            defaults.set("gfm", forKey: "nativeEditor.exportDialect")
            defaults.set("preserve", forKey: "nativeEditor.gfmExtensionExportStrategy")
            defaults.set("gfm", forKey: "nativeEditor.taskRendering")
            defaults.set(false, forKey: "nativeEditor.orderedTasksEnabled")
            defaults.set(false, forKey: "nativeEditor.headingCheckboxesEnabled")
            defaults.set("gfmDefault", forKey: "nativeEditor.orderedListNumbering")
            defaults.set(NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue, forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
            defaults.set("rich", forKey: "nativeEditor.mermaidRenderMode")
            defaults.set("glyph", forKey: "nativeEditor.checkboxHitTarget")
            defaults.set(true, forKey: "nativeEditor.syntaxHighlightingEnabled")
            defaults.set(true, forKey: "nativeEditor.paragraphBlockSeparationEnabled")
            defaults.set(false, forKey: "nativeEditor.headingOutlineVisible")
            defaults.set(NativeEditorThemeMode.system.rawValue, forKey: NativeEditorAppearance.themeModeKey)
            defaults.removeObject(forKey: NativeEditorAppearance.customThemeJSONKey)
            defaults.set(NativeEditorFontFamilyPreset.system.rawValue, forKey: NativeEditorAppearance.fontFamilyKey)
            defaults.removeObject(forKey: NativeEditorAppearance.customFontFamilyKey)
            defaults.set(NativeEditorFontDesign.system.rawValue, forKey: NativeEditorAppearance.fontDesignKey)
            defaults.set(16, forKey: NativeEditorAppearance.fontSizeKey)
            defaults.set(NativeEditorTableOverflowMode.wrap.rawValue, forKey: NativeEditorAppearance.tableOverflowModeKey)
            defaults.set(NativeEditorReadableWidthMode.fullWidth.rawValue, forKey: NativeEditorAppearance.readableWidthModeKey)
            defaults.set(NativeEditorAppearance.defaultReadableMaxWidth, forKey: NativeEditorAppearance.readableMaxWidthKey)
            defaults.set(false, forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey)
        case .kernExtensions:
            defaults.set("kern", forKey: "nativeEditor.exportDialect")
            defaults.set("preserve", forKey: "nativeEditor.gfmExtensionExportStrategy")
            defaults.set("kern", forKey: "nativeEditor.taskRendering")
            defaults.set(true, forKey: "nativeEditor.orderedTasksEnabled")
            defaults.set(true, forKey: "nativeEditor.headingCheckboxesEnabled")
            defaults.set("preserveTyped", forKey: "nativeEditor.orderedListNumbering")
            defaults.set(NativeEditorSyntaxVisibilityMode.wysiwyg.rawValue, forKey: NativeEditorSyntaxVisibilityMode.userDefaultsKey)
            defaults.set("rich", forKey: "nativeEditor.mermaidRenderMode")
            defaults.set("glyph", forKey: "nativeEditor.checkboxHitTarget")
            defaults.set(true, forKey: "nativeEditor.syntaxHighlightingEnabled")
            defaults.set(true, forKey: "nativeEditor.paragraphBlockSeparationEnabled")
            defaults.set(false, forKey: "nativeEditor.headingOutlineVisible")
            defaults.set(NativeEditorThemeMode.system.rawValue, forKey: NativeEditorAppearance.themeModeKey)
            defaults.removeObject(forKey: NativeEditorAppearance.customThemeJSONKey)
            defaults.set(NativeEditorFontFamilyPreset.system.rawValue, forKey: NativeEditorAppearance.fontFamilyKey)
            defaults.removeObject(forKey: NativeEditorAppearance.customFontFamilyKey)
            defaults.set(NativeEditorFontDesign.system.rawValue, forKey: NativeEditorAppearance.fontDesignKey)
            defaults.set(16, forKey: NativeEditorAppearance.fontSizeKey)
            defaults.set(NativeEditorTableOverflowMode.wrap.rawValue, forKey: NativeEditorAppearance.tableOverflowModeKey)
            defaults.set(NativeEditorReadableWidthMode.fullWidth.rawValue, forKey: NativeEditorAppearance.readableWidthModeKey)
            defaults.set(NativeEditorAppearance.defaultReadableMaxWidth, forKey: NativeEditorAppearance.readableMaxWidthKey)
            defaults.set(false, forKey: MarkdownImageAttachment.remoteImageLoadingUserDefaultsKey)
        }

        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)

        try f()
    }

    @MainActor
    private func applySnapshotTheme(for appearance: NSAppearance?) {
        let theme: NativeEditorThemeMode
        if let appearance,
           appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            theme = .kernDark
        } else {
            theme = .kernLight
        }
        UserDefaults.standard.set(theme.rawValue, forKey: NativeEditorAppearance.themeModeKey)
        NotificationCenter.default.post(name: .nativeEditorPreferencesDidChange, object: nil)
    }

    // MARK: - Fixtures

    private func loadFixture(name: String) throws -> (url: URL, markdown: String) {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // KernTests/
            .deletingLastPathComponent() // repo root
        let url = root.appendingPathComponent("test-fixtures/native-editor-golden", isDirectory: true)
            .appendingPathComponent(name)
        return (url: url, markdown: try String(contentsOf: url, encoding: .utf8))
    }

    // MARK: - Hosting

    @MainActor
    private func hostInWindow(vc: NSViewController, size: NSSize, appearance: NSAppearance?) -> NSView {
        let rect = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: rect, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.windowBackgroundColor
        window.appearance = appearance
        window.contentViewController = vc

        // Snapshot the window's content view (includes background + padding).
        let content = window.contentView ?? vc.view
        if let appearance {
            applyAppearance(appearance, to: content)
        }

        // SnapshotTesting captures the NSView image directly. Since our editor surface is transparent
        // (real app background comes from the window), enforce a solid backing color here so baselines
        // are deterministic and don't appear as "blank black" transparent PNGs.
        content.wantsLayer = true
        content.layer?.backgroundColor = resolvedWindowBackgroundColor(for: appearance).cgColor

        // Force layout.
        window.setFrame(rect, display: true)
        window.layoutIfNeeded()
        content.setFrameSize(size)
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        return content
    }

    @MainActor
    private func makeSnapshotView(
        fixture: (url: URL, markdown: String),
        size: NSSize,
        appearance: NSAppearance?
    ) -> NSView {
        let vc = NativeEditorViewController()
        _ = vc.view
        let view = hostInWindow(vc: vc, size: size, appearance: appearance)

        vc.documentURL = fixture.url
        vc.stringValue = fixture.markdown

        settleSnapshotView(view)
        return view
    }

    @MainActor
    private func settleSnapshotView(_ view: NSView) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        let textView = findSubview(withAXIdentifier: "NativeEditor.TextView", in: view) as? NSTextView
        if let textView {
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        }

        if let scrollView = findSubview(withAXIdentifier: "NativeEditor.ScrollView", in: view) as? NSScrollView {
            let clip = scrollView.contentView
            clip.scroll(to: .zero)
            scrollView.reflectScrolledClipView(clip)
        }

        waitForSnapshotRenderStability(in: view, textView: textView)

        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
    }

    @MainActor
    private func waitForSnapshotRenderStability(in view: NSView, textView: NSTextView?) {
        struct Signature: Equatable {
            let attachmentCount: Int
            let attachmentsWithCell: Int
            let localImageCount: Int
            let pendingLocalImageCount: Int
            let documentHeight: CGFloat
        }

        func signature(for textView: NSTextView?) -> Signature {
            guard let textView,
                  let storage = textView.textStorage else {
                return Signature(
                    attachmentCount: 0,
                    attachmentsWithCell: 0,
                    localImageCount: 0,
                    pendingLocalImageCount: 0,
                    documentHeight: 0
                )
            }

            var attachmentCount = 0
            var attachmentsWithCell = 0
            var localImageCount = 0
            var pendingLocalImageCount = 0
            storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                attachmentCount += 1
                if attachment.attachmentCell != nil {
                    attachmentsWithCell += 1
                }
                if let imageAttachment = attachment as? MarkdownImageAttachment,
                   imageAttachment.resolvedURL?.isFileURL == true {
                    localImageCount += 1
                    if !imageAttachment.debugHasRenderedImage,
                       imageAttachment.loadState == .loading {
                        pendingLocalImageCount += 1
                    }
                }
            }

            let documentHeight: CGFloat
            if let scrollView = textView.enclosingScrollView {
                documentHeight = scrollView.documentView?.bounds.height ?? 0
            } else {
                documentHeight = textView.bounds.height
            }

            return Signature(
                attachmentCount: attachmentCount,
                attachmentsWithCell: attachmentsWithCell,
                localImageCount: localImageCount,
                pendingLocalImageCount: pendingLocalImageCount,
                documentHeight: documentHeight
            )
        }

        let deadline = Date().addingTimeInterval(1.2)
        var previous: Signature?
        var stableTicks = 0
        var localImagesReadyAt: Date?

        while Date() < deadline {
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()

            let current = signature(for: textView)
            if current.pendingLocalImageCount > 0 {
                localImagesReadyAt = nil
                previous = current
                stableTicks = 0
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                continue
            }
            if current.localImageCount > 0, localImagesReadyAt == nil {
                localImagesReadyAt = Date()
            }
            if current == previous {
                stableTicks += 1
            } else {
                stableTicks = 0
                previous = current
            }

            if let localImagesReadyAt,
               Date().timeIntervalSince(localImagesReadyAt) < 0.18 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                continue
            }

            let requiredStableTicks = current.localImageCount > 0 ? 4 : 2
            if stableTicks >= requiredStableTicks {
                if current.attachmentCount > 0 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                    view.layoutSubtreeIfNeeded()
                    view.displayIfNeeded()
                }
                return
            }

            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    @MainActor
    private func applyAppearance(_ appearance: NSAppearance, to view: NSView) {
        view.appearance = appearance
        for sub in view.subviews {
            applyAppearance(appearance, to: sub)
        }
    }

    @MainActor
    private func resolvedWindowBackgroundColor(for appearance: NSAppearance?) -> NSColor {
        if let appearance, appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(calibratedWhite: 0.11, alpha: 1.0)
        }
        return NSColor(calibratedWhite: 0.97, alpha: 1.0)
    }

    @MainActor
    private func findSubview(withAXIdentifier id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for sub in view.subviews {
            if let found = findSubview(withAXIdentifier: id, in: sub) {
                return found
            }
        }
        return nil
    }

    @MainActor
    private static func resetGlobalAppKitSnapshotState() {
        NativeMarkdownCodec.resetCachesForTesting()
        MarkdownImageAttachment.resetImageCacheForTesting()
        for window in NSApp.windows {
            window.orderOut(nil)
            window.close()
        }
        NSApp.appearance = nil
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}
