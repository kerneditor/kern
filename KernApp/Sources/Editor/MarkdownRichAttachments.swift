import AppKit
import CryptoKit
import Darwin
import Foundation
import ImageIO

final class MarkdownImageAttachment: NSTextAttachment {
    enum LoadState {
        case loading
        case ready
        case failed
    }

    nonisolated static let remoteImageLoadingUserDefaultsKey = "nativeEditor.remoteImageLoadingEnabled"
    private nonisolated(unsafe) static let remoteResponseMaxBytes = 20 * 1024 * 1024
    private nonisolated(unsafe) static let defaultMaxDecodedPixelCount = 40_000_000
    private nonisolated(unsafe) static let defaultMaxDecodedDimension = 12_000

    let altText: String
    let destination: String
    let sourceMarkdown: String
    let resolvedURL: URL?
    let allowsRemoteLoading: Bool

    private(set) var renderedImage: NSImage?
    private(set) var loadState: LoadState = .loading

    private var displayWidthLimit: CGFloat = 520
    private weak var hostView: NSView?
    private var isLoading = false
    private var needsLayoutRefreshWhenHostViewBinds = false

    nonisolated(unsafe) private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.name = "com.gradigit.kern.markdown-image-cache"
        // Bound image-memory growth across long editing sessions.
        cache.totalCostLimit = 128 * 1024 * 1024 // 128 MB
        cache.countLimit = 256
        return cache
    }()

    nonisolated(unsafe) private static var remoteImageSession: URLSession = {
        makeRemoteImageSession()
    }()

    nonisolated(unsafe) private static var remoteImageProtocolClassesOverride: [AnyClass]?
    nonisolated(unsafe) private static var maxDecodedPixelCount = defaultMaxDecodedPixelCount
    nonisolated(unsafe) private static var maxDecodedDimension = defaultMaxDecodedDimension

    private static func makeRemoteImageSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
        configuration.urlCredentialStorage = nil
        configuration.protocolClasses = remoteImageProtocolClassesOverride
        return URLSession(configuration: configuration)
    }

    static func resetImageCacheForTesting() {
        cache.removeAllObjects()
    }

    static func configureRemoteImageProtocolClassesForTesting(_ classes: [AnyClass]?) {
        remoteImageSession.invalidateAndCancel()
        remoteImageProtocolClassesOverride = classes
        remoteImageSession = makeRemoteImageSession()
    }

    static func configureDecodeLimitsForTesting(maxPixelCount: Int? = nil, maxDimension: Int? = nil) {
        Self.maxDecodedPixelCount = maxPixelCount ?? defaultMaxDecodedPixelCount
        Self.maxDecodedDimension = maxDimension ?? defaultMaxDecodedDimension
    }

    init(
        altText: String,
        destination: String,
        sourceMarkdown: String,
        baseURL: URL?,
        allowsRemoteLoading: Bool
    ) {
        self.altText = altText
        self.destination = destination
        self.sourceMarkdown = sourceMarkdown
        self.resolvedURL = MarkdownImageAttachment.resolveURL(destination: destination, baseURL: baseURL)
        self.allowsRemoteLoading = allowsRemoteLoading
        super.init(data: nil, ofType: nil)
        let cell = MarkdownImageAttachmentCell()
        cell.attachment = self
        self.attachmentCell = cell
        loadImageIfNeeded()
    }

    required init?(coder: NSCoder) {
        self.altText = ""
        self.destination = ""
        self.sourceMarkdown = ""
        self.resolvedURL = nil
        self.allowsRemoteLoading = false
        super.init(coder: coder)
        let cell = MarkdownImageAttachmentCell()
        cell.attachment = self
        self.attachmentCell = cell
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let widthSource = textContainer?.containerSize.width ?? lineFrag.width
        let containerWidth = max(220, min(900, widthSource - 8))
        // Remote placeholders often include large text; cap their rendered width lower so they
        // stay visually balanced in-document.
        let maxVisualWidth: CGFloat = isRemoteURL ? 560 : 760
        let maxWidth = min(containerWidth, maxVisualWidth)
        displayWidthLimit = maxWidth

        if let image = renderedImage, image.size.width > 0, image.size.height > 0 {
            let maxHeight: CGFloat = 420
            let ratio = min(1, maxWidth / image.size.width, maxHeight / image.size.height)
            let w = max(100, floor(image.size.width * ratio))
            let h = max(48, floor(image.size.height * ratio))
            let captionHeight: CGFloat = altText.isEmpty ? 0 : 18
            return NSRect(x: 0, y: -4, width: w, height: h + captionHeight + 8)
        }

        // Placeholder / error frame.
        let w = min(maxWidth, 360)
        let h: CGFloat = altText.isEmpty ? 84 : 98
        return NSRect(x: 0, y: -4, width: w, height: h)
    }

    var debugHasRenderedImage: Bool {
        renderedImage != nil
    }

    private var isRemoteURL: Bool {
        guard let resolvedURL, let scheme = resolvedURL.scheme?.lowercased() else { return false }
        if resolvedURL.isFileURL { return false }
        return scheme == "http" || scheme == "https"
    }

    private func loadImageIfNeeded() {
        guard !isLoading, renderedImage == nil else { return }
        guard let url = resolvedURL else {
            loadState = .failed
            return
        }

        // Respect remote-loading preference even if the URL was previously cached.
        // Disabled means no remote fetches and no reuse of remote cache entries.
        if isRemoteURL, !allowsRemoteLoading {
            loadState = .failed
            requestDisplayUpdate()
            return
        }

        if let cached = Self.cache.object(forKey: url as NSURL) {
            renderedImage = cached
            loadState = .ready
            requestDisplayUpdate()
            return
        }

        if url.isFileURL {
            isLoading = true
            loadState = .loading
            let fileURL = url
            DispatchQueue.global(qos: .userInitiated).async {
                let image = Self.validatedImage(fromFileURL: fileURL)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isLoading = false
                    if let image {
                        let cost = Self.estimatedImageCostBytes(image)
                        Self.cache.setObject(image, forKey: fileURL as NSURL, cost: cost)
                        self.renderedImage = image
                        self.loadState = .ready
                    } else {
                        self.loadState = .failed
                    }
                    self.requestDisplayUpdate()
                }
            }
            return
        }

        isLoading = true
        loadState = .loading

        let req = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        Self.remoteImageSession.dataTask(with: req) { data, response, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoading = false

                guard error == nil,
                      let data,
                      let response = response as? HTTPURLResponse,
                      Self.remoteResponseLooksSafe(response: response, data: data),
                      let image = Self.validatedImage(fromRemoteData: data)
                else {
                    self.loadState = .failed
                    self.requestDisplayUpdate()
                    return
                }

                let cost = Self.estimatedImageCostBytes(image)
                Self.cache.setObject(image, forKey: url as NSURL, cost: cost)
                self.renderedImage = image
                self.loadState = .ready
                self.requestDisplayUpdate()
            }
        }.resume()
    }

    private static func remoteResponseLooksSafe(response: HTTPURLResponse, data: Data) -> Bool {
        guard (200..<300).contains(response.statusCode) else { return false }
        if let mimeType = response.mimeType?.lowercased(), !mimeType.hasPrefix("image/") {
            return false
        }
        if let contentLength = response.value(forHTTPHeaderField: "Content-Length"),
           let bytes = Int(contentLength),
           bytes > remoteResponseMaxBytes {
            return false
        }
        return data.count <= remoteResponseMaxBytes
    }

    private static func validatedImage(fromFileURL fileURL: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              imageSourceLooksSafe(source)
        else {
            return nil
        }
        return makeImage(from: source)
    }

    private static func validatedImage(fromRemoteData data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              imageSourceLooksSafe(source)
        else {
            return nil
        }
        return makeImage(from: source)
    }

    private static func imageSourceLooksSafe(_ source: CGImageSource) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0
        else {
            return false
        }

        guard width <= maxDecodedDimension, height <= maxDecodedDimension else { return false }
        let pixelCount = Int64(width) * Int64(height)
        return pixelCount > 0 && pixelCount <= Int64(maxDecodedPixelCount)
    }

    private static func makeImage(from source: CGImageSource) -> NSImage? {
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private func requestDisplayUpdate() {
        guard hostView != nil else {
            needsLayoutRefreshWhenHostViewBinds = true
            return
        }
        performSelector(onMainThread: #selector(requestDisplayUpdateOnMainThread), with: nil, waitUntilDone: false)
    }

    @objc
    @MainActor
    private func requestDisplayUpdateOnMainThread() {
        guard let hostView else { return }
        hostView.needsDisplay = true
        guard let textView = hostView as? NSTextView,
              let lm = textView.layoutManager,
              let tc = textView.textContainer,
              let storage = textView.textStorage else { return }

        let shouldForceContiguousSmallDocumentLayout = storage.length <= 12_000
        let previousAllowsNonContiguousLayout = lm.allowsNonContiguousLayout
        if shouldForceContiguousSmallDocumentLayout {
            lm.allowsNonContiguousLayout = false
        }
        defer {
            if shouldForceContiguousSmallDocumentLayout {
                lm.allowsNonContiguousLayout = previousAllowsNonContiguousLayout
            }
        }

        let fullRange = NSRange(location: 0, length: storage.length)
        var attachmentRanges: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? MarkdownImageAttachment,
                  attachment === self else { return }
            attachmentRanges.append(range)
        }

        if attachmentRanges.isEmpty {
            attachmentRanges = [fullRange]
        }

        for range in attachmentRanges {
            lm.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.invalidateDisplay(forGlyphRange: glyphRange)
            storage.edited(.editedAttributes, range: range, changeInLength: 0)
        }

        lm.ensureLayout(for: tc)
        textView.invalidateIntrinsicContentSize()
        textView.layoutSubtreeIfNeeded()
        textView.enclosingScrollView?.layoutSubtreeIfNeeded()
        let visibleRectInContainer = textView.visibleRect.offsetBy(
            dx: -textView.textContainerOrigin.x,
            dy: -textView.textContainerOrigin.y
        )
        let visibleGlyphRange = lm.glyphRange(forBoundingRect: visibleRectInContainer, in: tc)
        lm.invalidateDisplay(forGlyphRange: visibleGlyphRange)
    }

    fileprivate func didDraw(in view: NSView?) {
        if let view {
            let didBindNewHostView = hostView == nil || hostView !== view
            hostView = view
            if didBindNewHostView, needsLayoutRefreshWhenHostViewBinds {
                needsLayoutRefreshWhenHostViewBinds = false
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(requestDisplayUpdateOnMainThread), object: nil)
                perform(#selector(requestDisplayUpdateOnMainThread), with: nil, afterDelay: 0)
            }
        }
    }

    fileprivate func drawAttachmentContents(in frame: NSRect) {
        let background = NSBezierPath(roundedRect: frame, xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
        background.fill()
        NSColor.separatorColor.withAlphaComponent(0.8).setStroke()
        background.lineWidth = 1
        background.stroke()

        switch loadState {
        case .ready:
            drawLoadedImage(in: frame)
        case .loading:
            drawPlaceholder(
                in: frame,
                title: "Loading image",
                subtitle: altText.isEmpty ? destination : altText
            )
        case .failed:
            drawPlaceholder(
                in: frame,
                title: "Image unavailable",
                subtitle: altText.isEmpty ? destination : altText
            )
        }
    }

    private func drawLoadedImage(in frame: NSRect) {
        guard let image = renderedImage, image.size.width > 0, image.size.height > 0 else {
            drawPlaceholder(in: frame, title: "Image unavailable", subtitle: altText)
            return
        }

        let captionHeight: CGFloat = altText.isEmpty ? 0 : 18
        let imageRect = NSRect(
            x: frame.minX + 4,
            y: frame.minY + 4 + captionHeight,
            width: frame.width - 8,
            height: frame.height - 8 - captionHeight
        )
        let fittedImageRect = Self.aspectFitRect(for: image.size, in: imageRect)
        image.draw(in: fittedImageRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true, hints: nil)

        if !altText.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
            let textRect = NSRect(
                x: frame.minX + 8,
                y: frame.minY + 4,
                width: frame.width - 16,
                height: captionHeight - 2
            )
            (altText as NSString).draw(in: textRect, withAttributes: attrs)
        }
    }

    private func drawPlaceholder(in frame: NSRect, title: String, subtitle: String) {
        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let subtitleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let clippedSubtitle = subtitle.isEmpty ? "" : subtitle
        let titleRect = NSRect(x: frame.minX + 10, y: frame.midY - 4, width: frame.width - 20, height: 18)
        let subtitleRect = NSRect(x: frame.minX + 10, y: frame.midY - 20, width: frame.width - 20, height: 16)

        (title as NSString).draw(in: titleRect, withAttributes: titleAttrs)
        if !clippedSubtitle.isEmpty {
            (clippedSubtitle as NSString).draw(in: subtitleRect, withAttributes: subtitleAttrs)
        }
    }

    private static func aspectFitRect(for imageSize: CGSize, in targetRect: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, targetRect.width > 0, targetRect.height > 0 else {
            return targetRect
        }
        let scale = min(targetRect.width / imageSize.width, targetRect.height / imageSize.height)
        let fittedWidth = imageSize.width * scale
        let fittedHeight = imageSize.height * scale
        return NSRect(
            x: targetRect.midX - (fittedWidth / 2),
            y: targetRect.midY - (fittedHeight / 2),
            width: fittedWidth,
            height: fittedHeight
        ).integral
    }

    private static func resolveURL(destination: String, baseURL: URL?) -> URL? {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            guard let scheme = absolute.scheme?.lowercased() else { return nil }
            if absolute.isFileURL {
                return nil
            }
            guard scheme == "http" || scheme == "https" else {
                return nil
            }
            return absolute
        }

        let unescaped = trimmed.removingPercentEncoding ?? trimmed
        let path = NSString(string: unescaped)

        if unescaped.hasPrefix("~") || path.isAbsolutePath {
            return nil
        }

        if let baseDirectory = trustedAttachmentBaseDirectory(baseURL: baseURL) {
            let resolved = baseDirectory.appendingPathComponent(unescaped).standardizedFileURL
            if isContainedWithinTrustedBase(resolved, baseDirectory: baseDirectory) {
                return resolved
            }
        }

        return nil
    }

    private static func trustedAttachmentBaseDirectory(baseURL: URL?) -> URL? {
        guard let baseURL, baseURL.isFileURL else { return nil }
        if baseURL.hasDirectoryPath {
            return baseURL.standardizedFileURL
        }
        return baseURL.deletingLastPathComponent().standardizedFileURL
    }

    private static func isContainedWithinTrustedBase(_ url: URL, baseDirectory: URL) -> Bool {
        let basePath = resolvedTrustedLocalPath(baseDirectory)
        let candidatePath = resolvedTrustedLocalPath(url)
        if candidatePath == basePath { return true }
        return candidatePath.hasPrefix(basePath.hasSuffix("/") ? basePath : basePath + "/")
    }

    private static func resolvedTrustedLocalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Estimate decoded RGBA memory footprint so NSCache can evict by memory pressure.
    private static func estimatedImageCostBytes(_ image: NSImage) -> Int {
        let bitmapReps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let rep = bitmapReps.max(by: { ($0.pixelsWide * $0.pixelsHigh) < ($1.pixelsWide * $1.pixelsHigh) }) {
            let bytesPerPixel = max(4, rep.bitsPerPixel / 8)
            let rowBytes = max(1, rep.bytesPerRow > 0 ? rep.bytesPerRow : rep.pixelsWide * bytesPerPixel)
            let total = Int64(rowBytes) * Int64(max(1, rep.pixelsHigh))
            return Int(max(1, min(total, Int64(Int.max))))
        }

        // Fallback when bitmap metadata is unavailable.
        let width = Int(max(1, ceil(image.size.width)))
        let height = Int(max(1, ceil(image.size.height)))
        let total = Int64(width) * Int64(height) * 4
        return Int(max(1, min(total, Int64(Int.max))))
    }
}

private final class MarkdownImageAttachmentCell: NSTextAttachmentCell {
    private var lastObservedLineFragmentMinY: CGFloat?

    override init() {
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func cellFrame(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard let attachment = attachment as? MarkdownImageAttachment else {
            let w = max(1, min(900, lineFrag.width))
            return NSRect(x: 0, y: 0, width: w, height: 96)
        }
        let bounds = attachment.attachmentBounds(
            for: textContainer,
            proposedLineFragment: lineFrag,
            glyphPosition: position,
            characterIndex: charIndex
        )
        lastObservedLineFragmentMinY = max(lastObservedLineFragmentMinY ?? -.greatestFiniteMagnitude, lineFrag.minY)
        return NSRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        drawAttachmentImage(attachment as? MarkdownImageAttachment, frame: cellFrame, in: controlView)
    }

    override func draw(
        withFrame cellFrame: NSRect,
        in controlView: NSView?,
        characterIndex charIndex: Int
    ) {
        let storage = (controlView as? NSTextView)?.textStorage
        let attachment = storage.flatMap { storage -> MarkdownImageAttachment? in
            guard charIndex >= 0, charIndex < storage.length else { return nil }
            return storage.attribute(.attachment, at: charIndex, effectiveRange: nil) as? MarkdownImageAttachment
        }
        let layoutManager = (controlView as? NSTextView)?.layoutManager
        let drawFrame = attachment.flatMap {
            if layoutManager?.allowsNonContiguousLayout == true {
                return resolvedDrawFrame(
                    for: $0,
                    characterIndex: charIndex,
                    layoutManager: layoutManager,
                    controlView: controlView,
                    fallbackFrame: cellFrame
                )
            }
            return cellFrame
        } ?? cellFrame
        drawAttachmentImage(attachment, frame: drawFrame, in: controlView)
    }

    override func draw(
        withFrame cellFrame: NSRect,
        in controlView: NSView?,
        characterIndex charIndex: Int,
        layoutManager: NSLayoutManager
    ) {
        let attachment = layoutManager.textStorage?.attribute(
            .attachment,
            at: charIndex,
            effectiveRange: nil
        ) as? MarkdownImageAttachment

        let drawFrame = attachment.flatMap {
            if layoutManager.allowsNonContiguousLayout {
                return resolvedDrawFrame(
                    for: $0,
                    characterIndex: charIndex,
                    layoutManager: layoutManager,
                    controlView: controlView,
                    fallbackFrame: cellFrame
                )
            }
            return cellFrame
        } ?? cellFrame
        drawAttachmentImage(attachment, frame: drawFrame, in: controlView)
    }

    private func resolvedDrawFrame(
        for attachment: MarkdownImageAttachment,
        characterIndex charIndex: Int,
        layoutManager: NSLayoutManager?,
        controlView: NSView?,
        fallbackFrame: NSRect
    ) -> NSRect? {
        guard let layoutManager else { return nil }
        guard charIndex >= 0,
              let textStorage = layoutManager.textStorage,
              charIndex < textStorage.length
        else { return nil }

        let characterRange = NSRange(location: charIndex, length: 1)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characterRange,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0,
              let textContainer = layoutManager.textContainer(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
              )
        else { return nil }

        let lineFragment = layoutManager.lineFragmentRect(
            forGlyphAt: glyphRange.location,
            effectiveRange: nil
        )
        let glyphPosition = layoutManager.location(forGlyphAt: glyphRange.location)
        let bounds = attachment.attachmentBounds(
            for: textContainer,
            proposedLineFragment: lineFragment,
            glyphPosition: glyphPosition,
            characterIndex: charIndex
        )
        let lineY = max(lastObservedLineFragmentMinY ?? lineFragment.minY, lineFragment.minY)
        return NSRect(
            x: fallbackFrame.minX,
            y: lineY + lineFragment.height - (bounds.height / 2),
            width: bounds.width,
            height: bounds.height
        ).integral
    }

    private func drawAttachmentImage(_ attachment: MarkdownImageAttachment?, frame: NSRect, in controlView: NSView?) {
        guard let attachment else { return }
        attachment.didDraw(in: controlView)
        attachment.drawAttachmentContents(in: frame.integral)
    }
}

final class MarkdownMathBlockAttachment: NSTextAttachment {
    let sourceMarkdown: String
    let displayText: String

    private let lineHeight: CGFloat = 30
    private var displayWidth: CGFloat = 420

    init(sourceMarkdown: String) {
        self.sourceMarkdown = sourceMarkdown
        self.displayText = MathTextRenderer.renderBlockMath(from: sourceMarkdown)
        super.init(data: nil, ofType: nil)
        self.attachmentCell = MarkdownMathBlockAttachmentCell()
    }

    required init?(coder: NSCoder) {
        self.sourceMarkdown = ""
        self.displayText = ""
        super.init(coder: coder)
        self.attachmentCell = MarkdownMathBlockAttachmentCell()
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let widthSource = textContainer?.containerSize.width ?? lineFrag.width
        let finiteWidth = widthSource.isFinite && widthSource > 1 ? widthSource : lineFrag.width
        let maxWidth = max(220, min(880, finiteWidth - 8))
        displayWidth = maxWidth
        let lineCount = max(1, displayText.split(separator: "\n", omittingEmptySubsequences: false).count)
        let h = CGFloat(lineCount) * lineHeight + 34
        return NSRect(x: 0, y: -2, width: maxWidth, height: h)
    }
}

private enum MarkdownAttachmentChrome {
    static func topY(in frame: NSRect, inset: CGFloat, height: CGFloat, flipped: Bool) -> CGFloat {
        if flipped {
            return frame.minY + inset
        }
        return frame.maxY - inset - height
    }

    static func contentMinY(in frame: NSRect, topInset: CGFloat, bottomInset: CGFloat, flipped: Bool) -> CGFloat {
        if flipped {
            return frame.minY + topInset
        }
        return frame.minY + bottomInset
    }
}

private final class MarkdownMathBlockAttachmentCell: NSTextAttachmentCell {
    override init() {
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func cellFrame(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard let attachment else {
            let w = max(1, min(900, lineFrag.width))
            return NSRect(x: 0, y: 0, width: w, height: 56)
        }
        let bounds = attachment.attachmentBounds(
            for: textContainer,
            proposedLineFragment: lineFrag,
            glyphPosition: position,
            characterIndex: charIndex
        )
        return NSRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let owner = attachment as? MarkdownMathBlockAttachment else { return }
        let frame = cellFrame.integral
        let isFlipped = controlView?.isFlipped ?? true

        let bg = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        NSColor.textBackgroundColor.withAlphaComponent(0.78).setFill()
        bg.fill()
        NSColor.separatorColor.withAlphaComponent(0.70).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        let accentRect = NSRect(
            x: frame.minX + 1,
            y: frame.minY + 10,
            width: 3,
            height: max(1, frame.height - 20)
        )
        let accent = NSBezierPath(roundedRect: accentRect, xRadius: 1.5, yRadius: 1.5)
        NSColor.controlAccentColor.withAlphaComponent(0.55).setFill()
        accent.fill()

        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let badgeSize = ("MATH" as NSString).size(withAttributes: badgeAttrs)
        let badgeHeight: CGFloat = 14
        let badgeRect = NSRect(
            x: frame.maxX - badgeSize.width - 18,
            y: MarkdownAttachmentChrome.topY(in: frame, inset: 7, height: badgeHeight, flipped: isFlipped),
            width: badgeSize.width + 10,
            height: badgeHeight
        ).integral
        let badge = NSBezierPath(roundedRect: badgeRect, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
        badge.fill()
        ("MATH" as NSString).draw(
            in: NSRect(
                x: badgeRect.midX - badgeSize.width / 2,
                y: badgeRect.midY - badgeSize.height / 2,
                width: badgeSize.width,
                height: badgeSize.height
            ),
            withAttributes: badgeAttrs
        )

        let textFont = MathTextRenderer.displayFont(size: 23)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: NSColor.labelColor,
            .kern: 0.2,
        ]
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineSpacing = 2

        let textAttrs = attrs.merging([.paragraphStyle: para]) { _, rhs in rhs }
        let maxTextWidth = max(1, frame.width - 52)
        let measuredText = (owner.displayText as NSString).boundingRect(
            with: CGSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: textAttrs
        )
        let textHeight = min(max(1, ceil(measuredText.height)), max(1, frame.height - 26))
        let textRect = NSRect(
            x: frame.minX + 26,
            y: frame.midY - textHeight / 2,
            width: maxTextWidth,
            height: textHeight
        )
        (owner.displayText as NSString).draw(in: textRect, withAttributes: textAttrs)
    }
}

final class MarkdownMermaidAttachment: NSTextAttachment {
    fileprivate enum OfficialExternalRenderState: String {
        case disabled
        case cacheHit
        case rendering
        case ready
        case failed
    }

    struct Node {
        let id: String
        let label: String
    }

    struct Edge {
        let from: String
        let to: String
        let label: String?
    }

    fileprivate struct ASCIILayout {
        let lines: [String]
        let size: CGSize
        let lineHeight: CGFloat
        let font: NSFont
    }

    let sourceMarkdown: String
    nonisolated fileprivate let requestedRenderMode: NativeMarkdownCodec.Options.MermaidRenderMode
    nonisolated fileprivate let effectiveRenderMode: NativeMarkdownCodec.Options.MermaidRenderMode
    nonisolated fileprivate let kind: MermaidMiniParser.DiagramKind
    nonisolated let nodes: [Node]
    nonisolated let edges: [Edge]
    nonisolated(unsafe) private var cachedLayoutWidthKey: Int?
    nonisolated(unsafe) private var cachedLayoutResult: MermaidMiniLayout.Result?
    nonisolated(unsafe) private var cachedASCIIWidthKey: Int?
    nonisolated(unsafe) private var cachedASCIILayout: ASCIILayout?
    nonisolated(unsafe) private var officialExternalImage: NSImage?
    nonisolated(unsafe) private var officialExternalRenderState: OfficialExternalRenderState = .disabled
    nonisolated(unsafe) private var officialExternalRenderIdentity: String?
    nonisolated(unsafe) private var officialExternalRenderDidStart = false
    private weak var hostView: NSView?
    private var needsLayoutRefreshWhenHostViewBinds = false

    init(
        sourceMarkdown: String,
        requestedRenderMode: NativeMarkdownCodec.Options.MermaidRenderMode = .rich
    ) {
        self.sourceMarkdown = sourceMarkdown
        let parsed = MermaidMiniParser.parse(sourceMarkdown: sourceMarkdown)
        self.kind = parsed.kind
        self.nodes = parsed.nodes
        self.edges = parsed.edges
        self.requestedRenderMode = requestedRenderMode
        self.effectiveRenderMode = MarkdownMermaidAttachment.resolveRenderMode(
            requested: requestedRenderMode,
            kind: parsed.kind,
            nodes: parsed.nodes,
            edges: parsed.edges
        )
        super.init(data: nil, ofType: nil)
        self.attachmentCell = MarkdownMermaidAttachmentCell()
    }

    required init?(coder: NSCoder) {
        self.sourceMarkdown = ""
        self.requestedRenderMode = .rich
        self.effectiveRenderMode = .rich
        self.kind = .generic
        self.nodes = []
        self.edges = []
        super.init(coder: coder)
        self.attachmentCell = MarkdownMermaidAttachmentCell()
    }

    override func attachmentBounds(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        let widthSource = textContainer?.containerSize.width ?? lineFrag.width
        let availableWidth = max(280, min(920, widthSource - 8))
        let contentWidth = max(220, availableWidth - MermaidChromeMetrics.horizontalPadding * 2)
        let width: CGFloat
        let height: CGFloat
        if requestedRenderMode == .officialExternal {
            if let officialExternalImage, officialExternalImage.size.width > 0, officialExternalImage.size.height > 0 {
                let maxOfficialHeight: CGFloat = 640
                let imageRatio = min(1, contentWidth / officialExternalImage.size.width, maxOfficialHeight / officialExternalImage.size.height)
                let scaledHeight = max(72, ceil(officialExternalImage.size.height * imageRatio))
                return NSRect(
                    x: 0,
                    y: -2,
                    width: availableWidth,
                    height: max(
                        MermaidChromeMetrics.minimumHeight,
                        scaledHeight + MermaidChromeMetrics.topChromeHeight + MermaidChromeMetrics.bottomPadding
                    )
                )
            }
        }
        if effectiveRenderMode == .ascii {
            let layout = asciiLayout(maxContentWidth: contentWidth)
            width = availableWidth
            height = max(
                MermaidChromeMetrics.minimumHeightASCII,
                layout.size.height + MermaidChromeMetrics.topChromeHeight + MermaidChromeMetrics.bottomPadding
            )
        } else if shouldDrawSourceFallback {
            let layout = asciiLayout(maxContentWidth: contentWidth)
            width = availableWidth
            height = max(
                MermaidChromeMetrics.minimumHeightASCII,
                layout.size.height + MermaidChromeMetrics.topChromeHeight + MermaidChromeMetrics.bottomPadding
            )
        } else {
            let layout = layoutResult(maxContentWidth: contentWidth)
            width = availableWidth
            height = max(
                MermaidChromeMetrics.minimumHeight,
                layout.size.height + MermaidChromeMetrics.topChromeHeight + MermaidChromeMetrics.bottomPadding
            )
        }
        return NSRect(x: 0, y: -2, width: width, height: height)
    }

    nonisolated fileprivate func layoutResult(maxContentWidth: CGFloat) -> MermaidMiniLayout.Result {
        // Bucket widths to reduce cache churn during TextKit's iterative line-fragment probing.
        let widthBucket: CGFloat = 16
        let widthKey = max(1, Int((maxContentWidth / widthBucket).rounded()) * Int(widthBucket))
        if cachedLayoutWidthKey == widthKey, let cachedLayoutResult {
            return cachedLayoutResult
        }

        let layout = MermaidMiniLayout.layout(
            kind: kind,
            nodes: nodes,
            edges: edges,
            maxContentWidth: CGFloat(widthKey)
        )
        cachedLayoutWidthKey = widthKey
        cachedLayoutResult = layout
        return layout
    }

    nonisolated fileprivate func asciiLayout(maxContentWidth: CGFloat) -> ASCIILayout {
        let widthBucket: CGFloat = 16
        let widthKey = max(1, Int((maxContentWidth / widthBucket).rounded()) * Int(widthBucket))
        if cachedASCIIWidthKey == widthKey, let cachedASCIILayout {
            return cachedASCIILayout
        }

        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let charWidth = ceil(max(5.8, ("M" as NSString).size(withAttributes: [.font: font]).width))
        let maxChars = max(24, Int((CGFloat(widthKey) - 24) / charWidth))

        let baseLines = MermaidASCIIFormatter.lines(
            sourceMarkdown: sourceMarkdown,
            kind: kind,
            nodes: nodes,
            edges: edges,
            maxColumns: maxChars
        )
        let wrappedLines = MermaidASCIIFormatter.wrap(lines: baseLines, maxColumns: maxChars)
        let maxLineChars = max(24, wrappedLines.map(\.count).max() ?? maxChars)
        let lineHeight = max(13, ceil(NSLayoutManager().defaultLineHeight(for: font)))
        let textHeight = CGFloat(wrappedLines.count) * lineHeight
        let maxTextWidth = CGFloat(maxLineChars) * charWidth
        let size = CGSize(
            width: min(CGFloat(widthKey), maxTextWidth + 28),
            height: max(72, textHeight + 18)
        )
        let layout = ASCIILayout(lines: wrappedLines, size: size, lineHeight: lineHeight, font: font)
        cachedASCIIWidthKey = widthKey
        cachedASCIILayout = layout
        return layout
    }

    fileprivate func officialExternalImageForDrawing(maxContentWidth: CGFloat, themeIdentifier: String) -> NSImage? {
        prepareOfficialExternalRenderIfNeeded(maxContentWidth: maxContentWidth, themeIdentifier: themeIdentifier)
        return officialExternalImage
    }

    private func prepareOfficialExternalRenderIfNeeded(maxContentWidth: CGFloat, themeIdentifier: String) {
        guard requestedRenderMode == .officialExternal else { return }
        let widthBucket = MermaidOfficialExternalRenderer.widthBucket(for: maxContentWidth)
        let identity = MermaidOfficialExternalRenderer.renderIdentity(
            sourceMarkdown: sourceMarkdown,
            widthBucket: widthBucket,
            themeIdentifier: themeIdentifier
        )
        if officialExternalRenderIdentity != identity {
            officialExternalImage = nil
            officialExternalRenderState = .disabled
            officialExternalRenderDidStart = false
            officialExternalRenderIdentity = identity
        }
        guard officialExternalImage == nil, !officialExternalRenderDidStart else { return }
        officialExternalRenderDidStart = true

        if MermaidOfficialExternalRenderer.isRendererConfigured {
            officialExternalRenderState = .rendering
        }

        MermaidOfficialExternalRenderer.render(
            sourceMarkdown: sourceMarkdown,
            widthBucket: widthBucket,
            themeIdentifier: themeIdentifier
        ) { [weak self] result in
            guard let self else { return }
            guard self.officialExternalRenderIdentity == identity else { return }
            switch result {
            case .disabled:
                self.officialExternalRenderState = .disabled
            case .cacheHit(let image):
                self.officialExternalImage = image
                self.officialExternalRenderState = .cacheHit
                self.requestDisplayUpdate()
            case .rendered(let image):
                self.officialExternalImage = image
                self.officialExternalRenderState = .ready
                self.requestDisplayUpdate()
            case .failed:
                self.officialExternalRenderState = .failed
                self.requestDisplayUpdate()
            }
        }
    }

    private func requestDisplayUpdate() {
        guard hostView != nil else {
            needsLayoutRefreshWhenHostViewBinds = true
            return
        }
        performSelector(onMainThread: #selector(requestDisplayUpdateOnMainThread), with: nil, waitUntilDone: false)
    }

    @objc
    @MainActor
    private func requestDisplayUpdateOnMainThread() {
        guard let hostView else { return }
        hostView.needsDisplay = true
        guard let textView = hostView as? NSTextView,
              let lm = textView.layoutManager,
              let tc = textView.textContainer,
              let storage = textView.textStorage
        else { return }

        let fullRange = NSRange(location: 0, length: storage.length)
        var attachmentRanges: [NSRange] = []
        storage.enumerateAttribute(.attachment, in: fullRange, options: []) { value, range, _ in
            guard let attachment = value as? MarkdownMermaidAttachment,
                  attachment === self
            else { return }
            attachmentRanges.append(range)
        }

        if attachmentRanges.isEmpty {
            attachmentRanges = [fullRange]
        }

        for range in attachmentRanges {
            lm.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.invalidateDisplay(forGlyphRange: glyphRange)
            storage.edited(.editedAttributes, range: range, changeInLength: 0)
        }

        lm.ensureLayout(for: tc)
        textView.invalidateIntrinsicContentSize()
        textView.layoutSubtreeIfNeeded()
        textView.enclosingScrollView?.layoutSubtreeIfNeeded()
    }

    fileprivate func didDraw(in view: NSView?) {
        if let view {
            let didBindNewHostView = hostView == nil || hostView !== view
            hostView = view
            if didBindNewHostView, needsLayoutRefreshWhenHostViewBinds {
                needsLayoutRefreshWhenHostViewBinds = false
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(requestDisplayUpdateOnMainThread), object: nil)
                perform(#selector(requestDisplayUpdateOnMainThread), with: nil, afterDelay: 0)
            }
        }
    }

    nonisolated fileprivate static func resolveRenderMode(
        requested: NativeMarkdownCodec.Options.MermaidRenderMode,
        kind: MermaidMiniParser.DiagramKind,
        nodes: [Node],
        edges: [Edge]
    ) -> NativeMarkdownCodec.Options.MermaidRenderMode {
        switch requested {
        case .rich, .ascii:
            return requested
        case .auto:
            guard kind.supportsNativeRichRenderer else {
                return .ascii
            }
            let score = mermaidComplexityScore(kind: kind, nodes: nodes, edges: edges)
            let threshold = mermaidAutoASCIIThreshold()
            return score >= threshold ? .ascii : .rich
        case .officialExternal:
            // The official Mermaid renderer is intentionally optional and external.
            // Until a cached async render result exists, first-open must stay native and non-blocking.
            return .rich
        }
    }

    nonisolated fileprivate static func mermaidComplexityScore(
        kind: MermaidMiniParser.DiagramKind,
        nodes: [Node],
        edges: [Edge]
    ) -> Int {
        let kindWeight: Int
        switch kind {
        case .flowchart: kindWeight = 10
        case .sequence: kindWeight = 16
        case .mindmap: kindWeight = 24
        case .timeline: kindWeight = 24
        case .journey: kindWeight = 24
        case .sankey: kindWeight = 28
        case .generic: kindWeight = 12
        }
        let nodeLabelChars = nodes.reduce(0) { $0 + $1.label.count }
        let edgeLabelChars = edges.reduce(0) { partial, edge in
            partial + (edge.label?.count ?? 0)
        }
        let topologyScore = nodes.count * 5 + edges.count * 7
        let labelScore = min(220, (nodeLabelChars + edgeLabelChars) / 6)
        return kindWeight + topologyScore + labelScore
    }

    nonisolated fileprivate static func mermaidAutoASCIIThreshold() -> Int {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["KERN_NATIVE_MERMAID_AUTO_ASCII_THRESHOLD"], let parsed = Int(raw) {
            return max(30, parsed)
        }
        if let raw = UserDefaults.standard.object(forKey: "nativeEditor.mermaidAutoAsciiThreshold") as? NSNumber {
            return max(30, raw.intValue)
        }
        if let raw = UserDefaults.standard.string(forKey: "nativeEditor.mermaidAutoAsciiThreshold"),
           let parsed = Int(raw) {
            return max(30, parsed)
        }
        return 100
    }

    var debugNodeCount: Int { nodes.count }
    var debugEdgeCount: Int { edges.count }
    var debugNodeHeightsForTesting: [CGFloat] {
        Array(layoutResult(maxContentWidth: 560).nodeFrames.values.map(\.height))
    }
    var debugShowsEdgeLabelsForTesting: Bool { true }
    var debugRequestedRenderModeForTesting: NativeMarkdownCodec.Options.MermaidRenderMode { requestedRenderMode }
    var debugEffectiveRenderModeForTesting: NativeMarkdownCodec.Options.MermaidRenderMode { effectiveRenderMode }
    var debugASCIILinesForTesting: [String] { asciiLayout(maxContentWidth: 680).lines }
    var debugOfficialExternalRenderStateForTesting: String { officialExternalRenderState.rawValue }
    var debugHasOfficialExternalImageForTesting: Bool { officialExternalImage != nil }
    var debugOfficialExternalRenderIdentityForTesting: String? { officialExternalRenderIdentity }
    var debugDiagramKindForTesting: String { kind.rawValue }
    var debugSupportsNativeRichMermaidForTesting: Bool { kind.supportsNativeRichRenderer }
    func debugPrepareOfficialExternalRenderForTesting(maxContentWidth: CGFloat = 680, themeIdentifier: String = "default") {
        prepareOfficialExternalRenderIfNeeded(maxContentWidth: maxContentWidth, themeIdentifier: themeIdentifier)
    }
    func debugMarkOfficialExternalRenderFailedForTesting() {
        if officialExternalRenderState == .rendering {
            officialExternalRenderState = .failed
        }
    }
    fileprivate var officialExternalRenderStateForDrawing: OfficialExternalRenderState { officialExternalRenderState }
    fileprivate var shouldDrawSourceFallback: Bool {
        !kind.supportsNativeRichRenderer
    }
}

enum MermaidOfficialExternalRenderer {
    enum Result {
        case disabled
        case cacheHit(NSImage)
        case rendered(NSImage)
        case failed
    }

    static let commandUserDefaultsKey = "nativeEditor.officialMermaidRendererCommand"
    static let cacheDirectoryUserDefaultsKey = "nativeEditor.officialMermaidCacheDirectory"
    static let npxEnabledUserDefaultsKey = "nativeEditor.officialMermaidUseNPX"
    static let puppeteerConfigFileUserDefaultsKey = "nativeEditor.officialMermaidPuppeteerConfigFile"
    private static let renderQueue = DispatchQueue(label: "com.gradigit.kern.official-mermaid-renderer", qos: .utility)

    static var isRendererConfigured: Bool {
        rendererCommand() != nil
    }

    static func widthBucket(for maxContentWidth: CGFloat) -> Int {
        max(280, Int((maxContentWidth / 64).rounded()) * 64)
    }

    static func renderIdentity(sourceMarkdown: String, widthBucket: Int, themeIdentifier: String) -> String {
        let normalizedTheme = mermaidThemeIdentifier(themeIdentifier)
        let fingerprintInput = [
            "kern-mermaid-official-v3",
            "png",
            normalizedTheme,
            "\(widthBucket)",
            rendererCacheFingerprint(),
            sourceMarkdown,
        ].joined(separator: "\n")
        let hash = SHA256.hash(data: Data(fingerprintInput.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(normalizedTheme)-\(widthBucket)-\(hash)"
    }

    static func cachedOutputURLForTesting(sourceMarkdown: String, widthBucket: Int, themeIdentifier: String) -> URL {
        cachedOutputURL(sourceMarkdown: sourceMarkdown, widthBucket: widthBucket, themeIdentifier: themeIdentifier)
    }

    static func configuredCacheDirectoryForDisplay(defaults: UserDefaults = .standard) -> URL {
        configuredCacheDirectory(defaults: defaults)
    }

    static func clearCache(defaults: UserDefaults = .standard) throws {
        let cacheDirectory = configuredCacheDirectory(defaults: defaults)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let children = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: []
        )
        for child in children where isGeneratedCacheArtifact(child) {
            try FileManager.default.removeItem(at: child)
        }
    }

    static func render(
        sourceMarkdown: String,
        widthBucket: Int,
        themeIdentifier: String,
        completion: @escaping (Result) -> Void
    ) {
        guard let command = rendererCommand() else {
            completion(.disabled)
            return
        }

        let mermaidTheme = mermaidThemeIdentifier(themeIdentifier)
        let cacheURL = cachedOutputURL(
            sourceMarkdown: sourceMarkdown,
            widthBucket: widthBucket,
            themeIdentifier: mermaidTheme
        )
        if let image = NSImage(contentsOf: cacheURL), image.size.width > 0, image.size.height > 0 {
            completion(.cacheHit(image))
            return
        }

        renderQueue.async {
            do {
                try FileManager.default.createDirectory(
                    at: cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let workDirectory = cacheURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(".work-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
                defer {
                    try? FileManager.default.removeItem(at: workDirectory)
                }

                let sourceURL = workDirectory.appendingPathComponent("diagram.mmd")
                let outputURL = workDirectory.appendingPathComponent("diagram.png")
                try mermaidBody(from: sourceMarkdown).write(to: sourceURL, atomically: true, encoding: .utf8)

                let commandComponents = parseCommandComponents(command)
                guard !commandComponents.isEmpty else {
                    DispatchQueue.main.async { completion(.failed) }
                    return
                }

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = commandComponents + [
                    "-i", sourceURL.path,
                    "-o", outputURL.path,
                    "-b", "transparent",
                    "-w", "\(widthBucket)",
                    "-t", mermaidTheme,
                    "-q",
                ]
                if let puppeteerConfigFilePath = puppeteerConfigFilePath() {
                    process.arguments?.append(contentsOf: ["-p", puppeteerConfigFilePath])
                }
                process.currentDirectoryURL = workDirectory
                process.environment = rendererProcessEnvironment()
                let nullDevice = FileHandle(forWritingAtPath: "/dev/null")
                process.standardOutput = nullDevice
                process.standardError = nullDevice
                defer {
                    try? nullDevice?.close()
                }
                try process.run()

                let deadline = Date().addingTimeInterval(renderTimeoutSeconds())
                while process.isRunning, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.05)
                }
                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.25)
                    if process.isRunning {
                        Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                }
                process.waitUntilExit()

                guard process.terminationStatus == 0,
                      FileManager.default.fileExists(atPath: outputURL.path)
                else {
                    DispatchQueue.main.async { completion(.failed) }
                    return
                }

                if FileManager.default.fileExists(atPath: cacheURL.path) {
                    try FileManager.default.removeItem(at: cacheURL)
                }
                try FileManager.default.moveItem(at: outputURL, to: cacheURL)

                guard let image = NSImage(contentsOf: cacheURL), image.size.width > 0, image.size.height > 0 else {
                    DispatchQueue.main.async { completion(.failed) }
                    return
                }
                DispatchQueue.main.async { completion(.rendered(image)) }
            } catch {
                DispatchQueue.main.async { completion(.failed) }
            }
        }
    }

    private static func rendererCommand() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["KERN_OFFICIAL_MERMAID_RENDERER_COMMAND"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        if let raw = UserDefaults.standard.string(forKey: commandUserDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }

        let npxEnabled = env["KERN_OFFICIAL_MERMAID_USE_NPX"] == "1"
            || UserDefaults.standard.bool(forKey: npxEnabledUserDefaultsKey)
        guard npxEnabled else { return nil }
        let version = env["KERN_OFFICIAL_MERMAID_CLI_VERSION"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedVersion = (version?.isEmpty == false) ? version! : "11.15.0"
        return "\(defaultNPXExecutable()) -y @mermaid-js/mermaid-cli@\(selectedVersion)"
    }

    private static func rendererCacheFingerprint() -> String {
        [
            rendererCommand() ?? "disabled",
            puppeteerConfigFilePath() ?? "",
        ].joined(separator: "\u{1f}")
    }

    private static func defaultNPXExecutable() -> String {
        for candidate in ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return "npx"
    }

    static func debugRendererProcessEnvironmentForTesting() -> [String: String] {
        rendererProcessEnvironment()
    }

    static func debugCommandComponentsForTesting(_ command: String) -> [String] {
        parseCommandComponents(command)
    }

    private static func rendererProcessEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        var pathEntries = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        for required in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
            if !pathEntries.contains(required) {
                pathEntries.append(required)
            }
        }
        environment["PATH"] = pathEntries.joined(separator: ":")
        if environment["HOME"]?.isEmpty != false {
            environment["HOME"] = NSHomeDirectory()
        }
        return environment
    }

    private static func cachedOutputURL(sourceMarkdown: String, widthBucket: Int, themeIdentifier: String) -> URL {
        let cacheDirectory = configuredCacheDirectory()
        let identity = renderIdentity(
            sourceMarkdown: sourceMarkdown,
            widthBucket: widthBucket,
            themeIdentifier: themeIdentifier
        )
        let hash = identity.split(separator: "-").last.map(String.init) ?? identity
        return cacheDirectory.appendingPathComponent("\(hash).png")
    }

    private static func configuredCacheDirectory(defaults: UserDefaults = .standard) -> URL {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["KERN_OFFICIAL_MERMAID_CACHE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        if let raw = defaults.string(forKey: cacheDirectoryUserDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("Kern", isDirectory: true)
            .appendingPathComponent("OfficialMermaidRenderer", isDirectory: true)
    }

    private static func puppeteerConfigFilePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["KERN_OFFICIAL_MERMAID_PUPPETEER_CONFIG_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        if let raw = UserDefaults.standard.string(forKey: puppeteerConfigFileUserDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return raw
        }
        return nil
    }

    private static func isGeneratedCacheArtifact(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        if name.hasPrefix(".work-") {
            return true
        }
        guard name.count == 68, name.hasSuffix(".png") else {
            return false
        }
        let hex = name.dropLast(4)
        return hex.allSatisfy { character in
            character >= "0" && character <= "9" || character >= "a" && character <= "f"
        }
    }

    private static func mermaidBody(from sourceMarkdown: String) -> String {
        var lines = sourceMarkdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let first = lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           first.hasPrefix("```mermaid") || first.hasPrefix("~~~mermaid") {
            lines.removeFirst()
        }
        if let last = lines.last?.trimmingCharacters(in: .whitespacesAndNewlines),
           last == "```" || last == "~~~" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func parseCommandComponents(_ command: String) -> [String] {
        var components: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        for character in command {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }
            if character == "\\" {
                isEscaping = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character.isWhitespace {
                if !current.isEmpty {
                    components.append(current)
                    current = ""
                }
                continue
            }
            current.append(character)
        }
        if isEscaping {
            current.append("\\")
        }
        if !current.isEmpty {
            components.append(current)
        }
        return components
    }

    private static func renderTimeoutSeconds() -> TimeInterval {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["KERN_OFFICIAL_MERMAID_RENDER_TIMEOUT_SECONDS"],
           let value = TimeInterval(raw),
           value > 0 {
            return max(1, value)
        }
        let value = UserDefaults.standard.double(forKey: "nativeEditor.officialMermaidRenderTimeoutSeconds")
        if value > 0 {
            return max(1, value)
        }
        return 30
    }

    private static func mermaidThemeIdentifier(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "dark":
            return "dark"
        default:
            return "default"
        }
    }
}

private enum MermaidChromeMetrics {
    static let horizontalPadding: CGFloat = 12
    static let topChromeHeight: CGFloat = 26
    static let bottomPadding: CGFloat = 10
    static let minimumHeight: CGFloat = 170
    static let minimumHeightASCII: CGFloat = 128
}

private final class MarkdownMermaidAttachmentCell: NSTextAttachmentCell {
    override init() {
        super.init(textCell: "")
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func cellFrame(
        for textContainer: NSTextContainer?,
        proposedLineFragment lineFrag: NSRect,
        glyphPosition position: CGPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        guard let attachment else {
            let w = max(1, min(900, lineFrag.width))
            return NSRect(x: 0, y: 0, width: w, height: 220)
        }
        let bounds = attachment.attachmentBounds(
            for: textContainer,
            proposedLineFragment: lineFrag,
            glyphPosition: position,
            characterIndex: charIndex
        )
        return NSRect(x: bounds.origin.x, y: bounds.origin.y, width: bounds.width, height: bounds.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        guard let owner = attachment as? MarkdownMermaidAttachment else { return }
        let frame = cellFrame.integral
        let isFlipped = controlView?.isFlipped ?? true
        owner.didDraw(in: controlView)
        let officialThemeIdentifier = officialMermaidThemeIdentifier(for: controlView)
        let officialImage = owner.officialExternalImageForDrawing(
            maxContentWidth: max(1, frame.width - MermaidChromeMetrics.horizontalPadding * 2),
            themeIdentifier: officialThemeIdentifier
        )

        let bg = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        NSColor.textBackgroundColor.withAlphaComponent(0.78).setFill()
        bg.fill()
        NSColor.separatorColor.withAlphaComponent(0.70).setStroke()
        bg.lineWidth = 1
        bg.stroke()

        drawBadge(text: badgeText(owner: owner, officialImage: officialImage), in: frame, flipped: isFlipped)

        let contentRect = NSRect(
            x: frame.minX + MermaidChromeMetrics.horizontalPadding,
            y: MarkdownAttachmentChrome.contentMinY(
                in: frame,
                topInset: MermaidChromeMetrics.topChromeHeight,
                bottomInset: MermaidChromeMetrics.bottomPadding,
                flipped: isFlipped
            ),
            width: frame.width - MermaidChromeMetrics.horizontalPadding * 2,
            height: frame.height - MermaidChromeMetrics.topChromeHeight - MermaidChromeMetrics.bottomPadding
        ).integral
        guard contentRect.width > 10, contentRect.height > 10 else { return }

        if let officialImage {
            drawOfficialImage(officialImage, contentRect: contentRect)
            return
        }

        drawOfficialExternalDiagnosticIfNeeded(owner: owner, contentRect: contentRect, flipped: isFlipped)

        if owner.effectiveRenderMode == .ascii || owner.shouldDrawSourceFallback {
            drawASCII(owner: owner, contentRect: contentRect, flipped: isFlipped)
            return
        }

        let layout = owner.layoutResult(maxContentWidth: contentRect.width)
        let scale = min(
            1,
            contentRect.width / max(layout.size.width, 1),
            contentRect.height / max(layout.size.height, 1)
        )
        let drawWidth = layout.size.width * scale
        let drawHeight = layout.size.height * scale
        let origin = CGPoint(
            x: contentRect.minX + (contentRect.width - drawWidth) / 2,
            y: contentRect.midY - drawHeight / 2
        )

        let canvasRect = NSRect(
            x: origin.x,
            y: origin.y,
            width: drawWidth,
            height: drawHeight
        )
        let canvas = NSBezierPath(roundedRect: canvasRect, xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.withAlphaComponent(0.55).setFill()
        canvas.fill()
        NSColor.separatorColor.withAlphaComponent(0.6).setStroke()
        canvas.lineWidth = 1
        canvas.stroke()

        if owner.kind == .sequence {
            drawSequenceDiagram(layout: layout, origin: origin, scale: scale)
        } else {
            drawEdges(layout: layout, origin: origin, scale: scale, showLabels: true)
            drawNodes(layout: layout, origin: origin, scale: scale)
        }
    }

    private func officialMermaidThemeIdentifier(for controlView: NSView?) -> String {
        let appearance = controlView?.effectiveAppearance ?? NSApp.effectiveAppearance
        let best = appearance.bestMatch(from: [.darkAqua, .aqua])
        return best == .darkAqua ? "dark" : "default"
    }

    private func badgeText(owner: MarkdownMermaidAttachment, officialImage: NSImage?) -> String {
        if owner.debugRequestedRenderModeForTesting == .officialExternal {
            if officialImage != nil { return "MERMAID OFFICIAL" }
            switch owner.officialExternalRenderStateForDrawing {
            case .disabled:
                return owner.shouldDrawSourceFallback ? "MERMAID SOURCE" : "MERMAID NATIVE FALLBACK"
            case .rendering:
                return "MERMAID RENDERING"
            case .failed:
                return owner.shouldDrawSourceFallback ? "MERMAID SOURCE" : "MERMAID FALLBACK"
            case .cacheHit, .ready:
                return "MERMAID OFFICIAL"
            }
        }
        if owner.shouldDrawSourceFallback {
            return "MERMAID SOURCE"
        }
        return owner.effectiveRenderMode == .ascii ? "MERMAID ASCII" : "MERMAID"
    }

    private func drawOfficialExternalDiagnosticIfNeeded(
        owner: MarkdownMermaidAttachment,
        contentRect: NSRect,
        flipped: Bool
    ) {
        guard owner.debugRequestedRenderModeForTesting == .officialExternal else { return }
        let message: String?
        switch owner.officialExternalRenderStateForDrawing {
        case .disabled:
            message = owner.shouldDrawSourceFallback
                ? "Official renderer not configured; showing Mermaid source."
                : "Official renderer not configured; showing native rich fallback."
        case .rendering:
            message = "Rendering official Mermaid…"
        case .failed:
            message = owner.shouldDrawSourceFallback
                ? "Official renderer failed; showing Mermaid source."
                : "Official renderer failed; showing native rich fallback."
        case .cacheHit, .ready:
            message = nil
        }
        guard let message else { return }
        let font = NSFont.systemFont(ofSize: 11, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.78),
        ]
        let size = (message as NSString).size(withAttributes: attrs)
        let y = flipped ? contentRect.maxY - size.height - 4 : contentRect.minY + 4
        (message as NSString).draw(
            in: NSRect(
                x: contentRect.minX + 8,
                y: y,
                width: min(size.width + 4, contentRect.width - 16),
                height: size.height + 2
            ),
            withAttributes: attrs
        )
    }

    private func drawOfficialImage(_ image: NSImage, contentRect: NSRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(1, contentRect.width / image.size.width, contentRect.height / image.size.height)
        let drawSize = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = NSRect(
            x: contentRect.midX - drawSize.width / 2,
            y: contentRect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        ).integral
        image.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func drawASCII(owner: MarkdownMermaidAttachment, contentRect: NSRect, flipped: Bool) {
        let layout = owner.asciiLayout(maxContentWidth: contentRect.width)
        let textAreaWidth = min(contentRect.width, layout.size.width)
        let textAreaHeight = min(contentRect.height, layout.size.height)

        let textAreaRect = NSRect(
            x: contentRect.minX + (contentRect.width - textAreaWidth) / 2,
            y: contentRect.midY - textAreaHeight / 2,
            width: textAreaWidth,
            height: textAreaHeight
        ).integral

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.lineBreakMode = .byClipping
        let attrs: [NSAttributedString.Key: Any] = [
            .font: layout.font,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.88),
            .paragraphStyle: paragraph,
        ]

        let leftInset: CGFloat = 8
        let topInset: CGFloat = 6
        let maxVisibleLines = max(1, Int((textAreaRect.height - topInset * 2) / layout.lineHeight))
        let visibleLines = layout.lines.prefix(maxVisibleLines)
        for (index, line) in visibleLines.enumerated() {
            let y: CGFloat
            if flipped {
                y = textAreaRect.minY + topInset + CGFloat(index) * layout.lineHeight
            } else {
                y = textAreaRect.maxY - topInset - CGFloat(index + 1) * layout.lineHeight
            }
            let lineRect = NSRect(
                x: textAreaRect.minX + leftInset,
                y: y,
                width: textAreaRect.width - leftInset * 2,
                height: layout.lineHeight
            )
            (line as NSString).draw(in: lineRect, withAttributes: attrs)
        }
    }

    private func drawBadge(text: String, in frame: NSRect, flipped: Bool) {
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let textSize = (text as NSString).size(withAttributes: textAttrs)
        let pillHeight: CGFloat = 14
        let pillRect = NSRect(
            x: frame.maxX - textSize.width - 18,
            y: MarkdownAttachmentChrome.topY(in: frame, inset: 6, height: pillHeight, flipped: flipped),
            width: textSize.width + 10,
            height: pillHeight
        ).integral
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
        NSColor.textBackgroundColor.withAlphaComponent(0.55).setFill()
        pill.fill()
        (text as NSString).draw(
            in: NSRect(
                x: pillRect.midX - textSize.width / 2,
                y: pillRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            ).integral,
            withAttributes: textAttrs
        )
    }

    private func drawSequenceDiagram(layout: MermaidMiniLayout.Result, origin: CGPoint, scale: CGFloat) {
        guard !layout.nodes.isEmpty else { return }

        func point(_ local: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + local.x * scale, y: origin.y + local.y * scale)
        }

        let nodeBottom = layout.nodeFrames.values.map(\.maxY).max() ?? 0
        let messageTop = nodeBottom + 24
        let messageStep: CGFloat = 26
        let bottomY = max(messageTop + messageStep, layout.size.height - 18)

        NSColor.labelColor.withAlphaComponent(0.18).setStroke()
        for node in layout.nodes {
            guard let frame = layout.nodeFrames[node.id] else { continue }
            let path = NSBezierPath()
            path.move(to: point(CGPoint(x: frame.midX, y: frame.maxY + 7)))
            path.line(to: point(CGPoint(x: frame.midX, y: bottomY)))
            path.lineWidth = max(1, 1 * scale)
            let dash: [CGFloat] = [4 * scale, 4 * scale]
            path.setLineDash(dash, count: dash.count, phase: 0)
            path.stroke()
        }

        NSColor.labelColor.withAlphaComponent(0.52).setStroke()
        for (index, edge) in layout.edges.enumerated() {
            guard let from = layout.nodeFrames[edge.from], let to = layout.nodeFrames[edge.to] else { continue }
            let y = messageTop + CGFloat(index) * messageStep
            guard y < bottomY + 1 else { break }

            let startX = from.midX
            let endX = to.midX
            if abs(startX - endX) < 4 {
                drawSequenceSelfMessage(x: startX, y: y, edge: edge, origin: origin, scale: scale)
                continue
            }

            let start = point(CGPoint(x: startX, y: y))
            let end = point(CGPoint(x: endX, y: y))
            let path = NSBezierPath()
            path.move(to: start)
            path.line(to: end)
            path.lineWidth = max(1, 1.35 * scale)
            path.stroke()

            let direction: CGFloat = endX >= startX ? 1 : -1
            drawArrowHead(at: end, angle: direction >= 0 ? 0 : .pi, scale: scale)

            if let label = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                drawEdgeLabel(label, at: CGPoint(x: (start.x + end.x) / 2, y: start.y - 10 * scale))
            }
        }

        drawNodes(layout: layout, origin: origin, scale: scale)
    }

    private func drawSequenceSelfMessage(
        x: CGFloat,
        y: CGFloat,
        edge: MarkdownMermaidAttachment.Edge,
        origin: CGPoint,
        scale: CGFloat
    ) {
        let loopWidth: CGFloat = 42
        let loopHeight: CGFloat = 18
        let rect = NSRect(
            x: origin.x + x * scale,
            y: origin.y + (y - loopHeight / 2) * scale,
            width: loopWidth * scale,
            height: loopHeight * scale
        )
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.midY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.lineWidth = max(1, 1.35 * scale)
        path.stroke()
        drawArrowHead(at: NSPoint(x: rect.minX, y: rect.maxY), angle: .pi, scale: scale)

        if let label = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            drawEdgeLabel(label, at: CGPoint(x: rect.midX, y: rect.minY - 8 * scale))
        }
    }

    private func drawArrowHead(at end: CGPoint, angle: CGFloat, scale: CGFloat) {
        let arrowSize = max(4.5, 5.5 * scale)
        let arrow = NSBezierPath()
        arrow.move(to: end)
        arrow.line(to: CGPoint(
            x: end.x - arrowSize * cos(angle - .pi / 7),
            y: end.y - arrowSize * sin(angle - .pi / 7)
        ))
        arrow.move(to: end)
        arrow.line(to: CGPoint(
            x: end.x - arrowSize * cos(angle + .pi / 7),
            y: end.y - arrowSize * sin(angle + .pi / 7)
        ))
        arrow.lineWidth = max(1, 1.2 * scale)
        arrow.stroke()
    }

    private func drawEdges(layout: MermaidMiniLayout.Result, origin: CGPoint, scale: CGFloat, showLabels: Bool) {
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()

        for edge in layout.edges {
            guard let from = layout.nodeFrames[edge.from], let to = layout.nodeFrames[edge.to] else { continue }
            let horizontal = abs(to.midX - from.midX) >= abs(to.midY - from.midY)
            let startRaw = CGPoint(
                x: horizontal ? (to.midX >= from.midX ? from.maxX - 2 : from.minX + 2) : from.midX,
                y: horizontal ? from.midY : (to.midY >= from.midY ? from.maxY - 2 : from.minY + 2)
            )
            let endRaw = CGPoint(
                x: horizontal ? (to.midX >= from.midX ? to.minX + 2 : to.maxX - 2) : to.midX,
                y: horizontal ? to.midY : (to.midY >= from.midY ? to.minY + 2 : to.maxY - 2)
            )
            let start = CGPoint(x: origin.x + startRaw.x * scale, y: origin.y + startRaw.y * scale)
            let end = CGPoint(x: origin.x + endRaw.x * scale, y: origin.y + endRaw.y * scale)

            let path = NSBezierPath()
            path.move(to: start)
            if abs(start.y - end.y) > 6 {
                let c1 = CGPoint(x: start.x + (end.x - start.x) * 0.45, y: start.y)
                let c2 = CGPoint(x: start.x + (end.x - start.x) * 0.55, y: end.y)
                path.curve(to: end, controlPoint1: c1, controlPoint2: c2)
            } else {
                path.line(to: end)
            }
            path.lineWidth = max(1, 1.5 * scale)
            path.stroke()

            // Arrow head.
            let angle = atan2(end.y - start.y, end.x - start.x)
            drawArrowHead(at: end, angle: angle, scale: scale)

            if showLabels, let label = edge.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
                drawEdgeLabel(label, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2))
            }
        }
    }

    private func drawNodes(layout: MermaidMiniLayout.Result, origin: CGPoint, scale: CGFloat) {
        for node in layout.nodes {
            guard let rect = layout.nodeFrames[node.id] else { continue }
            let drawRect = NSRect(
                x: origin.x + rect.origin.x * scale,
                y: origin.y + rect.origin.y * scale,
                width: rect.width * scale,
                height: rect.height * scale
            )

            let nodePath = NSBezierPath(roundedRect: drawRect, xRadius: max(5, 7 * scale), yRadius: max(5, 7 * scale))
            NSColor.textBackgroundColor.withAlphaComponent(0.96).setFill()
            nodePath.fill()
            NSColor.separatorColor.withAlphaComponent(0.75).setStroke()
            nodePath.lineWidth = max(1, 1 * scale)
            nodePath.stroke()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            paragraph.lineBreakMode = .byWordWrapping
            let textFont = NSFont.systemFont(ofSize: max(10, 12 * scale), weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: textFont,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            let insetRect = drawRect.insetBy(dx: max(6, 8 * scale), dy: max(4, 6 * scale))
            let measured = (node.label as NSString).boundingRect(
                with: CGSize(width: insetRect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attrs
            )
            let textHeight = max(1, min(insetRect.height, ceil(measured.height)))
            let centeredRect = NSRect(
                x: insetRect.minX,
                y: insetRect.midY - textHeight / 2,
                width: insetRect.width,
                height: textHeight
            )
            (node.label as NSString).draw(in: centeredRect, withAttributes: attrs)
        }
    }

    private func drawEdgeLabel(_ label: String, at center: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let normalized = String(label.prefix(24))
        let size = (normalized as NSString).size(withAttributes: attrs)
        let pillRect = NSRect(
            x: center.x - (size.width + 8) / 2,
            y: center.y - (size.height + 4) / 2,
            width: size.width + 8,
            height: size.height + 4
        ).integral
        let pill = NSBezierPath(roundedRect: pillRect, xRadius: 4, yRadius: 4)
        NSColor.textBackgroundColor.withAlphaComponent(0.92).setFill()
        pill.fill()
        (normalized as NSString).draw(
            in: NSRect(
                x: pillRect.midX - size.width / 2,
                y: pillRect.midY - size.height / 2,
                width: size.width,
                height: size.height
            ).integral,
            withAttributes: attrs
        )
    }
}

enum MathTextRenderer {
    static func renderInlineMath(_ expression: String) -> String {
        normalize(expression)
    }

    static func renderBlockMath(from sourceMarkdown: String) -> String {
        let lines = sourceMarkdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var body = lines
        if !body.isEmpty, body.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "$$" {
            body.removeFirst()
        }
        if !body.isEmpty, body.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "$$" {
            body.removeLast()
        }
        return normalize(body.joined(separator: "\n"))
    }

    static func displayFont(size: CGFloat) -> NSFont {
        if let math = NSFont(name: "STIX Two Math", size: size) ?? NSFont(name: "STIXTwoMath-Regular", size: size) {
            return math
        }
        if let serif = NSFont(name: "Times New Roman", size: size) {
            return NSFontManager.shared.convert(serif, toHaveTrait: .italicFontMask)
        }
        return NSFont.systemFont(ofSize: size, weight: .regular)
    }

    private static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "\\\\", with: "\n")
        s = s.replacingOccurrences(of: "&", with: "")

        s = unwrapLatexCommands(in: s)
        s = replaceFractions(in: s)
        s = replaceSquareRoots(in: s)
        s = replaceKnownSymbols(in: s)
        s = collapseSuperscriptsAndSubscripts(in: s)

        let cleanupReplacements: [(String, String)] = [
            ("\\left", ""),
            ("\\right", ""),
            ("\\,", " "),
            ("\\;", " "),
            ("\\:", " "),
            ("\\!", ""),
            ("{", ""),
            ("}", ""),
            ("\\", ""),
        ]
        for (target, replacement) in cleanupReplacements {
            s = s.replacingOccurrences(of: target, with: replacement)
        }
        s = s.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func unwrapLatexCommands(in text: String) -> String {
        var s = text
        let removableEnvironments = ["aligned", "align", "gathered", "matrix", "pmatrix", "bmatrix"]
        for environment in removableEnvironments {
            s = s.replacingOccurrences(of: "\\begin{\(environment)}", with: "")
            s = s.replacingOccurrences(of: "\\end{\(environment)}", with: "")
        }

        let wrappers = ["mathbf", "mathbb", "mathcal", "mathrm", "mathit", "text", "operatorname"]
        for wrapper in wrappers {
            s = replaceRegex(pattern: "\\\\\(wrapper)\\{([^{}]+)\\}", in: s) { match, ns in
                guard match.numberOfRanges > 1 else { return "" }
                return ns.substring(with: match.range(at: 1))
            }
        }
        return s
    }

    private static func replaceFractions(in text: String) -> String {
        var s = text
        for _ in 0..<6 {
            let next = replaceRegex(pattern: #"\\frac\s*\{([^{}]+)\}\s*\{([^{}]+)\}"#, in: s) { match, ns in
                guard match.numberOfRanges > 2 else { return "" }
                let numerator = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                let denominator = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                return "(\(numerator))⁄(\(denominator))"
            }
            if next == s { break }
            s = next
        }
        return s
    }

    private static func replaceSquareRoots(in text: String) -> String {
        replaceRegex(pattern: #"\\sqrt\s*\{([^{}]+)\}"#, in: text) { match, ns in
            guard match.numberOfRanges > 1 else { return "√()" }
            let inner = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
            return "√(\(inner))"
        }
    }

    private static func replaceKnownSymbols(in text: String) -> String {
        var s = text
        let replacements: [(String, String)] = [
            ("\\rightarrow", "→"),
            ("\\leftarrow", "←"),
            ("\\Rightarrow", "⇒"),
            ("\\Leftarrow", "⇐"),
            ("\\leftrightarrow", "↔"),
            ("\\alpha", "α"),
            ("\\beta", "β"),
            ("\\gamma", "γ"),
            ("\\Gamma", "Γ"),
            ("\\delta", "δ"),
            ("\\Delta", "Δ"),
            ("\\epsilon", "ε"),
            ("\\varepsilon", "ε"),
            ("\\theta", "θ"),
            ("\\lambda", "λ"),
            ("\\mu", "μ"),
            ("\\pi", "π"),
            ("\\rho", "ρ"),
            ("\\sigma", "σ"),
            ("\\Sigma", "Σ"),
            ("\\phi", "φ"),
            ("\\omega", "ω"),
            ("\\Omega", "Ω"),
            ("\\nabla", "∇"),
            ("\\partial", "∂"),
            ("\\infty", "∞"),
            ("\\int", "∫"),
            ("\\sum", "∑"),
            ("\\prod", "∏"),
            ("\\cdot", "·"),
            ("\\times", "×"),
            ("\\div", "÷"),
            ("\\pm", "±"),
            ("\\leq", "≤"),
            ("\\le", "≤"),
            ("\\geq", "≥"),
            ("\\ge", "≥"),
            ("\\neq", "≠"),
            ("\\approx", "≈"),
            ("\\equiv", "≡"),
            ("\\to", "→"),
        ]
        for (target, replacement) in replacements {
            s = s.replacingOccurrences(of: target, with: replacement)
        }
        return s
    }

    private static func collapseSuperscriptsAndSubscripts(in text: String) -> String {
        let superscriptMap: [Character: String] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
            "n": "ⁿ", "i": "ⁱ",
        ]
        let subscriptMap: [Character: String] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
            "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ",
            "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
            "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ",
            "v": "ᵥ", "x": "ₓ",
        ]

        var s = convertScripts(marker: "^", in: text, map: superscriptMap)
        s = convertScripts(marker: "_", in: s, map: subscriptMap)
        return s
    }

    private static func convertScripts(marker: Character, in text: String, map: [Character: String]) -> String {
        let escaped = marker == "^" ? #"\^"# : "_"
        var s = replaceRegex(pattern: "\(escaped)\\{([^{}]+)\\}", in: text) { match, ns in
            guard match.numberOfRanges > 1 else { return String(marker) }
            let inner = ns.substring(with: match.range(at: 1))
            return convertScriptGroup(inner, marker: marker, map: map)
        }
        s = replaceRegex(pattern: "\(escaped)([A-Za-z0-9+\\-=()])", in: s) { match, ns in
            guard match.numberOfRanges > 1 else { return String(marker) }
            let inner = ns.substring(with: match.range(at: 1))
            return convertScriptGroup(inner, marker: marker, map: map)
        }
        return s
    }

    private static func convertScriptGroup(_ group: String, marker: Character, map: [Character: String]) -> String {
        let converted = group.map { map[$0] ?? String($0) }.joined()
        if converted == group {
            return "\(marker)(\(group))"
        }
        return converted
    }

    private static func replaceRegex(
        pattern: String,
        in source: String,
        replacement: (_ match: NSTextCheckingResult, _ ns: NSString) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return source }
        let ns = source as NSString
        let matches = regex.matches(in: source, range: NSRange(location: 0, length: ns.length)).reversed()
        var output = source
        for match in matches {
            output = (output as NSString).replacingCharacters(in: match.range, with: replacement(match, ns))
        }
        return output
    }
}

private enum MermaidMiniParser {
    enum DiagramKind: String {
        case flowchart
        case sequence
        case mindmap
        case timeline
        case journey
        case sankey
        case generic

        var supportsNativeRichRenderer: Bool {
            switch self {
            case .flowchart, .sequence:
                return true
            case .mindmap, .timeline, .journey, .sankey, .generic:
                return false
            }
        }
    }

    struct ParseResult {
        let kind: DiagramKind
        let nodes: [MarkdownMermaidAttachment.Node]
        let edges: [MarkdownMermaidAttachment.Edge]
    }

    private struct MutableNode {
        var id: String
        var label: String
    }

    static func parse(sourceMarkdown: String) -> ParseResult {
        let body = extractBody(sourceMarkdown)
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trimmedLower = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        var nodeOrder: [String] = []
        var nodes: [String: MutableNode] = [:]
        var edges: [MarkdownMermaidAttachment.Edge] = []
        let kind = detectKind(trimmedLower)

        func ensureNode(id: String, label: String? = nil) {
            guard !id.isEmpty else { return }
            let cleanLabel = label.map(normalizeLabel)
            if nodes[id] == nil {
                nodes[id] = MutableNode(id: id, label: cleanLabel ?? id)
                nodeOrder.append(id)
            } else if let cleanLabel, !cleanLabel.isEmpty, nodes[id]?.label == id {
                nodes[id]?.label = cleanLabel
            }
        }

        let nodePatterns = [
            #"([A-Za-z][A-Za-z0-9_-]*)\s*\[\s*\"?([^\]]+?)\"?\s*\]"#,
            #"([A-Za-z][A-Za-z0-9_-]*)\s*\(([^\)]+)\)"#,
            #"([A-Za-z][A-Za-z0-9_-]*)\s*\{([^\}]+)\}"#,
        ]
        let flowEdgePattern = #"([A-Za-z][A-Za-z0-9_-]*)(?:\s*(?:\[[^\]]+\]|\([^\)]*\)|\{[^\}]*\}))?\s*--[^>]*>\s*(?:\|([^|]*)\|\s*)?([A-Za-z][A-Za-z0-9_-]*)"#
        let sequenceParticipantPattern = #"^\s*participant\s+([A-Za-z][A-Za-z0-9_-]*)(?:\s+as\s+(.+))?\s*$"#
        let sequenceEdgePattern = #"^\s*([A-Za-z][A-Za-z0-9_-]*?)\s*[-.]+[<>]{1,2}\s*([A-Za-z][A-Za-z0-9_-]*)\s*:?\s*(.*)$"#

        for line in lines {
            if kind == .sequence {
                if let participant = regexCaptures(pattern: sequenceParticipantPattern, in: line).first,
                   participant.count >= 2
                {
                    ensureNode(id: participant[0], label: participant[1].isEmpty ? participant[0] : participant[1])
                }
                if let sequenceEdge = regexCaptures(pattern: sequenceEdgePattern, in: line).first,
                   sequenceEdge.count >= 3
                {
                    let from = sequenceEdge[0]
                    let to = sequenceEdge[1]
                    let label = normalizeLabel(sequenceEdge[2])
                    ensureNode(id: from)
                    ensureNode(id: to)
                    if edges.count < 40 {
                        edges.append(.init(from: from, to: to, label: label.isEmpty ? nil : label))
                    }
                }
            }

            if kind == .flowchart || kind == .generic {
                for pattern in nodePatterns {
                    for match in regexCaptures(pattern: pattern, in: line) where match.count >= 2 {
                        ensureNode(id: match[0], label: match[1])
                    }
                }

                for match in regexCaptures(pattern: flowEdgePattern, in: line) where match.count >= 3 {
                    let from = match[0]
                    let label = normalizeLabel(match[1])
                    let to = match[2]
                    ensureNode(id: from)
                    ensureNode(id: to)
                    if edges.count < 40 {
                        edges.append(.init(from: from, to: to, label: label.isEmpty ? nil : label))
                    }
                }
            }
        }

        // Fallback for unknown Mermaid content. Explicit official-only families must remain
        // source/official-renderer cards; fabricating generic chains makes invalid visual claims.
        if kind == .generic && nodeOrder.isEmpty {
            let fallback = Array(lines.prefix(6))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { line in
                    let lower = line.lowercased()
                    guard !line.isEmpty else { return false }
                    guard !lower.hasPrefix("flowchart"), !lower.hasPrefix("graph"), !lower.hasPrefix("sequencediagram") else {
                        return false
                    }
                    return true
                }
            for (i, line) in fallback.enumerated() where i < 6 {
                let id = "L\(i + 1)"
                ensureNode(id: id, label: normalizeLabel(line))
                if i > 0 {
                    edges.append(.init(from: "L\(i)", to: id, label: nil))
                }
            }
        }

        let finalNodes = nodeOrder
            .prefix(18)
            .compactMap { key -> MarkdownMermaidAttachment.Node? in
                guard let node = nodes[key] else { return nil }
                return .init(id: node.id, label: node.label)
            }
        let allowedIDs = Set(finalNodes.map(\.id))
        let finalEdges = edges.filter { allowedIDs.contains($0.from) && allowedIDs.contains($0.to) }

        return ParseResult(kind: kind, nodes: finalNodes, edges: finalEdges)
    }

    private static func detectKind(_ trimmedLowerLines: [String]) -> DiagramKind {
        guard let first = trimmedLowerLines.first(where: { line in
            !line.isEmpty && !line.hasPrefix("%%")
        }) else {
            return .generic
        }
        let firstToken = first
            .split { $0 == " " || $0 == "\t" }
            .first
            .map(String.init) ?? first

        if firstToken == "sequencediagram" { return .sequence }
        if firstToken == "flowchart" || firstToken == "graph" { return .flowchart }
        if firstToken == "mindmap" { return .mindmap }
        if firstToken == "timeline" { return .timeline }
        if firstToken == "journey" { return .journey }
        if firstToken == "sankey" || firstToken == "sankey-beta" { return .sankey }

        return .generic
    }

    private static func extractBody(_ sourceMarkdown: String) -> String {
        let lines = sourceMarkdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return sourceMarkdown }
        var body = lines
        if body.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
            body.removeFirst()
        }
        if body.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" {
            body.removeLast()
        }
        return body.joined(separator: "\n")
    }

    private static func regexCaptures(pattern: String, in source: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let ns = source as NSString
        let range = NSRange(location: 0, length: ns.length)
        return re.matches(in: source, options: [], range: range).map { match in
            (1..<match.numberOfRanges).map { idx in
                let r = match.range(at: idx)
                guard r.location != NSNotFound else { return "" }
                return ns.substring(with: r)
            }
        }
    }

    private static func normalizeLabel(_ raw: String) -> String {
        var label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if (label.hasPrefix("\"") && label.hasSuffix("\"")) || (label.hasPrefix("'") && label.hasSuffix("'")) {
            label = String(label.dropFirst().dropLast())
        }
        label = label.replacingOccurrences(of: "`", with: "")
        label = label.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return String(label.prefix(120))
    }
}

private enum MermaidMiniLayout {
    struct Result {
        let size: CGSize
        let nodes: [MarkdownMermaidAttachment.Node]
        let edges: [MarkdownMermaidAttachment.Edge]
        let nodeFrames: [String: CGRect]
    }

    static func layout(
        kind: MermaidMiniParser.DiagramKind,
        nodes: [MarkdownMermaidAttachment.Node],
        edges: [MarkdownMermaidAttachment.Edge],
        maxContentWidth: CGFloat
    ) -> Result {
        guard !nodes.isEmpty else {
            return Result(size: CGSize(width: 320, height: 180), nodes: [], edges: [], nodeFrames: [:])
        }

        let incoming = Dictionary(grouping: edges, by: \.to).mapValues(\.count)
        let outgoing = Dictionary(grouping: edges, by: \.from)

        // Depth assignment must be cycle-safe. Using "longest path" updates can loop forever on
        // self/cyclic edges (common in sequence/flow diagrams) and explode memory/CPU.
        var depth: [String: Int] = [:]
        var queue: [String] = nodes.map(\.id).filter { incoming[$0] == nil }
        if queue.isEmpty {
            queue = [nodes[0].id]
        }
        for root in queue {
            depth[root] = 0
        }

        let maxDepth = max(0, nodes.count - 1)
        var qi = 0
        while qi < queue.count {
            let current = queue[qi]
            qi += 1
            let currentDepth = depth[current] ?? 0
            for edge in outgoing[current] ?? [] {
                // Visit each node once during BFS to guarantee termination on cyclic graphs.
                guard depth[edge.to] == nil else { continue }
                depth[edge.to] = min(currentDepth + 1, maxDepth)
                queue.append(edge.to)
            }
        }

        // Any disconnected/cycle-only nodes that did not get a depth are placed after known columns.
        if depth.count < nodes.count {
            var fallbackDepth = min((depth.values.max() ?? -1) + 1, maxDepth)
            for node in nodes where depth[node.id] == nil {
                depth[node.id] = fallbackDepth
                fallbackDepth = min(fallbackDepth + 1, maxDepth)
            }
        }

        let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let measuredLabelWidths = nodes.map { ($0.label as NSString).size(withAttributes: [.font: labelFont]).width }
        let baseNodeWidth = min(220, max(104, (measuredLabelWidths.max() ?? 104) + 28))

        let margin: CGFloat = 18
        let gapX: CGFloat = 40
        let gapY: CGFloat = 18
        let minNodeWidth: CGFloat = 92
        let maxColumnsByKind = (kind == .sequence) ? 4 : 6

        let uniqueDepths = Array(Set(nodes.map { depth[$0.id] ?? 0 })).sorted()
        var depthRank: [Int: Int] = [:]
        for (i, d) in uniqueDepths.enumerated() {
            depthRank[d] = i
        }

        let preferredColumns = max(1, uniqueDepths.count)
        let widthForColumns = maxContentWidth - margin * 2
        var columnCount = min(preferredColumns, maxColumnsByKind)
        columnCount = max(columnCount, 1)
        while columnCount > 1 {
            let candidateWidth = (widthForColumns - CGFloat(columnCount - 1) * gapX) / CGFloat(columnCount)
            if candidateWidth >= minNodeWidth { break }
            columnCount -= 1
        }
        let fittedNodeWidth = max(
            minNodeWidth,
            min(baseNodeWidth, (widthForColumns - CGFloat(max(0, columnCount - 1)) * gapX) / CGFloat(max(columnCount, 1)))
        )
        let labelParagraph = NSMutableParagraphStyle()
        labelParagraph.alignment = .center
        labelParagraph.lineBreakMode = .byWordWrapping
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: labelFont,
            .paragraphStyle: labelParagraph,
        ]
        let labelTextWidth = max(40, fittedNodeWidth - 16)
        let minimumNodeHeight: CGFloat = 34
        let maximumNodeHeight: CGFloat = 96
        func measuredNodeHeight(for label: String) -> CGFloat {
            let measured = (label as NSString).boundingRect(
                with: CGSize(width: labelTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: labelAttrs
            )
            let padded = ceil(measured.height) + 12
            return min(maximumNodeHeight, max(minimumNodeHeight, padded))
        }
        let nodeHeights: [String: CGFloat] = Dictionary(uniqueKeysWithValues: nodes.map { node in
            (node.id, measuredNodeHeight(for: node.label))
        })

        if kind == .sequence {
            let sequenceColumns = max(1, min(columnCount, nodes.count))
            let rowGap: CGFloat = 12
            let topRowHeight = max(minimumNodeHeight, nodes.map { nodeHeights[$0.id] ?? minimumNodeHeight }.max() ?? minimumNodeHeight)
            var frames: [String: CGRect] = [:]
            var maxX: CGFloat = margin
            var maxY: CGFloat = margin

            for (index, node) in nodes.enumerated() {
                let column = index % sequenceColumns
                let row = index / sequenceColumns
                let nodeHeight = nodeHeights[node.id] ?? minimumNodeHeight
                let x = margin + CGFloat(column) * (fittedNodeWidth + gapX)
                let y = margin + CGFloat(row) * (topRowHeight + rowGap)
                let rect = CGRect(x: x, y: y, width: fittedNodeWidth, height: nodeHeight)
                frames[node.id] = rect
                maxX = max(maxX, rect.maxX)
                maxY = max(maxY, rect.maxY)
            }

            let messageRows = max(1, min(edges.count, 20))
            let sequenceHeight = maxY + 24 + CGFloat(messageRows) * 26 + margin
            let size = CGSize(
                width: min(maxContentWidth, maxX + margin),
                height: sequenceHeight
            )
            return Result(size: size, nodes: nodes, edges: edges, nodeFrames: frames)
        }

        func compressedColumn(for depthValue: Int) -> Int {
            let rank = depthRank[depthValue] ?? 0
            if preferredColumns <= columnCount { return rank }
            let denominator = max(1, preferredColumns - 1)
            return Int(round(CGFloat(rank) * CGFloat(columnCount - 1) / CGFloat(denominator)))
        }

        var columns: [Int: [MarkdownMermaidAttachment.Node]] = [:]
        for node in nodes {
            let d = compressedColumn(for: depth[node.id] ?? 0)
            columns[d, default: []].append(node)
        }
        let sortedColumns = columns.keys.sorted()

        var frames: [String: CGRect] = [:]
        var maxX: CGFloat = margin
        var maxY: CGFloat = margin

        for d in sortedColumns {
            let col = columns[d] ?? []
            var y = margin
            for node in col {
                let x = margin + CGFloat(d) * (fittedNodeWidth + gapX)
                let nodeHeight = nodeHeights[node.id] ?? minimumNodeHeight
                let rect = CGRect(x: x, y: y, width: fittedNodeWidth, height: nodeHeight)
                frames[node.id] = rect
                maxX = max(maxX, rect.maxX)
                maxY = max(maxY, rect.maxY)
                y = rect.maxY + gapY
            }
        }

        let size = CGSize(
            width: min(maxContentWidth, maxX + margin),
            height: maxY + margin
        )
        return Result(size: size, nodes: nodes, edges: edges, nodeFrames: frames)
    }
}

private enum MermaidASCIIFormatter {
    private enum FlowDirection {
        case topDown
        case leftRight
        case bottomTop
        case rightLeft

        var isVertical: Bool {
            switch self {
            case .topDown, .bottomTop: return true
            case .leftRight, .rightLeft: return false
            }
        }

        var isReversed: Bool {
            switch self {
            case .bottomTop, .rightLeft: return true
            case .topDown, .leftRight: return false
            }
        }
    }

    private struct RenderNode {
        let id: String
        let label: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        var minX: Int { x }
        var maxX: Int { x + width - 1 }
        var minY: Int { y }
        var maxY: Int { y + height - 1 }
        var centerX: Int { x + width / 2 }
        var centerY: Int { y + height / 2 }
    }

    private struct Glyphs {
        let horizontal: Character
        let vertical: Character
        let topLeft: Character
        let topRight: Character
        let bottomLeft: Character
        let bottomRight: Character
        let teeDown: Character
        let teeUp: Character
        let teeRight: Character
        let teeLeft: Character
        let cross: Character
        let arrowRight: Character
        let arrowLeft: Character
        let arrowDown: Character
        let arrowUp: Character

        static let unicode = Glyphs(
            horizontal: "─",
            vertical: "│",
            topLeft: "┌",
            topRight: "┐",
            bottomLeft: "└",
            bottomRight: "┘",
            teeDown: "┬",
            teeUp: "┴",
            teeRight: "├",
            teeLeft: "┤",
            cross: "┼",
            arrowRight: "▶",
            arrowLeft: "◀",
            arrowDown: "▼",
            arrowUp: "▲"
        )
    }

    private struct Canvas {
        private let glyphs: Glyphs
        private var rows: [[Character]]

        init(width: Int, height: Int, glyphs: Glyphs = .unicode) {
            self.glyphs = glyphs
            self.rows = Array(
                repeating: Array(repeating: Character(" "), count: max(1, width)),
                count: max(1, height)
            )
        }

        var width: Int { rows.first?.count ?? 0 }
        var height: Int { rows.count }

        mutating func put(_ char: Character, x: Int, y: Int) {
            guard y >= 0, y < height, x >= 0, x < width else { return }
            rows[y][x] = char
        }

        mutating func putText(_ text: String, x: Int, y: Int) {
            guard y >= 0, y < height else { return }
            for (offset, char) in text.enumerated() {
                put(char, x: x + offset, y: y)
            }
        }

        mutating func drawBox(_ box: RenderNode) {
            guard box.width >= 3, box.height >= 3 else { return }
            put(glyphs.topLeft, x: box.minX, y: box.minY)
            put(glyphs.topRight, x: box.maxX, y: box.minY)
            put(glyphs.bottomLeft, x: box.minX, y: box.maxY)
            put(glyphs.bottomRight, x: box.maxX, y: box.maxY)
            if box.width > 2 {
                for x in (box.minX + 1)..<box.maxX {
                    putLine(glyphs.horizontal, x: x, y: box.minY)
                    putLine(glyphs.horizontal, x: x, y: box.maxY)
                }
            }
            if box.height > 2 {
                for y in (box.minY + 1)..<box.maxY {
                    putLine(glyphs.vertical, x: box.minX, y: y)
                    putLine(glyphs.vertical, x: box.maxX, y: y)
                }
            }

            let label = compactLabel(box.label, maxCharacters: max(1, box.width - 4))
            let free = max(0, box.width - 2 - label.count)
            let left = free / 2
            putText(label, x: box.minX + 1 + left, y: box.centerY)
        }

        mutating func drawHorizontal(y: Int, x1: Int, x2: Int) {
            guard y >= 0, y < height else { return }
            let start = max(0, min(x1, x2))
            let end = min(width - 1, max(x1, x2))
            guard start <= end else { return }
            for x in start...end {
                putLine(glyphs.horizontal, x: x, y: y)
            }
        }

        mutating func drawVertical(x: Int, y1: Int, y2: Int) {
            guard x >= 0, x < width else { return }
            let start = max(0, min(y1, y2))
            let end = min(height - 1, max(y1, y2))
            guard start <= end else { return }
            for y in start...end {
                putLine(glyphs.vertical, x: x, y: y)
            }
        }

        mutating func putLine(_ char: Character, x: Int, y: Int) {
            guard y >= 0, y < height, x >= 0, x < width else { return }
            let existing = rows[y][x]
            if existing == " " {
                rows[y][x] = char
            } else if isLine(existing) && isLine(char) {
                rows[y][x] = mergedLine(existing: existing, incoming: char)
            }
        }

        private func isLine(_ char: Character) -> Bool {
            switch char {
            case glyphs.horizontal, glyphs.vertical, glyphs.teeDown, glyphs.teeUp,
                glyphs.teeRight, glyphs.teeLeft, glyphs.cross:
                return true
            default:
                return false
            }
        }

        private func mergedLine(existing: Character, incoming: Character) -> Character {
            if existing == incoming { return existing }
            if existing == glyphs.horizontal && incoming == glyphs.vertical { return glyphs.cross }
            if existing == glyphs.vertical && incoming == glyphs.horizontal { return glyphs.cross }
            if existing == glyphs.cross || incoming == glyphs.cross { return glyphs.cross }
            return incoming
        }

        func renderedLines() -> [String] {
            var out = rows.map { row -> String in
                var line = String(row)
                while line.last == " " {
                    line.removeLast()
                }
                return line
            }
            while out.last?.isEmpty == true {
                out.removeLast()
            }
            return out.isEmpty ? [""] : out
        }
    }

    static func lines(
        sourceMarkdown: String,
        kind: MermaidMiniParser.DiagramKind,
        nodes: [MarkdownMermaidAttachment.Node],
        edges: [MarkdownMermaidAttachment.Edge],
        maxColumns: Int
    ) -> [String] {
        let sourceLines = bodyLines(from: sourceMarkdown)
        switch kind {
        case .flowchart:
            if let rendered = renderFlowchart(
                sourceLines: sourceLines,
                nodes: nodes,
                edges: edges,
                maxColumns: maxColumns
            ) {
                return rendered
            }
        case .sequence:
            if let rendered = renderSequence(nodes: nodes, edges: edges, maxColumns: maxColumns) {
                return rendered
            }
        case .mindmap, .timeline, .journey, .sankey:
            break
        case .generic:
            if let rendered = renderGeneric(
                sourceLines: sourceLines,
                nodes: nodes,
                edges: edges,
                maxColumns: maxColumns
            ) {
                return rendered
            }
        }
        return sourceFallbackLines(sourceLines: sourceLines, kind: kind, nodes: nodes, edges: edges, maxColumns: maxColumns)
    }

    static func wrap(lines: [String], maxColumns: Int) -> [String] {
        let columns = max(16, maxColumns)
        var out: [String] = []
        for line in lines {
            out.append(contentsOf: wrap(line: line, maxColumns: columns))
        }
        return out
    }

    private static func renderFlowchart(
        sourceLines: [String],
        nodes: [MarkdownMermaidAttachment.Node],
        edges: [MarkdownMermaidAttachment.Edge],
        maxColumns: Int
    ) -> [String]? {
        guard !nodes.isEmpty else { return nil }

        let direction = flowDirection(from: sourceLines)
        let depths = graphDepths(nodes: nodes, edges: edges)
        let positioned = direction.isVertical
            ? verticalFlowNodes(nodes: nodes, depths: depths, direction: direction, maxColumns: maxColumns)
            : horizontalFlowNodes(nodes: nodes, depths: depths, direction: direction, maxColumns: maxColumns)
        guard !positioned.isEmpty else { return nil }

        let canvasWidth = max(24, min(maxColumns, (positioned.map(\.maxX).max() ?? 0) + 4))
        let canvasHeight = max(7, (positioned.map(\.maxY).max() ?? 0) + 4)
        var canvas = Canvas(width: canvasWidth, height: canvasHeight)
        let byID = Dictionary(uniqueKeysWithValues: positioned.map { ($0.id, $0) })

        for edge in edges.prefix(48) {
            guard let from = byID[edge.from], let to = byID[edge.to] else { continue }
            if direction.isVertical {
                drawVerticalFlowEdge(edge, from: from, to: to, canvas: &canvas)
            } else {
                drawHorizontalFlowEdge(edge, from: from, to: to, canvas: &canvas)
            }
        }

        for node in positioned {
            canvas.drawBox(node)
        }

        return canvas.renderedLines()
    }

    private static func renderSequence(
        nodes: [MarkdownMermaidAttachment.Node],
        edges: [MarkdownMermaidAttachment.Edge],
        maxColumns: Int
    ) -> [String]? {
        guard !nodes.isEmpty else { return nil }
        let participants = Array(nodes.prefix(8))
        let canvasWidth = max(24, maxColumns)
        let maxParticipantWidth = max(
            7,
            min(18, max(7, (canvasWidth - 2) / max(participants.count, 1) - 2))
        )

        var boxes: [RenderNode] = []
        let widestBox = participants
            .map { max(7, min(maxParticipantWidth, compactLabel($0.label, maxCharacters: maxParticipantWidth - 4).count + 4)) }
            .max() ?? 7
        let minCenter = max(1 + widestBox / 2, 1)
        let maxCenter = max(minCenter, canvasWidth - 2 - widestBox / 2)
        for (index, participant) in participants.enumerated() {
            let width = max(7, min(maxParticipantWidth, compactLabel(participant.label, maxCharacters: maxParticipantWidth - 4).count + 4))
            let centerX: Int
            if participants.count == 1 {
                centerX = canvasWidth / 2
            } else {
                centerX = minCenter + (maxCenter - minCenter) * index / max(1, participants.count - 1)
            }
            let box = RenderNode(
                id: participant.id,
                label: participant.label,
                x: max(0, min(canvasWidth - width - 1, centerX - width / 2)),
                y: 0,
                width: width,
                height: 3
            )
            boxes.append(box)
        }

        let messageCount = max(1, min(edges.count, 24))
        let canvasHeight = 6 + messageCount * 3
        var canvas = Canvas(width: canvasWidth, height: canvasHeight)
        let byID = Dictionary(uniqueKeysWithValues: boxes.map { ($0.id, $0) })

        for box in boxes {
            canvas.drawBox(box)
            canvas.drawVertical(x: box.centerX, y1: box.maxY + 1, y2: canvasHeight - 2)
        }

        for (index, edge) in edges.prefix(messageCount).enumerated() {
            guard let from = byID[edge.from], let to = byID[edge.to] else { continue }
            let y = 5 + index * 3
            let label = compactLabel(edge.label ?? "", maxCharacters: max(0, abs(to.centerX - from.centerX) - 2))
            if from.id == to.id {
                canvas.putText("↺ " + label, x: min(from.maxX + 2, max(0, canvasWidth - label.count - 3)), y: y)
                continue
            }

            if from.centerX < to.centerX {
                canvas.drawHorizontal(y: y, x1: from.centerX + 1, x2: to.centerX - 1)
                canvas.put(Glyphs.unicode.arrowRight, x: to.centerX - 1, y: y)
                drawCenteredLabel(label, startX: from.centerX + 1, endX: to.centerX - 1, y: y - 1, canvas: &canvas)
            } else {
                canvas.drawHorizontal(y: y, x1: to.centerX + 1, x2: from.centerX - 1)
                canvas.put(Glyphs.unicode.arrowLeft, x: to.centerX + 1, y: y)
                drawCenteredLabel(label, startX: to.centerX + 1, endX: from.centerX - 1, y: y - 1, canvas: &canvas)
            }
        }

        return canvas.renderedLines()
    }

    private static func renderGeneric(
        sourceLines: [String],
        nodes: [MarkdownMermaidAttachment.Node],
        edges: [MarkdownMermaidAttachment.Edge],
        maxColumns: Int
    ) -> [String]? {
        guard !sourceLines.isEmpty else { return nil }
        return sourcePanelLines(
            title: "\(genericTitle(from: sourceLines)) · \(countLabel(nodes.count, singular: "node")) · \(countLabel(edges.count, singular: "edge"))",
            lines: sourceLines,
            maxColumns: maxColumns
        )
    }

    private static func verticalFlowNodes(
        nodes: [MarkdownMermaidAttachment.Node],
        depths: [String: Int],
        direction: FlowDirection,
        maxColumns: Int
    ) -> [RenderNode] {
        let order = nodeOrder(nodes)
        let groups = groupedNodes(nodes: nodes, depths: depths, order: order, reversed: direction.isReversed)
        let maxSiblings = max(1, groups.map(\.nodes.count).max() ?? 1)
        let gapX = maxSiblings >= 3 ? 3 : 5
        let availablePerNode = max(5, (maxColumns - 2 - max(0, maxSiblings - 1) * gapX) / maxSiblings)
        let maxLabelCharacters = max(3, min(34, availablePerNode - 4))
        let rowGap = 3
        let boxHeight = 3
        let rowBoxes = groups.map { group in
            group.nodes.map { node -> (MarkdownMermaidAttachment.Node, Int) in
                let labelWidth = compactLabel(node.label, maxCharacters: maxLabelCharacters).count
                return (node, max(7, min(availablePerNode, labelWidth + 4)))
            }
        }
        let rowWidths = rowBoxes.map { boxes in
            boxes.reduce(0) { $0 + $1.1 } + max(0, boxes.count - 1) * gapX
        }
        let canvasWidth = max(24, min(maxColumns, (rowWidths.max() ?? 0) + 2))

        var rendered: [RenderNode] = []
        for (rank, boxes) in rowBoxes.enumerated() {
            let rowWidth = rowWidths[rank]
            var x = max(1, (canvasWidth - rowWidth) / 2)
            let y = 1 + rank * (boxHeight + rowGap)
            for (node, width) in boxes {
                rendered.append(RenderNode(id: node.id, label: node.label, x: x, y: y, width: width, height: boxHeight))
                x += width + gapX
            }
        }
        return rendered
    }

    private static func horizontalFlowNodes(
        nodes: [MarkdownMermaidAttachment.Node],
        depths: [String: Int],
        direction: FlowDirection,
        maxColumns: Int
    ) -> [RenderNode] {
        let order = nodeOrder(nodes)
        let groups = groupedNodes(nodes: nodes, depths: depths, order: order, reversed: direction.isReversed)
        let gapX = 6
        let gapY = 2
        let boxHeight = 3
        let columnCount = max(1, groups.count)
        let availablePerColumn = max(7, (maxColumns - 2 - max(0, columnCount - 1) * gapX) / columnCount)
        let maxLabelCharacters = max(3, min(24, availablePerColumn - 4))

        var rendered: [RenderNode] = []
        var x = 1
        for group in groups {
            let columnWidth = max(
                7,
                min(
                    availablePerColumn,
                    (group.nodes.map { compactLabel($0.label, maxCharacters: maxLabelCharacters).count }.max() ?? 3) + 4
                )
            )
            var y = 1
            for node in group.nodes {
                rendered.append(RenderNode(id: node.id, label: node.label, x: x, y: y, width: columnWidth, height: boxHeight))
                y += boxHeight + gapY
            }
            x += columnWidth + gapX
        }
        return rendered
    }

    private static func drawVerticalFlowEdge(
        _ edge: MarkdownMermaidAttachment.Edge,
        from: RenderNode,
        to: RenderNode,
        canvas: inout Canvas
    ) {
        if to.centerY > from.centerY {
            let startY = from.maxY + 1
            let endY = to.minY - 1
            guard startY <= endY else { return }
            let midY = max(startY, (startY + endY) / 2)
            canvas.drawVertical(x: from.centerX, y1: startY, y2: midY)
            canvas.drawHorizontal(y: midY, x1: from.centerX, x2: to.centerX)
            canvas.drawVertical(x: to.centerX, y1: midY, y2: endY)
            canvas.put(Glyphs.unicode.arrowDown, x: to.centerX, y: endY)
            drawEdgeLabel(edge.label, startX: from.centerX, endX: to.centerX, y: max(startY, midY - 1), canvas: &canvas)
        } else if to.centerY < from.centerY {
            let startY = from.minY - 1
            let endY = to.maxY + 1
            guard endY <= startY else { return }
            let midY = max(endY, (startY + endY) / 2)
            canvas.drawVertical(x: from.centerX, y1: midY, y2: startY)
            canvas.drawHorizontal(y: midY, x1: from.centerX, x2: to.centerX)
            canvas.drawVertical(x: to.centerX, y1: endY, y2: midY)
            canvas.put(Glyphs.unicode.arrowUp, x: to.centerX, y: endY)
            drawEdgeLabel(edge.label, startX: from.centerX, endX: to.centerX, y: max(0, midY - 1), canvas: &canvas)
        } else {
            let routeX = min(canvas.width - 2, max(from.maxX, to.maxX) + 2)
            canvas.drawHorizontal(y: from.centerY, x1: from.maxX + 1, x2: routeX)
            canvas.drawVertical(x: routeX, y1: min(from.centerY, to.centerY), y2: max(from.centerY, to.centerY) + 2)
            canvas.drawHorizontal(y: to.centerY, x1: to.maxX + 1, x2: routeX)
        }
    }

    private static func drawHorizontalFlowEdge(
        _ edge: MarkdownMermaidAttachment.Edge,
        from: RenderNode,
        to: RenderNode,
        canvas: inout Canvas
    ) {
        if to.centerX > from.centerX {
            let startX = from.maxX + 1
            let endX = to.minX - 1
            guard startX <= endX else { return }
            let midX = max(startX, (startX + endX) / 2)
            canvas.drawHorizontal(y: from.centerY, x1: startX, x2: midX)
            canvas.drawVertical(x: midX, y1: from.centerY, y2: to.centerY)
            canvas.drawHorizontal(y: to.centerY, x1: midX, x2: endX)
            canvas.put(Glyphs.unicode.arrowRight, x: endX, y: to.centerY)
            drawEdgeLabel(edge.label, startX: startX, endX: endX, y: max(0, min(from.centerY, to.centerY) - 1), canvas: &canvas)
        } else if to.centerX < from.centerX {
            let startX = from.minX - 1
            let endX = to.maxX + 1
            guard endX <= startX else { return }
            let midX = max(endX, (startX + endX) / 2)
            canvas.drawHorizontal(y: from.centerY, x1: midX, x2: startX)
            canvas.drawVertical(x: midX, y1: from.centerY, y2: to.centerY)
            canvas.drawHorizontal(y: to.centerY, x1: endX, x2: midX)
            canvas.put(Glyphs.unicode.arrowLeft, x: endX, y: to.centerY)
            drawEdgeLabel(edge.label, startX: endX, endX: startX, y: max(0, min(from.centerY, to.centerY) - 1), canvas: &canvas)
        } else {
            let routeY = max(from.maxY, to.maxY) + 2
            canvas.drawVertical(x: from.centerX, y1: from.maxY + 1, y2: routeY)
            canvas.drawHorizontal(y: routeY, x1: min(from.centerX, to.centerX), x2: max(from.centerX, to.centerX) + 3)
        }
    }

    private static func drawEdgeLabel(
        _ rawLabel: String?,
        startX: Int,
        endX: Int,
        y: Int,
        canvas: inout Canvas
    ) {
        let available = max(0, abs(endX - startX) - 2)
        let label = compactLabel(rawLabel ?? "", maxCharacters: min(18, available))
        drawCenteredLabel(label, startX: startX, endX: endX, y: y, canvas: &canvas)
    }

    private static func drawCenteredLabel(
        _ label: String,
        startX: Int,
        endX: Int,
        y: Int,
        canvas: inout Canvas
    ) {
        guard !label.isEmpty, y >= 0 else { return }
        let left = min(startX, endX)
        let right = max(startX, endX)
        let available = max(0, right - left + 1)
        guard available >= label.count else { return }
        let x = left + max(0, (available - label.count) / 2)
        canvas.putText(label, x: x, y: y)
    }

    private struct GroupedDepth {
        let depth: Int
        let nodes: [MarkdownMermaidAttachment.Node]
    }

    private static func groupedNodes(
        nodes: [MarkdownMermaidAttachment.Node],
        depths: [String: Int],
        order: [String: Int],
        reversed: Bool
    ) -> [GroupedDepth] {
        let grouped = Dictionary(grouping: nodes) { depths[$0.id] ?? 0 }
        var depthKeys = grouped.keys.sorted()
        if reversed { depthKeys.reverse() }
        return depthKeys.map { depth in
            let ordered = (grouped[depth] ?? []).sorted { lhs, rhs in
                (order[lhs.id] ?? 0) < (order[rhs.id] ?? 0)
            }
            return GroupedDepth(depth: depth, nodes: ordered)
        }
    }

    private static func nodeOrder(_ nodes: [MarkdownMermaidAttachment.Node]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
    }

    private static func graphDepths(
        nodes: [MarkdownMermaidAttachment.Node],
        edges: [MarkdownMermaidAttachment.Edge]
    ) -> [String: Int] {
        let incoming = Dictionary(grouping: edges, by: \.to).mapValues(\.count)
        let outgoing = Dictionary(grouping: edges, by: \.from)
        var depth: [String: Int] = [:]
        var queue = nodes.map(\.id).filter { incoming[$0] == nil }
        if queue.isEmpty, let first = nodes.first?.id {
            queue = [first]
        }
        for root in queue { depth[root] = 0 }

        let maxDepth = max(0, nodes.count - 1)
        var index = 0
        while index < queue.count {
            let current = queue[index]
            index += 1
            let currentDepth = depth[current] ?? 0
            for edge in outgoing[current] ?? [] where depth[edge.to] == nil {
                depth[edge.to] = min(currentDepth + 1, maxDepth)
                queue.append(edge.to)
            }
        }

        if depth.count < nodes.count {
            var fallbackDepth = min((depth.values.max() ?? -1) + 1, maxDepth)
            for node in nodes where depth[node.id] == nil {
                depth[node.id] = fallbackDepth
                fallbackDepth = min(fallbackDepth + 1, maxDepth)
            }
        }
        return depth
    }

    private static func flowDirection(from bodyLines: [String]) -> FlowDirection {
        guard let first = bodyLines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return .topDown
        }
        let tokens = first.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0 == " " || $0 == "\t" }
            .map { String($0).uppercased() }
        guard tokens.count >= 2 else { return .topDown }
        switch tokens[1] {
        case "LR": return .leftRight
        case "RL": return .rightLeft
        case "BT": return .bottomTop
        default: return .topDown
        }
    }

    private static func sourceFallbackLines(
        sourceLines: [String],
        kind: MermaidMiniParser.DiagramKind,
        nodes: [MarkdownMermaidAttachment.Node],
        edges: [MarkdownMermaidAttachment.Edge],
        maxColumns: Int
    ) -> [String] {
        if !sourceLines.isEmpty {
            return sourcePanelLines(
                title: "\(kindLabel(kind)) source · \(countLabel(nodes.count, singular: "node")) · \(countLabel(edges.count, singular: "edge"))",
                lines: sourceLines,
                maxColumns: maxColumns
            )
        }

        if nodes.isEmpty {
            return sourcePanelLines(
                title: "\(kindLabel(kind)) source",
                lines: ["No nodes parsed"],
                maxColumns: maxColumns
            )
        }

        let summary = nodes.prefix(24).map { "[\($0.id)] \($0.label)" }
        return sourcePanelLines(
            title: "\(kindLabel(kind)) source · \(countLabel(nodes.count, singular: "node")) · \(countLabel(edges.count, singular: "edge"))",
            lines: summary,
            maxColumns: maxColumns
        )
    }

    private static func sourcePanelLines(title rawTitle: String, lines rawLines: [String], maxColumns: Int) -> [String] {
        let safeColumns = max(24, maxColumns)
        let title = compactLabel(rawTitle, maxCharacters: safeColumns)
        var out = [title, String(repeating: "─", count: min(safeColumns, max(12, title.count)))]
        let bodyColumns = max(16, safeColumns - 2)
        let wrappedBody = rawLines.flatMap { line in
            wrap(line: line, maxColumns: bodyColumns)
        }
        for line in wrappedBody.prefix(32) {
            out.append("  " + line)
        }
        if wrappedBody.count > 32 {
            out.append("  " + compactLabel("… +\(wrappedBody.count - 32) more lines", maxCharacters: bodyColumns))
        }
        return out
    }

    private static func genericTitle(from sourceLines: [String]) -> String {
        guard let first = sourceLines.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return "Mermaid"
        }
        let token = first.trimmingCharacters(in: .whitespacesAndNewlines)
            .split { $0 == " " || $0 == "\t" }
            .first
            .map(String.init) ?? "Mermaid"
        return compactLabel(token, maxCharacters: 36)
    }

    private static func countLabel(_ count: Int, singular: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count) \(singular)s"
    }

    private static func wrap(line: String, maxColumns: Int) -> [String] {
        guard line.count > maxColumns else { return [line] }
        var remaining = line[...]
        var wrapped: [String] = []
        while remaining.count > maxColumns {
            let splitIndex = remaining.index(remaining.startIndex, offsetBy: maxColumns)
            let prefix = remaining[..<splitIndex]
            if let ws = prefix.lastIndex(where: { $0.isWhitespace }), ws > remaining.startIndex {
                let chunk = String(remaining[..<ws]).trimmingCharacters(in: .whitespaces)
                wrapped.append(chunk)
                let next = remaining.index(after: ws)
                remaining = remaining[next...]
            } else {
                wrapped.append(String(prefix))
                remaining = remaining[splitIndex...]
            }
        }
        wrapped.append(String(remaining))
        return wrapped
    }

    private static func compactLabel(_ raw: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0 else { return "" }
        var label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        label = label.replacingOccurrences(of: #"<br\s*/?>"#, with: " / ", options: [.regularExpression, .caseInsensitive])
        label = label.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if label.count <= maxCharacters { return label }
        if maxCharacters <= 1 { return "…" }
        return String(label.prefix(maxCharacters - 1)) + "…"
    }

    private static func kindLabel(_ kind: MermaidMiniParser.DiagramKind) -> String {
        switch kind {
        case .flowchart: return "flowchart"
        case .sequence: return "sequence"
        case .mindmap: return "mindmap"
        case .timeline: return "timeline"
        case .journey: return "journey"
        case .sankey: return "sankey"
        case .generic: return "generic"
        }
    }

    private static func bodyLines(from sourceMarkdown: String) -> [String] {
        let normalized = sourceMarkdown.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
            lines.removeFirst()
        }
        if lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") == true {
            lines.removeLast()
        }
        while lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            lines.removeLast()
        }
        return lines
    }
}
